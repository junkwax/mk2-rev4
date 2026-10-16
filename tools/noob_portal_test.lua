-- Runtime proof for Noob Saibot's shadow portal (Down,Down + LK).
--
-- Forces P1 = Noob, starts a normal match, drives the motion, and checks what
-- actually happened rather than that the code ran:
--
--   * the NOOBAIRGUNK blast played over his held cast pose
--   * the hole was born on NOOBAIRGUNK6 - the frame where the blast reaches
--     the floor - and not a beat either side of it
--   * a projectile object carrying a NOOBPORTAL SAG appeared
--   * it appeared under the VICTIM, not under Noob (the whole point - every
--     other projectile in this game spawns on the thrower)
--   * it sits on the floor line, not floating (NOOBPORTAL's ellipse centre is
--     131px below its anipoint, which is where a grounded fighter's feet are)
--   * the victim took damage
--   * the victim went INVISIBLE partway through (m_inviso, the swallow)
--   * the victim came back down from ABOVE THE SCREEN
--   * the victim ended up on the far side of Noob from where he started
--   * NOOB turned to face the side the victim landed on
--
-- Then two more passes:
--
--   "jump_up" / "jump_fwd" / "jump_back"
--             the victim is launched on a REAL arc - a jump velocity and the
--             game's own gravity, not a pinned oypos - and must come down
--             untouched.  Jumping the hole is the move's counterplay and it
--             has been silently broken twice: first by a strike box anchored
--             on the head instead of the floor, then by the box alone being
--             unable to express it at all (a jump passes through the bottom
--             of ANY band on the way up and again on the way down, so the
--             takeoff or the landing gets caught).  It is an is_he_airborn
--             gate in noob_portal_proc now.  jump_up is the one that matters
--             most: it stays directly over the hole, so it cannot pass for
--             the wrong reason by drifting out of the x band.  These passes
--             also exercise the only path that closes an unused portal, so a
--             hole left spinning forever fails here too.
--   "lethal"  the victim is on 6 HP, so the portal KILLS him.  This pass
--             exists for one reason: the swallow sets m_inviso by hand and it
--             is r_noob_portal's own drop that clears it again, so a hit that
--             ends the round inside that ~10-tick window is the one way this
--             move could leave a fighter permanently invisible.
--
-- Pointer-level like the other Noob harnesses: matching SAGs prove the tables
-- are reached, not that the art is right.  Look at the snapshots.
--
-- All offsets/addresses are TMS34010 BIT units - MAME's tms34010 program space
-- is bit-addressed, and mk2.map values go in raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("NOOB_TEST_LOG") or (ROOT .. "/tools/noob_portal_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[portal] " .. string.format(fmt, ...)
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
local function sym(n, fb) return symbols[n] or fb end

local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    objlst = sym("objlst"), winner_status = sym("winner_status"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    ground_y = sym("ground_y"),
    left_edge = sym("left_edge"), right_edge = sym("right_edge"),
}
local P_ACTION = 0x100 + 0xf0     -- pdata + p_action
local P_GANIY  = 0x100 + 0x100    -- pdata + p_ganiy
local OFLAGS, OFLAGS2, B_FLIPH = 0xf0, 0x160, 4
local M_INVISO = 0x20
local OIMG, MP_LEN, ONEXT, OXPOS, OYPOS = 0x1a0, 0x70, 0x00, 0x90, 0xb0
-- ograv is ALIASED with oslink/oplink at 0x20 (DISPEQU.ASM) - it is not a
-- field of its own.  Writing it on a player object is what gravity_n_bounds
-- integrates; without it a launched fighter rises forever.
-- oxvel/oyvel are fields of their own.  ograv is NOT: 0x20 is shared by
-- oslink / oplink / ograv (DISPEQU.ASM), i.e. the same longword is the
-- object's link to its controlling process.  Writing "gravity" onto a PLAYER
-- object from outside the engine therefore stamps on that link, and the
-- damage is not immediate or obvious - an early version of these passes did
-- it and the victim's fighter started walking around and re-casting moves
-- with every input held at zero, ~130 frames later.  Drive the arc instead.
local OXVEL, OYVEL = 0x40, 0x60
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_NOOB, FT_JAX, MAX_HP = 10, 15, 11, 0x00a1
local ACT_PORTAL = 0x0117

-- SAG -> frame name, straight out of the generated table.
local sag_name = {}
local marker_count = 0
do
    local fh = assert(io.open(ROOT .. "/src/NOOBPORT.TBL", "r"), "missing src/NOOBPORT.TBL")
    local label
    for line in fh:lines() do
        local l = line:match("^%s*(NOOBPORTAL%d*):")
                or line:match("^%s*(NSPORTALSHOT%w*):")
                or line:match("^%s*(NOOBAIRGUNK%d*):")
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
local fields = {}
local charsel_frame, vs_frame, confirm_frame, fighting_frame = 0, 0, 0, 0
local last_gstate, last_action = -1, -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local R = {}
local function res(k, v) R[k] = v end

local RESULT_KEYS = { "portal_seen", "portal_frames", "portal_under_victim",
                      "portal_off_ground", "portal_damage", "victim_vanished",
                      "victim_from_above", "victim_crossed", "noob_turned",
                      "cast_played", "cast_frames", "cast_left_stance",
                      "blast_frames", "portal_born_on", "blast_gap_px",
                      "jump_up_missed", "jump_fwd_missed", "jump_back_missed",
                      "jump_apex", "jumped_portal_closed",
                      "lethal_killed", "lethal_visible_after" }

local function finish(ok, reason)
    if finished then return end
    finished = true
    for _, k in ipairs(RESULT_KEYS) do log("  %-20s %s", k, tostring(R[k])) end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true, ["P1 High Kick"]=true,
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

-- The sidecar carries two sets and they mean different things: NOOBPORTAL* is
-- the hole (a projectile object), NSPORTALSHOT* is Noob's own body during the
-- cast.  Keeping them apart is what lets one lookup table answer both "did the
-- hole appear" and "is he still stuck on a cast frame".
-- Prefix test written once.  Hand-counted sub(1,N) lengths are how the first
-- version of this silently matched nothing at all: "NOOBPORTAL" is 10
-- characters and "NOOBAIRGUNK" is 11, and both were compared against a
-- 12-character slice, so every lookup returned false and the report claimed
-- the portal had never appeared on a run where it plainly had.
local function starts_with(n, pre)
    return n ~= nil and n:sub(1, #pre) == pre
end
local function is_cast_frame(n) return starts_with(n, "NSPORTALSHOT") end
local function is_gunk_frame(n) return starts_with(n, "NOOBAIRGUNK") end
local function is_hole_frame(n) return starts_with(n, "NOOBPORTAL") end

local function find_portal()
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frame(obj)
            -- Match the HOLE specifically.  The sidecar carries the blast and
            -- his cast frames too, and both are on objects this walk sees -
            -- "anything from NOOBPORT.TBL" would happily report the blast as
            -- the portal and pass every placement check against the wrong art.
            if is_hole_frame(n) then
                return n, s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS))
            end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return nil
end

-- Which NOOBAIRGUNK frame, if any, is on screen right now.
local function find_gunk()
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frame(obj)
            if is_gunk_frame(n) then
                return n, s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS))
            end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return nil
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

