-- test_buff_queue.lua
--
-- Unit tests for the buff timer queue system (BUG-025 rewrite).
--
-- Tests cover:
--   1. Queue building: !buffs (party) and !buffme (owner only)
--   2. Sequential processing: one spell per timer tick
--   3. Edge cases: dead target, in-combat retry, queue overwrite, empty queue, retry cap
--   4. Entity variable management: serialize/deserialize, index tracking, cleanup
--
-- These tests run standalone under LuaJIT/Lua 5.1 without a live server.
-- They mock the EQEmu API (eq.*, Database, entity objects) and simulate
-- timer ticks by directly invoking the event_timer handler loaded from
-- global_npc.lua.
--
-- Run with (from the quests/ directory):
--   luajit tests/test_buff_queue.lua
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
        -- Returns a stub entity list; tests replace this per-scenario
        return _current_entity_list or {
            GetClientByCharID = function() return nil end,
            GetMobByID        = function() return nil end,
        }
    end,
    get_zone_id         = function() return 0 end,
    get_zone_short_name = function() return "testzone" end,
    set_timer  = function(name, ms)
        _last_timer_set  = name
        _last_timer_ms   = ms
        _active_timers[name] = ms
    end,
    stop_timer = function(name)
        _active_timers[name] = nil
    end,
    is_content_flag_enabled = function() return false end,
    ChooseRandom = function(...) return (...) end,
    Set = function(t) local s = {} for _, v in ipairs(t) do s[v] = true end return s end,
}

-- Message type constants
MT = { Red = 15, Yellow = 4, White = 7, DimGray = 22 }

-- os.time stub
os = os or {}
os.time = os.time or function() return 0 end

-- Global timer tracking (reset in each test)
_active_timers   = {}
_last_timer_set  = nil
_last_timer_ms   = nil
_current_entity_list = nil

-- ============================================================================
-- Database mock factory
-- ============================================================================

-- Build a Database() stub that returns a fixed list of spell rows.
-- spell_rows is a list of { spell_id = N } tables, in query result order.
local function make_database(spell_rows)
    spell_rows = spell_rows or {}
    return function()
        local idx = 0
        local stmt = {
            execute    = function(self, params) idx = 0 end,
            fetch_hash = function(self)
                idx = idx + 1
                return spell_rows[idx]  -- nil when exhausted
            end,
        }
        return {
            prepare = function(self, sql) return stmt end,
            close   = function(self) end,
        }
    end
end

-- ============================================================================
-- Object factories
-- ============================================================================

