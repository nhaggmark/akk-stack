"""NPC conversation memory via ChromaDB vector database and sentence-transformers."""

import logging
import os
import time
from typing import Optional

import chromadb

logger = logging.getLogger("npc-llm.memory")


class MemoryManager:
    """Manages NPC conversation memory via ChromaDB and sentence-transformers.

    Operates in disabled (no-op) mode when enabled=False.
    All ChromaDB operations are wrapped in try/except for graceful degradation.
    ChromaDB runs embedded — no API key or remote connection needed.
    """

    def __init__(self, persist_path: str = "/data/chromadb", enabled: bool = True):
        self.enabled = enabled
        self.client = None
        self.embed_model = None
        self._persist_path = persist_path

        if not self.enabled:
            logger.info("Memory system disabled (MEMORY_ENABLED=false)")
            return

        try:
            self.client = chromadb.PersistentClient(path=persist_path)
            logger.info("ChromaDB initialized with persistent storage at: %s",
                        persist_path)
        except Exception:
            logger.exception("Failed to initialize ChromaDB — memory disabled")
            self.enabled = False
            return

        try:
            from sentence_transformers import SentenceTransformer

            self.embed_model = SentenceTransformer("all-MiniLM-L6-v2")
            logger.info("Embedding model loaded: all-MiniLM-L6-v2 (384-dim)")
        except Exception:
            logger.exception("Failed to load embedding model — memory disabled")
            self.enabled = False

    def _get_collection(self, npc_type_id: int):
        """Get or create a ChromaDB collection for the given NPC type."""
        name = f"npc_{npc_type_id}"
        return self.client.get_or_create_collection(
            name=name,
            metadata={"hnsw:space": "cosine"},
        )

    def embed(self, text: str) -> list[float]:
        """Generate 384-dim embedding from text. Returns empty list on error."""
        if not self.enabled or self.embed_model is None:
            return []
        try:
            embedding = self.embed_model.encode(text, normalize_embeddings=True)
            return embedding.tolist()
        except Exception:
            logger.exception("Embedding failed")
            return []

    @staticmethod
    def _cosine_sim(a: list[float], b: list[float]) -> float:
        """Cosine similarity between two normalized vectors (= dot product)."""
        return sum(x * y for x, y in zip(a, b))

    async def retrieve(self, npc_type_id: int, player_id: int, query_text: str,
                       top_k: int = 5, score_threshold: float = 0.4) -> list[dict]:
        """Query ChromaDB for relevant past conversations.

        Returns list of memory dicts sorted by recency-weighted score.
        Applies diversity filtering to prevent feedback loops where a bad
        follow-up answer drowns out the original correct statement.
        Returns empty list on any error (graceful degradation).

        Note: ChromaDB returns cosine distances (lower = more similar).
        We convert to scores via: score = 1.0 - distance.
        """
        if not self.enabled or self.client is None:
            return []

        try:
            query_embedding = self.embed(query_text)
            if not query_embedding:
                return []

            collection = self._get_collection(npc_type_id)

            # Over-fetch for diversity filtering
            fetch_count = min(top_k * 3, 20)

            results = collection.query(
                query_embeddings=[query_embedding],
                n_results=fetch_count,
                where={"player_id": player_id},
                include=["metadatas", "documents", "distances", "embeddings"],
            )

            now = time.time()
            candidates = []

            # ChromaDB returns lists of lists; first (only) query result
            ids = results.get("ids", [[]])[0]
            distances = results.get("distances", [[]])[0]
            metadatas = results.get("metadatas", [[]])[0]
            embeddings = results.get("embeddings", [[]])[0]

            for i, vector_id in enumerate(ids):
                # Convert cosine distance to similarity score
                distance = distances[i] if i < len(distances) else 1.0
                score = 1.0 - distance

                if score < score_threshold:
                    continue

                meta = metadatas[i] if i < len(metadatas) else {}
                ts = meta.get("timestamp", now)
                days_since = max((now - ts) / 86400, 0)

                # Recency weighting: recent memories score higher
                adjusted_score = score * (1 / (1 + days_since * 0.1))

                emb = embeddings[i] if i < len(embeddings) else []

                candidates.append({
                    "player_message": meta.get("player_message", ""),
                    "npc_response": meta.get("npc_response", ""),
                    "turn_summary": meta.get("turn_summary", ""),
                    "zone": meta.get("zone", ""),
                    "timestamp": ts,
                    "faction_at_time": meta.get("faction_at_time", 0),
                    "score": adjusted_score,
                    "days_ago": days_since,
                    "_embedding": emb,
                })

            # Diversity filter: when two memories are semantically similar
            # (>0.7 cosine), keep the OLDER one to prevent feedback loops
            # where a bad follow-up answer drowns out the original statement.
            candidates.sort(key=lambda m: m["timestamp"])  # oldest first
            diverse = []
            for mem in candidates:
                is_duplicate = False
                emb = mem.get("_embedding")
                if emb is not None and len(emb) > 0:
                    for existing in diverse:
                        ex_emb = existing.get("_embedding")
                        if ex_emb is not None and len(ex_emb) > 0:
                            sim = self._cosine_sim(emb, ex_emb)
                            if sim > 0.7:
                                is_duplicate = True
                                break
                if not is_duplicate:
                    diverse.append(mem)

            # Strip internal embedding field before returning
            for mem in diverse:
                mem.pop("_embedding", None)

            # Sort by adjusted score descending
            diverse.sort(key=lambda m: m["score"], reverse=True)

            logger.info(
                "Memory retrieval: %d fetched, %d above threshold, %d after diversity",
                len(ids), len(candidates), len(diverse),
            )

            return diverse[:top_k]

        except Exception:
            logger.exception("Memory retrieval failed — proceeding without memory")
            return []

    async def store(self, npc_type_id: int, player_id: int, player_name: str,
                    player_message: str, npc_response: str, zone: str,
                    faction_level: int, turn_summary: str):
        """Embed turn_summary and upsert to ChromaDB. Fire-and-forget on error."""
        if not self.enabled or self.client is None:
            return

        try:
            embedding = self.embed(turn_summary)
            if not embedding:
                return

            collection = self._get_collection(npc_type_id)
            ts = int(time.time())
            vector_id = f"conv_{player_id}_{ts}"

            collection.upsert(
                ids=[vector_id],
                embeddings=[embedding],
                metadatas=[{
                    "player_id": player_id,
                    "player_name": player_name,
                    "player_message": player_message[:500],
                    "npc_response": npc_response[:500],
                    "zone": zone,
                    "timestamp": ts,
                    "faction_at_time": faction_level,
                    "turn_summary": turn_summary[:300],
                }],
                documents=[turn_summary[:300]],
            )

            # Prune oldest if over per-player limit
            max_per_player = int(os.environ.get("MEMORY_MAX_PER_PLAYER", "100"))
            await self._prune_if_needed(collection, player_id, max_per_player)

            logger.info("Memory stored: %s in npc_%d", vector_id, npc_type_id)

        except Exception:
            logger.exception("Memory storage failed — exchange not remembered")

    async def _prune_if_needed(self, collection, player_id: int,
                               max_count: int):
        """Delete oldest vectors if a player exceeds the per-NPC limit."""
        try:
            # Get all vectors for this player in this collection
            results = collection.get(
                where={"player_id": player_id},
                include=["metadatas"],
            )

            ids = results.get("ids", [])
            metadatas = results.get("metadatas", [])

            if len(ids) <= max_count:
                return

            # Pair ids with timestamps for sorting
            id_ts_pairs = []
            for i, vid in enumerate(ids):
                meta = metadatas[i] if i < len(metadatas) else {}
                ts = meta.get("timestamp", 0)
                id_ts_pairs.append((vid, ts))

            # Sort by timestamp ascending (oldest first)
            id_ts_pairs.sort(key=lambda p: p[1])
            to_delete = [p[0] for p in id_ts_pairs[:len(id_ts_pairs) - max_count]]

            if to_delete:
                collection.delete(ids=to_delete)
                logger.info("Pruned %d old memories for player %d in %s",
                            len(to_delete), player_id, collection.name)

        except Exception:
            logger.exception("Memory pruning failed")

    async def clear(self, npc_type_id: int = None, player_id: int = None,
                    clear_all: bool = False) -> int:
        """Delete vectors matching criteria. Returns count of deleted vectors."""
        if not self.enabled or self.client is None:
            return 0

        try:
            if clear_all:
                # Delete all collections
                collections = self.client.list_collections()
                total = 0
                for col in collections:
                    count = col.count()
                    total += count
                    self.client.delete_collection(col.name)
                logger.info("Cleared all memory: %d vectors across %d collections",
                            total, len(collections))
                return total

            if npc_type_id is not None:
                collection_name = f"npc_{npc_type_id}"
                try:
                    collection = self.client.get_collection(collection_name)
                except Exception:
                    # Collection doesn't exist — nothing to clear
                    return 0

                if player_id is not None:
                    # Delete all vectors for a specific player in this collection
                    results = collection.get(
                        where={"player_id": player_id},
                    )
                    ids = results.get("ids", [])
                    if ids:
                        collection.delete(ids=ids)
                    logger.info("Cleared %d memories for player %d in %s",
                                len(ids), player_id, collection_name)
                    return len(ids)
                else:
                    # Delete entire collection
                    count = collection.count()
                    self.client.delete_collection(collection_name)
                    logger.info("Cleared all memories in collection %s (%d vectors)",
                                collection_name, count)
                    return count

            return 0

        except Exception:
            logger.exception("Memory clear failed")
            return 0

    async def cleanup_expired(self, ttl_days: int = 90):
        """Delete vectors older than ttl_days. Called by scheduled background task."""
        if not self.enabled or self.client is None:
            return

        try:
            cutoff = int(time.time()) - (ttl_days * 86400)
            collections = self.client.list_collections()
            total_deleted = 0

            for collection in collections:
                # Query for old vectors using timestamp metadata filter
                results = collection.get(
                    where={"timestamp": {"$lt": cutoff}},
                )
                ids = results.get("ids", [])
                if ids:
                    collection.delete(ids=ids)
                    total_deleted += len(ids)

            if total_deleted > 0:
                logger.info("Cleanup: deleted %d expired vectors (TTL=%d days)",
                            total_deleted, ttl_days)

        except Exception:
            logger.exception("Memory cleanup failed")

    def health_status(self) -> dict:
        """Return memory system status for health endpoint."""
        status = {
            "memory_enabled": self.enabled,
            "chromadb_connected": self.client is not None,
            "embedding_model_loaded": self.embed_model is not None,
            "persist_path": self._persist_path if self.enabled else None,
        }

        # Add collection count if connected
        if self.client is not None:
            try:
                collections = self.client.list_collections()
                status["collection_count"] = len(collections)
            except Exception:
                status["collection_count"] = -1

        return status


def generate_turn_summary_prompt(player_name: str, player_message: str,
                                 npc_name: str, npc_response: str) -> str:
    """Build a prompt to generate a brief turn summary for embedding.

    Returns the prompt string to append as an additional LLM generation.
    """
    return (
        f"Summarize this exchange in one brief sentence (under 30 words):\n"
        f"{player_name}: \"{player_message}\"\n"
        f"{npc_name}: \"{npc_response}\"\n"
        f"Summary:"
    )


def fallback_turn_summary(player_message: str, npc_response: str) -> str:
    """Generate a simple concatenation summary when LLM summary fails."""
    player_part = player_message[:50].rstrip()
    # Get first sentence of NPC response
    npc_part = npc_response.split(".")[0][:80].rstrip()
    return f"Player asked: {player_part}. NPC responded about: {npc_part}"
