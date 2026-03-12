-- companion.lua
-- Core recruitment logic for the NPC companion system.
-- Called from global/global_npc.lua when recruitment/management keywords are detected.
--
-- Dependencies:
--   eq.*          - EQEmu Lua API (data buckets, rules, DB)
--   Database()    - Lua_Database class (prepared statements)
--
-- C++ API (Tasks 17/18 — confirmed binding names):
--   client:CreateCompanion(npc)          - Creates Companion from live NPC, returns Companion or nil.
--                                          Re-recruitment handled transparently: if is_dismissed=1 record
--                                          exists, C++ calls Load()+Unsuspend() automatically.
--   client:HasActiveCompanion(npc_type_id) - Returns bool
--   client:GetCompanionByNPCTypeID(npc_type_id) - Returns Companion or nil
--   companion:Dismiss(voluntary_bool)    - true=voluntary (earns re-recruit bonus), false=forced
--   companion:SetStance(stance_int)      - 0=passive, 1=balanced, 2=aggressive
--   companion:SoulWipe()                 - C++ cascade delete (Lua calls ChromaDB clear first)
--   npc:IsCompanion()                    - Returns true if this NPC is a Companion instance

local companion = {}

-- ============================================================================
-- Constants
-- ============================================================================

-- Recruitment keywords that trigger attempt_recruitment()
local RECRUIT_KEYWORDS = {
    "recruit", "join me", "come with me", "travel with me",
    "adventure with me", "will you join", "join my party",
    "join my group", "come along", "follow me"
}

-- Command prefix (finalized design decision — not a rule)
local COMMAND_PREFIX = "!"

-- Recall minimum distance in units (game design constraint — not configurable)
-- Below this distance !recall is rejected to prevent combat positioning abuse
local RECALL_MIN_DISTANCE = 200

-- Module-level guard/follow mode tracking
-- Keys are entity IDs (npc:GetID()), values are "follow" or "guard"
-- Reset on quest reload; default assumption is "follow"
local companion_modes = {}

-- Faction level -> recruitment bonus percentage
-- EQ faction: 1=Ally, 2=Warmly, 3=Kindly (lower = better faction)
local FACTION_BONUS = {
    [1] = 30,  -- Ally
    [2] = 20,  -- Warmly
    [3] = 10,  -- Kindly
    [4] = 0,   -- Amiably (not eligible, MinFaction=3)
    [5] = 0,   -- Indifferently (not eligible)
}

-- Disposition integer -> recruitment modifier percentage
-- Stored as npc entity variable "companion_disposition"
-- 4=Eager, 3=Restless, 2=Curious, 1=Content, 0=Rooted
local DISPOSITION_MODIFIER = {
    [4] = 25,   -- Eager
    [3] = 15,   -- Restless
    [2] = 5,    -- Curious
    [1] = -10,  -- Content
    [0] = -30,  -- Rooted
}

-- Level difference modifier (per level, deducted from roll)
local LEVEL_DIFF_MODIFIER = 5

-- Recruitment roll clamp [min, max] percent
local ROLL_MIN = 5
local ROLL_MAX = 95

-- Re-recruitment bonus (applied when is_dismissed=1 record exists)
local REREC_BONUS = 10

-- Combat role display names (maps Companion::GetCombatRole() uint8 return to display string)
-- Values mirror the CompanionCombatRole enum in companion.h:
--   0=COMBAT_ROLE_MELEE_TANK, 1=COMBAT_ROLE_MELEE_DPS, 2=COMBAT_ROLE_ROGUE,
--   3=COMBAT_ROLE_CASTER_DPS, 4=COMBAT_ROLE_HEALER
local COMBAT_ROLE_NAMES = {
    [0] = "Melee Tank",
    [1] = "Melee DPS",
    [2] = "Rogue",
    [3] = "Caster DPS",
    [4] = "Healer",
}

-- Command dispatch table: maps command names to handler function names and help categories.
-- requires_owner = false marks read-only informational commands that any player may use on
-- any companion they can target. Commands without this field default to owner-only.
local COMMANDS = {
    passive          = { handler = "cmd_passive",          category = "stance" },
    balanced         = { handler = "cmd_balanced",         category = "stance" },
    aggressive       = { handler = "cmd_aggressive",       category = "stance" },
    follow           = { handler = "cmd_follow",           category = "movement" },
    guard            = { handler = "cmd_guard",            category = "movement" },
    recall           = { handler = "cmd_recall",           category = "movement" },
    tome             = { handler = "cmd_tome",             category = "movement" },
    flee             = { handler = "cmd_flee",             category = "movement" },
    equipment        = { handler = "cmd_equipment",        category = "equipment",   requires_owner = false },
    gear             = { handler = "cmd_equipment",        category = "equipment",   requires_owner = false },  -- alias for !equipment
    equip            = { handler = "cmd_equip",            category = "equipment" },
    unequip          = { handler = "cmd_unequip",          category = "equipment" },
    unequipall       = { handler = "cmd_unequipall",       category = "equipment" },  -- alias for !unequip all
    equipmentupgrade = { handler = "cmd_equipmentupgrade", category = "equipment",   requires_owner = false },
    equipmentmissing = { handler = "cmd_equipmentmissing", category = "equipment",   requires_owner = false },
    stats            = { handler = "cmd_stats",            category = "information", requires_owner = false },
    status           = { handler = "cmd_status",           category = "information", requires_owner = false },
    help             = { handler = "cmd_help",             category = "information", requires_owner = false },
    target           = { handler = "cmd_target",           category = "combat" },
    assist           = { handler = "cmd_assist",           category = "combat" },
    buffme           = { handler = "cmd_buffme",           category = "buffs" },
    buffs            = { handler = "cmd_buffs",            category = "buffs" },
    dismiss          = { handler = "cmd_dismiss",          category = "control" },
}

-- ============================================================================
-- Keyword Detection (Recruitment Only)
-- ============================================================================

-- Returns true if the message contains a recruitment keyword
function companion.is_recruitment_keyword(message)
    if not message then return false end
    local msg = message:lower()
    for _, kw in ipairs(RECRUIT_KEYWORDS) do
        if msg:find(kw, 1, true) then
            return true
        end
    end
    return false
end

-- ============================================================================
-- Prefix Command Dispatch
-- ============================================================================

