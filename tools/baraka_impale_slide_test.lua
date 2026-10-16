-- baraka_impale_slide_test.lua
--
-- Drives Baraka's Back,Forward,Down,Forward + LP impale fatality (do_impale,
-- MKDEATH.ASM) during FINISH HIM and MEASURES the ride: how far the victim is
-- lifted onto the blades, where the downward slide starts, how far it travels
-- and where he is parked when stop_him freezes him.
--
-- Why: the tail of do_impale sets the victim's oyvel to 0x10000 (1 px/tick)
-- and an away_x_vel of -0x10000, sleeps a fixed number of ticks and then
-- stop_him's him.  That sleep IS the slide distance.  a_impaled lifts him a
-- net 56px (ani_adjustxy +010h then three -018h), so the retail 14-tick slide
-- gives back only a quarter of the lift.  This rig reports the real numbers
-- and snapshots the slide so a longer one can be judged, not guessed.
--
-- The direction matters as much as the distance: the victim's art carries a
-- red open wound where the blade leaves his back, and only motion PARALLEL to
-- the blade (dx/dy = 0.58) keeps the two lined up.  Retail's 1:1 was 15 degrees
-- off, which costs sin(15) per pixel travelled -- invisible over 14px, obvious
-- over 24.  Check the wound in the slide_end snapshot, not just the height.
--
-- Flow (modeled on raiden_lift_fatality_test.lua, which reaches FINISH HIM the
-- honest way -- forcing winner_status=3 by hand leaves the victim un-dizzy and
-- fatality_xfer rejects every attempt):
--   1. Direct-select P1 Baraka (ft_sa=3) vs P2 Jax (ft_jax=11), reach fight.
--   2. Round 1: plain KO.  Round 2: drain the victim so FINISH HIM comes up.
--   3. Snap P1 inside the 0x88 close-range gate, tap B,F,D,F + LP until
--      f_death goes non-zero.
--   4. Log the victim's oypos/oyvel every frame, snapshot the slide, and
--      print a summary: stand y, peak lift, slide start/end, travel.
--
-- Env knobs:
--   BIS_LOG=path        log path
--   BIS_OBSERVE=N       frames to keep watching after f_death clears (default 150)
--   BIS_HANG=N          frames the fatality may stay live before it's a hang
--   BIS_TAG=name        label stamped into the summary line (e.g. before/after)

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("BIS_LOG") or (ROOT .. "/tools/baraka_impale_slide_test.log")
local OBSERVE = getenv_int("BIS_OBSERVE", 150)
local HANG_LIMIT = getenv_int("BIS_HANG", 900)
local TAG = os.getenv("BIS_TAG") or "run"
-- Preview probe: after stop_him parks the victim, keep walking him down the
-- blades by hand for this many more pixels, snapping every BIS_EXTRA_STEP.
-- Lets a longer slide be SEEN before it is assembled into the ROM.
local EXTRA = getenv_int("BIS_EXTRA", 0)
local EXTRA_STEP = getenv_int("BIS_EXTRA_STEP", 5)

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
    print("[bis] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
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
    log("WARN missing symbol %s", name)
    return fallback or 0
end

local A = {
    active        = sym("active"),
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),      p2_state = sym("p2_state"),
    p1_char       = sym("p1_char"),       p2_char  = sym("p2_char"),
    p1_obj        = sym("p1_obj"),        p2_obj   = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),       p2_proc  = sym("p2_proc"),
    p1_bar        = sym("p1_bar"),        p2_bar   = sym("p2_bar"),
    curback       = sym("curback"),
    winner_status = sym("winner_status"),
    f_death       = sym("f_death"),
    objlst        = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    dizzy         = sym("dizzy"),
    system_lockup = sym("system_lockup"),
    tvbp          = sym("TVBP"),
}

