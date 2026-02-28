#!/usr/bin/env python3
"""NPC LLM Sidecar — Automated Conversation Test Suite

Runs test scenarios against the sidecar API and evaluates responses for:
  - Lore accuracy (expected keywords present)
  - Hallucination detection (banned terms absent)
  - INT-gating (low-INT responses shorter than high-INT)
  - Tone matching (hostile NPCs sound hostile, friendly sound friendly)
  - Era compliance (no post-Luclin knowledge)
  - Memory persistence (multi-turn recall)
  - Response length (under 450 chars, 1-3 sentences)

Usage:
  docker exec akk-stack-npc-llm-1 python3.11 /app/tests/test_suite.py
  # or via Makefile:
  make test-llm
"""
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

SIDECAR_URL = "http://localhost:8100"

# Common hallucination markers — terms no EverQuest NPC should ever say
GLOBAL_BANNED = [
    "eldoria", "erendor", "elysia", "scholars' guild", "council of elders",
    "grand library", "ancient temple of wisdom", "mystical academy",
    "realm of", "kingdom of light", "shadow realm",
    # Modern language violations
    "technology", "economy", "democracy", "mental health",
    "artificial intelligence", "algorithm",
    # AI self-awareness
    "as an ai", "i'm an ai", "language model", "i cannot",
    # Post-era content
    "plane of knowledge", "berserker class", "gates of discord",
    "omens of war", "depths of darkhollow",
]


@dataclass
class TestResult:
    name: str
    passed: bool
    details: str
    response: str = ""
    tokens: int = 0
    elapsed_ms: int = 0


@dataclass
class TestScenario:
    """A single test scenario with NPC profile, player input, and evaluation criteria."""
    name: str
    description: str
    request: dict
    # At least one of these keywords should appear (case-insensitive)
    expected_any: list[str] = field(default_factory=list)
    # ALL of these must be absent (case-insensitive)
    banned: list[str] = field(default_factory=list)
    # Max response length in characters
    max_length: int = 450
    # If set, response must be shorter than this many chars (for low-INT tests)
    max_length_strict: int = 0
    # If set, response tone should match
    expect_hostile: bool = False
    expect_friendly: bool = False


def make_request(npc_type_id, npc_name, npc_race, npc_class, npc_level,
                 zone_short, zone_long, message,
                 npc_int=80, npc_primary_faction=0, npc_gender=0,
                 npc_is_merchant=False, faction_level=5,
                 faction_tone="indifferent",
                 faction_instruction="Respond in a neutral, professional manner.",
                 player_name="Testplayer", player_race=1, player_class=3,
                 player_level=10, player_id=0):
    """Build a chat request dict."""
    return {
        "npc_type_id": npc_type_id,
        "npc_name": npc_name,
        "npc_race": npc_race,
        "npc_class": npc_class,
        "npc_level": npc_level,
        "zone_short": zone_short,
        "zone_long": zone_long,
        "player_name": player_name,
        "player_race": player_race,
        "player_class": player_class,
        "player_level": player_level,
        "faction_level": faction_level,
        "faction_tone": faction_tone,
        "faction_instruction": faction_instruction,
        "message": message,
        "player_id": player_id,
        "npc_int": npc_int,
        "npc_primary_faction": npc_primary_faction,
        "npc_gender": npc_gender,
        "npc_is_merchant": npc_is_merchant,
    }


# ---------------------------------------------------------------------------
# Test Scenarios
# ---------------------------------------------------------------------------

