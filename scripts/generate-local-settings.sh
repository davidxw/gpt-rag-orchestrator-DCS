#!/bin/bash

set -e

# Generate local.settings.json from an .env file
# Usage: ./generate-local-settings.sh <path-to-env-file> [output-file]

if [ -z "$1" ]; then
    echo "Usage: $0 <path-to-env-file> [output-file]"
    echo "  output-file defaults to ../local.settings.json (relative to this script)"
    exit 1
fi

ENV_FILE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${2:-$SCRIPT_DIR/../local.settings.json}"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found: $ENV_FILE"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Install it with: sudo apt install jq"
    exit 1
fi

# Parse .env file into an associative array
declare -A env_vars
while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Match KEY=VALUE or KEY="VALUE"
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # Strip surrounding quotes, unescape internal escaped quotes, and remove \r
        value="${value#\"}"
        value="${value%\"}"
        value="${value//\\\"/\"}"
        value="${value//$'\r'/}"
        env_vars["$key"]="$value"
    fi
done < "$ENV_FILE"

echo "Read ${#env_vars[@]} variables from $ENV_FILE"

# --- Map .env variables to local.settings.json values ---

AZURE_KEY_VAULT_NAME="${env_vars[AZURE_KEY_VAULT_NAME]:-${env_vars[AZURE_KV_NAME]:-}}"
AZURE_SEARCH_SERVICE="${env_vars[AZURE_SEARCH_SERVICE_NAME]:-}"
AZURE_SEARCH_INDEX="${env_vars[AZURE_SEARCH_INDEX]:-ragindex}"
AZURE_SEARCH_APPROACH="${env_vars[AZURE_RETRIEVAL_APPROACH]:-hybrid}"
AZURE_SEARCH_USE_SEMANTIC="${env_vars[AZURE_USE_SEMANTIC_RERANKING]:-false}"
AZURE_OPENAI_RESOURCE="${env_vars[AZURE_OPENAI_SERVICE_NAME]:-}"
AZURE_OPENAI_CHATGPT_DEPLOYMENT="${env_vars[AZURE_CHAT_GPT_DEPLOYMENT_NAME]:-chat}"
AZURE_OPENAI_CHATGPT_MODEL="${env_vars[AZURE_CHAT_GPT_MODEL_NAME]:-}"
AZURE_OPENAI_EMBEDDING_DEPLOYMENT="${env_vars[AZURE_EMBEDDINGS_DEPLOYMENT_NAME]:-text-embedding}"
ORCHESTRATOR_MESSAGES_LANGUAGE="${env_vars[AZURE_ORCHESTRATOR_MESSAGES_LANGUAGE]:-en}"

# Try to extract Cosmos DB info from AZURE_DB_CONFIG JSON
AZURE_DB_ID=""
AZURE_DB_NAME=""
if [ -n "${env_vars[AZURE_DB_CONFIG]:-}" ]; then
    AZURE_DB_ID=$(echo "${env_vars[AZURE_DB_CONFIG]}" | jq -r '.dbAccountName // empty' 2>/dev/null || true)
    AZURE_DB_NAME=$(echo "${env_vars[AZURE_DB_CONFIG]}" | jq -r '.dbDatabaseName // empty' 2>/dev/null || true)
fi

# Warn about empty Cosmos DB values
if [ -z "$AZURE_DB_ID" ] || [ -z "$AZURE_DB_NAME" ]; then
    echo ""
    echo "WARNING: AZURE_DB_ID and/or AZURE_DB_NAME could not be determined from the .env file."
    echo "  The .env variable AZURE_DB_CONFIG has empty dbAccountName/dbDatabaseName fields."
    echo "  You will need to set these manually in $OUTPUT_FILE"
    echo ""
fi

# Build the JSON using jq
jq -n \
    --arg key_vault "$AZURE_KEY_VAULT_NAME" \
    --arg db_id "$AZURE_DB_ID" \
    --arg db_name "$AZURE_DB_NAME" \
    --arg search_service "$AZURE_SEARCH_SERVICE" \
    --arg search_index "$AZURE_SEARCH_INDEX" \
    --arg search_approach "$AZURE_SEARCH_APPROACH" \
    --arg search_use_semantic "$AZURE_SEARCH_USE_SEMANTIC" \
    --arg openai_resource "$AZURE_OPENAI_RESOURCE" \
    --arg openai_chat_deployment "$AZURE_OPENAI_CHATGPT_DEPLOYMENT" \
    --arg openai_chat_model "$AZURE_OPENAI_CHATGPT_MODEL" \
    --arg openai_embedding_deployment "$AZURE_OPENAI_EMBEDDING_DEPLOYMENT" \
    --arg messages_language "$ORCHESTRATOR_MESSAGES_LANGUAGE" \
