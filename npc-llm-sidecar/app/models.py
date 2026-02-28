from pydantic import BaseModel
from typing import Optional


class ChatRequest(BaseModel):
    npc_type_id: int
    npc_name: str
    npc_race: int
    npc_class: int
    npc_level: int
    npc_deity: int = 0
    zone_short: str
    zone_long: str
    player_name: str
    player_race: int
    player_class: int
    player_level: int
    faction_level: int
    faction_tone: str
    faction_instruction: str
    message: str
    player_id: int = 0  # For memory lookup. 0 = no memory.
    npc_int: int = 80           # NPC INT stat for knowledge tier gating
    npc_primary_faction: int = 0  # Primary faction ID for cultural context lookup
    npc_gender: int = 0         # 0=male, 1=female, 2=neutral
    npc_is_merchant: bool = False  # True if NPC class == 41 (Merchant)
    quest_hints: list[str] | None = None     # Tier 2: hint sentences for quest guidance
    quest_state: str | None = None           # Tier 2: current quest progress descriptor


class ChatResponse(BaseModel):
    response: Optional[str] = None
    tokens_used: int = 0
    error: Optional[str] = None
    memories_retrieved: int = 0
    memory_stored: bool = False


class MemoryClearRequest(BaseModel):
    npc_type_id: Optional[int] = None
    player_id: Optional[int] = None
    clear_all: bool = False


class MemoryClearResponse(BaseModel):
    cleared: int = 0
