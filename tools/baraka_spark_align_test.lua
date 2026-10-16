-- baraka_spark_align_test.lua
--
-- Measures WHERE Baraka's blade-spark burst (a_saprojani part 3, UGSPARK5-11)
-- is drawn relative to WHERE the spark actually made contact.
--
-- The spark is steerable up and down in flight (spark_proc reads the thrower's
-- joystick and adds to oyvel).  spark_hit used to snap the object onto the
-- victim's anchor with match_me_with_him before playing the burst, which threw
-- the contact height away: aim the spark low and the streak hit low while the
-- burst still bloomed at the victim's chest.
--
-- The rig fires a real spark at range, steers it with a real joystick hold,
-- and records:
--    flight_y  - the object's oypos on the last tick it showed a FLIGHT frame
--    burst_y   - the object's oypos on the first tick it shows a BURST frame
--    victim_y  - the victim's oypos at that moment (= the OLD placement)
--
-- PASS when burst_y tracks flight_y (contact-aligned).  The old behaviour
-- reads burst_y == victim_y instead, so the two are directly distinguishable
-- in one line of log.
--
-- Env knobs:
--   SPARK_AIM=down|up|none   joystick hold during flight (default down)
--   SPARK_FORCE_DY=N         additionally shove the spark N px off the level
--                            line once it launches, to guarantee a big,
--                            unambiguous separation (default 0 = joystick only)
--   SPARK_RANGE=N            px to snap P1 behind the victim before firing
--   SPARK_OBSERVE=N          frames to watch after the burst starts
--   SPARK_ALIGN_LOG=path     override log path

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("SPARK_ALIGN_LOG") or (ROOT .. "/tools/baraka_spark_align_test.log")
local AIM = (os.getenv("SPARK_AIM") or "down"):lower()
local FORCE_DY = getenv_int("SPARK_FORCE_DY", 0)
local SNAP_X = getenv_int("SPARK_RANGE", 250)
local OBSERVE_FRAMES = getenv_int("SPARK_OBSERVE", 60)
local ALIGN_TOL = getenv_int("SPARK_TOL", 2)
-- A/B knob: reproduce the OLD placement (burst snapped onto the victim's
-- anchor) on the current ROM, by re-stomping the object's oyval the way
-- match_me_with_him used to leave it.  For before/after screenshots without
-- rebuilding the ROM.
local EMULATE_OLD = os.getenv("SPARK_EMULATE_OLD") == "1"
-- Trial knob for the burst's horizontal placement: extra pixels BACKWARD
-- (toward the thrower) on top of the -080h that spark_hit already applies.
-- Lets a new constant be eyeballed on screenshots without a ROM rebuild.
local BURST_BACK = getenv_int("SPARK_BURST_BACK", 0)
-- Fire from the victim's RIGHT instead of the left, to prove the burst
-- placement is symmetric under b_fliph (a code x-nudge next to an art anipoint
-- is exactly the kind of thing that lands 2*dx off on the other facing).
local MIRROR = os.getenv("SPARK_MIRROR") == "1"
-- Draw the engine's own strike box (f_colbox): strike_check paints the box it
-- is testing as a solid green rect in front of everything.  Run once with and
-- once without and the two snapshot sets line up frame for frame, so the box
-- and the streak art can be measured against each other.
local COLBOX = os.getenv("SPARK_COLBOX") == "1"

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[align] " .. msg)
end
local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end
local function s16(v)
    v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end
    return v
end
local function s32(v)
    v = v & 0xffffffff
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
end

-- Symbols from the freshly linked map (BSS shifts on every relink).
local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if not fh then map_path = ROOT .. "/src/MK2.MAP"; fh = io.open(map_path, "r") end
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
        log("loaded symbols from %s", map_path)
    else
        log("WARN no linker map found")
    end
end
local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s; fallback=%s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    active        = sym("active"),
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),
    p2_state      = sym("p2_state"),
    p1_char       = sym("p1_char"),
    p2_char       = sym("p2_char"),
    p1_obj        = sym("p1_obj"),
    p2_obj        = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),
    p2_proc       = sym("p2_proc"),
    p1_bar        = sym("p1_bar"),
    p2_bar        = sym("p2_bar"),
    curback       = sym("curback"),
    winner_status = sym("winner_status"),
    worldtlx      = sym("worldtlx"),
    f_colbox      = sym("f_colbox"),
    f_death       = sym("f_death"),
    objlst        = sym("objlst"),
    objlst2       = sym("objlst2"),
    objlst3       = sym("objlst3"),
}

