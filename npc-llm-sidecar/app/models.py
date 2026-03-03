from pydantic import BaseModel
from typing import Optional


class GroupMember(BaseModel):
    """A member of the player's group, used in companion context."""
    name: str = ""
    race: str = ""
    class_id: int = 0
    level: int = 0
    is_companion: bool = False


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

    # --- Companion context fields ---
    # Present when the NPC is an active companion (is_companion=true).
    # All optional with defaults so non-companion requests are unaffected.
    is_companion: bool = False
    companion_type: int | None = None         # 0=loyal, 1=mercenary
    companion_stance: int | None = None       # 0=passive, 1=balanced, 2=aggressive
    companion_name: str | None = None
    time_active_seconds: int | None = None
    time_active_description: str | None = None  # "a few hours", "several days", etc.
    evolution_tier: int | None = None         # 0=early, 1=mid, 2=late
    recruited_zone_short: str | None = None
    recruited_zone_long: str | None = None
    original_role: str | None = None          # "guard", "merchant", etc.
    zone_type: str | None = None              # "outdoor", "dungeon", "city", "indoor"
    time_of_day: str | None = None            # "dawn", "day", "dusk", "night", "fixed_lighting"
    is_luclin_fixed_light: bool = False
    in_combat: bool = False
    hp_percent: int | None = None
    recently_damaged: bool = False
    group_members: list[GroupMember] | None = None
    group_size: int | None = None
    recent_kills: str | None = None           # Comma-separated NPC names
    race_culture_id: int | None = None
    type_framing: str | None = None           # Full companion/mercenary framing text from Lua
    evolution_context: str | None = None      # Identity evolution text from Lua
    unprompted: bool = False                   # True for unprompted companion commentary


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
