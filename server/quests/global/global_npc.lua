local llm_bridge = require("llm_bridge")
local llm_config = require("llm_config")
local llm_faction = require("llm_faction")
local companion_lib = require("companion")

-- LLM fallback for NPCs without local scripts.
-- Fires only when no per-NPC or per-zone quest script handles the event first.
function event_say(e)
    -- Companion prefix commands: intercept BEFORE LLM block.
    -- !-prefixed messages are commands; everything else flows to LLM for conversation.
    if e.self:IsCompanion() then
        if e.message:sub(1, 1) == "!" then
            companion_lib.dispatch_prefix_command(e.self, e.other, e.message)
            return
        end
        -- Non-prefixed: fall through to LLM block below for natural conversation
    end

    -- Recruitment keywords: intercept BEFORE LLM block.
    -- Only attempt recruitment on non-companion NPCs.
    if not e.self:IsCompanion() and companion_lib.is_recruitment_keyword(e.message) then
        companion_lib.attempt_recruitment(e.self, e.other)
        return
    end

    -- Check if LLM is enabled and NPC is eligible (INT, body type, opt-out)
    if not llm_bridge.is_eligible(e) then return end

    -- Get faction data for this player/NPC pair
    local faction_level = e.other:GetFaction(e.self)
    local faction_data = llm_faction[faction_level] or llm_faction[5]

    -- Check hostile cooldown (Threatening/Scowling NPCs ignore repeated speech)
    if llm_bridge.check_hostile_cooldown(e, faction_level) then return end

    -- Scowling (9): hostile emote only, no verbal response
    if faction_data.no_verbal then
        llm_bridge.send_hostile_emote(e)
        llm_bridge.set_hostile_cooldown(e)
        return
    end

    -- Send speaker-only "thinking" indicator before the blocking sidecar call
    llm_bridge.send_thinking_indicator(e)

    -- Build context and call sidecar
    local context = llm_bridge.build_context(e)
    local response = llm_bridge.generate_response(context, e.message)

    if response then
        e.self:Say(response)
        -- Threatening NPCs (8): set cooldown after their single warning
        if faction_data.max_responses then
            llm_bridge.set_hostile_cooldown(e)
        end
    end
    -- Sidecar unavailable: silent fallthrough (NPC stays quiet, no error)
end

function event_spawn(e)
    -- peq_halloween
    if (eq.is_content_flag_enabled("peq_halloween")) then
        -- exclude mounts and pets
        if (e.self:GetCleanName():findi("mount") or e.self:IsPet()) then
            return;
        end

        -- soulbinders
        -- priest of discord
        if (e.self:GetCleanName():findi("soulbinder") or e.self:GetCleanName():findi("priest of discord")) then
            e.self:ChangeRace(eq.ChooseRandom(14,60,82,85));
            e.self:ChangeSize(6);
            e.self:ChangeTexture(1);
            e.self:ChangeGender(2);
        end

        -- Shadow Haven
        -- The Bazaar
        -- The Plane of Knowledge
        -- Guild Lobby
        local halloween_zones = eq.Set { 202, 150, 151, 344 }
        local not_allowed_bodytypes = eq.Set { 11, 60, 66, 67 }
        if (halloween_zones[eq.get_zone_id()] and not_allowed_bodytypes[e.self:GetBodyType()] == nil) then
            e.self:ChangeRace(eq.ChooseRandom(14,60,82,85));
            e.self:ChangeSize(6);
            e.self:ChangeTexture(1);
            e.self:ChangeGender(2);
        end
    end
end
