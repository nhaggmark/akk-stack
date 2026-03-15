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
        local channel = e.self:GetEntityVariable("gsay_response_channel")
        if channel == "group" then
            -- Clear immediately so a failed LLM call does not leave stale state
            e.self:SetEntityVariable("gsay_response_channel", "")
            -- Check for stagger delay (set by C++ on companions 2..N in @all)
            local stagger = e.self:GetEntityVariable("gsay_stagger_ms")
            if stagger ~= "" then
                e.self:SetEntityVariable("gsay_stagger_ms", "")
                local delay_ms = tonumber(stagger) or 0
                if delay_ms > 0 then
                    -- Defer delivery via timer; event_timer handles group:GroupMessage
                    e.self:SetEntityVariable("gsay_pending_response", response)
                    eq.set_timer("gsay_deliver_" .. e.self:GetID(), delay_ms)
                    if faction_data.max_responses then
                        llm_bridge.set_hostile_cooldown(e)
                    end
                    return
                end
            end
            -- Immediate group chat delivery
            local group = e.other:GetGroup()
            if group and group.valid then
                group:GroupMessage(e.self, response)
            else
                e.self:Say(response)
            end
        else
            e.self:Say(response)
        end
        -- Threatening NPCs (8): set cooldown after their single warning
        if faction_data.max_responses then
            llm_bridge.set_hostile_cooldown(e)
        end
    end
    -- Sidecar unavailable: silent fallthrough (NPC stays quiet, no error)
end

-- NPC model races that visually correspond to player races.
-- These NPCs use non-player race IDs in the database but look like (and behave as)
-- player races. GetPlayerRaceBit() returns 0 for all of them, which causes
-- IsEquipable() to reject ALL items regardless of the item's race flags.
-- Mapping these to their player race equivalents restores correct restriction checks.
-- For NPC races not in this table with raw_race > 16 (non-player races like skeletons,
-- dragons, etc.), the race check is bypassed entirely — class check still applies.
local NPC_RACE_TO_PLAYER_RACE = {
    [44]  = 1,   -- FreeportGuard    → Human
    [55]  = 1,   -- HumanBeggar      → Human
    [67]  = 1,   -- HighpassCitizen  → Human
    [71]  = 1,   -- QeynosCitizen    → Human
    [77]  = 6,   -- NeriakCitizen    → Dark Elf
    [78]  = 3,   -- EruditeCitizen   → Erudite
    [81]  = 11,  -- RivervaleCitizen → Halfling
    [90]  = 2,   -- HalasCitizen     → Barbarian
    [92]  = 9,   -- GrobbCitizen     → Troll
    [93]  = 10,  -- OggokCitizen     → Ogre
    [94]  = 8,   -- KaladimCitizen   → Dwarf
}

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

