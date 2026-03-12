import logging
import azure.functions as func
import json
import os
from azure.cosmos.aio import CosmosClient
from shared.util import get_credential

LOGLEVEL = os.environ.get('LOGLEVEL', 'DEBUG').upper()
logging.basicConfig(level=LOGLEVEL)
logging.getLogger('azure').setLevel(logging.WARNING)
logging.getLogger('azure.cosmos').setLevel(logging.WARNING)

AZURE_DB_ID = os.environ.get("AZURE_DB_ID")
AZURE_DB_NAME = os.environ.get("AZURE_DB_NAME")
AZURE_DB_URI = f"https://{AZURE_DB_ID}.documents.azure.com:443/"


async def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Conversation detail function processed a request.')

    conversation_id = req.params.get('conversation_id')
    client_principal_id = req.params.get('client_principal_id')

    if not conversation_id:
        return func.HttpResponse(
            json.dumps({"error": "conversation_id is required"}),
            mimetype="application/json", status_code=400
        )

    if not client_principal_id:
        return func.HttpResponse(
            json.dumps({"error": "client_principal_id is required"}),
            mimetype="application/json", status_code=400
        )

    credential = get_credential()
    async with CosmosClient(AZURE_DB_URI, credential=credential) as db_client:
        db = db_client.get_database_client(database=AZURE_DB_NAME)
        container = db.get_container_client('conversations')

        try:
            conversation = await container.read_item(
                item=conversation_id, partition_key=conversation_id
            )
        except Exception:
            return func.HttpResponse(
                json.dumps({"error": "conversation not found"}),
                mimetype="application/json", status_code=404
            )

        # Verify the requesting user owns this conversation
        interactions = conversation.get('conversation_data', {}).get('interactions', [])
        if not interactions or interactions[0].get('user_id') != client_principal_id:
            return func.HttpResponse(
                json.dumps({"error": "conversation not found"}),
                mimetype="application/json", status_code=404
            )

        # Return conversation history and metadata
        result = {
            "conversation_id": conversation_id,
            "start_date": conversation.get('conversation_data', {}).get('start_date'),
            "history": conversation.get('history', []),
            "interaction_count": len(interactions)
        }

    return func.HttpResponse(json.dumps(result), mimetype="application/json", status_code=200)