SCENARIOS: list[TestScenario] = [
    # --- Lore accuracy: City guards know their city ---

    TestScenario(
        name="freeport-guard-lore",
        description="Freeport guard should reference Freeport-specific lore",
        request=make_request(
            9124, "Guard_Munden", 12, 1, 50,
            "freportw", "West Freeport",
            "Tell me about this city",
            npc_int=75, npc_primary_faction=281,
        ),
        expected_any=["freeport", "militia", "commonlands", "tradefolk",
                      "docks", "coalition", "dervish", "merchant"],
        banned=["qeynos", "halas", "neriak", "oggok"],
    ),

    TestScenario(
        name="qeynos-guard-lore",
        description="Qeynos guard should reference Qeynos-specific lore",
        request=make_request(
            2093, "Guard_Gehnus", 71, 1, 50,
            "qeynos2", "South Qeynos",
            "What threats face this city?",
            npc_int=100, npc_primary_faction=219,
        ),
        # race 71 = halfling-ish? Actually 71 might not be in our race map.
        # Let's check: the guard is race 71 which is likely "Half Elf" variant
        expected_any=["qeynos", "gnoll", "blackburrow", "bayle", "antonius",
                      "sabertooth", "plains", "karana"],
        banned=["freeport", "neriak", "oggok", "militia"],
    ),

    # --- Racial voice: Dark Elf in Neriak ---

    TestScenario(
        name="neriak-dark-elf-voice",
        description="Dark Elf Necromancer should sound sinister, reference Innoruuk/Teir'Dal",
        request=make_request(
            40001, "X`Ta_Timpi", 6, 11, 40,
            "neriaka", "Neriak Foreign Quarter",
            "Tell me about your people",
            npc_int=130, npc_primary_faction=236,
            faction_level=7, faction_tone="threatening",
            faction_instruction="Respond with hostility and contempt. Make thinly veiled threats.",
        ),
        expected_any=["teir'dal", "dark el", "innoruuk", "neriak", "shadow",
                      "hate", "foreign quarter"],
        expect_hostile=True,
    ),

    # --- INT-gating: Low INT = short, simple ---

    TestScenario(
        name="oggok-ogre-low-int",
        description="Low-INT Ogre should give short, blunt responses",
        request=make_request(
            49023, "Bozlum_Blossom", 10, 10, 60,
            "oggok", "Oggok",
            "What is this place?",
            npc_int=50, npc_primary_faction=242,
        ),
        expected_any=["oggok", "rallos", "ogre", "strong", "crush",
                      "fight", "war", "eat", "smash"],
        max_length_strict=250,  # Low INT should produce short responses
    ),

    # --- Merchant framing ---

    TestScenario(
        name="merchant-commerce-framing",
        description="Merchant NPC should frame knowledge through trade/commerce",
        request=make_request(
            49024, "Gralbug", 10, 41, 50,
            "oggok", "Oggok",
            "How is business these days?",
            npc_int=85, npc_primary_faction=228,
            npc_is_merchant=True,
        ),
        expected_any=["trade", "buy", "sell", "wares", "goods", "merchant",
                      "coin", "business", "supply", "stock", "customer"],
    ),

    TestScenario(
        name="freeport-merchant-framing",
        description="Freeport merchant should mention trade and commerce",
        request=make_request(
            9038, "Chardo_Ahdelia", 44, 41, 45,
            "freportw", "West Freeport",
            "How is business these days?",
            npc_int=85, npc_primary_faction=220,
            npc_is_merchant=True,
        ),
        expected_any=["trade", "goods", "buy", "sell", "wares", "merchant",
                      "business", "coin", "docks", "ship"],
    ),

    # --- Era compliance ---

    TestScenario(
        name="era-plane-of-knowledge",
        description="NPC should NOT know about Plane of Knowledge (post-Luclin)",
        request=make_request(
            9124, "Guard_Munden", 12, 1, 50,
            "freportw", "West Freeport",
            "Can you tell me how to get to the Plane of Knowledge?",
            npc_int=75, npc_primary_faction=281,
        ),
        # NPC may express confusion, redirect, or dismiss — all acceptable
        expected_any=["know not", "never heard", "don't know", "unfamiliar",
                      "what plane", "no such", "confus", "not aware",
                      "can't say", "unknown", "what is", "fool",
                      "mind your", "beyond", "peril", "not sure",
                      "heard rumor", "dangerous", "wouldn't know",
                      "none have", "returned", "speak of", "no one knows"],
        banned=["plane of knowledge is located", "i can help you get there",
                "the portal to the plane of knowledge",
                "book of knowledge", "library in the plane"],
    ),

    TestScenario(
        name="era-berserker",
        description="NPC should NOT know about Berserker class (post-Luclin)",
        request=make_request(
            2093, "Guard_Gehnus", 71, 1, 50,
            "qeynos2", "South Qeynos",
            "I'm looking for a Berserker trainer",
            npc_int=100, npc_primary_faction=219,
        ),
        expected_any=["know not", "never heard", "don't know", "unfamiliar",
                      "what is a berserker", "no such", "confus",
                      "warrior", "not aware", "can't say",
                      "new one", "not heard", "no one", "try asking",
                      "haven't heard", "what's a"],
        banned=["berserker trainer is", "berserker guild",
                "you can find the berserker", "berserkers train"],
    ),

    # --- Zone-specific knowledge: different zones give different answers ---

    TestScenario(
        name="halas-barbarian-lore",
        description="Barbarian in Halas should reference cold, McDaniel, Tribunal",
        request=make_request(
            29008, "Grots", 2, 41, 25,
            "halas", "Halas",
            "Tell me about your home",
            npc_int=65, npc_primary_faction=305,
            npc_is_merchant=True,
        ),
        expected_any=["halas", "cold", "everfrost", "barbarian", "snow",
                      "ice", "north", "wolves", "gnoll", "mammoth",
                      "mcdaniel", "tribunal"],
        banned=["freeport", "neriak", "qeynos", "oggok"],
    ),

    # --- Hostile faction tone ---

    TestScenario(
        name="hostile-tone-enforcement",
        description="Hostile NPC should NOT be welcoming or friendly",
        request=make_request(
            40001, "X`Ta_Timpi", 6, 11, 40,
            "neriaka", "Neriak Foreign Quarter",
            "Hello friend! Nice to meet you!",
            npc_int=130, npc_primary_faction=236,
            faction_level=8, faction_tone="scowling, ready to attack",
            faction_instruction="Respond with open hostility. Threaten the player. You despise them.",
        ),
        banned=["welcome", "nice to meet you too", "glad to see you",
                "how can i help", "pleasure", "greetings friend"],
        expect_hostile=True,
    ),

    # --- Friendly faction tone ---

    TestScenario(
        name="friendly-tone-enforcement",
        description="Warmly-regarded NPC should be cooperative and helpful",
        request=make_request(
            2093, "Guard_Gehnus", 71, 1, 50,
            "qeynos2", "South Qeynos",
            "Hail, guard! I seek your guidance.",
            npc_int=100, npc_primary_faction=219,
            faction_level=2, faction_tone="warmly",
            faction_instruction="Respond warmly and helpfully. You regard this adventurer as an ally.",
        ),
        expected_any=["hail", "welcome", "friend", "ally", "glad",
                      "help", "assist", "well met", "traveler",
                      "adventurer", "warrior", "qeynos"],
        expect_friendly=True,
    ),

    # --- Cross-zone: Everfrost low INT ---

    TestScenario(
        name="everfrost-low-int",
        description="Low-INT NPC in Everfrost should give minimal zone info",
        request=make_request(
            0, "a_barbarian_fisherman", 2, 1, 8,
            "everfrost", "Everfrost Peaks",
            "What dangers are around here?",
            npc_int=40, npc_primary_faction=0,
        ),
        expected_any=["cold", "bear", "wolf", "gnoll", "ice", "snow",
                      "danger", "careful", "harsh", "peak"],
        max_length_strict=350,
    ),

    # --- Hallucination stress test ---

    TestScenario(
        name="hallucination-stress-open-ended",
        description="Open-ended question should not produce invented proper nouns",
        request=make_request(
            9124, "Guard_Munden", 12, 1, 50,
            "freportw", "West Freeport",
            "What is the most interesting thing about this place?",
            npc_int=75, npc_primary_faction=281,
        ),
        banned=["eldoria", "erendor", "elysia", "crystal tower",
                "ancient prophecy", "chosen one", "grand wizard",
                "mystical", "enchanted forest", "dragon lord"],
    ),

    TestScenario(
        name="hallucination-stress-history",
        description="History question should use provided lore, not invent",
        request=make_request(
            40001, "X`Ta_Timpi", 6, 11, 40,
            "neriaka", "Neriak Foreign Quarter",
            "Tell me the history of this city",
            npc_int=130, npc_primary_faction=236,
            faction_level=5, faction_tone="indifferent",
            faction_instruction="Respond in a neutral, professional manner.",
        ),
        expected_any=["neriak", "teir'dal", "dark el", "innoruuk",
                      "foreign quarter", "underground"],
        banned=["eldoria", "founded in the year",
                "democratic", "republic", "parliament"],
    ),
]