-- Main entry point for !-prefixed commands from global_npc.lua.
-- Called when e.self:IsCompanion() and message starts with "!".
-- Access control: read-only commands (requires_owner = false) are available to any
-- player targeting any companion. Owner-only commands check GetOwnerCharacterID() first.
function companion.dispatch_prefix_command(npc, client, message)
    -- Strip prefix and leading whitespace, parse command + args
    local body = message:sub(2):gsub("^%s+", "")
    if body == "" then
        -- Empty "!" with no command: show help (read-only, no ownership needed)
        companion.cmd_help(npc, client, "")
        return
    end

    local cmd, args = body:match("^(%S+)%s*(.*)")
    cmd = cmd:lower()

    local entry = COMMANDS[cmd]

    -- Ownership check: skip for read-only commands (requires_owner = false),
    -- enforce for all owner-only commands and unknown commands.
    if not (entry and entry.requires_owner == false) then
        if npc:GetOwnerCharacterID() ~= client:CharacterID() then
            client:Message(15, "That is not your companion.")
            return
        end
    end

    if entry then
        companion[entry.handler](npc, client, args or "")
    else
        client:Message(15, "Unknown command: !" .. cmd ..
                           ". Type !help for available commands.")
    end
end

-- ============================================================================
-- Eligibility Checks
-- ============================================================================

