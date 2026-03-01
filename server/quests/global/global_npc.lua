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
    local elig_ok, elig_err = pcall(function() return llm_bridge.is_eligible(e) end)
    if not elig_ok then
        e.other:Message(15, "[DEBUG] is_eligible error: " .. tostring(elig_err))
        return
    end
    if not llm_bridge.is_eligible(e) then return end

    -- Get faction data for this player/NPC pair
    local fac_ok, faction_level = pcall(function() return e.other:GetFaction(e.self) end)
    if not fac_ok then
        e.other:Message(15, "[DEBUG] GetFaction error: " .. tostring(faction_level))
        faction_level = 5 -- default to indifferent
    end
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
    local ctx_ok, context = pcall(function() return llm_bridge.build_context(e) end)
    if not ctx_ok then
        e.other:Message(15, "[DEBUG] build_context error: " .. tostring(context))
        return
    end
    local gen_ok, response = pcall(function() return llm_bridge.generate_response(context, e.message) end)
    if not gen_ok then
        e.other:Message(15, "[DEBUG] generate_response error: " .. tostring(response))
        return
    end

    if response then
        e.self:Say(response)
        -- Threatening NPCs (8): set cooldown after their single warning
        if faction_data.max_responses then
            llm_bridge.set_hostile_cooldown(e)
        end
    end
    -- Sidecar unavailable: silent fallthrough (NPC stays quiet, no error)
end

-- Slot integer -> name string for GiveSlot (must match SlotNameToSlotID in companion.cpp).
-- PowerSource (21) is intentionally omitted — companions do not use it.
local COMPANION_SLOT_NAMES = {
    [0]  = "charm",    [1]  = "ear1",    [2]  = "head",    [3]  = "face",
    [4]  = "ear2",     [5]  = "neck",    [6]  = "shoulder",[7]  = "arms",
    [8]  = "back",     [9]  = "wrist1",  [10] = "wrist2",  [11] = "range",
    [12] = "hands",    [13] = "primary", [14] = "secondary",[15] = "finger1",
    [16] = "finger2",  [17] = "chest",   [18] = "legs",    [19] = "feet",
    [20] = "waist",    [22] = "ammo",
}

-- Determine the first equipment slot valid for this item based on its Slots bitmask.
-- Returns slot_id (0-22) or nil if no valid equipment slot is found.
local function companion_find_slot(slots_bitmask)
    for slot_id = 0, 22 do
        if slot_id ~= 21 then  -- skip PowerSource
            local bit_set = math.floor(slots_bitmask / (2 ^ slot_id)) % 2
            if bit_set == 1 and COMPANION_SLOT_NAMES[slot_id] then
                return slot_id
            end
        end
    end
    return nil
end

-- Trade handler: equip items traded to a companion by their owner.
-- Non-companion NPCs: ignored (items are returned automatically by the engine).
function event_trade(e)
    if not e.self:IsCompanion() then
        return
    end

    -- Ownership check: only the owner may trade equipment to their companion
    local owner_char_id = e.self:GetOwnerCharacterID()
    if owner_char_id == 0 or owner_char_id ~= e.other:CharacterID() then
        e.other:Message(15, "Only " .. e.self:GetCleanName() .. "'s owner can give them equipment.")
        -- Return all traded items to the sender
        for i = 1, 4 do
            local inst = e.trade["item" .. i]
            if inst and inst.valid and inst:GetID() ~= 0 then
                e.other:SummonItem(inst:GetID())
            end
        end
        if e.trade.platinum and e.trade.platinum > 0 then
            e.other:AddMoneyToPP(0, 0, 0, e.trade.platinum, true)
        end
        return
    end

    -- Return any money (companions cannot hold coins)
    if e.trade.platinum and e.trade.platinum > 0 then
        e.other:AddMoneyToPP(0, 0, 0, e.trade.platinum, true)
    end
    if e.trade.gold and e.trade.gold > 0 then
        e.other:AddMoneyToPP(0, 0, e.trade.gold, 0, true)
    end
    if e.trade.silver and e.trade.silver > 0 then
        e.other:AddMoneyToPP(0, e.trade.silver, 0, 0, true)
    end
    if e.trade.copper and e.trade.copper > 0 then
        e.other:AddMoneyToPP(e.trade.copper, 0, 0, 0, true)
    end

    -- Equip each traded item
    local equipped_count = 0
    for i = 1, 4 do
        local inst = e.trade["item" .. i]
        if inst and inst.valid then
            local item_id = inst:GetID()
            if item_id and item_id ~= 0 then
                local item_data = inst:GetItem()
                local slots_bitmask = item_data and item_data:Slots() or 0
                local slot_id = companion_find_slot(slots_bitmask)

                if slot_id then
                    local slot_name = COMPANION_SLOT_NAMES[slot_id]
                    -- Return any item already in this slot before overwriting it
                    e.self:GiveSlot(e.other, slot_name)
                    -- Equip the new item
                    local ok = e.self:GiveItem(item_id, slot_id)
                    if ok then
                        equipped_count = equipped_count + 1
                    else
                        -- GiveItem rejected — return item to player
                        e.other:SummonItem(item_id)
                    end
                else
                    -- No valid equipment slot for this item
                    e.other:Message(15, e.self:GetCleanName() ..
                        " cannot equip that item.")
                    e.other:SummonItem(item_id)
                end
            end
        end
    end

    if equipped_count > 0 then
        e.self:Say("Thank you.")
    end
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
