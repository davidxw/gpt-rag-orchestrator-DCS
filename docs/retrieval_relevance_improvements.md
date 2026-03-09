# Retrieval Relevance Improvements

## Current Flow

1. **Triage** generates a search query (capped at 25 words)
2. **VectorIndexRetrieval** embeds the query, searches Azure AI Search (hybrid by default, semantic ranking on by default), returns top K (default 8) chunks
3. Chunks below the minimum relevance score threshold are dropped
4. If no relevant chunks remain, the system short-circuits to a "not enough information" response
5. Remaining chunks are structured with numbering/metadata and passed to the **Answer** prompt
6. **IsGrounded** checks if the answer is based on the sources

---

## Issues and Recommendations

### 1. No Relevance Score Filtering (Critical) — IMPLEMENTED

**Problem:** In `orc/plugins/Retrieval/native_function.py`, every document in the top K was blindly appended regardless of its relevance score.

**Implemented solution:** Added two separate minimum score environment variables, one for each ranking mode:

- `AZURE_SEARCH_MIN_RERANKER_SCORE` — used when semantic ranking is ON (`@search.rerankerScore`, 0–4 scale, default `1.0`)
- `AZURE_SEARCH_MIN_SEARCH_SCORE` — used when semantic ranking is OFF (`@search.score`, scale varies by approach, default `0.0`)

At runtime, the correct score field and threshold are selected based on whether semantic ranking is active. Documents below the threshold are dropped with detailed logging showing the filepath, score, and threshold.

```python
# Min score when semantic ranking is ON (uses @search.rerankerScore, 0-4 scale)
AZURE_SEARCH_MIN_RERANKER_SCORE = float(os.environ.get("AZURE_SEARCH_MIN_RERANKER_SCORE", "1.0"))
# Min score when semantic ranking is OFF (uses @search.score, scale varies by search approach):
#   - hybrid (RRF fusion): typically 0.01-0.05, try 0.01-0.03
#   - vector (cosine similarity): typically 0.5-1.0, try 0.7-0.8
#   - term (BM25): typically 1.0-20.0+, try 2.0-5.0
AZURE_SEARCH_MIN_SEARCH_SCORE = float(os.environ.get("AZURE_SEARCH_MIN_SEARCH_SCORE", "0.0"))
```

**Files changed:** `orc/plugins/Retrieval/native_function.py`, `local.settings.json.template`

---

### 2. Semantic Ranking Disabled by Default (Critical) — IMPLEMENTED

**Problem:** `AZURE_SEARCH_USE_SEMANTIC` defaulted to `"false"`. Semantic ranking reorders results using a deep-learning model and dramatically improves relevance for natural-language queries.

**Implemented solution:** Changed the default to `"true"` in the code and in the settings template:

```python
AZURE_SEARCH_USE_SEMANTIC = os.environ.get("AZURE_SEARCH_USE_SEMANTIC") or "true"
```

**Note:** This requires a semantic configuration to be provisioned on the Azure AI Search index — see the Prerequisites section below.

**Files changed:** `orc/plugins/Retrieval/native_function.py`, `local.settings.json.template`

---

### 3. Search Query Too Aggressively Truncated (High) — IMPLEMENTED

**Problem:** The Triage prompt limited the query to 10 words, which lost critical legislative identifiers like section numbers, Act names, and clause references.

**Implemented solution:** Increased the limit to 25 words with explicit instruction to preserve legislative identifiers:

```
Query string is no longer than 25 words. Include specific section numbers, clause references, and Act/Regulation names when present in the ASK.
```

**Files changed:** `orc/plugins/Conversation/Triage/skprompt.txt`

---

### 4. No Two-Stage Retrieval (Retrieve-Then-Rerank) (Medium) — NOT YET IMPLEMENTED

**Problem:** The current pipeline does a single retrieval pass. For high-stakes legislative use cases, a two-stage approach significantly improves precision.

**Recommendation:** Implement a retrieve-then-rerank approach:

1. **Retrieve broadly** (e.g., top 20 with hybrid search) — increase `AZURE_SEARCH_TOP_K` to a higher over-fetch value (e.g., 15–20)
2. **Rerank with LLM** — add a new semantic function that scores each chunk's relevance to the query on a 0–10 scale
3. Keep only the top N chunks scoring above a configurable threshold and pass them to the Answer prompt

This can be implemented as a new Semantic Kernel plugin under `orc/plugins/Conversation/` with a prompt like:

```
## Task
Rate the relevance of the following DOCUMENT to the QUERY on a scale of 0-10.

"QUERY": "{{$query}}"
"DOCUMENT": "{{$document}}"

Output a single integer score (0-10).
```

---

### 5. Results Lack Structure (Medium) — IMPLEMENTED

**Problem:** All chunks were concatenated as `filepath: content\n`, losing `title`, `chunk_id`, and relevance ordering signals.

**Implemented solution:** Results are now structured with numbering and metadata:

```python
for i, doc in enumerate(json['value']):
    score = doc.get(score_field, 0)
    if score >= min_score:
        search_results.append(
            f"[Source {i+1}] {doc.get('title', '')} ({doc['filepath']}):\n{doc['content'].strip()}\n"
        )
```