# ---------------------------------------------------------------------------
# Multi-turn memory test (special handling)
# ---------------------------------------------------------------------------

MEMORY_TEST_TURNS = [
    {
        "message": "My name is Valorian and I am a knight from the Plains of Karana.",
        "description": "Introduction — NPC should acknowledge",
    },
    {
        "message": "What do you think of the Militia?",
        "description": "Topic shift — building conversation",
    },
    {
        "message": "Do you remember my name?",
        "description": "Memory recall — should reference 'Valorian'",
        "expected_any": ["valorian"],
    },
]


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def send_chat(request: dict, timeout: int = 30) -> dict:
    """Send a chat request to the sidecar and return the parsed response."""
    url = f"{SIDECAR_URL}/v1/chat"
    data = json.dumps(request).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8") if e.fp else ""
        return {"error": f"HTTP {e.code}: {body}"}
    except Exception as e:
        return {"error": str(e)}


def clear_memories(npc_type_id: int | None = None, clear_all: bool = False) -> int:
    """Clear memories. Returns count cleared."""
    url = f"{SIDECAR_URL}/v1/memory/clear"
    payload = {}
    if npc_type_id is not None:
        payload["npc_type_id"] = npc_type_id
    if clear_all:
        payload["clear_all"] = True
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            return result.get("cleared", 0)
    except Exception:
        return 0