-- ---------------------------------------------------------------- input plan
-- 4-frame taps with a 2-frame neutral gap, the shape proven by
-- jade_boomerang_test.lua and reused by noob_moves_test.lua.  Down,Down is two
-- taps of the SAME direction, which has to go through neutral in between - the
-- gap is what makes the second one a separate queue entry at all.
local SEQ = { {0, 4, "P1 Down"}, {6, 10, "P1 Down"}, {12, 18, "P1 Low Kick"} }
local RETRY_AFTER, MAX_TRIES = 60, 10
local WATCH = 200                       -- frames to observe after it fires

-- Place them centrally: the reaction drops the victim BEHIND Noob, and
-- r_noob_portal falls back to dropping him in FRONT when Noob is inside
-- NOOB_RNP_EDGE of a wall (teleport_next_to's rule).  A corner test would
-- exercise the fallback, which is not what this run is measuring.
local SPACING = 150
local function place_fighters()
    local le, re = s16(r16(A.left_edge)), s16(r16(A.right_edge))
    local mid = (le + re) // 2
    w16(r32(A.p1_obj) + OXPOS, mid & 0xffff)
    w16(r32(A.p2_obj) + OXPOS, (mid + SPACING) & 0xffff)
end

-- Two passes.  `hp` is what the victim's bar is forced to just before the
-- motion; nil leaves it full.
-- `jump` launches the victim on a real arc the tick the portal arms: oyvel up,
-- the game's own gravity, and `drift` px/tick sideways for the flip-jump
-- variants.  A velocity rather than a pinned oypos, because the thing under
-- test is a STATE (is_he_airborn keys on oyvel first) and because pinning
-- oypos leaves oyvel and ograv at zero, which is not what a jump looks like to
-- anything that asks.
--
-- The arc is COMPUTED HERE and written to oypos a tick at a time, rather than
-- handed to the engine as a velocity and a gravity.  Two reasons, both learned
-- the hard way: gravity cannot be set from outside without stamping on oplink
-- (see above), and nothing grounds a hand-launched fighter anyway, so the
-- engine would fly him into the basement and wreck the following pass.
--
-- 12px/tick up against 0.5px/tick^2 gives 48 ticks of airtime and a 144px
-- apex, deliberately longer than NOOB_PORTAL_LIFE (40) so a clean jump
-- outlives the whole armed window.  The correct result is then ZERO damage
-- across the pass - a binary assertion with no "did he land before or after it
-- closed" ambiguity.
local JUMP_V0, JUMP_G = 12.0, 0.5
local JUMP_TICKS = 48
--
-- `drift` is px/tick applied to oxpos, NOT an oxvel write.  The drone
-- re-asserts its own oxvel every tick from its state machine, so a velocity
-- handed to a CPU fighter is gone by the next frame - the first version of
-- these two passes set oxvel and measured 5px of travel across a 48-tick arc,
-- i.e. they were three straight-up jumps wearing different names.  Driving
-- oxpos moves him for real.
--
-- 2px/tick x 48 = 96px, which clears the hole's ~72px half-width without
-- walking him into Noob at the 150px spacing these passes use.
local PASSES = {
    { name = "hit",       hp = nil },
    { name = "jump_up",   hp = nil, jump = true, drift = 0 },
    { name = "jump_fwd",  hp = nil, jump = true, drift = -2 },  -- toward Noob
    { name = "jump_back", hp = nil, jump = true, drift = 2 },   -- away
    { name = "lethal",    hp = 6 },     -- less than stk_noob_portal's 12
}
local pass_idx = 0

local tries, fired, move_start = 0, false, 0
local seen, first_x, first_y = {}, nil, nil
local noob_x0, jax_x0, jax_hp0 = nil, nil, nil
local jax_min_y, saw_inviso = nil, false
local jax_ganiy, noob_flip0, jax_apex = nil, nil, 0
local saw_cast, cast_frames = false, {}
local gunk_frames, portal_born_on, blast_gap = {}, nil, nil

-- The box arms NOOB_PORTAL_OPEN ticks after the hole appears, and the hole
-- appears on the GUNK6 beat - 2*NOOB_PSHOT_IN + 3*NOOB_GUNK_RATE = 26 ticks
-- into the cast, so it goes live around 36.  Launching here puts him in the
-- air right as it arms, which is the worst case for the gate.  RETIME THIS
-- WITH THE CAST: launch too early and he has landed again before the box is
-- live, which passes for the wrong reason.
local LAUNCH_REL = 35

-- Put the victim back on his feet with nothing left over.
--
-- NOTHING GROUNDS HIM FOR US.  Landing is `flight`'s job (clr ograv /
-- stop_me / ground_player) and a fighter moved by hand never enters flight, so
-- the arc has to be ended explicitly.  An earlier version handed the engine a
-- velocity and a gravity instead and simply let go: he accelerated downward
-- forever and the pass AFTER the jump measured a victim thousands of px below
-- the world (apex 0, min y 7816).  Land him, and again at the top of every
-- pass, so no pass can inherit the last one's state.
local function ground_victim()
    local jo = r32(A.p2_obj)
    if jo == 0 or not space then return end
    space:write_u32(jo + OXVEL, 0)
    space:write_u32(jo + OYVEL, 0)
    local gy = s16(r16(r32(A.p2_proc) + P_GANIY))
    w16(jo + OYPOS, gy & 0xffff)
