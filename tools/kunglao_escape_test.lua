-- Runtime proof for Kung Lao's ESCAPE dive + roll - airborne Forward,Forward + LP.
--
-- HATHED12.IMG ships the move authored and never coded (sequence "X CAYP":
-- TMESCAPE1, TMESCAPE2, TMESCAPE3 held, then JFLIPSQ2 twice and JFLIP1).  The
-- wiring is do_hh_escape (MOVES.ASM) off hh_lo_punch's airborne branch: a dive
-- that stays stretched out until the belly meets the floor, then Mileena's
-- roll (act_kano) on his tuck frames, then do_backup.  What this rig proves:
--
--   1. it fires IN THE AIR from Forward,Forward + LP
--   2. TMESCAPE1 -> TMESCAPE2 -> TMESCAPE3 in that order
--   3. he goes DOWN into a floor roll: act_kano, tuck frames, travelling
--   4. he stands up and gets back to his stance - and how fast
--   5. the old input, airborne Forward,Forward + LK, no longer escapes
--   6. the ground Forward,Forward + LK is still the spin (act_hhspin)
--   7. CONTACT: a roll that runs into the opponent bowls him over - real
--      damage AND the victim goes up (r_kano), not a flinch
--   8. THE CORNER RULE (2026-10-10, hhesc_corner_ok in MKHHESC.ASM): every
--      escape trial starts with Kung Lao against the LEFT wall and back-flips
--      INTO it (or jumps straight up - 'upcorner').  Mid-screen, a back flip
--      and a forward jump must both be REFUSED: no TMESCAPE pose, and he lands
--      and gets back to his stance.  He must still dive AT Jax (forward).
--   9. CONTACT now takes the AIR FLIP PUNCH's reaction (strike routine 00c08h
--      = react_to_hh row 0ch, r_flipp): a real bar drop, the victim reacting,
--      and NOT launched the way r_kano used to throw him.
--
-- The field report does NOT prove the art is right: a stale SAG still reads
-- as the right frame NAME here.  Look at the snapshots.
--
-- Structure and boot schedule are lifted from tools/reptile_divekick_test.lua.
-- All offsets are TMS34010 BIT units; mk2.map values go in raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("KL_ESC_LOG") or (ROOT .. "/tools/kunglao_escape_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[klesc] " .. string.format(fmt, ...)
    raw_print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"), ground_y = sym("ground_y"),
    f_freeze_timer = sym("f_freeze_timer"), left_edge = sym("left_edge"),
}
local P_ACTION = 0x100 + 0xf0
local OIMG, MP_LEN, OXVAL, OXPOS, OYPOS = 0x1a0, 0x70, 0x80, 0x90, 0xb0
local OXVEL, OFLAGS, M_FLIPH = 0x40, 0xf0, 0x10
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_HATHEAD, FT_JAX, MAX_HP = 0, 11, 0x00a1
local ACT_STANCE, ACT_HHSPIN, ACT_KANO = 0x0303, 0x0108, 0x020e

-- SAG -> frame name, out of Kung Lao's own art table.
local sag_name, marker_count = {}, 0
do
    local fh = assert(io.open(ROOT .. "/src/MKHH.TBL", "r"), "missing src/MKHH.TBL")
    local label
    for line in fh:lines() do
        local l = line:match("^%s*(%u[%u%d_]*):")
        if l then label = l end
        local sag = label and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
        if sag then
            sag_name[tonumber(sag, 16) & 0x00ffffff] = label
            marker_count = marker_count + 1
            label = nil
        end
    end
    fh:close()
