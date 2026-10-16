-- Runtime proof for Noob Saibot's two MK TRILOGY moves.
--
-- Derived from tools/noob_moves_test.lua, which does the same job for the
-- (compiled-out) shadow moves - the boot/select/placement scaffolding is
-- that rig's, unchanged.  What differs is which motions are driven and what
-- counts as proof.
--
--   D,F + LP  the GHOST BALL: a projectile object carrying an RNPSX SAG that
--             TRAVELS away from Noob while Noob stays put, and takes damage
--             off the other man.
--   D,U       the TELEPORT SLAM: Noob's OWN object leaves the top of the
--             screen, re-enters beside the other man, and - when the grab
--             lands - carries him DOWN THROUGH THE FLOOR and back in from
--             the top.
--
-- SCORING THE SLAM ON DAMAGE WOULD BE WRONG.  stk_noob_slam carries
-- damage_hit 0 by design (the grab hands off to body_slam_init, which applies
-- its own), and it is one of twelve records in the build that do.  A rig that
-- scores "connected" as damage>0 reads a perfectly landing grab as a miss.
-- So the grab is scored on the VICTIM'S TRAJECTORY instead: the ride is the
-- only thing in the game that puts him below the floor line AND above the top
-- of the screen in the same move.
--
-- Pointer-level like the rig it came from: matching SAGs prove the tables are
-- reached, not that the art is right.  Look at the snapshots.
--
-- All offsets/addresses are TMS34010 BIT units - MAME's tms34010 program space
-- is bit-addressed, and mk2.map values go in raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("NOOB_TEST_LOG") or (ROOT .. "/tools/noob_trilogy_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[noob] " .. string.format(fmt, ...)
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
    debug5 = sym("debug5"), debug6 = sym("debug6"),
    gh_src = sym("gh_src"), gh_n = sym("gh_n"), ghost_lst = sym("ghost_lst"),
    p1_proc = sym("p1_proc"), ground_y = sym("ground_y"),
    f_norepell = sym("f_norepell"), fpalram = sym("fpalram"),
}
-- THE BALL'S DAMAGE, out of the source every run.  ghost_kill used to leave
-- him on a hard-coded 4 "and the ball does 5"; NBG_DAMAGE has since become 3,
-- the ball stopped killing, the round was never decided and the trial tested
-- nothing.  He is left one short of it now, whatever it is.
local NBG_DAMAGE
do
    local fh = io.open(ROOT .. "/src/MKREACT.ASM", "r")
    if fh then
        for line in fh:lines() do
            local v = line:match("^NBG_DAMAGE%s+%.set%s+(%d+)")
            if v then NBG_DAMAGE = tonumber(v) break end
        end
        fh:close()
    end
end
local KILL_HP = NBG_DAMAGE and math.max(1, NBG_DAMAGE - 1) or nil
-- JG_NEG=1: the CONTROL for ego_juggle - puts back the old flat 040h repell
-- hold at the moment the kick lands, which is what the throw used to leave.
local JG_NEG = os.getenv("JG_NEG") == "1"
local JG_UP = tonumber(os.getenv("JG_UP") or "0")   -- ticks after the throw to jump
-- A FLIP toward where he is flying (the throw sends him LEFT here), which keeps
-- Noob LEVEL with him - straight up leaves Noob below, repell takes its
-- "player above player" path and the bug cannot show.  JG_DIR= for straight up.
local JG_DIR = os.getenv("JG_DIR") or "Left"
local P_ACTION = 0x100 + 0xf0     -- pdata + p_action, bit offset in the proc block
local OFLAGS   = 0xf0
local B_FLIPH  = 4
-- Object block offsets, DISPEQU.ASM.  OXVEL used to be 0x80 here, which is
-- oxval (the 16.16 master x POSITION), not a velocity - that is why the old
-- "peak |oxvel|" line logged eight-digit nonsense.  oxvel is 0x40, oyvel 0x60.
local OIMG, MP_LEN, ONEXT, OXPOS, OYPOS = 0x1a0, 0x70, 0x00, 0x90, 0xb0
local OXVEL, OYVEL = 0x40, 0x60
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_NOOB, FT_JAX, MAX_HP = 10, 15, 11, 0x00a1

-- SAG -> frame name, straight out of the generated tables.
-- NOOBPRJ.TBL is the ghost ball's own pack (RNPSX524-544); MKNJ.TBL is there
-- so Noob's ORDINARY frames resolve to names too, which is what lets the slam
-- half tell "back on his stance" from "still showing something else".
local sag_name = {}
local marker_count = 0
for _, tbl in ipairs({ "NOOBPRJ.TBL", "NOOBRING.TBL", "MKNJ.TBL" }) do
    local fh = assert(io.open(ROOT .. "/src/" .. tbl, "r"), "missing src/" .. tbl)
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
local fields = {}
local charsel_frame, vs_frame, confirm_frame, fighting_frame = 0, 0, 0, 0
local last_gstate = -1
local last_action = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

-- WHICH PALETTE he wears, not which colour MAP: player_swpal frees his map for
-- the flash and the swap back can land the same palette on another map, so
-- opal's number legitimately changes.  fpalram[map] holds the palette's ROM
-- address (0x40 bits a row), which is the identity.
local function pal_id(obj)
    if obj == 0 or not A.fpalram then return nil end
    local map = (r16(obj + 0x140) >> 8) & 0xff
    return r32(A.fpalram + map * 0x40)
end