-- Determine the best equipment slot for this item based on its Slots bitmask.
-- Prefers empty slots over occupied ones for multi-slot items (rings, wrists).
-- Pass 1: return the first matching slot that is currently empty.
-- Pass 2: if all matching slots are occupied, return the first matching slot (will displace).
-- Returns slot_id (0-22) or nil if no valid equipment slot is found.
local function companion_find_slot(companion, slots_bitmask)
    local first_match = nil
    for slot_id = 0, 22 do
        if slot_id ~= 21 then  -- skip PowerSource
            local bit_set = math.floor(slots_bitmask / (2 ^ slot_id)) % 2
            if bit_set == 1 and COMPANION_SLOT_NAMES[slot_id] then
                if not first_match then
                    first_match = slot_id
                end
                -- Prefer this slot if it is empty
                if companion:GetEquipment(slot_id) == 0 then
                    return slot_id
                end
            end
        end
    end
    -- No empty slot found — fall back to the first matching slot (will displace)
    return first_match
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
    local had_money = false
    if e.trade.platinum and e.trade.platinum > 0 then
        e.other:AddMoneyToPP(0, 0, 0, e.trade.platinum, true)
        had_money = true
    end
    if e.trade.gold and e.trade.gold > 0 then
        e.other:AddMoneyToPP(0, 0, e.trade.gold, 0, true)
        had_money = true
    end
    if e.trade.silver and e.trade.silver > 0 then
        e.other:AddMoneyToPP(0, e.trade.silver, 0, 0, true)
        had_money = true
    end
    if e.trade.copper and e.trade.copper > 0 then
        e.other:AddMoneyToPP(e.trade.copper, 0, 0, 0, true)
        had_money = true
    end
    if had_money then
        e.other:Message(15, e.self:GetCleanName() .. " has no use for money.")
    end

    -- Equip each traded item
    local equipped_count = 0
    for i = 1, 4 do
        local inst = e.trade["item" .. i]
        if inst and inst.valid then
            local item_id = inst:GetID()
            if item_id and item_id ~= 0 then
                -- Wrap per-item processing in pcall so any unexpected Lua error
                -- returns the item to the player instead of losing it forever.
                -- (After event_trade returns, C++ unconditionally safe_delete's all
                -- trade slot instances — if we haven't SummonItem'd a rejected item
                -- by then, it's gone.)
                local item_equipped = false
                local ok, err = pcall(function()
                    local item_data = inst:GetItem()
                    local slots_bitmask = item_data and item_data:Slots() or 0
                    local slot_id = companion_find_slot(e.self, slots_bitmask)

                    if slot_id then
                        -- Fix: compare rule string to "true" — eq.get_rule() returns
                        -- a string like "true"/"false", not a boolean. In Lua, the
                        -- string "false" is truthy, so a bare truthiness check would
                        -- always enable restrictions regardless of the rule value.
                        local enforce_class = eq.get_rule("Companions:EnforceClassRestrictions") == "true"
                        local enforce_race  = eq.get_rule("Companions:EnforceRaceRestrictions") == "true"
                        if (enforce_class or enforce_race) and inst then
                            local raw_race   = e.self:GetRace()
                            local comp_class = e.self:GetClass()
                            -- Map NPC model race to its player race equivalent so
                            -- IsEquipable() receives a valid race ID. Without this,
                            -- citizen/guard NPCs (race 44, 67, 71, etc.) always fail
                            -- the race check because GetPlayerRaceBit() returns 0 for
                            -- any race ID that isn't a player race (1-12, 128, 130, 330, 522).
                            local mapped_race = NPC_RACE_TO_PLAYER_RACE[raw_race]
                            -- For genuinely non-player races (skeletons, dragons, etc.)
                            -- that have no player-race equivalent, bypass the race portion
                            -- of the check by using race 1 (Human), which passes all
                            -- race-flag values. Class restrictions still apply normally.
                            local check_race
                            if mapped_race then
                                check_race = mapped_race
                            elseif raw_race > 16 then
                                check_race = 1  -- bypass race check for unmappable NPC races
                            else
                                check_race = raw_race  -- player race IDs 1-16 pass through unchanged
                            end
                            -- Fix: use inst:IsEquipable() — IsEquipable lives on
                            -- Lua_ItemInst, not Lua_Item. Calling it on item_data
                            -- (a Lua_Item) would call nil and crash the handler.
                            if not inst:IsEquipable(check_race, comp_class) then
                                e.other:Message(15, e.self:GetCleanName() ..
                                    " cannot use that item (class/race restricted).")
                                e.other:SummonItem(item_id)
                                return  -- early return replaces goto continue
                            end
                        end

                        local slot_name = COMPANION_SLOT_NAMES[slot_id]
                        -- Return any item already in this slot before overwriting it.
                        -- Pre-check: only call GiveSlot if the slot is actually occupied.
                        -- This guards against double-dispatch (Candidate A in bug-018 plan):
                        -- if both a local event_trade handler and this global handler fire
                        -- for the same trade, the first pass empties the slot and the second
                        -- pass must not return a phantom item. GiveSlot has its own internal
                        -- guard (returns false on empty slot), but checking here prevents an
                        -- unnecessary C++ call and makes the intent explicit.
                        if e.self:GetEquipment(slot_id) ~= 0 then
                            e.self:GiveSlot(e.other, slot_name)
                        end
                        -- Equip the new item
                        local give_ok = e.self:GiveItem(item_id, slot_id)
                        if give_ok then
                            item_equipped = true
                            -- Return excess stack to the player. Companions only need
                            -- one instance of any stackable item (NPCs have infinite
                            -- ammo), so giving back charges-1 prevents item loss.
                            if inst:IsStackable() then
                                local charges = inst:GetCharges()
                                if charges and charges > 1 then
                                    e.other:SummonItem(item_id, charges - 1)
                                end
                            end
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
                end)

                if not ok then
                    -- Safety net: return item to player on any unexpected Lua error.
                    -- Log the error so it is visible to the GM/admin.
                    e.other:SummonItem(item_id)
                    e.other:Message(15, "[Error] Could not process item for " ..
                        e.self:GetCleanName() .. ". Item returned. (" ..
                        tostring(err) .. ")")
                elseif item_equipped then
                    equipped_count = equipped_count + 1
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

    -- Companion commentary timer setup.
    -- When a companion spawns (or enters a zone), start the periodic commentary
    -- check timer and record baseline entity variables for context change detection.
    if e.self:IsCompanion() then
        local now = tostring(os.time())
        local interval_ms = (llm_config.companion_commentary_min_interval_s or 600) * 1000
        local timer_name = "comp_commentary_" .. e.self:GetID()
        eq.set_timer(timer_name, interval_ms)
        e.self:SetEntityVariable("comp_spawn_time",        now)
        e.self:SetEntityVariable("comp_last_zone",         eq.get_zone_short_name())
        e.self:SetEntityVariable("comp_last_comment_time", "")
        e.self:SetEntityVariable("comp_named_kill",        "0")
        e.self:SetEntityVariable("comp_recent_kills",      "")
    end
end

-- Timer handler for companion unprompted commentary.
-- Fires every companion_commentary_min_interval_s for each companion entity.
function event_timer(e)
    -- gsay_deliver_<entity_id>: deferred group chat delivery for staggered @all LLM responses
    if e.timer and e.timer:sub(1, 13) == "gsay_deliver_" then
        eq.stop_timer(e.timer)
        local pending = e.self:GetEntityVariable("gsay_pending_response")
        if pending and pending ~= "" then
            e.self:SetEntityVariable("gsay_pending_response", "")
            local owner_id = e.self:GetOwnerCharacterID()
            local owner = owner_id ~= 0 and eq.get_entity_list():GetClientByCharID(owner_id) or nil
            if owner and owner.valid then
                local group = owner:GetGroup()
                if group and group.valid then
                    group:GroupMessage(e.self, pending)
                else
                    e.self:Say(pending)
                end
            end
        end
        return
    end

    -- Companion commentary timers are named "comp_commentary_<entity_id>"
    if e.timer and e.timer:sub(1, 16) == "comp_commentary_" and e.self:IsCompanion() then
        local ok, companion_commentary = pcall(require, "companion_commentary")
        if ok and companion_commentary then
            local ok_speak, err = pcall(companion_commentary.check_and_speak, e.self)
            if not ok_speak then
                eq.log(1, "companion commentary error: " .. tostring(err))
            end
        end
        -- Restart the timer for the next check cycle
        local interval_ms = (llm_config.companion_commentary_min_interval_s or 600) * 1000
        eq.set_timer(e.timer, interval_ms)
        return
    end

    -- comp_tome_restore_<entity_id>: restore stance after !tome passive override.
    -- !tome temporarily sets passive so Companion::Process() calls SetTarget(nullptr)
    -- on the next AI tick, breaking re-engage logic before this timer fires.
    -- After 500ms the original stance is restored here.
    if e.timer and e.timer:sub(1, 18) == "comp_tome_restore_" and e.self:IsCompanion() then
        eq.stop_timer(e.timer)
        local saved_raw = e.self:GetEntityVariable("comp_tome_saved_stance")
        local saved_stance = tonumber(saved_raw)
        if saved_stance and saved_stance ~= 0 then
            -- Only restore if still passive (another command may have changed stance)
            local cur_stance = e.self:GetStance()
            if cur_stance == 0 then
                e.self:SetStance(saved_stance)
            end
        end
        e.self:SetEntityVariable("comp_tome_saved_stance", "")
        return
    end

    -- Buff request timers are named "buff_request_<entity_id>"
    -- Fires when !buffme or !buffs sets buff_request_target entity variable.
    --
    -- Two-phase sequential queue to fix BUG-025:
    -- CastSpell() sets casting_spell_id on the first call; all subsequent calls in
    -- the same tick find it non-zero and silently return false. The original nested
    -- loop only ever cast the first spell on the first target.
    --
    -- Fix: build a queue of {spell_id, target_id} pairs (JSON in entity var), then
    -- process exactly ONE pair per timer tick. Re-arm at 2000ms until queue empty.
    --
    -- Phase 1 (buff_queue is empty): build queue, then fall through to Phase 2 to
    --   cast the first entry immediately (no extra 2s delay).
    -- Phase 2 (buff_queue is set): pop one entry, cast one spell, re-arm timer.
    --
    -- SpellType_Buff = (1<<3) = 8, SpellType_PreCombatBuff = (1<<20) = 1048576
    if e.timer and e.timer:sub(1, 13) == "buff_request_" and e.self:IsCompanion() then
        eq.stop_timer(e.timer)

        local request = e.self:GetEntityVariable("buff_request_target")
        if not request or request == "" then
            return  -- Request was cancelled or already processed
        end

        -- Retry cap: 30 retries * 2s = 60 seconds maximum wait
        local retries = tonumber(e.self:GetEntityVariable("buff_request_retries")) or 0
        if retries >= 30 then
            e.self:SetEntityVariable("buff_request_target", "")
            e.self:SetEntityVariable("buff_request_retries", "0")
            e.self:SetEntityVariable("buff_queue", "")
            e.self:SetEntityVariable("buff_queue_idx", "")
            local owner_id = e.self:GetOwnerCharacterID()
            if owner_id ~= 0 then
                local owner = eq.get_entity_list():GetClientByCharID(owner_id)
                if owner and owner.valid then
                    local group = owner:GetGroup()
                    if group and group.valid then
                        group:GroupMessage(e.self, e.self:GetCleanName() ..
                            " was unable to buff right now.")
                    end
                end
            end
            return
        end

        -- Wait until companion is idle (not in combat, not casting)
        if e.self:IsEngaged() or e.self:IsCasting() then
            e.self:SetEntityVariable("buff_request_retries", tostring(retries + 1))
            eq.set_timer(e.timer, 2000)
            return
        end

        -- Resolve owner
        local owner_id = e.self:GetOwnerCharacterID()
        if owner_id == 0 then
            e.self:SetEntityVariable("buff_request_target", "")
            e.self:SetEntityVariable("buff_request_retries", "0")
            e.self:SetEntityVariable("buff_queue", "")
            e.self:SetEntityVariable("buff_queue_idx", "")
            return
        end
        local owner = eq.get_entity_list():GetClientByCharID(owner_id)
        if not owner or not owner.valid then
            e.self:SetEntityVariable("buff_request_target", "")
            e.self:SetEntityVariable("buff_request_retries", "0")
            e.self:SetEntityVariable("buff_queue", "")
            e.self:SetEntityVariable("buff_queue_idx", "")
            return
        end

        local json = require("json")

        -- Phase 1: Build the queue if it doesn't exist yet.
        -- Runs once per !buffs or !buffme command. Builds the full ordered list of
        -- {spell_id, target_id} pairs and stores it as JSON in buff_queue.
        local queue_raw = e.self:GetEntityVariable("buff_queue")
        if not queue_raw or queue_raw == "" then
            -- Build target list based on request type
            local target_ids = {}
            if request == "owner" then
                target_ids[#target_ids + 1] = owner:GetID()
            else
                -- "party": all group members including NPC companions
                local group = owner:GetGroup()
                if group and group.valid then
                    for i = 0, 5 do
                        local member = group:GetMember(i)
                        if member and member.valid then
                            target_ids[#target_ids + 1] = member:GetID()
                        end
                    end
                else
                    target_ids[#target_ids + 1] = owner:GetID()  -- solo: just owner
                end
            end

            -- Query companion_spell_sets for buff spells for this companion's class/level
            local comp_class = e.self:GetClass()
            local comp_level = e.self:GetLevel()
            local BUFF_TYPE_MASK = 8 + 1048576  -- SpellType_Buff | SpellType_PreCombatBuff

            local db = Database()
            local stmt = db:prepare(
                "SELECT spell_id FROM companion_spell_sets " ..
                "WHERE class_id = ? AND min_level <= ? AND max_level >= ? " ..
                "AND (spell_type & ?) > 0 " ..
                "ORDER BY priority ASC, id ASC"
            )
            stmt:execute({comp_class, comp_level, comp_level, BUFF_TYPE_MASK})

            -- Build ordered list: for each spell, queue it for each target.
            -- Spell-major order: cast spell 1 on all targets, then spell 2, etc.
            local queue = {}
            local row = stmt:fetch_hash()
            while row do
                local spell_id = tonumber(row.spell_id)
                if spell_id and spell_id > 0 then
                    for _, target_id in ipairs(target_ids) do
                        queue[#queue + 1] = {spell_id, target_id}
                    end
                end
                row = stmt:fetch_hash()
            end
            db:close()

            if #queue == 0 then
                -- No buff spells found — notify and clean up
                e.self:SetEntityVariable("buff_request_target", "")
                e.self:SetEntityVariable("buff_request_retries", "0")
                local grp = owner:GetGroup()
                if grp and grp.valid then
                    grp:GroupMessage(e.self, e.self:GetCleanName() ..
                        " has no buff spells available.")
                end
                return
            end

            -- Store queue and initialize index
            e.self:SetEntityVariable("buff_queue", json.encode(queue))
            e.self:SetEntityVariable("buff_queue_idx", "1")
            queue_raw = e.self:GetEntityVariable("buff_queue")
        end

        -- Phase 2: Process one entry from the queue.
        local queue = json.decode(queue_raw)
        local idx = tonumber(e.self:GetEntityVariable("buff_queue_idx")) or 1

        if idx > #queue then
            -- Queue exhausted — clean up all state
            e.self:SetEntityVariable("buff_request_target", "")
            e.self:SetEntityVariable("buff_request_retries", "0")
            e.self:SetEntityVariable("buff_queue", "")
            e.self:SetEntityVariable("buff_queue_idx", "")
            return
        end

        -- Pop current entry: {spell_id, target_id}
        local entry = queue[idx]
        local spell_id = entry[1]
        local target_id = entry[2]

        -- Re-validate target each tick (may have died or zoned since queue was built)
        local target = eq.get_entity_list():GetMobByID(target_id)
        if target and target.valid and target:GetHP() > 0 then
            e.self:CastSpell(spell_id, target_id, 7)  -- slot 7 = misc spell slot
        end
        -- Skip invalid targets silently — advance index regardless

        -- Advance index
        e.self:SetEntityVariable("buff_queue_idx", tostring(idx + 1))

        -- Re-arm timer: if this was the last entry the next tick will hit the
        -- idx > #queue cleanup branch above and stop cleanly.
        eq.set_timer(e.timer, 2000)
        return
    end
end

-- Level-up handler: fire personalized LLM dialogue when a companion gains a level.
-- Companions are NPCs, so NPC event_level_up fires (not player event_level_up).
-- Uses companion_culture "level_up" event type for appropriate framing.
function event_level_up(e)
    if not e.self:IsCompanion() then return end

    local owner_char_id = e.self:GetOwnerCharacterID()
    if not owner_char_id or owner_char_id == 0 then return end
    local client = eq.get_entity_list():GetClientByCharID(owner_char_id)
    if not client or not client.valid then return end

    local fake_e = { self = e.self, other = client }
    local ok_ctx, context = pcall(function()
        return llm_bridge.build_context(fake_e)
    end)
    if not ok_ctx or not context then return end

    -- Override type_framing with level-up event-specific guidance.
    -- companion_culture.get_companion_context() returns the assembled system-prompt
    -- text (type framing + evolution + event prompt) for the "level_up" event.
    local ok_cc, culture_lib = pcall(require, "companion_culture")
    if ok_cc and culture_lib then
        local ok_ctx2, event_text = pcall(function()
            return culture_lib.get_companion_context(e.self, client, "level_up", {
                companion_type = context.companion_type or 0,
                time_active    = context.time_active_seconds or 0,
            })
        end)
        if ok_ctx2 and event_text then
            context.type_framing = event_text
        end
    end

    -- Mark as unprompted so sidecar keeps it to 1 sentence
    context.unprompted = true

    local ok_gen, response = pcall(function()
        return llm_bridge.generate_response(context, "[level_up]")
    end)

    if ok_gen and response then
        local group = client:GetGroup()
        if group and group.valid then
            group:GroupMessage(e.self, response)
        else
            e.self:Say(response)
        end
    end
end

-- Zone-wide death tracking for companion recent-kill context.
-- When any NPC dies in the zone, update all companion entities with the kill.
-- Tracks the last 5 killed NPC names in "comp_recent_kills" entity variable.
function event_death_zone(e)
    if not e.self then return end

    -- Skip companions, pets, and unnamed targets (no interesting context)
    if e.self:IsCompanion() then return end
    if e.self:IsPet() then return end

    local killed_name = e.self:GetCleanName()
    if not killed_name or killed_name == "" then return end

    -- Check if this was a named NPC (first letter uppercase and not "a "/"an " prefix)
    local is_named = not (killed_name:sub(1, 2) == "a " or killed_name:sub(1, 3) == "an ")

    -- Update all companions currently in the zone
    local clients = eq.get_entity_list():GetClientList()
    if not clients then return end

    for client in clients.entries do
        if client and client.valid then
            local group = client:GetGroup()
            if group and group.valid then
                for i = 0, 5 do
                    local member = group:GetMember(i)
                    if member and member.valid then
                        local ok_comp, is_comp = pcall(function() return member:IsCompanion() end)
                        if ok_comp and is_comp then
                            -- Update recent kills list (last 5, comma-separated)
                            local kills_raw = member:GetEntityVariable("comp_recent_kills")
                            local kills = {}
                            if kills_raw and kills_raw ~= "" then
                                for name in kills_raw:gmatch("[^,]+") do
                                    kills[#kills + 1] = name
                                end
                            end
                            kills[#kills + 1] = killed_name
                            -- Keep only last 5
                            if #kills > 5 then
                                local trimmed = {}
                                for i = #kills - 4, #kills do
                                    trimmed[#trimmed + 1] = kills[i]
                                end
                                kills = trimmed
                            end
                            member:SetEntityVariable("comp_recent_kills", table.concat(kills, ","))

                            -- Flag named kills for commentary trigger
                            if is_named then
                                member:SetEntityVariable("comp_named_kill", "1")
                            end
                        end
                    end
                end
            end
        end
    end
end