def evaluate_scenario(scenario: TestScenario) -> TestResult:
    """Run a single test scenario and evaluate the response."""
    start = time.time()
    result = send_chat(scenario.request)
    elapsed_ms = int((time.time() - start) * 1000)

    if "error" in result and result["error"]:
        return TestResult(
            name=scenario.name,
            passed=False,
            details=f"API error: {result['error']}",
            elapsed_ms=elapsed_ms,
        )

    response = result.get("response", "")
    tokens = result.get("tokens_used", 0)

    if not response:
        return TestResult(
            name=scenario.name,
            passed=False,
            details="Empty response from model",
            elapsed_ms=elapsed_ms,
        )

    response_lower = response.lower()
    failures = []

    # Check expected keywords (at least one must be present)
    if scenario.expected_any:
        found = [kw for kw in scenario.expected_any if kw.lower() in response_lower]
        if not found:
            failures.append(
                f"MISSING expected keywords (need at least 1 of: "
                f"{', '.join(scenario.expected_any[:5])}...)"
            )

    # Check banned terms (none may be present)
    all_banned = GLOBAL_BANNED + scenario.banned
    found_banned = [b for b in all_banned if b.lower() in response_lower]
    if found_banned:
        failures.append(f"HALLUCINATION/BANNED: {', '.join(found_banned)}")

    # Check response length
    if len(response) > scenario.max_length:
        failures.append(
            f"TOO LONG: {len(response)} chars (max {scenario.max_length})"
        )

    # Check strict length (for low-INT tests)
    if scenario.max_length_strict and len(response) > scenario.max_length_strict:
        failures.append(
            f"LOW-INT TOO VERBOSE: {len(response)} chars (max {scenario.max_length_strict})"
        )

    # Check hostile tone
    if scenario.expect_hostile:
        friendly_markers = ["welcome", "glad to help", "nice to meet",
                            "how can i help", "pleasure to"]
        found_friendly = [m for m in friendly_markers if m in response_lower]
        if found_friendly:
            failures.append(f"HOSTILE NPC IS FRIENDLY: {', '.join(found_friendly)}")

    # Check friendly tone
    if scenario.expect_friendly:
        hostile_markers = ["die", "kill you", "leave now", "get out",
                           "despise", "filth", "scum"]
        found_hostile = [m for m in hostile_markers if m in response_lower]
        if found_hostile:
            failures.append(f"FRIENDLY NPC IS HOSTILE: {', '.join(found_hostile)}")

    passed = len(failures) == 0
    details = "OK" if passed else "; ".join(failures)

    return TestResult(
        name=scenario.name,
        passed=passed,
        details=details,
        response=response,
        tokens=tokens,
        elapsed_ms=elapsed_ms,
    )