'{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "LOCAL_ENV": "true",

    "AZURE_KEY_VAULT_NAME": $key_vault,

    "AZURE_DB_ID": $db_id,
    "AZURE_DB_NAME": $db_name,

    "AZURE_SEARCH_SERVICE": $search_service,
    "AZURE_SEARCH_INDEX": $search_index,
    "AZURE_SEARCH_API_VERSION": "2024-07-01",
    "AZURE_SEARCH_APPROACH": $search_approach,
    "AZURE_SEARCH_USE_SEMANTIC": $search_use_semantic,
    "AZURE_SEARCH_TOP_K": "3",

    "AZURE_OPENAI_RESOURCE": $openai_resource,
    "AZURE_OPENAI_CHATGPT_DEPLOYMENT": $openai_chat_deployment,
    "AZURE_OPENAI_CHATGPT_MODEL": $openai_chat_model,
    "AZURE_OPENAI_EMBEDDING_DEPLOYMENT": $openai_embedding_deployment,
    "AZURE_OPENAI_EMBEDDING_APIVERSION": "2024-05-01-preview",
    "AZURE_OPENAI_CHATGPT_MONITORING_DEPLOYMENT": "chat",
    "AZURE_OPENAI_CHATGPT_LLM_MONITORING": "true",
    "AZURE_OPENAI_STREAM": "false",
    "AZURE_OPENAI_LOAD_BALANCING": "true",

    "AZURE_OPENAI_TEMPERATURE": "0.1",
    "AZURE_OPENAI_TOP_P": "0.27",
    "AZURE_OPENAI_MAX_TOKENS": "1000",
    "AZURE_OPENAI_APIVERSION": "2024-05-01-preview",

    "BING_SEARCH_TOP_K": "3",
    "BING_SEARCH_MAX_TOKENS": "1000",

    "ORCHESTRATOR_MESSAGES_LANGUAGE": $messages_language,
    "CONVERSATION_MAX_HISTORY": "3",

    "BLOCKED_LIST_CHECK": "true",
    "GROUNDEDNESS_CHECK": "true",
    "RESPONSIBLE_AI_CHECK": "true",
    "SECURITY_HUB_CHECK": "false",
    "SECURITY_HUB_AUDIT": "false",

    "SECURITY_HUB_ENDPOINT": "",
    "CONVERSATION_METADATA": "true",

    "BING_RETRIEVAL": "false",
    "SEARCH_RETRIEVAL": "true",
    "RETRIEVAL_PRIORITY": "search",
    "DB_RETRIEVAL": "false",
    "DB_SERVER": "",
    "DB_DATABASE": "",
    "DB_USERNAME": "",
    "DB_TOP_K": "3",
    "DB_MAX_TOKENS": "1000",
    "SECURITY_HUB_HATE_THRESHHOLD": "0",
    "SECURITY_HUB_SELFHARM_THRESHHOLD": "0",
    "SECURITY_HUB_SEXUAL_THRESHHOLD": "0",
    "SECURITY_HUB_VIOLENCE_THRESHHOLD": "0",
    "SECURITY_HUB_UNGROUNDED_PERCENTAGE_THRESHHOLD": "0.1",
    "APIM_ENABLED": "false",
    "APIM_AZURE_OPENAI_ENDPOINT": "",
    "APIM_BING_CUSTOM_SEARCH_URL": "",
    "APIM_AZURE_SEARCH_URL": "",
    "APIM_SECURITY_HUB_ENDPOINT": ""
  }
}' > "$OUTPUT_FILE"

echo "Generated: $OUTPUT_FILE"
echo ""
echo "--- Mapped values from .env ---"
echo "AZURE_KEY_VAULT_NAME:              $AZURE_KEY_VAULT_NAME"
echo "AZURE_DB_ID:                       ${AZURE_DB_ID:-(empty - set manually)}"
echo "AZURE_DB_NAME:                     ${AZURE_DB_NAME:-(empty - set manually)}"
echo "AZURE_SEARCH_SERVICE:              $AZURE_SEARCH_SERVICE"
echo "AZURE_SEARCH_INDEX:                $AZURE_SEARCH_INDEX"
echo "AZURE_SEARCH_APPROACH:             $AZURE_SEARCH_APPROACH"
echo "AZURE_SEARCH_USE_SEMANTIC:         $AZURE_SEARCH_USE_SEMANTIC"
echo "AZURE_OPENAI_RESOURCE:             $AZURE_OPENAI_RESOURCE"
echo "AZURE_OPENAI_CHATGPT_DEPLOYMENT:   $AZURE_OPENAI_CHATGPT_DEPLOYMENT"
echo "AZURE_OPENAI_CHATGPT_MODEL:        $AZURE_OPENAI_CHATGPT_MODEL"
echo "AZURE_OPENAI_EMBEDDING_DEPLOYMENT: $AZURE_OPENAI_EMBEDDING_DEPLOYMENT"
echo "ORCHESTRATOR_MESSAGES_LANGUAGE:     $ORCHESTRATOR_MESSAGES_LANGUAGE"
echo "-------------------------------"
