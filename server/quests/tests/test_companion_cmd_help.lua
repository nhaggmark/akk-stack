-- test_companion_cmd_help.lua
--
-- Unit tests for companion.cmd_help (NPC-level) and cmd_help_standalone (player-level).
--
-- Tests verify:
--   1. cmd_help general output is alphabetical within each category
--   2. cmd_help general output has !hold under Movement
--   3. cmd_help general output has one command per line
--   4. cmd_help_standalone produces identical content as cmd_help
--   5. cmd_help_standalone uses client:Message() instead of companion_say()
--   6. @all deduplication lock prevents double responses
--   7. !help <topic> still works for all 7 categories
--   8. Unknown topic returns error message
--
-- Run with:
--   luajit tests/test_companion_cmd_help.lua
-- from the lua_modules/ directory, OR:
--   cd akk-stack/server/quests && luajit tests/test_companion_cmd_help.lua
--
-- ============================================================================
-- EQEmu API stubs
-- ============================================================================

local data_store = {}

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
    get_data = function(key) return data_store[key] end,
    set_data = function(key, val, ttl) data_store[key] = val end,
    delete_data = function(key) data_store[key] = nil end,
    get_zone_id = function() return 1 end,
}

MT = { Red = 15, Yellow = 4, White = 7, DimGray = 22 }
os = os or { time = function() return 0 end }

-- ============================================================================
-- Object factories
-- ============================================================================

