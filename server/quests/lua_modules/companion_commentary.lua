-- companion_commentary.lua
-- Unprompted companion commentary system.
-- Called from global_npc.lua event_timer when the companion commentary timer fires.
--
-- Logic:
--   1. Is companion still alive and active? (not suspended, HP > 0)
--   2. Is companion NOT in combat? (blocked during active combat per config)
--   3. Has grace period elapsed since recruitment/spawn? (no comments too soon)
--   4. Has the hard cap elapsed since the last unprompted comment?
--   5. Has a significant context change occurred? (new zone, named kill, idle)
--   6. Random probability roll (25% when conditions are met)
--   If all pass: build context, call LLM bridge with unprompted=true, NPC says it.
--
-- Context changes tracked via NPC entity variables (set by global_npc.lua):
--   comp_spawn_time       — epoch when companion spawned/zoned in (string)
--   comp_last_zone        — zone short name when companion spawned (string)
--   comp_last_comment_time — epoch of last unprompted comment (string)
--   comp_named_kill       — set to "1" by event_death_zone when named NPC killed (string)
--   comp_recent_kills     — comma-separated last 5 NPC clean names (string)

local config = require("llm_config")
local llm_bridge = require("llm_bridge")

local companion_commentary = {}

-- Minimum seconds between commentary checks (from config, default 600 = 10 min)
local function get_min_interval()
    return config.companion_commentary_min_interval_s or 600
end

-- Hard cap seconds between actual comments (from config, default 900 = 15 min)
local function get_hard_cap()
    return config.companion_commentary_hard_cap_s or 900
end

-- Probability (0-100) of firing when conditions met (from config, default 25%)
local function get_probability()
    return config.companion_commentary_probability or 25
end

-- Grace period seconds after spawn before first comment (from config, default 120 = 2 min)
local function get_grace_period()
    return config.companion_commentary_grace_period_s or 120
end

-- ============================================================================
-- Context change detection
-- Returns true if a significant context change has occurred since the
-- companion last commented (worth generating an unprompted remark).
-- ============================================================================
function companion_commentary.detect_context_change(npc)
    local now = os.time()

    -- Zone change: companion is in a different zone than when it spawned
    local last_zone = npc:GetEntityVariable("comp_last_zone")
    local current_zone = eq.get_zone_short_name()
    if last_zone and last_zone ~= "" and last_zone ~= current_zone then
        return true, "zone_change"
    end

    -- Named kill: a named NPC was recently killed (set by event_death_zone)
    local named_kill = npc:GetEntityVariable("comp_named_kill")
    if named_kill == "1" then
        return true, "named_kill"
    end

    -- Extended idle: no combat for a long time (idle musing opportunity)
    -- Use 20 minutes of no commentary as idle trigger
    local last_comment_str = npc:GetEntityVariable("comp_last_comment_time")
    if last_comment_str and last_comment_str ~= "" then
        local last_comment = tonumber(last_comment_str)
        if last_comment and (now - last_comment) >= 1200 then  -- 20 minutes idle
            return true, "idle"
        end
    else
        -- Never commented — spawn was long enough ago; treat as idle
        local spawn_str = npc:GetEntityVariable("comp_spawn_time")
        if spawn_str and spawn_str ~= "" then
            local spawn_time = tonumber(spawn_str)
            if spawn_time and (now - spawn_time) >= 1200 then
                return true, "idle"
            end
        end
    end

    return false, nil
end

-- ============================================================================
-- Main check-and-speak function
-- Called from event_timer in global_npc.lua when the commentary timer fires.
-- npc: the companion NPC entity
-- ============================================================================
function companion_commentary.check_and_speak(npc)
    -- Guard: feature must be enabled
    if not config.companion_commentary_enabled then return end

    -- Guard: NPC must still be valid and alive
    if not npc or not npc.valid then return end
    local hp_ok, hp = pcall(function() return npc:GetHP() end)
    if not hp_ok or (hp and hp <= 0) then return end

    -- Guard: no commentary during combat (if configured)
    if config.companion_commentary_combat_block then
        local ok_eng, engaged = pcall(function() return npc:IsEngaged() end)
        if ok_eng and engaged then return end
    end

    local now = os.time()

    -- Guard: grace period — no comments too soon after spawn/recruitment
    local spawn_str = npc:GetEntityVariable("comp_spawn_time")
    if spawn_str and spawn_str ~= "" then
        local spawn_time = tonumber(spawn_str)
        if spawn_time and (now - spawn_time) < get_grace_period() then return end
    end

    -- Guard: hard cap — cannot comment again this soon
    local last_comment_str = npc:GetEntityVariable("comp_last_comment_time")
    if last_comment_str and last_comment_str ~= "" then
        local last_comment = tonumber(last_comment_str)
        if last_comment and (now - last_comment) < get_hard_cap() then return end
    end

    -- Check for a significant context change
    local has_change, change_type = companion_commentary.detect_context_change(npc)
    if not has_change then return end

    -- Probability roll
    if math.random(100) > get_probability() then return end

    -- Find the companion's owner client
    local owner_char_id = npc:GetOwnerCharacterID()
    if not owner_char_id or owner_char_id == 0 then return end

    local client = eq.get_entity_list():GetClientByCharID(owner_char_id)
    if not client or not client.valid then return end

    -- Build context with unprompted=true flag
    -- We simulate an event-table-like structure for build_context
    local fake_e = { self = npc, other = client }
    local ok_ctx, context = pcall(function()
        return llm_bridge.build_context(fake_e)
    end)
    if not ok_ctx or not context then return end

    -- Mark as unprompted — sidecar uses this to generate short observational remarks
    context.unprompted = true
    context.unprompted_trigger = change_type or "idle"

    -- Generate the unprompted remark
    -- Use a brief synthetic "trigger" message rather than actual player speech
    local trigger_msg = "[unprompted]"
    local ok_gen, response = pcall(function()
        return llm_bridge.generate_response(context, trigger_msg)
    end)

    if ok_gen and response then
        -- Route through group chat to match all other companion dialogue.
        -- Falls back to npc:Say() only if the owner has no group.
        local group = client:GetGroup()
        if group and group.valid then
            group:GroupMessage(npc, response)
        else
            npc:Say(response)
        end
        -- Update last comment timestamp
        npc:SetEntityVariable("comp_last_comment_time", tostring(now))
        -- Update last zone to current (consumed the zone-change trigger)
        npc:SetEntityVariable("comp_last_zone", eq.get_zone_short_name())
        -- Clear named kill flag (consumed)
        npc:SetEntityVariable("comp_named_kill", "0")
    end
end

return companion_commentary
