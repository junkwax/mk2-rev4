-- Runtime proof for Reptile's dive kick - airborne Up,Down + HK.
--
-- The move is do_reptile_superk, which the retail source names after him and
-- then only ever hands to Kung Lao (hh_hi_kick).  rp_hi_kick now reads the same
-- scom_super_rep, so this rig has to answer two things a damage counter cannot:
--
--   1. it is THE DIVE and not an ordinary air kick - p_action must read
--      act_reptile_fly (020dh), which no normal jump attack ever sets
--   2. it swings the RIGHT BOX - super_reptile_scan used to read strike 012h
--      unconditionally, which is stk_super_rep in hh_strikes but stk_slide in
--      nj_strikes.  The two are told apart by what the victim does:
--        stk_slide      routine 12h -> r_slide, 22 damage, victim stays down
--        stk_rp_superk  routine 0bh -> r_flipk, 26 damage, victim goes 8px/tick
--                       STRAIGHT UP
--      So the launch height is the real assertion here, not the hit.
--
-- MK2_DIVE_CHAR=kunglao runs the same measurement on Kung Lao, whose path
-- through the shared scan changed too - that is the regression half.
--
-- MK2_DIVE_CHAR=noob is the third man on it (noobdive, MAINEQU.ASM): the same
-- input, the same gate, the same routine, and he reads nj_strikes like Reptile
-- so it is the SAME half of super_reptile_scan - which is why the launch
-- height is still the assertion.  He has no grid portrait and cannot be forced
-- into a fight by writing p1_char at select, so the rig confirms SCORPION and
-- swaps the slot during post-select, the way tools/noob_divekick_test.lua does.
-- No afterimage is expected: superk_afterimage is gated on ft_reptile.
--
-- Structure and boot schedule are lifted from tools/noob_divekick_test.lua.
-- All offsets are TMS34010 BIT units; mk2.map values go in raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("REP_DIVE_LOG") or (ROOT .. "/tools/reptile_divekick_test.log")
local WHO = (os.getenv("MK2_DIVE_CHAR") or "reptile"):lower()
-- MK2_DIVE_SOAK=N: keep casting after a good one.  The afterimage is a gmo
-- object, and a gmo object that is not released is this project's most
-- repeated bug - the pool runs dry and every OTHER effect quietly stops.
-- superk_afterimage skips silently when getprc fails, so a leak does not
-- crash: it shows up as afterimage_seen going false on the later casts.
local SOAK = tonumber(os.getenv("MK2_DIVE_SOAK") or "0") or 0
-- MK2_DIVE_INVISO=1: he dives while INVISIBLE, and the dive has to bring him
-- back (do_reptile_superk -> clear_inviso).  The rig sets the bit the way
-- set_inviso does (m_inviso on, m_shadow off) at the top of every try rather
-- than casting Up,Up,Down+HP: the clear is what is under test, not the cast,
-- and tools/run_reptile_uninviso_test.ps1 already drives the real cast.
-- Also asserts NO afterimage - superk_afterimage runs before the clear and
-- still skips itself for an invisible man.
local INVISO = os.getenv("MK2_DIVE_INVISO") == "1"
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[rdive] " .. string.format(fmt, ...)
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
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    ground_y = sym("ground_y"),
    f_freeze_timer = sym("f_freeze_timer"), objlst = sym("objlst"),
    -- The ghost ring (MKDISP.ASM).  gh_src is the object being trailed, 0 =
    -- off; gh_snaps is the sentinel count of snapshots taken; gh_n the number
    -- of ghosts.  All three are .global.
    gh_src = sym("gh_src"), gh_snaps = sym("gh_snaps"), gh_n = sym("gh_n"),
}
local P_ACTION = 0x100 + 0xf0
local OIMG, MP_LEN, ONEXT, OXVAL, OXPOS, OYPOS = 0x1a0, 0x70, 0x00, 0x80, 0x90, 0xb0
local OFLAGS2, M_SHADOW, M_INVISO = 0x160, 0x0010, 0x0020
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_HATHEAD, FT_REPTILE, FT_JAX, MAX_HP = 0, 9, 11, 0x00a1
local FT_SCORPION, FT_NOOB = 10, 15

local ACT_REPTILE_FLY = 0x020d       -- MAINEQU.ASM: the flying kick's action
local HEIGHT_GATE = 0xa0             -- distance_from_ground gate in the handler

local P1_CHAR = (WHO == "kunglao") and FT_HATHEAD
               or (WHO == "noob") and FT_NOOB or FT_REPTILE