-- Returns true if the NPC passes all eligibility checks for recruitment.
-- Short-circuits in the documented order from the architecture spec.
-- Returns: eligible (bool), reason (string if not eligible)
function companion.is_eligible_npc(npc, client)
    -- 1. Companion system enabled
    if eq.get_rule("Companions:CompanionsEnabled") ~= "true" then
        return false, "The companion system is not available on this server."
    end

    -- 2. Group capacity (client group must have < 6 members)
    local group = client:GetGroup()
    if group then
        if group:GroupCount() >= 6 then
            return false, "Your party is full. Dismiss a companion or group member first."
        end
    end
    -- If client has no group, that's fine — companion will form/join a group

    -- 3. Not already recruited (NPC entity variable check)
    local is_recruited = npc:GetEntityVariable("is_recruited")
    if is_recruited and is_recruited ~= "" and is_recruited ~= "0" then
        return false, npc:GetName() .. " has already joined someone's party."
    end

    -- 4. Combat check — neither party can be in combat
    if npc:IsEngaged() then
        return false, npc:GetName() .. " is engaged in combat."
    end
    if client:GetAggroCount() > 0 then
        return false, "You cannot recruit while in combat."
    end

    -- 5. Level range check (0 = disabled, no restriction)
    local level_range = tonumber(eq.get_rule("Companions:LevelRange")) or 3
    if level_range > 0 then
        local player_level = client:GetLevel()
        local npc_level = npc:GetLevel()
        if math.abs(player_level - npc_level) > level_range then
            return false, npc:GetName() .. " is too far from your level to recruit."
        end
    end

    -- 6. Faction check (player faction with NPC's faction must be >= MinFaction)
    local min_faction = tonumber(eq.get_rule("Companions:MinFaction")) or 3
    local npc_faction_id = npc:GetNPCFactionID()
    if npc_faction_id and npc_faction_id > 0 then
        local player_faction = client:GetCharacterFactionLevel(npc_faction_id)
        -- EQ faction: 1=Ally(best), 6=Scowling(worst). min_faction=3 means Kindly or better.
        if not player_faction or player_faction > min_faction then
            return false, npc:GetName() .. " will not join you — your faction standing is too low."
        end
    end

    -- 7. NPC type check — IsPet(), IsBot(), IsMerc(), IsCompanion()
    if npc:IsPet() then
        return false, "Pets cannot be recruited as companions."
    end
    if npc:IsBot() then
        return false, "Bots cannot be recruited as companions."
    end
    if npc:IsMerc() then
        return false, "Mercenaries cannot be recruited as companions."
    end
    if npc:IsCompanion() then
        return false, npc:GetName() .. " is already someone's companion."
    end

    -- 8. Class exclusion (handled by companion_exclusions table)
    -- Class 40/41 (Banker/Merchant) and 20-35 (Guildmasters) are pre-seeded

    -- 9. Bodytype exclusion (handled by companion_exclusions table for bodytypes 11, 64+)
    -- Secondary check: catch any bodytype issues not pre-seeded
    local bodytype = npc:GetBodyType()
    if bodytype == 11 then  -- Untargetable
        return false, npc:GetName() .. " cannot be recruited."
    end

    -- 10. Exclusion table check
    local npc_type_id = npc:GetNPCTypeID()
    local db = Database()
    local stmt = db:prepare(
        "SELECT npc_type_id FROM companion_exclusions WHERE npc_type_id = ? LIMIT 1"
    )
    stmt:execute({npc_type_id})
    local excl_row = stmt:fetch_hash()
    db:close()
    if excl_row then
        return false, npc:GetName() .. " cannot be recruited."
    end

    -- 11. Froglok check (race 74 and 330 are also in exclusion table, but belt+suspenders)
    local race = npc:GetRace()
    if race == 74 or race == 330 then
        return false, npc:GetName() .. " cannot be recruited in this era."
    end

    return true, nil
end

-- ============================================================================
-- Persuasion Bonus Calculation
-- ============================================================================

-- Returns the persuasion bonus (integer percentage) for the player recruiting this NPC.
-- Sources: companion_culture_persuasion table for primary/secondary stat and type.
-- Returns 0 if no culture record found (CHA default applied).
function companion.get_persuasion_bonus(client, npc)
    local npc_race = npc:GetRace()
    local db = Database()
    local stmt = db:prepare(
        "SELECT primary_stat, secondary_type, secondary_stat " ..
        "FROM companion_culture_persuasion WHERE race_id = ? LIMIT 1"
    )
    stmt:execute({npc_race})
    local row = stmt:fetch_hash()
    db:close()

    if not row then
        -- Default: CHA-based, (CHA - 75) / 5
        local cha = client:GetCHA()
        return math.floor((cha - 75) / 5)
    end

    -- Primary stat contribution: (stat - 75) / 5
    local primary_bonus = 0
    local pstat = row.primary_stat
    if pstat == "CHA" then
        primary_bonus = math.floor((client:GetCHA() - 75) / 5)
    elseif pstat == "STR" then
        primary_bonus = math.floor((client:GetSTR() - 75) / 5)
    elseif pstat == "INT" then
        primary_bonus = math.floor((client:GetINT() - 75) / 5)
    end

    -- Secondary contribution
    local secondary_bonus = 0
    local stype = row.secondary_type
    if stype == "faction" then
        -- faction_level 1-5 scale (1=Ally, 5=Scowling). Invert so better faction = more bonus.
        local npc_faction_id = npc:GetNPCFactionID()
        if npc_faction_id and npc_faction_id > 0 then
            local fl = client:GetCharacterFactionLevel(npc_faction_id) or 5
            -- fl=1(Ally)=+10, fl=2(Warmly)=+8, fl=3(Kindly)=+6, fl=4(Amiably)=+4, fl=5=+2
            secondary_bonus = math.max(0, (6 - fl) * 2)
        end
    elseif stype == "level" then
        -- (player_level - npc_level), positive if player is higher
        secondary_bonus = client:GetLevel() - npc:GetLevel()
    elseif stype == "stat" then
        local sstat = row.secondary_stat
        local sval = 75
        if sstat == "STR" then sval = client:GetSTR()
        elseif sstat == "INT" then sval = client:GetINT()
        elseif sstat == "CHA" then sval = client:GetCHA()
        elseif sstat == "WIS" then sval = client:GetWIS()
        elseif sstat == "DEX" then sval = client:GetDEX()
        elseif sstat == "AGI" then sval = client:GetAGI()
        elseif sstat == "STA" then sval = client:GetSTA()
        end
        secondary_bonus = math.floor((sval - 75) / 10)
    end

    return primary_bonus + secondary_bonus
end

-- ============================================================================
-- Faction and Disposition Modifiers
-- ============================================================================

-- Returns faction bonus percentage for the recruitment roll
function companion.get_faction_bonus(client, npc)
    local npc_faction_id = npc:GetNPCFactionID()
    if not npc_faction_id or npc_faction_id == 0 then return 0 end
    local fl = client:GetCharacterFactionLevel(npc_faction_id) or 5
    return FACTION_BONUS[fl] or 0
end

-- Returns disposition modifier percentage from NPC soul element data
-- Disposition is stored as integer 0-4 on NPC entity variable "companion_disposition"
-- Default: Curious (2) if no soul element data exists
function companion.get_disposition_modifier(npc)
    local disp_str = npc:GetEntityVariable("companion_disposition")
    local disp = tonumber(disp_str)
    if not disp then disp = 2 end  -- Default: Curious
    disp = math.max(0, math.min(4, disp))
    return DISPOSITION_MODIFIER[disp] or 0
end

-- ============================================================================
-- Re-Recruitment Check
-- ============================================================================

-- Returns the dismissed companion_data record if one exists for this NPC+player pair.
-- Returns nil if no dismissed record found.
function companion.check_dismissed_record(npc_type_id, char_id)
    local db = Database()
    local stmt = db:prepare(
        "SELECT id, level, experience, recruited_level, stance, name, companion_type " ..
        "FROM companion_data " ..
        "WHERE owner_id = ? AND npc_type_id = ? AND is_dismissed = 1 LIMIT 1"
    )
    stmt:execute({char_id, npc_type_id})
    local row = stmt:fetch_hash()
    db:close()
    return row
end

-- ============================================================================
-- Main Recruitment Flow
-- ============================================================================

-- Main entry point called from global_npc.lua when a recruitment keyword is detected.
-- Handles eligibility, roll, cooldown, and success/failure messaging.
function companion.attempt_recruitment(npc, client)
    local npc_type_id = npc:GetNPCTypeID()
    local char_id = client:CharacterID()
    local npc_name = npc:GetName()

    -- Check cooldown (data bucket: companion_cooldown_{npc_type_id}_{char_id})
    local cooldown_key = "companion_cooldown_" .. npc_type_id .. "_" .. char_id
    local on_cooldown = eq.get_data(cooldown_key)
    if on_cooldown and on_cooldown ~= "" then
        npc:Say(npc_name .. " won't discuss joining you again so soon.")
        return
    end

    -- Eligibility check
    local eligible, reason = companion.is_eligible_npc(npc, client)
    if not eligible then
        client:Message(15, reason)
        return
    end

    -- Check for dismissed record (re-recruitment bonus)
    local dismissed_record = companion.check_dismissed_record(npc_type_id, char_id)

    -- Calculate recruitment roll
    local base = tonumber(eq.get_rule("Companions:BaseRecruitChance")) or 50
    local faction_bonus = companion.get_faction_bonus(client, npc)
    local disposition_mod = companion.get_disposition_modifier(npc)
    local persuasion_bonus = companion.get_persuasion_bonus(client, npc)
    local level_diff = math.abs(client:GetLevel() - npc:GetLevel())
    local level_penalty = level_diff * LEVEL_DIFF_MODIFIER
    local rerec_bonus = dismissed_record and REREC_BONUS or 0

    local roll_chance = base + faction_bonus + disposition_mod + persuasion_bonus
                        - level_penalty + rerec_bonus
    roll_chance = math.max(ROLL_MIN, math.min(ROLL_MAX, roll_chance))

    -- Roll
    local roll = math.random(1, 100)
    local success = roll <= roll_chance

    if success then
        companion._on_recruitment_success(npc, client, dismissed_record)
    else
        companion._on_recruitment_failure(npc, client, cooldown_key)
    end
end

-- Called on successful recruitment roll
function companion._on_recruitment_success(npc, client, dismissed_record)
    local npc_name = npc:GetName()

    -- Mark NPC as recruited to prevent duplicate recruitment attempts while C++ processes
    npc:SetEntityVariable("is_recruited", "1")

    -- Create companion via C++ API (Task 17: client:CreateCompanion(npc))
    -- Re-recruitment is handled transparently: if is_dismissed=1 record exists for this
    -- npc_type_id + owner, C++ detects it, calls Load()+Unsuspend() to restore full state
    -- (level, XP, equipment, buffs). No extra parameters needed for re-recruitment.
    local companion_entity = client:CreateCompanion(npc)
    if not companion_entity then
        client:Message(15, "Something went wrong. " .. npc_name .. " could not join you.")
        npc:SetEntityVariable("is_recruited", "0")
        return
    end

    -- Brief in-character acknowledgment (LLM will provide richer flavor via companion_culture.lua)
    if not dismissed_record then
        npc:Say("I will join you.")
    else
        npc:Say("I remember you. Let us continue.")
    end
end

-- Called on failed recruitment roll
function companion._on_recruitment_failure(npc, client, cooldown_key)
    -- Set cooldown
    local cooldown_s = tonumber(eq.get_rule("Companions:RecruitCooldownS")) or 900
    eq.set_data(cooldown_key, "1", tostring(cooldown_s))

    -- Brief refusal (LLM will provide richer flavor dialogue via companion_culture.lua)
    npc:Say("I will not join you.")
end

-- ============================================================================
-- Command Handlers (! prefix system)
-- ============================================================================

-- Helper: send a message in group chat from the companion.
-- Mirrors the non-stagger path in global_npc.lua:event_say().
-- Falls back to npc:Say() if the owner has no group (should not happen in practice).
local function companion_say(npc, client, msg)
    local group = client:GetGroup()
    if group and group.valid then
        group:GroupMessage(npc, msg)
    else
        npc:Say(msg)
    end
end

-- Stance: set companion to passive (disengage, follow owner)
function companion.cmd_passive(npc, client, args)
    if npc.SetStance then npc:SetStance(0) end  -- nil-guard: SetStance is Companion-only; Lua_NPC cast drops it
    npc:WipeHateList()
    npc:Say("I will stand down.")
end

-- Stance: set companion to balanced (default combat behavior)
-- Response splits by companion_type: loyal = relational, mercenary = neutral
function companion.cmd_balanced(npc, client, args)
    if npc.SetStance then npc:SetStance(1) end  -- nil-guard: SetStance is Companion-only; Lua_NPC cast drops it
    local companion_type = npc.GetCompanionType and npc:GetCompanionType() or 0  -- nil-guard: GetCompanionType is Companion-only; default 0 (loyal)
    if companion_type == 0 then
        npc:Say("I will fight at your side.")
    else
        npc:Say("Understood.")
    end
end

-- Stance: set companion to aggressive (actively pursue enemies)
function companion.cmd_aggressive(npc, client, args)
    if npc.SetStance then npc:SetStance(2) end  -- nil-guard: SetStance is Companion-only; Lua_NPC cast drops it
    npc:Say("Understood. I will fight aggressively.")
end

-- Movement: resume following owner at standard distance
function companion.cmd_follow(npc, client, args)
    if npc:GetHP() <= 0 then
        companion_say(npc, client, npc:GetCleanName() .. " is dead and cannot follow.")
        return
    end
    if npc.SetGuardMode then npc:SetGuardMode(false) end  -- nil-guard: SetGuardMode is Companion-only; Lua_NPC cast drops it
    companion_modes[npc:GetID()] = "follow"
    companion_say(npc, client, npc:GetCleanName() .. " will follow you.")
end

-- Movement: hold current position, stop following
function companion.cmd_guard(npc, client, args)
    if npc.SetGuardMode then npc:SetGuardMode(true) end  -- nil-guard: SetGuardMode is Companion-only; Lua_NPC cast drops it
    companion_modes[npc:GetID()] = "guard"
    npc:Say("I will hold here.")
end

-- Movement: teleport companion to player location (only if far enough away)
function companion.cmd_recall(npc, client, args)
    local cooldown_s = tonumber(eq.get_rule("Companions:RecallCooldownS")) or 30
    local companion_id = npc.GetCompanionID and npc:GetCompanionID() or 0  -- nil-guard: GetCompanionID is Companion-only; Lua_NPC cast drops it
    local cd_key = "companion_recall_cd_" ..
                   companion_id .. "_" .. client:CharacterID()

    -- Cooldown check
    local on_cd = eq.get_data(cd_key)
    if on_cd and on_cd ~= "" then
        client:Message(15, "Recall is on cooldown.")
        return
    end

    -- Distance check: RECALL_MIN_DISTANCE prevents combat positioning abuse
    local dist = npc:CalculateDistance(client)
    if dist < RECALL_MIN_DISTANCE then
        client:Message(15, "Your companion is already nearby.")
        return
    end

    -- Teleport to player position and reset to follow mode
    npc:GMMove(client:GetX(), client:GetY(), client:GetZ(), client:GetHeading())
    companion_modes[npc:GetID()] = "follow"
    npc:Say("I am here.")

    -- Set cooldown via data bucket TTL
    eq.set_data(cd_key, "1", tostring(cooldown_s))
end

-- Equipment: display all equipped items
function companion.cmd_equipment(npc, client, args)
    npc:ShowEquipment(client)
end

-- Equipment: deferred — display instructions to use trade window instead
function companion.cmd_equip(npc, client, args)
    client:Message(15, "To give items to your companion: pick up the item from")
    client:Message(15, "your inventory (left-click to place it on your cursor),")
    client:Message(15, "then left-click your companion to open the trade window.")
    client:Message(15, "Place items and click Trade. They will be auto-equipped.")
end

-- Equipment: return item from a named slot, or all items if slot is "all"
function companion.cmd_unequip(npc, client, args)
    local slot_name = args:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if slot_name == "" then
        client:Message(15, "Usage: !unequip <slot> or !unequip all")
        client:Message(15, "Valid slots: primary, secondary, head, chest, " ..
                           "arms, wrist1, wrist2, hands, legs, feet, " ..
                           "charm, ear1, ear2, face, neck, shoulder, " ..
                           "back, finger1, finger2, range, waist, ammo")
        return
    end
    if slot_name == "all" then
        npc:Say("As you wish.")
        npc:GiveAll(client)
    else
        local returned = npc:GiveSlot(client, slot_name)
        if not returned then
            client:Message(15, npc:GetCleanName() .. " has nothing equipped in that slot.")
        end
    end
end

-- Equipment: return all equipped items (alias for !unequip all)
function companion.cmd_unequipall(npc, client, args)
    companion.cmd_unequip(npc, client, "all")
end

-- Information: show companion status overview (group chat, enhanced with buffs/target/state)
function companion.cmd_status(npc, client, args)
    local stance_names = { [0] = "Passive", [1] = "Balanced", [2] = "Aggressive" }
    local type_names   = { [0] = "Companion", [1] = "Mercenary" }
    local name = npc:GetCleanName()

    -- Dead check
    if npc:GetHP() <= 0 then
        companion_say(npc, client, "=== " .. name .. " [DEAD] ===")
        companion_say(npc, client, "  Level: " .. npc:GetLevel() ..
                                   "  Class: " .. npc:GetClassName())
        return
    end

    -- HP line (always show percentage)
    local max_hp = npc:GetMaxHP()
    local cur_hp = npc:GetHP()
    local hp_pct = max_hp > 0 and math.floor(cur_hp / max_hp * 100) or 0
    local hp_str = "HP: " .. cur_hp .. "/" .. max_hp .. " (" .. hp_pct .. "%)"

    -- Mana line (show N/A for pure melee)
    local max_mana = npc:GetMaxMana()
    local mana_str
    if max_mana == 0 then
        mana_str = "Mana: N/A"
    else
        local cur_mana = npc:GetMana()
        local mana_pct = math.floor(cur_mana / max_mana * 100)
        mana_str = "Mana: " .. cur_mana .. "/" .. max_mana .. " (" .. mana_pct .. "%)"
    end

    -- Target
    local target_mob = npc:GetTarget()
    local target_str = (target_mob and target_mob.valid) and target_mob:GetCleanName() or "None"

    -- Sit/stand state
    local state_str = npc:IsSitting() and "Sitting" or "Standing"

    -- Follow/guard mode
    local mode = companion_modes[npc:GetID()] or "follow"
    mode = mode:sub(1, 1):upper() .. mode:sub(2)

    -- Stance (nil-guard: GetStance is Companion-only; Lua_NPC cast drops it; default 1 = balanced)
    local stance_str = stance_names[npc.GetStance and npc:GetStance() or 1] or "Unknown"

    -- XP
    local current_xp    = npc:GetCompanionXP()
    local next_level_xp = npc:GetXPForNextLevel()

    companion_say(npc, client, "=== " .. name .. " ===")
    -- nil-guard: GetCompanionType is Companion-only; Lua_NPC cast drops it; default 0 (loyal)
    companion_say(npc, client, "  Level: " .. npc:GetLevel() ..
                               "  Class: " .. npc:GetClassName() ..
                               "  Type: " .. (type_names[npc.GetCompanionType and npc:GetCompanionType() or 0] or "Unknown"))
    companion_say(npc, client, "  " .. hp_str)
    companion_say(npc, client, "  " .. mana_str)
    companion_say(npc, client, "  XP: " .. current_xp .. " / " .. next_level_xp)
    companion_say(npc, client, "  Stance: " .. stance_str ..
                               "  Mode: " .. mode ..
                               "  State: " .. state_str)
    companion_say(npc, client, "  Target: " .. target_str)

    -- Buff list
    local buffs = npc:GetBuffs()
    if buffs then
        local buff_lines = {}
        for _, buff in pairs(buffs) do
            if buff and buff.valid then
                local spell_id = buff:GetSpellID()
                if spell_id and spell_id > 0 then
                    local spell_name = eq.get_spell_name(spell_id) or ("Spell " .. spell_id)
                    local tics = buff:GetTicsRemaining()
                    local dur_str
                    if tics and tics > 0 then
                        local secs = tics * 6
                        if secs < 60 then
                            dur_str = "<1 min"
                        else
                            dur_str = math.floor(secs / 60) .. " min"
                        end
                    else
                        dur_str = "permanent"
                    end
                    buff_lines[#buff_lines + 1] = "    " .. spell_name .. " (" .. dur_str .. ")"
                end
            end
        end
        if #buff_lines > 0 then
            companion_say(npc, client, "  Buffs (" .. #buff_lines .. " active):")
            for _, line in ipairs(buff_lines) do
                companion_say(npc, client, line)
            end
        else
            companion_say(npc, client, "  Buffs: none")
        end
    end
end

-- Information: show detailed combat stats for any targeted companion (read-only, no ownership required)
-- Requires c-expert Task 1: GetMinDMG(), GetMaxDMG(), GetCombatRole() bindings on Lua_Companion.
-- All other stat methods are available via Lua_Mob inheritance (GetSTR, GetAC, GetMR, etc.).
function companion.cmd_stats(npc, client, args)
    local role_id   = npc.GetCombatRole and npc:GetCombatRole() or 0  -- nil-guard: GetCombatRole is Companion-only; Lua_NPC cast drops it; default 0
    local role_name = COMBAT_ROLE_NAMES[role_id] or "Unknown"

    client:Message(15, "=== " .. npc:GetCleanName() .. " ===")
    client:Message(15, "Level " .. npc:GetLevel() ..
                       " " .. npc:GetClassName() ..
                       " (" .. role_name .. ")")
    client:Message(15, "HP: " .. npc:GetHP() .. "/" .. npc:GetMaxHP() ..
                       "  |  Mana: " .. npc:GetMana() .. "/" .. npc:GetMaxMana())
    client:Message(15, "--- Attributes ---")
    client:Message(15, "STR: " .. npc:GetSTR() ..
                       "  STA: " .. npc:GetSTA() ..
                       "  AGI: " .. npc:GetAGI() ..
                       "  DEX: " .. npc:GetDEX())
    client:Message(15, "INT: " .. npc:GetINT() ..
                       "  WIS: " .. npc:GetWIS() ..
                       "  CHA: " .. npc:GetCHA())
    client:Message(15, "--- Combat ---")
    client:Message(15, "AC: " .. npc:GetAC() ..
                       "  ATK: " .. npc:GetATK())
    client:Message(15, "Damage: " .. npc:GetMinDMG() ..
                       " - " .. npc:GetMaxDMG())
    client:Message(15, "--- Resistances ---")
    client:Message(15, "MR: " .. npc:GetMR() ..
                       "  FR: " .. npc:GetFR() ..
                       "  CR: " .. npc:GetCR() ..
                       "  PR: " .. npc:GetPR() ..
                       "  DR: " .. npc:GetDR())
end

-- Information: display help, optionally filtered by category topic
-- When sent @all, only the first companion responds (data bucket lock with 1s TTL)
function companion.cmd_help(npc, client, args)
    local topic = args:lower():gsub("^%s+", ""):gsub("%s+$", "")

    -- @all !help deduplication: only the first companion to receive this command responds.
    -- Key is zone-scoped so companions in different zones don't interfere.
    -- TTL of 1 second covers the entire @all dispatch window.
    local help_lock_key = "help_lock_" .. tostring(eq.get_zone_id())
    local lock_held = eq.get_data(help_lock_key)
    if lock_held and lock_held ~= "" then
        return  -- Another companion already responded this tick
    end
    -- Claim the lock before responding
    eq.set_data(help_lock_key, "1", "1")

    if topic == "" then
        companion_say(npc, client, "=== Companion Commands ===")
        companion_say(npc, client, "Stance: !passive  !balanced  !aggressive")
        companion_say(npc, client, "Movement: !follow  !guard  !recall  !tome  !flee")
        companion_say(npc, client, "Combat: !target  !assist")
        companion_say(npc, client, "Buffs: !buffme  !buffs")
        companion_say(npc, client, "Equipment: !equipment  !equip  !unequip  !equipmentupgrade  !equipmentmissing")
        companion_say(npc, client, "Information: !stats  !status  !help")
        companion_say(npc, client, "Control: !dismiss")
        companion_say(npc, client, "Type '!help <topic>' for details. Topics: stance, movement, combat, buffs, equipment, information, control")

    elseif topic == "stance" then
        companion_say(npc, client, "=== Stance Commands ===")
        companion_say(npc, client, "  !passive    - Stop fighting, follow owner. Will not engage combat.")
        companion_say(npc, client, "  !balanced   - Default. Fight when attacked or owner is attacked.")
        companion_say(npc, client, "  !aggressive - Actively seek and attack enemies in range.")

    elseif topic == "movement" then
        companion_say(npc, client, "=== Movement Commands ===")
        companion_say(npc, client, "  !follow  - Follow you at standard distance.")
        companion_say(npc, client, "  !guard   - Hold current position, stop following.")
        companion_say(npc, client, "  !recall  - Teleport to your location if stuck/far (>200 units, 30s cooldown).")
        companion_say(npc, client, "  !tome    - Path to your location (no cooldown, within 50 units: skips).")
        companion_say(npc, client, "  !flee    - Go passive, move to you, set follow mode. Hate list retained.")

    elseif topic == "combat" then
        companion_say(npc, client, "=== Combat Commands ===")
        companion_say(npc, client, "  !target - Target your current target. In balanced/aggressive: engages.")
        companion_say(npc, client, "  !assist - Attack your target. Auto-switches passive->balanced stance.")

    elseif topic == "buffs" then
        companion_say(npc, client, "=== Buff Commands ===")
        companion_say(npc, client, "  !buffme - Queue buff refresh on you only. Cast on next idle window.")
        companion_say(npc, client, "  !buffs  - Queue buff refresh on all party members.")
        companion_say(npc, client, "  Casters only. Requires >10% mana. Replaces any pending request.")

    elseif topic == "equipment" then
        companion_say(npc, client, "=== Equipment Commands ===")
        companion_say(npc, client, "  !equipment              - Show all equipped items.")
        companion_say(npc, client, "  !equip                  - How to give items (use trade window).")
        companion_say(npc, client, "  !unequip <slot>         - Return item from slot.")
        companion_say(npc, client, "  !unequip all            - Return all equipped items.")
        companion_say(npc, client, "  !equipmentupgrade [link] - Evaluate linked item vs equipped.")
        companion_say(npc, client, "  !equipmentmissing       - List empty equipment slots.")
        companion_say(npc, client, "Valid slots: primary, secondary, head, chest, arms, wrist1, wrist2,")
        companion_say(npc, client, "  hands, legs, feet, charm, ear1, ear2, face, neck, shoulder,")
        companion_say(npc, client, "  back, finger1, finger2, range, waist, ammo")

    elseif topic == "information" then
        companion_say(npc, client, "=== Information Commands ===")
        companion_say(npc, client, "  !stats        - Detailed combat stats (any player, any companion).")
        companion_say(npc, client, "  !status       - Overview: HP, mana, stance, target, buffs.")
        companion_say(npc, client, "  !help         - This command list.")
        companion_say(npc, client, "  !help <topic> - Details for: stance, movement, combat, buffs, equipment, information, control")

    elseif topic == "control" then
        companion_say(npc, client, "=== Control Commands ===")
        companion_say(npc, client, "  !dismiss - Dismiss companion. Re-recruit later with +10% bonus.")

    else
        companion_say(npc, client, "Unknown help topic: " .. topic)
        companion_say(npc, client, "Topics: stance, movement, combat, buffs, equipment, information, control")
    end
end

-- Equipment: list all empty equipment slots
function companion.cmd_equipmentmissing(npc, client, args)
    -- COMPANION_SLOT_NAMES is defined in global_npc.lua; use our own local copy here
    -- for display. Slot 21 (PowerSource) is intentionally skipped — companions don't use it.
    local slot_names = {
        [0]  = "charm",   [1]  = "ear1",     [2]  = "head",    [3]  = "face",
        [4]  = "ear2",    [5]  = "neck",      [6]  = "shoulder",[7]  = "arms",
        [8]  = "back",    [9]  = "wrist1",    [10] = "wrist2",  [11] = "range",
        [12] = "hands",   [13] = "primary",   [14] = "secondary",[15] = "finger1",
        [16] = "finger2", [17] = "chest",     [18] = "legs",    [19] = "feet",
        [20] = "waist",   [22] = "ammo",
    }
    local empty = {}
    for slot_id = 0, 22 do
        if slot_id ~= 21 and slot_names[slot_id] then
            if npc:GetEquipment(slot_id) == 0 then
                empty[#empty + 1] = slot_names[slot_id]
            end
        end
    end
    local name = npc:GetCleanName()
    if #empty == 0 then
        companion_say(npc, client, name .. " has all equipment slots filled.")
    else
        companion_say(npc, client, name .. " has nothing equipped in: " .. table.concat(empty, ", "))
    end
end

-- Movement: path to player's location (no cooldown; skips if already nearby)
function companion.cmd_tome(npc, client, args)
    local name = npc:GetCleanName()
    if npc:GetHP() <= 0 then
        companion_say(npc, client, name .. " is dead and cannot move.")
        return
    end
    local dist = npc:CalculateDistance(client)
    if dist < 50 then
        companion_say(npc, client, name .. " is already nearby.")
        return
    end
    -- BUG-022: Use GMMove for instant repositioning. RunTo is overridden by the
    -- follow-target AI on the next process tick, making it ineffective.
    -- GMMove sets position directly; the follow AI then resumes formation normally.
    -- This matches cmd_recall's approach (see above).
    npc:GMMove(client:GetX(), client:GetY(), client:GetZ(), client:GetHeading())
    companion_say(npc, client, name .. " moves to your side.")
end

-- Movement: disengage and retreat to player (passive + GMMove + follow mode)
-- NOTE: hate list is intentionally NOT cleared (lore-correct; mobs continue pursuit)
function companion.cmd_flee(npc, client, args)
    local name = npc:GetCleanName()
    if npc:GetHP() <= 0 then
        companion_say(npc, client, name .. " is dead and cannot flee.")
        return
    end
    local was_in_combat = npc:IsEngaged()
    -- nil-guard: GetStance is Companion-only; Lua_NPC cast drops it; default 1 (balanced = not passive)
    local was_passive   = ((npc.GetStance and npc:GetStance() or 1) == 0)

    -- Set passive and move to follow mode
    if npc.SetStance then npc:SetStance(0) end      -- nil-guard: SetStance is Companion-only; Lua_NPC cast drops it
    if npc.SetGuardMode then npc:SetGuardMode(false) end  -- nil-guard: SetGuardMode is Companion-only; Lua_NPC cast drops it
    companion_modes[npc:GetID()] = "follow"
    -- Use GMMove for instant repositioning. RunTo is overridden by the follow-target AI
    -- on the next process tick, making it ineffective (same issue as cmd_tome / BUG-022).
    npc:GMMove(client:GetX(), client:GetY(), client:GetZ(), client:GetHeading())

    if was_in_combat and not was_passive then
        companion_say(npc, client, name .. " disengages and retreats to you!")
    else
        companion_say(npc, client, name .. " moves to follow you.")
    end
end

-- Combat: set companion's target to player's current target
-- In passive stance: companion faces target but does NOT engage
-- In balanced/aggressive: companion engages via AddToHateList
function companion.cmd_target(npc, client, args)
    local player_target = client:GetTarget()
    if not player_target or not player_target.valid then
        client:Message(15, "You must target an enemy first.")
        return
    end
    npc:SetTarget(player_target)
    -- nil-guard: GetStance is Companion-only; Lua_NPC cast drops it; default 1 (balanced = engage)
    local stance = npc.GetStance and npc:GetStance() or 1
    if stance ~= 0 then
        npc:AddToHateList(player_target, 1, 0, false, false, false)
    end
    npc:Say("I see your target.")
end

-- Combat: companion assists player (targets and engages player's target)
-- Auto-switches from passive to balanced stance before engaging.
function companion.cmd_assist(npc, client, args)
    local name = npc:GetCleanName()

    -- Dead check
    if npc:GetHP() <= 0 then
        companion_say(npc, client, name .. " is dead and cannot fight.")
        return
    end

    local player_target = client:GetTarget()
    if not player_target or not player_target.valid then
        companion_say(npc, client, name .. " has no target to assist with. Target a mob first.")
        return
    end

    -- Friendly/self target check
    if player_target == npc then
        companion_say(npc, client, name .. " will not attack themselves.")
        return
    end
    if not npc:IsAttackAllowed(player_target) then
        companion_say(npc, client, name .. " will not attack a friendly target.")
        return
    end

    -- Auto-switch passive -> balanced before engaging
    -- nil-guard: GetStance/SetStance are Companion-only; Lua_NPC cast drops them (BUG-021)
    local switched_stance = false
    local stance = npc.GetStance and npc:GetStance() or 1  -- default 1 (balanced) if method unavailable
    if stance == 0 then
        if npc.SetStance then npc:SetStance(1) end
        switched_stance = true
    end

    npc:SetTarget(player_target)
    npc:AddToHateList(player_target, 1, 0, false, false, false)

    local target_name = player_target:GetCleanName()
    if switched_stance then
        companion_say(npc, client, name .. " switches to balanced stance and assists against " .. target_name .. "!")
    else
        companion_say(npc, client, name .. " assists against " .. target_name .. "!")
    end
end

-- Buffs: queue a buff refresh targeting the owner only
function companion.cmd_buffme(npc, client, args)
    local name = npc:GetCleanName()

    if npc:GetHP() <= 0 then
        companion_say(npc, client, name .. " is dead and cannot cast spells.")
        return
    end
    -- Check if companion is a caster (pure melee have 0 max mana)
    if npc:GetMaxMana() == 0 then
        companion_say(npc, client, name .. " has no buff spells available.")
        return
    end
    -- OOM check: below 10% mana
    if npc:GetManaRatio() < 10 then
        companion_say(npc, client, name .. " is too low on mana to buff right now.")
        return
    end

    -- Set buff request and start processing timer
    npc:SetEntityVariable("buff_request_target", "owner")
    npc:SetEntityVariable("buff_request_retries", "0")
    eq.set_timer("buff_request_" .. npc:GetID(), 2000)
    companion_say(npc, client, name .. " will refresh your buffs when able.")
end

-- Buffs: queue a buff refresh targeting all party members
function companion.cmd_buffs(npc, client, args)
    local name = npc:GetCleanName()

    if npc:GetHP() <= 0 then
        companion_say(npc, client, name .. " is dead and cannot cast spells.")
        return
    end
    if npc:GetMaxMana() == 0 then
        companion_say(npc, client, name .. " has no buff spells available.")
        return
    end
    if npc:GetManaRatio() < 10 then
        companion_say(npc, client, name .. " is too low on mana to buff right now.")
        return
    end

    npc:SetEntityVariable("buff_request_target", "party")
    npc:SetEntityVariable("buff_request_retries", "0")
    eq.set_timer("buff_request_" .. npc:GetID(), 2000)
    companion_say(npc, client, name .. " will refresh party buffs when able.")
end

-- Helper: compute a stat score for an item using eq.get_item_stat(item_id, identifier).
-- Armor score: AC + all stat bonuses + HP + Mana
-- Weapon score adds: floor(Damage * 10 / Delay)
-- Returns integer score.
local function item_stat_score_by_id(item_id)
    local score = eq.get_item_stat(item_id, "ac")
                + eq.get_item_stat(item_id, "astr")
                + eq.get_item_stat(item_id, "asta")
                + eq.get_item_stat(item_id, "aagi")
                + eq.get_item_stat(item_id, "adex")
                + eq.get_item_stat(item_id, "awis")
                + eq.get_item_stat(item_id, "aint")
                + eq.get_item_stat(item_id, "acha")
                + eq.get_item_stat(item_id, "hp")
                + eq.get_item_stat(item_id, "mana")
    local delay = eq.get_item_stat(item_id, "delay")
    if delay and delay > 0 then
        local dmg = eq.get_item_stat(item_id, "damage") or 0
        score = score + math.floor(dmg * 10 / delay)
    end
    return score
end

-- Helper: parse an EQ item link from a message string.
-- After TitaniumToServerSayLink(), the internal link body is 56 chars between \x12 delimiters.
-- Body layout (1-indexed): [1 type byte][5 hex item_id][5 hex aug1]...[rest]
-- Item ID is always at body chars 2-6 as 5 uppercase hex digits.
-- Returns item_id (number) or nil if no valid link found.
local function parse_item_link(msg)
    if not msg then return nil end
    -- \x12 is byte 18. Find the opening delimiter.
    local delim_pos = string.find(msg, "\18")
    if not delim_pos then return nil end
    -- Item ID starts 2 chars after the opening \x12 (skip 1 type byte)
    local hex_start = delim_pos + 2
    local hex_str = msg:sub(hex_start, hex_start + 4)  -- 5 hex chars
    if #hex_str < 5 then return nil end
    local item_id = tonumber(hex_str, 16)
    if not item_id or item_id <= 0 then return nil end
    return item_id
end

-- Equipment: evaluate a linked item vs. what the companion currently has equipped
-- Uses eq.get_item_stat() for stat comparisons — no ItemInst needed.
function companion.cmd_equipmentupgrade(npc, client, args)
    local name = npc:GetCleanName()

    -- Dead companion: silent (per architecture spec)
    if npc:GetHP() <= 0 then return end

    -- Parse item link from the args string
    local item_id = parse_item_link(args)
    if not item_id then
        companion_say(npc, client, "Please link an item for me to evaluate.")
        return
    end

    -- Basic validity check: item must exist (slots > 0 means it's equippable)
    local slots_bitmask = eq.get_item_stat(item_id, "slots")
    if not slots_bitmask or slots_bitmask == 0 then
        companion_say(npc, client, "Please link an item for me to evaluate.")
        return
    end

    -- Equippability check using class/race restrictions
    local enforce_class = eq.get_rule("Companions:EnforceClassRestrictions") == "true"
    local enforce_race  = eq.get_rule("Companions:EnforceRaceRestrictions") == "true"
    if enforce_class or enforce_race then
        local NPC_RACE_TO_PLAYER_RACE_LOCAL = {
            [44]=1,[55]=1,[67]=1,[71]=1,[77]=6,[78]=3,[81]=11,[90]=2,[92]=9,[93]=10,[94]=8,
        }
        local raw_race   = npc:GetRace()
        local comp_class = npc:GetClass()
        -- Map NPC race to player race equivalent for IsEquipable check
        local mapped_race = NPC_RACE_TO_PLAYER_RACE_LOCAL[raw_race]
        local check_race
        if mapped_race then
            check_race = mapped_race
        elseif raw_race > 16 then
            check_race = 1  -- bypass race check for non-player races
        else
            check_race = raw_race
        end
        -- Check class restriction via bitmask (class_id bitmask in "classes" field)
        if enforce_class then
            local class_mask = eq.get_item_stat(item_id, "classes")
            if class_mask and class_mask > 0 then
                local class_bit = math.floor(class_mask / (2 ^ (comp_class - 1))) % 2
                if class_bit == 0 then
                    return  -- Silent: companion class cannot use this item
                end
            end
        end
        if enforce_race then
            local race_mask = eq.get_item_stat(item_id, "races")
            if race_mask and race_mask > 0 then
                local race_bit = math.floor(race_mask / (2 ^ (check_race - 1))) % 2
                if race_bit == 0 then
                    return  -- Silent: companion race cannot use this item
                end
            end
        end
    end

    -- Determine best slot for this item based on Slots bitmask
    local slot_names_local = {
        [0]="charm",[1]="ear1",[2]="head",[3]="face",[4]="ear2",[5]="neck",
        [6]="shoulder",[7]="arms",[8]="back",[9]="wrist1",[10]="wrist2",[11]="range",
        [12]="hands",[13]="primary",[14]="secondary",[15]="finger1",[16]="finger2",
        [17]="chest",[18]="legs",[19]="feet",[20]="waist",[22]="ammo",
    }

    local target_slot = nil
    local first_match = nil
    for slot_id = 0, 22 do
        if slot_id ~= 21 and slot_names_local[slot_id] then
            local bit_set = math.floor(slots_bitmask / (2 ^ slot_id)) % 2
            if bit_set == 1 then
                if not first_match then first_match = slot_id end
                if npc:GetEquipment(slot_id) == 0 then
                    target_slot = slot_id
                    break
                end
            end
        end
    end
    if not target_slot then target_slot = first_match end
    if not target_slot then return end  -- No valid slot; silent

    local slot_name    = slot_names_local[target_slot] or ("slot " .. target_slot)
    local new_name     = eq.get_item_name(item_id) or ("Item " .. item_id)
    local equipped_id  = npc:GetEquipment(target_slot)

    -- Empty slot: always an upgrade
    if equipped_id == 0 then
        companion_say(npc, client, name .. ": " .. new_name ..
                      " is an upgrade! My " .. slot_name .. " slot is empty.")
        return
    end

    -- Compare stat scores
    local new_score = item_stat_score_by_id(item_id)
    local cur_score = item_stat_score_by_id(equipped_id)
    local cur_name  = eq.get_item_name(equipped_id) or ("Item " .. equipped_id)

    if new_score > cur_score then
        companion_say(npc, client, name .. ": " .. new_name ..
                      " (score: " .. new_score .. ") is an upgrade over " ..
                      cur_name .. " (score: " .. cur_score .. ") in my " ..
                      slot_name .. " slot.")
    elseif new_score == cur_score then
        companion_say(npc, client, name .. ": " .. new_name ..
                      " (score: " .. new_score .. ") is equal to " ..
                      cur_name .. " (score: " .. cur_score .. ") in my " ..
                      slot_name .. " slot.")
    else
        companion_say(npc, client, name .. ": " .. new_name ..
                      " (score: " .. new_score .. ") is worse than " ..
                      cur_name .. " (score: " .. cur_score .. ") in my " ..
                      slot_name .. " slot.")
    end
end

-- Control: dismiss companion voluntarily (preserves re-recruitment record and +10% bonus)
function companion.cmd_dismiss(npc, client, args)
    npc:Say("Farewell.")
    npc:Dismiss(true)
end

-- ============================================================================
-- Re-Recruitment (Task 23)
-- ============================================================================

-- Re-recruitment state restore is handled transparently inside client:CreateCompanion(npc).
-- When C++ detects an is_dismissed=1 record for this npc_type_id + owner_id, it calls
-- Load() + Unsuspend() to restore full companion state (level, XP, equipment, stance, buffs).
-- No separate Lua call is needed. check_dismissed_record() is used only to apply the
-- +10% roll bonus in attempt_recruitment() before calling CreateCompanion.

-- ============================================================================
-- Soul Wipe (Task 24)
-- ============================================================================

-- Trigger a soul wipe for a permanently dead companion:
--   1. Clear ChromaDB memories via LLM sidecar
--   2. Mark companion record as permanently deleted (C++ handles cascade)
-- Called from Companion::Death() C++ hook when auto-dismiss triggers after DeathDespawnS.
function companion.trigger_soul_wipe(npc_type_id, char_id)
    -- Clear ChromaDB memories via LLM sidecar
    -- POST http://npc-llm:8100/v1/memory/clear
    -- Body: {"npc_type_id": N, "player_id": N}
    local payload = '{"npc_type_id":' .. tostring(npc_type_id) ..
                    ',"player_id":' .. tostring(char_id) .. '}'
    local cmd = "curl -s -X POST http://npc-llm:8100/v1/memory/clear" ..
                " -H 'Content-Type: application/json'" ..
                " -d '" .. payload .. "' 2>&1"
    local result = io.popen(cmd)
    if result then
        result:read("*a")
        result:close()
    end
    -- Note: companion_data cascade delete is handled on C++ side (Task 24 c-expert).
    -- This function only clears the LLM memory layer.
end

return companion