local O = {
    next = 0x000, oyvel = 0x060, oxval = 0x080, oxpos = 0x090,
    oyval = 0x0a0, oypos = 0x0b0, oflags = 0x0f0, osag = 0x100,
    osizex = 0x120, osizey = 0x130, oflags2 = 0x160, oimg = 0x1a0,
    oid = 0x1c0, oshape = 0x1d0, ochar = 0x1f0,
}
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_SA = 3
-- Victim: ft_* id from MAINEQU.ASM (11 = Jax).  Each character carries its own
-- a_impaled lift, from -39 (ninjas) to -82 (Cage), so the ride height - and
-- therefore how much slide fits under it - is per victim.
local FT_VIC = getenv_int("BIS_VICTIM", 11)
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local STAGE_ID = 5           -- Armory: no stage fatality to confuse the input
local SNAP_X = 78            -- P1 offset from the victim; close gate is 0x88 = 136

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, fight_count = 0, 0, 0
local p1_confirm_start, did_direct_select = 0, false
local finish_forced_frame, victim_dizzy_forced = 0, false
local combo_start_frame, combo_attempt = 0, 0
local fatal_frame, fatal_end_frame = 0, 0
local finished = false
local snap_index = 0
local body_seq, last_body = {}, nil
local fatal_num = nil
local extra_done, extra_next_snap = 0, 0
local extra_x_acc, extra_x0 = 0.0, nil
-- Blade axis: dx per px of y, measured off the exposed blade (0.569) and
-- UGSTAB6C's 42x70 art box (0.600).  do_impale's slide uses the same number.
local BLADE_DXDY = 0.58

-- slide measurements
local stand_y, peak_y, peak_rel = nil, nil, nil
local slide_start_rel, slide_start_y, slide_start_x = nil, nil, nil
local slide_end_rel, slide_end_y, slide_end_x = nil, nil, nil
local was_sliding = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

--------------------------------------------------------------------------
-- SAG -> label maps, straight out of the source art tables.
--------------------------------------------------------------------------
local function load_sags(path, into)
    local fh = io.open(path, "r")
    if not fh then return 0 end
    local n, current = 0, nil
    for line in fh:lines() do
        local label = line:match("^([%w_]+):") or line:match("^(UG[%w_]*)%s*$")
        if label then current = label end
        if current then
            local raw = line:match("%.long%s+0?x?([%x]+)[Hh]")
            if raw then
                local sag = tonumber(raw, 16)
                if into[sag] == nil then into[sag] = current end
                sag = sag & 0x00ffffff
                if into[sag] == nil then into[sag] = current end
                current = nil
                n = n + 1
            end
        end
    end
    fh:close()
    return n
end

