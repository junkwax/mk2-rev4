-- camera_scroll_probe.lua
--
-- Measures BGND.ASM's y-scroll controller (scrl6..scrla) in isolation.
--
-- The open bug is "uppercut an air-frozen victim and the camera misbehaves".
-- A frozen victim is just a process asleep for 080h ticks with no gravity, so
-- from the camera's point of view he is nothing more than a fighter parked at
-- a fixed height.  So park one -- by writing p2's oypos every frame -- sweep
-- that height through the band around the scroll barrier, and watch what
-- worldtly does.  No inputs, no move timing, no ice: just the controller.
--
-- The controller (BGND.ASM:341-408):
--     barrier      = worldtly + 40
--     if p1y <= barrier or p2y <= barrier -> scrl7 (scroll UP)
--         stop if worldtly <= ceiling_y - 010h        (scroll-up limit)
--         stop if |barrier - p1y| < 2 or |barrier - p2y| < 2   (jitter guard)
--         else scrolly = -018000h                     (-1.5 px/frame)
--     else
--         worldtly == ceiling_y -> stop
--         worldtly >  ceiling_y -> scrl8, snap to ceiling_y
--         worldtly <  ceiling_y -> scrolly = +018000h (+1.5 px/frame, down)
--
-- Rest barrier  = ceiling_y + 40.  Barrier at full scroll-up = ceiling_y + 24.
-- A victim parked between those two is the interesting case: scrolling up far
-- enough to clear him also drags the camera off ceiling_y, and the scroll-down
-- arm then pushes the barrier straight back onto him.
--
-- Judged per step: does worldtly SETTLE, or does it hunt?
--
-- Env: CAMPROBE_LOG
-- Usage: tools/run_camera_scroll_probe.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("CAMPROBE_LOG") or (ROOT .. "/tools/camera_scroll_probe.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[cam] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

-- ---------------------------------------------------------------- symbols
-- mk2.map holds TMS34010 BIT addresses, and MAME's tms34010 program space is
-- bit addressed, so they go in as-is (same convention as ai_anim_debug.lua).
-- Verified at fight start against the stage's own bgnd module constants.
local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state",
                     "p2_state", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view",
                     "winner_status", "battle_num", "map_position",
                     "worldtly", "scrolly", "ceiling_y", "ground_y" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s - results are worthless", n) end
end

local OYPOS = 0x0b0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local STAGE = 0                             -- Dead Pool
local STAGE_GROUND_Y, STAGE_CEILING_Y = 0xd8, 0xd8 - 0xe0   -- dedpool_mod

-- Heights to park the victim at, as offsets from ceiling_y.  40 = the resting
-- barrier, 24 = the barrier once the camera is scrolled all the way up.
local STEPS = { 80, 44, 40, 36, 32, 30, 28, 26, 24, 20, 12, 0, -20 }
local HOLD = 80                             -- frames per step
local SETTLE = 40                           -- ignore this many, measure the rest

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local step, step_start = 1, 0
local ceiling_y, ground_y, floor_y = 0, 0, 0
local samples, results, done = {}, {}, false
local wrote_last = nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function sety(p, y) local o = r32(p); if o ~= 0 then w16(o + OYPOS, y) end end

-- worldtly is 16.16; the integer half lives at +16 (that is what BGND reads).
local function wtly_int() return s16(r16(A.worldtly + 16)) end
local function wtly_frac() return r16(A.worldtly) end

local function cache_fields(fields)
    local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input field %s", n) end end
end
local fields = {}

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 1000 and (frame % 80) < 20
        end
        if name == "1 Player Start"  then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 and p1_confirm > 0 then
        if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
        if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
    end
    return false
end

local function finish()
    if done then return end
    done = true
    log("")
    log("ceiling_y=%d ground_y=%d  rest barrier=%d  full-scroll-up barrier=%d",
        ceiling_y, ground_y, ceiling_y + 40, ceiling_y - 0x10 + 40)
    log("scroll-up limit: worldtly may reach %d (ceiling_y - 010h)", ceiling_y - 0x10)
    log("")
    log("%-8s %-8s  %-18s %-7s %-6s  %s", "victim", "vs", "worldtly over last",
        "range", "flips", "verdict")
    log("%-8s %-8s  %-18s %-7s %-6s  %s", "oypos", "barrier", string.format("%d frames", HOLD - SETTLE),
        "", "", "")
    local hunting = 0
    for _, r in ipairs(results) do
        local verdict
        if r.range <= 1 then
            verdict = "settled"
        else
            verdict = "HUNTING"
            hunting = hunting + 1
        end
        log("%-8d %-8s  %-18s %-7d %-6d  %s", r.y,
            (r.y <= ceiling_y + 40) and "above" or "below",
            string.format("%d..%d", r.min, r.max), r.range, r.flips, verdict)
    end
    log("")
    if hunting == 0 then
        log("PASS camera: every parked height settled on a stable worldtly")
    else
        log("FAIL camera: %d of %d parked heights leave worldtly hunting",
            hunting, #results)
    end
    logfh:close(); manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields(fields)
        log("---- y-scroll controller response to a fighter parked in mid-air ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_REPTILE); w16(A.curback, STAGE)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING then w16(A.p2_state, 1) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; step_start = frame
        ceiling_y = s16(r16(A.ceiling_y))
        ground_y  = s16(r16(A.ground_y))
        floor_y   = gety(A.p2_obj) or 0
        log("fight start frame=%d  ceiling_y=%d ground_y=%d  victim standing oypos=%d",
            frame, ceiling_y, ground_y, floor_y)
        log("worldtly at rest = %d (frac %04x), scrolly = %d",
            wtly_int(), wtly_frac(), s32(r32(A.scrolly)))
        -- Address-convention check: if these do not match the stage's own
        -- bgnd module constants we are reading the wrong memory and every
        -- number below is noise.
        if ground_y ~= STAGE_GROUND_Y or ceiling_y ~= STAGE_CEILING_Y then
            log("FAIL setup: expected dedpool ground_y=%d ceiling_y=%d, read %d/%d "
                .. "- wrong stage or wrong address convention",
                STAGE_GROUND_Y, STAGE_CEILING_Y, ground_y, ceiling_y)
            finish(); return
        end
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    -- keep the round alive and both fighters idle
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    local target = ceiling_y + STEPS[step]
    local r = frame - step_start

    -- Did the game overwrite last frame's parked height?  If it does, the
    -- victim is not actually parked and the sweep proves nothing.
    local readback = gety(A.p2_obj)
    if wrote_last and readback ~= wrote_last and r > 1 then
        log("  step %d r=%3d: game moved the victim %d -> %d (parking not holding)",
            step, r, wrote_last, readback)
    end

    sety(A.p2_obj, target)
    wrote_last = target

    local w = wtly_int()
    local sc = s32(r32(A.scrolly))
    if r >= SETTLE then samples[#samples + 1] = { w = w, sc = sc } end
    if r % 8 == 0 or r < 6 then
        log("  y=%-5d r=%-3d worldtly=%-5d frac=%04x scrolly=%-9d barrier=%d %s",
            target, r, w, wtly_frac(), sc, w + 40,
            (target <= w + 40) and "victim ABOVE barrier" or "")
    end

    if r >= HOLD then
        local mn, mx, flips, prev = 1e9, -1e9, 0, nil
        for _, s in ipairs(samples) do
            if s.w < mn then mn = s.w end
            if s.w > mx then mx = s.w end
            local dir = (s.sc > 0 and 1) or (s.sc < 0 and -1) or 0
            if prev and dir ~= 0 and prev ~= 0 and dir ~= prev then flips = flips + 1 end
            if dir ~= 0 then prev = dir end
        end
        results[#results + 1] = { y = target, min = mn, max = mx, range = mx - mn, flips = flips }
        log("  == parked at %d: worldtly %d..%d (range %d), %d scroll-direction flips",
            target, mn, mx, mx - mn, flips)
        step = step + 1
        if step > #STEPS then finish(); return end
        step_start = frame; samples = {}; wrote_last = nil
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
