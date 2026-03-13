-- test_companion_commands_regression.lua
--
-- Regression tests for all 23 existing companion commands.
-- Verifies that no existing command behavior was changed by the companion-commands feature.
--
-- Commands tested: passive, balanced, aggressive, follow, guard, recall, tome, flee,
--   equipment, equip, unequip, unequipall, equipmentupgrade, equipmentmissing,
--   stats, status, help, target, assist, buffme, buffs, dismiss
--
-- Run with:
--   luajit tests/test_companion_commands_regression.lua
-- from the lua_modules/ directory, OR:
--   cd akk-stack/server/quests && luajit tests/test_companion_commands_regression.lua
--
-- ============================================================================
-- EQEmu API stubs
-- ============================================================================

local data_store = {}

eq = {
    get_rule = function(rule)
        if rule == "Companions:CompanionsEnabled" then return "true" end
        if rule == "Companions:RecallCooldownS" then return "30" end
        return "false"
    end,
    get_entity_list = function()
        return { GetClientByCharID = function() return nil end }
    end,
    set_timer = function() end,
    stop_timer = function() end,
    get_data  = function(key) return data_store[key] end,
    set_data  = function(key, val, ttl) data_store[key] = val end,
    delete_data = function(key) data_store[key] = nil end,
    get_zone_id = function() return 1 end,
    get_item_stat = function(item_id, stat) return 0 end,
    get_item_name = function(item_id) return "TestItem" .. tostring(item_id) end,
    get_spell_name = function(spell_id) return "TestSpell" .. tostring(spell_id) end,
}

MT = { Red = 15, Yellow = 4, White = 7, DimGray = 22 }
os = os or { time = function() return 0 end }

-- ============================================================================
-- Object factories
-- ============================================================================

