# RAG Orchestrator — Performance Analysis

## Executive Summary

Our RAG orchestrator currently takes **~17–18 seconds** to process a question-answering request. Analysis of the pipeline shows that **7 Azure OpenAI calls** are made sequentially (including a recently re-enabled groundedness check), with answer generation alone consuming 10 seconds. We've identified 6 optimizations that, combined, could reduce response times to **~3.5–5 seconds** — a 3–4x improvement:

1. **Use gpt-4o-mini** for 5 of 6 chat completion calls that perform trivial tasks (content filtering, language detection, intent classification, groundedness check, fairness check) — saving ~3.5s and ~95% cost on those calls.
2. **Parallelize independent LLM calls** that currently run sequentially — saving ~2s pre-retrieval, plus ~1s post-answer by running groundedness and fairness checks concurrently.
3. **Reduce source document volume** sent to the answer generation prompt — saving ~3–5s on the most expensive step. Also reduces groundedness check time since it receives the same sources.
4. **Merge language detection into the triage step** to eliminate a redundant LLM call — saving ~0.7s.
5. **Cache credentials, secrets, and clients** that are currently re-created on every request — saving ~0.3–0.5s.
6. **Implement semantic caching** to skip the entire pipeline for repeated/similar questions — reducing response time to ~1.5s on cache hits (estimated 30–50% of requests).

Items 1, 2, 4, and 5 are low-effort code changes. Item 3 requires testing to ensure answer quality. Item 6 is a medium-effort feature addition with the highest potential payoff. No changes to the existing Azure infrastructure are required for items 1–5.

---

## Current Pipeline Overview

Each question-answering request flows through 16 steps:

```
User Question
  │
  ├─ 1.  Load/Create Conversation (Cosmos DB)
  ├─ 2.  Initialize Kernel + Load Plugins
  ├─ 3.  Content Filter Check ──► blocked? → stop
  ├─ 4.  Blocked List Check ────► blocked? → stop
  ├─ 5.  Security Hub Check ───► (optional) blocked? → stop
  ├─ 6.  Detect Language
  ├─ 7.  Summarize Conversation History
  ├─ 8.  Triage (Intent + Query)
  │       ├─ greeting/about_bot/off_topic → direct answer → skip to 12
  │       └─ question_answering/follow_up → continue
  ├─ 9.  Vector Index Retrieval (Azure AI Search)
  ├─ 10. Bing Retrieval (optional)
  ├─ 11. Answer Generation (LLM + Sources)
  ├─ 12. Blocked List Check (Answer)
  ├─ 13. Groundedness Check ─────► ungrounded? → replace answer
  ├─ 14. Fairness Check ────────► unfair? → replace answer
  ├─ 15. Security Hub Check (Answer, optional)
  └─ 16. Save to Cosmos DB & Return Answer
```

### Step Details

**1. Conversation Setup**
Load or create the conversation context from Cosmos DB. `orchestrator.py` generates a `conversation_id` (UUID) if none is provided, then connects to Cosmos DB to retrieve the existing conversation (with its history) or create a new one. The user's question is appended to the history.

**2. Kernel & Plugin Initialization**
Set up the Semantic Kernel and load all plugins needed for downstream steps. `code_orchestration.py` calls `create_kernel()` to create a Semantic Kernel instance with an Azure OpenAI chat completion service. It then begins loading plugins in parallel via `asyncio.create_task()`: Conversation (DetectLanguage, Triage, Answer, etc.), Retrieval (vector search, Bing), Filters (content filter), and optionally Security and ResponsibleAI (Fairness).

**3. Content Filter Check (Question Guardrail)**
Detect if the user's question triggers Azure OpenAI's built-in content filters (hate, self-harm, sexual, violence). The raw question is sent to Azure OpenAI with `max_tokens=1`. It doesn't care about the response — it only checks whether the API returns an error with `content_filter` as the reason. If filtered, the answer is replaced with a canned blocked message and all subsequent steps are skipped.

