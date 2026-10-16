-- sweep_addon_combogap.lua - how fast must a special motion be entered?
--
-- INPUT_MODEL.md found a 3.5x spread in special-move windows: 42 of 90 records
-- get 56 ticks (1.02 s) while the tightest seven get 16 (292 ms). A window is
-- not directly playable information though - what a player feels is the
-- largest GAP they can leave between inputs and still have the move come out.
--
-- This sweeps that gap. Raiden's lightning is `scom_lightning`, D then F, on
-- the 16-tick window - one of the tightest in the game. D at t=0, F at t=G,
-- LP two ticks after F; G is swept and each value tried three times.
-- LP, not HP: the trigger is `rd_lo_punch`. A first run pressed HP and
-- returned 0/3 at every gap, which reads like a brutally tight window
-- and is actually the wrong button - the same trap the throw rig hit.
--
-- Both fighters are pinned 150 px apart, past the reach of any normal (a high
-- punch measured 0 damage at 130), so damage can only be the bolt.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/combogap.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, MAX_HP = 0x090, 0x080, 0xA1

local GAPS = { 2, 4, 6, 8, 10, 12, 14, 16, 18 }
local REPS = 3
local DIST, TRIAL, HOLD, START = 150, 130, 3, 10

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[gap] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
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
                       ["P1 Down"] = "D", ["P1 High Punch"] = "HP" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        log("=== combo gap === F at 0, F at G, HP at G+2 (spit, 24 ticks)")
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
        if cur then hits = hits + (cur.hit and 1 or 0) end
        rep = rep + 1
        if rep > REPS then
            if idx > 0 then
                log("G=%-3d spit came out %d/%d", GAPS[idx], hits, REPS)
            end
            hits, rep = 0, 1
            idx = idx + 1
            if idx > #GAPS then done = true; log("cases_done"); return end
        end
        if idx == 0 then idx = 1 end
        cur = { g = GAPS[idx], hit = false }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end

    local vx = s16(space:read_u16(right_edge)) - 60
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o1 + OXVAL, ((vx - DIST) << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - DIST)

    local g = cur.g
    press("L", false)
    press("D", false)
    -- F, F (a double tap of one direction, not a roll) then HP.
    press("R",  (rel >= START and rel < START + HOLD)
             or (rel >= START + g and rel < START + g + HOLD))
    press("HP", rel >= START + g + 2 and rel < START + g + 2 + HOLD)

    if space:read_u16(p2_bar) < MAX_HP then cur.hit = true end
end)

emu.register_stop(function()
    if cur and not done and idx > 0 then
        hits = hits + (cur.hit and 1 or 0)
        log("G=%-3d spit came out %d/%d", GAPS[idx], hits, rep)
    end
    log("run_end")
end)
