import asyncio
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI
from llama_cpp import Llama

from .context_providers import GlobalContextProvider, LocalContextProvider
from .memory import MemoryManager, fallback_turn_summary, generate_turn_summary_prompt
from .models import (
    ChatRequest,
    ChatResponse,
    MemoryClearRequest,
    MemoryClearResponse,
)
from .post_processor import process_response
from .prompt_assembler import PromptAssembler
from .prompt_builder import build_system_prompt, build_user_message, load_zone_cultures

logger = logging.getLogger("npc-llm")
logging.basicConfig(level=logging.INFO)

_llm: Llama | None = None
_model_name: str = ""
_memory: MemoryManager | None = None
_assembler: PromptAssembler | None = None
_cleanup_task: asyncio.Task | None = None


def _load_model():
    """Load the GGUF model from MODEL_PATH env var."""
    global _llm, _model_name
    model_path = os.environ.get("MODEL_PATH", "/models/model.gguf")
    if not Path(model_path).exists():
        logger.error("Model file not found: %s", model_path)
        return

    n_ctx = int(os.environ.get("LLM_N_CTX", "1024"))
    n_threads = int(os.environ.get("LLM_N_THREADS", "6"))
    n_gpu_layers = int(os.environ.get("LLM_N_GPU_LAYERS", "99"))

    logger.info(
        "Loading model from %s (n_ctx=%d, n_threads=%d, n_gpu_layers=%d)",
        model_path, n_ctx, n_threads, n_gpu_layers,
    )
    _llm = Llama(
        model_path=model_path,
        n_ctx=n_ctx,
        n_threads=n_threads,
        n_gpu_layers=n_gpu_layers,
        verbose=False,
    )
    _model_name = Path(model_path).stem
    logger.info("Model loaded: %s", _model_name)


def _init_memory():
    """Initialize the MemoryManager from environment variables."""
    global _memory
    persist_path = os.environ.get("CHROMADB_PATH", "/data/chromadb")
    enabled = os.environ.get("MEMORY_ENABLED", "true").lower() in ("true", "1", "yes")
    _memory = MemoryManager(persist_path=persist_path, enabled=enabled)


def _init_assembler():
    """Initialize the PromptAssembler with context providers and model reference."""
    global _assembler
    global_provider = GlobalContextProvider()
    local_provider = LocalContextProvider()
    _assembler = PromptAssembler(
        llm=_llm,
        global_provider=global_provider,
        local_provider=local_provider,
    )
    logger.info("PromptAssembler initialized")


async def _scheduled_cleanup():
    """Background loop: run memory cleanup on a timer."""
    interval_hours = int(os.environ.get("MEMORY_CLEANUP_INTERVAL_HOURS", "24"))
    ttl_days = int(os.environ.get("MEMORY_TTL_DAYS", "90"))
    interval_seconds = interval_hours * 3600

    while True:
        await asyncio.sleep(interval_seconds)
        if _memory and _memory.enabled:
            logger.info("Running scheduled memory cleanup (TTL=%d days)", ttl_days)
            await _memory.cleanup_expired(ttl_days=ttl_days)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _cleanup_task
    load_zone_cultures()
    _load_model()
    _init_memory()
    _init_assembler()

    # Start scheduled cleanup in background
    _cleanup_task = asyncio.create_task(_scheduled_cleanup())

    yield

    # Shutdown: cancel cleanup task
    if _cleanup_task:
        _cleanup_task.cancel()
        try:
            await _cleanup_task
        except asyncio.CancelledError:
            pass


app = FastAPI(title="NPC LLM Sidecar", version="2.5.0", lifespan=lifespan)


@app.get("/v1/health")
async def health():
    status = {
        "status": "ok" if _llm is not None else "model_not_loaded",
        "model_loaded": _llm is not None,
        "model_name": _model_name,
    }
    if _memory:
        status.update(_memory.health_status())
    return status


