import logging
import asyncio
import time
import os
import json
import azure.functions as func
import aiohttp
from azure.cosmos.aio import CosmosClient
from azure.identity.aio import ManagedIdentityCredential, AzureCliCredential, ChainedTokenCredential

LOGLEVEL = os.environ.get('LOGLEVEL', 'DEBUG').upper()
logging.basicConfig(level=LOGLEVEL)

# ── Environment variables ────────────────────────────────────────────

AZURE_DB_ID = os.environ.get("AZURE_DB_ID")
AZURE_DB_NAME = os.environ.get("AZURE_DB_NAME")
AZURE_DB_URI = f"https://{AZURE_DB_ID}.documents.azure.com:443/" if AZURE_DB_ID else None

AZURE_OPENAI_RESOURCE = os.environ.get("AZURE_OPENAI_RESOURCE")
AZURE_OPENAI_CHATGPT_DEPLOYMENT = os.environ.get("AZURE_OPENAI_CHATGPT_DEPLOYMENT") or "chat"
AZURE_OPENAI_APIVERSION = os.environ.get("AZURE_OPENAI_APIVERSION") or "2024-05-01-preview"

AZURE_SEARCH_SERVICE = os.environ.get("AZURE_SEARCH_SERVICE")
AZURE_SEARCH_INDEX = os.environ.get("AZURE_SEARCH_INDEX") or "ragindex"
AZURE_SEARCH_API_VERSION = os.environ.get("AZURE_SEARCH_API_VERSION") or "2024-07-01"

# ── Credential helper ────────────────────────────────────────────────

_cached_credential = None

def _get_credential():
    global _cached_credential
    if _cached_credential is None:
        _cached_credential = ChainedTokenCredential(
            ManagedIdentityCredential(), AzureCliCredential()
        )
    return _cached_credential

# ── Individual health checks ─────────────────────────────────────────

async def _check_cosmos_db():
    """Verify connectivity to Cosmos DB by reading the database."""
    credential = _get_credential()
    async with CosmosClient(AZURE_DB_URI, credential=credential) as client:
        db = client.get_database_client(database=AZURE_DB_NAME)
        await db.read()


async def _check_openai():
    """Verify connectivity to Azure OpenAI by sending a lightweight chat completion."""
    credential = _get_credential()
    resource = AZURE_OPENAI_RESOURCE
    if resource and "," in resource:
        resource = resource.split(",")[0].strip()
    token = await credential.get_token("https://cognitiveservices.azure.com/.default")
    url = (
        f"https://{resource}.openai.azure.com/openai/deployments"
        f"/{AZURE_OPENAI_CHATGPT_DEPLOYMENT}/chat/completions"
        f"?api-version={AZURE_OPENAI_APIVERSION}"
    )
    headers = {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json",
    }
    body = {
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 5,
    }
    async with aiohttp.ClientSession() as session:
        async with session.post(url, headers=headers, json=body) as resp:
            if resp.status >= 400:
                text = await resp.text()
                raise Exception(f"OpenAI returned {resp.status}: {text}")


async def _check_ai_search():
    """Verify connectivity to Azure AI Search by performing a simple query."""
    credential = _get_credential()
    token = await credential.get_token("https://search.azure.com/.default")
    url = (
        f"https://{AZURE_SEARCH_SERVICE}.search.windows.net"
        f"/indexes/{AZURE_SEARCH_INDEX}/docs/search"
        f"?api-version={AZURE_SEARCH_API_VERSION}"
    )
    headers = {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json",
    }
    body = {"search": "*", "top": 1, "select": "title"}
    async with aiohttp.ClientSession() as session:
        async with session.post(url, headers=headers, json=body) as resp:
            if resp.status >= 400:
                text = await resp.text()
                raise Exception(f"AI Search returned {resp.status}: {text}")


# ── Run a single check, capturing timing and errors ──────────────────

async def _run_check(name, check_fn):
    start = time.monotonic()
    try:
        await check_fn()
        elapsed = round(time.monotonic() - start, 3)
        return {"name": name, "status": "passed", "elapsedTime": f"{elapsed}s"}
    except Exception as e:
        elapsed = round(time.monotonic() - start, 3)
        logging.error(f"[health] {name} check failed: {e}")
        return {"name": name, "status": "failed", "elapsedTime": f"{elapsed}s", "error": str(e)}


# ── Settings report ──────────────────────────────────────────────────

