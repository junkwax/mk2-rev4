-- sweep_addon_twobtn.lua - how simultaneous does "LP+HP" have to be?
--
-- Kitana's fan throw and Reptile's forceball are F,F plus BOTH punch buttons
-- together. `two_button_check` (MOVES.ASM) looks back in the button queue for
-- the partner button and rejects it if more than 2 ticks separate the two -
-- 37 ms, which is a hard ask for a human hand.
--
-- This sweeps the separation S between the two presses and records whether the
-- move actually came out. Both fighters are pinned 150 px apart, well past the
-- range of any normal (the behaviour cases measured a high punch doing zero at
-- 130), so DAMAGE at that distance can only be the projectile - no action
-- constant needed and no chance of scoring a stray poke as a success.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/twobtn.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p2_proc = sym.p2_proc
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, MAX_HP = 0x090, 0x080, 0xA1
local P_ACTION, ACT_STANCE = 0x1f0, 0x0303

local SEPS = { 0, 1, 2, 3, 4, 5, 6, 8 }
local REPS = 3                     -- each separation tried this many times
-- TRIAL 160, not 120: the fan throw has its own 2-second cooldown
-- (`l_throw_fan` / `cmpi 040h*2` in the dispatch), and at 120 ticks
-- (2.19 s) a trial could start inside it - which showed up as 2/3
-- and 1/3 at separations that plainly work.
local DIST, TRIAL, HOLD = 150, 160, 2
local F1, F2, BTN = 6, 14, 26      -- forward tap, forward tap, first button

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[2btn] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, idx, rep, cur, done, hits = {}, 0, 0, nil, false, 0
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on) if fl[n] then fl[n]:set_value(on and 1 or 0) end end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        local want = { ["P1 Right"] = "R", ["P1 Left"] = "L",
                       ["P1 High Punch"] = "HP", ["P1 Low Punch"] = "LP" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        log("=== two-button separation === F,F then HP, then LP S ticks later")
    end
    if done then return end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r2 = space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r2 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end
    if t0 == nil then t0 = frame end

    local rel = (frame - t0) % TRIAL
    if rel == 0 then
        if cur then hits = hits + (cur.hit and 1 or 0) end
        rep = rep + 1
        if rep > REPS then
            if idx > 0 then
                log("S=%-2d fan came out %d/%d", SEPS[idx], hits, REPS)
            end
            hits, rep = 0, 1
            idx = idx + 1
            if idx > #SEPS then done = true; log("cases_done"); return end
        end
        if idx == 0 then idx = 1 end
        cur = { s = SEPS[idx], hit = false }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end

    local vx = s16(space:read_u16(right_edge)) - 60
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o1 + OXVAL, ((vx - DIST) << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - DIST)

    -- F,F as two clean taps, then HP, then LP S ticks after it. HP first so
    -- LP is the CURRENT press and HP the one two_button_check looks back for,
    -- which is the direction fn1_lo_punch actually tests.
    press("L", false)
    press("R", (rel >= F1 and rel < F1 + 3) or (rel >= F2 and rel < F2 + 3))
    press("HP", rel >= BTN and rel < BTN + HOLD)
    press("LP", rel >= BTN + cur.s and rel < BTN + cur.s + HOLD)

    if space:read_u16(p2_bar) < MAX_HP then cur.hit = true end
end)

emu.register_stop(function()
    if cur and not done and idx > 0 then
        hits = hits + (cur.hit and 1 or 0)
        log("S=%-2d fan came out %d/%d", SEPS[idx], hits, rep)
    end
    log("run_end")
end)
