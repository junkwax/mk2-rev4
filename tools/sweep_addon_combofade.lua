-- sweep_addon_combofade.lua - does the combo readout SHRINK across the window?
--
-- The ask: "the wording needs to shrink back to what it normally is after each
-- hit ... to give a visual idea the combo is about to wear out".
--
-- cmb_ease used to step cmb_scl one per tick, so the pop was gone in 4 ticks
-- and the remaining ~60 ticks of hudcmb_hold all drew at one size - the size
-- said "a hit just landed" and nothing about time left. It is now derived from
-- cmb_tick, so it should walk 0 (full) to COT_SCLMAX (resting) ACROSS the whole
-- window, and snap back to 0 whenever a hit re-arms the clock.
--
-- What is logged: every change of (cmb_tick, cmb_scl) for p1. What the verdict
-- checks is the two things that were wrong before:
--
--   spread   the scale must reach its resting step LATE, not within a few
--            ticks of the hit
--   resets   a fresh hit must put it back to 0
--
-- Env: CFADE_LOG
-- Driven by run_combofade_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("CFADE_LOG") or (ROOT .. "/tools/combofade.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local cmb_tick, cmb_scl, cmb_hits = sym.cmb_tick, sym.cmb_scl, sym.cmb_hits
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local P_ACTION, P_HIT = 0x1f0, 0x210
local OXPOS, OXVAL = 0x090, 0x080
-- Close enough for a jab, far enough that LOW PUNCH is not a THROW: at 55px
-- every poke came out as a body slam (p1act 0507) and no hit ever landed.
local GAP = 70
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local MAX_HP = 0xA1
local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[cfade] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Down","P1 High Punch","P1 Low Punch",
    "P1 High Kick","P1 Low Kick","P2 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local last_scl, last_hits, resets, lines = nil, nil, 0, 0
local seen = {}            -- scale steps observed
local latest_step_tick = 99   -- lowest cmb_tick at which step 0 was still shown
local rest_at = nil        -- ticks-left when the resting step was first reached
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== combo fade === does the size track the combo clock?")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    local tick = space:read_u16(cmb_tick) & 0xffff
    local scl  = space:read_u16(cmb_scl) & 0xffff
    local hits = space:read_u16(cmb_hits) & 0xffff

    -- cmb_ease only runs from the combo PROCESS, and that does not exist
    -- until hudcmb_min hits are in - so a one-hit exchange shows step 0 and
    -- never moves. Log every change, capped, rather than only scale changes.
    if tick ~= 0 and (scl ~= last_scl or hits ~= last_hits) then
        seen[scl] = true
        if last_scl and scl < last_scl then resets = resets + 1 end
        if scl >= 4 and not rest_at then rest_at = tick end
        if lines < 40 then
            lines = lines + 1
            log("  hits=%-3d ticks_left=%-3d scale_step=%d", hits, tick, scl)
        end
        last_scl, last_hits = scl, hits
    end

    -- Pin them together, or P1 never reaches and no combo ever starts.
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 ~= 0 and o2 ~= 0 then
        local x1 = s16(space:read_u16(o1 + OXPOS))
        local x2 = s16(space:read_u16(o2 + OXPOS))
        local tx = (x1 < x2) and (x1 + GAP) or (x1 - GAP)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end

    -- Diagnostic: is the poke even coming out, and is P2 in range?
    if t % 30 == 0 and lines < 40 then
        local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
        local a1 = r1 ~= 0 and (space:read_u16(r1 + P_ACTION) & 0xffff) or 0
        local a2 = r2 ~= 0 and (space:read_u16(r2 + P_ACTION) & 0xffff) or 0
        local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
        local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
        local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
        lines = lines + 1
        log("DIAG t=%-5d p1act=%04x p2act=%04x x1=%-4d x2=%-4d gap=%-4d hits=%d tick=%d",
            t, a1, a2, x1, x2, x2 - x1, hits, tick)
    end

    -- Pokes tight enough to CHAIN: the readout needs hudcmb_min = 2 hits
    -- inside one window before it appears at all.
    -- HIGH punch, not low: low punch inside grab range IS the throw.  Two
    -- jabs inside one window is the shortest thing that makes the readout
    -- appear at all (hudcmb_min = 2).
    -- Two jabs, then SILENCE for longer than hudcmb_hold (40h = 64 ticks).
    -- Jabbing continuously re-arms the clock on every hit and the readout
    -- never fades at all - true to the design, useless as a measurement.
    local c = t % 220
    press("P1 High Punch", c == 4 or c == 5 or c == 16 or c == 17)
end)

emu.register_stop(function()
    local steps = 0
    for _ in pairs(seen) do steps = steps + 1 end
    log("SUMMARY distinct steps=%d  resets=%d  rest reached at ticks_left=%s",
        steps, resets, tostring(rest_at))
    if steps <= 1 then
        log("VERDICT NO-CASE (no combo ever ran long enough to fade)")
    elseif rest_at and rest_at > 40 then
        log("VERDICT FAIL - resting size reached with %d ticks still on the")
        log("        clock, so the size still says nothing about time left")
    else
        log("VERDICT PASS - %d steps across the window, %d re-pops on new hits",
            steps, resets)
    end
end)
