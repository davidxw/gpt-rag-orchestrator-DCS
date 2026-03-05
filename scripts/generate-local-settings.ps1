# Generate local.settings.json from an .env file
# Usage: .\generate-local-settings.ps1 -EnvFile <path-to-env-file> [-OutputFile <output-path>]

param(
    [Parameter(Mandatory = $true)]
    [string]$EnvFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $OutputFile) {
    $OutputFile = Join-Path $scriptDir "..\local.settings.json"
}

if (-not (Test-Path $EnvFile)) {
    Write-Error "Error: .env file not found: $EnvFile"
    exit 1
}

# Parse .env file
$envVars = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    # Skip empty lines and comments
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    # Match KEY=VALUE or KEY="VALUE"
    if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $key = $Matches[1]
        $value = $Matches[2].Trim('"')
        $value = $value.Replace('\"', '"')
        $envVars[$key] = $value
    }
}

Write-Host "Read $($envVars.Count) variables from $EnvFile"

# --- Map .env variables to local.settings.json values ---

function Get-EnvValue($primary, $fallback, $default) {
    if ($envVars.ContainsKey($primary) -and $envVars[$primary]) { return $envVars[$primary] }
    if ($fallback -and $envVars.ContainsKey($fallback) -and $envVars[$fallback]) { return $envVars[$fallback] }
    return $default
}

$azureKeyVaultName = Get-EnvValue "AZURE_KEY_VAULT_NAME" "AZURE_KV_NAME" ""
$azureSearchService = Get-EnvValue "AZURE_SEARCH_SERVICE_NAME" $null ""
$azureSearchIndex = Get-EnvValue "AZURE_SEARCH_INDEX" $null "ragindex"
$azureSearchApproach = Get-EnvValue "AZURE_RETRIEVAL_APPROACH" $null "hybrid"
$azureSearchUseSemantic = Get-EnvValue "AZURE_USE_SEMANTIC_RERANKING" $null "false"
$azureOpenAIResource = Get-EnvValue "AZURE_OPENAI_SERVICE_NAME" $null ""
$azureOpenAIChatDeployment = Get-EnvValue "AZURE_CHAT_GPT_DEPLOYMENT_NAME" $null "chat"
$azureOpenAIChatModel = Get-EnvValue "AZURE_CHAT_GPT_MODEL_NAME" $null ""
$azureOpenAIEmbeddingDeployment = Get-EnvValue "AZURE_EMBEDDINGS_DEPLOYMENT_NAME" $null "text-embedding"
$orchestratorMessagesLanguage = Get-EnvValue "AZURE_ORCHESTRATOR_MESSAGES_LANGUAGE" $null "en"

# Try to extract Cosmos DB info from AZURE_DB_CONFIG JSON
$azureDbId = ""
$azureDbName = ""
if ($envVars.ContainsKey("AZURE_DB_CONFIG") -and $envVars["AZURE_DB_CONFIG"]) {
    try {
        $dbConfig = $envVars["AZURE_DB_CONFIG"] | ConvertFrom-Json
        if ($dbConfig.dbAccountName) { $azureDbId = $dbConfig.dbAccountName }
        if ($dbConfig.dbDatabaseName) { $azureDbName = $dbConfig.dbDatabaseName }
    } catch {
        Write-Host "Warning: Could not parse AZURE_DB_CONFIG as JSON."
    }
}

# Warn about empty Cosmos DB values
if (-not $azureDbId -or -not $azureDbName) {
    Write-Host ""
    Write-Host "WARNING: AZURE_DB_ID and/or AZURE_DB_NAME could not be determined from the .env file."
    Write-Host "  The .env variable AZURE_DB_CONFIG has empty dbAccountName/dbDatabaseName fields."
    Write-Host "  You will need to set these manually in $OutputFile"
    Write-Host ""
}