-- Results, filled in as each move runs.
local R = {}
local function res(k, v) R[k] = v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    for _, k in ipairs({ "ghost_seen", "ghost_travel", "ghost_noob_static",
                         "ghost_damage",
                         "slam_fired", "slam_climb", "slam_gap",
                         "slam_victim_below_floor", "slam_victim_above_screen",
                         "slam_saw_bodyslam",
                         "slam_grabbed",
                         "ghost_armed", "ghost_n", "ghost_drawn_max",
                         "ghost_disarmed",
                         "ego_fired", "ego_damage",
                         "ego_left_fired", "ego_left_damage",
                         "ego_crossed", "ego_peak",
                         "ego_left_crossed", "ego_left_peak",
                         "ego_close_fired", "ego_close_damage",
                         "ego_close_crossed", "ego_close_peak",
                         "ego_close_travel",
                         "jg_hit", "jg_hit_dmg", "jg_travel", "jg_early", "jg_norepell_at_hit",
                         "jump_shadow_left_over", "jump_last_shadow_tick",
                         "jump_noob_recovered", "jump_damage",
                         "kill_saw_ring", "kill_ring_lingered", "kill_ws_ticks",
                         "kill_pal_back_to_normal",
                         "ring_seen", "ring_ticks", "ring_frames" }) do
        log("  %-18s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Punch"]=true, ["P1 Low Kick"]=true, ["P1 High Kick"]=true,
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

-- Frame index of a named frame on an object, or nil.
local OSAG = 0x100
local function obj_frame(obj)
    if obj == 0 then return nil end
    -- SINGLE-part objects first: gso_dmawnz writes the record straight into
    -- osag, and there is no shape-RAM chain to walk.  The multipart walk below
    -- cannot see them at all, which is why the ghost ring read as absent the
    -- moment it stopped being a gmo_proc object.
    local sag1 = r32(obj + OSAG) & 0x00ffffff
    if sag_name[sag1] then return sag_name[sag1] end
    local image = r32(obj + OIMG); if image == 0 then return nil end
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        if sag_name[sag] then return sag_name[sag] end
    end
    return nil
end

