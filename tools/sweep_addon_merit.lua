-- sweep_addon_merit.lua - does the FASTER move actually win?
--
-- `firstactive` was validated in a mirror match, where both fighters throw the
-- same move and every exchange is an exact tie - so all that proved was the
-- parity tiebreak. The rule it is named for, "the attack whose active window
-- opened first wins", was never exercised at all.
--
-- This exercises it. Two moves with different measured startups, thrown on the
-- same frame:
--
--     low kick   startup 6   (FRAME_ADVANTAGE.md, do_lo_kick)
--     uppercut   startup 8   (do_uppercut)
--
-- so the low kick's window opens two ticks earlier and it should win - and it
-- should win from EITHER slot, which is the whole point. Run both ways round:
-- if the fast move wins as P1 and as P2, the rule is working and is not
-- slot-biased. If the winner follows the slot instead, it is not.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/merit.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, MAX_HP = 0x090, 0x080, 0xA1

-- FAST=1 puts the fast move (low kick) on P1; otherwise on P2.
local FAST_IS_P1 = (os.getenv("MERIT_FAST_P1") or "") == "1"
local DIST, TRIAL, HOLD, PRESS, REPS = 55, 91, 3, 16, 10

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[merit] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, n, cur, done = {}, 0, nil, false
local fastwins, slowwins, neither = 0, 0, 0
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(k, on) if fl[k] then fl[k]:set_value(on and 1 or 0) end end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        local want = { ["P1 Down"] = "1D", ["P1 High Punch"] = "1HP",
                       ["P1 Low Kick"] = "1LK", ["P1 Left"] = "1L",
                       ["P1 Right"] = "1R",
                       ["P2 Down"] = "2D", ["P2 High Punch"] = "2HP",
                       ["P2 Low Kick"] = "2LK", ["P2 Left"] = "2L",
                       ["P2 Right"] = "2R" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        log("=== merit === fast move (low kick, startup 6) on %s, "
            .. "slow (uppercut, startup 8) on %s",
            FAST_IS_P1 and "P1" or "P2", FAST_IS_P1 and "P2" or "P1")
    end
    if done then return end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 == 0 or o2 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end
    if t0 == nil then t0 = frame end

    local rel = (frame - t0) % TRIAL
    if rel == 0 then
        if cur then
            local h1 = space:read_u16(p1_bar) < MAX_HP
            local h2 = space:read_u16(p2_bar) < MAX_HP
            -- the LOSER takes the damage
            if h1 and not h2 then
                if FAST_IS_P1 then slowwins = slowwins + 1
                else fastwins = fastwins + 1 end
            elseif h2 and not h1 then
                if FAST_IS_P1 then fastwins = fastwins + 1
                else slowwins = slowwins + 1 end
            else neither = neither + 1 end
        end
        n = n + 1
        if n > REPS then
            done = true
            log("fast move won %d   slow move won %d   neither/both %d",
                fastwins, slowwins, neither)
            return
        end
        cur = true
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end

    local vx = s16(space:read_u16(right_edge)) - 100
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - DIST)
    space:write_u32(o1 + OXVAL, ((vx - DIST) << 16) & 0xffffffff)

    local btn = (rel >= PRESS and rel < PRESS + HOLD)
    local dn  = (rel >= PRESS - 6 and rel < PRESS + HOLD)
    for _, k in ipairs({ "1L", "1R", "2L", "2R" }) do press(k, false) end
    -- the uppercut needs Down held; the low kick is a bare button
    press("1D",  dn  and not FAST_IS_P1)
    press("2D",  dn  and FAST_IS_P1)
    press("1HP", btn and not FAST_IS_P1)
    press("2HP", btn and FAST_IS_P1)
    press("1LK", btn and FAST_IS_P1)
    press("2LK", btn and not FAST_IS_P1)
end)

emu.register_stop(function()
    if not done then
        log("fast move won %d   slow move won %d   neither/both %d",
            fastwins, slowwins, neither)
    end
    log("run_end")
end)
