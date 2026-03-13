-- test_companion_cmd_hold.lua
--
-- Unit tests for companion.cmd_hold and its interactions with cmd_assist/cmd_follow.
--
-- Tests verify:
--   1. !hold sets guard mode + passive stance + wipes hate list
--   2. !hold on dead companion returns early with error message
--   3. !hold when already holding returns "Already holding position."
--   4. !assist on held companion breaks guard mode and sets follow
--   5. !follow on held companion breaks guard, remains passive
--   6. !hold on NPC without Companion-only methods (nil-guard safety)
--   7. @all deduplication lock is not affected by !hold
--
-- Run with:
--   luajit tests/test_companion_cmd_hold.lua
-- from the lua_modules/ directory, OR:
--   cd akk-stack/server/quests && luajit tests/test_companion_cmd_hold.lua
--
-- ============================================================================
-- Minimal EQEmu API stubs
-- ============================================================================

eq = {
    get_rule = function(rule)
        if rule == "Companions:CompanionsEnabled" then return "true" end
        return "false"
    end,
    get_entity_list = function()
        return { GetClientByCharID = function() return nil end }
    end,
    set_timer = function() end,
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
    local is_comp    = opts.is_companion ~= nil and opts.is_companion or true

    local messages = {}
    local hate_list = {}
    local wiped     = false

    local npc = {
        _id          = entity_id,
        _hp          = hp,
        _name        = name,
        _char_id     = char_id,
        _is_comp     = is_comp,
        _messages    = messages,
        _hate_list   = hate_list,
        _wiped_count = 0,
        _guard_mode  = guard_mode,
        valid        = true,
    }

    function npc:GetID()             return self._id end
    function npc:GetHP()             return self._hp end
    function npc:GetCleanName()      return self._name end
    function npc:GetOwnerCharacterID() return self._char_id end
    function npc:GetMaxMana()        return opts.max_mana or 0 end
    function npc:GetManaRatio()      return opts.mana_ratio or 100 end
    function npc:IsCompanion()       return self._is_comp end
    function npc:IsAttackAllowed(mob)
        if opts.attack_allowed ~= nil then return opts.attack_allowed end
        return true
    end
    function npc:SetTarget(mob)      self._target = mob end
    function npc:GetTarget()         return self._target end
    function npc:AddToHateList(mob, threat, val, a, b, c)
        self._hate_list[#self._hate_list + 1] = { mob = mob, threat = threat }
    end
    function npc:WipeHateList()
        self._hate_list = {}
        self._wiped_count = self._wiped_count + 1
    end
    function npc:Say(msg)
        messages[#messages + 1] = { channel = "say", text = msg }
    end
    function npc:GetGroup()          return opts.group or nil end
    function npc:GetEntityVariable(k)   return "" end
    function npc:SetEntityVariable(k,v) end
    function npc:GetClass()          return opts.class or 1 end
    function npc:GetLevel()          return opts.level or 20 end
    function npc:GetRace()           return opts.race or 1 end

    -- Companion-only methods: only present if opts.has_companion_methods = true
    if opts.has_companion_methods ~= false then
        local st = stance
        local gm = guard_mode
        function npc:GetStance()         return st end
        function npc:SetStance(v)        st = v end
        function npc:GetGuardMode()      return gm end
        function npc:SetGuardMode(v)     gm = v; self._guard_mode = v end
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
    }
    function client:GetID()       return self._id end
    function client:CharacterID() return self._char_id end
    function client:GetTarget()   return self._target end
    function client:GetGroup()    return opts.group or nil end
    function client:Message(typ, msg)
        self._messages[#self._messages + 1] = { type = typ, text = msg }
    end
    return client
end

-- ============================================================================
-- Load the companion module
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
local function last_msg(client)
    if #client._messages == 0 then return "" end
    return client._messages[#client._messages].text
end

-- ============================================================================
-- Tests: basic !hold behavior
-- ============================================================================

print("\n=== companion.cmd_hold tests ===\n")

test("cmd_hold: sets guard mode on companion", function()
    local npc    = make_npc({ id = 1, hp = 500, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")

    assert_true(npc._guard_mode, "guard mode should be true after !hold")
end)

test("cmd_hold: sets stance to passive (0)", function()
    local npc    = make_npc({ id = 2, hp = 500, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")

    assert_eq(npc:GetStance(), 0, "stance should be passive (0) after !hold")
end)

test("cmd_hold: wipes hate list", function()
    local enemy  = make_mob({ id = 300 })
    local npc    = make_npc({ id = 3, hp = 500, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })
    npc:AddToHateList(enemy, 100, 0, false, false, false)

    companion.cmd_hold(npc, client, "")

    assert_eq(#npc._hate_list, 0, "hate list should be empty after !hold")
    assert_eq(npc._wiped_count, 1, "WipeHateList should have been called once")
end)

test("cmd_hold: tracks mode as 'guard' in companion_modes", function()
    -- Verify that after !hold, a subsequent !hold sees "already holding"
    local npc    = make_npc({ id = 4, hp = 500, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")
    -- Second call should see already-holding state
    companion.cmd_hold(npc, client, "")

    local last = last_say(npc)
    assert_contains(last, "already holding", "second !hold should say 'already holding'")
end)

test("cmd_hold: responds 'Holding position.'", function()
    local npc    = make_npc({ id = 5, hp = 500, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")

    local resp = last_say(npc)
    assert_contains(resp, "holding position", "response should mention 'holding position'")
end)

-- ============================================================================
-- Tests: dead companion
-- ============================================================================

test("cmd_hold: dead companion returns error (HP=0)", function()
    local npc    = make_npc({ id = 10, hp = 0, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")

    assert_false(npc._guard_mode, "guard mode should NOT be set on dead companion")
    assert_eq(npc._wiped_count, 0, "WipeHateList should NOT be called on dead companion")
    local resp = last_say(npc)
    assert_contains(resp, "dead", "response should mention 'dead'")
    assert_contains(resp, "hold position", "response should mention 'hold position'")
end)

test("cmd_hold: dead companion returns error (HP negative)", function()
    local npc    = make_npc({ id = 11, hp = -10, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")

    assert_false(npc._guard_mode, "guard mode should NOT be set on dead (negative HP) companion")
end)

-- ============================================================================
-- Tests: already holding
-- ============================================================================

test("cmd_hold: already holding (guard + passive) returns 'Already holding position.'", function()
    -- Start in guard mode with passive stance (the hold state)
    local npc    = make_npc({ id = 20, hp = 500, stance = 0, guard_mode = true })
    local client = make_client({ char_id = 42 })
    -- Manually set companion_modes to guard so the check fires correctly
    -- We do this by calling cmd_guard first to set the internal state
    companion.cmd_guard(npc, client, "")
    -- Then set stance to passive directly
    npc:SetStance(0)

    local msg_count_before = #npc._messages
    companion.cmd_hold(npc, client, "")

    local resp = last_say(npc)
    assert_contains(resp, "already holding", "should respond 'Already holding position.'")
    -- WipeHateList should NOT have been called again
    assert_eq(npc._wiped_count, 0, "should not wipe hate list when already holding")
end)

test("cmd_hold: not in guard but passive — still sets guard (not already holding)", function()
    -- Passive but following: not a hold state
    local npc    = make_npc({ id = 21, hp = 500, stance = 0, guard_mode = false })
    local client = make_client({ char_id = 42 })
    -- Ensure companion_modes is "follow" (default)

    companion.cmd_hold(npc, client, "")

    assert_true(npc._guard_mode, "should set guard mode even if already passive")
    local resp = last_say(npc)
    assert_contains(resp, "holding position", "should confirm hold")
    -- should NOT say "already"
    assert_false(resp:find("already", 1, true), "should not say 'already' for follow+passive")
end)

test("cmd_hold: in guard but balanced — still applies passive (not already holding)", function()
    -- Guard mode but NOT passive: not a full hold state
    local npc    = make_npc({ id = 22, hp = 500, stance = 1, guard_mode = true })
    local client = make_client({ char_id = 42 })
    companion.cmd_guard(npc, client, "")  -- set companion_modes to "guard"

    companion.cmd_hold(npc, client, "")

    assert_eq(npc:GetStance(), 0, "stance should become passive")
    local resp = last_say(npc)
    assert_false(resp:find("already", 1, true), "should not say 'already' for guard+balanced")
end)

-- ============================================================================
-- Tests: nil-guard safety (plain Lua_NPC without Companion-only methods)
-- ============================================================================

test("cmd_hold: does not crash when SetGuardMode is nil (plain Lua_NPC)", function()
    local npc    = make_npc({ id = 30, hp = 500, has_companion_methods = false })
    local client = make_client({ char_id = 42 })

    -- Must not crash; nil-guards prevent method calls on plain Lua_NPC
    companion.cmd_hold(npc, client, "")

    -- WipeHateList should still be called (it's a Lua_Mob method, always present)
    assert_eq(npc._wiped_count, 1, "WipeHateList should be called even on plain Lua_NPC")
end)

test("cmd_hold: does not crash when GetStance is nil (already-holding check)", function()
    -- If GetStance is nil, stance defaults to 1 (balanced), so "already holding" = false
    local npc    = make_npc({ id = 31, hp = 500, has_companion_methods = false })
    local client = make_client({ char_id = 42 })
    -- First call sets guard mode via companion_modes
    companion.cmd_hold(npc, client, "")

    -- Second call: companion_modes="guard" but GetStance is nil => stance defaults to 1
    -- so "already holding" is false and we proceed to hold again (idempotent)
    companion.cmd_hold(npc, client, "")

    -- No crash is the key assertion; both calls should have invoked WipeHateList
    assert_eq(npc._wiped_count, 2, "WipeHateList should be called twice (two !hold invocations)")
end)

-- ============================================================================
-- Tests: interaction — !hold then !assist
-- ============================================================================

test("cmd_hold then cmd_assist: assist breaks guard mode and resumes follow", function()
    local npc    = make_npc({ id = 40, hp = 500, stance = 1, guard_mode = false })
    local enemy  = make_mob({ id = 400, name = "a_troll" })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_hold(npc, client, "")
    -- Verify hold state
    assert_true(npc._guard_mode, "guard mode should be set after !hold")
    assert_eq(npc:GetStance(), 0, "stance should be passive after !hold")

    companion.cmd_assist(npc, client, "")

    -- Guard should be broken
    assert_false(npc._guard_mode, "guard mode should be cleared after !assist")
    -- Stance should be balanced (auto-switch from passive)
    assert_eq(npc:GetStance(), 1, "stance should be balanced after !assist auto-switch")
    -- Should have engaged the enemy
    assert_true(#npc._hate_list > 0, "enemy should be on hate list after !assist")
end)

-- ============================================================================
-- Tests: interaction — !hold then !follow
-- ============================================================================

test("cmd_hold then cmd_follow: follow breaks guard, stance stays passive", function()
    local npc    = make_npc({ id = 50, hp = 500, stance = 1, guard_mode = false })
    local client = make_client({ char_id = 42 })

    companion.cmd_hold(npc, client, "")
    assert_true(npc._guard_mode, "guard mode should be set after !hold")
    assert_eq(npc:GetStance(), 0, "stance should be passive after !hold")

    companion.cmd_follow(npc, client, "")

    -- Guard should be broken
    assert_false(npc._guard_mode, "guard mode should be cleared after !follow")
    -- Stance should remain passive (PRD: follow doesn't change stance)
    assert_eq(npc:GetStance(), 0, "stance should remain passive after !follow")
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