def _get_settings():
    def _val(name):
        return os.environ.get(name) or ""

    return [
        {
            "group": "General",
            "settings": [
                {"name": "ORCHESTRATOR_MESSAGES_LANGUAGE", "value": _val("ORCHESTRATOR_MESSAGES_LANGUAGE"), "description": "Language code for orchestrator system messages"},
                {"name": "CONVERSATION_MAX_HISTORY", "value": _val("CONVERSATION_MAX_HISTORY"), "description": "Maximum number of conversation turns retained in history"},
                {"name": "BLOCKED_LIST_CHECK", "value": _val("BLOCKED_LIST_CHECK"), "description": "Enable blocked word list validation"},
                {"name": "GROUNDEDNESS_CHECK", "value": _val("GROUNDEDNESS_CHECK"), "description": "Enable answer groundedness verification"},
                {"name": "RESPONSIBLE_AI_CHECK", "value": _val("RESPONSIBLE_AI_CHECK"), "description": "Enable responsible AI content checks"},
                {"name": "SECURITY_HUB_CHECK", "value": _val("SECURITY_HUB_CHECK"), "description": "Enable Security Hub question/answer checks"},
                {"name": "SECURITY_HUB_AUDIT", "value": _val("SECURITY_HUB_AUDIT"), "description": "Enable Security Hub audit logging"},
            ],
        },
        {
            "group": "Azure OpenAI",
            "settings": [
                {"name": "AZURE_OPENAI_RESOURCE", "value": _val("AZURE_OPENAI_RESOURCE"), "description": "Azure OpenAI resource name(s)"},
                {"name": "AZURE_OPENAI_CHATGPT_DEPLOYMENT", "value": _val("AZURE_OPENAI_CHATGPT_DEPLOYMENT"), "description": "Chat model deployment name"},
                {"name": "AZURE_OPENAI_CHATGPT_MODEL", "value": _val("AZURE_OPENAI_CHATGPT_MODEL"), "description": "Chat model name (e.g. gpt-4o)"},
                {"name": "AZURE_OPENAI_SMALL_RESOURCE", "value": _val("AZURE_OPENAI_SMALL_RESOURCE"), "description": "Optional OpenAI resource for small model (falls back to AZURE_OPENAI_RESOURCE)"},
                {"name": "AZURE_OPENAI_SMALL_CHATGPT_MODEL", "value": _val("AZURE_OPENAI_SMALL_CHATGPT_MODEL"), "description": "Optional small chat model (falls back to AZURE_OPENAI_CHATGPT_MODEL)"},
                {"name": "AZURE_OPENAI_SMALL_CHATGPT_DEPLOYMENT", "value": _val("AZURE_OPENAI_SMALL_CHATGPT_DEPLOYMENT"), "description": "Optional small model deployment (falls back to AZURE_OPENAI_SMALL_CHATGPT_MODEL)"},
                {"name": "AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "value": _val("AZURE_OPENAI_EMBEDDING_DEPLOYMENT"), "description": "Embedding model deployment name"},
                {"name": "AZURE_OPENAI_EMBEDDING_APIVERSION", "value": _val("AZURE_OPENAI_EMBEDDING_APIVERSION"), "description": "API version for embedding calls"},
                {"name": "AZURE_OPENAI_TEMPERATURE", "value": _val("AZURE_OPENAI_TEMPERATURE"), "description": "Sampling temperature for chat completions"},
                {"name": "AZURE_OPENAI_TOP_P", "value": _val("AZURE_OPENAI_TOP_P"), "description": "Top-p (nucleus) sampling parameter"},
                {"name": "AZURE_OPENAI_MAX_TOKENS", "value": _val("AZURE_OPENAI_MAX_TOKENS"), "description": "Maximum tokens in chat completion response"},
                {"name": "AZURE_OPENAI_APIVERSION", "value": _val("AZURE_OPENAI_APIVERSION"), "description": "API version for chat completion calls"},
            ],
        },
        {
            "group": "Azure Search",
            "settings": [
                {"name": "AZURE_SEARCH_SERVICE", "value": _val("AZURE_SEARCH_SERVICE"), "description": "Azure AI Search service name"},
                {"name": "AZURE_SEARCH_INDEX", "value": _val("AZURE_SEARCH_INDEX"), "description": "Search index name"},
                {"name": "AZURE_SEARCH_API_VERSION", "value": _val("AZURE_SEARCH_API_VERSION"), "description": "Search REST API version"},
                {"name": "AZURE_SEARCH_APPROACH", "value": _val("AZURE_SEARCH_APPROACH"), "description": "Search approach: hybrid, vector, or term"},
                {"name": "AZURE_SEARCH_USE_SEMANTIC", "value": _val("AZURE_SEARCH_USE_SEMANTIC"), "description": "Enable semantic ranking on search queries"},
                {"name": "AZURE_SEARCH_SEMANTIC_SEARCH_CONFIG", "value": _val("AZURE_SEARCH_SEMANTIC_SEARCH_CONFIG"), "description": "Semantic search configuration name"},
                {"name": "AZURE_SEARCH_TOP_K", "value": _val("AZURE_SEARCH_TOP_K"), "description": "Number of top search results to retrieve"},
                {"name": "AZURE_SEARCH_MIN_RERANKER_SCORE", "value": _val("AZURE_SEARCH_MIN_RERANKER_SCORE"), "description": "Minimum semantic reranker score threshold (0-4)"},
                {"name": "AZURE_SEARCH_MIN_SEARCH_SCORE", "value": _val("AZURE_SEARCH_MIN_SEARCH_SCORE"), "description": "Minimum search score threshold when semantic ranking is off"},
            ],
        },
        {
            "group": "Cosmos DB",
            "settings": [
                {"name": "AZURE_DB_ID", "value": _val("AZURE_DB_ID"), "description": "Cosmos DB account name"},
                {"name": "AZURE_DB_NAME", "value": _val("AZURE_DB_NAME"), "description": "Cosmos DB database name"},
            ],
        },
        {
            "group": "Key Vault",
            "settings": [
                {"name": "AZURE_KEY_VAULT_NAME", "value": _val("AZURE_KEY_VAULT_NAME"), "description": "Azure Key Vault instance used for secret management"},
            ],
        },
    ]


# ── Azure Function entry point ───────────────────────────────────────

async def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("[health] Health check request received.")

    checks = [
        ("Database Connection", _check_cosmos_db),
        ("OpenAI Service", _check_openai),
        ("AI Search Service", _check_ai_search),
    ]

    results = await asyncio.gather(
        *[_run_check(name, fn) for name, fn in checks]
    )

    all_passed = all(r["status"] == "passed" for r in results)

    response = {
        "overallStatus": "healthy" if all_passed else "unhealthy",
        "healthChecks": list(results),
        "settings": _get_settings(),
    }

    status_code = 200 if all_passed else 503
    return func.HttpResponse(
        json.dumps(response, indent=2),
        mimetype="application/json",
        status_code=status_code,
    )