local O = {
    next = 0x000, oxvel = 0x040, oyvel = 0x060, oxval = 0x080, oxpos = 0x090,
    oyval = 0x0a0, oypos = 0x0b0, ozval = 0x0c0, oflags = 0x0f0, osag = 0x100,
    osizex = 0x120, osizey = 0x130, oflags2 = 0x160, oimg = 0x1a0, oid = 0x1c0,
    ochar = 0x1f0,
}
local P = { next = 0x000, id = 0x020, pa8 = 0x0c0, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_SA, FT_JAX = 3, 11
local ACT_SPARK = 0x0007
local PID_PROJ1 = 0x0700
local STAGE_ID = 5

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, fight_count = 0, 0, 0
local p1_confirm_start = 0
local did_direct_select = false
local combo_start_frame, combo_attempt = 0, 0
local spark_fired_frame = 0
local launched_frame = 0
local forced_dy_done = false
local flight_y, flight_x, flight_frame = nil, nil, 0
local flight_yval, flight_yvel = nil, nil
local burst_y, burst_x, burst_frame, burst_victim_y = nil, nil, 0, nil
local finished = false
local snap_index = 0
local last_status_frame = 0
local last_label = nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Up"] = true, ["P1 Down"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-16s MISSING", name); ok = false end
    end
    return ok
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s", snap_index, frame, label, tostring(ok))
    snap_index = snap_index + 1
end

-- SAG -> frame label, so the object's CURRENT authored frame is readable.
local sag_labels = {}
local function load_sag_labels(path, pattern)
    local fh = io.open(path, "r")
    if not fh then return end
    local current = nil
    for line in fh:lines() do
        local label = line:match("^([%w_]+):") or line:match("^([%w_]+)%s")
        if label and label:match(pattern) then
            current = label
        elseif current then
            local raw = line:match("%.long%s+([%x]+)H") or line:match("%.long%s+([%x]+)h")
            if raw then sag_labels[tonumber(raw, 16) & 0x00ffffff] = current; current = nil end
        end
    end
    fh:close()
end
load_sag_labels(ROOT .. "/src/MKSA.TBL", "^UGSPARK%d")
load_sag_labels(ROOT .. "/src/MKSA2.TBL", "^UGSPARK%d")
load_sag_labels(ROOT .. "/src/SASPARK.TBL", "^UGSPARK%d")
do
    local n = 0
    for _ in pairs(sag_labels) do n = n + 1 end
    log("spark frame labels loaded: %d", n)
end

-- STRIP CENSUS.  Three of the burst's frames are multiparts whose later
-- strips were in no ROM until data/SAHELI.LOD's third section loaded them
-- (UGSPARK7B, 8B, 8C, 11B).  The head object's own SAG cannot see that - it
-- is the ?A strip either way.
--
-- A multipart is ONE object, not a chain of them (ani2, MKUTIL.ASM): oimg
-- points at "multipart ram", a run of 112-bit records - sag:32, y:x size:32,
-- control:16, dx:16, dy:16 - terminated by a zero sag.  That run IS what the
-- DMA walks, so reading it back is a direct measurement of the strips the
-- frame draws.  (Walking objlst instead finds only the head and reports every
-- second strip missing, including the two that always shipped.)
local spark_obj   -- forward: defined below, called only from the frame loop
local MPART_REC_BITS = 112
local strip_census = {}     -- ["UGSPARK8"] = { UGSPARK8A=true, ... }