-- Find the first object (other than the two fighters) showing a frame whose
-- name starts with `prefix`.  Returns name, x, y.
local function find_shadow(prefix)
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frame(obj)
            if n and n:sub(1, #prefix) == prefix then
                return n, s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS)), obj
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
-- Each move is one entry: a list of {from, to, field} windows relative to the
-- move's start frame.  P1 stands on the left facing right, so Back = Left.
-- Window shape copied from tools/jade_boomerang_test.lua, which is the proven
-- one for this game: 4-frame taps with a 2-frame neutral gap between them, then
-- the button.  Longer, overlapping holds do not register as a motion.
-- `act` is the p_action a move must reach for the attempt to count as fired.
-- Boot timing drifts run to run, so a single fixed input window is not
-- reliable: the motion can land while Noob is mid-block or mid-recovery and
-- simply not register.  Each move re-drives its motion until the act appears
-- and only then starts measuring.
local ACT_GHOST, ACT_SLAM = 0x011f, 0x0212
local OXVAL = 0x80
local ACT_EGO = 0x0213          -- act_noob_ego, the SHADOW THROW cast
local RETRY_AFTER, MAX_TRIES = 50, 8
local MOVES = {
    -- Far enough out that the ball is seen to TRAVEL.  Point blank it would
    -- connect on its first tick and delete itself, which reads as "never
    -- moved" even though the move worked - the note the parent rig leaves on
    -- SPACING applies unchanged.
    { name = "ghost", prefix = "GHOSTPROJ", watch = 420, act = ACT_GHOST,
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Right"}, {12, 18, "P1 Low Punch"} } },
    -- The slam teleports itself into range, so the starting gap only has to
    -- be somewhere the drone will not immediately close.
    { name = "slam", prefix = "__none__", watch = 260, act = ACT_SLAM,
      spacing = 200,
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Up"} } },
    -- THE SHADOW THROW.  Forward, Forward + High Punch, and the window is
    -- only 010h, so the two taps are close together.  Started a little out so
    -- the shadow is seen to RUN before it reaches him.
    { name = "ego", prefix = "NJWALK", watch = 300, act = ACT_EGO,
      spacing = 200,
      seq = { {0, 3, "P1 Right"}, {5, 8, "P1 Right"}, {9, 13, "P1 High Punch"} } },
    -- ...and the SAME move from the other side.  Negative spacing puts Noob
    -- to Jax's RIGHT, so forward is LEFT: the shadow has to run the other
    -- way.  This is the trial that catches a direction decided by anything
    -- but the two positions.
    { name = "ego_left", prefix = "__none__", watch = 300, act = ACT_EGO,
      spacing = -200,
      seq = { {0, 3, "P1 Left"}, {5, 8, "P1 Left"}, {9, 13, "P1 High Punch"} } },
    -- HE JUMPS IT.  The victim is held 90 px off the floor while the shadow
    -- is out, which is past NBE_AIRMAX, so the toss is refused and the shadow
    -- runs on and off the screen.  What this trial is really asking: does it
    -- delete itself, and does Noob come out of the swipe he is holding?
    -- POINT BLANK.  The shadow catches him beside Noob, inside
    -- repell_distance, where repell_now leaves oxvel alone while f_norepell
    -- is up - so a throw that only made the x REQUEST sent him straight up
    -- and down, as if in a corner.  He must TRAVEL.
    { name = "ego_close", prefix = "__none__", watch = 300, act = ACT_EGO,
      spacing = 60,
      seq = { {0, 3, "P1 Right"}, {5, 8, "P1 Right"}, {9, 13, "P1 High Punch"} } },
    -- JUGGLE HIM AS HE SAILS OVER.  Noob jumps straight up and kicks the man
    -- his shadow just threw over his head.  The throw used to hold repell off
    -- for a flat 040h, which outlived the flight: the kick's knockback is only
    -- an x request, repell_now drops requests while that hold is up and the
    -- two are close, and he fell straight down as if pinned in a corner.
    { name = "ego_juggle", prefix = "__none__", watch = 300, act = ACT_EGO,
      spacing = 200, juggle = true,
      seq = { {0, 3, "P1 Right"}, {5, 8, "P1 Right"}, {9, 13, "P1 High Punch"} } },
    { name = "ego_jump", prefix = "__none__", watch = 300, act = ACT_EGO,
      spacing = 200,
      seq = { {0, 3, "P1 Right"}, {5, 8, "P1 Right"}, {9, 13, "P1 High Punch"} } },
    -- THE KILLING HIT.  THE BALL CANNOT KO (r_noob_ghost stops its damage at
    -- 1, the PC/PSX rule), so it leaves him on 1 and the ring starts; then
    -- Noob steps in and jabs the cursed man, who cannot block, and the round
    -- is decided while the ring is still playing on him.  Last, because a KO
    -- takes the fight out from under the rig.
    { name = "ghost_kill", prefix = "GHOSTPROJ", watch = 400, act = ACT_GHOST,
      spacing = 150,
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Right"}, {12, 18, "P1 Low Punch"} } },
}
-- The slam's ride is the verdict: below the floor AND above the screen.
local SLAM_BELOW_FLOOR = 0x40           -- px below his own STANDING y
local SLAM_CLIMB       = 120            -- px Noob must clear going up
local move_idx, move_start = 0, 0
local tries, fired = 0, false
local seen_frames, first_x, last_x, first_y, best_rise = {}, nil, nil, nil, 0
local first_rel = nil
local noob_x0, jax_x0, jax_hp0 = nil, nil, nil
local noob_y0_start, noob_min_y = nil, nil
local ring_seen, ring_ticks = {}, 0
local ring_obj = nil
local slam_snap20, slam_snap60, slam_snap110 = false, false, false
local ghost_armed, ghost_disarmed, ghost_max, ghost_n = false, false, 0, 0
local last_ring_frame = nil
local last_vic_frame, vic_frames = nil, {}
local throw_snaps = 0
local kill_pal0, kill_pal_seen, kill_pal_end = nil, {}, nil
local jump_y0, jump_last_shadow, jump_stuck_ticks, jump_noob_back = nil, -1, 0, false
local cross_side0, cross_side_now, cross_crossed, cross_peak, cross_y0 = nil, nil, false, 0, nil
local cross_x0, cross_travel = nil, 0
local jg_throw_frame, jg_hp1, jg_hit_frame, jg_hit_x, jg_travel, jg_hit_dmg, jg_nr = nil, nil, nil, nil, 0, 0, nil
local jg_early = 0      -- px the KICK carries him in its first 8 ticks: ~0 = pinned as if in a corner
local ws_ticks, ring_lingered, kill_saw_ring = 0, false, false
local kill_ring_frame, kill_step_frame = nil, nil
local slam_saw_grab = false
local jax_min_x, jax_max_x, jax_min_y, jax_max_y = nil, nil, nil, nil
local jax_y0_start = nil
local jax_peak_vel = 0

-- Put Noob a fixed distance to Jax's left instead of walking him there.
-- Walking with held Back is not reliable - Back is also block, so if the drone
-- happens to attack he stands still.  Distance matters: point blank the shadows
-- connect on their first tick and delete themselves, which reads as "never
-- travelled" even though the move worked.
local SPACING = 300
local function place_noob()
    local sp = (move_idx > 0 and MOVES[move_idx].spacing) or SPACING
    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
    local nx = jx - sp
    w16(r32(A.p1_obj) + OXPOS, nx & 0xffff)
    -- oxval TOO, not oxpos alone.  oxval is the authoritative 16.16 position
    -- and what the game compares when it asks which side somebody is on
    -- (is_he_right reads it, and so does the shadow throw); writing only
    -- oxpos left it stale, so a rig teleport moved the sprite and not the
    -- coordinate the code reasons about.
    w32(r32(A.p1_obj) + OXVAL, (nx * 65536) & 0xffffffff)
end

local function begin_move(i)
    move_idx = i
    move_start = frame
    tries, fired = 1, false
    slam_saw_grab = false
    -- BEFORE place_noob, which reads where Jax IS: setting him afterwards left
    -- the pair 363 px apart and the ball never reached him.
    if MOVES[i] and MOVES[i].juggle then
        -- mid-stage: by now the pair has drifted to the left wall, and a man
        -- thrown into the wall cannot travel whatever repell does
        w16(r32(A.p2_obj) + OXPOS, 600)
        w32(r32(A.p2_obj) + OXVAL, 600 * 65536)
    end
    if MOVES[i] and MOVES[i].name == "ghost_kill" then
        if not KILL_HP then finish(false, "NBG_DAMAGE_not_found_in_MKREACT") return end
        w16(A.p2_bar, KILL_HP)
        w16(r32(A.p2_obj) + OXPOS, 500)
        w32(r32(A.p2_obj) + OXVAL, 500 * 65536)
    end
    place_noob()
    seen_frames, first_x, last_x, first_y, best_rise = {}, nil, nil, nil, 0
    first_rel = nil
    noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
    noob_y0_start = s16(r16(r32(A.p1_obj) + OYPOS))
    noob_min_y = noob_y0_start
    ring_seen, ring_ticks = {}, 0
    -- per TRIAL, not per run: the first ego throw used the whole dozen and
    -- the second one filmed nothing.
    throw_snaps, last_ring_frame = 0, nil
    cross_side0, cross_side_now, cross_crossed, cross_peak, cross_y0 = nil, nil, false, 0, nil
    cross_x0, cross_travel = nil, 0
    jg_throw_frame, jg_hp1, jg_hit_frame, jg_hit_x, jg_travel, jg_hit_dmg, jg_nr = nil, nil, nil, nil, 0, 0, nil
    jg_early = 0
    jump_y0, jump_last_shadow, jump_stuck_ticks, jump_noob_back = nil, -1, 0, false
    kill_pal0, kill_pal_seen, kill_pal_end = nil, {}, nil
    kill_ring_frame, kill_step_frame = nil, nil
    jax_x0, jax_hp0 = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
    jax_min_x, jax_max_x = jax_x0, jax_x0
    local jy0 = s16(r16(r32(A.p2_obj) + OYPOS))
    jax_min_y, jax_max_y, jax_y0_start = jy0, jy0, jy0
    jax_peak_vel = 0
    log("--- move %d (%s) begins at frame %d, noob x=%d jax x=%d hp=%d",
        i, MOVES[i].name, frame, noob_x0, jax_x0, jax_hp0)
end

local function move_pressed(name)
    if move_idx == 0 then return false end
    -- the killing jab, once Noob has been stepped in beside him
    if MOVES[move_idx].name == "ghost_kill" and kill_step_frame and name == "P1 High Punch" then
        local ws = A.winner_status and r16(A.winner_status) or 0
        if ws ~= 0 then return false end
        local t = (frame - kill_step_frame) % 10
        return t >= 2 and t < 5
    end
    -- the juggle: straight up as the throw starts, then High Kick taps
    if MOVES[move_idx].juggle and jg_throw_frame and not jg_hit_frame then
        local t = frame - jg_throw_frame
        if name == "P1 Up" then return t >= JG_UP and t < JG_UP + 6 end
        if JG_DIR ~= "" and name == "P1 " .. JG_DIR then return t >= JG_UP and t < JG_UP + 6 end
        if name == "P1 High Kick" then
            for k = 0, 6 do
                local a = JG_UP + 8 + 5 * k
                if t >= a and t < a + 2 then return true end
            end
            return false
        end
    end
    local rel = frame - move_start
    for _, w in ipairs(MOVES[move_idx].seq) do
        if w[3] == name and rel >= w[1] and rel < w[2] then return true end
    end
    return false
end

local function finish_move()
    local m = MOVES[move_idx]
    local names = {}
    for n, _ in pairs(seen_frames) do names[#names+1] = n end
    table.sort(names)
    log("move %s: frames seen = %s", m.name, #names > 0 and table.concat(names, ",") or "NONE")

    if m.name == "ghost" then
        res("ghost_seen", #names > 0)
        res("ghost_travel", (first_x and last_x) and math.abs(last_x - first_x) or 0)
        local nx = s16(r16(r32(A.p1_obj) + OXPOS))
        res("ghost_noob_static", math.abs(nx - noob_x0) <= 8)
        local hp = r16(A.p2_bar)
        res("ghost_damage", jax_hp0 - hp)
        log("  ball x %s -> %s ; noob x %d -> %d",
            tostring(first_x), tostring(last_x), noob_x0, nx)
        log("  jax hp %d -> %d (-%d)", jax_hp0, hp, jax_hp0 - hp)
        local rnames = {}
        for n, _ in pairs(ring_seen) do rnames[#rnames+1] = n end
        table.sort(rnames)
        res("ring_seen", #rnames > 0)
        res("ring_ticks", ring_ticks)
        res("ring_frames", #rnames)
        log("  ghost ring: %d ticks on screen, frames = %s", ring_ticks,
            #rnames > 0 and table.concat(rnames, ",") or "NONE")
    else
        -- SLAM.  `fired` is set by the act watcher, so it is the honest
        -- "the move came out" signal and is independent of whether the grab
        -- landed.  The climb is Noob's own object clearing the screen top.
        if m.name == "ego_jump" then
            local sn = find_shadow("NJWALK")
            res("jump_shadow_left_over", sn ~= nil)
            res("jump_last_shadow_tick", jump_last_shadow)
            res("jump_noob_recovered", jump_noob_back)
            res("jump_damage", jax_hp0 - r16(A.p2_bar))
            -- PUT HIM BACK ON THE FLOOR.  This trial holds him 90 px up by
            -- writing oypos every tick; left there he is still airborne when
            -- the next trial starts, and the killing hit then routes through
            -- generic_airborn_hit instead of r_noob_ghost - so no ring spawns
            -- and ghost_kill quietly stops testing anything.  kill_saw_ring
            -- is the control that caught exactly that.
            if jump_y0 then w16(r32(A.p2_obj) + OYPOS, jump_y0 & 0xffff) end
            log("  jumped: last shadow seen at rel %d of %d, still drawn at the end: %s, Noob back in his stance: %s",
                jump_last_shadow, m.watch, tostring(sn ~= nil), tostring(jump_noob_back))
        end
        if m.name == "ghost_kill" then
            -- THE CONTROL.  "No ring was left on screen" is trivially true
            -- if no ring ever appeared, and an earlier cut of this trial was
            -- exactly that - it could not kill him, so it could not fail.
            -- kill_saw_ring has to be true for the other field to mean
            -- anything, so the verdict requires both.
            local pals = {}
            for k in pairs(kill_pal_seen) do pals[#pals+1] = string.format("%04x", k) end
            table.sort(pals)
            res("kill_pal_back_to_normal", kill_pal0 ~= nil and kill_pal_end == kill_pal0)
            log("  victim palette: started %s, ended %s, saw %s",
                kill_pal0 and string.format("%04x", kill_pal0) or "?",
                kill_pal_end and string.format("%04x", kill_pal_end) or "?",
                table.concat(pals, ","))
            res("kill_saw_ring", kill_saw_ring)
            res("kill_ring_lingered", ring_lingered)
            res("kill_ws_ticks", ws_ticks)
            log("  round decided %d ticks before the end of the window; ring still drawn after it: %s",
                ws_ticks, tostring(ring_lingered))
        end
        if m.name == "ego_juggle" then
            res("jg_hit", jg_hit_frame ~= nil)
            res("jg_hit_dmg", jg_hit_dmg)
            res("jg_travel", jg_travel)
            res("jg_early", jg_early)
            res("jg_norepell_at_hit", jg_nr)
            log("  ego_juggle: thrown %s, kicked %s (for %d), carried %d px in x by the kick, f_norepell at the kick %s%s",
                tostring(jg_throw_frame ~= nil), tostring(jg_hit_frame ~= nil), jg_hit_dmg,
                jg_travel, tostring(jg_nr), JG_NEG and "  [CONTROL: old 040h hold]" or "")
        end
        if m.name == "ego" or m.name == "ego_left" or m.name == "ego_close" then
            res(m.name .. "_fired", fired)
            res(m.name .. "_travel", cross_travel)
            res(m.name .. "_damage", jax_hp0 - r16(A.p2_bar))
            res(m.name .. "_crossed", cross_crossed)
            res(m.name .. "_peak", cross_peak)
            log("  %s: started %s of Noob, ended %s, crossed over him: %s (peak %d px up)",
                m.name,
                cross_side0 == nil and "?" or (cross_side0 > 0 and "RIGHT" or "LEFT"),
                cross_side_now == nil and "?" or (cross_side_now > 0 and "RIGHT" or "LEFT"),
                tostring(cross_crossed), cross_peak)
            log("  %s: victim travelled %d px in x once thrown", m.name, cross_travel)
        end
        res("ghost_armed", ghost_armed)
        res("ghost_drawn_max", ghost_max)
        res("ghost_n", ghost_n)
        res("ghost_disarmed", ghost_disarmed)
        if m.name == "slam" then
        res("slam_fired", fired)
        res("slam_climb", noob_y0_start and (noob_y0_start - noob_min_y) or 0)
        local gap = math.abs(s16(r16(r32(A.p1_obj) + OXPOS))
                           - s16(r16(r32(A.p2_obj) + OXPOS)))
        res("slam_gap", gap)
        local ganiy = A.ground_y and r16(A.ground_y) or 0
        -- MEASURE THE DESCENT AGAINST HIS OWN STANDING y, NOT THE FLOOR LINE.
        -- oypos is the sprite's TOP and a fighter is ~139px tall, so a man
        -- standing on the floor (ground_y 216) has a TOP of about 77 - his top
        -- NEVER passes the floor line, however far through it he is dragged.
        -- Comparing top against ground_y scored a ride that plainly happened
        -- (top 77 -> 147, i.e. feet 70px under the floor) as "never went
        -- below", which is the same class of mistake as scoring a
        -- damage_hit-0 grab on damage.
        res("slam_victim_below_floor",
            jax_y0_start and (jax_max_y - jax_y0_start) >= SLAM_BELOW_FLOOR)
        res("slam_victim_above_screen", jax_min_y < 0)
        -- THE GRAB IS act_bodyslam ON NOOB, not a y threshold on the victim.
        -- The first cut scored it as "victim more than 64px below his own
        -- standing y", and that number cannot discriminate: a man simply
        -- lying down is already ~54px lower, so the test was measuring the
        -- prone pose as much as the ride.  p_action 0507 is set by
        -- body_slam_init and by nothing else in this move, and the victim
        -- going ABOVE THE SCREEN corroborates it - nothing but this ride
        -- puts him there.
        res("slam_saw_bodyslam", slam_saw_grab)
        res("slam_grabbed", slam_saw_grab and R.slam_victim_above_screen)
        log("  noob y %s -> min %s (climb %s)", tostring(noob_y0_start),
            tostring(noob_min_y), tostring(R.slam_climb))
        log("  jax y range %d..%d  (stood at %s, ground_y %d; needs +%d down and <0 up)",
            jax_min_y, jax_max_y, tostring(jax_y0_start), ganiy, SLAM_BELOW_FLOOR)
        log("  landed %d px from Jax", gap)
        end
    end

    if move_idx < #MOVES then
        begin_move(move_idx + 1)
    else
        -- The ghost ball is gated fully.  The SLAM is gated on FIRING and
        -- on the climb, not on the grab: whether the drone is grabbable on
        -- the one rising tick depends on what it chose to do, so the grab is
        -- REPORTED and re-driven, never asserted from a single attempt.
        local ok = R.ghost_seen and R.ghost_noob_static
                   and (R.ghost_travel or 0) >= 40 and (R.ghost_damage or 0) > 0
                   and R.ring_seen and (R.ring_ticks or 0) >= 60
                   and R.slam_fired and (R.slam_climb or 0) >= SLAM_CLIMB
                   and R.slam_grabbed
                   and R.ego_fired and R.ego_left_fired
                   and R.ego_close_fired and (R.ego_close_travel or 0) >= 60
                   and R.jg_hit and (R.jg_early or 0) >= 10
                   and R.kill_saw_ring and R.kill_ring_lingered == false
                   and (R.kill_ws_ticks or 0) > 0
                   and R.kill_pal_back_to_normal
                   and R.jump_shadow_left_over == false and R.jump_noob_recovered
        finish(ok, ok and "both_moves_fired" or "see_field_report")
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded %d SAG markers, objlst=%s", marker_count,
            A.objlst and string.format("0x%x", A.objlst) or "MISSING")
    end

    if space and not finished then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d p1=%d p2=%d", frame, last_gstate, gs,
                r16(A.p1_char), r16(A.p2_char))
            last_gstate = gs
        end

        if gs == GS_PSEL then
            if charsel_frame == 0 then charsel_frame = frame end
            -- Noob has no grid portrait; confirm a visible ninja, then swap the
            -- fighter slot during post-select the way the Jade harness does.
            w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
            if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        elseif gs == GS_POST then
            if vs_frame == 0 then vs_frame = frame end
            w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
            -- Snapshot the VS screen: Noob's portrait is zipped_pics 28h since
            -- the dead VS_JC entry was retired, so this is where a bad index
            -- would show up as garbage or the wrong fighter.
            if frame - vs_frame == 120 then snap("vs_screen") end
        elseif gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
        end

        -- Keep both bars full so nothing ends the round mid-test.
        -- Keep Noob topped up so nothing ends the round, but leave Jax's bar
        -- alone: the shadows are supposed to hurt him and that is measurable.
        if fighting_frame > 0 then
            w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
            -- ...EXCEPT on the killing-hit trial, which exists to end the
            -- round.  This refill is why an earlier cut of it could never
            -- reproduce the bug: the bar was written back to full the frame
            -- after it was seeded, so nothing ever died and winner_status
            -- never moved off 0.
            local mv = MOVES[move_idx]
            if not (mv and mv.name == "ghost_kill") then
                if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end
            end
        end

        if fighting_frame > 0 and move_idx == 0 and frame - fighting_frame >= 150 then
            if r16(A.p1_char) ~= FT_NOOB then finish(false, "p1_not_noob") return end
            begin_move(1)
        end

        if move_idx > 0 then
            local m = MOVES[move_idx]
            local rel = frame - move_start
            -- Wait for the move to actually fire before measuring; re-drive the
            -- motion if it did not take.
            if not fired then
                local proc = A.p1_proc and r32(A.p1_proc) or 0
                if proc ~= 0 and r16(proc + P_ACTION) == m.act then
                    fired = true
                    move_start = frame
                    rel = 0
                    place_noob()
                    noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
    noob_y0_start = s16(r16(r32(A.p1_obj) + OYPOS))
    noob_min_y = noob_y0_start
    ring_seen, ring_ticks = {}, 0
                    jax_x0, jax_hp0 = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
                    jax_min_x, jax_max_x = jax_x0, jax_x0
                    local jy = s16(r16(r32(A.p2_obj) + OYPOS))
                    jax_min_y, jax_max_y, jax_y0_start = jy, jy, jy
                    log("  %s fired on try %d (noob x=%d jax x=%d)", m.name, tries, noob_x0, jax_x0)
                elseif rel >= RETRY_AFTER then
                    tries = tries + 1
                    if tries > MAX_TRIES then finish(false, m.name .. "_never_fired") return end
                    move_start = frame
                    place_noob()
                    log("  %s: no act %04x after %d frames, retry %d", m.name, m.act, RETRY_AFTER, tries)
                end
                for name, f in pairs(fields) do f:set_value(move_pressed(name) and 1 or 0) end
                return
            end
            -- Hold the victim in the game's own airborne state for the whole
            -- window.  Stop as soon as he is reacting: from there the reaction
            -- owns his velocities and writing oyvel would fight `flight`.
            if m.name == "airhit" and r16(A.p2_bar) == jax_hp0 then
                local jo = r32(A.p2_obj)
                if jo ~= 0 and space then
                    space:write_u32(jo + OYVEL, AIRHIT_OYVEL & 0xffffffff)
                end
            end
            local jxn = s16(r16(r32(A.p2_obj) + OXPOS))
            if jax_min_x and jxn < jax_min_x then jax_min_x = jxn end
            if jax_max_x and jxn > jax_max_x then jax_max_x = jxn end
            local jv = r32(r32(A.p2_obj) + OXVEL)
            if jv >= 0x80000000 then jv = jv - 0x100000000 end
            if math.abs(jv) > math.abs(jax_peak_vel) then jax_peak_vel = jv end
            local jyn = s16(r16(r32(A.p2_obj) + OYPOS))
            if jax_min_y and jyn < jax_min_y then jax_min_y = jyn end
            if jax_max_y and jyn > jax_max_y then jax_max_y = jyn end
            -- Noob's OWN y, for the slam's climb.  The parent rig never
            -- needed this: its teleport was judged on where he LANDED, this
            -- one on how far he left.
            local nyn = s16(r16(r32(A.p1_obj) + OYPOS))
            if noob_min_y and nyn < noob_min_y then noob_min_y = nyn end
            -- SLAM CLIMB: three shots on the way up, to see whether the
            -- shadow is still under him or has been clipped out.
            if move_idx > 0 and MOVES[move_idx].name == "slam" and noob_y0_start then
                local climb = noob_y0_start - nyn
                if climb > 20 and not slam_snap20 then
                    slam_snap20 = true
                    -- WHAT IS NOOB ACTUALLY WEARING, and is there a trail?
                    local body = obj_frame(r32(A.p1_obj)) or "?"
                    local tn, tx, ty, tobj = find_shadow("NJREPVIC")
                    log("  climb20: noob frame=%s  trail=%s", body, tn or "NONE")
                    if tobj then
                        local np = r32(A.p1_obj)
                        log("     trail obj=%x pal=%04x z=%d at %d,%d",
                            tobj, r16(tobj+0x140), r32(tobj+0xc0), tx, ty)
                        log("     noob        pal=%04x z=%d at %d,%d",
                            r16(np+0x140), r32(np+0xc0),
                            s16(r16(np+0x90)), s16(r16(np+0xb0)))
                    end
                    snap("climb20")
                end
                if climb > 60 and not slam_snap60 then slam_snap60 = true; snap("climb60") end
                if climb > 110 and not slam_snap110 then slam_snap110 = true; snap("climb110") end
            end
            -- THE GHOST RING, which is a separate object from the ball and
            -- outlives it: find_shadow walks objlst for any non-fighter
            -- showing a GHOSTRING frame.  Sampled every tick because the ring
            -- is spawned by the VICTIM's reaction, not by the ball's proc, so
            -- there is no single moment to look at.
            if m.name == "ghost_kill" then
                -- HIS PALETTE, by identity (pal_id).  The flash swaps him onto
                -- another palette and back, and what matters is the one he is
                -- left wearing when it is all over.
                local vpal = pal_id(r32(A.p2_obj))
                if vpal then
                    if kill_pal0 == nil then kill_pal0 = vpal end
                    kill_pal_seen[vpal] = true
                    kill_pal_end = vpal
                end
                -- A ring at ANY point, not only after the round was decided:
                -- the ring now bails the moment winner_status moves, so it can
                -- be gone before the first post-decision sample and the control
                -- would read false on a build where everything worked.
                if find_shadow("GHOSTRING") then
                    kill_saw_ring = true
                    kill_ring_frame = kill_ring_frame or frame
                end
                -- 30 ticks into the ring, put Noob in jab range (he faces
                -- right, Jax is to his right) and let the jabs take the 1.
                if kill_ring_frame and not kill_step_frame and frame - kill_ring_frame >= 30
                   and (A.winner_status and r16(A.winner_status) or 0) == 0 then
                    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
                    local nx = jx - 55
                    w16(r32(A.p1_obj) + OXPOS, nx & 0xffff)
                    w32(r32(A.p1_obj) + OXVAL, (nx * 65536) & 0xffffffff)
                    kill_step_frame = frame
                    log("  [ghost_kill] ring up 30 ticks, bar %d: Noob stepped in to x=%d (jax x=%d)",
                        r16(A.p2_bar), nx, jx)
                end
                local ws = A.winner_status and r16(A.winner_status) or 0
                if ws ~= 0 then
                    ws_ticks = ws_ticks + 1
                    if find_shadow("GHOSTRING") then
                        -- Anything still drawn a good while after the round
                        -- was decided is the bug: the fade is 9 ticks.
                        if ws_ticks > 60 then ring_lingered = true end
                    end
                end
            end
            local rn, rx, ry, robj = find_shadow("GHOSTRING")
            if rn and rn ~= last_ring_frame then
                log("  ring frame @%d: %s", ring_ticks, rn)
                last_ring_frame = rn
            end
            if rn then
                ring_seen[rn] = true
                if ring_ticks == 20 or ring_ticks == 90 or ring_ticks == 160 then
                    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
                    local jy = s16(r16(r32(A.p2_obj) + OYPOS))
                    local ro = robj or 0
                    local jo = r32(A.p2_obj)
                    log("  ring @%d %s obj=%x", ring_ticks, rn, ro)
                    log("     ring xval=%d yval=%d xpos=%d ypos=%d flags=%04x pal=%04x z=%d",
                        r32(ro+0x80)//65536, r32(ro+0xa0)//65536, s16(r16(ro+0x90)),
                        s16(r16(ro+0xb0)), r16(ro+0xf0), r16(ro+0x140), r32(ro+0xc0))
                    log("     jax  xval=%d yval=%d xpos=%d ypos=%d flags=%04x pal=%04x z=%d",
                        r32(jo+0x80)//65536, r32(jo+0xa0)//65536, jx, jy,
                        r16(jo+0xf0), r16(jo+0x140), r32(jo+0xc0))
                    snap("ring_" .. ring_ticks)
                end
                local jyr = s16(r16(r32(A.p2_obj) + OYPOS))
                ring_ticks = ring_ticks + 1
            end
            -- Trace what Noob's own process/object is doing, so a move that
            -- never fires can be told apart from one that fires and draws
            -- nothing.  p_action changing at all means the handler ran.
            if A.p1_proc then
                local proc = r32(A.p1_proc)
                if proc ~= 0 then
                    local act = r16(proc + P_ACTION)
                    if act == 0x0507 then slam_saw_grab = true end
                    if A.gh_src and m.name == "slam" then
                        local src = r32(A.gh_src)
                        if src ~= 0 then
                            local n, drawn = r16(A.gh_n), 0
                            local g = r32(A.ghost_lst)
                            while g ~= 0 and drawn < 16 do drawn = drawn + 1; g = r32(g) end
                            ghost_armed = true
                            if drawn > ghost_max then ghost_max = drawn end
                            ghost_n = n
                        elseif ghost_armed then
                            ghost_disarmed = true
                        end
                    end
                    if act == 0x0507 and rel % 6 == 0 then
                        local vo, no = r32(A.p2_obj), r32(A.p1_obj)
                        log("  [carry rel=%3d] noob fliph=%d x=%d y=%d | victim fliph=%d x=%d y=%d",
                            rel, (r16(no + OFLAGS) >> B_FLIPH) & 1, s16(r16(no + OXPOS)), s16(r16(no + OYPOS)),
                            (r16(vo + OFLAGS) >> B_FLIPH) & 1, s16(r16(vo + OXPOS)), s16(r16(vo + OYPOS)))
                    end
                    if act ~= last_action then
                        local o = r32(A.p1_obj)
                        local fl = r16(o + OFLAGS)
                        log("  [%s rel=%3d] p_action %04x -> %04x  fliph=%d shape=%08x",
                            m.name, rel, last_action, act,
                            (fl >> B_FLIPH) & 1, r32(o + 0x1d0))
                        last_action = act
                    end
                end
            end
            if m.name == "ego_jump" then
                local vo = r32(A.p2_obj)
                if jump_y0 == nil then jump_y0 = s16(r16(vo + OYPOS)) end
                -- hold him in the air for the whole window
                w16(vo + OYPOS, (jump_y0 - 90) & 0xffff)
                local sn = find_shadow("NJWALK")
                if sn then jump_last_shadow = rel end
                -- and watch Noob come back out of the swipe
                if A.p1_proc then
                    local pr = r32(A.p1_proc)
                    if pr ~= 0 and r16(pr + P_ACTION) == 0x0303 then
                        jump_noob_back = true
                    end
                end
            end
            if m.name == "ego_juggle" then
                local hp = r16(A.p2_bar)
                local vx = s16(r16(r32(A.p2_obj) + OXPOS))
                if not jg_throw_frame and hp < jax_hp0 then
                    jg_throw_frame, jg_hp1 = frame, hp
                    log("  [ego_juggle] thrown at frame %d, bar %d, victim x=%d noob x=%d",
                        frame, hp, vx, s16(r16(r32(A.p1_obj) + OXPOS)))
                elseif jg_throw_frame and not jg_hit_frame and hp < jg_hp1 then
                    jg_hit_frame, jg_hit_x, jg_hit_dmg = frame, vx, jg_hp1 - hp
                    jg_nr = r16(A.f_norepell)
                    if JG_NEG then w16(A.f_norepell, 0x40) end
                    log("  [ego_juggle] KICKED at +%d for %d: victim x=%d y=%d noob x=%d y=%d f_norepell=%d",
                        frame - jg_throw_frame, jg_hp1 - hp, vx, s16(r16(r32(A.p2_obj) + OYPOS)),
                        s16(r16(r32(A.p1_obj) + OXPOS)), s16(r16(r32(A.p1_obj) + OYPOS)), jg_nr)
                    snap("ego_juggle_kick")
                elseif jg_hit_frame and frame - jg_hit_frame <= 40 then
                    local d = math.abs(vx - jg_hit_x)
                    if d > jg_travel then jg_travel = d end
                    if frame - jg_hit_frame <= 8 and d > jg_early then jg_early = d end
                    if (frame - jg_hit_frame) % 8 == 0 then
                        log("  [ego_juggle] +%2d after kick: victim x=%d y=%d  noob x=%d",
                            frame - jg_hit_frame, vx, s16(r16(r32(A.p2_obj) + OYPOS)),
                            s16(r16(r32(A.p1_obj) + OXPOS)))
                    end
                elseif jg_throw_frame and not jg_hit_frame and (frame - jg_throw_frame) % 6 == 0
                       and frame - jg_throw_frame <= 48 then
                    log("  [ego_juggle] +%2d: victim x=%d y=%d  noob x=%d y=%d act=%04x",
                        frame - jg_throw_frame, vx, s16(r16(r32(A.p2_obj) + OYPOS)),
                        s16(r16(r32(A.p1_obj) + OXPOS)), s16(r16(r32(A.p1_obj) + OYPOS)),
                        r16(r32(A.p1_proc) + P_ACTION))
                end
            end
            if m.name == "ego" or m.name == "ego_left" or m.name == "ego_close" then
                -- Film the FLIGHT: once his bar has dropped the throw has
                -- happened, so snap the next dozen ticks - that is the only
                -- window the flip is on screen.
                -- DID HE GO OVER NOOB?  The only honest test is whether his
                -- x crosses Noob's: thrown away he stays on his own side, and
                -- thrown over him the sign of (victim - noob) flips.  Height
                -- alone proves nothing, since a bounce goes up too.
                if r16(A.p2_bar) < jax_hp0 then
                    local nx = s16(r16(r32(A.p1_obj) + OXPOS))
                    local vx = s16(r16(r32(A.p2_obj) + OXPOS))
                    local vy = s16(r16(r32(A.p2_obj) + OYPOS))
                    local side = (vx >= nx) and 1 or -1
                    if cross_x0 == nil then cross_x0 = vx end
                    if math.abs(vx - cross_x0) > cross_travel then
                        cross_travel = math.abs(vx - cross_x0)
                    end
                    if cross_side0 == nil then
                        cross_side0, cross_y0 = side, vy
                        log("  [%s] throw begins: noob x=%d victim x=%d (victim %s of him)",
                            m.name, nx, vx, side > 0 and "RIGHT" or "LEFT")
                    end
                    cross_side_now = side
                    if side ~= cross_side0 then cross_crossed = true end
                    if cross_y0 and (cross_y0 - vy) > cross_peak then
                        cross_peak = cross_y0 - vy
                    end
                end
                if r16(A.p2_bar) < jax_hp0 and throw_snaps < 12 then
                    throw_snaps = throw_snaps + 1
                    if throw_snaps % 2 == 1 then snap("ego_thrown_" .. rel) end
                end
                local sn, sx = find_shadow("NJWALK")
                if sn then
                    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
                    local nx = s16(r16(r32(A.p1_obj) + OXPOS))
                    log("  [ego rel=%3d] shadow %s x=%d  jax x=%d  dist=%d  noob x=%d",
                        rel, sn, sx or -1, jx, math.abs(jx - (sx or 0)), nx)
                    log("                why=%04x romdist=%d",
                        A.debug5 and r32(A.debug5) or 0, A.debug6 and r32(A.debug6) or -1)
                end
            end
            local n, x, y = find_shadow(m.prefix)
            if m.name == "tele" then
                n = obj_frame(r32(A.p1_obj))
                if n and n:sub(1, #m.prefix) ~= m.prefix then n = nil end
            end
            if n then
                if next(seen_frames) == nil then
                    snap(m.name .. "_first")
                    first_x, first_y, first_rel = x, y, rel
                    -- Placement maths, so the DY constants can be tuned from
                    -- numbers instead of eyeballing screenshots.  NOOBSLIDE1
                    -- hangs 139px below its anchor, NOOBAIRKICK1 79px.
                    local gy = A.ground_y and s16(r16(A.ground_y)) or -1
                    local drop = (m.name == "slide") and 139 or 79
                    log("  spawn: shadow oypos=%d bottom=%d ground_y=%d  -> DY correction %+d",
                        y or -1, (y or 0) + drop, gy, gy - ((y or 0) + drop))
                end
                seen_frames[n] = true
                last_x = x or last_x
                if y and first_y then
                    local rise = first_y - y
                    if rise > best_rise then best_rise = rise end
                end
                -- Snapshot once the shadow has travelled clear of Noob; at the
                -- spawn frame it sits right on top of him and proves nothing.
                if first_rel then
                    if rel == first_rel + 10 then snap(m.name .. "_flight1") end
                    if rel == first_rel + 22 then snap(m.name .. "_flight2") end
                    if rel == first_rel + 34 then snap(m.name .. "_flight3") end
                end
            end
            if rel >= m.watch then finish_move() end
        end
    end

    for name, field in pairs(fields) do
        local on = false
        if name == "UI Select" then on = frame >= 5 and frame < 35
        elseif name == "Coin 1" then on = frame >= 700 and frame < 980 and frame % 80 < 20
        elseif name == "1 Player Start" then on = frame >= 1000 and frame < 1080
        elseif name == "P1 High Punch" and charsel_frame > 0 and fighting_frame == 0 then
            on = confirm_frame > 0 and frame >= confirm_frame and frame < confirm_frame + 45
        else
            on = move_pressed(name)
        end
        field:set_value(on and 1 or 0)
    end

    if not finished and frame > 12000 then finish(false, "global_timeout") end
end)