**Files changed:** `orc/plugins/Retrieval/native_function.py`

---

### 6. No Handling of Zero Relevant Results (Medium) — IMPLEMENTED

**Problem:** If no documents passed the threshold, the code still proceeded to the Answer prompt with empty sources, leading to hallucination.

**Implemented solution:** Added a short-circuit in `orc/code_orchestration.py` that detects empty sources and immediately calls `NotInSourcesAnswer` instead of the Answer prompt:

```python
if not sources.strip() or sources.strip() == "NO_SOURCES_FOUND":
    function_result = await call_semantic_function(kernel, conversationPlugin["NotInSourcesAnswer"], arguments)
    answer = str(function_result)
    answer_generated_by = "no_sources_found"
    bypass_nxt_steps = True
```

This avoids the cost of running Answer + IsGrounded when there are no relevant sources.

**Files changed:** `orc/code_orchestration.py`

---

### 7. Missing Multi-Query Retrieval for Complex Questions (Low) — NOT YET IMPLEMENTED

**Problem:** Legislative questions often span multiple concepts (e.g., "penalties AND obligations under Act X"). A single search query may not surface all relevant chunks.

**Recommendation:** For `follow_up` and `question_answering` intents, generate 2–3 sub-queries from the Triage step and merge deduplicated results. Modify the Triage prompt to output a `query_strings` array instead of a single `query_string`:

```json
{
  "intents": ["question_answering"],
  "answer": "",
  "query_strings": [
    "penalties section 15 Design Building Practitioners Act 2020",
    "design compliance declaration obligations"
  ]
}
```

Then iterate over each sub-query, run retrieval independently, and deduplicate results by `chunk_id` before passing to the Answer prompt.

---

## Priority Implementation Order

| Priority | Change | Impact | Effort | Status |
|----------|--------|--------|--------|--------|
| **P0** | Add score filtering with separate reranker/search thresholds | High — removes irrelevant chunks immediately | Low | **Done** |
| **P0** | Enable semantic ranking by default | High — dramatically better relevance | Config change | **Done** |
| **P1** | Increase query word limit from 10 → 25 | Medium — preserves legislative references | Prompt edit | **Done** |
| **P1** | Short-circuit on empty/no relevant sources | Medium — avoids hallucination, saves cost | Low | **Done** |
| **P2** | Structure source output with numbering | Medium — helps LLM prioritize sources | Low | **Done** |
| **P3** | LLM-based reranking step | High — best precision | Medium | Not started |
| **P3** | Multi-query retrieval | Medium — improves recall for complex questions | Medium | Not started |

---

## Files Changed

- `orc/plugins/Retrieval/native_function.py` — score filtering, structured output, semantic ranking default
- `orc/plugins/Conversation/Triage/skprompt.txt` — query word limit increase
- `orc/code_orchestration.py` — empty sources short-circuit logic
- `local.settings.json.template` — new settings for semantic ranking and score thresholds

## Files Not Yet Changed

- New plugin (optional) — LLM-based reranker prompt
- `orc/plugins/Conversation/Triage/skprompt.txt` — multi-query output (if implementing recommendation 7)

---

## Prerequisites: Enabling Semantic Ranking on Azure AI Search

Semantic ranking requires configuration on the Azure AI Search service before it can be used. Without this, enabling `AZURE_SEARCH_USE_SEMANTIC` will result in a 400 Bad Request error.

### 1. Verify Service Tier

Semantic ranking is available on **Basic tier and above** (not Free tier).

### 2. Enable Semantic Ranker on the Service

In the Azure Portal:
1. Go to your search service
2. Navigate to **Settings → Semantic ranker**
3. Enable it

### 3. Add a Semantic Configuration to Your Index

The code references the configuration name set in the `AZURE_SEARCH_SEMANTIC_SEARCH_CONFIG` environment variable (defaults to `my-semantic-config`). This configuration must exist on the index.

**Via Azure Portal:**
1. Go to your search service → **Indexes** → select your index (e.g., `ragindex`)
2. Click the **Semantic configurations** tab
3. Click **Add semantic configuration**
4. Name it `my-semantic-config` (or match your `AZURE_SEARCH_SEMANTIC_SEARCH_CONFIG` value)
5. Set:
   - **Title field**: `title`
   - **Content fields**: `content`
   - **Keyword fields**: `filepath` (optional)
6. Save

**Via REST API:**

```json
PUT https://<your-search-service>.search.windows.net/indexes/<your-index>?api-version=2024-07-01

// Add this to the index definition:
{
  "semantic": {
    "configurations": [
      {
        "name": "my-semantic-config",
        "prioritizedFields": {
          "titleField": { "fieldName": "title" },
          "prioritizedContentFields": [
            { "fieldName": "content" }
          ],
          "prioritizedKeywordsFields": [
            { "fieldName": "filepath" }
          ]
        }
      }
    ]
  }
}
```

Once the semantic configuration is in place, restart the function app and semantic ranking will be active.