def _generate_turn_summary(req: ChatRequest, npc_response: str) -> str:
    """Use the LLM to generate a brief turn summary. Falls back to concatenation."""
    if _llm is None:
        return fallback_turn_summary(req.message, npc_response)

    try:
        prompt = generate_turn_summary_prompt(
            req.player_name, req.message, req.npc_name, npc_response
        )
        result = _llm.create_chat_completion(
            messages=[{"role": "user", "content": prompt}],
            max_tokens=40,
            temperature=0.3,
        )
        summary = result["choices"][0]["message"]["content"].strip()
        if summary and len(summary) > 10:
            return summary
    except Exception:
        logger.warning("Turn summary generation failed, using fallback")

    return fallback_turn_summary(req.message, npc_response)


async def _summarize_and_store_background(req: ChatRequest, npc_response: str):
    """Background task: generate turn summary then store the exchange in ChromaDB."""
    if not (_memory and _memory.enabled and req.player_id > 0):
        return
    turn_summary = _generate_turn_summary(req, npc_response)
    await _memory.store(
        npc_type_id=req.npc_type_id,
        player_id=req.player_id,
        player_name=req.player_name,
        player_message=req.message,
        npc_response=npc_response,
        zone=req.zone_short,
        faction_level=req.faction_level,
        turn_summary=turn_summary,
    )


@app.post("/v1/chat", response_model=ChatResponse)
async def chat(req: ChatRequest, background_tasks: BackgroundTasks):
    if _llm is None:
        return ChatResponse(error="Model not loaded")

    # Retrieve memories if player_id is provided and memory is enabled
    memories = []
    if _memory and _memory.enabled and req.player_id > 0:
        top_k = int(os.environ.get("MEMORY_TOP_K", "5"))
        score_threshold = float(os.environ.get("MEMORY_SCORE_THRESHOLD", "0.4"))
        memories = await _memory.retrieve(
            npc_type_id=req.npc_type_id,
            player_id=req.player_id,
            query_text=req.message,
            top_k=top_k,
            score_threshold=score_threshold,
        )

    # Use the layered assembler; fall back to legacy prompt builder if assembler failed to init
    if _assembler is not None:
        system_prompt = _assembler.assemble(req, memories=memories or None)
    else:
        logger.warning("PromptAssembler not initialized — falling back to build_system_prompt()")
        system_prompt = build_system_prompt(req, memories=memories or None)

    user_message = build_user_message(req)

    if os.environ.get("LLM_DEBUG_PROMPTS", "").lower() in ("true", "1"):
        logger.info("SYSTEM PROMPT:\n%s", system_prompt)
        logger.info("USER MESSAGE:\n%s", user_message)

    max_tokens = int(os.environ.get("LLM_MAX_TOKENS", "200"))
    temperature = float(os.environ.get("LLM_TEMPERATURE", "0.7"))

    try:
        result = _llm.create_chat_completion(
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
            max_tokens=max_tokens,
            temperature=temperature,
            stop=["\n\n"],
        )

        raw_text = result["choices"][0]["message"]["content"]
        tokens_used = result.get("usage", {}).get("total_tokens", 0)

        processed = process_response(raw_text)
        if not processed:
            return ChatResponse(error="Response filtered (era violation)")

        # Schedule turn summary + memory storage as background task
        memory_stored = False
        if _memory and _memory.enabled and req.player_id > 0:
            background_tasks.add_task(
                _summarize_and_store_background, req, processed
            )
            memory_stored = True

        return ChatResponse(
            response=processed,
            tokens_used=tokens_used,
            memories_retrieved=len(memories),
            memory_stored=memory_stored,
        )

    except Exception as e:
        logger.exception("LLM inference error")
        return ChatResponse(error=str(e))


@app.post("/v1/memory/clear", response_model=MemoryClearResponse)
async def memory_clear(req: MemoryClearRequest):
    if not _memory or not _memory.enabled:
        return MemoryClearResponse(cleared=0)

    cleared = await _memory.clear(
        npc_type_id=req.npc_type_id,
        player_id=req.player_id,
        clear_all=req.clear_all,
    )
    return MemoryClearResponse(cleared=cleared)
