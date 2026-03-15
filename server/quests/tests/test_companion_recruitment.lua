-- test_companion_recruitment.lua
--
-- Tests for the two-track companion recruitment system.
-- Covers:
--   - First-time recruitment: within level range, outside level range rejected
--   - First-time recruitment: cooldown blocking, failure sets cooldown
--   - Re-recruitment after death (is_suspended=1): bypasses all first-time checks
--   - Re-recruitment after dismissal (is_dismissed=1): same bypasses
--   - Re-recruitment after group wipe (multiple companions)
--   - Safety checks still enforced on re-recruitment (combat, group capacity, disabled)
--   - Stale cooldown deleted on re-recruitment success
--   - check_existing_companion_record() vs check_dismissed_record() distinction
--   - First-time recruitment regression (is_eligible_npc() all checks still run)
--   - Edge cases: cur_hp=0, both flags set, faction bypass, persuasion bypass,
--     is_recruited block, cooldown not deleted on failure, LIMIT 1 behavior
--
-- Run with:
--   luajit tests/test_companion_recruitment.lua
-- from the akk-stack/server/quests/ directory.
--
-- ============================================================================
-- EQEmu API stubs
-- ============================================================================

local data_store = {}

eq = {
    get_rule = function(rule)
        if rule == "Companions:CompanionsEnabled"  then return "true" end
        if rule == "Companions:LevelRange"         then return "3" end
        if rule == "Companions:MinFaction"         then return "3" end
        if rule == "Companions:BaseRecruitChance"  then return "50" end
        if rule == "Companions:RecruitCooldownS"   then return "900" end
        return "false"
    end,
    get_data    = function(key)       return data_store[key] end,
    set_data    = function(key, val, ttl) data_store[key] = val end,
    delete_data = function(key)       data_store[key] = nil end,
    get_entity_list = function()
        return { GetClientByCharID = function() return nil end }
    end,
    set_timer   = function() end,
    stop_timer  = function() end,
    get_zone_id = function() return 1 end,
}

MT = { Red = 15, Yellow = 4, White = 7, DimGray = 22 }
os = os or { time = function() return 0 end }

-- ============================================================================
-- Object factories
-- ============================================================================

local function make_group(count)
    return {
        valid = true,
        GroupCount = function(self) return count end,
        GroupMessage = function(self, npc, msg) end,
    }
end

