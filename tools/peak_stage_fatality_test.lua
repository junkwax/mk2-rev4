-- peak_stage_fatality_test.lua
--
-- YOTEIGAI TOR's stage fatality: does the body actually reach the sea?
--
-- Unlike THE DEAD POOL's, this one is a real check_dtp fatality - Liu Kang's
-- Back,Forward,Forward + Low Kick inside 36 ticks at range 0x48 - and unlike
-- THE PIT II's it never cuts away.  r_fall_off_mountain (BGND.ASM) keeps the
-- stage up, hands the scroller to peak_fall_scroll and rides the camera 756
-- rows down mount1BMOD to the blood-red sea at its foot.
--
-- So there are four separate things that can be wrong and only one of them is
-- "did the fatality fire":
--
--   1. the victim never gets act_mtn_fall                     (trigger)
--   2. the camera does not reach peak_fall_cam_y, or overruns it, so the
--      module runs out of blocks and the autoerase colour shows      (camera)
--   3. the splash lands outside the water.  The sea is on PLANE 3 at a
--      quarter of the fighting plane's scroll rate, so this is the failure
--      that only shows up from some positions on the bridge          (aim)
--   4. the skull never rises, or never drifts                        (payoff)
--
-- One run = one trial.  Pin the victim at PK_VX with the attacker PK_GAP away
-- on side PK_SIDE, drive the combo, then let go and watch.
--
-- Env knobs:
--   PK_VX=N        victim's world x at the moment of the fatality (default 400)
--   PK_GAP=N       attacker's distance from the victim (default 55)
--   PK_SIDE=left|right   which side the ATTACKER stands on (default left, so
--                        P1 faces right and Forward is P1 Right)
--   PK_OBSERVE=N   frames to watch after the fall starts (default 320)
--   PK_TEST_LOG=path

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("PK_TEST_LOG") or (ROOT .. "/tools/peak_stage_fatality_test.log")
local VICTIM_X = getenv_int("PK_VX", 400)
local GAP = getenv_int("PK_GAP", 55)
local SIDE = (os.getenv("PK_SIDE") or "left"):lower()
local OBSERVE_FRAMES = getenv_int("PK_OBSERVE", 320)
local PK_BATTLE = tonumber(os.getenv("PK_BATTLE") or "")
local SNAP_A, SNAP_B, SNAP_S
do
    local v = os.getenv("PK_SNAP")
    if v then
        local a, b, c = v:match("^(%d+):(%d+):(%d+)$")
        if a then SNAP_A, SNAP_B, SNAP_S = tonumber(a), tonumber(b), tonumber(c) end
    end
end

-- How long to hold the pin before firing, so the scroller (about 2px a tick)
-- can reach the pinned position.  The arena is ~1000px wide, so a worst-case
-- teleport needs ~500 ticks; 540 covers it with slack.
local CAMERA_SETTLE = getenv_int("PK_SETTLE", 540)

-- The sea, straight out of the ROM's own equates so the rig cannot drift away
-- from what the ROM was built to aim at.  tools/peak_sea_band.py is what keeps
-- those equates honest against the art; this only keeps the rig honest against
-- them.
--
-- They live in PEAKFAT.ASM since the 2026-09-22 split (peak_ground_y went to
-- MAINEQU.ASM, because both objects need it and .set equates do not cross an
-- object boundary).  All three files are read, so the rig keeps working
-- wherever a given equate ends up.
local SEA_L, SEA_R, SEA_CX, SEA_Y, CAM_Y = 395, 792, 593, 1021, 789
do
    local sea_bot, scrbot = 1042, 253
    for _, name in ipairs({ "/src/PEAKFAT.ASM", "/src/MAINEQU.ASM", "/src/BGND.ASM" }) do
    local fh = io.open(ROOT .. name, "r")
    if fh then
        for line in fh:lines() do
            local n = line:match("^peak_sea_lft%s+%.equ%s+(%d+)")
            if n then SEA_L = tonumber(n) end
            n = line:match("^peak_sea_rgt%s+%.equ%s+(%d+)")
            if n then SEA_R = tonumber(n) end
            n = line:match("^peak_sea_cx%s+%.equ%s+(%d+)")
            if n then SEA_CX = tonumber(n) end
            n = line:match("^peak_sea_y%s+%.equ%s+(%d+)")
            if n then SEA_Y = tonumber(n) end
            n = line:match("^peak_art_bot%s+%.equ%s+(%d+)")
            if n then sea_bot = tonumber(n) end
        end
        fh:close()
    end
    end
    CAM_Y = sea_bot - scrbot
