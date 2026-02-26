-- llm_bridge.lua
-- Bridge between EQEmu Lua quest scripts and the NPC LLM sidecar service.
-- Called from global_npc.lua event_say for NPCs without local quest scripts.

local json = require("json")
local config = require("llm_config")
local faction_map = require("llm_faction")

local llm_bridge = {}

-- Check if this NPC has a local quest script (Lua or Perl).
-- EQEmu fires both local and global event_say; we must skip LLM for scripted NPCs.
local function has_local_script(e)
    local zone = eq.get_zone_short_name()
    local name = e.self:GetCleanName():gsub(" ", "_")
    local base = "/home/eqemu/server/quests/" .. zone .. "/" .. name
    for _, ext in ipairs({".lua", ".pl"}) do
        local f = io.open(base .. ext, "r")
        if f then f:close() return true end
    end
    return false
end

-- Check if an NPC is eligible for LLM-generated dialogue.
-- Filters: local script, global enabled flag, NPC intelligence, body type exclusions, per-NPC opt-out.
function llm_bridge.is_eligible(e)
    if not config.enabled then return false end

    -- Skip NPCs that have their own quest scripts
    if has_local_script(e) then return false end

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
        npc_primary_faction = e.self:GetPrimaryFaction(),
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
function llm_bridge.generate_response(context, message)
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

    local handle = io.popen(cmd)
    if not handle then return nil end

    local result = handle:read("*a")
    handle:close()

    if not result or result == "" then return nil end

    local ok, decoded = pcall(json.decode, result)
    if not ok or not decoded then return nil end

    -- decoded.response may be json.null if sidecar returned {"response": null}
    if decoded.response == nil or decoded.response == json.null then return nil end

    return decoded.response
end

return llm_bridge
