"""context_providers.py
Providers for pre-compiled cultural and zone knowledge context.
Loaded at startup from JSON config files; served to the PromptAssembler per request.
"""
import json
import logging
import os
import re
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


# EverQuest deity IDs to names — Classic through Luclin era only.
DEITY_NAMES: dict[int, str] = {
    140: "Bertoxxulous",
    201: "Brell Serilis",
    202: "Cazic-Thule",
    203: "Erollisi Marr",
    205: "Innoruuk",
    206: "Karana",
    207: "Mithaniel Marr",
    208: "Prexus",
    209: "Quellious",
    210: "Rallos Zek",
    211: "Rodcet Nife",
    212: "Solusek Ro",
    213: "Bristlebane",
    214: "Tribunal",
    215: "Tunare",
    216: "Veeshan",
    396: "Agnostic",
}

# NPC name patterns for guard role detection (case-insensitive, word-boundary aware).
_GUARD_PATTERNS = re.compile(
    r"(?:^|\b)(?:Guard|Captain|Lieutenant|Trooper|Legionnaire|Sentinel|Watchman)(?:\b|_)",
    re.IGNORECASE,
)
_GUARD_SUFFIX = re.compile(r"(?:_Guard|_Sentinel|_Watchman)$", re.IGNORECASE)

# Priest classes: Cleric (2), Druid (6), Shaman (10)
_PRIEST_CLASSES = {2, 6, 10}

# Personality axis descriptors for format_soul_text: (low_label, high_label)
_AXIS_DESCRIPTORS: dict[str, tuple[str, str]] = {
    "courage": ("cautious and risk-averse", "notably brave — you confront threats directly and speak confidently about danger"),
    "generosity": ("somewhat self-interested — you look out for yourself first", "generous and willing to help others, even at personal cost"),
    "honesty": ("guarded with the truth — you reveal only what serves your purposes", "blunt and forthright — you say what you mean without decoration"),
    "piety": ("pragmatic and secular in outlook", "deeply devout — your faith shapes every aspect of your life"),
    "curiosity": ("set in your ways and incurious about novelty", "keenly curious about the wider world"),
    "loyalty": ("ambitious and self-serving — loyalty is a tool, not a virtue", "fiercely loyal — you would sacrifice yourself for those you serve"),
}

# Disposition descriptors for format_soul_text.
_DISPOSITION_TEXT: dict[str, str] = {
    "rooted": "You are deeply committed to your current role and post. You would never consider leaving.",
    "content": "You are satisfied with your place in the world. You have no desire for change.",
    "curious": "You sometimes wonder about life beyond your current role — the wider world holds a quiet pull.",
    "restless": "You feel restless in your current role — the routine weighs on you, though you would not admit it unprompted.",
    "eager": "You dream of something more than your current life. If the right opportunity came, you would leap at it.",
}


class SoulElementProvider:
    """Loads and serves soul element data for NPC personality.

    Fallback chain:
    1. npc_overrides[npc_type_id]  -- specific NPC soul
    2. role_defaults[detected_role] -- role-based defaults (guard, merchant, etc.)
    3. None                        -- no soul elements (majority of NPCs)
    """

    def __init__(self, config_path: str | None = None):
        if config_path is None:
            config_path = os.environ.get(
                "SOUL_ELEMENTS_PATH",
                str(Path(__file__).parent.parent / "config" / "soul_elements.json"),
            )
        self._data: dict = {}
        try:
            with open(config_path) as f:
                self._data = json.load(f)
            logger.info("SoulElementProvider loaded from %s", config_path)
        except FileNotFoundError:
            logger.warning(
                "soul_elements.json not found at %s — soul elements disabled",
                config_path,
            )
        except json.JSONDecodeError as e:
            logger.error("Failed to parse soul_elements.json: %s", e)

    def reload(self, config_path: str | None = None) -> None:
        """Re-read the config file. Called by the reload endpoint."""
        self.__init__(config_path=config_path)

    def detect_role(self, npc_name: str, npc_class: int, is_merchant: bool) -> str | None:
        """Detect NPC role from name patterns and class.

        Returns one of: 'guard', 'merchant', 'guildmaster', 'priest', or None.
        """
        # Merchant: explicit flag or class 41 (Merchant)
        if is_merchant or npc_class == 41:
            return "merchant"

        # Guard: name pattern matching
        clean_name = npc_name.replace("#", "").replace("_", " ")
        if _GUARD_PATTERNS.search(npc_name) or _GUARD_SUFFIX.search(npc_name):
            return "guard"

        # Guildmaster: name contains "Guildmaster" (case-insensitive)
        if "guildmaster" in clean_name.lower():
            return "guildmaster"

        # Priest: class-based detection
        if npc_class in _PRIEST_CLASSES:
            return "priest"

        return None

    def get_soul(
        self, npc_type_id: int, npc_name: str, npc_class: int, is_merchant: bool
    ) -> dict | None:
        """Return soul element data for the given NPC.

        Uses fallback chain: npc_overrides > role_defaults > None.
        """
        if not self._data:
            return None

        # Check NPC-specific override first
        overrides = self._data.get("npc_overrides", {})
        if str(npc_type_id) in overrides:
            return overrides[str(npc_type_id)]

        # Detect role and apply role defaults
        role = self.detect_role(npc_name, npc_class, is_merchant)
        if role:
            role_defaults = self._data.get("role_defaults", {})
            if role in role_defaults:
                return role_defaults[role]

        return None

    def format_soul_text(self, soul: dict, npc_deity: int = 0) -> str:
        """Convert structured soul data to natural language prompt text.

        Produces a character-direction paragraph for Layer 6 injection.
        """
        parts: list[str] = []

        # Personality axes
        trait_descriptions: list[str] = []
        for axis, (low_desc, high_desc) in _AXIS_DESCRIPTORS.items():
            value = soul.get(axis, 0)
            if value == 0:
                continue
            if abs(value) >= 2:
                intensity = ""  # strong values speak for themselves
            else:
                intensity = "somewhat "
            if value > 0:
                trait_descriptions.append(f"You are {intensity}{high_desc}.")
            else:
                trait_descriptions.append(f"You are {intensity}{low_desc}.")

        if trait_descriptions:
            parts.append("Your personality: " + " ".join(trait_descriptions))

        # Motivations: desires and fears
        desires = soul.get("desires", [])
        fears = soul.get("fears", [])
        if desires or fears:
            motivation_parts: list[str] = []
            if desires:
                desire_str = " and ".join(desires)
                motivation_parts.append(f"you desire {desire_str}")
            if fears:
                fear_str = " and ".join(fears)
                motivation_parts.append(f"you fear {fear_str}")
            parts.append("Deep down, " + ", and ".join(motivation_parts) + ".")

        # Disposition
        disposition = soul.get("disposition")
        if disposition and disposition in _DISPOSITION_TEXT:
            parts.append(_DISPOSITION_TEXT[disposition])

        # Deity alignment language
        if npc_deity and npc_deity in DEITY_NAMES:
            deity_name = DEITY_NAMES[npc_deity]
            parts.append(
                f"Your faith in {deity_name} shapes your worldview. "
                "Reference your deity naturally when appropriate."
            )

        if not parts:
            return ""

        # Closing reminder to maintain cultural voice
        parts.append(
            "Express these traits through your racial and cultural voice."
        )

        return " ".join(parts)


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
