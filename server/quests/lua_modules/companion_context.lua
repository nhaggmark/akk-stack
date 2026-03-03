-- companion_context.lua
-- Builds companion-specific context fields for the LLM payload.
-- Called from llm_bridge.build_context() when npc:IsCompanion() is true.
--
-- Depends on:
--   companion_culture.lua — identity evolution, type framing, role extraction
--   C++ GetTimeActive()   — cumulative seconds the companion has been active
--   C++ GetRecruitedZoneID() — zone ID where companion was first recruited
--
-- Main entry point: companion_context.build(npc, client)
-- Returns a flat table of companion-specific fields to merge into the LLM payload.

local companion_culture = require("companion_culture")

local companion_context = {}

-- ============================================================================
-- Luclin fixed-lighting zone lookup
-- Several Luclin zones have fixed day/night conditions (no natural cycle).
-- When is_luclin_fixed_light = true, the sidecar should avoid day/night commentary.
-- Verified against Luclin zone list — these zones have static ambient lighting.
-- ============================================================================
local LUCLIN_FIXED_LIGHT_ZONES = {
    nexus         = true,   -- The Nexus (transit hub, artificial light)
    echo          = true,   -- Echo of Time
    umbral        = true,   -- Umbral Plains (dark side of Luclin)
    griegsend     = true,   -- Grieg's End (dungeon interior)
    thedeep       = true,   -- The Deep
    shadowrest    = true,   -- Shadow Rest
    akheva        = true,   -- Akheva Ruins
    sseru         = true,   -- Sanctus Seru (city — artificial lighting)
    katta         = true,   -- Katta Castellum (city — artificial lighting)
    sharvahl      = true,   -- Shar Vahl (city — artificial lighting)
    paludal       = true,   -- Paludal Caverns (underground)
    fungusgrove   = true,   -- Fungus Grove (underground)
    insidion      = true,   -- The Insidious Citadel
    bazaar        = false,  -- The Bazaar — has day/night on Luclin surface
    dawnshroud    = false,  -- Dawnshroud Peaks — surface, has day/night
    scarlet       = false,  -- Scarlet Desert — surface, has day/night
    tenebrous     = false,  -- Tenebrous Mountains — surface, has day/night
    twilight       = false,  -- The Twilight Sea — surface, has day/night
}

-- ============================================================================
-- Zone type classification
-- Maps ztype integer (from zone.ztype DB column) to a descriptive string.
-- The ztype column values come from the EverQuest zone definitions.
-- 255 (0xFF) is the default/unset value used for many classic zones.
-- ============================================================================
function companion_context.classify_zone_type(ztype)
    if ztype == 1 then
        return "outdoor"
    elseif ztype == 2 then
        return "dungeon"
    elseif ztype == 3 then
        return "city"
    elseif ztype == 0 then
        return "indoor"
    else
        -- 255 (0xFF) and unknown values: default to outdoor for open-world zones
        return "outdoor"
    end
end

-- ============================================================================
-- Time of day classification
-- Maps EQ hour (0-23 from eq.get_zone_time().zone_hour) to a period name.
-- EQ day: 8 hours of daylight, the rest night, with dawn/dusk transitions.
-- ============================================================================
function companion_context.classify_time_of_day(hour)
    if hour == nil then return "unknown" end
    if hour >= 5 and hour <= 7 then
        return "dawn"
    elseif hour >= 8 and hour <= 17 then
        return "day"
    elseif hour >= 18 and hour <= 20 then
        return "dusk"
    else
        return "night"
    end
end

-- ============================================================================
-- Time-active human description
-- Converts cumulative seconds to a short readable phrase.
-- ============================================================================
function companion_context.get_time_description(seconds)
    if seconds == nil or seconds == 0 then
        return "just recruited"
    elseif seconds < 3600 then
        return "less than an hour"
    elseif seconds < 7200 then
        return "about an hour"
    elseif seconds < 36000 then
        local hours = math.floor(seconds / 3600)
        return "a few hours (" .. hours .. "h)"
    elseif seconds < 86400 then
        local hours = math.floor(seconds / 3600)
        return "several hours (" .. hours .. "h)"
    elseif seconds < 259200 then
        local days = math.floor(seconds / 86400)
        return "a few days (" .. days .. "d)"
    elseif seconds < 604800 then
        local days = math.floor(seconds / 86400)
        return "several days (" .. days .. "d)"
    else
        local weeks = math.floor(seconds / 604800)
        return "many weeks (" .. weeks .. "w)"
    end
end

-- ============================================================================
-- Recruited zone name lookup
-- Looks up zone short and long name from a zone ID via DB or eq namespace.
-- Returns {short_name, long_name} or fallback strings if not found.
-- ============================================================================
function companion_context.get_recruited_zone_name(zone_id)
    if not zone_id or zone_id == 0 then
        return "unknown", "an unknown land"
    end

    -- Use eq.get_zone_long_name() and eq.get_zone_short_name() only work for
    -- the current zone. For the recruited zone (possibly different), use DB.
    local ok, result = pcall(function()
        local db = Database()
        local stmt = db:prepare("SELECT short_name, long_name FROM zone WHERE zoneidnumber = ? LIMIT 1")
        stmt:execute({zone_id})
        local row = stmt:fetch_hash()
        db:close()
        return row
    end)

    if ok and result and result.short_name then
        return result.short_name, result.long_name or result.short_name
    end

    -- Fallback: zone ID without a name
    return "zone_" .. tostring(zone_id), "a distant land"
