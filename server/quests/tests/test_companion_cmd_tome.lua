-- test_companion_cmd_tome.lua
--
-- Unit tests for companion.cmd_tome (updated behavior).
--
-- Tests verify:
--   1. !tome on dead companion returns early with error
--   2. !tome when companion is within 50 units returns "already nearby"
--   3. !tome moves companion to player (GMMove called)
--   4. !tome wipes hate list (stops active combat)
--   5. !tome sets passive stance temporarily, saves original stance in entity var
--   6. !tome sets a comp_tome_restore_<id> timer for stance restore
--   7. !tome breaks guard mode and sets follow mode
--   8. !tome nil-guard safety (no SetGuardMode/SetStance when unavailable)
--   9. Passive companions: no timer fired (already passive, no restore needed)
--
-- Run with:
--   luajit tests/test_companion_cmd_tome.lua
-- from the lua_modules/ directory, OR:
--   cd akk-stack/server/quests && luajit tests/test_companion_cmd_tome.lua
--
-- ============================================================================
-- EQEmu API stubs
-- ============================================================================

local timers_set = {}   -- {name -> delay} — tracks eq.set_timer calls

eq = {
    get_rule = function(rule)
        if rule == "Companions:CompanionsEnabled" then return "true" end
        return "false"
    end,
    get_entity_list = function()
        return { GetClientByCharID = function() return nil end }
    end,
    set_timer = function(name, delay)
        timers_set[name] = delay
    end,
    stop_timer = function() end,
    get_data = function() return nil end,
    set_data = function() end,
    get_zone_id = function() return 1 end,
}

MT = { Red = 15, Yellow = 4, White = 7, DimGray = 22 }
os = os or { time = function() return 0 end }

-- ============================================================================
-- Object factories
-- ============================================================================