end

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
    print("[peakfat] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end return v end

local symbols = {}
do
    local fh = io.open(os.getenv("PK_MAP") or (ROOT .. "/src/mk2.map"), "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        log("WARN no linker map")
    end
end
local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s", name)
    return fallback or 0
end

local A = {
    gstate = sym("gstate"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"),
    worldtlx = sym("worldtlx"), worldtlx3 = sym("worldtlx3"),
    worldtly = sym("worldtly"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    -- The rising skull moved to its own display list so the sea draws over
    -- it.  Walk that too, or find_art() reports no_skull on a skull that is
    -- on screen - the rig would be measuring the list, not the game.
    skull_lst = sym("peak_skull_lst"),
    fill_lst = sym("peak_fill_lst"), front_lst = sym("peak_front_lst"),
    battle_num = sym("battle_num"), rain_lst = sym("peak_rain_lst"),
    dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
}

local O = { next = 0x000, oxvel = 0x040, oyvel = 0x060, oxval = 0x080, oxpos = 0x090,
            oyval = 0x0a0, oypos = 0x0b0, oflags = 0x0f0, osag = 0x100,
            oflags2 = 0x160, oimg = 0x1a0, oid = 0x1c0, ochar = 0x1f0 }
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KANG, FT_JAX = 1, 11
local STAGE_PEAK = 0x18
local ACT_MTN_FALL, ACT_STUNNED = 0x050c, 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm_start = 0, 0, 0
local finish_forced_frame, victim_dizzy_forced = 0, false
local attempt_start, attempt_n = 0, 0
local fall_start_frame = 0
local land_x, land_frame = nil, 0
-- PK_FALLTRACE=1: one line per TICK for the fall - the victim's screen x and
-- both velocities.  A 10-tick obs line cannot show a one-tick reversal, and the
-- horizontal SHAPE of the arc is the thing being judged here.  xv_turns counts
-- direction changes on the sign alone: one is correct (thrown out, steered back
-- towards the sea), more than one means something is fighting the steer.
local FALLTRACE = ((os.getenv("PK_FALLTRACE") or os.getenv("MP_FALLTRACE")) or "") ~= ""
-- PK_SKULLTRACE=1: the rising skull, per tick, against the WATERLINE.  It is
-- a single-part gso_dmawnz object, so oypos IS its drawn top and it draws down
-- osizey rows; both come out of its own image header, so no table of record
-- sizes is needed.  "how high above the lake" is only answerable in screen
-- rows, and the waterline is peak_sea_y - worldtly.
local SKULLTRACE = (os.getenv("PK_SKULLTRACE") or "") ~= ""
local xv_sign, xv_turns = 0, 0
local cam_y_max, cam_y_at_land = -32768, nil
local splash_x, splash_screen, skull_x, skull_frame = nil, nil, nil, 0
local skull_x_first, skull_x_last, skull_drift_frames = nil, nil, 0
local finished, snap_index = false, 0
local last_status = 0
local cross_frame = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

-- SAG -> label, for the splash (MKBGANI.TBL, shared with THE DEAD POOL) and
-- the rising skull (MTNSKUL.TBL, this stage's own sidecar).
local sag_labels = {}
do
    local function load_tbl(path, want)
        local fh = io.open(path, "r")
        if not fh then log("WARN no %s", path); return 0 end
        local current, n = nil, 0
        for line in fh:lines() do
            local label = line:match("^([%w_]+):")
            if label then
                current = want(label) and label or nil
            elseif current then
                local raw = line:match("%.long%s+0?(%x+)[hH]")
                if raw then
                    sag_labels[tonumber(raw, 16) & 0x00ffffff] = current
                    current = nil; n = n + 1
                end
            end
        end
        fh:close()
        return n
    end
    local a = load_tbl(ROOT .. "/src/MKBGANI.TBL",
                       function(l) return l:match("^acidsplash") ~= nil end)
    local b = load_tbl(ROOT .. "/src/MTNSKUL.TBL",
                       function(l) return l:match("^fleshup") ~= nil end)
    log("art SAGs loaded: %d splash, %d skull", a, b)
end

local function walk_objects(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3, A.skull_lst }) do
        local obj, guard, seen = r32(list), 0, {}
        while obj ~= 0 and guard < 400 do
            if seen[obj] then return "cycle" end
            seen[obj] = true
            fn(obj)
            obj = r32(obj + O.next)
            guard = guard + 1
        end
        if guard >= 400 then return "overflow" end
    end
    return nil
end

local function find_art()
    local out = {}
    walk_objects(function(obj)
        local label = sag_labels[r32(obj + O.osag) & 0x00ffffff]
        if label then
            out[#out + 1] = { label = label, obj = obj, x = r16(obj + O.oxpos),
                              y = s16(r16(obj + O.oypos)),
                              xvel = s32(r32(obj + O.oxvel)) }
        end
    end)
    return out
end

-- The sea lives on plane 3.  Convert it into the screen the player sees, which
-- is the only space it and the body share.
local function sea_screen()
    local w3 = s16(r16(A.worldtlx3 + 16))
    -- peak_dress_bottom fills mount1's bottom-left hole with water-and-rock
    -- copied 91px left (PEAKFAT.ASM peak_hole_w), so the sea now runs from
    -- SEA_L - 91 in plane-3 world.
    return SEA_L - 91 - w3, SEA_R - w3
end
local function body_screen_x(x)
    return x - s16(r16(A.worldtlx + 16))
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    if s then pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s", snap_index, frame, label)
    snap_index = snap_index + 1
end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Low Kick"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
    }
    local all = {}
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            all[#all + 1] = field.name
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    table.sort(all)
    log("ports: %s", table.concat(all, " | "))
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-16s MISSING", name); ok = false end
    end
    return ok
end

local function victim_obj() return r32(A.p2_obj) end
local function attacker_obj() return r32(A.p1_obj) end
local function p1_action()
    local p = r32(A.p1_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end
local function p2_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state_line(tag)
    local a, v = attacker_obj(), victim_obj()
    local ax = a ~= 0 and r16(a + O.oxpos) or -1
    local vx = v ~= 0 and r16(v + O.oxpos) or -1
    local vy = v ~= 0 and s16(r16(v + O.oypos)) or -1
    local vv = v ~= 0 and s32(r32(v + O.oxvel)) or 0
    local art = {}
    for _, e in ipairs(find_art()) do art[#art + 1] = e.label .. "@" .. e.x .. "," .. e.y end
    local sl, sr = sea_screen()
    return string.format(
        "%s gs=%d ws=%d fdeath=%d p1act=0x%04x p2act=0x%04x atk_x=%d vic_x=%d vic_y=%d "
        .. "vic_xvel=%d wtlx=%d wtlx3=%d wtly=%d sea_scr=%d..%d body_scr=%d art=[%s]",
        tag, r16(A.gstate), r16(A.winner_status), s16(r16(A.f_death)),
        p1_action(), p2_action(), ax, vx, vy, vv // 65536,
        s16(r16(A.worldtlx + 16)), s16(r16(A.worldtlx3 + 16)), s16(r16(A.worldtly + 16)),
        sl, sr, vx >= 0 and body_screen_x(vx) or -999, table.concat(art, ","))
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_pass" or "final_fail")
    log("RESULT %s reason=%s vx=%d side=%s gap=%d land_x=%s cam_y_max=%d cam_target=%d "
        .. "splash_scr=%s skull_x=%s skull_drift=%d fdeath=%d xturns=%d",
        ok and "PASS" or "FAIL", reason, VICTIM_X, SIDE, GAP,
        tostring(land_x), cam_y_max, CAM_Y, tostring(splash_screen),
        tostring(skull_x), skull_drift_frames, s16(r16(A.f_death)), xv_turns)
    log("%s", state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_PEAK)
    -- PK_BATTLE=n: the storm is a hash of battle_num and the pairing
    -- (peak_weather_roll); for Liu Kang v Jax, 3..8 come up WET.
    if PK_BATTLE and A.battle_num ~= 0 then w16(A.battle_num, PK_BATTLE) end
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
end

local function fighters_ok()
    local a, v = attacker_obj(), victim_obj()
    return a ~= 0 and v ~= 0 and r16(a + O.ochar) == FT_KANG and r16(v + O.ochar) == FT_JAX
end

local function force_finish_him()
    if fall_start_frame ~= 0 then return end
    if not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 2000 then return end
    w16(A.winner_status, 3)
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
        log("finish_him frame=%d | %s", frame, state_line("ff"))
        snap("finish_him")
    end
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

local function pin()
    local a, v = attacker_obj(), victim_obj()
    if a == 0 or v == 0 then return end
    local ax = SIDE == "left" and (VICTIM_X - GAP) or (VICTIM_X + GAP)
    w16(v + O.oxpos, VICTIM_X); w32(v + O.oxval, (VICTIM_X << 16) & 0xffffffff)
    w16(a + O.oxpos, ax);       w32(a + O.oxval, (ax << 16) & 0xffffffff)
end

-- One attempt at Liu Kang's stage fatality: Back, Forward, Forward + Low Kick
-- (scom_lk_dtp, a 36-tick window, dispatched from lk_lo_kick into check_dtp).
-- The whole motion is 26 ticks from the first Back to the button, which leaves
-- 10 ticks of slack in the window.
local ATTEMPT_LEN = 80
local BACK = SIDE == "left" and "P1 Left" or "P1 Right"
local FWD = SIDE == "left" and "P1 Right" or "P1 Left"
local function press_for(name, rel)
    if name == BACK then return rel >= 0 and rel < 5 end
    if name == FWD then return (rel >= 9 and rel < 14) or (rel >= 18 and rel < 23) end
    if name == "P1 Low Kick" then return rel >= 26 and rel < 32 end
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
    if attempt_start > 0 and fall_start_frame == 0 and fighting_frame > 0 then
        return press_for(name, (frame - attempt_start) % ATTEMPT_LEN)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("trial vx=%d side=%s gap=%d  sea(plane3)=%d..%d cx=%d y=%d cam_floor=%d",
            VICTIM_X, SIDE, GAP, SEA_L, SEA_R, SEA_CX, SEA_Y, CAM_Y)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fighting_frame = frame
            log("fight_start frame=%d | %s", frame, state_line("fs"))
        end
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0
        and frame > charsel_frame + 90 and r16(A.p1_char) == FT_KANG and r16(A.p2_char) == FT_JAX then
        p1_confirm_start = frame + 25
    end

    if fighting_frame > 0 and fall_start_frame == 0 then
        if r16(A.curback) ~= STAGE_PEAK then finish(false, "wrong_stage"); return end
        force_finish_him()
        -- Pin FIRST and let the camera travel to the pinned position before
        -- firing anything.  Without this the trial is not a position on the
        -- bridge at all: pin() teleports the fighters, the scroller only
        -- closes ~2px a tick, and a fatality fired 10 frames later happens
        -- with the body 400px off the camera - which cannot happen in play
        -- and makes the aim look far worse than it is.
        if finish_forced_frame > 0 then pin() end
        if attempt_start == 0 and finish_forced_frame > 0 and victim_ready()
            and frame >= finish_forced_frame + CAMERA_SETTLE then
            attempt_start = frame + 10
            log("victim_ready frame=%d attempts begin %d | %s", frame, attempt_start, state_line("vr"))
        end
        if attempt_start > 0 then
            if frame >= attempt_start and (frame - attempt_start) % ATTEMPT_LEN == 0 then
                attempt_n = attempt_n + 1
                log("attempt=%d frame=%d | %s", attempt_n, frame, state_line("try"))
                if attempt_n > 8 then finish(false, "fatality_never_fired"); return end
            end
        end
        if p2_action() == ACT_MTN_FALL then
            fall_start_frame = frame
            log("MTN_FALL frame=%d | %s", frame, state_line("fall"))
            snap("mtn_fall_start")
        end
    end

    if fall_start_frame > 0 then
        local rel = frame - fall_start_frame
        local wtly = s16(r16(A.worldtly + 16))
        local v = victim_obj()
        if wtly > cam_y_max then cam_y_max = wtly end

        -- The bridge crossing is the only place the display-list swap can be
        -- seen, and it is over in a handful of frames.  Snap every one of them.
        if v ~= 0 then
            local vy = s16(r16(v + O.oypos))
            if cross_frame == 0 and vy > 150 then     -- peak_behind_y
                cross_frame = frame
                log("DECK_CROSS frame=%d rel=%d vy=%d", frame, rel, vy)
            end
            if cross_frame > 0 and frame >= cross_frame - 4 and frame <= cross_frame + 20
                and (frame - cross_frame) % 3 == 0 then
                snap(string.format("cross_%+03d", frame - cross_frame))
            end
        end

        for _, e in ipairs(find_art()) do
            if splash_x == nil and e.label:match("^acidsplash") then
                splash_x = e.x
                splash_screen = body_screen_x(e.x)
                cam_y_at_land = wtly
                land_x = e.x
                land_frame = frame
                log("SPLASH frame=%d rel=%d %s@%d screen=%d | %s",
                    frame, rel, e.label, e.x, splash_screen, state_line("splash"))
                snap("splash")
            end
            if e.label:match("^fleshup") then
                if skull_x == nil then
                    skull_x = e.x
                    skull_x_first = e.x
                    skull_frame = frame
                    log("SKULL frame=%d rel=%d %s@%d,%d | %s",
                        frame, rel, e.label, e.x, e.y, state_line("skull"))
                    snap("skull")
                end
                skull_x_last = e.x
                if e.xvel ~= 0 then skull_drift_frames = skull_drift_frames + 1 end
            end
        end

        if SKULLTRACE then
            local camy = s16(r16(A.worldtly + 16))
            for _, e in ipairs(find_art()) do
                if e.label:match("^fleshup") then
                    local o = e.obj
                    local img = r32(o + O.oimg)
                    local h = img ~= 0 and s16(r16(img + 0x10)) or -1
                    log("SKULL rel=%03d %s top=%d(scr %d) h=%d bot_scr=%d "
                        .. "water_scr=%d above_water=%d xvel=%.3f",
                        rel, e.label, e.y, e.y - camy, h, e.y - camy + h,
                        SEA_Y - camy, (SEA_Y - camy) - (e.y - camy),
                        e.xvel / 65536.0)
                end
            end
        end
        if v ~= 0 and land_frame == 0 then
            local xv = s32(r32(v + O.oxvel))
            local sgn = (xv > 0 and 1) or (xv < 0 and -1) or 0
            if sgn ~= 0 then
                if xv_sign ~= 0 and sgn ~= xv_sign then xv_turns = xv_turns + 1 end
                xv_sign = sgn
            end
            if FALLTRACE and rel <= 160 then
                local a = attacker_obj()
                local w3 = s16(r16(A.worldtlx3 + 16))
                log("FTRACE rel=%03d scrx=%d oxpos=%d oxvel=%.3f oypos=%d oyvel=%.3f "
                    .. "atk=%d bounds=%d..%d",
                    rel, s16(r16(v + O.oxpos)) - s16(r16(A.worldtlx + 16)),
                    s16(r16(v + O.oxpos)), xv / 65536.0,
                    s16(r16(v + O.oypos)), s32(r32(v + O.oyvel)) / 65536.0,
                    a ~= 0 and s16(r16(a + O.oxpos)) or -1,
                    math.max(SEA_L - w3, 0) + 48,
                    math.min(SEA_R - w3, 399) - 48)
            end
        end
        -- The cloned blocks: peak_front_lst (rocks in front of the skull) and
        -- peak_fill_lst (mount1's bottom-left hole), in plane-3 world.
        if rel == 0 or rel == 60 or rel == 100 then
            local n, obj = 0, (A.rain_lst ~= 0 and r32(A.rain_lst) or 0)
            while obj ~= 0 and n < 200 do n = n + 1; obj = r32(obj + O.next) end
            log("RAIN rel=%03d drops=%d battle=%d", rel, n, A.battle_num ~= 0 and r16(A.battle_num) or -1)
        end
        if rel == 300 then
            for _, nm in ipairs({ "fill_lst", "front_lst" }) do
                local parts, obj, guard = {}, (A[nm] ~= 0 and r32(A[nm]) or 0), 0
                while obj ~= 0 and guard < 20 do
                    parts[#parts + 1] = string.format("%d,%d %dx%d", s16(r16(obj + O.oxpos)),
                        s16(r16(obj + O.oypos)), r16(obj + 0x120), r16(obj + 0x130))
                    obj = r32(obj + O.next); guard = guard + 1
                end
                log("LIST %s n=%d [%s] wtlx3=%d", nm, #parts, table.concat(parts, " "),
                    s16(r16(A.worldtlx3 + 16)))
            end
        end
        -- PK_SNAP=a:b:step - extra snapshots across one beat (the skull's bob)
        if SNAP_A and rel >= SNAP_A and rel <= SNAP_B and (rel - SNAP_A) % SNAP_S == 0 then
            snap(string.format("beat_%03d", rel))
        end
        if rel <= 24 or rel % 10 == 0 then
            log("obs rel=%03d | %s", rel, state_line("obs"))
            if rel % 40 == 0 then snap(string.format("obs_%03d", rel)) end
        end

        if rel >= OBSERVE_FRAMES then
            local bad = {}
            if splash_x == nil then bad[#bad + 1] = "no_splash" end
            if skull_x == nil then bad[#bad + 1] = "no_skull" end
            -- The body may change horizontal direction ONCE: thrown one way,
            -- and at most steered back.  More than that means something is
            -- fighting the fall - repell, or a throw aimed so badly that the
            -- catch has to haul it across the screen.  Reporting xturns
            -- without failing on it let exactly that ship: a throw flipped
            -- 208px into the opposite bound scored PASS with xturns=2.
            if xv_turns > 1 then
                bad[#bad + 1] = string.format("fall_reversed_%dx", xv_turns)
            end
            -- The camera has to land ON the clamp: short and the sea is off the
            -- bottom of the screen, past and the module is out of blocks.
            if cam_y_max ~= CAM_Y then
                bad[#bad + 1] = string.format("camera_stopped_at_%d_not_%d", cam_y_max, CAM_Y)
            end
            if splash_screen ~= nil then
                local sl, sr = sea_screen()
                if splash_screen < sl + 24 or splash_screen > sr - 24 then
                    bad[#bad + 1] = string.format("splash_screen_%d_outside_sea_%d..%d",
                                                  splash_screen, sl, sr)
                end
            end
            if skull_x_first ~= nil and skull_x_last == skull_x_first and skull_drift_frames == 0 then
                bad[#bad + 1] = "skull_never_drifted"
            end
            if s16(r16(A.f_death)) ~= -1 then bad[#bad + 1] = "f_death_not_minus1" end
            if #bad == 0 then finish(true, "landed_in_the_sea")
            else finish(false, table.concat(bad, "+")) end
            return
        end
    end

    if frame - last_status >= 180 then
        last_status = frame
        log("status | %s", state_line("status"))
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 9000 then finish(false, "never_reached_fight")
    elseif frame > 20000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)

-- PK_POOL=1: the object pool's free count every frame, for missing mountain
-- blocks (addblock skips a block when getobj fails).  Logs each new low and a
-- line every 25 frames once the fall's camera is below the deck.
if os.getenv("PK_POOL") == "1" then
    local OFREE, WTLY = sym("ofree"), sym("worldtly")
    local pool_min, pool_n = 9999, 0
    emu.register_frame(function()
        if not space then return end
        local n, p = 0, space:read_u32(OFREE)
        while p ~= 0 and n < 400 do n = n + 1; p = space:read_u32(p) end
        pool_n = pool_n + 1
        local cy = s16(space:read_u32(WTLY) >> 16)
        if n < pool_min then pool_min = n; log("POOL new_min=%d frame=%d cam_y=%d", n, frame, cy) end
        local dl = {}
        for _, k in ipairs({"dmaq_late","dmaq_lost","dmaq_over","qdma_drops"}) do dl[#dl+1] = k .. "=" .. space:read_u16(sym(k)) end
        local d = table.concat(dl, " ")
        if d ~= POOL_LASTD then POOL_LASTD = d; log("DMAQ %s frame=%d cam_y=%d", d, frame, cy) end
        if cy > 100 and pool_n % 25 == 0 then log("POOL free=%d frame=%d cam_y=%d", n, frame, cy) end
    end)
end
