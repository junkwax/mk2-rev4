-- baraka_spark_finishim_test.lua
--
-- Reproduction harness for the reported bug: playing Baraka, firing his blade
-- spark projectile (do_sa_zap) DURING the "FINISH HIM" window corrupts the game.
--
-- Baraka's HP handler (sa_hi_punch, MOVES.ASM) checks the spark combo
-- (scom_spark = Down,Back) BEFORE the decap-fatality combo, and fires the
-- spark through restricted_xfer -- which, unlike fatality_xfer, does NOT gate
-- on winner_status / f_death / victim-dizzy.  So the spark is reachable during
-- FINISH HIM on a far-less-guarded path.  This harness drives exactly that.
--
-- Flow (modeled on st_decap_fatality_test.lua):
--   1. Direct-select P1 Baraka (ft_sa=3) vs P2 Jax (ft_jax=11), reach fight.
--   2. Force FINISH HIM: winner_status=3, f_death=0, victim wake=dizzy_dude.
--   3. Wait for the victim to be genuinely dizzy (ACT_STUNNED in dizzy window).
--   4. Snap P1 to a fixed range, then input the spark combo (Down, Back, +HP),
--      retrying until the spark fires (p1 action == act_spark) or timeout.
--   5. Dense per-frame diagnostics + screenshots for OBSERVE_FRAMES frames,
--      running corruption detectors the whole time.
--
-- Env knobs:
--   BARAKA_WS=N          winner_status to force (default 3 = finish him)
--   BARAKA_CONTROL=1     fire the spark during a NORMAL fight (ws stays 0) as
--                        a control, to isolate whether finish-him is required.
--   BARAKA_OBSERVE=N     frames to observe after the spark fires (default 200)
--   BARAKA_TEST_LOG=path override log path

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("BARAKA_TEST_LOG")
    or (ROOT .. "/tools/baraka_spark_finishim_test.log")
local WS_FORCE = getenv_int("BARAKA_WS", 3)
local CONTROL = os.getenv("BARAKA_CONTROL") == "1"
local OBSERVE_FRAMES = getenv_int("BARAKA_OBSERVE", 200)
if CONTROL then WS_FORCE = 0 end

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
    print("[baraka] " .. msg)
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

-- Resolve symbols from the freshly built linker map.
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
        log("WARN no linker map found; using address fallbacks")
    end
end
local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s; fallback=%s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    active        = sym("active", 0x010dc6d0),
    gstate        = sym("gstate", 0x0112a7f0),
    p1_state      = sym("p1_state", 0x0112a810),
    p2_state      = sym("p2_state", 0x0112b3e0),
    p1_char       = sym("p1_char", 0x0112a8a0),
    p2_char       = sym("p2_char", 0x0112b470),
    p1_obj        = sym("p1_obj", 0x0112a840),
    p2_obj        = sym("p2_obj", 0x0112b410),
    p1_proc       = sym("p1_proc", 0x0112a860),
    p2_proc       = sym("p2_proc", 0x0112b430),
    p1_bar        = sym("p1_bar", 0x0112a910),
    p2_bar        = sym("p2_bar", 0x0112b4e0),
    curback       = sym("curback", 0x0112c0f0),
    round_num     = sym("round_num", 0x0112c120),
    winner_status = sym("winner_status", 0x0112c170),
    f_death       = sym("f_death", 0x0112c020),
    f_death2      = sym("f_death2", 0x0112c650),
    objlst        = sym("objlst", 0x01127570),
    objlst2       = sym("objlst2", 0x01127590),
    objlst3       = sym("objlst3", 0x011275b0),
    dizzy_dude    = sym("dizzy_dude", 0xffa27af0),
    dizzy         = sym("dizzy", 0xffa27e40),
    system_lockup = sym("system_lockup", 0xffa74d60),
    tvbp          = sym("TVBP", 0xffa74f70),
}