**4. Blocked List Check (Question Guardrail)**
Check if the question contains any organization-defined blocked words. A blocked word list is fetched from Cosmos DB (a key-value store document with id `blocked_list`). The question is split into words and checked for exact matches. If a blocked word is found, the answer is replaced with a canned message and subsequent steps are skipped.

**5. Security Hub Check (Optional Question Guardrail)**
Run Azure AI Content Safety analysis on the question. Enabled via `SECURITY_HUB_CHECK` env var. The Security plugin's `QuestionSecurityCheck` calls the Azure AI Content Safety API. It checks category severity scores against configurable thresholds and blocklist matches. If any check fails, the question is blocked.

**6. Language Detection**
Detect the language of the user's question so all downstream outputs can respond in the same language. The DetectLanguage Semantic Kernel prompt sends the question to Azure OpenAI and asks it to return the language name (e.g., "English"). The result is stored for use by subsequent prompts.

**7. Conversation Summary**
Summarize prior conversation history to give context to the Triage and Answer steps without passing the entire history. If there is conversation history, the ConversationSummary prompt produces a concise summary. On first turn (no history), this step is skipped entirely.

**8. Triage (Intent Detection + Query Generation)**
Classify the user's intent and, for QA intents, generate an optimized search query. The Triage prompt asks Azure OpenAI to return a JSON object with `intents`, `answer`, and `query_string`. Valid intents are: `greeting`, `about_bot`, `follow_up`, `off_topic`, `question_answering`. For greetings/about_bot/off_topic, a direct answer is generated. For QA/follow-up, a search query (max 10 words) is generated for the retrieval step.

**9. Vector Index Retrieval (Search)**
Retrieve relevant source documents from Azure AI Search to ground the answer. An embedding is generated for the search query by calling the Azure OpenAI embeddings API. It then queries Azure AI Search using the configured approach — hybrid (default), vector, or term. The search includes a security filter based on the user's security IDs. Up to `AZURE_SEARCH_TOP_K` (default 8) document chunks are returned, each with filepath + content concatenated into a sources string.

**10. Bing Retrieval (Optional)**
Supplement search results with web content from Bing Custom Search. Enabled via `BING_RETRIEVAL` env var. The Bing Custom Search API is called, the top results are fetched, text is extracted from HTML pages, and each is truncated to `BING_SEARCH_MAX_TOKENS`.

**11. Answer Generation**
Generate the final answer grounded in the retrieved sources. The Answer prompt sends the bot description, user question, previous answer, conversation summary, detected language, and all retrieved sources to Azure OpenAI. The model is instructed to answer only from the provided sources, cite them with `[filepath][PageNumber]` format, and respond in the detected language. This is the most time-consuming step due to the large source context.

**12. Blocked List Check (Answer Guardrail)**
Ensure the generated answer doesn't contain any blocked words. The same word-matching check as Step 4 is performed on the generated answer text. If a blocked word is found, the answer is replaced with a canned message.

**13. Groundedness Check**
Verify the answer is grounded in the provided sources and not hallucinated. Enabled via `GROUNDEDNESS_CHECK` env var. The IsGrounded prompt sends both the generated answer and the full sources to Azure OpenAI and asks whether the answer is based on the sources (output: "yes" or "no"). If ungrounded, a second LLM call is made via the NotInSourcesAnswer prompt to generate an apology message explaining the system doesn't have enough information. Only runs for QA/follow-up intents. This is a simple binary classification task with a trivial output (one word) but a large prompt (answer + all sources).

**14. Responsible AI / Fairness Check**
Evaluate whether the answer exhibits bias, discrimination, or unfair treatment of any group. Enabled via `RESPONSIBLE_AI_CHECK` env var. The Fairness prompt sends the answer to Azure OpenAI and asks if it's fair per defined criteria. If unfair, the answer is replaced with a short refusal. Only runs for QA/follow-up intents.

**15. Security Hub Check (Optional Answer Guardrail)**
Run Azure AI Content Safety on the generated answer (same as Step 5 but on the output). Enabled via `SECURITY_HUB_CHECK`. If the answer fails, it's replaced with a blocked message. If `SECURITY_HUB_AUDIT` is enabled, violations are logged but the answer is still returned.

