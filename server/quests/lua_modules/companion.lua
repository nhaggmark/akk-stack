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
    passive    = { handler = "cmd_passive",    category = "stance" },
    balanced   = { handler = "cmd_balanced",   category = "stance" },
    aggressive = { handler = "cmd_aggressive", category = "stance" },
    follow     = { handler = "cmd_follow",     category = "movement" },
    guard      = { handler = "cmd_guard",      category = "movement" },
    recall     = { handler = "cmd_recall",     category = "movement" },
    equipment  = { handler = "cmd_equipment",  category = "equipment",   requires_owner = false },
    gear       = { handler = "cmd_equipment",  category = "equipment",   requires_owner = false },  -- alias for !equipment
    equip      = { handler = "cmd_equip",      category = "equipment" },
    unequip    = { handler = "cmd_unequip",    category = "equipment" },
    unequipall = { handler = "cmd_unequipall", category = "equipment" },  -- alias for !unequip all
    stats      = { handler = "cmd_stats",      category = "information", requires_owner = false },
    status     = { handler = "cmd_status",     category = "information", requires_owner = false },
    help       = { handler = "cmd_help",       category = "information", requires_owner = false },
    target     = { handler = "cmd_target",     category = "combat" },
    assist     = { handler = "cmd_assist",     category = "combat" },
    dismiss    = { handler = "cmd_dismiss",    category = "control" },
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

-- Stance: set companion to passive (disengage, follow owner)
function companion.cmd_passive(npc, client, args)
    npc:SetStance(0)
    npc:WipeHateList()
    npc:Say("I will stand down.")
end

-- Stance: set companion to balanced (default combat behavior)
-- Response splits by companion_type: loyal = relational, mercenary = neutral
function companion.cmd_balanced(npc, client, args)
    npc:SetStance(1)
    if npc:GetCompanionType() == 0 then
        npc:Say("I will fight at your side.")
    else
        npc:Say("Understood.")
    end
end

-- Stance: set companion to aggressive (actively pursue enemies)
function companion.cmd_aggressive(npc, client, args)
    npc:SetStance(2)
    npc:Say("Understood. I will fight aggressively.")
end

-- Movement: resume following owner at standard distance
function companion.cmd_follow(npc, client, args)
    npc:SetGuardMode(false)
    companion_modes[npc:GetID()] = "follow"
    npc:Say("I will follow.")
end

-- Movement: hold current position, stop following
function companion.cmd_guard(npc, client, args)
    npc:SetGuardMode(true)
    companion_modes[npc:GetID()] = "guard"
    npc:Say("I will hold here.")
end

-- Movement: teleport companion to player location (only if far enough away)
function companion.cmd_recall(npc, client, args)
    local cooldown_s = tonumber(eq.get_rule("Companions:RecallCooldownS")) or 30
    local cd_key = "companion_recall_cd_" ..
                   npc:GetCompanionID() .. "_" .. client:CharacterID()

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

-- Information: show companion stats overview
function companion.cmd_status(npc, client, args)
    local stance_names = { [0] = "Passive", [1] = "Balanced", [2] = "Aggressive" }
    local type_names   = { [0] = "Companion", [1] = "Mercenary" }
    local mode = companion_modes[npc:GetID()] or "follow"
    mode = mode:sub(1, 1):upper() .. mode:sub(2)

    client:Message(15, "=== " .. npc:GetCleanName() .. " ===")
    client:Message(15, "  Level: " .. npc:GetLevel() ..
                       "  Class: " .. npc:GetClassName())
    client:Message(15, "  HP: " .. npc:GetHP() .. "/" .. npc:GetMaxHP() ..
                       "  Mana: " .. npc:GetMana() .. "/" .. npc:GetMaxMana())
    local current_xp    = npc:GetCompanionXP()
    local next_level_xp = npc:GetXPForNextLevel()
    client:Message(15, "  XP: " .. current_xp .. " / " .. next_level_xp)
    client:Message(15, "  Stance: " ..
                       (stance_names[npc:GetStance()] or "Unknown") ..
                       "  Mode: " .. mode)
    client:Message(15, "  Type: " ..
                       (type_names[npc:GetCompanionType()] or "Unknown"))
end