-- Who to CONFIRM on the grid.  Noob is a secret fighter: a select forced to
-- ft_noob never confirms (the fight is simply never reached), so he is picked
-- up after it instead.
local SEL_CHAR = (WHO == "noob") and FT_SCORPION or P1_CHAR
-- Who superk_afterimage leaves a copy behind for (MKPROP.ASM).  REPTILE and
-- NOOB do; Kung Lao does not, and that is the discrimination - an assertion
-- that only ever demanded an afterimage would pass on a gate that had been
-- widened to everybody, which is the likely regression here.
-- ...and in INVISO mode nobody leaves one: superk_afterimage runs ahead of
-- the clear and skips itself for an invisible man, which that mode already
-- asserts on its own.
-- WHICH shadow to expect, READ OUT OF THE SWITCH rather than written in here.
-- Noob has two possible ones (noobdive_ghost, MAINEQU.ASM): the parked decoy
-- Reptile leaves, or the teleport slam's ghost trail, which is not an object
-- at all so find_afterimage cannot see it.  Hardcoding either would make this
-- rig fail honestly on a correct build the day the switch moves, which is the
-- kind of failure that gets a rig ignored.  Kung Lao gets neither, ever.
local NOOB_GHOST = false
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local v = line:match("^noobdive_ghost%s+%.set%s+(%d)")
            if v then NOOB_GHOST = (v ~= "0") end
        end
        fh:close()
    end
end
-- The two are EXCLUSIVE for every character, which is what catches both a gate
-- widened to everybody and a build that armed BOTH shadows for Noob.
local WANT_AFTERIMAGE = (WHO == "reptile" or (WHO == "noob" and not NOOB_GHOST))
                        and not INVISO
local WANT_GHOSTS = (WHO == "noob") and NOOB_GHOST
-- Frame prefix the KICKING body should be wearing.  Both men ride anitab1 01eh,
-- the flip kick: NJFLIPKICK* for the ninjas, TMFLIPKICK* for Kung Lao.
local KICK_PREFIX = (WHO == "kunglao") and "TMFLIPKICK" or "NJFLIPKICK"
local ART_TBL = (WHO == "kunglao") and "MKHH.TBL" or "MKNJ.TBL"

-- SAG -> frame name, read out of the character's own art table.
local sag_name, marker_count = {}, 0
do
    local fh = assert(io.open(ROOT .. "/src/" .. ART_TBL, "r"), "missing src/" .. ART_TBL)
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
local soak_done, soak_log = 0, {}
local function res(k, v) R[k] = v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- field report (%s) ----", WHO)
    for _, k in ipairs({ "dive_fired", "dive_height_at_fire", "dive_spacing",
                         "dive_body_pose", "dive_body_is_flipkick",
                         "dive_step_dx", "dive_dy_first_last", "dive_accelerating",
                         "dive_landed", "dive_damage", "dive_hit",
                         "dive_victim_rise", "dive_flipkick_reaction",
                         "inviso_before_cast", "inviso_after_cast", "inviso_no_afterimage",
                         "victim_peak_y", "victim_came_back_down",
                         "afterimage_seen", "afterimage_ticks",
                         "afterimage_expected", "afterimage_as_expected",
                         "ghosts_expected", "ghosts_armed_ticks",
                         "ghosts_were_mine", "ghosts_n", "ghosts_snapped",
                         "ghosts_as_expected",
                         "afterimage_drift_px", "afterimage_gone_at",
                         "afterimage_he_left_it",
                         "soak_casts", "soak_all_had_afterimage" }) do
        log("  %-22s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 High Kick"]=true,
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

local function obj_frame(obj)
    if obj == 0 then return nil end
    local image = r32(obj + OIMG); if image == 0 then return nil end
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        if sag_name[sag] then return sag_name[sag] end
    end
    return nil
end

-- The AFTERIMAGE: a third object, neither fighter, wearing the kick pose.
-- superk_afterimage parks it at the launch point while the real man flies out
-- of it, so "it exists" is not the test - "it stayed put while he left" is.
local function find_afterimage()
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frame(obj)
            if n and n:sub(1, #KICK_PREFIX) == KICK_PREFIX then
                return n, s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS))
            end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return nil
end

local function p1_action()
    local proc = A.p1_proc and r32(A.p1_proc) or 0
    if proc == 0 then return -1 end
    return r16(proc + P_ACTION)
end

