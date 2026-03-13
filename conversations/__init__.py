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
    logging.info('Conversations list function processed a request.')

    client_principal_id = req.params.get('client_principal_id')
    if not client_principal_id:
        return func.HttpResponse(
            json.dumps({"error": "client_principal_id is required"}),
            mimetype="application/json", status_code=400
        )

    limit = int(req.params.get('limit', 50))

    credential = get_credential()
    async with CosmosClient(AZURE_DB_URI, credential=credential) as db_client:
        db = db_client.get_database_client(database=AZURE_DB_NAME)
        container = db.get_container_client('conversations')

        # Query conversations where the user participated (check first interaction's user_id)
        query = (
            "SELECT c.id, c.conversation_data.start_date, "
            "ARRAY_LENGTH(c.conversation_data.interactions) AS interaction_count, "
            "c.conversation_data.interactions[0].user_ask AS first_question "
            "FROM c "
            "WHERE c.conversation_data.interactions[0].user_id = @client_principal_id "
            "ORDER BY c.conversation_data.start_date DESC "
            "OFFSET 0 LIMIT @limit"
        )
        parameters = [
            {"name": "@client_principal_id", "value": client_principal_id},
            {"name": "@limit", "value": limit}
        ]

        conversations = []
        async for item in container.query_items(
            query=query,
            parameters=parameters
        ):
            conversations.append(item)

        result = {
            "client_principal_id": client_principal_id,
            "conversations": conversations
        }

    return func.HttpResponse(json.dumps(result), mimetype="application/json", status_code=200)