local function multipart_sags(obj)
    local out = {}
    local mp = r32(obj + O.oimg)
    if mp == 0 then return out end
    for i = 0, 15 do
        local sag = r32(mp + i * MPART_REC_BITS)
        if sag == 0 then break end
        out[#out + 1] = sag & 0x00ffffff
    end
    return out
end

local function census_tick()
    local so = spark_obj()
    if so == 0 then return end
    local here = {}
    for _, sag in ipairs(multipart_sags(so)) do
        local lbl = sag_labels[sag]
        if lbl then here[lbl] = true end
    end
    for lbl in pairs(here) do
        local base = lbl:match("^(UGSPARK%d+)")
        if base then
            strip_census[base] = strip_census[base] or {}
            strip_census[base][lbl] = true
        end
    end
end

-- What UGMO8.IMG actually carries for each burst pose.
local EXPECTED_STRIPS = {
    UGSPARK5  = { "UGSPARK5A" },
    UGSPARK6  = { "UGSPARK6A" },
    UGSPARK7  = { "UGSPARK7A", "UGSPARK7B" },
    UGSPARK8  = { "UGSPARK8A", "UGSPARK8B", "UGSPARK8C" },
    UGSPARK9  = { "UGSPARK9A", "UGSPARK9B" },
    UGSPARK10 = { "UGSPARK10A", "UGSPARK10B" },
    UGSPARK11 = { "UGSPARK11A", "UGSPARK11B" },
}

-- Returns ok, summary.  Only poses the run actually reached are judged; a
-- burst cut short by the round ending is not a strip failure.
local function census_report()
    local ok, seen_any = true, false
    local lines = {}
    for i = 5, 11 do
        local base = "UGSPARK" .. i
        local got = strip_census[base]
        if got then
            seen_any = true
            local missing = {}
            for _, want in ipairs(EXPECTED_STRIPS[base]) do
                if not got[want] then missing[#missing + 1] = want end
            end
            local names = {}
            for s in pairs(got) do names[#names + 1] = s end
            table.sort(names)
            if #missing > 0 then
                ok = false
                lines[#lines + 1] = string.format("%s DREW %s MISSING %s",
                    base, table.concat(names, ","), table.concat(missing, ","))
            else
                lines[#lines + 1] = string.format("%s DREW %s ok", base, table.concat(names, ","))
            end
        end
    end
    if not seen_any then return nil, "no burst pose observed" end
    return ok, table.concat(lines, " | ")
end

local function find_proj_proc()
    local p = r32(A.active)
    local guard = 0
    while p ~= 0 and guard < 400 do
        if r16(p + P.id) == PID_PROJ1 then return p end
        p = r32(p + P.next)
        guard = guard + 1
    end
    return 0
end

-- The spark object is the projectile process's saved a8 (do_sa_zap: pa8).
function spark_obj()
    local p = find_proj_proc()
    if p == 0 then return 0 end
    return r32(p + P.pa8)
end

local function obj_label(obj)
    if obj == 0 then return nil end
    local sag1 = r32(obj + O.osag) & 0x00ffffff
    local lbl = sag_labels[sag1]
    if lbl then return lbl end
    local img = r32(obj + O.oimg)
    if img ~= 0 then return sag_labels[r32(img) & 0x00ffffff] end
    return nil
end

-- UGSPARK1-4 = windup/flight, UGSPARK5-11 = the hit burst.
local function label_phase(label)
    if not label then return nil end
    local n = tonumber(label:match("^UGSPARK(%d+)"))
    if not n then return nil end
    return (n >= 5) and "burst" or "flight", n
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state_line(tag)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1o ~= 0 then p1x, p1y = s16(r16(p1o + O.oxpos)), s16(r16(p1o + O.oypos)) end
    if p2o ~= 0 then p2x, p2y = s16(r16(p2o + O.oxpos)), s16(r16(p2o + O.oypos)) end
    local so = spark_obj()
    local sx, sy, syv, lbl = 0, 0, 0, "-"
    if so ~= 0 then
        sx, sy = s16(r16(so + O.oxpos)), s16(r16(so + O.oypos))
        syv = s32(r32(so + O.oyvel))
        lbl = obj_label(so) or "?"
    end
    return string.format(
        "%s gs=%d ws=%d p1act=0x%04x p1hp=%d p2hp=%d p1=(%d,%d) p2=(%d,%d) spark=%s@(%d,%d) yvel=%d",
        tag, r16(A.gstate), r16(A.winner_status), p1_action(),
        r16(A.p1_bar), r16(A.p2_bar), p1x, p1y, p2x, p2y, lbl, sx, sy, syv)
end

-- The object is moved by the engine (oyval += oyvel) at the top of the tick
-- the strike lands on, and spark_hit runs after that -- so the contact height
-- is one velocity step past the last FLIGHT frame this rig sampled.
local function predicted_contact_y()
    if not flight_yval then return nil end
    return (flight_yval + (flight_yvel or 0)) // 0x10000
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    if burst_y then
        local pred = predicted_contact_y()
        local dv = burst_y - (burst_victim_y or 0)
        local da = burst_y - (pred or 0)
        log("RESULT aim=%s force_dy=%d contact_y=%s burst_y=%d victim_y=%s | burst-contact=%d burst-victim=%d",
            AIM, FORCE_DY, tostring(pred), burst_y, tostring(burst_victim_y), da, dv)
    end
    local cok, csum = census_report()
    if cok == nil then
        log("STRIPS no-verdict: %s", csum)
    else
        log("STRIPS %s: %s", cok and "PASS" or "FAIL", csum)
        if not cok then ok = false; reason = reason .. "+missing_strips" end
    end
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", reason, state_line("end"))
    snap(ok and "final_ok" or ("final_" .. reason))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    w16(A.p1_char, FT_SA)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Baraka(%d) P2=Jax(%d) stage=%d range=%d aim=%s force_dy=%d mirror=%s",
            FT_SA, FT_JAX, STAGE_ID, SNAP_X, AIM, FORCE_DY, tostring(MIRROR))
    end
end

local function fighters_ok()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return false end
    return r16(p1o + O.ochar) == FT_SA and r16(p2o + O.ochar) == FT_JAX
end

local function snap_range()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local p2x = s16(r16(p2o + O.oxpos))
    local x = MIRROR and (p2x + SNAP_X) or (p2x - SNAP_X)
    w32(p1o + O.oxval, (x << 16) & 0xffffffff)
    w16(p1o + O.oxpos, x)
end

local function back_input_name()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return "P1 Left" end
    if s16(r16(p1o + O.oxpos)) > s16(r16(p2o + O.oxpos)) then return "P1 Right" end
    return "P1 Left"
end

-- One spark attempt = Down, Back, + HP inside the combo window.
local ATTEMPT_LEN = 44
local function combo_press(name, rel)
    -- scom_spark's window is 16 ticks and it is measured from the DOWN, so
    -- Down->HP has to span less than that: the old 0/11/17 schedule was 17
    -- ticks wide and never matched.  Back is also released before HP - holding
    -- away at the press hands HP to joy_power_punch (Baraka's swipe, action
    -- 0x1e) the moment the combo lookup misses, which is what hid the timing
    -- bug behind a move that did fire.
    if name == "P1 Down" and rel >= 0 and rel < 5 then return true end
    if rel >= 6 and rel < 11 and name == back_input_name() then return true end
    if name == "P1 High Punch" and rel >= 12 and rel < 22 then return true end
    return false
end

local function aim_press(name)
    if AIM == "down" and name == "P1 Down" then return true end
    if AIM == "up" and name == "P1 Up" then return true end
    return false
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    -- steer the spark in flight with a genuine joystick hold
    if spark_fired_frame > 0 and burst_frame == 0 then return aim_press(name) end
    if combo_start_frame > 0 and spark_fired_frame == 0 and fighting_frame > 0 then
        local rel = (frame - combo_start_frame) % ATTEMPT_LEN
        return combo_press(name, rel)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("loaded: aim=%s force_dy=%d range=%d tol=%d", AIM, FORCE_DY, SNAP_X, ALIGN_TOL)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d | %s", frame, state_line("fs"))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0
        and frame > charsel_frame + 90 and r16(A.p1_char) == FT_SA and r16(A.p2_char) == FT_JAX then
        p1_confirm_start = frame + 25
    end

    if COLBOX and fighting_frame > 0 and A.f_colbox ~= 0 then
        if r16(A.f_colbox) ~= 1 then w16(A.f_colbox, 1) end
    end

    if fighting_frame > 0 and spark_fired_frame == 0 then
        if combo_start_frame == 0 and fighters_ok() and frame - fighting_frame > 90 then
            snap_range()
            combo_start_frame = frame + 20
            log("ready frame=%d combo at %d | %s", frame, combo_start_frame, state_line("rdy"))
        end
        if combo_start_frame > 0 and frame >= combo_start_frame then
            if (frame - combo_start_frame) % ATTEMPT_LEN == 0 then
                combo_attempt = combo_attempt + 1
                snap_range()
                log("spark_attempt=%d frame=%d back=%s | %s",
                    combo_attempt, frame, back_input_name(), state_line("try"))
            end
            if p1_action() == ACT_SPARK or spark_obj() ~= 0 then
                spark_fired_frame = frame
                log("SPARK_FIRED frame=%d | %s", frame, state_line("fired"))
                snap("spark_fired")
            elseif combo_attempt >= 10 then
                finish(false, "spark_never_fired")
                return
            end
        end
    end

    -- Track the spark object frame by frame.
    if spark_fired_frame > 0 and not finished then
        local so = spark_obj()
        if so ~= 0 then
            local label = obj_label(so)
            local phase = label_phase(label)
            local y = s16(r16(so + O.oypos))
            local x = s16(r16(so + O.oxpos))
            census_tick()

            if launched_frame == 0 and s32(r32(so + O.oxvel)) ~= 0 then
                launched_frame = frame
                log("launched frame=%d | %s", frame, state_line("launch"))
            end
            -- Optional deterministic shove, applied one tick after launch so it
            -- rides the same oyval the flight loop maintains.
            if FORCE_DY ~= 0 and not forced_dy_done and launched_frame > 0
                and frame >= launched_frame + 1 and phase == "flight" then
                forced_dy_done = true
                local yv = s32(r32(so + O.oyval))
                w32(so + O.oyval, (yv + FORCE_DY * 0x10000) & 0xffffffff)
                log("force_dy applied %+d px at frame=%d", FORCE_DY, frame)
            end

            if label ~= last_label then
                log("frame=%d spark %s -> %s at (%d,%d) yvel=%d",
                    frame, tostring(last_label), tostring(label), x, y, s32(r32(so + O.oyvel)))
                last_label = label
            end

            if phase == "flight" then
                if launched_frame > 0 then
                    log("flight t=%d frame=%d obj=(%d,%d) screen=(%d,%d) label=%s",
                        frame - launched_frame, frame, x, y,
                        x - (r32(A.worldtlx) >> 16), y, tostring(label))
                    snap(string.format("flight_%02d", frame - launched_frame))
                end
                flight_y, flight_x, flight_frame = y, x, frame
                flight_yval = s32(r32(so + O.oyval))
                flight_yvel = s32(r32(so + O.oyvel))
            elseif phase == "burst" and burst_frame == 0 then
                burst_frame = frame
                burst_y, burst_x = y, x
                local p2o = r32(A.p2_obj)
                burst_victim_y = p2o ~= 0 and s16(r16(p2o + O.oypos)) or nil
                if BURST_BACK ~= 0 then
                    local flags = r16(so + O.oflags)
                    local dx = ((flags & 0x10) ~= 0) and BURST_BACK or -BURST_BACK
                    w32(so + O.oxval, (s32(r32(so + O.oxval)) + dx * 0x10000) & 0xffffffff)
                    x = s16(r16(so + O.oxpos))
                    burst_x = x
                    log("BURST_BACK %d px applied (fliph=%s) -> x=%d",
                        BURST_BACK, tostring((flags & 0x10) ~= 0), x)
                end
                log("burst geometry: obj_x=%d victim_x=%d worldtlx=%d fliph=%s",
                    x, s16(r16(r32(A.p2_obj) + O.oxpos)), r32(A.worldtlx) >> 16,
                    tostring((r16(so + O.oflags) & 0x10) ~= 0))
                if EMULATE_OLD then
                    local p2 = r32(A.p2_obj)
                    if p2 ~= 0 then
                        w32(so + O.oyval, r32(p2 + O.oyval))
                        log("EMULATE_OLD: burst forced onto victim anchor y=%d",
                            s16(r16(p2 + O.oypos)))
                    end
                end
                log("BURST frame=%d label=%s at (%d,%d) | contact_y=%s last_flight=(%s,%s) victim_y=%s",
                    frame, tostring(label), x, y, tostring(predicted_contact_y()),
                    tostring(flight_x), tostring(flight_y), tostring(burst_victim_y))
                snap("burst_start")
            end
            -- The burst is 7 poses at sleep 3 = ~21 ticks.  Six frames only
            -- reached UGSPARK7, so the three poses whose strips were missing
            -- (7, 8, 11) were never in a snapshot.
            if burst_frame > 0 and (frame - burst_frame) <= 24 then
                snap(string.format("burst_%02d_%s", frame - burst_frame,
                                   tostring(label)))
            end
        elseif burst_frame > 0 then
            -- spark object gone: the burst has finished
            if frame - burst_frame > 4 then
                local da = burst_y - (predicted_contact_y() or 0)
                if math.abs(da) <= ALIGN_TOL then
                    finish(true, string.format("aligned_delta_%d", da))
                else
                    finish(false, string.format("misaligned_delta_%d", da))
                end
                return
            end
        end
        if burst_frame > 0 and frame - burst_frame > OBSERVE_FRAMES then
            local da = burst_y - (predicted_contact_y() or 0)
            if math.abs(da) <= ALIGN_TOL then finish(true, string.format("aligned_delta_%d", da))
            else finish(false, string.format("misaligned_delta_%d", da)) end
            return
        end
        if burst_frame == 0 and frame - spark_fired_frame > 400 then
            finish(false, "spark_never_hit")
            return
        end
    end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        log("status | %s", state_line("status"))
    end

    local held = {}
    for name, field in pairs(fields) do
        local on = pressed(name)
        field:set_value(on and 1 or 0)
        if on then held[#held + 1] = name end
    end
    if os.getenv("SPARK_TRACE") == "1" and combo_start_frame > 0 and fighting_frame > 0
       and spark_fired_frame == 0 and (frame - combo_start_frame) < (ATTEMPT_LEN * 2) then
        table.sort(held)
        log("trace rel=%d p1act=0x%04x held=[%s]",
            (frame - combo_start_frame) % ATTEMPT_LEN, p1_action(), table.concat(held, ","))
    end

    if fighting_frame == 0 and frame > 8000 then finish(false, "never_reached_fight")
    elseif frame > 16000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