local all_sags = {}
do
    local total = 0
    local ok, dirlist = pcall(function()
        local t, p = {}, io.popen('dir /b "' .. ROOT:gsub("/", "\\") .. '\\src\\*.TBL"')
        if p then for l in p:lines() do t[#t + 1] = l end p:close() end
        return t
    end)
    if ok and dirlist then
        for _, f in ipairs(dirlist) do total = total + load_sags(ROOT .. "/src/" .. f, all_sags) end
    end
    total = total + load_sags(ROOT .. "/src/MKSA.ASM", all_sags)
    log("art SAGs: %d records", total)
end

local function obj_label(obj)
    if obj == 0 then return nil, 0 end
    local cands = { r32(obj + O.osag) }
    local img = r32(obj + O.oimg)
    if img ~= 0 then cands[#cands + 1] = r32(img) end
    for _, raw in ipairs(cands) do
        local lab = all_sags[raw] or all_sags[raw & 0x00ffffff]
        if lab then return lab, raw end
    end
    return nil, cands[#cands]
end

local function walk(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if list ~= 0 then
            local obj, guard, seen = r32(list), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then return "cycle" end
                seen[obj] = true
                fn(obj)
                obj = r32(obj + O.next)
                guard = guard + 1
            end
        end
    end
    return nil
end

local function object_count()
    local n = 0
    local err = walk(function() n = n + 1 end)
    return n, err
end

local function count_procs()
    local p, n, guard, seen = r32(A.active), 0, 0, {}
    while p ~= 0 and guard < 400 do
        if seen[p] then return n, true end
        seen[p] = true
        n = n + 1
        p = r32(p + P.next)
        guard = guard + 1
    end
    return n, false
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function vic_xy()
    local o = r32(A.p2_obj)
    if o == 0 then return 0, 0, 0 end
    return s16(r16(o + O.oxpos)), s16(r16(o + O.oypos)), s32(r32(o + O.oyvel))
end

local function state_line(tag)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local blab = select(1, obj_label(p1o))
    local vlab = select(1, obj_label(p2o))
    local p1x, p1y = 0, 0
    if p1o ~= 0 then p1x, p1y = s16(r16(p1o + O.oxpos)), s16(r16(p1o + O.oypos)) end
    local vx, vy, vyv = vic_xy()
    local nobj, oerr = object_count()
    local nproc, pcyc = count_procs()
    return string.format(
        "%s gs=%d ws=%d fdeath=%d p1act=0x%04x p1=(%d,%d)%s p2=(%d,%d) yvel=%s vic=%s objs=%d%s procs=%d%s",
        tag, r16(A.gstate), r16(A.winner_status), s16(r16(A.f_death)), p1_action(),
        p1x, p1y, blab and (" " .. blab) or "",
        vx, vy, hx(vyv), vlab or "?",
        nobj, oerr and ("!" .. oerr) or "", nproc, pcyc and "!cycle" or "")
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

local function summary()
    log("---- SLIDE SUMMARY (%s) ----", TAG)
    log("stand_y      = %s", tostring(stand_y))
    log("peak_y       = %s (rel=%s)  lift=%s px",
        tostring(peak_y), tostring(peak_rel),
        (stand_y and peak_y) and tostring(stand_y - peak_y) or "?")
    log("slide_start  = y %s x %s (rel=%s)", tostring(slide_start_y),
        tostring(slide_start_x), tostring(slide_start_rel))
    log("slide_end    = y %s x %s (rel=%s)", tostring(slide_end_y),
        tostring(slide_end_x), tostring(slide_end_rel))
    if slide_start_y and slide_end_y then
        log("slide travel = %d px down, %d px toward Baraka, %s ticks",
            slide_end_y - slide_start_y, math.abs(slide_end_x - slide_start_x),
            tostring(slide_end_rel - slide_start_rel))
    end
    if stand_y and slide_end_y then
        log("parked %d px above his standing height", stand_y - slide_end_y)
    end
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_ok" or ("final_" .. reason))
    log("body frames seen: %s", table.concat(body_seq, ","))
    summary()
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", reason, state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
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

local function detect_corruption()
    local pc = cpu_pc()
    if pc and A.system_lockup ~= 0 and A.tvbp ~= 0
        and pc >= A.system_lockup and pc < A.tvbp then
        return "lockup_pc_" .. hx(pc)
    end
    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then return string.format("bad_gstate_0x%04x", gs) end
    local nobj, oerr = object_count()
    if oerr then return "objlist_" .. oerr end
    if nobj > 220 then return "object_explosion_" .. nobj end
    local _, pcyc = count_procs()
    if pcyc then return "active_proc_cycle" end
    return nil
end

--------------------------------------------------------------------------
-- Setup / input
--------------------------------------------------------------------------
local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Down"] = true,
        ["P1 Low Punch"] = true,
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

local function force_select()
    w16(A.p1_char, FT_SA)
    w16(A.p2_char, FT_VIC)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Baraka(%d) P2=victim ft_%d stage=%d", FT_SA, FT_VIC, STAGE_ID)
    end
end

local function fighters_ok()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return false end
    return r16(p1o + O.ochar) == FT_SA and r16(p2o + O.ochar) == FT_VIC
end

local function force_finish_him()
    if fatal_frame ~= 0 then return end
    if not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 120 then return end
    if fight_count < 2 then
        if r16(A.p2_bar) > 0 then
            w16(A.p2_bar, 0)
            log("round1_ko frame=%d | %s", frame, state_line("ko1"))
        end
        return
    end
    if not victim_dizzy_forced then
        w16(A.p2_bar, 0)
        victim_dizzy_forced = true
        log("drained_p2 frame=%d | %s", frame, state_line("kill"))
    end
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then
        w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    if finish_forced_frame == 0 and r16(A.winner_status) == 3 then
        finish_forced_frame = frame
        log("finish_him frame=%d | %s", frame, state_line("ff"))
        snap("finish_him")
    end
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return A.dizzy ~= 0 and wake >= A.dizzy and wake < (A.dizzy + 0x120)
end

local function snap_range()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local p2x = r16(p2o + O.oxpos)
    local x = p2x - SNAP_X
    w16(p1o + O.oxpos, x)
    w32(p1o + O.oxval, (x << 16) & 0xffffffff)
end

local function fwd_name()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return "P1 Right" end
    if r16(p1o + O.oxpos) > r16(p2o + O.oxpos) then return "P1 Left" end
    return "P1 Right"
end
local function back_name()
    return fwd_name() == "P1 Right" and "P1 Left" or "P1 Right"
end

-- One attempt: Back, Forward, Down, Forward then Low Punch, all inside
-- scom_sa_stab's 0x38 = 56 tick window.
local ATTEMPT_LEN = 70
local function combo_press(name, rel)
    local f, b = fwd_name(), back_name()
    if name == b and rel >= 0 and rel < 5 then return true end
    if name == f and ((rel >= 9 and rel < 14) or (rel >= 27 and rel < 32)) then return true end
    if name == "P1 Down" and rel >= 18 and rel < 23 then return true end
    if name == "P1 Low Punch" and rel >= 36 and rel < 41 then return true end
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
    if combo_start_frame > 0 and fatal_frame == 0 and fighting_frame > 0 then
        return combo_press(name, (frame - combo_start_frame) % ATTEMPT_LEN)
    end
    return false
end

--------------------------------------------------------------------------
local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("Baraka B,F,D,F+LP impale slide probe; tag=%s observe=%d", TAG, OBSERVE)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d | %s", frame, fight_count, state_line("fs"))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        force_select()
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_SA and r16(A.p2_char) == FT_VIC then
            p1_confirm_start = frame + 25
        end
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    if fatal_frame == 0 then
        force_finish_him()
        if combo_start_frame == 0 and finish_forced_frame > 0 and victim_ready() then
            combo_start_frame = frame
            snap_range()
            local _, vy = vic_xy()
            stand_y = vy
            log("combo_start frame=%d stand_y=%d | %s", frame, vy, state_line("cs"))
        end
        if combo_start_frame > 0 then
            local rel = (frame - combo_start_frame) % ATTEMPT_LEN
            if rel == 0 then
                combo_attempt = combo_attempt + 1
                snap_range()
                local _, vy = vic_xy()
                stand_y = vy
                log("attempt %d frame=%d | %s", combo_attempt, frame, state_line("try"))
            end
            if r16(A.winner_status) ~= 3 then w16(A.winner_status, 3) end
        end
        if s16(r16(A.f_death)) ~= 0 then
            fatal_frame = frame
            fatal_num = s16(r16(A.f_death))
            peak_y = select(2, vic_xy())
            log("FATALITY STARTED frame=%d after %d attempts stand_y=%s | %s",
                frame, combo_attempt, tostring(stand_y), state_line("go"))
            snap("fatality_start")
        end
        if combo_attempt > 24 then finish(false, "fatality_never_triggered"); return end
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    -- ---- fatality is live: watch it ----
    for name, field in pairs(fields) do field:set_value(0) end

    local rel = frame - fatal_frame
    local bad = detect_corruption()
    if bad then finish(false, bad .. "_at_rel_" .. rel); return end

    local p1o = r32(A.p1_obj)
    local blab, bsag = obj_label(p1o)
    if blab ~= last_body then
        body_seq[#body_seq + 1] = blab or ("?" .. hx(bsag))
        last_body = blab
    end

    local vx, vy, vyv = vic_xy()
    if peak_y == nil or vy < peak_y then peak_y, peak_rel = vy, rel end

    local sliding = (vyv ~= 0)
    if sliding and not was_sliding then
        slide_start_rel, slide_start_y, slide_start_x = rel, vy, vx
        log("SLIDE START rel=%d y=%d x=%d yvel=%s | %s", rel, vy, vx, hx(vyv), state_line("slide"))
        snap("slide_start")
    elseif (not sliding) and was_sliding and slide_end_rel == nil then
        slide_end_rel, slide_end_y, slide_end_x = rel, vy, vx
        extra_x0 = vx
        log("SLIDE END   rel=%d y=%d x=%d travel=%d px | %s",
            rel, vy, vx, vy - (slide_start_y or vy), state_line("slide"))
        snap("slide_end")
    end
    was_sliding = sliding

    if rel <= 40 or rel % 10 == 0 then log("rel=%-4d | %s", rel, state_line("obs")) end
    if rel == 1 or rel == 30 or rel == 60 or rel == 90 or rel == 120 or rel == 160 then
        snap(string.format("fat_%03d", rel))
    end

    -- Preview: hand-walk the parked victim further down the blades so a longer
    -- slide can be judged from a screenshot before it is written into do_impale.
    if EXTRA > 0 and slide_end_rel ~= nil and extra_done < EXTRA then
        local o = r32(A.p2_obj)
        if o ~= 0 then
            -- Walk him along the BLADE's axis, not diagonally: the blade is
            -- 29.6 degrees off vertical (dx/dy = 0.58, fitted from the exposed
            -- blade pixels and confirmed by UGSTAB6C's 42x70 art box).  Any
            -- other direction slides the blade sideways out of the red wound
            -- painted on his back, which is what the preview is here to judge.
            local y = s16(r16(o + O.oypos)) + 1
            extra_x_acc = extra_x_acc + BLADE_DXDY
            local x = extra_x0 - math.floor(extra_x_acc + 0.5)
            w16(o + O.oypos, y); w32(o + O.oyval, (y << 16) & 0xffffffff)
            w16(o + O.oxpos, x); w32(o + O.oxval, (x << 16) & 0xffffffff)
            extra_done = extra_done + 1
            if extra_done >= extra_next_snap then
                extra_next_snap = extra_next_snap + EXTRA_STEP
                log("EXTRA +%d px  y=%d x=%d", extra_done, y, x)
                snap(string.format("extra_%02d", extra_done))
            end
        end
    end

    if fatal_end_frame == 0 and fatal_num ~= nil and s16(r16(A.f_death)) ~= fatal_num then
        fatal_end_frame = frame
        log("death_blow_complete frame=%d rel=%d | %s", frame, rel, state_line("done"))
        snap("fatality_complete")
    end

    if fatal_end_frame == 0 and rel > HANG_LIMIT then finish(false, "fatality_hung_rel_" .. rel); return end

    if fatal_end_frame > 0 and frame - fatal_end_frame >= OBSERVE then
        finish(true, string.format("completed_in_%d_frames", fatal_end_frame - fatal_frame))
        return
    end

    if frame > 12000 then finish(false, "global_timeout"); return end
end

emu.register_frame(function()
    if finished then return end
    local ok, err = pcall(on_frame)
    if not ok then
        log("LUA ERROR frame=%d: %s", frame, tostring(err))
        finish(false, "harness_lua_error")
    end
end)