end

-- ============================================================================
-- Group composition builder
-- Iterates over group members and returns a structured array.
-- Returns {name, race, class_id, level, is_companion} for each member.
-- ============================================================================
function companion_context.get_group_composition(client)
    local members = {}
    local group = client:GetGroup()
    if not group or not group.valid then
        return members, 1
    end

    local count = group:GroupCount()
    for i = 0, 5 do
        local member = group:GetMember(i)
        if member and member.valid then
            local ok_comp, is_comp = pcall(function() return member:IsCompanion() end)
            members[#members + 1] = {
                name         = member:GetCleanName(),
                race         = member:GetRaceName(),
                class_id     = member:GetClass(),
                level        = member:GetLevel(),
                is_companion = (ok_comp and is_comp) and true or false,
            }
        end
    end

    return members, count
end

-- ============================================================================
-- Main context builder
-- Entry point: companion_context.build(npc, client)
-- Returns a table of companion fields to merge into the LLM payload.
-- ============================================================================
function companion_context.build(npc, client)
    local ctx = {}

    -- Basic companion flags
    ctx.is_companion = true
    ctx.companion_type = npc:GetCompanionType()
    ctx.companion_stance = npc:GetStance()
    ctx.companion_name = npc:GetCleanName()
    ctx.race_culture_id = npc:GetRace()

    -- Time active (new C++ getter)
    local time_active = 0
    local ok_time, tv = pcall(function() return npc:GetTimeActive() end)
    if ok_time and tv then
        time_active = tonumber(tv) or 0
    end
    ctx.time_active_seconds = time_active
    ctx.time_active_description = companion_context.get_time_description(time_active)
    ctx.evolution_tier = companion_culture.get_evolution_tier(time_active)

    -- Recruited zone (new C++ getter)
    local rec_zone_id = 0
    local ok_zone, zv = pcall(function() return npc:GetRecruitedZoneID() end)
    if ok_zone and zv then
        rec_zone_id = tonumber(zv) or 0
    end
    local rec_short, rec_long = companion_context.get_recruited_zone_name(rec_zone_id)
    ctx.recruited_zone_short = rec_short
    ctx.recruited_zone_long  = rec_long

    -- Original role extracted from NPC name
    ctx.original_role = companion_culture._extract_role_from_name(npc:GetName())

    -- Current zone classification
    local zone_type_int = 255
    local ok_zt = pcall(function()
        local z = eq.get_zone()
        if z and z.valid then
            zone_type_int = z:GetZoneType()
        end
    end)
    ctx.zone_type = companion_context.classify_zone_type(zone_type_int)

    -- Time of day
    local zone_short = eq.get_zone_short_name()
    local fixed_light = companion_context.is_luclin_fixed_light(zone_short)
    ctx.is_luclin_fixed_light = fixed_light

    if fixed_light then
        ctx.time_of_day = "fixed_lighting"
    else
        local ok_t, t = pcall(function() return eq.get_zone_time() end)
        if ok_t and t then
            ctx.time_of_day = companion_context.classify_time_of_day(t.zone_hour)
        else
            ctx.time_of_day = "unknown"
        end
    end

    -- Combat state and health
    ctx.in_combat = npc:IsEngaged()
    local hp_ok, hp_ratio = pcall(function() return npc:GetHPRatio() end)
    ctx.hp_percent = (hp_ok and hp_ratio) and math.floor(hp_ratio) or 100
    ctx.recently_damaged = ctx.hp_percent < 80

    -- Group composition
    local group_members, group_size = companion_context.get_group_composition(client)
    ctx.group_members = group_members
    ctx.group_size = group_size

    -- Recent kills (tracked via entity variables set by event_death_zone in global_npc.lua)
    -- Format: comma-separated NPC clean names, last 5
    local kills_raw = npc:GetEntityVariable("comp_recent_kills")
    if kills_raw and kills_raw ~= "" then
        ctx.recent_kills = kills_raw
    else
        ctx.recent_kills = ""
    end

    -- Identity framing from companion_culture
    ctx.type_framing = companion_culture.get_type_framing(ctx.companion_type, ctx.race_culture_id)
    ctx.evolution_context = companion_culture.get_evolution_context(
        ctx.companion_type,
        time_active,
        ctx.original_role
    )

    return ctx
end

-- ============================================================================
-- Luclin fixed-light check
-- Returns true if the given zone short name is a Luclin fixed-lighting zone.
-- ============================================================================
function companion_context.is_luclin_fixed_light(zone_short)
    if not zone_short then return false end
    return LUCLIN_FIXED_LIGHT_ZONES[zone_short:lower()] == true
end

return companion_context