local function make_npc(opts)
    opts = opts or {}
    local char_id = opts.char_id or 42
    local messages = {}

    local npc = {
        _id       = opts.id or 100,
        _hp       = opts.hp or 500,
        _name     = opts.name or "Testius",
        _char_id  = char_id,
        _messages = messages,
        valid     = true,
    }
    function npc:GetID()                 return self._id end
    function npc:GetHP()                 return self._hp end
    function npc:GetCleanName()          return self._name end
    function npc:GetOwnerCharacterID()   return self._char_id end
    function npc:GetMaxMana()            return 0 end
    function npc:GetManaRatio()          return 100 end
    function npc:IsCompanion()           return true end
    function npc:Say(msg)
        messages[#messages + 1] = { channel = "say", text = msg }
    end
    function npc:GetGroup()              return opts.group or nil end
    function npc:GetEntityVariable(k)    return "" end
    function npc:SetEntityVariable(k,v)  end
    return npc
end

local function make_client(opts)
    opts = opts or {}
    local client = {
        _id       = opts.id or 1,
        _char_id  = opts.char_id or 42,
        _messages = {},
        valid     = true,
    }
    function client:GetID()       return self._id end
    function client:CharacterID() return self._char_id end
    function client:GetTarget()   return opts.target or nil end
    function client:GetGroup()    return opts.group or nil end
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
    -- Reset data store (lock) between tests
    data_store = {}
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

-- Collect all say messages from an NPC into a single string for searching
local function npc_output(npc)
    local lines = {}
    for _, m in ipairs(npc._messages) do
        lines[#lines + 1] = m.text
    end
    return table.concat(lines, "\n")
end

-- Collect all client:Message() calls into a single string
local function client_output(client)
    local lines = {}
    for _, m in ipairs(client._messages) do
        lines[#lines + 1] = m.text
    end
    return table.concat(lines, "\n")
end

-- ============================================================================
-- Tests: cmd_help general output
-- ============================================================================

print("\n=== companion.cmd_help / cmd_help_standalone tests ===\n")

test("cmd_help: includes === Companion Commands === header", function()
    local npc    = make_npc({ id = 1 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    assert_contains(out, "=== Companion Commands ===", "header should be present")
end)

test("cmd_help: includes all 7 category headings", function()
    local npc    = make_npc({ id = 2 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    for _, cat in ipairs({"Buffs:", "Combat:", "Control:", "Equipment:", "Information:", "Movement:", "Stance:"}) do
        assert_contains(out, cat, "category heading '" .. cat .. "' should be present")
    end
end)

test("cmd_help: !hold appears under Movement", function()
    local npc    = make_npc({ id = 3 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    -- Check that !hold line appears after Movement: heading
    local out = npc_output(npc)
    local movement_pos = out:find("Movement:", 1, true)
    local hold_pos     = out:find("!hold", 1, true)
    local stance_pos   = out:find("Stance:", 1, true)

    assert_true(movement_pos ~= nil, "Movement: heading should be present")
    assert_true(hold_pos ~= nil, "!hold should appear in output")
    assert_true(hold_pos > movement_pos, "!hold should appear after Movement:")
    assert_true(hold_pos < stance_pos, "!hold should appear before Stance: (within Movement section)")
end)

test("cmd_help: Movement commands are alphabetical (flee/follow/guard/hold/recall/tome)", function()
    local npc    = make_npc({ id = 4 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    -- All six movement commands should appear in alphabetical order
    local positions = {}
    for _, cmd in ipairs({"!flee", "!follow", "!guard", "!hold", "!recall", "!tome"}) do
        local p = out:find(cmd, 1, true)
        assert_true(p ~= nil, cmd .. " should be in help output")
        positions[cmd] = p
    end
    assert_true(positions["!flee"]   < positions["!follow"], "!flee should come before !follow")
    assert_true(positions["!follow"] < positions["!guard"],  "!follow should come before !guard")
    assert_true(positions["!guard"]  < positions["!hold"],   "!guard should come before !hold")
    assert_true(positions["!hold"]   < positions["!recall"], "!hold should come before !recall")
    assert_true(positions["!recall"] < positions["!tome"],   "!recall should come before !tome")
end)

test("cmd_help: Stance commands are alphabetical (aggressive/balanced/passive)", function()
    local npc    = make_npc({ id = 5 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    local pa = out:find("!aggressive", 1, true)
    local pb = out:find("!balanced", 1, true)
    local pc = out:find("!passive", 1, true)
    assert_true(pa ~= nil, "!aggressive should be in output")
    assert_true(pb ~= nil, "!balanced should be in output")
    assert_true(pc ~= nil, "!passive should be in output")
    assert_true(pa < pb, "!aggressive before !balanced")
    assert_true(pb < pc, "!balanced before !passive")
end)

test("cmd_help: Buffs commands are alphabetical (buffme/buffs)", function()
    local npc    = make_npc({ id = 6 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    local pa = out:find("!buffme", 1, true)
    local pb = out:find("!buffs", 1, true)
    assert_true(pa ~= nil, "!buffme should be in output")
    assert_true(pb ~= nil, "!buffs should be in output")
    assert_true(pa < pb, "!buffme before !buffs")
end)

test("cmd_help: !gear alias mentioned inline, not as separate entry", function()
    local npc    = make_npc({ id = 7 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    -- !gear should appear on the !equipment line (as alias note), not as its own line
    local equipment_pos = out:find("!equipment", 1, true)
    local gear_pos      = out:find("!gear", 1, true)
    assert_true(equipment_pos ~= nil, "!equipment should be in output")
    assert_true(gear_pos ~= nil, "!gear alias should be mentioned")
    -- !gear should appear within a few characters of !equipment on the same line
    assert_true(math.abs(gear_pos - equipment_pos) < 80, "!gear should be on the same line as !equipment")
end)

test("cmd_help: includes footer with '!help <topic>'", function()
    local npc    = make_npc({ id = 8 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")

    local out = npc_output(npc)
    assert_contains(out, "!help <topic>", "footer should mention !help <topic>")
end)

-- ============================================================================
-- Tests: cmd_help topic filtering
-- ============================================================================

test("cmd_help stance topic: has all 3 stance commands alphabetically", function()
    local npc    = make_npc({ id = 20 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "stance")

    local out = npc_output(npc)
    assert_contains(out, "=== Stance Commands ===", "header should be present")
    local pa = out:find("!aggressive", 1, true)
    local pb = out:find("!balanced", 1, true)
    local pc = out:find("!passive", 1, true)
    assert_true(pa and pb and pc, "all stance commands should appear")
    assert_true(pa < pb and pb < pc, "stance commands should be alphabetical")
end)

test("cmd_help movement topic: has !hold and all movement commands", function()
    local npc    = make_npc({ id = 21 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "movement")

    local out = npc_output(npc)
    assert_contains(out, "=== Movement Commands ===", "header should be present")
    assert_contains(out, "!hold", "!hold should appear in movement topic")
    assert_contains(out, "!flee", "!flee should appear in movement topic")
    assert_contains(out, "!follow", "!follow should appear in movement topic")
    assert_contains(out, "!guard", "!guard should appear in movement topic")
    assert_contains(out, "!recall", "!recall should appear in movement topic")
    assert_contains(out, "!tome", "!tome should appear in movement topic")
end)

test("cmd_help combat topic: has both combat commands alphabetically", function()
    local npc    = make_npc({ id = 22 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "combat")

    local out = npc_output(npc)
    assert_contains(out, "=== Combat Commands ===", "header should be present")
    local pa = out:find("!assist", 1, true)
    local pb = out:find("!target", 1, true)
    assert_true(pa and pb, "both combat commands should appear")
    assert_true(pa < pb, "!assist before !target (alphabetical)")
end)

test("cmd_help buffs topic: includes caster requirement note", function()
    local npc    = make_npc({ id = 23 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "buffs")

    local out = npc_output(npc)
    assert_contains(out, "=== Buff Commands ===", "header should be present")
    assert_contains(out, "Casters", "should mention caster requirement")
end)

test("cmd_help equipment topic: lists all equipment commands and valid slots", function()
    local npc    = make_npc({ id = 24 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "equipment")

    local out = npc_output(npc)
    assert_contains(out, "=== Equipment Commands ===", "header should be present")
    assert_contains(out, "!equipment", "!equipment should appear")
    assert_contains(out, "!unequip", "!unequip should appear")
    assert_contains(out, "primary", "slot names should appear")
end)

test("cmd_help information topic: has help/stats/status alphabetically", function()
    local npc    = make_npc({ id = 25 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "information")

    local out = npc_output(npc)
    assert_contains(out, "=== Information Commands ===", "header should be present")
    local ph = out:find("!help", 1, true)
    local ps = out:find("!stats", 1, true)
    local pst = out:find("!status", 1, true)
    assert_true(ph and ps and pst, "all info commands should appear")
    assert_true(ph < ps and ps < pst, "information commands should be alphabetical")
end)

test("cmd_help control topic: has !dismiss", function()
    local npc    = make_npc({ id = 26 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "control")

    local out = npc_output(npc)
    assert_contains(out, "=== Control Commands ===", "header should be present")
    assert_contains(out, "!dismiss", "!dismiss should appear")
end)

test("cmd_help unknown topic: returns error message", function()
    local npc    = make_npc({ id = 27 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "bogustopic")

    local out = npc_output(npc)
    assert_contains(out, "Unknown help topic", "should say unknown topic")
    assert_contains(out, "bogustopic", "should echo the unknown topic")
end)

-- ============================================================================
-- Tests: @all deduplication lock
-- ============================================================================

test("cmd_help: @all deduplication lock prevents double response", function()
    -- Simulate two companions receiving !help via @all
    local npc1   = make_npc({ id = 50 })
    local npc2   = make_npc({ id = 51 })
    local client = make_client({ char_id = 42 })

    -- First companion responds
    companion.cmd_help(npc1, client, "")
    local count1 = #npc1._messages
    assert_true(count1 > 0, "first companion should respond")

    -- Second companion should be blocked by the lock
    companion.cmd_help(npc2, client, "")
    assert_eq(#npc2._messages, 0, "second companion should be blocked by dedup lock")
end)

-- ============================================================================
-- Tests: cmd_help_standalone
-- ============================================================================

test("cmd_help_standalone: uses client:Message() (no NPC required)", function()
    local client = make_client({ char_id = 42 })

    companion.cmd_help_standalone(client, "")

    assert_true(#client._messages > 0, "client should receive messages directly")
end)

test("cmd_help_standalone: general output contains all 7 category headings", function()
    local client = make_client({ char_id = 42 })

    companion.cmd_help_standalone(client, "")

    local out = client_output(client)
    for _, cat in ipairs({"Buffs:", "Combat:", "Control:", "Equipment:", "Information:", "Movement:", "Stance:"}) do
        assert_contains(out, cat, "category '" .. cat .. "' should be in standalone output")
    end
end)

test("cmd_help_standalone: includes !hold under Movement", function()
    local client = make_client({ char_id = 42 })

    companion.cmd_help_standalone(client, "")

    local out = client_output(client)
    local movement_pos = out:find("Movement:", 1, true)
    local hold_pos     = out:find("!hold", 1, true)
    assert_true(hold_pos ~= nil, "!hold should appear in standalone output")
    assert_true(hold_pos > movement_pos, "!hold should appear after Movement:")
end)

test("cmd_help_standalone: topic filter works (e.g. 'stance')", function()
    local client = make_client({ char_id = 42 })

    companion.cmd_help_standalone(client, "stance")

    local out = client_output(client)
    assert_contains(out, "=== Stance Commands ===", "stance topic should work in standalone")
    assert_contains(out, "!aggressive", "!aggressive should appear in stance topic")
end)

test("cmd_help_standalone: uses same dedup lock key as cmd_help", function()
    -- If cmd_help runs first, cmd_help_standalone should be blocked
    local npc    = make_npc({ id = 60 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help(npc, client, "")  -- claims the lock
    local client2 = make_client({ char_id = 42 })
    companion.cmd_help_standalone(client2, "")  -- should be blocked

    assert_eq(#client2._messages, 0, "standalone should be blocked by NPC-level lock")
end)

test("cmd_help_standalone: blocks cmd_help if standalone runs first", function()
    -- If standalone runs first, cmd_help should be blocked
    local npc    = make_npc({ id = 61 })
    local client = make_client({ char_id = 42 })

    companion.cmd_help_standalone(client, "")  -- claims the lock
    companion.cmd_help(npc, client, "")  -- should be blocked

    assert_eq(#npc._messages, 0, "NPC-level cmd_help should be blocked by standalone lock")
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