# Build the settings object
$settings = [ordered]@{
    IsEncrypted = $false
    Values = [ordered]@{
        FUNCTIONS_WORKER_RUNTIME = "python"
        AzureWebJobsStorage = "UseDevelopmentStorage=true"
        LOCAL_ENV = "true"

        AZURE_KEY_VAULT_NAME = $azureKeyVaultName

        AZURE_DB_ID = $azureDbId
        AZURE_DB_NAME = $azureDbName

        AZURE_SEARCH_SERVICE = $azureSearchService
        AZURE_SEARCH_INDEX = $azureSearchIndex
        AZURE_SEARCH_API_VERSION = "2024-07-01"
        AZURE_SEARCH_APPROACH = $azureSearchApproach
        AZURE_SEARCH_USE_SEMANTIC = $azureSearchUseSemantic
        AZURE_SEARCH_TOP_K = "3"

        AZURE_OPENAI_RESOURCE = $azureOpenAIResource
        AZURE_OPENAI_CHATGPT_DEPLOYMENT = $azureOpenAIChatDeployment
        AZURE_OPENAI_CHATGPT_MODEL = $azureOpenAIChatModel
        AZURE_OPENAI_EMBEDDING_DEPLOYMENT = $azureOpenAIEmbeddingDeployment
        AZURE_OPENAI_EMBEDDING_APIVERSION = "2024-05-01-preview"
        AZURE_OPENAI_CHATGPT_MONITORING_DEPLOYMENT = "chat"
        AZURE_OPENAI_CHATGPT_LLM_MONITORING = "true"
        AZURE_OPENAI_STREAM = "false"
        AZURE_OPENAI_LOAD_BALANCING = "true"

        AZURE_OPENAI_TEMPERATURE = "0.1"
        AZURE_OPENAI_TOP_P = "0.27"
        AZURE_OPENAI_MAX_TOKENS = "1000"
        AZURE_OPENAI_APIVERSION = "2024-05-01-preview"

        BING_SEARCH_TOP_K = "3"
        BING_SEARCH_MAX_TOKENS = "1000"

        ORCHESTRATOR_MESSAGES_LANGUAGE = $orchestratorMessagesLanguage
        CONVERSATION_MAX_HISTORY = "3"

        BLOCKED_LIST_CHECK = "true"
        GROUNDEDNESS_CHECK = "true"
        RESPONSIBLE_AI_CHECK = "true"
        SECURITY_HUB_CHECK = "false"
        SECURITY_HUB_AUDIT = "false"

        SECURITY_HUB_ENDPOINT = ""
        CONVERSATION_METADATA = "true"

        BING_RETRIEVAL = "false"
        SEARCH_RETRIEVAL = "true"
        RETRIEVAL_PRIORITY = "search"
        DB_RETRIEVAL = "false"
        DB_SERVER = ""
        DB_DATABASE = ""
        DB_USERNAME = ""
        DB_TOP_K = "3"
        DB_MAX_TOKENS = "1000"
        SECURITY_HUB_HATE_THRESHHOLD = "0"
        SECURITY_HUB_SELFHARM_THRESHHOLD = "0"
        SECURITY_HUB_SEXUAL_THRESHHOLD = "0"
        SECURITY_HUB_VIOLENCE_THRESHHOLD = "0"
        SECURITY_HUB_UNGROUNDED_PERCENTAGE_THRESHHOLD = "0.1"
        APIM_ENABLED = "false"
        APIM_AZURE_OPENAI_ENDPOINT = ""
        APIM_BING_CUSTOM_SEARCH_URL = ""
        APIM_AZURE_SEARCH_URL = ""
        APIM_SECURITY_HUB_ENDPOINT = ""
    }
}

$settings | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "Generated: $OutputFile"
Write-Host ""
Write-Host "--- Mapped values from .env ---"
Write-Host "AZURE_KEY_VAULT_NAME:              $azureKeyVaultName"
Write-Host "AZURE_DB_ID:                       $(if ($azureDbId) { $azureDbId } else { '(empty - set manually)' })"
Write-Host "AZURE_DB_NAME:                     $(if ($azureDbName) { $azureDbName } else { '(empty - set manually)' })"
Write-Host "AZURE_SEARCH_SERVICE:              $azureSearchService"
Write-Host "AZURE_SEARCH_INDEX:                $azureSearchIndex"
Write-Host "AZURE_SEARCH_APPROACH:             $azureSearchApproach"
Write-Host "AZURE_SEARCH_USE_SEMANTIC:         $azureSearchUseSemantic"
Write-Host "AZURE_OPENAI_RESOURCE:             $azureOpenAIResource"
Write-Host "AZURE_OPENAI_CHATGPT_DEPLOYMENT:   $azureOpenAIChatDeployment"
Write-Host "AZURE_OPENAI_CHATGPT_MODEL:        $azureOpenAIChatModel"
Write-Host "AZURE_OPENAI_EMBEDDING_DEPLOYMENT: $azureOpenAIEmbeddingDeployment"
Write-Host "ORCHESTRATOR_MESSAGES_LANGUAGE:     $orchestratorMessagesLanguage"
Write-Host "-------------------------------"