local function p2_action()
    local proc = A.p2_proc and r32(A.p2_proc) or 0
    if proc == 0 then return -1 end
    return r16(proc + P_ACTION)
end

local function p1_y() return s16(r16(r32(A.p1_obj) + OYPOS)) end
local function p1_x() return s16(r16(r32(A.p1_obj) + OXPOS)) end
local function p2_y() return s16(r16(r32(A.p2_obj) + OYPOS)) end
local function height() return s16(r16(A.ground_y)) - p1_y() end
local function p1_inviso() return (r16(r32(A.p1_obj) + OFLAGS2) & M_INVISO) ~= 0 end
local inviso_before_cast, inviso_after_cast = nil, nil

-- The dive has to be thrown from far enough out that the descent still has
-- somewhere to go, and the press has to land near the apex for the height gate.
-- Sweep both rather than guessing either.
local DELAYS   = { 6, 2, 10, 6, 2, 10, 0, 8, 4, 12, 6, 2, 10, 6, 2 }
local SPACINGS = { 110, 130, 90, 150, 110, 130, 90, 150, 170, 110, 130, 90, 150, 170, 110 }
local MAX_TRIES, RETRY_AFTER = 15, 140

local phase_try, phase_start = 0, 0
local takeoff_at, motion_at, ground_h = nil, nil, nil
local fired_at, peak_height, height_at_hk = nil, 0, nil
local vic_hp0, vic_hp_min = nil, nil
local body_pose = nil
local lx, ly, step_dx, first_dy, max_dy = nil, nil, nil, nil, nil
local victim_y_prehit, victim_min_y, hit_at, victim_fell_back = nil, nil, nil, nil
local ai_name, ai_x0, ai_drift, ai_seen_ticks, ai_gone_at, ai_launch_x = nil, nil, 0, 0, nil, nil
local gh_armed_ticks, gh_mine_ticks, gh_n_seen = 0, 0, 0
local gh_snaps0, gh_snaps_last = nil, nil

-- oxval is the master: the display recomputes oxpos from it every pass, so an
-- oxpos-only write is thrown away before the next draw and the spacing sweep
-- would silently be measuring wherever the fight happened to drift.
local function place(sp)
    local o = r32(A.p1_obj)
    if o == 0 then return end
    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
    local x = (jx - sp) & 0xffff
    if space then space:write_u32(o + OXVAL, x << 16) end
    w16(o + OXPOS, x)
end

local function begin_try(try)
    phase_try, phase_start = try, frame
    takeoff_at, motion_at, fired_at, height_at_hk, peak_height = nil, nil, nil, nil, 0
    body_pose = nil
    lx, ly, step_dx, first_dy, max_dy = nil, nil, nil, nil, nil
    victim_y_prehit, victim_min_y, hit_at, victim_fell_back = nil, nil, nil, nil
    ai_name, ai_x0, ai_drift, ai_seen_ticks, ai_gone_at, ai_launch_x = nil, nil, 0, 0, nil, nil
    gh_armed_ticks, gh_mine_ticks, gh_n_seen = 0, 0, 0
    gh_snaps0, gh_snaps_last = nil, nil
    place(SPACINGS[try] or 110)
    inviso_before_cast, inviso_after_cast = nil, nil
    if INVISO then
        local o = r32(A.p1_obj)
        w16(o + OFLAGS2, (r16(o + OFLAGS2) | M_INVISO) & ~M_SHADOW)
    end
    -- Standing is not zero: oypos is head-anchored, so feet-on-floor already
    -- reads ~120 against @ground_y.  Takeoff is judged against that baseline.
    ground_h = height()
    vic_hp0 = r16(A.p2_bar); vic_hp_min = vic_hp0
    log("--- try %d at frame %d  spacing=%d standing height=%d victim hp=%d",
        try, frame, SPACINGS[try] or 110, ground_h, vic_hp0)
end

-- Up (the jump itself is the Up half of scom_super_rep), then Down, then HK.
-- The motion does NOT start on a fixed frame: it waits for him to actually
-- leave the ground, because boot timing and the drone both drift.
local function drive()
    local rel = frame - phase_start
    if rel >= 0 and rel < 5 then held["P1 Up"] = true end
    if not takeoff_at and rel > 5 and (height() - ground_h) >= 0x20 then
        takeoff_at = frame
    end
    if takeoff_at and not motion_at and frame - takeoff_at >= (DELAYS[phase_try] or 6) then
        motion_at = frame
    end
    if motion_at then
        local m = frame - motion_at
        if m >= 0 and m < 4 then held["P1 Down"] = true end
        if m >= 6 and m < 12 then
            held["P1 High Kick"] = true
            if not height_at_hk then height_at_hk = height() end
        end
    end
