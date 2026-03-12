-- test_companion_cmd_assist.lua
--
-- Unit tests for companion.cmd_assist and cmd_target.
--
-- These tests run standalone under LuaJIT/Lua 5.1 without a live server.
-- They mock the EQEmu API (npc/client/mob objects) to verify:
--   1. cmd_assist works when called on a Lua_NPC (not Lua_Companion)
--   2. The player_target == npc comparison uses GetID() (BUG-023 fix)
--   3. All nil-guards for Companion-only methods are in place (BUG-021/022)
--   4. The command produces correct behavior with default fallbacks
--
-- Run with:
--   luajit tests/test_companion_cmd_assist.lua
-- from the lua_modules/ directory, OR:
--   cd akk-stack/server/quests && luajit tests/test_companion_cmd_assist.lua
--
-- ============================================================================
-- Minimal EQEmu API stubs
-- ============================================================================

-- Stub 'eq' namespace (used by companion.lua)
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
}

-- Stub MT (message type constants)
MT = { Red = 15, Yellow = 4, White = 7, DimGray = 22 }

-- Stub os (for companion_commentary guard in script_init style)
os = os or { time = function() return 0 end }

-- ============================================================================
-- Object factories
-- ============================================================================

-- Create a mock NPC object.
-- By default has NO Companion-only methods (GetStance, SetStance) to simulate
-- the luabind cast issue (BUG-021): when the companion system receives an NPC
-- via e.self in global_npc.lua, luabind may present it as a plain Lua_NPC
-- without the Companion-specific methods.
local function make_npc(opts)
    opts = opts or {}
    local entity_id   = opts.id or 100
    local hp          = opts.hp or 500
    local name        = opts.name or "Testius"
    local char_id     = opts.char_id or 42   -- owner character ID
    local stance      = opts.stance          -- nil = no GetStance method
    local is_comp     = opts.is_companion ~= nil and opts.is_companion or true

    local messages = {}
    local target = opts.target  -- current target of this NPC

    local npc = {
        _id       = entity_id,
        _hp       = hp,
        _name     = name,
        _char_id  = char_id,
        _is_comp  = is_comp,
        _messages = messages,
        _target   = target,
        _hate_list = {},
        valid = true,
    }

    function npc:GetID()             return self._id end
    function npc:GetHP()             return self._hp end
    function npc:GetCleanName()      return self._name end
    function npc:GetOwnerCharacterID() return self._char_id end
    function npc:GetMaxMana()        return opts.max_mana or 0 end
    function npc:GetManaRatio()      return opts.mana_ratio or 100 end
    function npc:IsCompanion()       return self._is_comp end
    function npc:IsAttackAllowed(mob)
        -- Simulate allow-attack check: returns false for same team (e.g. client)
        if opts.attack_allowed ~= nil then return opts.attack_allowed end
        return true  -- default: attack allowed
    end
    function npc:SetTarget(mob)  self._target = mob end
    function npc:GetTarget()     return self._target end
    function npc:AddToHateList(mob, threat, val, a, b, c)
        self._hate_list[#self._hate_list + 1] = { mob = mob, threat = threat }
    end
    function npc:Say(msg)
        messages[#messages + 1] = { channel = "say", text = msg }
    end
    function npc:GetGroup()   return opts.group or nil end
    function npc:GetEntityVariable(k)  return "" end
    function npc:SetEntityVariable(k, v) end
    function npc:GetClass()   return opts.class or 1 end
    function npc:GetLevel()   return opts.level or 20 end
    function npc:GetRace()    return opts.race or 1 end

    -- Companion-only methods: only present if opts.has_stance = true
    if opts.has_stance then
        local st = stance or 1
        function npc:GetStance() return st end
        function npc:SetStance(v) st = v end
    end

    return npc
end

-- Create a mock Mob object (enemy target)
local function make_mob(opts)
    opts = opts or {}
    local mob = {
        _id   = opts.id or 200,
        _name = opts.name or "a_gnoll",
        valid = (opts.valid ~= false),
    }
    function mob:GetID()        return self._id end
    function mob:GetCleanName() return self._name end
    function mob:IsAttackAllowed(other)
        return opts.attack_allowed ~= false
    end
    return mob
end

-- Create a mock Client object
local function make_client(opts)
    opts = opts or {}
    local client = {
        _id      = opts.id or 1,
        _char_id = opts.char_id or 42,
        _target  = opts.target or nil,
        _messages = {},
        valid = true,
    }
    function client:GetID()         return self._id end
    function client:CharacterID()   return self._char_id end
    function client:GetTarget()     return self._target end
    function client:GetGroup()      return opts.group or nil end
    function client:Message(typ, msg)
        self._messages[#self._messages + 1] = { type = typ, text = msg }
    end
    return client
end

-- ============================================================================
-- Load the companion module
-- We need to set up package.path to find lua_modules from the tests/ directory.
-- ============================================================================

-- Determine path relative to this file
local script_dir = debug.getinfo(1, "S").source:match("^@(.*)tests/") or
                   "./"
package.path = script_dir .. "lua_modules/?.lua;" ..
               script_dir .. "lua_modules/?/init.lua;" ..
               package.path

-- Minimal stubs required before requiring companion
-- (string_ext, json, etc. are pulled in by companion internally)
-- Stub require for modules we don't need
local real_require = require
local stubbed = {
    string_ext = true,
    command    = true,
    client_ext = true,
    mob_ext    = true,
    npc_ext    = true,
    entity_list_ext = true,
    general_ext = true,
    bit        = true,
    directional = true,
    json       = true,
    llm_bridge = true,
    llm_config = true,
    llm_faction = true,
    companion_commentary = true,
    companion_context    = true,
    companion_culture    = true,
    ["constants/instance_versions"] = true,
}

require = function(modname)
    if stubbed[modname] then
        -- Return a minimal no-op table so companion.lua doesn't crash
        return setmetatable({}, { __index = function() return function() end end })
    end
    return real_require(modname)
end

-- Stub Database() global (used in event_timer buff handling)
Database = function()
    return {
        prepare  = function(self, sql) return {
            execute = function() end,
            fetch_hash = function() return nil end,
        } end,
        close = function() end,
    }
end

-- Now load companion
local ok, companion = pcall(require, "companion")
if not ok then
    error("Failed to load companion module: " .. tostring(companion))
end

require = real_require  -- restore

-- ============================================================================
-- Test framework
-- ============================================================================

local PASS = 0
local FAIL = 0
local ERRORS = {}

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
    if not v then
        error((msg or "assertion failed") .. ": expected true, got " .. tostring(v), 2)
    end
end

local function assert_false(v, msg)
    if v then
        error((msg or "assertion failed") .. ": expected false, got " .. tostring(v), 2)
    end
end

local function assert_contains(str, sub, msg)
    if not str:find(sub, 1, true) then
        error((msg or "string assertion failed") ..
              ": '" .. sub .. "' not found in '" .. str .. "'", 2)
    end
end

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== companion.cmd_assist tests ===\n")

-- ------------------------------------------------------------------
-- BUG-023: player_target == npc cross-type luabind __eq
-- This is the critical regression test for the fix.
-- ------------------------------------------------------------------

test("BUG-023: cmd_assist does not crash with luabind cross-type __eq (npc is own target)", function()
    -- Create an NPC (no Companion-only methods) and a client whose
    -- target is the companion NPC itself. Before the fix, this would
    -- emit "No such operator defined" for __eq.
    local npc    = make_npc({ id = 100, hp = 500 })
    -- client's target has the SAME ID as the companion
    local target = make_mob({ id = 100, name = "Testius" })
    local client = make_client({ char_id = 42, target = target })

    -- Must not raise
    companion.cmd_assist(npc, client, "")

    -- Companion should decline to attack itself
    assert_eq(#npc._hate_list, 0, "hate list should be empty when targeting self")
end)

test("BUG-023: cmd_assist uses GetID() identity check (not luabind __eq)", function()
    -- Two different objects with the same ID — both represent the companion.
    -- The fix should match them as the same entity, preventing self-attack.
    local npc    = make_npc({ id = 77, hp = 400 })
    local target = make_mob({ id = 77, name = "SameIdMob" })  -- same ID
    local client = make_client({ char_id = 42, target = target })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "same-ID target should be refused (self-attack guard)")
end)

test("BUG-023: cmd_assist attacks different-ID target normally", function()
    -- Target has a DIFFERENT ID from the companion — should engage.
    local enemy  = make_mob({ id = 999, name = "a_gnoll" })
    local npc    = make_npc({ id = 100, hp = 400, has_stance = true })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    assert_true(#npc._hate_list > 0, "companion should engage the enemy")
    assert_eq(npc._hate_list[1].mob._id, 999, "hate target should be the enemy")
end)

-- ------------------------------------------------------------------
-- BUG-021/022: nil-guard for Companion-only methods
-- ------------------------------------------------------------------

test("BUG-021: cmd_assist does not crash when GetStance is nil (plain Lua_NPC)", function()
    -- NPC without GetStance/SetStance (plain Lua_NPC cast, BUG-021 scenario)
    local enemy  = make_mob({ id = 500, name = "a_troll" })
    local npc    = make_npc({ id = 10, hp = 300, has_stance = false })
    local client = make_client({ char_id = 42, target = enemy })

    -- Should not crash; GetStance nil-guard defaults to balanced (stance=1)
    companion.cmd_assist(npc, client, "")

    assert_true(#npc._hate_list > 0, "companion should engage even without GetStance")
end)

test("BUG-021: cmd_assist auto-switches stance when GetStance is available and returns 0", function()
    -- NPC with GetStance returning 0 (passive) — should auto-switch to balanced
    local enemy  = make_mob({ id = 501, name = "a_gnoll" })
    local npc    = make_npc({ id = 11, hp = 300, has_stance = true, stance = 0 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    assert_true(#npc._hate_list > 0, "companion should engage after stance auto-switch")
    -- Verify SetStance was called (stance should now be 1)
    assert_eq(npc:GetStance(), 1, "stance should be set to balanced (1) after auto-switch")
end)

test("BUG-021: cmd_assist skips SetStance when method unavailable (nil-guard)", function()
    -- NPC without SetStance — passive detection falls back to default (1 = balanced)
    -- so switched_stance is false and no error
    local enemy  = make_mob({ id = 502, name = "a_spider" })
    local npc    = make_npc({ id = 12, hp = 300, has_stance = false })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    -- Should engage (default stance is balanced)
    assert_true(#npc._hate_list > 0, "companion should engage with default balanced stance")
end)

-- ------------------------------------------------------------------
-- Dead companion
-- ------------------------------------------------------------------

test("cmd_assist refuses to fight when companion is dead (HP <= 0)", function()
    local enemy  = make_mob({ id = 600 })
    local npc    = make_npc({ id = 20, hp = 0 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "dead companion should not add to hate list")
end)

test("cmd_assist refuses when HP is negative (already dead)", function()
    local enemy  = make_mob({ id = 601 })
    local npc    = make_npc({ id = 21, hp = -50 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "negative-HP companion should not add to hate list")
end)

-- ------------------------------------------------------------------
-- No target
-- ------------------------------------------------------------------

test("cmd_assist refuses when client has no target", function()
    local npc    = make_npc({ id = 30, hp = 400 })
    local client = make_client({ char_id = 42, target = nil })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "no-target should produce no hate list entry")
end)

test("cmd_assist refuses when client's target is invalid", function()
    local invalid_target = { valid = false, GetID = function() return 0 end,
                              GetCleanName = function() return "" end }
    local npc    = make_npc({ id = 31, hp = 400 })
    local client = make_client({ char_id = 42, target = invalid_target })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "invalid-target should produce no hate list entry")
end)

-- ------------------------------------------------------------------
-- Friendly target check
-- ------------------------------------------------------------------

test("cmd_assist refuses to attack a friendly (IsAttackAllowed returns false)", function()
    local friendly = make_mob({ id = 700, name = "friendly_npc" })
    local npc      = make_npc({ id = 40, hp = 400, attack_allowed = false })
    local client   = make_client({ char_id = 42, target = friendly })

    companion.cmd_assist(npc, client, "")

    assert_eq(#npc._hate_list, 0, "companion should not attack a friendly")
end)

-- ------------------------------------------------------------------
-- cmd_target (related command, also uses player_target)
-- ------------------------------------------------------------------

test("cmd_target does not crash on plain Lua_NPC (no GetStance)", function()
    local enemy  = make_mob({ id = 800, name = "a_skeleton" })
    local npc    = make_npc({ id = 50, hp = 500, has_stance = false })
    local client = make_client({ char_id = 42, target = enemy })

    -- Must not raise
    companion.cmd_target(npc, client, "")

    assert_eq(npc._target._id, 800, "target should be set to enemy")
    -- Default stance is 1 (balanced) so hate list should be populated
    assert_true(#npc._hate_list > 0, "should add to hate list when stance is balanced")
end)

test("cmd_target does not add to hate list when stance is passive (0)", function()
    local enemy  = make_mob({ id = 801, name = "a_zombie" })
    local npc    = make_npc({ id = 51, hp = 500, has_stance = true, stance = 0 })
    local client = make_client({ char_id = 42, target = enemy })

    companion.cmd_target(npc, client, "")

    assert_eq(npc._target._id, 801, "target should still be set in passive stance")
    assert_eq(#npc._hate_list, 0, "passive stance should not add to hate list")
end)

test("cmd_target refuses when client has no target", function()
    local npc    = make_npc({ id = 52, hp = 500 })
    local client = make_client({ char_id = 42, target = nil })

    companion.cmd_target(npc, client, "")

    assert_eq(npc._target, nil, "target should not be set when client has no target")
end)

-- ------------------------------------------------------------------
-- Summary
-- ------------------------------------------------------------------

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
