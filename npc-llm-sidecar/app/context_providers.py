"""context_providers.py
Providers for pre-compiled cultural and zone knowledge context.
Loaded at startup from JSON config files; served to the PromptAssembler per request.
"""
import json
import logging
import os
from pathlib import Path

logger = logging.getLogger("npc-llm")


class GlobalContextProvider:
    """Loads and serves pre-compiled cultural context paragraphs.

    Fallback chain per request:
    1. npc_overrides[npc_type_id]       -- specific NPC backstory
    2. race_class_faction[r_c_f]        -- race + class + primary faction
    3. race_class[r_c]                  -- race + class
    4. race[r]                          -- race baseline
    5. ""                               -- no entry (caller handles gracefully)
    """

    def __init__(self, config_path: str | None = None):
        if config_path is None:
            config_path = os.environ.get(
                "GLOBAL_CONTEXTS_PATH",
                str(Path(__file__).parent.parent / "config" / "global_contexts.json"),
            )
        self._data: dict = {}
        try:
            with open(config_path) as f:
                self._data = json.load(f)
            logger.info("GlobalContextProvider loaded from %s", config_path)
        except FileNotFoundError:
            logger.warning(
                "global_contexts.json not found at %s — global context disabled",
                config_path,
            )
        except json.JSONDecodeError as e:
            logger.error("Failed to parse global_contexts.json: %s", e)

    def get_context(
        self,
        npc_type_id: int,
        race: int,
        class_: int,
        primary_faction: int,
    ) -> str:
        """Return the best-match cultural context paragraph using the fallback chain."""
        if not self._data:
            return ""

        overrides = self._data.get("npc_overrides", {})
        if str(npc_type_id) in overrides:
            return overrides[str(npc_type_id)]

        race_class_faction = self._data.get("race_class_faction", {})
        key_rcf = f"{race}_{class_}_{primary_faction}"
        if primary_faction and key_rcf in race_class_faction:
            return race_class_faction[key_rcf]

        race_class = self._data.get("race_class", {})
        key_rc = f"{race}_{class_}"
        if key_rc in race_class:
            return race_class[key_rc]

        race_data = self._data.get("race", {})
        if str(race) in race_data:
            return race_data[str(race)]

        return ""


class LocalContextProvider:
    """Loads and serves per-zone knowledge at INT-gated detail tiers.

    INT mapping:
    - < 75:      "low"    -- short, simple sentences
    - 75 - 120:  "medium" -- standard detail
    - > 120:     "high"   -- full zone intelligence
    """

    def __init__(self, config_path: str | None = None):
        if config_path is None:
            config_path = os.environ.get(
                "LOCAL_CONTEXTS_PATH",
                str(Path(__file__).parent.parent / "config" / "local_contexts.json"),
            )
        self._data: dict = {}
        try:
            with open(config_path) as f:
                self._data = json.load(f)
            logger.info("LocalContextProvider loaded from %s", config_path)
        except FileNotFoundError:
            logger.warning(
                "local_contexts.json not found at %s — local context disabled",
                config_path,
            )
        except json.JSONDecodeError as e:
            logger.error("Failed to parse local_contexts.json: %s", e)

    def get_int_tier(self, npc_int: int) -> str:
        if npc_int < 75:
            return "low"
        elif npc_int <= 120:
            return "medium"
        else:
            return "high"

    def get_context(self, zone_short: str, npc_int: int) -> str:
        """Return zone knowledge at the appropriate detail tier.

        Falls back to lower tiers if the requested tier is absent.
        Returns empty string if zone has no entry.
        """
        if not self._data:
            return ""

        zone_data = self._data.get(zone_short)
        if not zone_data:
            return ""

        tier = self.get_int_tier(npc_int)
        # Fallback: high → medium → low → ""
        for t in (tier, "medium", "low"):
            text = zone_data.get(t, "")
            if text:
                return text
        return ""


# Class-to-role mapping for role framing instructions.
# Classes not listed here (e.g., class 41 GM/Merchant) get no specific framing.
ROLE_FRAMES: dict[str, dict] = {
    "military": {
        "classes": {1, 3, 5, 4},  # Warrior, Paladin, SK, Ranger
        "frame": "Frame your knowledge as tactical intelligence and threat assessment.",
    },
    "commerce": {
        "classes": {9},  # Rogue (overridden by merchant flag)
        "frame": "Frame your knowledge through trade, commerce, and practical concerns.",
    },
    "scholar": {
        "classes": {12, 14, 13, 11},  # Wizard, Enchanter, Magician, Necromancer
        "frame": "Frame your knowledge with scholarly analysis and historical context.",
    },
    "spiritual": {
        "classes": {2, 6, 10},  # Cleric, Druid, Shaman
        "frame": "Frame your knowledge through spiritual and moral assessment.",
    },
    "social": {
        "classes": {8, 7, 15},  # Bard, Monk, Beastlord
        "frame": "Frame your knowledge as stories, rumors, and community concerns.",
    },
}


def get_role_frame(npc_class: int, is_merchant: bool) -> str:
    """Return role framing instruction for the given NPC class.

    Merchant flag overrides class-based framing — a merchant selling goods
    should speak from a commerce perspective regardless of combat class.
    """
    if is_merchant:
        return ROLE_FRAMES["commerce"]["frame"]
    for role_data in ROLE_FRAMES.values():
        if npc_class in role_data["classes"]:
            return role_data["frame"]
    return ""  # Class 41 (GM/Merchant by DB class), unclassified classes