local function make_npc(opts)
    opts = opts or {}
    local messages = {}
    local entity_vars = {}

    local npc = {
        _id           = opts.id or 100,
        _hp           = opts.hp or 500,
        _name         = opts.name or "Test NPC",
        _level        = opts.level or 20,
        _npc_type_id  = opts.npc_type_id or 1001,
        _race         = opts.race or 1,
        _faction_id   = opts.faction_id or 0,
        _engaged      = opts.engaged or false,
        _is_companion = opts.is_companion or false,
        _is_pet       = opts.is_pet or false,
        _is_bot       = opts.is_bot or false,
        _is_merc      = opts.is_merc or false,
        _bodytype     = opts.bodytype or 1,
        _messages     = messages,
        _entity_vars  = entity_vars,
        valid         = true,
    }
    function npc:GetID()              return self._id end
    function npc:GetName()            return self._name end
    function npc:GetCleanName()       return self._name end
    function npc:GetLevel()           return self._level end
    function npc:GetNPCTypeID()       return self._npc_type_id end
    function npc:GetRace()            return self._race end
    function npc:GetNPCFactionID()    return self._faction_id end
    function npc:GetBodyType()        return self._bodytype end
    function npc:IsEngaged()          return self._engaged end
    function npc:IsCompanion()        return self._is_companion end
    function npc:IsPet()              return self._is_pet end
    function npc:IsBot()              return self._is_bot end
    function npc:IsMerc()             return self._is_merc end
    function npc:GetEntityVariable(k) return self._entity_vars[k] or "" end
    function npc:SetEntityVariable(k, v) self._entity_vars[k] = v end
    function npc:Say(msg)
        messages[#messages + 1] = { channel = "say", text = msg }
    end
    return npc
end

local function make_client(opts)
    opts = opts or {}
    local messages = {}

    local client = {
        _char_id     = opts.char_id or 42,
        _level       = opts.level or 20,
        _aggro_count = opts.aggro_count or 0,
        _group       = opts.group or nil,
        _cha         = opts.cha or 100,
        _messages    = messages,
        _companions  = {},
        valid        = true,
    }
    function client:CharacterID()   return self._char_id end
    function client:GetLevel()      return self._level end
    function client:GetAggroCount() return self._aggro_count end
    function client:GetGroup()      return self._group end
    function client:GetCHA()        return self._cha end
    function client:GetSTR()        return 100 end
    function client:GetINT()        return 100 end
    function client:GetCharacterFactionLevel(faction_id) return opts.faction_level or 3 end
    function client:Message(typ, msg)
        messages[#messages + 1] = { type = typ, text = msg }
    end
    function client:CreateCompanion(npc)
        -- Stub: returns a mock companion entity on success, nil if opts.create_fails
        if opts.create_fails then return nil end
        local comp = { valid = true, _npc = npc }
        self._companions[#self._companions + 1] = comp
        return comp
    end
    return client
end

-- ============================================================================
-- Database stub factory
-- ============================================================================
-- Returns a Database() constructor that yields the given row from fetch_hash().
-- Pass nil to simulate "no record found".
local function make_db_stub(row)
    return function()
        return {
            prepare = function(self, sql)
                return {
                    execute   = function(self, params) end,
                    fetch_hash = function(self) return row end,
                }
            end,
            close = function(self) end,
        }
    end
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
-- Default Database: no record found
Database = make_db_stub(nil)

local ok, companion = pcall(require, "companion")
if not ok then error("Failed to load companion module: " .. tostring(companion)) end
require = real_require

-- ============================================================================
-- Test framework
-- ============================================================================

local PASS, FAIL, ERRORS = 0, 0, {}
local function test(name, fn)
    data_store = {}
    Database = make_db_stub(nil)  -- reset DB stub before each test
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
local function assert_nil(v, msg)
    if v ~= nil then error((msg or "expected nil") .. ": got " .. tostring(v), 2) end
end
local function assert_not_nil(v, msg)
    if v == nil then error((msg or "expected non-nil value"), 2) end
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
local function all_client_msgs(client)
    local out = ""
    for _, m in ipairs(client._messages) do out = out .. m.text end
    return out
end

-- ============================================================================
-- check_existing_companion_record()
-- ============================================================================

print("\n=== check_existing_companion_record() ===\n")

test("returns nil when no record exists", function()
    Database = make_db_stub(nil)
    local row = companion.check_existing_companion_record(1001, 42)
    assert_nil(row, "should return nil when no record in DB")
end)

test("returns record when is_suspended=1 (dead companion)", function()
    local fake_row = {
        id = 7, level = 38, experience = 50000, recruited_level = 20,
        stance = 1, name = "Aria", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)
    local row = companion.check_existing_companion_record(1001, 42)
    assert_not_nil(row, "should return record for suspended companion")
    assert_eq(row.is_suspended, 1, "is_suspended should be 1")
    assert_eq(row.level, 38, "level should be restored from DB row")
end)

test("returns record when is_dismissed=1 (voluntarily dismissed companion)", function()
    local fake_row = {
        id = 8, level = 25, experience = 10000, recruited_level = 18,
        stance = 1, name = "Brom", companion_type = 0,
        is_dismissed = 1, is_suspended = 0,
    }
    Database = make_db_stub(fake_row)
    local row = companion.check_existing_companion_record(1001, 42)
    assert_not_nil(row, "should return record for dismissed companion")
    assert_eq(row.is_dismissed, 1, "is_dismissed should be 1")
end)

test("returns nil when both flags are 0 (active companion — should not happen in practice)", function()
    -- The SQL WHERE clause requires is_dismissed=1 OR is_suspended=1.
    -- The DB stub always returns whatever row we give it, so we test that a nil
    -- row is propagated correctly. In production, an active companion has both=0
    -- and would not be returned by the query — this stub tests the nil propagation path.
    Database = make_db_stub(nil)
    local row = companion.check_existing_companion_record(1001, 42)
    assert_nil(row, "active companion (both flags 0) should not match the query")
end)

-- ============================================================================
-- is_re_recruitment_eligible()
-- ============================================================================

print("\n=== is_re_recruitment_eligible() ===\n")

test("returns true when all safety checks pass", function()
    local npc    = make_npc({ engaged = false, is_companion = false })
    local client = make_client({ aggro_count = 0 })
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(ok, "should be eligible when all checks pass")
    assert_nil(reason, "reason should be nil on success")
end)

test("blocks when companion system is disabled", function()
    local orig = eq.get_rule
    eq.get_rule = function(r)
        if r == "Companions:CompanionsEnabled" then return "false" end
        return orig(r)
    end
    local npc    = make_npc({})
    local client = make_client({})
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    eq.get_rule = orig
    assert_true(not ok, "should block when system disabled")
    assert_contains(reason, "not available", "reason should mention not available")
end)

test("blocks when group is full (6 members)", function()
    local npc    = make_npc({})
    local client = make_client({ group = make_group(6) })
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(not ok, "should block full group")
    assert_contains(reason, "full", "reason should mention full")
end)

test("passes when group has 5 members (room for one more)", function()
    local npc    = make_npc({ is_companion = false })
    local client = make_client({ group = make_group(5) })
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(ok, "5-member group should have room for re-recruit")
end)

test("passes when client has no group", function()
    local npc    = make_npc({ is_companion = false })
    local client = make_client({ group = nil })
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(ok, "no group is fine for re-recruitment")
end)

test("blocks when NPC already recruited by someone else", function()
    local npc = make_npc({})
    npc._entity_vars["is_recruited"] = "1"
    local client = make_client({})
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(not ok, "should block already-recruited NPC")
    assert_contains(reason, "already joined", "reason should mention already joined")
end)

test("blocks when NPC is in combat", function()
    local npc    = make_npc({ engaged = true })
    local client = make_client({})
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(not ok, "should block NPC in combat")
    assert_contains(reason, "combat", "reason should mention combat")
end)

test("blocks when client is in combat", function()
    local npc    = make_npc({ engaged = false })
    local client = make_client({ aggro_count = 3 })
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(not ok, "should block client in combat")
    assert_contains(reason, "combat", "reason should mention combat")
end)

test("blocks when NPC is already a Companion instance", function()
    local npc    = make_npc({ is_companion = true })
    local client = make_client({})
    local ok, reason = companion.is_re_recruitment_eligible(npc, client)
    assert_true(not ok, "should block Companion instance")
    assert_contains(reason, "companion", "reason should mention companion")
end)

-- ============================================================================
-- attempt_recruitment(): re-recruitment track (is_suspended=1 — dead companion)
-- ============================================================================

print("\n=== attempt_recruitment(): Re-recruitment after death (is_suspended=1) ===\n")

test("re-recruitment succeeds immediately — no cooldown check", function()
    local fake_row = {
        id = 10, level = 38, experience = 50000, recruited_level = 20,
        stance = 1, name = "Aria", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)
    -- Pre-set a stale cooldown — should NOT block re-recruitment
    data_store["companion_cooldown_1001_42"] = "1"

    local npc    = make_npc({ npc_type_id = 1001, level = 20 })
    local client = make_client({ char_id = 42, level = 40 })

    companion.attempt_recruitment(npc, client)

    -- Success: NPC says "I remember you"
    assert_contains(last_say(npc), "remember", "should say 'I remember you'")
    -- Companion was created
    assert_eq(#client._companions, 1, "companion should be created")
end)

test("re-recruitment: stale cooldown is deleted after success", function()
    local fake_row = {
        id = 11, level = 35, experience = 30000, recruited_level = 18,
        stance = 1, name = "Brom", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)
    data_store["companion_cooldown_1001_42"] = "1"  -- stale cooldown

    local npc    = make_npc({ npc_type_id = 1001 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_nil(data_store["companion_cooldown_1001_42"],
               "stale cooldown should be deleted after re-recruitment")
end)

test("re-recruitment: bypasses level range — NPC 20 levels below player", function()
    local fake_row = {
        id = 12, level = 38, experience = 50000, recruited_level = 18,
        stance = 1, name = "Aria", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    -- Player level 40, NPC level 20 — would fail first-time ±3 check
    local npc    = make_npc({ npc_type_id = 1001, level = 20 })
    local client = make_client({ char_id = 42, level = 40 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember", "should succeed despite level gap")
end)

test("re-recruitment: NPC marked as recruited after success", function()
    local fake_row = {
        id = 13, level = 30, experience = 15000, recruited_level = 22,
        stance = 1, name = "Crix", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 1001 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_eq(npc._entity_vars["is_recruited"], "1",
              "NPC entity variable is_recruited should be set to 1")
end)

-- ============================================================================
-- attempt_recruitment(): re-recruitment track (is_dismissed=1 — voluntary dismissal)
-- ============================================================================

print("\n=== attempt_recruitment(): Re-recruitment after dismissal (is_dismissed=1) ===\n")

test("re-recruitment after dismissal succeeds immediately", function()
    local fake_row = {
        id = 20, level = 25, experience = 10000, recruited_level = 20,
        stance = 1, name = "Dana", companion_type = 0,
        is_dismissed = 1, is_suspended = 0,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 2001 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember",
                    "dismissed companion should get 'I remember you' on re-recruit")
end)

test("re-recruitment after dismissal: cooldown does not block", function()
    local fake_row = {
        id = 21, level = 22, experience = 5000, recruited_level = 20,
        stance = 1, name = "Elara", companion_type = 0,
        is_dismissed = 1, is_suspended = 0,
    }
    Database = make_db_stub(fake_row)
    data_store["companion_cooldown_2001_42"] = "1"

    local npc    = make_npc({ npc_type_id = 2001 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember",
                    "cooldown should not block re-recruitment after dismissal")
end)

-- ============================================================================
-- attempt_recruitment(): re-recruitment safety checks still enforced
-- ============================================================================

print("\n=== attempt_recruitment(): Safety checks on re-recruitment ===\n")

test("re-recruitment blocked when client in combat", function()
    local fake_row = {
        id = 30, level = 30, experience = 20000, recruited_level = 20,
        stance = 1, name = "Fenn", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 3001 })
    local client = make_client({ char_id = 42, aggro_count = 2 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "combat",
                    "should block re-recruitment when client in combat")
    assert_eq(#client._companions, 0, "companion should not be created")
end)

test("re-recruitment blocked when NPC in combat", function()
    local fake_row = {
        id = 31, level = 30, experience = 20000, recruited_level = 20,
        stance = 1, name = "Garro", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 3001, engaged = true })
    local client = make_client({ char_id = 42, aggro_count = 0 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "combat",
                    "should block re-recruitment when NPC in combat")
end)

test("re-recruitment blocked when group is full", function()
    local fake_row = {
        id = 32, level = 28, experience = 18000, recruited_level = 20,
        stance = 1, name = "Hessa", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 3001 })
    local client = make_client({ char_id = 42, group = make_group(6) })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "full",
                    "should block re-recruitment when group full")
end)

test("re-recruitment blocked when companion system disabled", function()
    local orig = eq.get_rule
    eq.get_rule = function(r)
        if r == "Companions:CompanionsEnabled" then return "false" end
        return orig(r)
    end
    local fake_row = {
        id = 33, level = 25, experience = 10000, recruited_level = 20,
        stance = 1, name = "Ira", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 3001 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)
    eq.get_rule = orig

    assert_contains(last_client_msg(client), "not available",
                    "should block when system disabled")
end)

test("re-recruitment blocked when NPC is_recruited=1 entity var set", function()
    -- is_recruited entity var is set when another client has already initiated
    -- recruitment of the same NPC. Safety check prevents double-recruitment.
    local fake_row = {
        id = 34, level = 25, experience = 10000, recruited_level = 20,
        stance = 1, name = "Juno", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc = make_npc({ npc_type_id = 3002 })
    npc._entity_vars["is_recruited"] = "1"
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "already joined",
                    "is_recruited=1 should block re-recruitment")
    assert_eq(#client._companions, 0, "companion should not be created")
end)

-- ============================================================================
-- attempt_recruitment(): group wipe recovery (multiple companions)
-- ============================================================================

print("\n=== attempt_recruitment(): Group wipe recovery ===\n")

test("group wipe: first companion re-recruits successfully", function()
    local fake_row1 = {
        id = 40, level = 38, experience = 50000, recruited_level = 20,
        stance = 1, name = "Cleric", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row1)

    local npc    = make_npc({ npc_type_id = 4001 })
    local client = make_client({ char_id = 42, group = make_group(1) })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember", "first companion should re-recruit")
    assert_eq(#client._companions, 1, "first companion created")
end)

test("group wipe: second companion re-recruits independently (no cross-interference)", function()
    -- Each companion has its own npc_type_id and cooldown key
    local fake_row2 = {
        id = 41, level = 37, experience = 45000, recruited_level = 18,
        stance = 1, name = "Warrior", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row2)
    -- First companion's cooldown key should not interfere
    data_store["companion_cooldown_4001_42"] = "1"

    local npc    = make_npc({ npc_type_id = 4002 })
    local client = make_client({ char_id = 42, group = make_group(2) })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember",
                    "second companion re-recruits independently")
end)

test("group wipe: cooldown keys are independent per npc_type_id", function()
    -- Re-recruiting companion A should only delete companion A's cooldown key
    local fake_row = {
        id = 42, level = 36, experience = 40000, recruited_level = 16,
        stance = 1, name = "Rogue", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)
    data_store["companion_cooldown_4003_42"] = "1"  -- this companion's key
    data_store["companion_cooldown_4004_42"] = "1"  -- another companion's key

    local npc    = make_npc({ npc_type_id = 4003 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_nil(data_store["companion_cooldown_4003_42"],
               "this companion's cooldown should be deleted")
    assert_eq(data_store["companion_cooldown_4004_42"], "1",
              "other companion's cooldown should NOT be touched")
end)

-- ============================================================================
-- attempt_recruitment(): first-time recruitment track (unchanged behavior)
-- ============================================================================

print("\n=== attempt_recruitment(): First-time recruitment (regression) ===\n")

test("first-time recruitment: no existing record → runs eligibility checks", function()
    -- No DB record (default stub returns nil)
    -- NPC is out of level range (player 40, NPC 20, range ±3) → should fail
    local npc    = make_npc({ npc_type_id = 5001, level = 20 })
    local client = make_client({ char_id = 42, level = 40 })

    companion.attempt_recruitment(npc, client)

    -- Should hit level range check in is_eligible_npc()
    assert_contains(last_client_msg(client), "level",
                    "first-time recruitment should enforce level range")
    assert_eq(#client._companions, 0, "companion should not be created")
end)

test("first-time recruitment: cooldown blocks attempt", function()
    data_store["companion_cooldown_5001_42"] = "1"

    local npc    = make_npc({ npc_type_id = 5001, level = 20 })
    local client = make_client({ char_id = 42, level = 20 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "soon",
                    "cooldown should block first-time re-attempt")
end)

test("first-time recruitment: failed roll sets cooldown", function()
    -- Force a failed roll: override math.random to return 100 (always fails with base 50%)
    local orig_random = math.random
    math.random = function(a, b) return 100 end

    local npc    = make_npc({ npc_type_id = 5002, level = 20 })
    local client = make_client({ char_id = 42, level = 20 })

    companion.attempt_recruitment(npc, client)
    math.random = orig_random

    assert_eq(data_store["companion_cooldown_5002_42"], "1",
              "failed first-time roll should set cooldown")
    assert_contains(last_say(npc), "not join",
                    "NPC should say refusal on failure")
end)

test("first-time recruitment: successful roll creates companion (first-time dialogue)", function()
    -- Force a successful roll: always roll 1
    local orig_random = math.random
    math.random = function(a, b) return 1 end

    local npc    = make_npc({ npc_type_id = 5003, level = 20 })
    local client = make_client({ char_id = 42, level = 20 })

    companion.attempt_recruitment(npc, client)
    math.random = orig_random

    assert_contains(last_say(npc), "I will join you",
                    "first-time success should say 'I will join you'")
    assert_eq(#client._companions, 1, "companion should be created on success")
end)

test("first-time recruitment: faction below Kindly blocks attempt", function()
    local npc    = make_npc({ npc_type_id = 5004, level = 20, faction_id = 100 })
    -- faction_level 4 = Amiably (below Kindly=3 threshold)
    local client = make_client({ char_id = 42, level = 20, faction_level = 4 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "faction",
                    "low faction should block first-time recruitment")
end)

test("first-time recruitment: NPC that is a Companion instance is blocked", function()
    local npc    = make_npc({ npc_type_id = 5005, level = 20, is_companion = true })
    local client = make_client({ char_id = 42, level = 20 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "companion",
                    "Companion instance should be blocked at first-time eligibility check")
end)

test("first-time recruitment: no cooldown set on success", function()
    local orig_random = math.random
    math.random = function(a, b) return 1 end

    local npc    = make_npc({ npc_type_id = 5006, level = 20 })
    local client = make_client({ char_id = 42, level = 20 })

    companion.attempt_recruitment(npc, client)
    math.random = orig_random

    assert_nil(data_store["companion_cooldown_5006_42"],
               "cooldown should NOT be set after successful first-time recruitment")
end)

-- ============================================================================
-- _on_recruitment_success(): C++ failure path
-- ============================================================================

print("\n=== _on_recruitment_success(): C++ failure handling ===\n")

test("C++ CreateCompanion failure: NPC entity variable cleared, error shown", function()
    local fake_row = {
        id = 60, level = 30, experience = 20000, recruited_level = 20,
        stance = 1, name = "Jax", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 6001 })
    local client = make_client({ char_id = 42, create_fails = true })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_client_msg(client), "went wrong",
                    "should show error when C++ fails")
    assert_eq(npc._entity_vars["is_recruited"], "0",
              "is_recruited should be cleared on C++ failure")
end)

-- ============================================================================
-- check_dismissed_record() still works (backward compatibility / deprecation)
-- ============================================================================

print("\n=== check_dismissed_record(): Backward compatibility ===\n")

test("check_dismissed_record: still returns is_dismissed=1 rows", function()
    local fake_row = {
        id = 70, level = 25, experience = 8000, recruited_level = 20,
        stance = 1, name = "Kira", companion_type = 0,
    }
    Database = make_db_stub(fake_row)
    local row = companion.check_dismissed_record(7001, 42)
    assert_not_nil(row, "check_dismissed_record should still return dismissed rows")
end)

test("check_dismissed_record: returns nil when no record found", function()
    Database = make_db_stub(nil)
    local row = companion.check_dismissed_record(7001, 42)
    assert_nil(row, "check_dismissed_record should return nil when no record")
end)

-- ============================================================================
-- Edge cases: additional coverage per Task #2 requirements
-- ============================================================================

print("\n=== Edge cases ===\n")

test("re-recruitment: cur_hp=0 in DB row — Lua proceeds (C++ handles HP restore)", function()
    -- A companion that died and was marked is_suspended=1 will have cur_hp=0 in the DB.
    -- Lua should not check cur_hp — it proceeds and C++ restores HP on Load().
    local fake_row = {
        id = 80, level = 30, experience = 20000, recruited_level = 20,
        stance = 1, name = "Mort", companion_type = 0,
        is_dismissed = 0, is_suspended = 1, cur_hp = 0,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 8001 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    -- Should succeed — Lua does not block on cur_hp=0
    assert_contains(last_say(npc), "remember",
                    "cur_hp=0 in DB should not block re-recruitment")
    assert_eq(#client._companions, 1, "companion should be created despite cur_hp=0")
end)

test("re-recruitment: is_suspended=1 AND is_dismissed=1 simultaneously — still re-recruits", function()
    -- Edge case: both flags set (e.g., companion died then was also flagged dismissed).
    -- check_existing_companion_record() queries (is_dismissed=1 OR is_suspended=1) so
    -- either flag alone or both together routes to the re-recruitment track.
    local fake_row = {
        id = 81, level = 28, experience = 15000, recruited_level = 20,
        stance = 1, name = "Deva", companion_type = 0,
        is_dismissed = 1, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 8002 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember",
                    "both flags set should still trigger re-recruitment track")
    assert_eq(#client._companions, 1, "companion should be created")
end)

test("re-recruitment: ignores faction — faction=4 (Amiably) does not block", function()
    -- faction_level=4 would block first-time recruitment (MinFaction=3 requires Kindly).
    -- Re-recruitment skips faction check entirely.
    local fake_row = {
        id = 82, level = 25, experience = 10000, recruited_level = 20,
        stance = 1, name = "Fend", companion_type = 0,
        is_dismissed = 1, is_suspended = 0,
    }
    Database = make_db_stub(fake_row)

    -- NPC has a faction ID and client has faction level 4 (Amiably — below threshold)
    local npc    = make_npc({ npc_type_id = 8003, faction_id = 200 })
    local client = make_client({ char_id = 42, level = 20, faction_level = 4 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember",
                    "re-recruitment should ignore faction check (Amiably is fine)")
    assert_eq(#client._companions, 1, "companion should be created despite low faction")
end)

test("re-recruitment: ignores persuasion roll — succeeds even when random always returns 100", function()
    -- First-time recruitment would fail if math.random always returns 100 (above 50% base).
    -- Re-recruitment track skips the persuasion roll entirely.
    local orig_random = math.random
    math.random = function(a, b) return 100 end  -- worst possible roll

    local fake_row = {
        id = 83, level = 25, experience = 10000, recruited_level = 20,
        stance = 1, name = "Grix", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 8004 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)
    math.random = orig_random

    assert_contains(last_say(npc), "remember",
                    "re-recruitment should not be blocked by a worst-case persuasion roll")
    assert_eq(#client._companions, 1, "companion should be created regardless of roll")
end)

test("first-time: cooldown NOT deleted after failed roll", function()
    -- A first-time failure sets a cooldown. Verify eq.delete_data() is NOT called
    -- (the cooldown should remain in data_store after failure).
    local orig_random = math.random
    math.random = function(a, b) return 100 end  -- always fail

    local npc    = make_npc({ npc_type_id = 8005, level = 20 })
    local client = make_client({ char_id = 42, level = 20 })

    companion.attempt_recruitment(npc, client)
    math.random = orig_random

    -- Cooldown should be SET (by failure), not deleted
    assert_eq(data_store["companion_cooldown_8005_42"], "1",
              "cooldown should be SET after first-time failure, not deleted")
end)

test("LIMIT 1: check_existing_companion_record returns one row even when multiple could match", function()
    -- The SQL uses LIMIT 1. The DB stub always returns one row.
    -- Verify that receiving a single row (whichever the DB chooses) works correctly.
    -- In production, multiple rows with the same npc_type_id+owner+flags shouldn't exist,
    -- but LIMIT 1 guarantees graceful handling if they do.
    local fake_row = {
        id = 91, level = 30, experience = 20000, recruited_level = 20,
        stance = 1, name = "First", companion_type = 0,
        is_dismissed = 1, is_suspended = 0,
    }
    Database = make_db_stub(fake_row)

    local row = companion.check_existing_companion_record(9001, 42)
    assert_not_nil(row, "should return the first matching row")
    assert_eq(row.id, 91, "should return the row the DB provided (LIMIT 1)")

    -- Re-recruitment proceeds with this single row
    local npc    = make_npc({ npc_type_id = 9001 })
    local client = make_client({ char_id = 42 })
    companion.attempt_recruitment(npc, client)
    assert_eq(#client._companions, 1, "should recruit using the LIMIT 1 result")
end)

test("re-recruitment: bypasses NPC bodytype/exclusion checks (untargetable bodytype=11)", function()
    -- First-time recruitment checks bodytype 11 (untargetable) and rejects it.
    -- Re-recruitment track calls is_re_recruitment_eligible() which does NOT check bodytype.
    local fake_row = {
        id = 92, level = 20, experience = 5000, recruited_level = 20,
        stance = 1, name = "Ghost", companion_type = 0,
        is_dismissed = 1, is_suspended = 0,
    }
    Database = make_db_stub(fake_row)

    -- NPC with untargetable bodytype — would fail is_eligible_npc() bodytype check
    local npc    = make_npc({ npc_type_id = 9002, bodytype = 11 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    assert_contains(last_say(npc), "remember",
                    "re-recruitment bypasses bodytype check — should succeed")
    assert_eq(#client._companions, 1, "companion should be created despite bodytype=11")
end)

test("re-recruitment with is_suspended=1: no cooldown set on success (re-recruit path has no failure)", function()
    -- The re-recruitment track has no persuasion roll and no cooldown.
    -- Verify that after a successful re-recruitment, no cooldown key is created.
    local fake_row = {
        id = 93, level = 25, experience = 10000, recruited_level = 20,
        stance = 1, name = "Sera", companion_type = 0,
        is_dismissed = 0, is_suspended = 1,
    }
    Database = make_db_stub(fake_row)

    local npc    = make_npc({ npc_type_id = 9003 })
    local client = make_client({ char_id = 42 })

    companion.attempt_recruitment(npc, client)

    -- No new cooldown should have been created (stale one deleted, no new one set)
    assert_nil(data_store["companion_cooldown_9003_42"],
               "no cooldown should exist after successful re-recruitment")
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