local O = {
    next = 0x000, ograv = 0x020, oyvel = 0x060, oxval = 0x080, oxpos = 0x090,
    oyval = 0x0a0, oypos = 0x0b0, ozval = 0x0c0, oflags = 0x0f0, osag = 0x100,
    opal = 0x140, oflags2 = 0x160, oimg = 0x1a0, oid = 0x1c0, ochar = 0x1f0,
}
local P = {
    next = 0x000, id = 0x020, time = 0x030, sp = 0x040, pa8 = 0x0c0,
    wake = 0x0e0, action = 0x1f0, flags = 0x210,
}

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_SA, FT_JAX = 3, 11
local ACT_SPARK = 0x0007
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local PID_PROJ1 = 0x0700
local STAGE_ID = 5   -- Armory (no stage fatality route to confuse the input)
local SNAP_X = 80    -- P1 distance left of victim before firing

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, fight_count = 0, 0, 0
local p1_confirm_start = 0
local did_direct_select = false
local finish_forced_frame = 0
local victim_dizzy_forced = false
local dizzy_ready_frame = 0
local combo_start_frame = 0
local combo_attempt = 0
local spark_fired_frame = 0
local observe_start = 0
local finished, did_error = false, false
local repro_kind = nil
local baseline_obj_count = 0
local last_status_frame = 0
local snap_index = 0

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
        if fields[name] then log("input %-16s ok", name)
        else log("input %-16s MISSING", name); ok = false end
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
    local ok, err = false, "no screen"
    if s then ok, err = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s%s", snap_index, frame, label,
        tostring(ok), ok and "" or (" err=" .. tostring(err)))
    snap_index = snap_index + 1
end

-- SAG labels: recognise the spark projectile art in the object list.
local sag_labels = {}
local function load_sag_labels(path, pattern)
    local fh = io.open(path, "r")
    if not fh then log("WARN cannot open %s", path); return end
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
load_sag_labels(ROOT .. "/src/MKSA.TBL", "^UGSPARKBLADE%d")
load_sag_labels(ROOT .. "/src/MKSA2.TBL", "^UGSPARK%d")
load_sag_labels(ROOT .. "/src/MKSA2.TBL", "^UGSPARKBLADE%d")