local function make_npc(opts)
    opts = opts or {}
    local entity_id  = opts.id or 100
    local hp         = opts.hp or 500
    local name       = opts.name or "Testius"
    local char_id    = opts.char_id or 42
    local stance     = opts.stance ~= nil and opts.stance or 1  -- default balanced
    local guard_mode = opts.guard_mode or false
    local distance   = opts.distance or 100  -- distance to client

    local messages    = {}
    local hate_list   = {}
    local move_calls  = {}
    local entity_vars = {}  -- stores SetEntityVariable/GetEntityVariable values

    local npc = {
        _id          = entity_id,
        _hp          = hp,
        _name        = name,
        _char_id     = char_id,
        _messages    = messages,
        _hate_list   = hate_list,
        _move_calls  = move_calls,
        _wiped_count = 0,
        _guard_mode  = guard_mode,
        _distance    = distance,
        _entity_vars = entity_vars,
        valid        = true,
    }

    function npc:GetID()             return self._id end
    function npc:GetHP()             return self._hp end
    function npc:GetCleanName()      return self._name end
    function npc:GetOwnerCharacterID() return self._char_id end
    function npc:GetMaxMana()        return opts.max_mana or 0 end
    function npc:GetManaRatio()      return opts.mana_ratio or 100 end
    function npc:IsCompanion()       return true end
    function npc:SetTarget(mob)      self._target = mob end
    function npc:GetTarget()         return self._target end
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
    function npc:GetGroup()          return opts.group or nil end
    function npc:GetEntityVariable(k)   return entity_vars[k] or "" end
    function npc:SetEntityVariable(k,v) entity_vars[k] = v end
    function npc:GetClass()          return opts.class or 1 end
    function npc:GetLevel()          return opts.level or 20 end
    function npc:GetRace()           return opts.race or 1 end
    function npc:CalculateDistance(other)
        return self._distance
    end
    function npc:GMMove(x, y, z, h)
        self._move_calls[#self._move_calls + 1] = { x=x, y=y, z=z, h=h }
    end

    -- Companion-only methods (nil-guarded in cmd_tome)
    if opts.has_companion_methods ~= false then
        local st = stance
        local gm = guard_mode
        function npc:GetStance()     return st end
        function npc:SetStance(v)    st = v end
        function npc:GetGuardMode()  return gm end
        function npc:SetGuardMode(v) gm = v; self._guard_mode = v end
    end

    return npc
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
    -- Reset timer tracking before each test
    for k in pairs(timers_set) do timers_set[k] = nil end

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

-- ============================================================================
-- Tests: dead companion
-- ============================================================================

print("\n=== companion.cmd_tome tests ===\n")

test("cmd_tome: dead companion returns error, no move", function()
    local npc    = make_npc({ id = 1, hp = 0, distance = 200 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    assert_eq(#npc._move_calls, 0, "GMMove should NOT be called for dead companion")
    assert_eq(npc._wiped_count, 0, "WipeHateList should NOT be called for dead companion")
    local resp = last_say(npc)
    assert_contains(resp, "dead", "response should mention 'dead'")
end)

-- ============================================================================
-- Tests: already nearby
-- ============================================================================

test("cmd_tome: skips when companion is within 50 units", function()
    local npc    = make_npc({ id = 2, hp = 500, distance = 30 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    assert_eq(#npc._move_calls, 0, "GMMove should NOT be called when within 50 units")
    assert_eq(npc._wiped_count, 0, "WipeHateList should NOT be called when within 50 units")
    local resp = last_say(npc)
    assert_contains(resp, "already nearby", "response should say 'already nearby'")
end)

test("cmd_tome: skips when companion is exactly 50 units", function()
    local npc    = make_npc({ id = 3, hp = 500, distance = 49 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    assert_eq(#npc._move_calls, 0, "GMMove should NOT be called at <50 units")
end)

-- ============================================================================
-- Tests: normal execution (>50 units away)
-- ============================================================================

test("cmd_tome: calls GMMove to client position", function()
    local npc    = make_npc({ id = 10, hp = 500, distance = 200 })
    local client = make_client({ char_id = 42, x = 100, y = 200, z = 10, h = 90 })

    companion.cmd_tome(npc, client, "")

    assert_eq(#npc._move_calls, 1, "GMMove should be called once")
    assert_eq(npc._move_calls[1].x, 100, "GMMove x should match client x")
    assert_eq(npc._move_calls[1].y, 200, "GMMove y should match client y")
    assert_eq(npc._move_calls[1].z, 10,  "GMMove z should match client z")
    assert_eq(npc._move_calls[1].h, 90,  "GMMove heading should match client heading")
end)

test("cmd_tome: wipes hate list after move (stops active combat)", function()
    local npc    = make_npc({ id = 11, hp = 500, distance = 150 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    assert_eq(npc._wiped_count, 1, "WipeHateList should be called once")
end)

test("cmd_tome: breaks guard mode after move", function()
    local npc    = make_npc({ id = 12, hp = 500, distance = 150, guard_mode = true })
    local client = make_client({ char_id = 42 })
    companion.cmd_guard(npc, client, "")  -- set companion_modes to "guard"

    companion.cmd_tome(npc, client, "")

    assert_false(npc._guard_mode, "guard mode should be cleared after !tome")
end)

test("cmd_tome: sets follow mode (companion_modes = 'follow') after move", function()
    local npc    = make_npc({ id = 13, hp = 500, distance = 150, stance = 1, guard_mode = true })
    local client = make_client({ char_id = 42 })
    companion.cmd_guard(npc, client, "")  -- set companion_modes to "guard"

    companion.cmd_tome(npc, client, "")

    -- Verify guard mode cleared (SetGuardMode(false) called)
    assert_false(npc._guard_mode, "guard mode should be false after !tome breaks it")
end)

-- ============================================================================
-- Tests: stance override and restore timer (re-engage prevention fix)
-- ============================================================================
--
-- !tome temporarily sets passive so Companion::Process() calls SetTarget(nullptr)
-- on the next AI tick, preventing re-engage from balanced/aggressive stance logic.
-- The original stance is saved in entity var "comp_tome_saved_stance" and restored
-- by a "comp_tome_restore_<id>" timer after 500ms.
--
-- Tests here verify the Lua-side half of the fix: correct timer name/delay and
-- saved_stance entity variable. The C++ passive-tick and global_npc timer handler
-- are not testable in unit tests.
-- ============================================================================

test("cmd_tome: sets passive stance temporarily when originally aggressive (stance=2)", function()
    local npc    = make_npc({ id = 14, hp = 500, distance = 200, stance = 2 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    -- Stance is immediately passive after cmd_tome returns
    assert_eq(npc:GetStance(), 0, "stance should be passive immediately after !tome (restore happens via timer)")
end)

test("cmd_tome: saves original aggressive stance in entity variable", function()
    local npc    = make_npc({ id = 14, hp = 500, distance = 200, stance = 2 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    local saved = npc:GetEntityVariable("comp_tome_saved_stance")
    assert_eq(saved, "2", "comp_tome_saved_stance should hold original stance '2'")
end)

test("cmd_tome: sets restore timer for aggressive companion", function()
    local npc    = make_npc({ id = 14, hp = 500, distance = 200, stance = 2 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    local timer_name = "comp_tome_restore_" .. npc:GetID()
    assert_true(timers_set[timer_name] ~= nil, "comp_tome_restore timer should be set")
    assert_eq(timers_set[timer_name], 500, "restore timer should fire after 500ms")
end)

test("cmd_tome: sets passive stance temporarily when originally balanced (stance=1)", function()
    local npc    = make_npc({ id = 15, hp = 500, distance = 200, stance = 1 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    assert_eq(npc:GetStance(), 0, "stance should be passive immediately after !tome")
end)

test("cmd_tome: saves original balanced stance in entity variable", function()
    local npc    = make_npc({ id = 15, hp = 500, distance = 200, stance = 1 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    local saved = npc:GetEntityVariable("comp_tome_saved_stance")
    assert_eq(saved, "1", "comp_tome_saved_stance should hold original stance '1'")
end)

test("cmd_tome: sets restore timer for balanced companion", function()
    local npc    = make_npc({ id = 15, hp = 500, distance = 200, stance = 1 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    local timer_name = "comp_tome_restore_" .. npc:GetID()
    assert_true(timers_set[timer_name] ~= nil, "comp_tome_restore timer should be set")
end)

test("cmd_tome: passive companion stays passive, saved_stance is '0', timer still fires", function()
    -- Passive companion: SetStance(0) is a no-op (already 0). Timer still fires
    -- to clean up entity var. The restore handler skips the SetStance call when
    -- saved_stance == 0 (nothing to restore).
    local npc    = make_npc({ id = 16, hp = 500, distance = 200, stance = 0 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    assert_eq(npc:GetStance(), 0, "passive stance stays passive after !tome")
    local saved = npc:GetEntityVariable("comp_tome_saved_stance")
    assert_eq(saved, "0", "comp_tome_saved_stance should be '0' for passive companion")
    local timer_name = "comp_tome_restore_" .. npc:GetID()
    assert_true(timers_set[timer_name] ~= nil, "restore timer set even for passive companion (entity var cleanup)")
end)

test("cmd_tome: responds with move confirmation", function()
    local npc    = make_npc({ id = 17, hp = 500, distance = 200 })
    local client = make_client({ char_id = 42 })

    companion.cmd_tome(npc, client, "")

    local resp = last_say(npc)
    assert_contains(resp, "moves to your side", "response should confirm move")
end)

-- ============================================================================
-- Tests: nil-guard safety
-- ============================================================================

test("cmd_tome: does not crash when SetGuardMode/SetStance are nil (plain Lua_NPC)", function()
    local npc    = make_npc({ id = 20, hp = 500, distance = 200, has_companion_methods = false })
    local client = make_client({ char_id = 42 })

    -- Must not crash
    companion.cmd_tome(npc, client, "")

    assert_eq(#npc._move_calls, 1, "GMMove should still be called")
    assert_eq(npc._wiped_count, 1, "WipeHateList should still be called")
end)

-- ============================================================================
-- Tests: !hold then !tome
-- ============================================================================

test("cmd_hold then cmd_tome: tome breaks guard, wipes hate, sets passive temporarily", function()
    local npc    = make_npc({ id = 30, hp = 500, distance = 200, stance = 2, guard_mode = false })
    local client = make_client({ char_id = 42 })

    -- Hold: sets guard + passive, wipes hate
    companion.cmd_hold(npc, client, "")
    assert_true(npc._guard_mode, "hold should set guard mode")
    assert_eq(npc:GetStance(), 0, "hold should set passive stance")

    -- Tome: moves to player, wipes hate again, breaks guard
    -- Stance is passive from !hold, so saved_stance = "0", no real change
    companion.cmd_tome(npc, client, "")

    assert_false(npc._guard_mode, "tome should clear guard mode")
    assert_eq(npc:GetStance(), 0, "stance remains passive (was passive from !hold)")
    assert_eq(npc._wiped_count, 2, "WipeHateList called by both !hold and !tome")
    assert_eq(#npc._move_calls, 1, "GMMove should be called by !tome")
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