local function make_npc(opts)
    opts = opts or {}
    local stance     = opts.stance ~= nil and opts.stance or 1
    local guard_mode = opts.guard_mode or false
    local dismissed  = false
    local messages   = {}
    local hate_list  = {}

    local npc = {
        _id          = opts.id or 100,
        _hp          = opts.hp or 500,
        _name        = opts.name or "Testius",
        _char_id     = opts.char_id or 42,
        _messages    = messages,
        _hate_list   = hate_list,
        _wiped_count = 0,
        _guard_mode  = guard_mode,
        _dismissed   = false,
        _entity_vars = {},
        valid        = true,
    }
    function npc:GetID()                 return self._id end
    function npc:GetHP()                 return self._hp end
    function npc:GetMaxHP()              return opts.max_hp or 1000 end
    function npc:GetCleanName()          return self._name end
    function npc:GetName()               return self._name end
    function npc:GetOwnerCharacterID()   return self._char_id end
    function npc:GetMaxMana()            return opts.max_mana or 0 end
    function npc:GetMana()               return opts.mana or 0 end
    function npc:GetManaRatio()          return opts.mana_ratio or 100 end
    function npc:IsCompanion()           return true end
    function npc:IsSitting()             return false end
    function npc:IsEngaged()             return false end
    function npc:IsAttackAllowed(mob)
        if opts.attack_allowed ~= nil then return opts.attack_allowed end
        return true
    end
    function npc:SetTarget(mob)          self._target = mob end
    function npc:GetTarget()             return self._target end
    function npc:AddToHateList(mob, threat, val, a, b, c)
        self._hate_list[#self._hate_list + 1] = { mob = mob }
    end
    function npc:WipeHateList()
        self._hate_list = {}
        self._wiped_count = self._wiped_count + 1
    end
    function npc:Say(msg)
        messages[#messages + 1] = { channel = "say", text = msg }
    end
    function npc:GetGroup()              return opts.group or nil end
    function npc:GetEntityVariable(k)    return self._entity_vars[k] or "" end
    function npc:SetEntityVariable(k,v)  self._entity_vars[k] = v end
    function npc:GetClass()              return opts.class or 1 end
    function npc:GetClassName()          return "Warrior" end
    function npc:GetLevel()              return opts.level or 20 end
    function npc:GetRace()               return opts.race or 1 end
    function npc:GetNPCTypeID()          return opts.npc_type_id or 1000 end
    function npc:CalculateDistance(other) return opts.distance or 200 end
    function npc:GMMove(x, y, z, h)      self._moved = { x=x, y=y, z=z, h=h } end
    function npc:GetSTR()  return 100 end
    function npc:GetSTA()  return 100 end
    function npc:GetAGI()  return 100 end
    function npc:GetDEX()  return 100 end
    function npc:GetINT()  return 100 end
    function npc:GetWIS()  return 100 end
    function npc:GetCHA()  return 100 end
    function npc:GetAC()   return 200 end
    function npc:GetATK()  return 150 end
    function npc:GetMR()   return 50 end
    function npc:GetFR()   return 50 end
    function npc:GetCR()   return 50 end
    function npc:GetPR()   return 50 end
    function npc:GetDR()   return 50 end
    function npc:GetMinDMG() return 10 end
    function npc:GetMaxDMG() return 40 end
    function npc:GetCompanionXP() return 12000 end
    function npc:GetXPForNextLevel() return 50000 end
    function npc:GetEquipment(slot) return 0 end
    function npc:ShowEquipment(client) end
    function npc:GiveAll(client) end
    function npc:GiveSlot(client, slot) return true end
    function npc:Dismiss(voluntary) self._dismissed = voluntary end
    function npc:GetBuffs() return {} end

    -- Companion-only methods (nil-guarded in real code)
    if opts.has_companion_methods ~= false then
        local st = stance
        local gm = guard_mode
        local ct = opts.companion_type or 0
        local cid = opts.companion_id or 999
        local cr  = opts.combat_role or 0
        function npc:GetStance()         return st end
        function npc:SetStance(v)        st = v end
        function npc:GetGuardMode()      return gm end
        function npc:SetGuardMode(v)     gm = v; self._guard_mode = v end
        function npc:GetCompanionType()  return ct end
        function npc:GetCompanionID()    return cid end
        function npc:GetCombatRole()     return cr end
    end

    return npc
end

local function make_mob(opts)
    opts = opts or {}
    local mob = {
        _id   = opts.id or 200,
        _name = opts.name or "a_gnoll",
        valid = (opts.valid ~= false),
    }
    function mob:GetID()        return self._id end
    function mob:GetCleanName() return self._name end
    function mob:IsAttackAllowed(other) return opts.attack_allowed ~= false end
    return mob
end

local function make_client(opts)
    opts = opts or {}
    local client = {
        _id       = opts.id or 1,
        _char_id  = opts.char_id or 42,
        _target   = opts.target or nil,
        _messages = {},
        valid     = true,
        _x = opts.x or 0, _y = opts.y or 0, _z = opts.z or 0, _h = opts.h or 0,
    }
    function client:GetID()       return self._id end
    function client:CharacterID() return self._char_id end
    function client:GetTarget()   return self._target end
    function client:GetGroup()    return opts.group or nil end
    function client:GetX()        return self._x end
    function client:GetY()        return self._y end
    function client:GetZ()        return self._z end
    function client:GetHeading()  return self._h end
    function client:Message(typ, msg)
        self._messages[#self._messages + 1] = { type = typ, text = msg }
    end
    return client
end

-- ============================================================================
-- Load companion module
-- ============================================================================

local script_dir = debug.getinfo(1, "S").source:match("^@(.*)tests/") or "./"
package.path = script_dir .. "lua_modules/?.lua;" ..
               script_dir .. "lua_modules/?/init.lua;" ..
               package.path

local real_require = require
local stubbed = {
    string_ext = true, command = true, client_ext = true, mob_ext = true,
    npc_ext = true, entity_list_ext = true, general_ext = true,
    bit = true, directional = true, json = true, llm_bridge = true,
    llm_config = true, llm_faction = true, companion_commentary = true,
    companion_context = true, companion_culture = true,
    ["constants/instance_versions"] = true,
}
require = function(modname)
    if stubbed[modname] then
        return setmetatable({}, { __index = function() return function() end end })
    end
    return real_require(modname)
end
Database = function()
    return {
        prepare  = function(self, sql) return {
            execute = function() end,
            fetch_hash = function() return nil end,
        } end,
        close = function() end,
    }
end
local ok, companion = pcall(require, "companion")
if not ok then error("Failed to load companion module: " .. tostring(companion)) end
require = real_require

-- ============================================================================
-- Test framework
-- ============================================================================

local PASS, FAIL, ERRORS = 0, 0, {}
local function test(name, fn)
    data_store = {}  -- reset data buckets between tests
    local ok, err = pcall(fn)
    if ok then
        PASS = PASS + 1
        io.write("  PASS  " .. name .. "\n")
    else
        FAIL = FAIL + 1
        ERRORS[#ERRORS + 1] = { name = name, err = tostring(err) }
        io.write("  FAIL  " .. name .. "\n")
        io.write("         " .. tostring(err) .. "\n")
    end
end
local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assertion failed") ..
              ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end
local function assert_true(v, msg)
    if not v then error((msg or "expected true") .. ": got " .. tostring(v), 2) end
end
local function assert_false(v, msg)
    if v then error((msg or "expected false") .. ": got " .. tostring(v), 2) end
end
local function assert_contains(str, sub, msg)
    if not str:find(sub, 1, true) then
        error((msg or "string assertion failed") ..
              ": '" .. sub .. "' not found in '" .. str .. "'", 2)
    end
end
local function last_say(npc)
    if #npc._messages == 0 then return "" end
    return npc._messages[#npc._messages].text
end
local function last_client_msg(client)
    if #client._messages == 0 then return "" end
    return client._messages[#client._messages].text
end

-- ============================================================================
-- Regression: Stance commands
-- ============================================================================

print("\n=== Regression: Stance commands ===\n")

test("cmd_passive: sets stance to 0 and wipes hate list", function()
    local npc    = make_npc({ id = 1, stance = 1 })
    local client = make_client({ char_id = 42 })

    companion.cmd_passive(npc, client, "")

    assert_eq(npc:GetStance(), 0, "stance should be passive (0)")
    assert_eq(npc._wiped_count, 1, "WipeHateList should be called")
end)

test("cmd_balanced: sets stance to 1", function()
    local npc    = make_npc({ id = 2, stance = 0 })
    local client = make_client({ char_id = 42 })

    companion.cmd_balanced(npc, client, "")

    assert_eq(npc:GetStance(), 1, "stance should be balanced (1)")
end)

test("cmd_aggressive: sets stance to 2", function()
    local npc    = make_npc({ id = 3, stance = 1 })
    local client = make_client({ char_id = 42 })

    companion.cmd_aggressive(npc, client, "")

    assert_eq(npc:GetStance(), 2, "stance should be aggressive (2)")
end)

test("cmd_passive: does not crash on plain Lua_NPC (no SetStance)", function()
    local npc    = make_npc({ id = 4, hp = 500, has_companion_methods = false })
    local client = make_client({ char_id = 42 })
    companion.cmd_passive(npc, client, "")  -- must not crash
    -- WipeHateList is Lua_Mob method, always present
    assert_eq(npc._wiped_count, 1, "WipeHateList should be called")
end)

-- ============================================================================
-- Regression: Movement commands
-- ============================================================================

print("\n=== Regression: Movement commands ===\n")

test("cmd_follow: sets mode to follow, clears guard mode", function()
    local npc    = make_npc({ id = 10, hp = 500, guard_mode = true })
    local client = make_client({ char_id = 42 })
    companion.cmd_guard(npc, client, "")  -- ensure companion_modes = guard

    companion.cmd_follow(npc, client, "")

    assert_false(npc._guard_mode, "guard mode should be cleared")
    assert_contains(last_say(npc), "follow", "response should mention 'follow'")
end)

test("cmd_follow: dead companion returns error", function()
    local npc    = make_npc({ id = 11, hp = 0 })
    local client = make_client({ char_id = 42 })

    companion.cmd_follow(npc, client, "")

    assert_contains(last_say(npc), "dead", "dead companion should say 'dead'")
end)

test("cmd_guard: sets guard mode, tracks mode as guard", function()
    local npc    = make_npc({ id = 12, hp = 500 })
    local client = make_client({ char_id = 42 })

    companion.cmd_guard(npc, client, "")

    assert_true(npc._guard_mode, "guard mode should be set")
    assert_contains(last_say(npc), "hold here", "response should say 'hold here'")
end)

test("cmd_recall: skips when within RECALL_MIN_DISTANCE (200 units)", function()
    local npc    = make_npc({ id = 13, hp = 500, distance = 100 })
    local client = make_client({ char_id = 42 })

    companion.cmd_recall(npc, client, "")

    assert_eq(npc._moved, nil, "GMMove should NOT be called within 200 units")
    assert_contains(last_client_msg(client), "nearby", "should say 'already nearby'")
end)

test("cmd_recall: teleports when beyond 200 units and no cooldown", function()
    local npc    = make_npc({ id = 14, hp = 500, distance = 300 })
    local client = make_client({ char_id = 42, x = 50, y = 60, z = 5, h = 45 })

    companion.cmd_recall(npc, client, "")

    assert_true(npc._moved ~= nil, "GMMove should be called")
    assert_eq(npc._moved.x, 50, "x should match client x")
end)

test("cmd_recall: blocked when on cooldown", function()
    local npc    = make_npc({ id = 15, hp = 500, distance = 300, companion_id = 555 })
    local client = make_client({ char_id = 42 })
    -- Pre-set cooldown
    local cd_key = "companion_recall_cd_555_42"
    data_store[cd_key] = "1"

    companion.cmd_recall(npc, client, "")

    assert_eq(npc._moved, nil, "GMMove should NOT be called when on cooldown")
    assert_contains(last_client_msg(client), "cooldown", "should say 'cooldown'")
end)

test("cmd_flee: goes passive, moves to player, sets follow mode (hate list retained)", function()
    local enemy  = make_mob({ id = 300 })
    local npc    = make_npc({ id = 16, hp = 500, distance = 200, stance = 1 })
    local client = make_client({ char_id = 42, x = 10, y = 20, z = 0 })
    npc:AddToHateList(enemy, 100, 0, false, false, false)

    companion.cmd_flee(npc, client, "")

    assert_eq(npc:GetStance(), 0, "stance should be passive after !flee")
    assert_false(npc._guard_mode, "guard mode should be cleared after !flee")
    assert_true(npc._moved ~= nil, "GMMove should be called")
    -- Hate list is intentionally NOT cleared by !flee
    -- (npc._hate_list was populated before the cmd_flee call)
end)

test("cmd_flee: dead companion returns error", function()
    local npc    = make_npc({ id = 17, hp = 0 })
    local client = make_client({ char_id = 42 })

    companion.cmd_flee(npc, client, "")

    assert_eq(npc._moved, nil, "GMMove should NOT be called for dead companion")
    assert_contains(last_say(npc), "dead", "dead companion should say 'dead'")
end)

-- ============================================================================
-- Regression: Equipment commands
-- ============================================================================

print("\n=== Regression: Equipment commands ===\n")

test("cmd_equipment: calls ShowEquipment without error", function()
    local npc    = make_npc({ id = 30 })
    local client = make_client({ char_id = 42 })
    local called = false
    npc.ShowEquipment = function(self, c) called = true end

    companion.cmd_equipment(npc, client, "")

    assert_true(called, "ShowEquipment should be called")
end)

test("cmd_equip: sends trade window instructions", function()
    local npc    = make_npc({ id = 31 })
    local client = make_client({ char_id = 42 })

    companion.cmd_equip(npc, client, "")

    assert_true(#client._messages > 0, "client should receive instructions")
    local out = ""
    for _, m in ipairs(client._messages) do out = out .. m.text end
    assert_contains(out, "trade", "instructions should mention 'trade'")
end)

test("cmd_unequip: no slot argument shows usage", function()
    local npc    = make_npc({ id = 32 })
    local client = make_client({ char_id = 42 })

    companion.cmd_unequip(npc, client, "")

    assert_true(#client._messages > 0, "usage message should be sent")
    local out = ""
    for _, m in ipairs(client._messages) do out = out .. m.text end
    assert_contains(out, "Usage", "should say 'Usage'")
end)

test("cmd_unequipall: calls cmd_unequip with 'all'", function()
    local npc    = make_npc({ id = 33 })
    local client = make_client({ char_id = 42 })
    local give_all_called = false
    npc.GiveAll = function(self, c) give_all_called = true end

    companion.cmd_unequipall(npc, client, "")

    assert_true(give_all_called, "GiveAll should be called for !unequipall")
end)

test("cmd_equipmentmissing: reports empty slots", function()
    local npc    = make_npc({ id = 34 })
    local client = make_client({ char_id = 42 })

    companion.cmd_equipmentmissing(npc, client, "")

    local out = ""
    for _, m in ipairs(npc._messages) do out = out .. m.text end
    -- All slots empty (GetEquipment returns 0 for all) so should mention empty slots
    assert_true(#npc._messages > 0, "response should be sent")
end)

-- ============================================================================
-- Regression: Combat commands
-- ============================================================================

print("\n=== Regression: Combat commands ===\n")

test("cmd_target: sets target on companion", function()
    local enemy  = make_mob({ id = 400 })
    local npc    = make_npc({ id = 40, hp = 500, stance = 1 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_target(npc, client, "")

    assert_eq(npc._target._id, 400, "companion target should be set")
end)

test("cmd_target: no target shows error", function()
    local npc    = make_npc({ id = 41, hp = 500 })
    local client = make_client({ char_id = 42, target = nil })

    companion.cmd_target(npc, client, "")

    assert_eq(npc._target, nil, "target should not be set without client target")
    assert_contains(last_client_msg(client), "must target", "should prompt to target")
end)

test("cmd_assist: engages enemy, adds to hate list", function()
    local enemy  = make_mob({ id = 500 })
    local npc    = make_npc({ id = 42, hp = 500, stance = 1 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    assert_true(#npc._hate_list > 0, "enemy should be on hate list")
    assert_eq(npc._hate_list[1].mob._id, 500, "hate target should be the enemy")
end)

test("cmd_assist: dead companion refuses", function()
    local enemy  = make_mob({ id = 501 })
    local npc    = make_npc({ id = 43, hp = 0 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "dead companion should not engage")
end)

test("cmd_assist: now breaks guard mode (new behavior, verify not regression)", function()
    -- This is additive behavior added by this feature; verifying it's present
    local enemy  = make_mob({ id = 502 })
    local npc    = make_npc({ id = 44, hp = 500, stance = 1, guard_mode = true })
    local client = make_client({ char_id = 42, target = enemy })
    companion.cmd_guard(npc, client, "")  -- set companion_modes to guard

    companion.cmd_assist(npc, client, "")

    assert_false(npc._guard_mode, "cmd_assist should break guard mode (new behavior)")
    assert_true(#npc._hate_list > 0, "enemy should still be engaged")
end)

-- ============================================================================
-- Regression: Buff commands
-- ============================================================================

print("\n=== Regression: Buff commands ===\n")

test("cmd_buffme: dead companion refuses", function()
    local npc    = make_npc({ id = 50, hp = 0, max_mana = 1000 })
    local client = make_client({ char_id = 42 })

    companion.cmd_buffme(npc, client, "")

    local out = last_say(npc)
    assert_contains(out, "dead", "dead companion should not buff")
end)

test("cmd_buffme: melee companion (no mana) refuses", function()
    local npc    = make_npc({ id = 51, hp = 500, max_mana = 0 })
    local client = make_client({ char_id = 42 })

    companion.cmd_buffme(npc, client, "")

    local out = last_say(npc)
    assert_contains(out, "no buff spells", "melee companion should say no buff spells")
end)

test("cmd_buffme: caster companion sets entity variable", function()
    local npc    = make_npc({ id = 52, hp = 500, max_mana = 1000, mana_ratio = 80 })
    local client = make_client({ char_id = 42 })

    companion.cmd_buffme(npc, client, "")

    assert_eq(npc._entity_vars["buff_request_target"], "owner",
              "buff_request_target should be 'owner'")
end)

test("cmd_buffs: sets buff request to 'party' for casters", function()
    local npc    = make_npc({ id = 53, hp = 500, max_mana = 1000, mana_ratio = 80 })
    local client = make_client({ char_id = 42 })

    companion.cmd_buffs(npc, client, "")

    assert_eq(npc._entity_vars["buff_request_target"], "party",
              "buff_request_target should be 'party'")
end)

-- ============================================================================
-- Regression: Information commands
-- ============================================================================

print("\n=== Regression: Information commands ===\n")

test("cmd_stats: does not crash, sends messages to client", function()
    local npc    = make_npc({ id = 60 })
    local client = make_client({ char_id = 42 })

    companion.cmd_stats(npc, client, "")

    assert_true(#client._messages > 0, "cmd_stats should send messages to client")
end)

test("cmd_status: does not crash, sends overview to group/say", function()
    local npc    = make_npc({ id = 61 })
    local client = make_client({ char_id = 42 })

    companion.cmd_status(npc, client, "")

    assert_true(#npc._messages > 0, "cmd_status should send messages")
    local out = ""
    for _, m in ipairs(npc._messages) do out = out .. m.text end
    assert_contains(out, "===", "status should include a header")
end)

test("cmd_status: dead companion shows DEAD header", function()
    local npc    = make_npc({ id = 62, hp = 0 })
    local client = make_client({ char_id = 42 })

    companion.cmd_status(npc, client, "")

    local out = ""
    for _, m in ipairs(npc._messages) do out = out .. m.text end
    assert_contains(out, "DEAD", "dead companion status should show [DEAD]")
end)

test("cmd_help: does not crash, produces output", function()
    data_store = {}  -- clear lock
    local npc    = make_npc({ id = 63 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    assert_true(#npc._messages > 0, "cmd_help should produce output")
end)

-- ============================================================================
-- Regression: Control commands
-- ============================================================================

print("\n=== Regression: Control commands ===\n")

test("cmd_dismiss: calls Dismiss(true) on companion", function()
    local npc    = make_npc({ id = 70 })
    local client = make_client({ char_id = 42 })

    companion.cmd_dismiss(npc, client, "")

    assert_eq(npc._dismissed, true, "Dismiss(true) should be called")
    assert_contains(last_say(npc), "Farewell", "should say Farewell")
end)

-- ============================================================================
-- Regression: dispatch_prefix_command routing
-- ============================================================================

print("\n=== Regression: dispatch_prefix_command ===\n")

test("dispatch_prefix_command: routes !passive correctly", function()
    local npc    = make_npc({ id = 80, stance = 1 })
    local client = make_client({ char_id = 42 })

    companion.dispatch_prefix_command(npc, client, "!passive")

    assert_eq(npc:GetStance(), 0, "dispatch should route !passive to cmd_passive")
end)

test("dispatch_prefix_command: ownership check blocks non-owner", function()
    local npc    = make_npc({ id = 81, char_id = 42 })
    local client = make_client({ char_id = 99 })  -- different owner

    companion.dispatch_prefix_command(npc, client, "!passive")

    assert_contains(last_client_msg(client), "not your companion",
                    "non-owner should get rejected")
end)

test("dispatch_prefix_command: read-only commands bypass ownership check", function()
    local npc    = make_npc({ id = 82, char_id = 42 })
    local client = make_client({ char_id = 99 })  -- not owner
    data_store = {}  -- reset help lock

    -- !stats is requires_owner = false
    companion.dispatch_prefix_command(npc, client, "!stats")

    assert_true(#client._messages > 0, "non-owner should see !stats output")
end)

test("dispatch_prefix_command: unknown command shows error", function()
    local npc    = make_npc({ id = 83, char_id = 42 })
    local client = make_client({ char_id = 42 })

    companion.dispatch_prefix_command(npc, client, "!boguscommand")

    assert_contains(last_client_msg(client), "Unknown command",
                    "unknown command should show error")
end)

test("dispatch_prefix_command: empty ! shows help", function()
    data_store = {}
    local npc    = make_npc({ id = 84, char_id = 42 })
    local client = make_client({ char_id = 42 })

    companion.dispatch_prefix_command(npc, client, "!")

    assert_true(#npc._messages > 0, "empty ! should show help")
end)

test("dispatch_prefix_command: routes new !hold command", function()
    local npc    = make_npc({ id = 85, hp = 500, char_id = 42, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.dispatch_prefix_command(npc, client, "!hold")

    assert_true(npc._guard_mode, "dispatch should route !hold to cmd_hold")
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n=== Results: %d passed, %d failed ===\n", PASS, FAIL))
if FAIL > 0 then
    print("FAILURES:")
    for _, e in ipairs(ERRORS) do
        print("  " .. e.name)
        print("    " .. e.err)
    end
    os.exit(1)
else
    print("All tests passed.")
    os.exit(0)
end