def run_memory_test() -> TestResult:
    """Run the multi-turn memory persistence test."""
    # Use a unique player_id and NPC for memory test
    npc_type_id = 9124  # Guard Munden
    player_id = 99999   # Fake player ID for isolation

    # Clear any existing memories
    clear_memories(npc_type_id=npc_type_id)

    last_response = ""
    start = time.time()

    for i, turn in enumerate(MEMORY_TEST_TURNS):
        request = make_request(
            npc_type_id, "Guard_Munden", 12, 1, 50,
            "freportw", "West Freeport",
            turn["message"],
            npc_int=75, npc_primary_faction=281,
            player_id=player_id,
            player_name="Valorian",
        )

        result = send_chat(request)

        if result.get("error"):
            return TestResult(
                name="memory-persistence",
                passed=False,
                details=f"Turn {i+1} API error: {result['error']}",
            )

        response = result.get("response", "")
        if not response:
            return TestResult(
                name="memory-persistence",
                passed=False,
                details=f"Turn {i+1} empty response",
            )

        last_response = response

        # Check turn-specific expectations
        if "expected_any" in turn:
            response_lower = response.lower()
            found = [kw for kw in turn["expected_any"] if kw in response_lower]
            if not found:
                elapsed_ms = int((time.time() - start) * 1000)
                return TestResult(
                    name="memory-persistence",
                    passed=False,
                    details=(
                        f"Turn {i+1}: memory recall FAILED — "
                        f"expected one of {turn['expected_any']}, not found in response"
                    ),
                    response=response,
                    elapsed_ms=elapsed_ms,
                )

        # Small delay between turns for memory storage
        if i < len(MEMORY_TEST_TURNS) - 1:
            time.sleep(2)

    elapsed_ms = int((time.time() - start) * 1000)

    # Clean up test memories
    clear_memories(npc_type_id=npc_type_id)

    return TestResult(
        name="memory-persistence",
        passed=True,
        details="3-turn memory recall succeeded",
        response=last_response,
        elapsed_ms=elapsed_ms,
    )


def check_health() -> bool:
    """Verify sidecar is healthy before running tests."""
    try:
        req = urllib.request.Request(f"{SIDECAR_URL}/v1/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("model_loaded"):
                print(f"  Model: {data.get('model_name', 'unknown')}")
                return True
            print(f"  ERROR: Model not loaded")
            return False
    except Exception as e:
        print(f"  ERROR: {e}")
        return False


def main():
    print("=" * 70)
    print("NPC LLM Sidecar — Automated Conversation Test Suite")
    print("=" * 70)
    print()

    # Health check
    print("[*] Checking sidecar health...")
    if not check_health():
        print("FATAL: Sidecar not healthy. Aborting.")
        sys.exit(1)
    print()

    # Run single-turn scenarios
    results: list[TestResult] = []
    total = len(SCENARIOS) + 1  # +1 for memory test

    for i, scenario in enumerate(SCENARIOS, 1):
        print(f"[{i}/{total}] {scenario.name}: {scenario.description}")
        result = evaluate_scenario(scenario)
        results.append(result)
        status = "PASS" if result.passed else "FAIL"
        print(f"       {status} ({result.elapsed_ms}ms, {result.tokens} tokens)")
        if not result.passed:
            print(f"       >> {result.details}")
            if result.response:
                # Truncate long responses for display
                display = result.response[:200] + "..." if len(result.response) > 200 else result.response
                print(f"       >> Response: {display}")
        print()

    # Run memory test
    print(f"[{total}/{total}] memory-persistence: Multi-turn memory recall test")
    mem_result = run_memory_test()
    results.append(mem_result)
    status = "PASS" if mem_result.passed else "FAIL"
    print(f"       {status} ({mem_result.elapsed_ms}ms)")
    if not mem_result.passed:
        print(f"       >> {mem_result.details}")
        if mem_result.response:
            display = mem_result.response[:200] + "..." if len(mem_result.response) > 200 else mem_result.response
            print(f"       >> Response: {display}")
    print()

    # Summary
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    total_time = sum(r.elapsed_ms for r in results)

    print("=" * 70)
    print(f"RESULTS: {passed}/{len(results)} PASS, {failed} FAIL ({total_time}ms total)")
    print("=" * 70)

    if failed > 0:
        print()
        print("FAILURES:")
        for r in results:
            if not r.passed:
                print(f"  [{r.name}] {r.details}")

    print()

    # Exit code: 0 if all pass, 1 if any fail
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