end

local function move_pressed(name)
    local rel = frame - move_start
    for _, w in ipairs(SEQ) do
        if w[3] == name and rel >= w[1] and rel < w[2] then return true end
    end
    return false
end

local function reset_measurements()
    noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
    noob_flip0 = (r16(r32(A.p1_obj) + OFLAGS) >> B_FLIPH) & 1
    jax_x0, jax_hp0 = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
    jax_min_y = s16(r16(r32(A.p2_obj) + OYPOS))
    jax_ganiy = s16(r16(r32(A.p2_proc) + P_GANIY))
    saw_inviso = false
    jax_apex = 0
    saw_cast, cast_frames = false, {}
    gunk_frames, portal_born_on, blast_gap = {}, nil, nil
    seen, first_x, first_y = {}, nil, nil
end

local begin_pass                 -- forward declaration; defined below

local function report()
    local pass = PASSES[pass_idx].name
    local names = {}
    for n, _ in pairs(seen) do names[#names+1] = n end
    table.sort(names)
    res("portal_seen", #names > 0)
    res("portal_frames", #names)

    local jo = r32(A.p2_obj)
    local jx, hp = s16(r16(jo + OXPOS)), r16(A.p2_bar)
    local nx = s16(r16(r32(A.p1_obj) + OXPOS))
    local nflip = (r16(r32(A.p1_obj) + OFLAGS) >> B_FLIPH) & 1
    local inviso_now = (r16(jo + OFLAGS2) & M_INVISO) ~= 0
    res("portal_damage", jax_hp0 - hp)
    res("victim_vanished", saw_inviso)
    -- He is placed at NOOB_RNP_TOP (-0a0h) before the drop, so anything that
    -- far above the floor can only be the reappearance.
    res("victim_from_above", jax_min_y <= -0x80)
    -- He started on Noob's right; behind Noob is Noob's left.
    res("victim_crossed", jx < nx)
    -- joy_stance_loop's am_i_facing_him is what turns him, so this is really a
    -- check that Noob got back to a normal state at all after the cast.
    res("noob_turned", nflip ~= noob_flip0)
    local names_cast = {}
    for n, _ in pairs(cast_frames) do names_cast[#names_cast+1] = n end
    table.sort(names_cast)
    res("cast_played", saw_cast)
    res("cast_frames", #names_cast)
    -- By the end of the window the cast is long over, so he must be back on
    -- his stance and not parked on a cast pose.
    res("cast_left_stance", not is_cast_frame(obj_frame(r32(A.p1_obj))))
    local names_gunk = {}
    for n, _ in pairs(gunk_frames) do names_gunk[#names_gunk+1] = n end
    table.sort(names_gunk)
    res("blast_frames", #names_gunk)
    res("portal_born_on", portal_born_on or "nothing")
    res("blast_gap_px", blast_gap or "n/a")
    log("  blast frames seen: %s",
        #names_gunk > 0 and table.concat(names_gunk, ",") or "NONE")
    log("  cast frames seen on Noob: %s",
        #names_cast > 0 and table.concat(names_cast, ",") or "NONE")

    if first_x then
        res("portal_under_victim", math.abs(first_x - jax_x0) <= 24)
        res("portal_off_ground", (first_y or 0) - (jax_ganiy or 0))
    else
        res("portal_under_victim", false)
        res("portal_off_ground", "n/a")
    end

    log("frames seen: %s", #names > 0 and table.concat(names, ",") or "NONE")
    log("  portal spawn x=%s y=%s   jax x0=%d ganiy=%s",
        tostring(first_x), tostring(first_y), jax_x0, tostring(jax_ganiy))
    log("  noob x %d -> %d   jax x %d -> %d   jax min y %d",
        noob_x0, nx, jax_x0, jx, jax_min_y)
    log("  hp %d -> %d (-%d)", jax_hp0, hp, jax_hp0 - hp)

    log("  noob fliph %d -> %d   victim inviso now = %s",
        noob_flip0, nflip, tostring(inviso_now))

    local ok = R.portal_seen and R.portal_under_victim
               and math.abs(tonumber(R.portal_off_ground) or 999) <= 12
               and (PASSES[pass_idx].jump or
                    (R.victim_vanished and R.victim_from_above
                     and (R.portal_damage or 0) > 0))

    if PASSES[pass_idx].jump then
        -- Nothing may have happened to him, and the hole must have shut itself.
        local missed = (jax_hp0 - hp) == 0 and not saw_inviso
        res(pass .. "_missed", missed)
        res("jump_apex", jax_apex)
        res("jumped_portal_closed", find_portal() == nil)
        local travelled = jx - jax_x0
        log("  apex %d px off the ground, travelled %+d px", jax_apex, travelled)
        if PASSES[pass_idx].drift ~= 0 and math.abs(travelled) < 40 then
            finish(false, pass .. "_never_moved_horizontally") return
        end
        -- A jump that never really left the floor would "miss" for the wrong
        -- reason, so the arc itself has to be proven before the miss counts.
        ok = R.portal_seen and missed and R.jumped_portal_closed and jax_apex >= 60
        if not ok then finish(false, "see_field_report") return end
        begin_pass(pass_idx + 1)
        return
    end

    if pass == "lethal" then
        -- The round is over by now, so "crossed" and "turned" mean nothing -
        -- what matters is that the hit killed him and left him VISIBLE.
        res("lethal_killed", hp == 0)
        res("lethal_visible_after", not inviso_now)
        ok = ok and R.lethal_killed and R.lethal_visible_after
        finish(ok, ok and "portal_kill_leaves_him_visible" or "see_field_report")
        return
    end

    ok = ok and R.victim_crossed and R.noob_turned
               and R.cast_played and R.cast_left_stance
               and R.blast_frames == 5
               and R.portal_born_on == "NOOBAIRGUNK6"
               and (tonumber(R.blast_gap_px) or 9999) <= 8
    if not ok then finish(false, "see_field_report") return end
    begin_pass(pass_idx + 1)
end

function begin_pass(i)
    pass_idx = i
    move_start, tries, fired = frame, 1, false
    last_action = -1
    ground_victim()                     -- never inherit the last pass's arc
    place_fighters()
    if PASSES[i].hp then
        w16(A.p2_bar, PASSES[i].hp); w16(A.p2_bar_view, PASSES[i].hp)
    end
    reset_measurements()
    log("--- pass %d (%s) begins at frame %d, noob x=%d jax x=%d hp=%d",
        i, PASSES[i].name, frame, noob_x0, jax_x0, jax_hp0)
end

-- Boot driving: coin in, start, confirm a visible ninja on the select grid.
-- Same schedule as noob_moves_test.lua - Noob has no grid portrait, so the
-- fighter slot is swapped during post-select instead of navigated to.
local function boot_input(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and charsel_frame > 0 and fighting_frame == 0 then
        return confirm_frame > 0 and frame >= confirm_frame and frame < confirm_frame + 45
    end
    return nil                          -- not a boot key this frame
end

-- Set every input for this frame.  `motion` is true while the move's own
-- window owns the stick, false to force everything off.
local function drive_inputs(motion)
    for name, field in pairs(fields) do
        local on = boot_input(name)
        if on == nil then on = motion and move_pressed(name) or false end
        field:set_value(on and 1 or 0)
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded %d NOOBPORT markers, objlst=%s", marker_count,
            A.objlst and string.format("0x%x", A.objlst) or "MISSING")
    end
    if not space or finished then return end
    if not finished and frame > 12000 then finish(false, "global_timeout") return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d p1=%d p2=%d", frame, last_gstate, gs,
            r16(A.p1_char), r16(A.p2_char))
        last_gstate = gs
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        if vs_frame == 0 then vs_frame = frame end
        w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
    end

    -- Keep Noob alive so nothing else ends the round.  The victim's bar is
    -- left alone once a pass has started - the damage is the measurement, and
    -- the lethal pass needs him to actually die.
    if fighting_frame > 0 then
        w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
        if pass_idx == 0 and r16(A.p2_bar) < 0x30 then
            w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
        end
    end

    if fighting_frame > 0 and pass_idx == 0 and frame - fighting_frame >= 150 then
        if r16(A.p1_char) ~= FT_NOOB then finish(false, "p1_not_noob") return end
        begin_pass(1)
    end
    if pass_idx == 0 then drive_inputs(false) return end

    local rel = frame - move_start
    if not fired then
        local proc = A.p1_proc and r32(A.p1_proc) or 0
        if proc ~= 0 and r16(proc + P_ACTION) == ACT_PORTAL then
            fired = true
            move_start = frame; rel = 0
            reset_measurements()
            log("  fired on try %d (noob x=%d jax x=%d)", tries, noob_x0, jax_x0)
        elseif rel >= RETRY_AFTER then
            tries = tries + 1
            if tries > MAX_TRIES then finish(false, "portal_never_fired") return end
            move_start = frame
            place_fighters()
            if PASSES[pass_idx].hp then
                w16(A.p2_bar, PASSES[pass_idx].hp)
                w16(A.p2_bar_view, PASSES[pass_idx].hp)
            end
            reset_measurements()
            log("  no act %04x after %d frames, retry %d", ACT_PORTAL, RETRY_AFTER, tries)
        end
        drive_inputs(true)
        return
    end
    drive_inputs(false)

    local jo = r32(A.p2_obj)
    -- Launch him ONCE, on the tick the box arms, then let the game fly him.
    -- Writing velocity and gravity and standing back is the whole point: the
    -- gate under test keys on oyvel, and a scripted arc that the engine is
    -- actually integrating is the only way to be sure the takeoff tick and the
    -- landing tick are exercised too.  Those two are where the box-only
    -- version failed.
    local pass_cfg = PASSES[pass_idx]
    if pass_cfg.jump then
        local t = (frame - move_start) - LAUNCH_REL
        if t == 0 then
            log("  [rel=%3d] jump starts: %.0fpx/tick up, %d ticks, drift %d",
                frame - move_start, JUMP_V0, JUMP_TICKS, pass_cfg.drift)
        end
        if t >= 0 and t <= JUMP_TICKS then
            -- Height on a real parabola, written straight to oypos.  oyvel is
            -- written to match so is_he_airborn's FIRST test (oyvel ~= 0,
            -- checked before it compares oypos to p_ganiy) is exercised too -
            -- that is the branch covering a jump's takeoff tick, which is the
            -- one the box-only version used to miss.
            local h = JUMP_V0 * t - 0.5 * JUMP_G * t * t
            if h < 0 then h = 0 end
            local v = JUMP_V0 - JUMP_G * t
            w16(jo + OYPOS, ((jax_ganiy or 0) - math.floor(h + 0.5)) & 0xffff)
            space:write_u32(jo + OYVEL, math.floor(-v * 65536) & 0xffffffff)
            if pass_cfg.drift ~= 0 and t > 0 then
                w16(jo + OXPOS, (s16(r16(jo + OXPOS)) + pass_cfg.drift) & 0xffff)
            end
        elseif t == JUMP_TICKS + 1 then
            ground_victim()             -- back on his feet, nothing left over
        end
    end
    local jy = s16(r16(jo + OYPOS))
    if pass_cfg.jump then
        local up = (jax_ganiy or 0) - jy
        if up > (jax_apex or 0) then jax_apex = up end
    end
    if jy < jax_min_y then jax_min_y = jy end
    if (r16(jo + OFLAGS2) & M_INVISO) ~= 0 then saw_inviso = true end

    -- Noob's own sprite.  The cast has to PLAY (so the frames are reached at
    -- all) and then has to STOP - do_proj_sitting_duck never touches the frame,
    -- so anything still displayed when the move ends stays up for the whole
    -- recovery, and NSPORTALSHOT art left up after player_normpal draws in the
    -- wrong palette.
    local nf = obj_frame(r32(A.p1_obj))
    if is_cast_frame(nf) then saw_cast = true; cast_frames[nf] = true end

    local proc = r32(A.p1_proc)
    if proc ~= 0 then
        local act = r16(proc + P_ACTION)
        -- Firing twice inside one pass means the harness is driving inputs it
        -- did not mean to, or has perturbed the game into acting on its own.
        -- Either way every measurement after it is the union of two moves, so
        -- fail here rather than reporting a confusing verdict.
        if act == ACT_PORTAL and fired and last_action ~= ACT_PORTAL
           and (frame - move_start) > 5 then
            log("  [rel=%3d] SECOND cast in one pass - harness fault", frame - move_start)
            finish(false, "double_cast_" .. PASSES[pass_idx].name) return
        end
        if act ~= last_action then
            log("  [rel=%3d] noob p_action %04x -> %04x", rel, last_action, act)
            last_action = act
        end
    end

    local gn, gx, gy = find_gunk()
    if gn then gunk_frames[gn] = true end

    local n, x, y = find_portal()
    if n then
        if next(seen) == nil then
            -- The tick the hole first exists, stamp which blast frame is up.
            -- This is the whole of "the portal is born on GUNK6": both objects
            -- are placed on the same tick by do_noob_portal, so the blast frame
            -- showing here is the one it was born on.
            portal_born_on = gn
            -- The blast must already be standing on the spot when the hole
            -- appears - that is the whole ordering rule of the move.  Both
            -- objects go through noob_aim_at_victim, so agreement should be
            -- exact; the tolerance is for the anipoint spread between frames.
            blast_gap = (gx ~= nil) and math.abs(gx - x) or 9999
            first_x, first_y = x, y
            log("  [rel=%3d] portal %s at (%d,%d)  jax x=%d ganiy=%s  -> DY %+d",
                rel, n, x, y, s16(r16(jo + OXPOS)), tostring(jax_ganiy),
                (jax_ganiy or 0) - y)
        end
        seen[n] = true
    end
    -- rel is measured from the cast.  Spawn is rel 8, the box arms at
    -- 8+NOOB_PORTAL_OPEN, the hit lands the tick after that, then the sink
    -- runs NOOB_RNP_SINK_TICKS and the invisible window NOOB_RNP_GONE.  These
    -- five are picked to land one inside each beat - rel 20 in particular is
    -- the one worth looking at, because with no smoke it is the only thing
    -- proving his legs never draw below the ellipse while he goes down.
    -- rel is measured from the cast.  With the blast in, the beats are:
    -- 0-3 SHOT1, 3-6 SHOT2, 6 SHOT3 + blast starts, then GUNK3/4/5/6/8 two
    -- ticks each (the hole is born on GUNK6 at ~12), 16-22 the reverse leg,
    -- 22 stance.  The victim sinks from the hit and is invisible ~10 ticks
    -- later.  One snapshot per beat, and rel 14 is the one that documents the
    -- requirement: blast at the floor, hole open under him.
    -- rel is measured from the cast.  Beats, at the shipped constants:
    --   0   SHOT1      8   SHOT3 + blast starts   26  GUNK6, hole opens
    --   4   SHOT2     14   GUNK4                  32  GUNK8
    --            20   GUNK5 (arrives on target)   38  blast gone, TAIL hold
    --   46  SHOT2      50  SHOT1                  54  stance
    -- These move whenever the cast is retimed; recompute, do not nudge.
    if rel == 12 then snap("blast_rising") end
    if rel == 28 then snap("blast_on_target_hole_open") end
    if rel == 34 then snap("blast_splash") end
    if rel == 42 then snap("noob_holding_the_reach") end
    if rel == 52 then snap("victim_gone") end
    if rel == 72 then snap("victim_dropping") end
    if rel ==105 then snap("victim_landed") end

    if rel >= WATCH then report() end
end)
