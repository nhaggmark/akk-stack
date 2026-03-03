-- llm_config.lua
-- Configuration for NPC LLM integration. All tunable values are here.
-- Hot-reloadable via #reloadquest — no server restart needed.

return {
    enabled = true,
    sidecar_url = "http://npc-llm:8100",
    timeout_seconds = 10,
    min_npc_intelligence = 1,  -- Body type filter handles non-sentients; INT=0 only for truly mindless
    max_response_length = 450,
    hostile_cooldown_seconds = 60,
    typing_indicator_enabled = true,
    debug_logging = false,
    excluded_body_types = {
        [5]  = true,  -- Construct (golems, animated armor)
        [11] = true,  -- NoTarget (untargetable environmental entities)
        [21] = true,  -- Animal (safety net; INT filter catches most)
        [22] = true,  -- Insect (spiders, wasps)
        [24] = true,  -- Summoned (elementals)
        [25] = true,  -- Plant (mushroom men, treants)
        [27] = true,  -- Summoned2
        [28] = true,  -- Summoned3
        [31] = true,  -- Familiar (wizard familiars)
        [33] = true,  -- Boxes (containers/crates)
        [60] = true,  -- NoTarget2
        [63] = true,  -- SwarmPet
    },
    thinking_emotes = {
        "considers your words carefully...",
        "ponders your question...",
        "thinks for a moment...",
        "studies you briefly...",
    },
    hostile_emotes = {
        "glares at you with undisguised contempt.",
        "snarls at you menacingly.",
        "makes a threatening gesture.",
    },

    -- Unprompted companion commentary
    -- Companions occasionally speak without being prompted by the player.
    -- Timer fires every companion_commentary_min_interval_s; additional checks apply.
    companion_commentary_enabled       = true,
    companion_commentary_min_interval_s = 600,   -- 10 min between timer checks
    companion_commentary_hard_cap_s    = 900,    -- 15 min hard cap between actual comments
    companion_commentary_probability   = 25,     -- percent chance when conditions are met
    companion_commentary_grace_period_s = 120,   -- no comments in first 2 min after recruitment
    companion_commentary_combat_block  = true,   -- suppress during active combat
}
