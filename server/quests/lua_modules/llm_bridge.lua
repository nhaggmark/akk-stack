-- llm_bridge.lua
-- Bridge between EQEmu Lua quest scripts and the NPC LLM sidecar service.
-- Called from global_npc.lua event_say for NPCs whose local script lacks event_say.

local json = require("json")
local config = require("llm_config")
local faction_map = require("llm_faction")

local llm_bridge = {}

-- Cache for Perl script EVENT_SAY scan results. Keyed by npc_type_id.
-- Persists until #reloadquest clears the Lua module cache.
local _perl_say_cache = {}

-- Check if this NPC's loaded script has event_say defined.
-- Uses the Lua registry (same mechanism as C++ HasFunction) to detect Lua event_say.
-- Falls back to cached file scan for Perl scripts (which live in a separate interpreter).
-- Returns true only when a local say handler exists; false means LLM is allowed.
local function has_local_say_handler(e)
    local npc_id = e.self:GetNPCTypeID()

    -- 1. Probe Lua registry: EventNPCLocal ran first, so the script is already loaded.
    local reg = debug.getregistry()
    local pkg = reg["npc_" .. npc_id]
    if pkg then
        -- Script is loaded. Allow LLM only if there is no event_say function.
        return type(pkg.event_say) == "function"
    end

    -- 2. No Lua script loaded. Check for Perl script with EVENT_SAY (cached).
    if _perl_say_cache[npc_id] ~= nil then
        return _perl_say_cache[npc_id]
    end

    local zone = eq.get_zone_short_name()
    local name = e.self:GetCleanName():gsub(" ", "_")
    local base  = "/home/eqemu/server/quests/" .. zone .. "/"

    -- Check name-based Perl script first, then ID-based (e.g., 48030.pl).
    for _, pl_path in ipairs({ base .. name .. ".pl", base .. npc_id .. ".pl" }) do
        local f = io.open(pl_path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local has_say = content:find("EVENT_SAY") ~= nil
            _perl_say_cache[npc_id] = has_say
            return has_say
        end
    end

    -- 3. No local script at all — LLM is allowed.
    _perl_say_cache[npc_id] = false
    return false
end

-- Check if an NPC is eligible for LLM-generated dialogue.
-- Filters: local say handler, global enabled flag, NPC intelligence, body type exclusions, per-NPC opt-out.
function llm_bridge.is_eligible(e)
    if not config.enabled then return false end

    -- Companions are always eligible for LLM conversation.
    -- They retain their original NPC type ID, so the local-script and body-type
    -- filters would incorrectly reject them. Non-prefixed speech to a companion
    -- should always reach the LLM.
    if e.self:IsCompanion() then return true end

    -- Skip NPCs whose local script already handles event_say
    if has_local_say_handler(e) then return false end

    -- Sentience filter: low-INT creatures do not speak
    if e.self:GetINT() < config.min_npc_intelligence then return false end

    -- Body type filter: non-sentient creature types excluded
    local body_type = e.self:GetBodyType()
    if config.excluded_body_types[body_type] then return false end

    -- Per-NPC opt-out: data bucket "llm_enabled-{npc_type_id}" = "0" disables
    local opt_out = eq.get_data("llm_enabled-" .. e.self:GetNPCTypeID())
    if opt_out == "0" then return false end

    return true
end

-- Check if a hostile NPC is in cooldown for this player.
-- Entity variables are in-memory only — cooldown resets if NPC respawns.
function llm_bridge.check_hostile_cooldown(e, faction_level)
    if faction_level < 8 then return false end -- Only Threatening (8) or Scowling (9)

    local cooldown_key = "llm_cd_" .. e.other:CharacterID()
    local last_time = e.self:GetEntityVariable(cooldown_key)
    if last_time ~= "" then
        local elapsed = os.time() - tonumber(last_time)
        if elapsed < config.hostile_cooldown_seconds then
            return true -- Still in cooldown; suppress response
        end
    end
    return false
end

-- Set the hostile cooldown timestamp for this player on this NPC.
function llm_bridge.set_hostile_cooldown(e)
    local cooldown_key = "llm_cd_" .. e.other:CharacterID()
    e.self:SetEntityVariable(cooldown_key, tostring(os.time()))
end

-- Send a speaker-only "thinking" indicator message.
-- Uses e.other:Message() so only the speaking player sees it (not bystanders).
function llm_bridge.send_thinking_indicator(e)
    if not config.typing_indicator_enabled then return end
    local emote = config.thinking_emotes[math.random(#config.thinking_emotes)]
    e.other:Message(10, e.self:GetCleanName() .. " " .. emote)
end

-- Send a speaker-only hostile emote (for Scowling NPCs).
function llm_bridge.send_hostile_emote(e)
    local emote = config.hostile_emotes[math.random(#config.hostile_emotes)]
    e.other:Message(10, e.self:GetCleanName() .. " " .. emote)
end

-- Build the NPC context table to send to the sidecar.
-- Gathers faction data, NPC stats, player stats, and zone info.
function llm_bridge.build_context(e)
    local faction_level = e.other:GetFaction(e.self)
    local faction_data = faction_map[faction_level] or faction_map[5] -- default: indifferent

    return {
        npc_type_id = e.self:GetNPCTypeID(),
        npc_name = e.self:GetCleanName(),
        npc_race = e.self:GetRace(),
        npc_class = e.self:GetClass(),
        npc_level = e.self:GetLevel(),
        npc_int = e.self:GetINT(),
        npc_primary_faction = e.self.GetPrimaryFaction and e.self:GetPrimaryFaction() or 0,
        npc_gender = e.self:GetGender(),
        npc_is_merchant = (e.self:GetClass() == 41),
        npc_deity = e.self:GetDeity(),
        zone_short = eq.get_zone_short_name(),
        zone_long = eq.get_zone_long_name(),
        player_id = e.other:CharacterID(),
        player_name = e.other:GetCleanName(),
        player_race = e.other:GetRace(),
        player_class = e.other:GetClass(),
        player_level = e.other:GetLevel(),
        faction_level = faction_level,
        faction_tone = faction_data.tone,
        faction_instruction = faction_data.instruction,
    }
end

-- Build context for Tier 2 (scripted) NPCs with quest hints.
-- quest_hints: table of strings describing the quest and valid keywords.
-- quest_state: optional string describing current quest progress for this player.
-- Returns a context table with quest_hints and quest_state merged in.
function llm_bridge.build_quest_context(e, quest_hints, quest_state)
    local context = llm_bridge.build_context(e)
    context.quest_hints = quest_hints
    context.quest_state = quest_state
    return context
end

-- Call the LLM sidecar via curl and return the response string.
-- Returns nil on any error (sidecar down, timeout, bad JSON, nil response field).
-- Blocking: pauses zone process for up to config.timeout_seconds.
-- Failures are logged to QuestErrors (category 87) for zone-log visibility.
function llm_bridge.generate_response(context, message)
    local LOG_ERRORS = 87  -- Logs.QuestErrors: console + gmsay
    local LOG_DEBUG  = 38  -- Logs.QuestDebug: gmsay only

    local request = {
        npc_type_id         = context.npc_type_id,
        npc_name            = context.npc_name,
        npc_race            = context.npc_race,
        npc_class           = context.npc_class,
        npc_level           = context.npc_level,
        npc_int             = context.npc_int,
        npc_primary_faction = context.npc_primary_faction,
        npc_gender          = context.npc_gender,
        npc_is_merchant     = context.npc_is_merchant,
        npc_deity           = context.npc_deity,
        zone_short          = context.zone_short,
        zone_long           = context.zone_long,
        player_id           = context.player_id,
        player_name         = context.player_name,
        player_race         = context.player_race,
        player_class        = context.player_class,
        player_level        = context.player_level,
        faction_level       = context.faction_level,
        faction_tone        = context.faction_tone,
        faction_instruction = context.faction_instruction,
        quest_hints         = context.quest_hints or json.null,
        quest_state         = context.quest_state or json.null,
        message             = message,
    }

    local json_body = json.encode(request)
    -- Escape single quotes for POSIX shell: ' becomes '\''
    local escaped = json_body:gsub("'", "'\\''")

    local cmd = string.format(
        "curl -s --max-time %d -X POST -H 'Content-Type: application/json' -d '%s' %s/v1/chat 2>/dev/null",
        config.timeout_seconds,
        escaped,
        config.sidecar_url
    )

    local result = nil

    local handle = io.popen(cmd)
    if not handle then
        -- io.popen failed — fall back to os.execute + temp file
        eq.log(LOG_ERRORS, "llm_bridge: io.popen returned nil for NPC " ..
            tostring(context.npc_name) .. " — trying os.execute fallback")
        local tmp = os.tmpname()
        local exec_cmd = cmd:gsub("2>/dev/null", ">" .. tmp .. " 2>/dev/null")
        local rc = os.execute(exec_cmd)
        if rc == 0 then
            local f = io.open(tmp, "r")
            if f then
                result = f:read("*a")
                f:close()
            end
        else
            eq.log(LOG_ERRORS, "llm_bridge: os.execute fallback also failed for NPC " ..
                tostring(context.npc_name))
        end
        os.remove(tmp)
    else
        result = handle:read("*a")
        handle:close()
    end

    if not result or result == "" then
        eq.log(LOG_ERRORS, "llm_bridge: empty response from sidecar for NPC " ..
            tostring(context.npc_name) .. " player=" .. tostring(context.player_name))
        return nil
    end

    local ok, decoded = pcall(json.decode, result)
    if not ok or not decoded then
        eq.log(LOG_ERRORS, "llm_bridge: JSON decode failed for NPC " ..
            tostring(context.npc_name) .. " raw=" .. tostring(result):sub(1, 80))
        return nil
    end

    -- decoded.response may be json.null if sidecar returned {"response": null}
    if decoded.response == nil or decoded.response == json.null then
        eq.log(LOG_ERRORS, "llm_bridge: sidecar returned null response for NPC " ..
            tostring(context.npc_name) .. " player=" .. tostring(context.player_name))
        return nil
    end

    eq.log(LOG_DEBUG, "llm_bridge: response OK for NPC " ..
        tostring(context.npc_name) .. " player=" .. tostring(context.player_name))
    return decoded.response
end

return llm_bridge
