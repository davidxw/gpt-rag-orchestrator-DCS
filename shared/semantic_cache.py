# Semantic cache using Cosmos DB with vector search (DiskANN indexing).
# Caches question/answer pairs with embeddings for semantic similarity lookup.
# Only first-turn questions (no conversation history) are cached.
# Cache keys include security_ids to ensure security-filtered isolation.

import logging
import os
import time
import hashlib
from datetime import datetime, timezone
from azure.cosmos.aio import CosmosClient as AsyncCosmosClient
from shared.util import get_credential

AZURE_DB_ID = os.environ.get("AZURE_DB_ID")
AZURE_DB_NAME = os.environ.get("AZURE_DB_NAME")
AZURE_DB_URI = f"https://{AZURE_DB_ID}.documents.azure.com:443/"

SEMANTIC_CACHE_CONTAINER = "semantic_cache"

# Configurable settings
SEMANTIC_CACHE_SIMILARITY_THRESHOLD = float(os.environ.get("SEMANTIC_CACHE_SIMILARITY_THRESHOLD", "0.90"))
SEMANTIC_CACHE_TTL_SECONDS = int(os.environ.get("SEMANTIC_CACHE_TTL_SECONDS", "86400"))  # 24 hours default


async def check_semantic_cache(question_embedding, security_ids):
    """
    Query Cosmos DB for a cached answer semantically similar to the question.
    Uses vector search with DiskANN indexing. Returns the best match above
    the similarity threshold, or None.
    """
    start_time = time.time()
    credential = get_credential()

    try:
        async with AsyncCosmosClient(AZURE_DB_URI, credential) as db_client:
            db = db_client.get_database_client(database=AZURE_DB_NAME)
            container = db.get_container_client(SEMANTIC_CACHE_CONTAINER)

            # Vector search query using Cosmos DB's VectorDistance function
            # ORDER BY closest first (cosine distance: lower = more similar)
            query = """
                SELECT TOP 1
                    c.question, c.answer, c.sources, c.search_query,
                    c.detected_language, c.security_ids, c.created_at,
                    VectorDistance(c.question_embedding, @embedding) AS similarity
                FROM c
                WHERE c.security_ids = @security_ids
                ORDER BY VectorDistance(c.question_embedding, @embedding)
            """

            parameters = [
                {"name": "@embedding", "value": question_embedding},
                {"name": "@security_ids", "value": security_ids},
            ]

            items = []
            async for item in container.query_items(
                query=query,
                parameters=parameters,
                partition_key=security_ids,
            ):
                items.append(item)
                break  # TOP 1

            response_time = round(time.time() - start_time, 2)

            if items:
                result = items[0]
                similarity = result.get("similarity", 0)
                logging.info(f"[sem_cache] cache lookup found match (similarity: {similarity:.4f}, threshold: {SEMANTIC_CACHE_SIMILARITY_THRESHOLD}). {response_time}s")

                if similarity >= SEMANTIC_CACHE_SIMILARITY_THRESHOLD:
                    logging.info(f"[sem_cache] cache HIT for question: {result['question'][:50]}")
                    return {
                        "answer": result["answer"],
                        "sources": result["sources"],
                        "search_query": result.get("search_query", ""),
                        "detected_language": result.get("detected_language", ""),
                        "similarity": similarity,
                    }
                else:
                    logging.info(f"[sem_cache] cache MISS (below threshold)")
                    return None
            else:
                logging.info(f"[sem_cache] cache MISS (no results for security_ids). {response_time}s")
                return None

    except Exception as e:
        response_time = round(time.time() - start_time, 2)
        logging.warning(f"[sem_cache] cache lookup failed ({response_time}s): {e}")
        return None


async def save_to_semantic_cache(question, question_embedding, answer, sources, search_query, detected_language, security_ids):
    """
    Save a question/answer pair to the semantic cache in Cosmos DB.
    The document ID is a hash of question + security_ids for idempotency.
    TTL is set so Cosmos DB auto-expires stale entries.
    """
    start_time = time.time()
    credential = get_credential()

    # Deterministic ID based on the exact question text + security context
    doc_id = hashlib.sha256(f"{question}|{security_ids}".encode()).hexdigest()[:32]

    cache_doc = {
        "id": doc_id,
        "security_ids": security_ids,
        "question": question,
        "question_embedding": question_embedding,
        "answer": answer,
        "sources": sources,
        "search_query": search_query,
        "detected_language": detected_language,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "ttl": SEMANTIC_CACHE_TTL_SECONDS,
    }

    try:
        async with AsyncCosmosClient(AZURE_DB_URI, credential) as db_client:
            db = db_client.get_database_client(database=AZURE_DB_NAME)
            container = db.get_container_client(SEMANTIC_CACHE_CONTAINER)
            await container.upsert_item(body=cache_doc)

        response_time = round(time.time() - start_time, 2)
        logging.info(f"[sem_cache] saved to cache (id: {doc_id[:8]}..., question: {question[:50]}). {response_time}s")

    except Exception as e:
        response_time = round(time.time() - start_time, 2)
        logging.warning(f"[sem_cache] failed to save to cache ({response_time}s): {e}")