-- Information: show detailed combat stats for any targeted companion (read-only, no ownership required)
-- Requires c-expert Task 1: GetMinDMG(), GetMaxDMG(), GetCombatRole() bindings on Lua_Companion.
-- All other stat methods are available via Lua_Mob inheritance (GetSTR, GetAC, GetMR, etc.).
function companion.cmd_stats(npc, client, args)
    local role_id   = npc:GetCombatRole()
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
function companion.cmd_help(npc, client, args)
    local topic = args:lower():gsub("^%s+", ""):gsub("%s+$", "")

    if topic == "" then
        client:Message(15, "=== Companion Commands ===")
        client:Message(15, "Stance:")
        client:Message(15, "  !passive       - Disengage from combat, follow owner")
        client:Message(15, "  !balanced      - Default combat stance")
        client:Message(15, "  !aggressive    - Actively pursue and attack enemies")
        client:Message(15, "Movement:")
        client:Message(15, "  !follow        - Follow you at standard distance")
        client:Message(15, "  !guard         - Hold current position")
        client:Message(15, "  !recall        - Return to your side (if stuck)")
        client:Message(15, "Equipment:")
        client:Message(15, "  !equipment     - Show equipped items")
        client:Message(15, "  !unequip <slot> - Return item from slot")
        client:Message(15, "  !unequip all   - Return all equipped items")
        client:Message(15, "  !equip         - How to give items")
        client:Message(15, "Information:")
        client:Message(15, "  !stats         - Show detailed combat stats")
        client:Message(15, "  !status        - Show companion overview")
        client:Message(15, "  !help          - This command list")
        client:Message(15, "  !help <topic>  - Details for a category")
        client:Message(15, "Combat:")
        client:Message(15, "  !target        - Companion targets your target")
        client:Message(15, "  !assist        - Companion assists you in combat")
        client:Message(15, "Control:")
        client:Message(15, "  !dismiss       - Dismiss companion")
        client:Message(15, "To talk naturally, just /say without ! prefix.")
        client:Message(15, "Type '!help <topic>' for details.")

    elseif topic == "stance" then
        client:Message(15, "=== Stance Commands ===")
        client:Message(15, "  !passive    - Stop fighting, follow owner.")
        client:Message(15, "               Companion will not engage combat.")
        client:Message(15, "  !balanced   - Default. Fight when attacked or")
        client:Message(15, "               when owner is attacked.")
        client:Message(15, "  !aggressive - Actively seek and attack enemies")
        client:Message(15, "               in range.")

    elseif topic == "movement" then
        client:Message(15, "=== Movement Commands ===")
        client:Message(15, "  !follow  - Follow you at standard distance.")
        client:Message(15, "  !guard   - Hold current position, stop following.")
        client:Message(15, "  !recall  - Teleport companion to your location if")
        client:Message(15, "             stuck or far away (>200 units). Has a")
        client:Message(15, "             30-second cooldown.")

    elseif topic == "equipment" then
        client:Message(15, "=== Equipment Commands ===")
        client:Message(15, "  !equipment      - Show all equipped items.")
        client:Message(15, "  !unequip <slot> - Return item from slot.")
        client:Message(15, "  !unequip all    - Return all equipped items.")
        client:Message(15, "  !equip          - How to give items to companion.")
        client:Message(15, "Valid slots: primary, secondary, head, chest, arms,")
        client:Message(15, "  wrist1, wrist2, hands, legs, feet, charm, ear1,")
        client:Message(15, "  ear2, face, neck, shoulder, back, finger1,")
        client:Message(15, "  finger2, range, waist, ammo")

    elseif topic == "combat" then
        client:Message(15, "=== Combat Commands ===")
        client:Message(15, "  !target - Companion targets your current target.")
        client:Message(15, "            In balanced/aggressive, engages combat.")
        client:Message(15, "            In passive, faces target but won't attack.")
        client:Message(15, "  !assist - Same as !target. Conveys 'help me fight")
        client:Message(15, "            this'. Same behavior as !target.")

    elseif topic == "control" then
        client:Message(15, "=== Control Commands ===")
        client:Message(15, "  !dismiss - Dismiss your companion. They can be")
        client:Message(15, "             re-recruited later with a +10% bonus.")

    elseif topic == "information" then
        client:Message(15, "=== Information Commands ===")
        client:Message(15, "  !stats        - Show detailed combat stats.")
        client:Message(15, "                  Available to any player targeting any")
        client:Message(15, "                  companion (not owner-restricted).")
        client:Message(15, "  !status       - Show companion overview: stance, XP, mode.")
        client:Message(15, "  !help         - Show all available commands.")
        client:Message(15, "  !help <topic> - Show details for a category.")
        client:Message(15, "                  Topics: stance, movement, equipment,")
        client:Message(15, "                  combat, control, information")

    else
        client:Message(15, "Unknown help topic: " .. topic)
        client:Message(15, "Available topics: stance, movement, equipment, " ..
                           "combat, control, information")
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
    if npc:GetStance() ~= 0 then
        npc:AddToHateList(player_target, 1, 0, false, false, false)
    end
    npc:Say("I see your target.")
end

-- Combat: companion assists player (targets and engages player's target)
-- Functionally identical to cmd_target; separate command for semantic clarity
function companion.cmd_assist(npc, client, args)
    local player_target = client:GetTarget()
    if not player_target or not player_target.valid then
        client:Message(15, "You must target an enemy first.")
        return
    end
    npc:SetTarget(player_target)
    if npc:GetStance() ~= 0 then
        npc:AddToHateList(player_target, 1, 0, false, false, false)
    end
    npc:Say("I will assist.")
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