local function walk_objects(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        local seen = {}
        while obj ~= 0 and guard < 300 do
            if seen[obj] then return "cycle", list, obj end
            seen[obj] = true
            fn(obj)
            obj = r32(obj + O.next)
            guard = guard + 1
        end
        if guard >= 300 then return "overflow", list, obj end
    end
    return nil
end

local function object_count()
    local n = 0
    local err = walk_objects(function() n = n + 1 end)
    return n, err
end

local function spark_objects()
    local labels = {}
    walk_objects(function(obj)
        local sag1 = r32(obj + O.osag) & 0x00ffffff
        local img = r32(obj + O.oimg)
        local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
        local label = sag_labels[sag1] or sag_labels[sag2]
        if label then labels[label] = true end
    end)
    local out = {}
    for k in pairs(labels) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function count_procs()
    local p = r32(A.active)
    local n, guard = 0, 0
    local seen = {}
    while p ~= 0 and guard < 400 do
        if seen[p] then return n, true end   -- cycle
        seen[p] = true
        n = n + 1
        p = r32(p + P.next)
        guard = guard + 1
    end
    return n, false
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

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state_line(tag)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1o ~= 0 then p1x, p1y = r16(p1o + O.oxpos), s16(r16(p1o + O.oypos)) end
    if p2o ~= 0 then p2x, p2y = r16(p2o + O.oxpos), s16(r16(p2o + O.oypos)) end
    local nobj, oerr = object_count()
    local nproc, pcycle = count_procs()
    return string.format(
        "%s gs=%d ws=%d fdeath=%d fdeath2=%d p1act=0x%04x p1hp=%d p2hp=%d p1=(%d,%d) p2=(%d,%d) objs=%d%s procs=%d%s proj=%s spark=[%s]",
        tag, r16(A.gstate), r16(A.winner_status), r16(A.f_death), r16(A.f_death2),
        p1_action(), r16(A.p1_bar), r16(A.p2_bar), p1x, p1y, p2x, p2y,
        nobj, oerr and ("!" .. oerr) or "", nproc, pcycle and "!cycle" or "",
        hx(find_proj_proc()), table.concat(spark_objects(), "+"))
end

local function cpu_pc()
    if not cpu then return nil end
    for _, name in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, item = pcall(function() return cpu.state[name] end)
        if ok and item then
            local okv, v = pcall(function() return item.value end)
            if okv then return v end
        end
    end
    return nil
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_ok" or ("final_" .. reason))
    log("%s reason=%s | %s", ok and "PASS" or "REPRO/FAIL", reason, state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

-- Normal spark recovery (measured from the control run): Baraka leaves
-- act_spark and returns to a stance action (~0x0303) by ~rel 60, and his
-- object position never moves.  These bound the freeze/corruption detectors.
local SPARK_RECOVER_BY = 90   -- rel by which act_spark must have ended
local prev_p1x, prev_p1y = nil, nil

local function p1_xy()
    local o = r32(A.p1_obj)
    if o == 0 then return nil, nil end
    return r16(o + O.oxpos), s16(r16(o + O.oypos))
end

-- Corruption detectors: return a reason string if something is wrong.
-- rel is frames since the spark fired (nil before it fires).
local function detect_corruption(rel)
    local pc = cpu_pc()
    if pc and pc >= A.system_lockup and pc < A.tvbp then
        return "lockup_pc_" .. hx(pc)
    end
    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then return "bad_gstate_" .. string.format("0x%04x", gs) end
    local nobj, oerr = object_count()
    if oerr then return "objlist_" .. oerr end
    if baseline_obj_count > 0 and nobj > baseline_obj_count + 40 then
        return "object_explosion_" .. nobj
    end
    local _, pcycle = count_procs()
    if pcycle then return "active_proc_cycle" end

    -- Post-spark, finish-him-specific soft-lock detectors.
    if rel then
        local p1x, p1y = p1_xy()
        if p1x then
            -- position corruption: a big single-frame jump, or Baraka thrown
            -- off the top (the bug drove x to 0xFF7F / y to -1).
            if prev_p1x then
                if math.abs(p1x - prev_p1x) > 200 or math.abs(p1y - prev_p1y) > 120 then
                    return string.format("p1_pos_jump_from_%d_%d_to_%d_%d", prev_p1x, prev_p1y, p1x, p1y)
                end
            end
            if p1y < -32 then return "p1_offscreen_top_y_" .. p1y end
            prev_p1x, prev_p1y = p1x, p1y
        end
        -- freeze: still in act_spark well past normal recovery.
        if rel > SPARK_RECOVER_BY and p1_action() == ACT_SPARK then
            return "spark_freeze_rel_" .. rel
        end
    end
    return nil
end

local function force_select()
    w16(A.p1_char, FT_SA)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Baraka(%d) P2=Jax(%d) stage=%d", FT_SA, FT_JAX, STAGE_ID)
    end
end

local function fighters_ok()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return false end
    return r16(p1o + O.ochar) == FT_SA and r16(p2o + O.ochar) == FT_JAX
end

local function force_finish_him()
    if CONTROL then return end
    if fight_count ~= 1 or spark_fired_frame ~= 0 then return end
    if not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 720 then return end
    w16(A.winner_status, WS_FORCE)
    w16(A.f_death, 0)
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then
        w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2p = r32(A.p2_proc)
    if p2p ~= 0 and not victim_dizzy_forced then
        w32(p2p + P.wake, A.dizzy_dude)
        victim_dizzy_forced = true
    end
    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        log("finish_him_forced frame=%d rel=%d ws=%d | %s", frame, rel, WS_FORCE, state_line("ff"))
        snap("finish_him_forced")
    end
end

local function victim_ready()
    if CONTROL then return fighters_ok() end
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

local function snap_range()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local p2x = r16(p2o + O.oxpos)
    local x = p2x - SNAP_X
    w16(p1o + O.oxpos, x)
    w32(p1o + O.oxval, (x << 16) & 0xffffffff)
    log("snap_range p1_x=%d p2_x=%d dist=%d", x, p2x, SNAP_X)
end

-- One spark attempt = Down, Back, + HP within the 16(+6)-tick window.
--
-- "Back" is resolved LIVE from which side P1 is standing on, not hardcoded to
-- Left.  P1 is snapped left of the victim, but in finish-him mode he can end
-- up on the far side before the first attempt - and then a hardcoded Left is
-- FORWARD, the combo never matches, and the run reports "spark suppressed"
-- when the truth is the input was never made.
local function back_input_name()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return "P1 Left" end
    if r16(p1o + O.oxpos) > r16(p2o + O.oxpos) then return "P1 Right" end
    return "P1 Left"
end

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

local function pressed(name)
    -- boot: coin + 2P start
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    -- char select confirm
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    -- spark combo attempts (only while trying to fire, before it fires)
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
        log("loaded: mode=%s ws_force=%d observe=%d", CONTROL and "CONTROL_normal_fight" or "finish_him",
            WS_FORCE, OBSERVE_FRAMES)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d | %s", frame, fight_count, state_line("fs"))
            snap("fight_start")
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0
        and frame > charsel_frame + 90 and r16(A.p1_char) == FT_SA and r16(A.p2_char) == FT_JAX then
        p1_confirm_start = frame + 25
        log("confirm_start=%d", p1_confirm_start)
    end

    if fighting_frame > 0 and spark_fired_frame == 0 then
        force_finish_him()
        -- Once victim is dizzy (or, in control mode, fighters are up), begin combo.
        if combo_start_frame == 0 and (finish_forced_frame > 0 or CONTROL) and victim_ready() then
            if dizzy_ready_frame == 0 then
                dizzy_ready_frame = frame
                snap_range()
                combo_start_frame = frame + 20
                log("victim_ready frame=%d; combo begins at %d | %s", frame, combo_start_frame, state_line("vr"))
                snap("victim_ready")
            end
        end
        -- Detect the spark firing.
        if combo_start_frame > 0 and frame >= combo_start_frame then
            if (frame - combo_start_frame) % ATTEMPT_LEN == 0 then
                combo_attempt = combo_attempt + 1
                baseline_obj_count = object_count()
                -- re-snap: P1 drifts (and can cross sides) between attempts,
                -- which silently changes what "Back" means and the range.
                snap_range()
                log("spark_attempt=%d frame=%d back=%s | %s", combo_attempt, frame,
                    back_input_name(), state_line("try"))
            end
            if p1_action() == ACT_SPARK or #spark_objects() > 0 then
                spark_fired_frame = frame
                observe_start = frame
                log("SPARK_FIRED frame=%d attempt=%d | %s", frame, combo_attempt, state_line("fired"))
                snap("spark_fired")
            elseif combo_attempt >= 8 then
                if CONTROL then
                    -- Normal fight: the spark MUST fire; not firing means the
                    -- combo input broke, not a real result.
                    finish(false, "spark_never_fired_control")
                else
                    -- Finish-him mode: the fix makes the spark refuse to fire
                    -- (sahp_spark skips to the fatality check when ws==3).
                    -- Reaching here with no corruption = correct suppression.
                    finish(true, "spark_correctly_suppressed_finish_him")
                end
                return
            end
        end
    end

    -- Observation window: dense diagnostics + corruption detection.
    if spark_fired_frame > 0 then
        local rel = frame - observe_start
        local reason = detect_corruption(rel)
        if reason and not did_error then
            did_error = true
            repro_kind = reason
            log("CORRUPTION frame=%d rel=%d kind=%s | %s", frame, rel, reason, state_line("corrupt"))
            snap("corruption_" .. reason)
            -- keep observing a little to capture the aftermath
        end
        -- screenshot the first ~40 frames densely, then every 10
        if rel <= 40 or rel % 10 == 0 then
            log("obs rel=%d | %s", rel, state_line("obs"))
            snap(string.format("obs_%03d", rel))
        end
        if rel >= OBSERVE_FRAMES then
            if did_error then finish(false, "repro_" .. tostring(repro_kind))
            else finish(true, "no_corruption_observed") end
            return
        end
    end

    -- Global lockup guard, active any time in-fight.
    if fighting_frame > 0 then
        local pc = cpu_pc()
        if pc and pc >= A.system_lockup and pc < A.tvbp and not did_error then
            did_error = true
            repro_kind = "lockup_pc"
            log("LOCKUP frame=%d pc=%s | %s", frame, hx(pc), state_line("lock"))
            snap("lockup")
            finish(false, "repro_lockup_" .. hx(pc))
            return
        end
    end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        log("status | %s", state_line("status"))
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then finish(false, "never_reached_fight")
    elseif combo_start_frame > 0 and spark_fired_frame == 0 and frame - combo_start_frame > 500 then
        finish(false, "spark_never_fired_timeout")
    elseif frame > 16000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
