import logging
import azure.functions as func
import json
import os
import uuid
from datetime import datetime, timezone

from azure.cosmos.aio import CosmosClient
from azure.cosmos import exceptions as cosmos_exceptions

from shared.util import get_credential

LOGLEVEL = os.environ.get('LOGLEVEL', 'DEBUG').upper()
logging.basicConfig(level=LOGLEVEL)
logging.getLogger('azure').setLevel(logging.WARNING)
logging.getLogger('azure.cosmos').setLevel(logging.WARNING)

AZURE_DB_ID = os.environ.get("AZURE_DB_ID")
AZURE_DB_NAME = os.environ.get("AZURE_DB_NAME")
AZURE_DB_URI = f"https://{AZURE_DB_ID}.documents.azure.com:443/"

FEEDBACK_CONTAINER = os.environ.get("AZURE_DB_FEEDBACK_CONTAINER", "feedback")
CONVERSATIONS_CONTAINER = "conversations"

MAX_COMMENT_LEN = 4000
ALLOWED_RATINGS = {"up", "down"}


def _bad_request(detail: str) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"error": "invalid_request", "detail": detail}),
        mimetype="application/json",
        status_code=400,
    )


def _internal_error() -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"error": "internal_error"}),
        mimetype="application/json",
        status_code=500,
    )


async def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Feedback function processed a request.")

    # Parse JSON body
    try:
        body = req.get_json()
    except ValueError:
        return _bad_request("request body must be valid JSON")

    if not isinstance(body, dict):
        return _bad_request("request body must be a JSON object")

    conversation_id = body.get("conversation_id")
    question = body.get("question")
    answer = body.get("answer")
    rating = body.get("rating")
    comment = body.get("comment", "") or ""
    message_index = body.get("message_index")
    client_principal_id = body.get("client_principal_id")
    client_principal_name = body.get("client_principal_name")
    client_group_names = body.get("client_group_names")

    # Validation
    if not isinstance(conversation_id, str) or not conversation_id.strip():
        return _bad_request("conversation_id is required")
    if not isinstance(answer, str) or not answer.strip():
        return _bad_request("answer is required")
    if rating not in ALLOWED_RATINGS:
        return _bad_request('rating must be "up" or "down"')
    if not isinstance(comment, str):
        return _bad_request("comment must be a string")
    if len(comment) > MAX_COMMENT_LEN:
        return _bad_request(f"comment exceeds {MAX_COMMENT_LEN} character limit")

    if message_index is not None:
        if isinstance(message_index, bool) or not isinstance(message_index, int):
            return _bad_request("message_index must be an integer")

    if client_group_names is not None and not (
        isinstance(client_group_names, list)
        and all(isinstance(g, str) for g in client_group_names)
    ):
        return _bad_request("client_group_names must be an array of strings")

    if question is not None and not isinstance(question, str):
        return _bad_request("question must be a string")

    feedback_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z"

    document = {
        "id": feedback_id,
        "conversation_id": conversation_id,
        "message_index": message_index,
        "question": question or "",
        "answer": answer,
        "rating": rating,
        "comment": comment,
        "user": {
            "principal_id": client_principal_id,
            "principal_name": client_principal_name,
            "groups": client_group_names or [],
        },
        "timestamp": timestamp,
        "source": "frontend",
    }

    try:
        credential = get_credential()
        async with CosmosClient(AZURE_DB_URI, credential=credential) as db_client:
            db = db_client.get_database_client(database=AZURE_DB_NAME)
            feedback_container = db.get_container_client(FEEDBACK_CONTAINER)
            await feedback_container.create_item(body=document)

            # Best-effort: stamp last_feedback summary on the matching conversation turn.
            try:
                conv_container = db.get_container_client(CONVERSATIONS_CONTAINER)
                conversation = await conv_container.read_item(
                    item=conversation_id, partition_key=conversation_id
                )
                last_feedback = {"rating": rating, "timestamp": timestamp}
                conversation["last_feedback"] = last_feedback

                interactions = (
                    conversation.get("conversation_data", {}).get("interactions", [])
                )
                if (
                    isinstance(message_index, int)
                    and 0 <= message_index < len(interactions)
                ):
                    interactions[message_index]["last_feedback"] = last_feedback

                await conv_container.replace_item(item=conversation, body=conversation)
            except cosmos_exceptions.CosmosResourceNotFoundError:
                logging.info(
                    "[feedback] conversation %s not found while stamping last_feedback",
                    conversation_id,
                )
            except Exception as stamp_err:  # noqa: BLE001
                logging.warning(
                    "[feedback] failed to stamp last_feedback on conversation %s: %s",
                    conversation_id,
                    stamp_err,
                )
    except Exception as e:  # noqa: BLE001
        logging.exception("[feedback] failed to persist feedback: %s", e)
        return _internal_error()

    # Observability: structured log + App Insights custom event.
    # Avoid logging comment text and principal name (PII).
    event_dimensions = {
        "conversation_id": conversation_id,
        "message_index": message_index,
        "rating": rating,
        "client_principal_id": client_principal_id,
        "feedback_id": feedback_id,
    }
    logging.info(
        "[feedback] FeedbackSubmitted conversation_id=%s message_index=%s rating=%s "
        "client_principal_id=%s feedback_id=%s",
        conversation_id,
        message_index,
        rating,
        client_principal_id,
        feedback_id,
    )

    # Emit App Insights custom event if the events extension is available.
    try:
        from azure.monitor.events.extension import track_event  # type: ignore

        track_event("FeedbackSubmitted", event_dimensions)
    except Exception:  # noqa: BLE001
        # Extension not installed; the structured log above is captured by
        # App Insights via the Functions Python worker integration.
        pass

    return func.HttpResponse(
        json.dumps({"status": "ok", "feedback_id": feedback_id}),
        mimetype="application/json",
        status_code=200,
    )
