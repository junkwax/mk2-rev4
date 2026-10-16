-- arena_haze_test.lua - KAHN'S ARENA per-line heat haze (sky_rows): only the
-- sky moves, what it costs, and whether it ever falls back.
--
-- sky_rows (MKDISP.ASM) draws the arena's sky - baklst7, arena6BMOD - one
-- scanline at a time from data/ARNSKY.BIN, each line at its own x.  The dpytap
-- shimmer before it sheared Kahn's staff, the medallions and the pagoda roofs;
-- this rig proves the new one cannot, by construction rather than by eye.
--
-- LIVE    the fight runs normally for LIVE_N frames.  Per frame: frames drawn
--         as lines (skr_ran) and frames that FELL BACK to the plain blocks
--         (skr_plain - alternating the two would read as flicker), lines queued,
--         process-pass overload, dmaq_late / dmaq_lost / dmaq_over, and the
--         queue high-water deep_dmaq.  HAZE_OFF=1 holds f_skyrows_off = 1 so
--         the same scene draws the plain blocks: the A/B.  Snapshots every
--         GIF_GAP frames.
-- FREEZE  every process frozen, nothing animates.  tick still runs under a
--         frozen scene, so the haze would not hold still: the comparisons use
--         f_skyrows_off modes 2 (every line at skr_fixdx) and 3 (alternating).
--           off_a, off_b     plain blocks, twice          (the scene is still)
--           shift_p/_m       the 15 sky blocks moved +/-40 px by their own
--                            oxval, plain                (the references)
--           rows_0           every line at 0             (== plain, exactly)
--           rows_p           every line +40              (== shift_p exactly)
--           rows_alt         even lines +40, odd -40     (line by line)
--         tmp/arena_haze/compare_rows.py checks them.
-- BAND    HAZE_BAND=1: the scene frozen but the haze LIVE - the one thing the
--         FREEZE gates cannot show, because they pin the offset by hand.
--         BAND_N consecutive frames, nothing pinned: tick advances under a
--         frozen scene, so the only thing that moves is the haze, and a row
--         identical in every shot is one the envelope leaves alone.  The
--         plain blocks are no use as a reference - the whole plane rests
--         SKR_AMP px left of its limit, so every sky row would read as moved.
--         tools/arena_haze_band_check.py reads the envelope back off the
--         screen and checks it against arena_sky_haze (src/BGND.ASM).
--
-- env: HAZE_OFF, HAZE_P1, HAZE_P2, HAZE_BAND, HAZE_LOG, MK2_ROOT
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local OFF = os.getenv("HAZE_OFF") == "1"
local CAMTEST = os.getenv("HAZE_CAMTEST") == "1"   -- the ripple must not depend on camera y
local BAND = os.getenv("HAZE_BAND") == "1"         -- which rows the envelope actually moves
local P1 = tonumber(os.getenv("HAZE_P1") or "8")
local P2 = tonumber(os.getenv("HAZE_P2") or "10")
local STAGE = 8
local LOG = os.getenv("HAZE_LOG") or (ROOT .. "/tools/arena_haze_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[haze] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local S = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local function sym(n) return assert(S[n], "missing map symbol " .. n) end

local A = {}
for _, n in ipairs({ "gstate", "curback", "map_position", "battle_num", "p1_char", "p2_char",
    "p1_state", "p2_state", "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view", "winner_status",
    "f_skyrows_off", "skr_fixdx", "skr_ran", "skr_plain", "skr_lines", "overload",
    "dmaq_late", "dmaq_lost", "dmaq_over", "deep_dmaq", "active", "baklst7", "tick", "worldtly" }) do A[n] = sym(n) end

local GS_PSEL, GS_FIGHTING, MAXBAR = 4, 2, 0xa1
local O_NEXT, O_OXVAL, O_OXPOS = 0x000, 0x080, 0x090
local P_NEXT, P_TIME = 0x000, 0x030
local LIVE_AT, LIVE_N, GIF_GAP, GIF_SHOTS = 90, 360, 2, 32
local SETTLE, SHIFT = 6, 40

local frame, space, fields = 0, nil, {}
local charsel, fighting, confirm = 0, 0, 0
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting == 0 then
        return (name == "P1 High Punch" or name == "P2 High Punch") and confirm > 0
               and frame >= confirm and frame < confirm + 40
    end
    return false
end

local function finish(verdict)
    if finished then return end
    finished = true
    log("RESULT %s", verdict)
    manager.machine:exit()
end

local snaps = 0
local function snap(label)
    manager.machine.video:snapshot()
    log("SNAP %04d %s", snaps, label)
    snaps = snaps + 1
end

-- ---------------------------------------------------------------- live
local L = { frames = 0, over_max = 0, lost_max = 0, lines_min = 1e9, lines_max = 0 }

local function live_frame(rel)
    if OFF then w16(A.f_skyrows_off, 1) end
    if rel == 0 then
        L.ran0, L.plain0 = r16(A.skr_ran), r16(A.skr_plain)
        L.late0, L.over0, L.deep0 = r16(A.dmaq_late), r16(A.dmaq_over), r16(A.deep_dmaq)
        L.prev_ran, L.prev_plain = L.ran0, L.plain0
        L.flips = 0
        log("LIVE start off=%s mode=%d", tostring(OFF), r16(A.f_skyrows_off))
    end
    L.frames = L.frames + 1
    local ran, plain = r16(A.skr_ran), r16(A.skr_plain)
    if ran ~= L.prev_ran then
        local n = r16(A.skr_lines)
        if n < L.lines_min then L.lines_min = n end
        if n > L.lines_max then L.lines_max = n end
        if L.last == "plain" then L.flips = L.flips + 1 end
        L.last = "rows"
    elseif plain ~= L.prev_plain then
        if L.last == "rows" then L.flips = L.flips + 1 end
        L.last = "plain"
    end
    L.prev_ran, L.prev_plain = ran, plain
    local ov = r16(A.overload); if ov > L.over_max then L.over_max = ov end
    local lost = r16(A.dmaq_lost); if lost > L.lost_max then L.lost_max = lost end
    if rel % GIF_GAP == 0 and rel // GIF_GAP < GIF_SHOTS then snap(string.format("live rel=%d", rel)) end
end

local function live_report()
    log("LIVE frames=%d rows=+%d fallback=+%d flips=%d lines=%d..%d overload_max=%d "
        .. "dmaq_late=+%d dmaq_over=+%d dmaq_lost_max=%d deep_dmaq=%d cells (was %d)",
        L.frames, r16(A.skr_ran) - L.ran0, r16(A.skr_plain) - L.plain0, L.flips,
        L.lines_min == 1e9 and 0 or L.lines_min, L.lines_max, L.over_max,
        r16(A.dmaq_late) - L.late0, r16(A.dmaq_over) - L.over0, L.lost_max,
        r16(A.deep_dmaq) // 6, L.deep0 // 6)
end

-- ---------------------------------------------------------------- freeze
local frozen, sky = {}, {}
local function freeze_all()
    local p, guard = r32(A.active), 0
    while p ~= 0 and guard < 256 do
        frozen[#frozen + 1] = { p = p, t = r16(p + P_TIME) }
        w16(p + P_TIME, 0x7fff)
        p = r32(p + P_NEXT); guard = guard + 1
    end
    log("FROZE %d processes", #frozen)
end
local function thaw_all() for _, f in ipairs(frozen) do w16(f.p + P_TIME, f.t) end end
local function sky_blocks()
    local o, guard = r32(A.baklst7), 0
    while o ~= 0 and guard < 64 do
        sky[#sky + 1] = { o = o, v = r32(o + O_OXVAL), x = r16(o + O_OXPOS) }
        o = r32(o + O_NEXT); guard = guard + 1
    end
    log("SKY baklst7 holds %d objects", #sky)
end
local function sky_shift(dx)
    for _, b in ipairs(sky) do
        w32(b.o + O_OXVAL, b.v + (dx << 16)); w16(b.o + O_OXPOS, b.x + dx)
    end
end

local steps, T = {}, 0
local function at(t, fn) steps[#steps + 1] = { t = t, fn = fn } end
local function step(action, label)
    T = T + SETTLE
    at(T - SETTLE, action)
    at(T, function() snap(label) end)
end
local function mode(m, dx) w16(A.skr_fixdx, dx or 0); w16(A.f_skyrows_off, m) end

-- CAMTEST: the haze held still by pinning tick, captured against the plain sky
-- at the camera's height and again 8 lines higher.  compare_rows.py --camera
-- measures each line's offset per WORLD row: both heights must agree.
local BAND_N = 16

local hold_tick = nil
if BAND then
    -- No reference shot and nothing pinned: the still rows ARE the reference.
    -- The plain blocks are no use as one - the whole plane rests SKR_AMP px
    -- left of its scroll limit, so a still row under the live haze is not
    -- where the ordinary draw puts it and every row of the sky would read as
    -- moved.  A row that is identical in all BAND_N shots is one the envelope
    -- leaves alone; tick advances under the frozen scene, so any row the
    -- envelope moves has swept its wave by the last of them.
    at(0, freeze_all)
    at(4, function() mode(0); log("BAND live haze, %d shots", BAND_N) end)
    for i = 0, BAND_N - 1 do
        at(14 + i, function() snap(string.format("band_%02d", i)) end)
    end
    at(14 + BAND_N + 2, function()
        mode(0); thaw_all()
        finish(string.format("band snaps=%d", snaps))
    end)
elseif CAMTEST then
    local function cam(label)
        return function() log("CAM %s worldty=%d", label, (r32(A.worldtly) >> 16) & 0xffff) end
    end
    at(0, function() freeze_all(); hold_tick = r16(A.tick) end)
    T = 6
    step(function() mode(1); cam("0")() end, "plain_c0")
    step(function() mode(0) end, "haze_c0")
    step(function() w32(A.worldtly, r32(A.worldtly) - (8 << 16)); mode(1); cam("up8")() end, "plain_c8")
    step(function() mode(0) end, "haze_c8")
    at(T + 2, function()
        w32(A.worldtly, r32(A.worldtly) + (8 << 16)); hold_tick = nil; thaw_all()
        finish(string.format("camtest snaps=%d", snaps))
    end)
else
at(0, freeze_all)
at(4, sky_blocks)
T = 6
step(function() mode(1) end, "off_a")
step(function() end, "off_b")
step(function() sky_shift(SHIFT) end, "shift_p")
step(function() sky_shift(-SHIFT) end, "shift_m")
step(function() sky_shift(0); mode(2, 0) end, "rows_0")
step(function() mode(2, SHIFT) end, "rows_p")
step(function() mode(3, SHIFT) end, "rows_alt")
at(T + 2, function()
    mode(0); thaw_all()
    finish(string.format("snaps=%d", snaps))
end)
end

local freeze_frame = 0

-- ---------------------------------------------------------------- main
emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("start off=%s p1=%d p2=%d", tostring(OFF), P1, P2)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space or finished then return end
    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel == 0 then charsel = frame end
    if charsel > 0 and fighting == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, P1); w16(A.p2_char, P2)
        w16(A.curback, STAGE); w16(A.map_position, 0); w16(A.battle_num, 1)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fighting == 0 then
        fighting = frame
        log("FIGHT frame=%d curback=%d", frame, r16(A.curback))
    end
    if fighting == 0 then
        if frame > 7000 then finish("ERROR never reached a fight") end
        return
    end
    w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
    w16(A.p1_bar_view, MAXBAR); w16(A.p2_bar_view, MAXBAR)
    w16(A.winner_status, 0)

    local rel = frame - fighting
    if rel >= LIVE_AT and rel < LIVE_AT + LIVE_N then
        live_frame(rel - LIVE_AT)
    elseif rel == LIVE_AT + LIVE_N then
        live_report()
        if OFF then finish("live-off") return end
        freeze_frame = frame
    end
    if hold_tick then w16(A.tick, hold_tick) end
    if freeze_frame > 0 then
        local t = frame - freeze_frame
        for _, s in ipairs(steps) do if s.t == t then s.fn() end end
    end
end)

emu.register_stop(function() if logfh then logfh:close() end end)