end

local function tick()
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
        last_gstate = gs
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, SEL_CHAR); w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, P1_CHAR); w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d ground_y=%d", r16(A.p1_char), r16(A.p2_char),
            s16(r16(A.ground_y)))
    end

    if fighting_frame == 0 then return end

    -- Pinning the bars stops a KO but not a TIME OVER, and a 15-try sweep runs
    -- well past 40 seconds of round clock.  Without this the stage tears down
    -- mid-sweep and every later reading belongs to another state.
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end

    if phase_try == 0 then
        if frame - fighting_frame >= 150 then
            if r16(A.p1_char) ~= P1_CHAR then finish(false, "p1_wrong_character") return end
            begin_try(1)
        end
        return
    end

    local act = p1_action()
    local h = height()
    if h > peak_height then peak_height = h end
    local hp = r16(A.p2_bar)
    if hp < vic_hp_min then vic_hp_min = hp end

    if not fired_at then
        -- act_reptile_fly is the whole point: a plain air kick never sets it,
        -- so this separates the dive from the jump kick the same press gives
        -- when the Up,Down is not in the queue.
        if act == ACT_REPTILE_FLY then
            fired_at = frame
            inviso_after_cast = p1_inviso()
            res("dive_fired", true)
            res("dive_height_at_fire", h)
            log("  DIVE cast on try %d  height=%d (gate %d, at HK press %s, peak %d)",
                phase_try, h, HEIGHT_GATE, tostring(height_at_hk), peak_height)
            snap("dive_cast")
            return
        end
        if frame - phase_start >= RETRY_AFTER then
            log("  no airborne cast after %d frames (peak height %d, at HK %s)",
                RETRY_AFTER, peak_height, tostring(height_at_hk))
            if phase_try >= MAX_TRIES then
                res("dive_fired", false)
                finish(false, "dive_never_fired")
                return
            end
            begin_try(phase_try + 1)
            return
        end
        -- The drone can knock him out of it before the cast (every reaction
        -- clears m_inviso); that try then proves nothing, so re-arm.
        if INVISO and not p1_inviso() then
            local o = r32(A.p1_obj)
            w16(o + OFLAGS2, (r16(o + OFLAGS2) | M_INVISO) & ~M_SHADOW)
        end
        inviso_before_cast = p1_inviso()
        drive()
        return
    end

    local since = frame - fired_at

    -- The KICK belongs to his own body here (unlike Noob's, which is thrown):
    -- anitab1 01eh, the flip kick.
    local body = obj_frame(r32(A.p1_obj))
    if body and (body:sub(1, #KICK_PREFIX) == KICK_PREFIX or not body_pose) then
        body_pose = body
    end

    -- Trajectory: forward step should hold near do_reptile_superk's 8px/tick
    -- while the descent GROWS - that growth is ograv 04000h being integrated,
    -- and it is the honest signature of the arc.
    local x, y = p1_x(), p1_y()
    if lx then
        local dx, dy = math.abs(x - lx), y - ly
        if dx > 0 then step_dx = math.max(step_dx or 0, dx) end
        if dy > 0 then
            first_dy = first_dy or dy
            max_dy = (max_dy and math.max(max_dy, dy)) or dy
        end
    end
    lx, ly = x, y

    local an, ax = find_afterimage()
    if an then
        ai_name = an
        if not ai_x0 then ai_x0, ai_launch_x = ax, p1_x() end
        local d = math.abs(ax - ai_x0)
        if d > ai_drift then ai_drift = d end
        ai_seen_ticks = ai_seen_ticks + 1
    elseif ai_name and not ai_gone_at then
        ai_gone_at = since
    end

    -- The ghost ring, sampled every tick of the dive.  Two readings, because
    -- either on its own is weak: gh_src must be THIS fighter (armed for him,
    -- not left over from the other man's move) and gh_snaps must ADVANCE,
    -- which is the only thing that says frames were really blitted rather
    -- than a setup sitting there with nothing drawing it.
    if A.gh_src and A.gh_snaps then
        local src = r32(A.gh_src)
        if src ~= 0 then
            gh_armed_ticks = gh_armed_ticks + 1
            if src == A.p1_obj then gh_mine_ticks = gh_mine_ticks + 1 end
            gh_n_seen = math.max(gh_n_seen, r16(A.gh_n))
        end
        local sn = r16(A.gh_snaps)
        if gh_snaps0 == nil then gh_snaps0 = sn end
        gh_snaps_last = sn
    end

    if since == 3 or since == 5 or since == 10 then snap("dive_mid") end

    -- Victim trace.  The reaction routine is not readable from RAM, so what it
    -- DID is the evidence: r_flipk puts him into `flight` (up, then all the way
    -- to the floor, then a getup) while a non-knockdown reaction leaves him on
    -- his feet.  Log action + y every other frame from the moment HP drops.
    if hp < vic_hp0 then
        if not hit_at then
            hit_at = frame
            log("  HIT at since=%d  victim act=%04x y=%d (ground_y=%d)",
                since, p2_action() & 0xffff, p2_y(), s16(r16(A.ground_y)))
        end
        local sh = frame - hit_at
        if sh % 3 == 0 and sh <= 66 then
            log("    +%-3d victim act=%04x y=%d", sh, p2_action() & 0xffff, p2_y())
        end
        if sh == 6 or sh == 20 or sh == 38 or sh == 60 then snap("victim_+" .. sh) end
        local vy = p2_y()
        if victim_y_prehit and victim_min_y
           and (victim_y_prehit - victim_min_y) >= 30
           and vy >= victim_y_prehit - 8 then
            victim_fell_back = true
        end
    end

    if hp >= vic_hp0 then
        victim_y_prehit = p2_y()
    else
        local vy = p2_y()
        victim_min_y = (victim_min_y and math.min(victim_min_y, vy)) or vy
    end

    if since >= 130 then
        local launch = (victim_y_prehit and victim_min_y)
                       and (victim_y_prehit - victim_min_y) or 0
        res("dive_spacing", SPACINGS[phase_try] or 110)
        res("dive_body_pose", body_pose or "none")
        res("dive_body_is_flipkick", (body_pose or ""):sub(1, #KICK_PREFIX) == KICK_PREFIX)
        res("dive_step_dx", step_dx or 0)
        res("dive_dy_first_last", string.format("%s -> %s",
            tostring(first_dy), tostring(max_dy)))
        res("dive_accelerating", (max_dy or 0) > (first_dy or 0))
        res("dive_landed", math.abs(height() - ground_h) <= 8)
        res("dive_damage", vic_hp0 - vic_hp_min)
        res("dive_hit", (vic_hp0 - vic_hp_min) > 0)
        res("dive_victim_rise", launch)
        -- r_flipk puts him into `flight` at -080000h.  r_slide - what the old
        -- unconditional 012h would have given Reptile - leaves him on the floor.
        res("dive_flipkick_reaction", launch >= 30)
        -- A KNOCKDOWN, spelled out as the arc rather than as a floor test.
        -- oypos is head-anchored and the knocked-down animation has its own
        -- anchor, so the victim's y comes back to roughly the number he stood
        -- at - "did he end up lower than he started" is not the question.
        -- What r_flipk does and a standing hit does not: throw him UP and then
        -- bring him all the way back DOWN while still reacting.
        --
        -- This is the assertion that would have caught the 2026-09-03
        -- regression on its own.  nj_strikes lost its row 20h when
        -- ermac_strikes was cloned off it, so Reptile's dive read one past the
        -- end of his table onto stk_njhikick: 32 damage, r_hikicked, victim
        -- pinned at y 77 for 42 frames of act_reacting and never leaving his
        -- feet.  Damage alone said "it hit" - louder than before, even.
        res("victim_peak_y", victim_min_y)
        res("victim_came_back_down", victim_fell_back or false)
        res("afterimage_seen", ai_name or false)
        res("afterimage_ticks", ai_seen_ticks)
        res("afterimage_drift_px", ai_drift)
        res("afterimage_gone_at", ai_gone_at or "still up")
        -- The proof it is an afterimage and not just the diving man being
        -- counted twice: he has to have LEFT it behind.
        res("afterimage_he_left_it",
            (ai_launch_x and ai_x0) and math.abs(p1_x() - ai_x0) or 0)
        -- ASSERTED, not just reported, and in both directions.  Judged on
        -- three things together, because the copy and the diving man wear the
        -- same frame: it was SEEN, it STAYED for a while, and he LEFT it -
        -- a find_afterimage that had locked onto the diver himself would
        -- score a drift that tracks him instead of a gap that opens.
        res("afterimage_expected", WANT_AFTERIMAGE)
        local gh_snapped = (gh_snaps_last and gh_snaps0)
                           and (gh_snaps_last - gh_snaps0) or 0
        res("ghosts_expected", WANT_GHOSTS)
        res("ghosts_armed_ticks", gh_armed_ticks)
        res("ghosts_were_mine", gh_mine_ticks)
        res("ghosts_n", gh_n_seen)
        res("ghosts_snapped", gh_snapped)
        -- Armed FOR HIM for most of the dive, and really blitting.  The
        -- snapshot count is the half a leftover setup cannot fake;
        -- gh_mine_ticks is the half that says THIS move armed it and not the
        -- other man's.
        res("ghosts_as_expected",
            WANT_GHOSTS
            -- 4, not 10: the dive CONNECTS at since=6..8 at every spacing
            -- this rig parks him at, and the trail is disarmed on contact -
            -- so the armed window is the flight, and the flight is short.
            and (gh_mine_ticks >= 4 and gh_mine_ticks == gh_armed_ticks
                 and gh_snapped >= 2 and gh_n_seen == 3)
            or (not WANT_GHOSTS and gh_armed_ticks == 0))
        res("afterimage_as_expected",
            WANT_AFTERIMAGE
            and (ai_name ~= nil and ai_seen_ticks >= 10
                 and (R.afterimage_he_left_it or 0) >= 30
                 and (ai_drift or 0) <= 4)
            or (not WANT_AFTERIMAGE and ai_name == nil))
        log("  travelled: step_dx=%s  dy %s -> %s   landed=%s",
            tostring(step_dx), tostring(first_dy), tostring(max_dy),
            tostring(R.dive_landed))
        log("  victim hp %d -> %d (-%d) ; launched %d px up (pre-hit y %s, peak y %s)",
            vic_hp0, vic_hp_min, vic_hp0 - vic_hp_min, launch,
            tostring(victim_y_prehit), tostring(victim_min_y))

        local structural = R.dive_body_is_flipkick and R.dive_accelerating
                           and (step_dx or 0) >= 6 and R.dive_landed
        local good = structural and R.dive_hit and R.dive_flipkick_reaction
                     and R.victim_came_back_down and R.dive_damage == 26
                     and R.afterimage_as_expected and R.ghosts_as_expected
        if INVISO then
            res("inviso_before_cast", inviso_before_cast)
            res("inviso_after_cast", inviso_after_cast)
            res("inviso_no_afterimage", not ai_name)
            log("  inviso: before cast=%s, on cast tick=%s, afterimage=%s",
                tostring(inviso_before_cast), tostring(inviso_after_cast), tostring(ai_name))
            good = good and inviso_before_cast == true and inviso_after_cast == false
                   and not ai_name
        end
        if good and SOAK > 0 then
            soak_done = soak_done + 1
            soak_log[#soak_log] = nil
            table.insert(soak_log, string.format("#%d %s(%dt,drift %d)",
                soak_done, tostring(ai_name), ai_seen_ticks, ai_drift))
            log("  soak %d/%d: afterimage %s for %d ticks, drift %d",
                soak_done, SOAK, tostring(ai_name), ai_seen_ticks, ai_drift)
            if soak_done < SOAK then
                begin_try((phase_try % MAX_TRIES) + 1)
                return
            end
            res("soak_casts", soak_done)
            res("soak_all_had_afterimage", true)
            for _, e in ipairs(soak_log) do
                if e:find("nil") then R.soak_all_had_afterimage = false end
            end
        end
        if good then
            snap("dive_done")
            finish(true, "dive_fires_flies_and_launches")
            return
        end
        if phase_try < MAX_TRIES then
            log("  did not connect at spacing %d (structural=%s) - retrying",
                SPACINGS[phase_try] or 110, tostring(structural))
            local kf, kh = R.dive_fired, R.dive_height_at_fire
            begin_try(phase_try + 1)
            R.dive_fired, R.dive_height_at_fire = kf, kh
            return
        end
        finish(false, "see_field_report")
        return
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("testing %s: %d art markers from %s", WHO, marker_count, ART_TBL)
        log("  expecting shadow: decoy=%s  ghost trail=%s  (noobdive_ghost=%s)",
            tostring(WANT_AFTERIMAGE), tostring(WANT_GHOSTS), tostring(NOOB_GHOST))
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

    if frame > 12000 then finish(false, "global_timeout") end
end)