**16. Save Conversation & Return**
Persist the conversation and return the response. The assistant's answer is appended to the history, interaction metadata is recorded, and the conversation is written back to Cosmos DB. A JSON response with `conversation_id`, formatted `answer`, `data_points`, and `thoughts` is returned.

---

## Baseline Timing (Sample Request)

The following timings are from a representative question-answering request log:

| Step | Duration | % of Total |
|---|---|---|
| Content Filter (AOAI chat completion) | 1.09s | 7% |
| Blocked List Check | 0.16s | 1% |
| Language Detection (AOAI chat completion) | 0.77s | 5% |
| Conversation Summary | 0.00s (skipped, first turn) | 0% |
| Triage / Intent Detection (AOAI chat completion) | 2.01s | 13% |
| Vector Retrieval (embedding + AI Search) | 0.22s | 1% |
| **Answer Generation (AOAI chat completion)** | **10.18s** | **64%** |
| Groundedness Check (AOAI chat completion) | ~1.0-1.5s (est.) | 6% |
| Fairness Check (AOAI chat completion) | 1.30s | 7% |
| **Total RAG flow** | **~17-18s** | |
| Cosmos DB + overhead | ~0.24s | |
| **Total request** | **~17-18s** | |

### Azure OpenAI Calls Breakdown

7 Azure OpenAI calls are made per request (all using gpt-4o except the embedding call):

| # | Step | API | Tokens | Time |
|---|---|---|---|---|
| 1 | Content Filter | Chat Completions | 130 | 1.09s |
| 2 | Language Detection | Chat Completions | 130 | 0.77s |
| 3 | Triage (Intent) | Chat Completions | 1,231 | 2.01s |
| 4 | Embedding Generation | Embeddings | — | 0.10s |
| 5 | Answer Generation | Chat Completions | 14,154 | 10.18s |
| 6 | Groundedness Check | Chat Completions | ~14,000 (est.) | ~1.0-1.5s (est.) |
| 7 | Fairness Check | Chat Completions | 1,137 | 1.30s |

**Note:** The groundedness check (call 6) receives both `{{$sources}}` and `{{$answer}}` so its prompt token count is similar to answer generation, but it only outputs a single word ("yes"/"no") making it much faster. If the answer is found to be ungrounded, an additional NotInSourcesAnswer call is made (8th call).

---

## Optimization Recommendations

### 1. Switch lightweight calls to gpt-4o-mini ✅ IMPLEMENTED

**Impact: High (~3.5s saving) | Effort: Low-Medium | Status: Complete**

5 of 6 chat completion calls use gpt-4o for trivial tasks. gpt-4o-mini is ~60% faster and ~95% cheaper while being equally capable for these:

| Call | Task | Current | With mini |
|---|---|---|---|
| Content Filter | Send question, check for error (`max_tokens=1`) | 1.09s | ~0.5s |
| Language Detection | Return a single word (2 completion tokens) | 0.77s | ~0.3s |
| Triage | Classify intent from 5 options + short search query | 2.01s | ~1.0s |
| Groundedness | Binary yes/no classification (1 token output) | ~1.0-1.5s | ~0.5-0.7s |
| Fairness | Binary fair/not-fair classification (20 tokens) | 1.30s | ~0.6s |

Only Answer Generation (10.18s, 14K tokens, complex synthesis with citations) should stay on gpt-4o.

The groundedness check is an especially good candidate for gpt-4o-mini: despite having a large prompt (it receives all sources + the answer), it produces only a single word output ("yes" or "no"). The task is straightforward binary classification — mini models handle this reliably.