-- Create a mock entity (NPC / mob / client) with entity variable storage,
-- CastSpell recording, and configurable group membership.
local function make_entity(opts)
    opts = opts or {}
    local vars = {}
    if opts.vars then
        for k, v in pairs(opts.vars) do vars[k] = v end
    end
    local cast_log = {}  -- records every CastSpell call: {spell_id, target_id, slot}

    local ent = {
        _id         = opts.id or 100,
        _name       = opts.name or "TestComp",
        _hp         = opts.hp or 500,
        _max_mana   = opts.max_mana or 1000,
        _mana_ratio = opts.mana_ratio or 80,
        _class      = opts.class or 5,   -- shaman
        _level      = opts.level or 50,
        _owner_id   = opts.owner_id or 42,
        _is_comp    = opts.is_companion ~= false,
        _is_engaged = opts.is_engaged or false,
        _is_casting = opts.is_casting or false,
        _group      = opts.group or nil,
        _messages   = {},
        cast_log    = cast_log,
        valid       = (opts.valid ~= false),
    }

    function ent:GetID()               return self._id end
    function ent:GetHP()               return self._hp end
    function ent:GetCleanName()        return self._name end
    function ent:GetOwnerCharacterID() return self._owner_id end
    function ent:GetMaxMana()          return self._max_mana end
    function ent:GetManaRatio()        return self._mana_ratio end
    function ent:GetClass()            return self._class end
    function ent:GetLevel()            return self._level end
    function ent:IsCompanion()         return self._is_comp end
    function ent:IsEngaged()           return self._is_engaged end
    function ent:IsCasting()           return self._is_casting end
    function ent:IsPet()               return false end
    function ent:GetBodyType()         return 1 end
    function ent:GetRace()             return 1 end
    function ent:GetGroup()            return self._group end
    function ent:CharacterID()         return self._owner_id end
    function ent:GetTarget()           return nil end

    function ent:GetEntityVariable(k)
        return vars[k] or ""
    end
    function ent:SetEntityVariable(k, v)
        vars[k] = v
    end

    function ent:CastSpell(spell_id, target_id, slot)
        cast_log[#cast_log + 1] = { spell_id = spell_id, target_id = target_id, slot = slot }
    end

    function ent:Say(msg)
        self._messages[#self._messages + 1] = { channel = "say", text = msg }
    end

    function ent:Message(typ, msg)
        self._messages[#self._messages + 1] = { type = typ, text = msg }
    end

    -- Expose vars table for inspection
    ent._vars = vars

    return ent
end

-- Create a mock group with up to N members (list of entity objects)
local function make_group(members)
    local grp = { valid = true }
    function grp:GetMember(i)
        return members[i + 1]  -- EQ uses 0-based index
    end
    function grp:GroupMessage(sender, msg)
        grp._last_msg = { sender = sender, text = msg }
    end
    grp._last_msg = nil
    return grp
end

-- Build a simple entity list stub from a table of {id → entity}
local function make_entity_list(id_map, char_map)
    char_map = char_map or {}
    return {
        GetMobByID = function(self_or_id, id_arg)
            -- Support both ent_list:GetMobByID(id) and plain call patterns
            local id = (type(self_or_id) == "number") and self_or_id or id_arg
            return id_map[id]
        end,
        GetClientByCharID = function(self_or_id, id_arg)
            local id = (type(self_or_id) == "number") and self_or_id or id_arg
            return char_map[id]
        end,
        GetClientList = function()
            -- Return an iterator-compatible table
            local clients = {}
            for _, v in pairs(char_map) do clients[#clients + 1] = v end
            local i = 0
            return {
                entries = function()
                    i = i + 1
                    return clients[i]
                end
            }
        end,
    }
end

-- ============================================================================
-- Load global_npc.lua
-- We extract only the event_timer handler (the buff queue logic lives there).
-- ============================================================================

-- Determine script root directory relative to this test file's location.
local script_dir = debug.getinfo(1, "S").source:match("^@(.*)tests/") or "./"
package.path = script_dir .. "lua_modules/?.lua;" ..
               script_dir .. "lua_modules/?/init.lua;" ..
               package.path

-- Modules to stub out (we only need json to be real)
local real_require = require
local stubbed = {
    string_ext           = true,
    command              = true,
    client_ext           = true,
    mob_ext              = true,
    npc_ext              = true,
    entity_list_ext      = true,
    general_ext          = true,
    bit                  = true,
    directional          = true,
    llm_bridge           = true,
    llm_config           = true,
    llm_faction          = true,
    companion            = true,
    companion_commentary = true,
    companion_context    = true,
    companion_culture    = true,
    ["constants/instance_versions"] = true,
}

-- llm_config needs a real table for interval_s access
local llm_config_stub = { companion_commentary_min_interval_s = 600 }

require = function(modname)
    if modname == "llm_config" then return llm_config_stub end
    if stubbed[modname] then
        return setmetatable({}, { __index = function() return function() end end })
    end
    return real_require(modname)
end

-- Stub Database global (overridden per test)
Database = make_database({})

-- Load global_npc — but we only want its event_timer function.
-- Wrap the load in a protected environment so its module-level requires
-- (llm_bridge, companion, etc.) hit our stubs without errors.
local global_npc_path = script_dir .. "global/global_npc.lua"
local chunk, load_err = loadfile(global_npc_path)
if not chunk then
    error("Failed to load global_npc.lua: " .. tostring(load_err))
end

-- Run the chunk to define event_timer in the global environment
chunk()

-- Restore require
require = real_require

-- Confirm event_timer was defined
if type(event_timer) ~= "function" then
    error("event_timer not found after loading global_npc.lua")
end

-- ============================================================================
-- Test framework
-- ============================================================================

local PASS = 0
local FAIL = 0
local ERRORS = {}

local function test(name, fn)
    -- Reset shared global state before each test
    _active_timers   = {}
    _last_timer_set  = nil
    _last_timer_ms   = nil
    _current_entity_list = nil
    Database = make_database({})

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
        error((msg or "expected true") .. ": got " .. tostring(v), 2)
    end
end

local function assert_false(v, msg)
    if v then
        error((msg or "expected false") .. ": got " .. tostring(v), 2)
    end
end

local function assert_nil(v, msg)
    if v ~= nil then
        error((msg or "expected nil") .. ": got " .. tostring(v), 2)
    end
end

local function assert_not_nil(v, msg)
    if v == nil then
        error((msg or "expected non-nil value"), 2)
    end
end

local function assert_contains(str, sub, msg)
    if not tostring(str):find(sub, 1, true) then
        error((msg or "string assertion failed") ..
              ": '" .. sub .. "' not found in '" .. tostring(str) .. "'", 2)
    end
end

-- Simulate one timer tick for a companion.
-- Sets up _current_entity_list and calls event_timer with the buff_request_<id> timer.
local function fire_buff_timer(comp, entity_list)
    _current_entity_list = entity_list
    event_timer({ self = comp, timer = "buff_request_" .. comp:GetID() })
end

-- Helper: run the buff queue from Phase 1 through all entries, up to max_ticks.
-- Returns number of CastSpell calls recorded on comp.
local function drain_queue(comp, entity_list, max_ticks)
    max_ticks = max_ticks or 100
    local ticks = 0
    -- Keep firing while the timer is re-armed and we haven't exceeded max
    while ticks < max_ticks do
        fire_buff_timer(comp, entity_list)
        ticks = ticks + 1
        -- Stop when the timer is no longer active (queue exhausted or aborted)
        if not _active_timers["buff_request_" .. comp:GetID()] then
            break
        end
    end
    return ticks
end

-- ============================================================================
-- Helper: require json directly for assertion inspection
-- ============================================================================
local json = require("json")

-- ============================================================================
-- GROUP 1: cmd_buffme / cmd_buffs queue-building via entity variables
-- ============================================================================

print("\n=== GROUP 1: Queue building (cmd_buffme / cmd_buffs) ===\n")

test("cmd_buffme sets buff_request_target to 'owner'", function()
    -- Load companion module with stubs to verify the entity variable is set
    local saved_require = require
    require = function(modname)
        if stubbed[modname] then
            return setmetatable({}, { __index = function() return function() end end })
        end
        return real_require(modname)
    end

    local ok, companion_lib = pcall(real_require, "companion")
    require = saved_require
    if not ok then error("companion module failed to load: " .. tostring(companion_lib)) end

    local comp = make_entity({ id = 1, max_mana = 1000, mana_ratio = 50, hp = 300 })
    local client = make_entity({ id = 2, owner_id = 42 })

    companion_lib.cmd_buffme(comp, client, "")

    assert_eq(comp:GetEntityVariable("buff_request_target"), "owner",
        "cmd_buffme should set buff_request_target to 'owner'")
    assert_eq(comp:GetEntityVariable("buff_request_retries"), "0",
        "cmd_buffme should reset retry counter")
    assert_true(_active_timers["buff_request_1"] ~= nil,
        "cmd_buffme should arm the buff_request timer")
end)

test("cmd_buffs sets buff_request_target to 'party'", function()
    local saved_require = require
    require = function(modname)
        if stubbed[modname] then
            return setmetatable({}, { __index = function() return function() end end })
        end
        return real_require(modname)
    end

    local ok, companion_lib = pcall(real_require, "companion")
    require = saved_require
    if not ok then error("companion module failed to load: " .. tostring(companion_lib)) end

    local comp = make_entity({ id = 2, max_mana = 1000, mana_ratio = 50, hp = 300 })
    local client = make_entity({ id = 3, owner_id = 42 })

    companion_lib.cmd_buffs(comp, client, "")

    assert_eq(comp:GetEntityVariable("buff_request_target"), "party",
        "cmd_buffs should set buff_request_target to 'party'")
    assert_eq(comp:GetEntityVariable("buff_request_retries"), "0",
        "cmd_buffs should reset retry counter")
    assert_true(_active_timers["buff_request_2"] ~= nil,
        "cmd_buffs should arm the buff_request timer")
end)

-- ============================================================================
-- GROUP 2: Queue building (Phase 1) inside event_timer
-- ============================================================================

print("\n=== GROUP 2: Queue building (Phase 1 — event_timer) ===\n")

test("Phase 1 builds queue entries for owner only when request is 'owner'", function()
    -- Single buff spell, owner-only request
    Database = make_database({ { spell_id = 101 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 5, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner },
        { [42] = owner }
    )

    fire_buff_timer(comp, _current_entity_list)

    -- buff_queue should be a JSON array with one entry: [[101, 10]]
    local raw = comp:GetEntityVariable("buff_queue")
    assert_true(raw and raw ~= "", "buff_queue should be populated after Phase 1")
    local queue = json.decode(raw)
    assert_eq(#queue, 1, "owner-only queue should have exactly 1 entry")
    assert_eq(queue[1][1], 101, "entry spell_id should match db result")
    assert_eq(queue[1][2], 10,  "entry target_id should be the owner's entity ID")
end)

test("Phase 1 builds queue entries for ALL group members when request is 'party'", function()
    -- Two buff spells, party request with 3 members: owner + 2 companions
    Database = make_database({
        { spell_id = 201 },
        { spell_id = 202 },
    })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp1 = make_entity({ id = 11, owner_id = 42 })
    local comp2 = make_entity({ id = 12, owner_id = 43 })

    local group = make_group({ owner, comp1, comp2 })
    owner._group = group

    local buffing_comp = make_entity({
        id = 20, owner_id = 42,
        vars = {
            buff_request_target  = "party",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner, [11] = comp1, [12] = comp2 },
        { [42] = owner }
    )

    fire_buff_timer(buffing_comp, _current_entity_list)

    local raw = buffing_comp:GetEntityVariable("buff_queue")
    assert_true(raw and raw ~= "", "buff_queue should be populated for party request")
    local queue = json.decode(raw)

    -- 2 spells x 3 members = 6 entries, spell-major order
    assert_eq(#queue, 6, "party queue should have 2 spells * 3 members = 6 entries")

    -- Verify spell-major ordering: first 3 entries are spell 201 on each member
    assert_eq(queue[1][1], 201, "entry 1 should be spell 201")
    assert_eq(queue[2][1], 201, "entry 2 should be spell 201")
    assert_eq(queue[3][1], 201, "entry 3 should be spell 201")
    -- Last 3 are spell 202
    assert_eq(queue[4][1], 202, "entry 4 should be spell 202")
    assert_eq(queue[5][1], 202, "entry 5 should be spell 202")
    assert_eq(queue[6][1], 202, "entry 6 should be spell 202")
end)

test("Phase 1 includes NPC companions as buff targets (not only the player)", function()
    Database = make_database({ { spell_id = 301 } })

    local owner  = make_entity({ id = 10, owner_id = 42 })
    local npc_c  = make_entity({ id = 15, owner_id = 44, is_companion = true })
    -- group has owner + npc companion
    local group = make_group({ owner, npc_c })
    owner._group = group

    local buffing_comp = make_entity({
        id = 21, owner_id = 42,
        vars = {
            buff_request_target  = "party",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner, [15] = npc_c },
        { [42] = owner }
    )

    fire_buff_timer(buffing_comp, _current_entity_list)

    local raw   = buffing_comp:GetEntityVariable("buff_queue")
    local queue = json.decode(raw)
    assert_eq(#queue, 2, "queue should have 1 spell * 2 members = 2 entries")

    -- Both targets should appear
    local target_ids = {}
    for _, entry in ipairs(queue) do target_ids[entry[2]] = true end
    assert_true(target_ids[10], "owner (id 10) should be a buff target")
    assert_true(target_ids[15], "NPC companion (id 15) should be a buff target")
end)

test("Phase 1 falls back to owner only when owner has no group (solo)", function()
    Database = make_database({ { spell_id = 401 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    -- owner has no group
    owner._group = nil

    local buffing_comp = make_entity({
        id = 22, owner_id = 42,
        vars = {
            buff_request_target  = "party",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner },
        { [42] = owner }
    )

    fire_buff_timer(buffing_comp, _current_entity_list)

    local raw   = buffing_comp:GetEntityVariable("buff_queue")
    local queue = json.decode(raw)
    assert_eq(#queue, 1, "solo fallback should produce 1 entry for the owner")
    assert_eq(queue[1][2], 10, "the single entry should target the owner")
end)

-- ============================================================================
-- GROUP 3: Sequential processing (Phase 2)
-- ============================================================================

print("\n=== GROUP 3: Sequential processing (Phase 2) ===\n")

test("Each timer tick casts exactly one spell (not all at once)", function()
    -- 3 spells x 1 target = 3 entries; first tick should cast only entry #1
    Database = make_database({
        { spell_id = 501 },
        { spell_id = 502 },
        { spell_id = 503 },
    })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 30, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner },
        { [42] = owner }
    )

    -- Tick 1: Phase 1 builds queue and casts first entry
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(#comp.cast_log, 1, "tick 1 should cast exactly 1 spell")
    assert_eq(comp.cast_log[1].spell_id, 501, "first spell cast should be 501")

    -- Timer should be re-armed
    assert_true(_active_timers["buff_request_30"] ~= nil,
        "timer should be re-armed after first tick")
end)

test("Queue index advances by 1 after each tick", function()
    Database = make_database({ { spell_id = 601 }, { spell_id = 602 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 31, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    -- Tick 1 (Phase 1 + first cast): idx advances to 2
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "2",
        "index should be 2 after first tick")

    -- Tick 2: idx advances to 3
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "3",
        "index should be 3 after second tick")
end)

test("Timer stops when queue is exhausted", function()
    -- 2 spells, 1 target = 2 queue entries
    Database = make_database({ { spell_id = 701 }, { spell_id = 702 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 32, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    -- Drain all ticks
    drain_queue(comp, _current_entity_list)

    -- Timer should be gone
    assert_nil(_active_timers["buff_request_32"],
        "timer should not be active after queue exhaustion")
end)

test("All spells in the queue eventually get cast (full drain)", function()
    Database = make_database({
        { spell_id = 801 },
        { spell_id = 802 },
        { spell_id = 803 },
    })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 33, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    drain_queue(comp, _current_entity_list)

    assert_eq(#comp.cast_log, 3, "all 3 spells should be cast")
    assert_eq(comp.cast_log[1].spell_id, 801, "first cast: 801")
    assert_eq(comp.cast_log[2].spell_id, 802, "second cast: 802")
    assert_eq(comp.cast_log[3].spell_id, 803, "third cast: 803")
end)

test("Party queue casts each spell on every group member in order", function()
    -- 2 spells x 2 targets = 4 entries
    Database = make_database({ { spell_id = 901 }, { spell_id = 902 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local ally  = make_entity({ id = 11, owner_id = 43 })
    local group = make_group({ owner, ally })
    owner._group = group

    local comp = make_entity({
        id = 34, owner_id = 42,
        vars = {
            buff_request_target  = "party",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner, [11] = ally },
        { [42] = owner }
    )

    drain_queue(comp, _current_entity_list)

    assert_eq(#comp.cast_log, 4, "should cast 2 spells x 2 targets = 4 times")

    -- Spell-major: first two casts are spell 901 on each target
    assert_eq(comp.cast_log[1].spell_id, 901)
    assert_eq(comp.cast_log[2].spell_id, 901)
    -- Last two casts are spell 902 on each target
    assert_eq(comp.cast_log[3].spell_id, 902)
    assert_eq(comp.cast_log[4].spell_id, 902)
end)

-- ============================================================================
-- GROUP 4: Edge cases
-- ============================================================================

print("\n=== GROUP 4: Edge cases ===\n")

test("Dead target mid-queue: entry is skipped, queue continues", function()
    -- Spell 1001 queued for target 10 (alive) and target 11 (dead/invalid)
    Database = make_database({ { spell_id = 1001 } })

    local owner  = make_entity({ id = 10, owner_id = 42 })
    local dead   = make_entity({ id = 11, hp = 0, owner_id = 43 })

    local group = make_group({ owner, dead })
    owner._group = group

    local comp = make_entity({
        id = 40, owner_id = 42,
        vars = {
            buff_request_target  = "party",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list(
        { [10] = owner, [11] = dead },
        { [42] = owner }
    )

    drain_queue(comp, _current_entity_list)

    -- Only the alive target (10) should receive the spell
    local cast_targets = {}
    for _, c in ipairs(comp.cast_log) do
        cast_targets[c.target_id] = (cast_targets[c.target_id] or 0) + 1
    end

    assert_eq(cast_targets[10], 1, "alive target should receive buff")
    assert_nil(cast_targets[11], "dead target (HP=0) should be skipped")
end)

test("Invalid (nil) target mid-queue: entry is skipped without crash", function()
    Database = make_database({ { spell_id = 1101 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    -- Build a group with owner + a member whose entity ID maps to nil in entity list
    local ghost = make_entity({ id = 99, owner_id = 50 })  -- not in entity list
    local group = make_group({ owner, ghost })
    owner._group = group

    local comp = make_entity({
        id = 41, owner_id = 42,
        vars = {
            buff_request_target  = "party",
            buff_request_retries = "0",
        }
    })

    -- Entity list does NOT include ghost (id=99), so GetMobByID(99) returns nil
    _current_entity_list = make_entity_list(
        { [10] = owner },
        { [42] = owner }
    )

    -- Must not crash
    drain_queue(comp, _current_entity_list)

    -- Owner (10) should still receive buff; ghost (99) silently skipped
    local cast_targets = {}
    for _, c in ipairs(comp.cast_log) do
        cast_targets[c.target_id] = (cast_targets[c.target_id] or 0) + 1
    end
    assert_eq(cast_targets[10], 1, "alive owner should receive buff despite invalid co-member")
    assert_nil(cast_targets[99], "invalid/nil target should be silently skipped")
end)

test("In-combat companion: queue pauses and retries", function()
    -- Companion is engaged — should not process queue, should re-arm timer
    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 42, owner_id = 42,
        is_engaged = true,   -- in combat
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    -- Should NOT have cast anything
    assert_eq(#comp.cast_log, 0, "in-combat companion should not cast spells")
    -- Timer should be re-armed for retry
    assert_true(_active_timers["buff_request_42"] ~= nil,
        "timer should be re-armed while companion is in combat")
    -- Retry counter should increment
    assert_eq(comp:GetEntityVariable("buff_request_retries"), "1",
        "retry counter should increment on each combat-blocked tick")
end)

test("Casting companion: queue pauses and retries", function()
    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 43, owner_id = 42,
        is_casting = true,   -- currently casting
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "2",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    assert_eq(#comp.cast_log, 0, "casting companion should not start a new cast")
    assert_true(_active_timers["buff_request_43"] ~= nil,
        "timer should re-arm while companion is casting")
    assert_eq(comp:GetEntityVariable("buff_request_retries"), "3",
        "retry counter should increment while casting")
end)

test("New !buffs overwrites an in-progress queue", function()
    -- Set up a partially-processed queue
    local existing_queue = json.encode({ {111, 10}, {112, 10}, {113, 10} })
    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 44, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
            buff_queue           = existing_queue,
            buff_queue_idx       = "2",   -- partially through
        }
    })

    -- New command arrives: set fresh request variables (as cmd_buffs/cmd_buffme would)
    comp:SetEntityVariable("buff_request_target",  "owner")
    comp:SetEntityVariable("buff_request_retries", "0")
    comp:SetEntityVariable("buff_queue",           "")     -- cleared by new request
    comp:SetEntityVariable("buff_queue_idx",       "")

    -- New DB has different spells
    Database = make_database({ { spell_id = 999 } })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    -- First tick: Phase 1 rebuilds queue from scratch
    fire_buff_timer(comp, _current_entity_list)

    local raw   = comp:GetEntityVariable("buff_queue")
    local queue = json.decode(raw)
    assert_eq(#queue, 1, "overwritten queue should have 1 entry from new DB result")
    assert_eq(queue[1][1], 999, "overwritten queue should contain the new spell")
    assert_eq(comp.cast_log[1].spell_id, 999, "first cast should be the new spell (999)")
end)

test("Empty spell set: timer cleans up and does not crash", function()
    -- No buff spells found in DB
    Database = make_database({})

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 45, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    local group = make_group({ owner })
    owner._group = group

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    assert_eq(#comp.cast_log, 0, "no spells should be cast when DB returns nothing")
    assert_nil(_active_timers["buff_request_45"],
        "timer should not be active after empty queue detected")
    assert_eq(comp:GetEntityVariable("buff_request_target"), "",
        "buff_request_target should be cleared after empty-queue abort")
end)

test("Retry cap (30 retries): queue aborts and notifies owner", function()
    -- Companion stuck in combat for 30+ retries
    local owner = make_entity({ id = 10, owner_id = 42 })
    local group = make_group({ owner })
    owner._group = group

    local comp = make_entity({
        id = 46, owner_id = 42,
        is_engaged = true,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "30",  -- at the cap
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    -- Timer should NOT be re-armed
    assert_nil(_active_timers["buff_request_46"],
        "timer should not re-arm after retry cap")
    -- All state should be cleared
    assert_eq(comp:GetEntityVariable("buff_request_target"), "",
        "buff_request_target should be cleared after abort")
    assert_eq(comp:GetEntityVariable("buff_queue"), "",
        "buff_queue should be cleared after abort")
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "",
        "buff_queue_idx should be cleared after abort")
    -- Group should have received a notification
    assert_not_nil(group._last_msg,
        "group should receive 'unable to buff' notification at retry cap")
end)

-- ============================================================================
-- GROUP 5: Entity variable management
-- ============================================================================

print("\n=== GROUP 5: Entity variable management ===\n")

test("buff_queue serializes as valid JSON and round-trips through json.decode", function()
    Database = make_database({ { spell_id = 2001 }, { spell_id = 2002 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 50, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    local raw = comp:GetEntityVariable("buff_queue")
    assert_true(raw and raw ~= "", "buff_queue must be a non-empty string")

    local ok, decoded = pcall(json.decode, raw)
    assert_true(ok, "buff_queue must be valid JSON (json.decode succeeded)")
    assert_true(type(decoded) == "table", "decoded buff_queue should be a table")

    -- Verify structure: array of [spell_id, target_id] pairs
    for i, entry in ipairs(decoded) do
        assert_true(type(entry[1]) == "number", "entry[" .. i .. "][1] (spell_id) must be a number")
        assert_true(type(entry[2]) == "number", "entry[" .. i .. "][2] (target_id) must be a number")
    end
end)

test("buff_queue_idx starts at 1 after Phase 1 build", function()
    Database = make_database({ { spell_id = 2101 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 51, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    -- After the first tick (Phase 1 + first cast), idx advances from 1 to 2
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "2",
        "index should be 2 after the first tick processes entry 1")
end)

test("All entity vars are cleaned up when queue completes normally", function()
    Database = make_database({ { spell_id = 2201 } })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 52, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    drain_queue(comp, _current_entity_list)

    assert_eq(comp:GetEntityVariable("buff_request_target"), "",
        "buff_request_target should be empty after completion")
    assert_eq(comp:GetEntityVariable("buff_request_retries"), "0",
        "buff_request_retries should be reset to 0 after completion")
    assert_eq(comp:GetEntityVariable("buff_queue"), "",
        "buff_queue should be cleared after completion")
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "",
        "buff_queue_idx should be cleared after completion")
end)

test("buff_queue_idx tracks position correctly across multiple ticks", function()
    -- 4 spells, 1 target; verify idx steps 2→3→4→5 (1 consumed per tick in Phase 2)
    Database = make_database({
        { spell_id = 2301 },
        { spell_id = 2302 },
        { spell_id = 2303 },
        { spell_id = 2304 },
    })

    local owner = make_entity({ id = 10, owner_id = 42 })
    local comp  = make_entity({
        id = 53, owner_id = 42,
        vars = {
            buff_request_target  = "owner",
            buff_request_retries = "0",
        }
    })

    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    -- Tick 1: build queue + cast entry 1; idx → 2
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "2")

    -- Tick 2: cast entry 2; idx → 3
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "3")

    -- Tick 3: cast entry 3; idx → 4
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "4")

    -- Tick 4: cast entry 4; idx → 5
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "5")

    -- Tick 5: idx=5 > #queue=4, cleanup runs
    fire_buff_timer(comp, _current_entity_list)
    assert_eq(comp:GetEntityVariable("buff_queue_idx"), "",
        "buff_queue_idx should be cleared after queue exhausted")
    assert_eq(#comp.cast_log, 4, "all 4 spells should have been cast")
end)

test("No entity vars remain dirty when request is cancelled before Phase 1", function()
    -- Scenario: timer fires but buff_request_target is already empty (request cancelled)
    local comp = make_entity({
        id = 54, owner_id = 42,
        vars = {
            buff_request_target  = "",  -- cancelled
            buff_request_retries = "0",
        }
    })

    local owner = make_entity({ id = 10, owner_id = 42 })
    _current_entity_list = make_entity_list({ [10] = owner }, { [42] = owner })

    fire_buff_timer(comp, _current_entity_list)

    assert_eq(#comp.cast_log, 0, "no spells should be cast for cancelled request")
    assert_nil(_active_timers["buff_request_54"],
        "timer should not be re-armed for cancelled request")
end)

-- ============================================================================
-- GROUP 6: Non-buff-timer events are not affected
-- ============================================================================

print("\n=== GROUP 6: Non-buff timer events pass through correctly ===\n")

test("event_timer ignores timers that are not buff_request_ prefixed", function()
    local comp = make_entity({ id = 60, owner_id = 42 })

    -- Fire with an unrelated timer name
    event_timer({ self = comp, timer = "some_other_timer" })

    assert_eq(#comp.cast_log, 0, "unrelated timer should not trigger buff logic")
end)

test("event_timer ignores non-companion entities for buff_request_ timers", function()
    -- An NPC that is not a companion has buff_request_ timer fire (shouldn't happen
    -- in practice, but must not crash)
    local non_comp = make_entity({ id = 70, owner_id = 0, is_companion = false })
    non_comp._vars["buff_request_target"]  = "owner"
    non_comp._vars["buff_request_retries"] = "0"

    _current_entity_list = make_entity_list({}, {})

    event_timer({ self = non_comp, timer = "buff_request_70" })

    assert_eq(#non_comp.cast_log, 0, "non-companion should not process buff timer")
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
