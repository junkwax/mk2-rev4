-- sweep_addon_hikick.lua - map the high kick's real connect band.
--
-- Chasing a play report: a high kick that visibly reached the opponent and did
-- nothing at all.
--
-- The suspicion is a gap between two mechanisms that are each individually
-- sensible. `knee_check` (JOY.ASM) converts a high kick into a knee whenever
-- the opponent is within 40h = 64 px, which is what normally stops anyone
-- throwing a high kick from inside its own reach - Baraka's box is
-- oxpos+23..+83, so at point blank there is nothing to hit with. BUT
-- knee_check bails out early if the opponent is AIRBORNE:
--
--     calla is_he_airborn
--     jrc   local_rets        ; yes, dont knee
--
-- so against a jumping opponent the high kick comes out at any range,
-- including ranges where its box cannot reach. That would be a whiff that
-- looks exactly like a hit.
--
-- This sweeps distance and records BOTH whether damage happened and which
-- action actually came out, because "the high kick missed" and "it was a knee
-- all along" look identical from the damage alone.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/hikick.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, OYVAL, MAX_HP = 0x090, 0x080, 0x0a0, 0xA1
local P_ACTION, ACT_STANCE = 0x1f0, 0x0303
local ACT_HIKICK, ACT_KNEE = 0x0103, 0x010f

-- Fine sweep across the edge: 85 connected and 95 did not, and the
-- question is where the BOX stops relative to where the ART still
-- visibly overlaps the opponent.
local DISTS = { 104, 108, 112, 115, 118, 122, 126, 130, 134, 140 }
-- AIR=1 launches the dummy before the kick, which is the case knee_check
-- deliberately exempts.
local AIR = (os.getenv("HK_AIR") or "") == "1"
local DIST_N, TRIAL, HOLD, PRESS = #DISTS, 110, 3, 20

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[hk] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, idx, cur, done = {}, 0, nil, false
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
                       ["P1 Down"] = "D", ["P1 High Kick"] = "HK" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        log("=== high kick band === dummy %s",
            AIR and "AIRBORNE (knee_check exempt)" or "standing")
    end
    if done then return end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1 = space:read_u32(p1_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end
    if t0 == nil then t0 = frame end

    local rel = (frame - t0) % TRIAL
    if rel == 0 then
        if cur then
            log("d=%-4d dmg=%-3d action=%s", cur.d, cur.dmg,
                (cur.act == ACT_HIKICK) and "high kick"
                or (cur.act == ACT_KNEE) and "KNEE"
                or string.format("%04xh", cur.act or 0))
        end
        idx = idx + 1
        if idx > DIST_N then done = true; log("cases_done"); return end
        cur = { d = DISTS[idx], dmg = 0, act = 0 }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end

    local vx = s16(space:read_u16(right_edge)) - 90
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - cur.d)
    space:write_u32(o1 + OXVAL, ((vx - cur.d) << 16) & 0xffffffff)

    -- hold the dummy off the floor for the airborne case: a real upward
    -- velocity, so is_he_airborn sees what it expects rather than a fighter
    -- teleported into the air with no motion
    if AIR and rel >= PRESS - 12 and rel < PRESS + 20 then
        space:write_u32(o2 + OYVAL, 0xFFF80000)
    end

    press("L", false); press("R", false); press("D", false)
    press("HK", rel >= PRESS and rel < PRESS + HOLD)

    local a = space:read_u16(r1 + P_ACTION)
    if cur.act == 0 and a ~= ACT_STANCE and a ~= 0 then cur.act = a end
    local lost = MAX_HP - space:read_u16(p2_bar)
    if lost > cur.dmg then cur.dmg = lost end
end)

emu.register_stop(function()
    if cur and not done then
        log("d=%-4d dmg=%-3d action=%04xh", cur.d, cur.dmg, cur.act or 0)
    end
    log("run_end")
end)