**Implementation (completed):**
- Added `AZURE_OPENAI_SMALL_CHATGPT_MODEL` and `AZURE_OPENAI_SMALL_CHATGPT_DEPLOYMENT` environment variables (with optional `AZURE_OPENAI_SMALL_RESOURCE`). If not set, falls back to the regular model with a warning logged at request time.
- A second `AzureChatCompletion` service is registered on the kernel with service ID `aoai_chat_completion_small` in `create_kernel()` (shared/util.py).
- Plugin `config.json` files for DetectLanguage, Triage, IsGrounded, NotInSourcesAnswer, ConversationSummary, and Fairness updated to use `aoai_chat_completion_small` execution settings.
- Content Filter (`native_function.py`) updated to pass small model/deployment to `chat_complete()`.
- `chat_complete()` and `get_aoai_config()` extended with optional model/deployment override parameters.
- Settings generation scripts (`generate-local-settings.sh`, `generate-local-settings.ps1`) and `local.settings.json.template` updated.

---

### 2. Parallelize independent LLM calls ✅ IMPLEMENTED

**Impact: High (~3s saving) | Effort: Low**

There are two parallelization opportunities:

**Pre-retrieval:** Content Filter runs as an early guardrail that can short-circuit the entire flow, so it must complete before any downstream work. Of the remaining pre-retrieval steps, Language Detection (0.77s) and Conversation Summary (~0.5s) are independent of each other, while Triage (2.01s) depends on `conversation_summary`. Running Language Detection and Conversation Summary concurrently via `asyncio.gather()` removes their overlap, so Triage can start sooner.

**Post-answer:** The Groundedness Check (~1.0-1.5s) and Fairness Check (1.30s) both operate on the generated answer and are independent of each other. They currently run sequentially. Running them concurrently with `asyncio.gather()` reduces their combined ~2.3-2.8s to ~1.3s (the slowest one), saving ~1s.