end

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local last_gstate = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local R = {}
local function res(k, v) R[k] = v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- field report ----")
    for _, k in ipairs({ "escape_fired", "fired_on_try", "height_at_fire",
                         "pose_runs", "order_ok", "air_ticks", "roll_ticks",
                         "roll_travel", "tumble_on_floor", "x_travel",
                         "back_to_stance_after", "old_air_lk_inert",
                         "spin_still_works", "arch_rise", "escape_phase_hit",
                         "back_jump_on_try", "back_jump_oxvel_before",
                         "back_dive_oxvel", "back_dive_facing", "back_dive_travel",
                         "contact_try", "contact_during", "contact_damage",
                         "contact_victim_rise", "contact_victim_act",
                         "corner_dive_dir", "up_corner_fired",
                         "mid_back_refused", "mid_fwd_refused" }) do
        log("  %-22s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Punch"]=true, ["P1 Low Kick"]=true,
        ["P1 Left"]=true, ["P1 Right"]=true, ["P1 Up"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

-- The POSE, not the piece: TMESCAPE3B -> TMESCAPE3, TMJUMPFLIP4A -> TMJUMPFLIP4.
local function body_pose()
    local obj = r32(A.p1_obj)
    if obj == 0 then return nil end
    local image = r32(obj + OIMG); if image == 0 then return nil end
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        local n = sag_name[sag]
        if n then return n:match("^(%u+%d+)") or n end
    end
    return nil
end
local function is_escape(pose) return pose and pose:sub(1, 8) == "TMESCAPE" end
local function is_tuck(pose) return pose and pose:sub(1, 10) == "TMJUMPFLIP" end

local function proc_action(sym_addr)
    local proc = sym_addr and r32(sym_addr) or 0
    if proc == 0 then return -1 end
    return r16(proc + P_ACTION)
end
local function p1_action() return proc_action(A.p1_proc) end
local function p2_action() return proc_action(A.p2_proc) end
local function p1_x() return s16(r16(r32(A.p1_obj) + OXPOS)) end
local function p1_y() return s16(r16(r32(A.p1_obj) + OYPOS)) end
local function p2_x() return s16(r16(r32(A.p2_obj) + OXPOS)) end
local function p2_y() return s16(r16(r32(A.p2_obj) + OYPOS)) end
local function height() return s16(r16(A.ground_y)) - p1_y() end
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end
local function p1_oxvel()
    local o = r32(A.p1_obj); if o == 0 then return 0 end
    return s32(r32(o + OXVEL))
end
-- fliph CLEAR = drawn facing right.
local function p1_faces_right()
    local o = r32(A.p1_obj); if o == 0 then return nil end
    return (r16(o + OFLAGS) & M_FLIPH) == 0
end

-- oxval is the master: an oxpos-only write is thrown away on the next draw.
local function place(sp)
    local o = r32(A.p1_obj)
    if o == 0 then return end
    local x = (p2_x() - sp) & 0xffff
    if space then space:write_u32(o + OXVAL, x << 16) end
    w16(o + OXPOS, x)
end

-- THE CORNER: Kung Lao 20px off the LEFT wall, Jax sp px in front of him.
-- Both are written, so the camera has both men in view.
local function place_corner(sp)
    local o, o2 = r32(A.p1_obj), r32(A.p2_obj)
    if o == 0 or o2 == 0 then return end
    local x1 = (s16(r16(A.left_edge)) + 20) & 0xffff
    local x2 = (x1 + sp) & 0xffff
    space:write_u32(o + OXVAL, x1 << 16); w16(o + OXPOS, x1)
    space:write_u32(o2 + OXVAL, x2 << 16); w16(o2 + OXPOS, x2)
end
-- MID-SCREEN: 300px off the wall, well outside hhesc_corner (080h).
local function place_mid(sp)
    local o, o2 = r32(A.p1_obj), r32(A.p2_obj)
    if o == 0 or o2 == 0 then return end
    local x1 = (s16(r16(A.left_edge)) + 300) & 0xffff
    local x2 = (x1 + sp) & 0xffff
    space:write_u32(o + OXVAL, x1 << 16); w16(o + OXPOS, x1)
    space:write_u32(o2 + OXVAL, x2 << 16); w16(o2 + OXPOS, x2)
end

-- When, after takeoff, the F,F+button goes in.
local DELAYS = { 3, 5, 1, 7, 3, 5, 1, 7 }
local MAX_TRIES, RETRY_AFTER = #DELAYS, 110
-- Contact: start far enough out that he comes DOWN short of Jax and the roll
-- has to carry into him.  Swept, because the drone moves.
local CONTACT_SP = { 260, 280, 240, 300, 260, 280, 240, 300 }

local phase, phase_try, phase_start = "wait", 0, 0
local ground_h, takeoff_at, motion_at = nil, nil, nil
local fired_at, runs, last_pose, x0 = nil, {}, nil, nil
local roll_at, roll_x0, roll_ticks, tuck_floor = nil, nil, 0, false
local landed_at, next_start = nil, nil
local c_try, c_rolled, c_hp0, c_y0, c_miny, c_hit, c_vact = 0, nil, nil, nil, nil, nil, nil
local c_fired, fire_h, arch_peak, esc_hp0 = nil, nil, nil, nil
local bj_try, bj_fired, bj_x0, bj_prevvel, bj_mode = 0, nil, nil, nil, nil

-- Up+Right is the forward flip.  Then Right, Right, <button> in the air -
-- "forward" is Right because he is placed left of Jax, facing him.
local function drive_jump(button, start, delay)
    local rel = frame - start
    if rel >= 0 and rel < 6 then held["P1 Up"] = true; held["P1 Right"] = true end
    if not takeoff_at and rel > 6 and (height() - ground_h) >= 0x10 then takeoff_at = frame end
    if takeoff_at and not motion_at and frame - takeoff_at >= delay then
        motion_at = frame
    end
    if motion_at then
        local m = frame - motion_at
        if m >= 0 and m < 3 then held["P1 Right"] = true end
        if m >= 5 and m < 8 then held["P1 Right"] = true end
        if m >= 9 and m < 14 then held[button] = true end
    end
end

-- The BACKWARD jump: Up+Left off a Kung Lao who is LEFT of Jax and facing
-- him, so he takes off AWAY.  Then Right, Right, LP in the air - "forward"
-- is still Right, because forward is where the other man is.
local function drive_jump_back(button, start, delay)
    local rel = frame - start
    if rel >= 0 and rel < 6 then held["P1 Up"] = true; held["P1 Left"] = true end
    if not takeoff_at and rel > 6 and (height() - ground_h) >= 0x10 then takeoff_at = frame end
    if takeoff_at and not motion_at and frame - takeoff_at >= delay then
        motion_at = frame
    end
    if motion_at then
        local m = frame - motion_at
        if m >= 0 and m < 3 then held["P1 Right"] = true end
        if m >= 5 and m < 8 then held["P1 Right"] = true end
        if m >= 9 and m < 14 then held[button] = true end
    end
end

-- Straight UP (Up alone), then Right, Right, LP in the air.
local function drive_jump_up(button, start, delay)
    local rel = frame - start
    if rel >= 0 and rel < 6 then held["P1 Up"] = true end
    if not takeoff_at and rel > 6 and (height() - ground_h) >= 0x10 then takeoff_at = frame end
    if takeoff_at and not motion_at and frame - takeoff_at >= delay then
        motion_at = frame
    end
    if motion_at then
        local m = frame - motion_at
        if m >= 0 and m < 3 then held["P1 Right"] = true end
        if m >= 5 and m < 8 then held["P1 Right"] = true end
        if m >= 9 and m < 14 then held[button] = true end
    end
end

local function begin_try(try)
    phase, phase_try, phase_start = "try", try, frame
    takeoff_at, motion_at = nil, nil
    place_corner(170)
    ground_h = height()
    log("--- CORNER back-flip try %d at frame %d  delay=%d  standing height=%d", try, frame,
        DELAYS[try], ground_h)
end

local function begin_contact(try)
    c_try, next_start = try, frame
    takeoff_at, motion_at = nil, nil
    c_rolled, c_hit, c_miny, c_vact, c_fired = nil, nil, nil, nil, nil
    place_corner(CONTACT_SP[try])
    ground_h = height()
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    c_hp0, c_y0 = MAX_HP, nil
    log("--- contact try %d  spacing=%d", try, CONTACT_SP[try])
end

local function tick()
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
        last_gstate = gs
        if fighting_frame > 0 and gs ~= GS_FIGHTING then
            finish(false, "left_fighting_state_mid_test")
            return
        end
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d ground_y=%d", r16(A.p1_char), r16(A.p2_char),
            s16(r16(A.ground_y)))
    end
    if fighting_frame == 0 then return end

    -- P1 always pinned.  P2 is only topped up when low, so the contact phase
    -- can read a real hit off his bar.
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end

    local pose = body_pose()
    local act = p1_action()

    if phase == "wait" then
        if frame - fighting_frame >= 150 then
            if r16(A.p1_char) ~= FT_HATHEAD then finish(false, "p1_wrong_character") return end
            begin_try(1)
        end
        return
    end

    if phase == "try" then
        if is_escape(pose) then
            fired_at, x0, phase = frame, p1_x(), "escape"
            fire_h, arch_peak, esc_hp0 = height() - ground_h, height() - ground_h, r16(A.p2_bar)
            res("escape_fired", true); res("fired_on_try", phase_try)
            res("height_at_fire", height() - ground_h)
            log("  ESCAPE fired on try %d  height above standing=%d  pose=%s act=%04x",
                phase_try, height() - ground_h, pose, act & 0xffff)
        elseif frame - phase_start >= RETRY_AFTER then
            if math.abs(height() - ground_h) <= 4 then
                log("  no escape on try %d (last pose %s)", phase_try, tostring(pose))
                if phase_try >= MAX_TRIES then
                    res("escape_fired", false)
                    finish(false, "escape_never_fired")
                    return
                end
                begin_try(phase_try + 1)
            end
            return
        else
            drive_jump_back("P1 Low Punch", phase_start, DELAYS[phase_try])
            return
        end
    end

    if phase == "escape" then
        local since = frame - fired_at
        if since % 2 == 0 and since <= 70 then snap(string.format("esc_%03d_%s", since, tostring(pose))) end
        if not landed_at and since <= 60 then
            log("    t%-3d %-12s act=%04x x=%4d h=%4d  jax x=%4d  gap=%4d",
                since, tostring(pose), act & 0xffff, p1_x(), height() - ground_h,
                p2_x(), p2_x() - p1_x())
        end
        if pose ~= last_pose then
            runs[#runs + 1] = { pose = tostring(pose), n = 1, h = height() - ground_h }
            last_pose = pose
        else
            runs[#runs].n = runs[#runs].n + 1
        end
        if not roll_at then
            local hh = height() - ground_h
            if hh > arch_peak then arch_peak = hh end
        end
        if not R.escape_phase_hit and r16(A.p2_bar) < esc_hp0 then
            R.escape_phase_hit = string.format("%s at t%d, -%d",
                act == ACT_KANO and "roll" or "dive", since, esc_hp0 - r16(A.p2_bar))
        end
        if act == ACT_KANO then
            if not roll_at then roll_at, roll_x0 = frame, p1_x() end
            roll_ticks = roll_ticks + 1
            -- on the floor means the anchor is BELOW his standing line
            if is_tuck(pose) and (height() - ground_h) < -20 then tuck_floor = true end
        end
        if not landed_at and roll_at and act ~= ACT_KANO then
            landed_at = frame
            res("roll_travel", math.abs(p1_x() - roll_x0))
            log("  roll ended at since=%d  roll travel=%d  total x travel=%d",
                since, R.roll_travel, math.abs(p1_x() - x0))
        end
        if landed_at and act == ACT_STANCE then
            local parts, order = {}, {}
            for _, r in ipairs(runs) do
                parts[#parts + 1] = string.format("%s x%d (h%d)", r.pose, r.n, r.h)
                if r.pose:sub(1, 8) == "TMESCAPE" then order[#order + 1] = r.pose end
            end
            local order_ok = table.concat(order, ",") == "TMESCAPE1,TMESCAPE2,TMESCAPE3,TMESCAPE2,TMESCAPE1"  -- dive, then the tuck-in (hhesc_tuck)
            res("pose_runs", table.concat(parts, " | "))
            res("order_ok", order_ok)
            res("air_ticks", roll_at - fired_at)
            res("arch_rise", arch_peak - fire_h)
            if not R.escape_phase_hit then res("escape_phase_hit", "none") end
            res("roll_ticks", roll_ticks)
            res("tumble_on_floor", tuck_floor)
            res("x_travel", math.abs(p1_x() - x0))
            res("corner_dive_dir", (p1_x() - x0) > 0 and "out of the corner, at him" or "BACKWARDS")
            if (p1_x() - x0) <= 0 then finish(false, "corner_escape_went_backwards") return end
            res("back_to_stance_after", frame - fired_at)
            snap("escape_done")
            if not (order_ok and roll_ticks >= 6 and tuck_floor and (R.roll_travel or 0) > 40) then
                finish(false, "escape_shape_wrong")
                return
            end
            phase, next_start = "airlk", frame + 30
            takeoff_at, motion_at = nil, nil
            return
        end
        if since > 240 then finish(false, "never_got_back_to_stance") return end
        return
    end

    -- The OLD input: airborne Forward,Forward + LK must not escape any more.
    if phase == "airlk" then
        local rel = frame - next_start
        if rel < 0 then return end
        if rel == 0 then place_corner(170); ground_h = height() end
        drive_jump_back("P1 Low Kick", next_start, 3)
        if is_escape(pose) then
            res("old_air_lk_inert", "NO - air F,F+LK still escapes")
            finish(false, "old_input_still_fires")
            return
        end
        if rel > 30 and math.abs(height() - ground_h) <= 4 and act == ACT_STANCE then
            res("old_air_lk_inert", motion_at and true or "no jump - inconclusive")
            phase, next_start = "spin", frame + 30
        elseif rel > 240 then
            finish(false, "air_lk_phase_never_settled")
        end
        return
    end

    -- Negative control: the ground Forward,Forward + LK must still be the spin.
    if phase == "spin" then
        local rel = frame - next_start
        if rel < 0 then return end
        if rel == 0 then place(170) end
        if rel >= 2 and rel < 5 then held["P1 Right"] = true end
        if rel >= 7 and rel < 10 then held["P1 Right"] = true end
        if rel >= 11 and rel < 16 then held["P1 Low Kick"] = true end
        if act == ACT_HHSPIN then
            res("spin_still_works", true)
            snap("ground_spin")
            phase, next_start = "backjump_wait", frame + 90
            return
        end
        if is_escape(pose) then
            res("spin_still_works", "NO - ground input gave the escape")
            finish(false, "ground_input_fired_escape")
            return
        end
        if rel > 90 then
            res("spin_still_works", false)
            finish(false, "ground_spin_did_not_fire")
        end
        return
    end

    -- CORNER, STRAIGHT UP: Up alone against the wall, then Forward,Forward+LP.
    -- Must fire (the rule's second half).  Retried over DELAYS like the main try.
    if phase == "backjump_wait" then
        if frame >= next_start and act == ACT_STANCE then
            bj_try = 1
            takeoff_at, motion_at, bj_fired = nil, nil, nil
            place_corner(170); ground_h = height()
            phase, next_start = "upcorner", frame
            log("--- CORNER straight-up try %d  delay=%d", bj_try, DELAYS[bj_try])
        end
        return
    end

    if phase == "upcorner" then
        local rel = frame - next_start
        if is_escape(pose) and not bj_fired then
            bj_fired = frame
            res("up_corner_fired", string.format("try %d", bj_try))
            log("  UP-CORNER escape fired  x=%d jax=%d", p1_x(), p2_x())
            snap("upcorner_fired")
        end
        if bj_fired then
            if frame - bj_fired > 30 and act == ACT_STANCE then
                phase, next_start = "mid_wait", frame + 30
                bj_mode = "back"
            elseif frame - bj_fired > 240 then
                finish(false, "upcorner_never_got_back_to_stance")
            end
            return
        end
        drive_jump_up("P1 Low Punch", next_start, DELAYS[bj_try])
        if rel > RETRY_AFTER and math.abs(height() - ground_h) <= 4 and act == ACT_STANCE then
            log("  no escape on straight-up try %d", bj_try)
            if bj_try >= MAX_TRIES then
                res("up_corner_fired", false)
                finish(false, "upcorner_escape_never_fired")
                return
            end
            bj_try = bj_try + 1
            takeoff_at, motion_at = nil, nil
            place_corner(170); ground_h = height()
            next_start = frame
        end
        return
    end

    -- MID-SCREEN, both must be REFUSED: a back flip, then a forward jump, 300px
    -- off the wall.  Each must land and reach his stance with no TMESCAPE pose -
    -- the refusal finishes the flip he was in (hhesc_refused).  A trial whose
    -- motion never went in is no verdict.
    if phase == "mid_wait" then
        if frame >= next_start and act == ACT_STANCE then
            takeoff_at, motion_at = nil, nil
            place_mid(170); ground_h = height()
            phase, next_start = "mid", frame
            log("--- MID-SCREEN %s jump (must be refused)", bj_mode)
            bj_try = 0
        end
        return
    end

    if phase == "mid" then
        local rel = frame - next_start
        if bj_mode == "back" then drive_jump_back("P1 Low Punch", next_start, 3)
        else drive_jump("P1 Low Punch", next_start, 3) end
        local key = bj_mode == "back" and "mid_back_refused" or "mid_fwd_refused"
        if is_escape(pose) then
            res(key, "NO - fired mid-screen")
            snap("mid_" .. bj_mode .. "_fired")
            finish(false, "escape_fired_outside_the_corner_" .. bj_mode)
            return
        end
        if not takeoff_at and rel > 90 then
            -- the jump never left the ground: re-place and go again
            bj_try = (bj_try or 0) + 1
            if bj_try > 4 then finish(false, "mid_" .. bj_mode .. "_never_took_off") return end
            log("  mid %s: no takeoff by +90 (act=%04x) - retry", bj_mode, act & 0xffff)
            place_mid(170); ground_h = height(); next_start = frame
            return
        end
        if takeoff_at and frame - takeoff_at > 20 and math.abs(height() - ground_h) <= 4
           and act == ACT_STANCE then
            if not motion_at then
                res(key, "no motion went in - no verdict")
                finish(false, "mid_" .. bj_mode .. "_motion_never_went_in")
                return
            end
            res(key, true)
            snap("mid_" .. bj_mode .. "_landed")
            if bj_mode == "back" then
                bj_mode = "fwd"
                phase, next_start = "mid_wait", frame + 30
            else
                phase, next_start = "contact_wait", frame + 90
            end
        elseif rel > 300 then
            finish(false, "mid_" .. bj_mode .. "_never_landed")
        end
        return
    end

    if phase == "contact_wait" then
        if frame >= next_start and act == ACT_STANCE then
            phase = "contact"
            begin_contact(1)
        end
        return
    end

    -- CONTACT out of the corner: damage off his bar, and the AIR FLIP PUNCH's
    -- reaction (r_flipp) - he reacts where he stands, NOT launched the way the
    -- old r_kano threw him.  The rise is what tells the two apart.
    if phase == "contact" then
        local rel = frame - next_start
        drive_jump_back("P1 Low Punch", next_start, 3)
        local hp = r16(A.p2_bar)
        if is_escape(pose) and not c_fired then
            c_fired = frame
            c_y0 = p2_y()
        end
        if act == ACT_KANO and not c_rolled then
            c_rolled = frame
            log("    rolling at x=%d  jax x=%d  gap=%d", p1_x(), p2_x(), p2_x() - p1_x())
        end
        if (c_fired or c_rolled) and not c_hit and hp < c_hp0 then
            c_hit, c_vact = frame, p2_action()
            res("contact_during", c_rolled and "roll" or "dive")
            log("    CONTACT: jax hp %d -> %d  act=%04x  y=%d", c_hp0, hp, c_vact & 0xffff, p2_y())
            snap("contact_hit")
            res("contact_try", c_try)
            res("contact_damage", c_hp0 - hp)
            res("contact_victim_act", string.format("%04x", c_vact & 0xffff))
        end
        if c_hit then
            local vy = p2_y()
            c_miny = (c_miny and math.min(c_miny, vy)) or vy
            if frame - c_hit <= 8 and p2_action() == 0x0503 then c_vact = 0x0503 end
            if frame - c_hit == 8 then snap("contact_+8") end
            if frame - c_hit >= 40 then
                local rise = (c_y0 or vy) - c_miny
                res("contact_victim_rise", rise)
                res("contact_victim_act", string.format("%04x", c_vact & 0xffff))
                if c_vact ~= 0x0503 then
                    finish(false, "hit_but_victim_not_reacting")
                elseif rise >= 20 then
                    finish(false, "victim_launched_like_r_kano_not_the_flip_punch")
                else
                    finish(true, "corner_escape_fires_refused_midscreen_flip_punch_hit")
                end
            end
            return
        end
        if rel > 200 and (act == ACT_STANCE or rel > 320) then
            log("  contact try %d: no hit (rolled=%s)", c_try, tostring(c_rolled ~= nil))
            if c_try >= #CONTACT_SP then
                res("contact_try", "none connected")
                finish(false, "roll_never_connected")
                return
            end
            begin_contact(c_try + 1)
        end
        return
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("%d art markers from MKHH.TBL", marker_count)
        for k, v in pairs(A) do
            if not v then log("MISSING SYMBOL %s", k) end
        end
    end
    if not space or finished then return end

    held = {}
    tick()
    if finished then return end

    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if confirm_frame > 0 and fighting_frame == 0
       and frame >= confirm_frame and frame < confirm_frame + 45 then
        held["P1 High Punch"] = true
    end

    for name, f in pairs(fields) do f:set_value(held[name] and 1 or 0) end

    if frame > 32000 then finish(false, "global_timeout") end
end)
