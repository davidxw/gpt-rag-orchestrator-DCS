#!/bin/bash

set -e

# Usage: ./assign-local-dev-roles.sh [resource-group-name]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/../local.settings.json"
RESOURCE_GROUP_ARG="${1:-}"

echo "=== Assign Local Development Roles ==="
echo ""

# Get the principal ID of the currently logged-in user
echo "Retrieving logged-in Azure CLI user..."
principalId=$(az ad signed-in-user show --query id -o tsv | tr -d '\r')
userName=$(az ad signed-in-user show --query userPrincipalName -o tsv | tr -d '\r')
echo "User: $userName"
echo "Principal ID: $principalId"
echo ""

# Get subscription ID
subscriptionId=$(az account show --query id -o tsv | tr -d '\r')
echo "Subscription: $subscriptionId"
echo ""

# Try to read resource names from local.settings.json
cosmosDbAccountName=""
openAIAccountName=""
aiSearchResource=""

if [ -f "$SETTINGS_FILE" ]; then
    echo "Reading resource names from local.settings.json..."
    if command -v jq &> /dev/null; then
        cosmosDbAccountName=$(jq -r '.Values.AZURE_DB_ID // empty' "$SETTINGS_FILE" | tr -d '\r')
        openAIAccountName=$(jq -r '.Values.AZURE_OPENAI_RESOURCE // empty' "$SETTINGS_FILE" | tr -d '\r')
        aiSearchResource=$(jq -r '.Values.AZURE_SEARCH_SERVICE // empty' "$SETTINGS_FILE" | tr -d '\r')
    else
        echo "Warning: jq is not installed. Cannot read local.settings.json automatically."
    fi
else
    echo "local.settings.json not found."
fi

# Prompt for any missing values
if [ -z "$cosmosDbAccountName" ]; then
    read -rp "Enter Cosmos DB account name: " cosmosDbAccountName
fi

if [ -z "$openAIAccountName" ]; then
    read -rp "Enter Azure OpenAI resource name: " openAIAccountName
fi

if [ -z "$aiSearchResource" ]; then
    read -rp "Enter Azure AI Search service name: " aiSearchResource
fi

if [ -n "$RESOURCE_GROUP_ARG" ]; then
    resourceGroupName="$RESOURCE_GROUP_ARG"
else
    read -rp "Enter resource group name: " resourceGroupName
fi

echo ""
echo "--- Configuration ---"
echo "Cosmos DB Account:    $cosmosDbAccountName"
echo "OpenAI Resource:      $openAIAccountName"
echo "AI Search Service:    $aiSearchResource"
echo "Resource Group:       $resourceGroupName"
echo "Subscription:         $subscriptionId"
echo "Principal ID:         $principalId"
echo "---------------------"
echo ""

# 1. Cosmos DB Built-in Data Contributor
echo "[1/4] Assigning Cosmos DB 'Built-in Data Contributor' role..."
roleDefinitionId='00000000-0000-0000-0000-000000000002'
if az cosmosdb sql role assignment create \
    --account-name "$cosmosDbAccountName" \
    --resource-group "$resourceGroupName" \
    --scope "/" \
    --principal-id "$principalId" \
    --role-definition-id "$roleDefinitionId"; then
    echo "  Done."
else
    echo "  Warning: assignment may already exist or failed."
fi

# 2. Cognitive Services OpenAI User (5e0bd9bd-7b93-4f28-af87-19fc36ad61bd)
echo "[2/4] Assigning 'Cognitive Services OpenAI User' role..."
if az role assignment create \
    --role "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd" \
    --assignee-object-id "$principalId" \
    --assignee-principal-type User \
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.CognitiveServices/accounts/$openAIAccountName"; then
    echo "  Done."
else
    echo "  Warning: assignment may already exist or failed."
fi

# 3. Search Index Data Contributor (8ebe5a00-799e-43f5-93ac-243d3dce84a7)
echo "[3/4] Assigning 'Search Index Data Contributor' role..."
if az role assignment create \
    --role "8ebe5a00-799e-43f5-93ac-243d3dce84a7" \
    --assignee-object-id "$principalId" \
    --assignee-principal-type User \
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Search/searchServices/$aiSearchResource"; then
    echo "  Done."
else
    echo "  Warning: assignment may already exist or failed."
fi

# 4. Search Service Contributor (7ca78c08-252a-4471-8644-bb5ff32d4ba0)
echo "[4/4] Assigning 'Search Service Contributor' role..."
if az role assignment create \
    --role "7ca78c08-252a-4471-8644-bb5ff32d4ba0" \
    --assignee-object-id "$principalId" \
    --assignee-principal-type User \
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Search/searchServices/$aiSearchResource"; then
    echo "  Done."
else
    echo "  Warning: assignment may already exist or failed."
fi

echo ""
echo "=== Role assignment complete ==="