**Implementation details:**
- **Pre-retrieval:** Language Detection has been merged into Triage (see optimization #4), so pre-retrieval parallelization is no longer applicable. The flow is now: ConversationSummary → Triage.
- **Post-answer:** When both GROUNDEDNESS_CHECK and RESPONSIBLE_AI_CHECK are enabled, IsGrounded and Fairness checks run concurrently via `asyncio.gather()`. After both complete, groundedness result is processed first — if ungrounded, `bypass_nxt_steps` is set and the fairness result is discarded. If grounded, the fairness result is applied. When only one check is enabled, it runs sequentially as before.
- Changes in `code_orchestration.py`.

---

### 3. Reduce source document volume for Answer Generation

**Impact: High (~3-5s saving) | Effort: Medium**

Answer Generation dominates at 10.18s with 13,308 prompt tokens. This is driven almost entirely by the `{{$sources}}` variable — the Answer prompt template does not reference `{{$history}}` (the history assignment before this call is effectively dead code). Two levers:

- **Reduce `AZURE_SEARCH_TOP_K`** from 8 to 4-5. Hybrid search already ranks well; the bottom results often add noise not signal.
- **Truncate individual chunks** — currently full content is concatenated as-is. Capping each chunk (e.g., 500 tokens) would substantially reduce prompt size.

Halving the source tokens could reduce this step from ~10s to ~5-7s. Requires testing to verify answer quality is maintained.

**Bonus impact on Groundedness Check:** The IsGrounded prompt also receives `{{$sources}}` (the full sources). Reducing source volume therefore also reduces the groundedness check prompt size and its latency.

---

### 4. Merge Language Detection into Triage ✅ IMPLEMENTED

**Impact: Medium (~0.7s saving) | Effort: Low**

The Triage prompt already instructs the model to "generate ANSWER and QUERY_STRING in the same language as the ASK" and outputs a `language` field in its JSON response. The separate DetectLanguage call (0.77s, 130 tokens) is redundant. Extracting the language from the Triage response eliminates one LLM round-trip entirely — reducing 6 calls to 5.

**Implementation details:**
- The Triage wrapper (`wrapper.py`) now extracts the `language` field from the Triage JSON response.
- The DetectLanguage LLM call has been removed from the orchestration flow.
- `arguments["language"]` is set to `"the same language as the ASK"` as a default before Triage runs (so `{{$language}}` in the prompt has a sensible value), then overridden with the language detected by Triage.
- The pre-retrieval flow is now: ConversationSummary → Triage (which includes language detection).
- Dead code (`triage_language` variable) removed.
- Changes in `code_orchestration.py` and `Triage/wrapper.py`.

---

### 5. Cache credentials, secrets, and clients ✅ IMPLEMENTED

**Impact: Low-Medium (~0.3-0.5s saving, compounds over calls) | Effort: Low**

- **`ChainedTokenCredential`** is created fresh in `get_aoai_config()`, `get_secret()`, `VectorIndexRetrieval()`, and `orchestrator.py`. Each creation + token fetch incurs overhead. Cache at request or app scope.
- **`get_secret()`** creates a new Key Vault client per call. Secrets like `apimSubscriptionKey` don't change — cache for the function app lifetime.
- **Embedding client** creates a new synchronous `AzureOpenAI` client on every call. Reuse it.

**Implementation details:**
- Added `get_credential()` in `shared/util.py` — returns a shared `ChainedTokenCredential` instance (created once, reused for app lifetime).
- Added `_secret_cache` dict in `shared/util.py` — `get_secret()` now caches returned values, skipping Key Vault calls on subsequent requests for the same secret.
- Added `_embedding_client` cache in `Retrieval/native_function.py` — the `AzureOpenAI` embedding client is reused across calls instead of being created fresh each time.
- Updated `get_aoai_config()`, `get_next_resource()`, `get_blocked_list()` in `shared/util.py` to use `get_credential()`.
- Updated `orchestrator.py` to use `get_credential()` instead of creating a new `ChainedTokenCredential`.
- Updated `VectorIndexRetrieval()` in `Retrieval/native_function.py` to use `get_credential()`.
- Changes in `shared/util.py`, `orc/orchestrator.py`, and `orc/plugins/Retrieval/native_function.py`.

---

### 6. Semantic Caching of Requests and Responses

**Impact: Very High on cache hits (skip ~14.5s) | Effort: Medium**

Instead of exact-match caching, generate an embedding of the incoming question and compare it against embeddings of previously-asked questions. If the cosine similarity exceeds a threshold (e.g., 0.95), return the cached answer instead of running the full pipeline. "What are tenant rights?" and "What rights do tenants have?" would produce a cache hit.

#### Where It Fits in the Pipeline

The cache check goes **after** the question guardrails (steps 3-5) but **before** everything else (steps 6-11). Harmful/filtered questions are still blocked, but safe questions that are semantically similar to previous ones skip all 5 remaining LLM calls.

```
User Question
  ├─ 3.  Content Filter Check
  ├─ 4.  Blocked List Check
  ├─ 5.  Security Hub Check (optional)
  ├─ NEW: Semantic Cache Lookup  ──► hit? → return cached answer → step 16
  ├─ 6.  Detect Language
  ├─ 7.  Conversation Summary
  ...continues as normal on cache miss (including Groundedness Check)
```

#### Performance Impact

- **Cache hit** (~30-50% of requests): ~1.5s total (one embedding call + vector similarity search). Cached answers have already passed the groundedness and fairness checks, so those are also skipped.
- **Cache miss**: ~0.15s overhead, but the embedding can be **reused** for the retrieval step (step 9), making the net cost effectively zero

#### Design Considerations

**Security-aware cache keys:** The system has per-user security filtering on search results (`security_ids`). Two users asking the same question may get different source documents and therefore different answers. The cache key must include `security_ids`.

**Conversation context:** Semantic caching works best for first-turn questions (no conversation history). For follow-up questions, the same words could mean different things depending on context. Recommended approach: only cache first-turn questions (where `history == []`).

**Cache storage options:**

| Store | Pros | Cons |
|---|---|---|
| Cosmos DB (with vector indexing) | Already in use; single data store | Need to enable vector search on the container |
| Azure AI Search | Already has vector search infra | Separate service; another index to manage |
| Azure Cache for Redis (with vector search) | Purpose-built for caching; TTL support; very fast | Additional service to provision |

Cosmos DB is the lowest-friction option since it's already in use and supports vector search with DiskANN indexing.

**Cache invalidation:** When source documents change in Azure AI Search, cached answers become stale. Options:
- **TTL-based** (recommended start): Set a cache expiry (e.g., 24 hours). Simple, but stale during the window.
- **Event-driven**: Clear the cache when the search index is updated. More complex but accurate.
- **Hybrid**: TTL of a few hours, with manual invalidation on known document updates.

#### Implementation Sketch

```python
# After guardrails, before language detection:

# 1. Generate embedding for the question (reuse for retrieval later)
question_embedding = await generate_embeddings(ask, apim_key=apim_key)

# 2. Check semantic cache (first-turn only)
if arguments["history"] == '[]':
    cached = await check_semantic_cache(question_embedding, security_ids)
    if cached and cached['similarity'] >= CACHE_SIMILARITY_THRESHOLD:
        logging.info(f"[code_orchest] cache hit (similarity: {cached['similarity']})")
        answer = cached['answer']
        answer_generated_by = "semantic_cache"
        sources = cached['sources']
        bypass_nxt_steps = True

# ... rest of pipeline runs on cache miss ...

# After answer generation, save to cache:
if answer_generated_by == "conversation_plugin_answer":
    await save_to_semantic_cache(question_embedding, ask, answer, sources, security_ids)
```

#### Interaction with Other Optimizations

| Optimization | Interaction with Semantic Cache |
|---|---|
| 1. gpt-4o-mini | Still valuable — cache misses still run the full pipeline |
| 2. Parallelize calls | Still valuable for cache misses; skipped entirely on hits |
| 3. Reduce source docs | Still valuable for cache misses; cached answers have sources baked in |
| 4. Merge Language Detection + Triage | Still valuable for cache misses; cache hits skip both |
| 5. Cache credentials | More important — the embedding call for cache lookup needs credentials |

Semantic caching complements all other optimizations. The other 5 improve cache-miss performance; semantic caching eliminates the pipeline entirely on hits.

#### Risks

- **Stale answers**: If source documents are updated frequently, cached answers may be outdated. TTL tuning is important.
- **Similarity threshold tuning**: Too low (e.g., 0.85) → wrong cached answers returned. Too high (e.g., 0.99) → low hit rate. Start at 0.95 and tune based on logs.
- **Follow-up questions**: Not cacheable without conversation context, limiting hit rate for multi-turn conversations.
- **Cost**: Adds one embedding call per request (~$0.00001), negligible compared to the 5 LLM calls it can skip.

---

## Combined Impact Summary

| # | Optimization | Time Saved | Effort | LLM Calls |
|---|---|---|---|---|
| 1 | Use gpt-4o-mini for 5 lightweight calls | ~3.5s | Low-Medium | 7 → 7 (faster) |
| 2 | Parallelize calls (pre-retrieval + post-answer) | ~3.0s | Low | Same |
| 3 | Reduce source docs (fewer/smaller chunks) | ~3-5s | Medium | Same |
| 4 | Merge Language Detection into Triage | ~0.7s | Low | 7 → 6 |
| 5 | Cache credentials, secrets, clients | ~0.3-0.5s | Low | Same |
| 6 | Semantic caching | ~16s on hit | Medium | 7 → 0 on hit |
| | **Total potential saving** | **~10-12s (miss) / ~16s (hit)** | | **7 → 6 (miss) / 0 (hit)** |

### Projected Response Times

| Scenario | Current | Optimized |
|---|---|---|
| Cache hit (~30-50% of requests) | ~17-18s | **~1.5s** |
| Cache miss (all other optimizations) | ~17-18s | **~6-8s** |
| Weighted average (40% hit rate) | ~17-18s | **~3.5-5s** |

### Recommended Implementation Order

1. **Phase 1 (Low effort):** Items 2, 4, 5 — parallelize calls (including groundedness + fairness in parallel), merge language detection, cache credentials
2. **Phase 2 (Low-Medium effort):** Item 1 — deploy gpt-4o-mini and configure plugin routing (including IsGrounded and NotInSourcesAnswer)
3. **Phase 3 (Medium effort):** Items 3, 6 — reduce source volume (with quality testing, also benefits groundedness check prompt size) and implement semantic caching
