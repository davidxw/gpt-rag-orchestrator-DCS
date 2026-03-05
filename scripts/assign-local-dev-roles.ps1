# Usage: .\assign-local-dev-roles.ps1 [-ResourceGroupName <name>]

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName
)

Write-Host "=== Assign Local Development Roles ==="
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsFile = Join-Path $scriptDir "..\local.settings.json"

# Get the principal ID of the currently logged-in user
Write-Host "Retrieving logged-in Azure CLI user..."
$principalId = az ad signed-in-user show --query id -o tsv
$userName = az ad signed-in-user show --query userPrincipalName -o tsv
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get signed-in user. Ensure you are logged in via 'az login'."
    exit 1
}
Write-Host "User: $userName"
Write-Host "Principal ID: $principalId"
Write-Host ""

# Get subscription ID
$subscriptionId = az account show --query id -o tsv
Write-Host "Subscription: $subscriptionId"
Write-Host ""

# Try to read resource names from local.settings.json
$cosmosDbAccountName = ""
$openAIAccountName = ""
$aiSearchResource = ""

if (Test-Path $settingsFile) {
    Write-Host "Reading resource names from local.settings.json..."
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
    $cosmosDbAccountName = $settings.Values.AZURE_DB_ID
    $openAIAccountName = $settings.Values.AZURE_OPENAI_RESOURCE
    $aiSearchResource = $settings.Values.AZURE_SEARCH_SERVICE
} else {
    Write-Host "local.settings.json not found."
}

# Prompt for any missing values
if ([string]::IsNullOrWhiteSpace($cosmosDbAccountName)) {
    $cosmosDbAccountName = Read-Host "Enter Cosmos DB account name"
}

if ([string]::IsNullOrWhiteSpace($openAIAccountName)) {
    $openAIAccountName = Read-Host "Enter Azure OpenAI resource name"
}

if ([string]::IsNullOrWhiteSpace($aiSearchResource)) {
    $aiSearchResource = Read-Host "Enter Azure AI Search service name"
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $resourceGroupName = Read-Host "Enter resource group name"
} else {
    $resourceGroupName = $ResourceGroupName
}

Write-Host ""
Write-Host "--- Configuration ---"
Write-Host "Cosmos DB Account:    $cosmosDbAccountName"
Write-Host "OpenAI Resource:      $openAIAccountName"
Write-Host "AI Search Service:    $aiSearchResource"
Write-Host "Resource Group:       $resourceGroupName"
Write-Host "Subscription:         $subscriptionId"
Write-Host "Principal ID:         $principalId"
Write-Host "---------------------"
Write-Host ""

# 1. Cosmos DB Built-in Data Contributor
Write-Host "[1/4] Assigning Cosmos DB 'Built-in Data Contributor' role..."
$roleDefinitionId = "00000000-0000-0000-0000-000000000002"
az cosmosdb sql role assignment create `
    --account-name $cosmosDbAccountName `
    --resource-group $resourceGroupName `
    --scope "/" `
    --principal-id $principalId `
    --role-definition-id $roleDefinitionId
if ($LASTEXITCODE -eq 0) { Write-Host "  Done." } else { Write-Host "  Warning: assignment may already exist or failed." }

# 2. Cognitive Services OpenAI User (5e0bd9bd-7b93-4f28-af87-19fc36ad61bd)
Write-Host "[2/4] Assigning 'Cognitive Services OpenAI User' role..."
az role assignment create `
    --role "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd" `
    --assignee $principalId `
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.CognitiveServices/accounts/$openAIAccountName"
if ($LASTEXITCODE -eq 0) { Write-Host "  Done." } else { Write-Host "  Warning: assignment may already exist or failed." }

# 3. Search Index Data Contributor (8bbe4f35-0d35-4acf-957f-681a119e2e91)
Write-Host "[3/4] Assigning 'Search Index Data Contributor' role..."
az role assignment create `
    --role "8bbe4f35-0d35-4acf-957f-681a119e2e91" `
    --assignee $principalId `
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Search/searchServices/$aiSearchResource"
if ($LASTEXITCODE -eq 0) { Write-Host "  Done." } else { Write-Host "  Warning: assignment may already exist or failed." }

# 4. Search Service Contributor (7ca78c08-252a-4471-8644-bb5ff32d4ba0)
Write-Host "[4/4] Assigning 'Search Service Contributor' role..."
az role assignment create `
    --role "7ca78c08-252a-4471-8644-bb5ff32d4ba0" `
    --assignee $principalId `
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Search/searchServices/$aiSearchResource"
if ($LASTEXITCODE -eq 0) { Write-Host "  Done." } else { Write-Host "  Warning: assignment may already exist or failed." }

Write-Host ""
Write-Host "=== Role assignment complete ==="
