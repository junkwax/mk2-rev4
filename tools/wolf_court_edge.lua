-- wolf_court_edge.lua - THE COURTYARD (MK1, Wolf only, curback 01Dh): where
-- does the camera stop on the right, and is the corner whole there?  MK1's
-- limit (634) shows sky through a gap where the right-hand spear guard's robe
-- meets the floor lip; make_mk1court.py's right_limit() pulls it in to the
-- last clean camera (doc/MK1_COURTYARD_GATES.md).  Plays a 1P game on the Wolf
-- build with curback held at 01Dh, then walks player 1 right with player 2
-- kept just ahead of him (oxpos written every frame), logs plane 1's worldtlx
-- and snapshots once the camera has stopped.  Judge the snapshot for
-- sky-blue (erase) pixels below plane 1's top, rows 162+.
-- Driven by run_wolf_boot_probe.ps1:
--   -Script wolf_court_edge.lua -Env WE_CURBACK=<curback> WE_WTLX=<worldtlx>
--   WE_P1=<p1_obj> WE_P2=<p2_obj> WE_P1BAR=<p1_bar> WE_P2BAR=<p2_bar> WE_EXPECT=<mk1c_right>
local LOG = os.getenv("WB_LOG")
local GSTATE = tonumber(os.getenv("WB_GSTATE"), 16)
local function env(n) return tonumber(os.getenv(n), 16) end
local CURBACK, WTLX, P1, P2 = env("WE_CURBACK"), env("WE_WTLX"), env("WE_P1"), env("WE_P2")
local P1BAR, P2BAR = env("WE_P1BAR"), env("WE_P2BAR")
local EXPECT = tonumber(os.getenv("WE_EXPECT"))
local OXPOS = 0x090

local f = nil
local function log(s)
    if not f then f = io.open(LOG, "w"); f:write("wolf_court_edge start\n") end
    f:write(s .. "\n"); f:flush()
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function field(name)
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[name] then return q.fields[name] end end
end
local F = { coin = field("Coin 1"), start = field("1 Player Start"), hp = field("P1 High Punch"),
            right = field("P1 Right") }

local frame, started, fight, sel = 0, false, nil, nil
local maxcam, still, lastcam, shot = 0, 0, nil, false
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    local gs = space:read_u16(GSTATE)
    if gs == 4 and not sel then sel = frame; log(("select at %d"):format(frame)) end
    local k = frame - 1500
    F.coin:set_value(((k >= 0 and k < 6) or (k >= 30 and k < 36)) and 1 or 0)
    F.start:set_value((k >= 120 and k < 126) and 1 or 0)
    F.hp:set_value((sel and frame >= sel + 300 and frame < sel + 306) and 1 or 0)
    if sel and gs ~= 2 and not fight then space:write_u16(CURBACK, 0x1D) end
    if gs == 2 and not fight then
        fight = frame
        log(("fight at %d, curback %02X"):format(frame, space:read_u16(CURBACK)))
    end
    if not fight then
        if frame > 9000 then log(("no fight by frame 9000 (gstate %d) - NO VERDICT"):format(gs)); f:close(); manager.machine:exit() end
        return
    end
    local rel = frame - fight
    space:write_u16(P1BAR, 0xA1); space:write_u16(P2BAR, 0xA1)
    F.right:set_value(rel < 900 and 1 or 0)
    local o1, o2 = space:read_u32(P1), space:read_u32(P2)
    if o1 ~= 0 and o2 ~= 0 then
        space:write_u16(o2 + OXPOS, space:read_u16(o1 + OXPOS) + 90)
    end
    local cam = space:read_u32(WTLX) >> 16
    if cam > maxcam then maxcam = cam end
    if cam == lastcam then still = still + 1 else still = 0 end
    lastcam = cam
    if rel % 60 == 0 then log(("fight +%d worldtlx %d"):format(rel, cam)) end
    if not shot and rel > 200 and still >= 60 then
        manager.machine.video:snapshot(); shot = true
        log(("SHOT at fight +%d, worldtlx %d (max %d)"):format(rel, cam, maxcam))
    end
    if shot and rel > 1000 or rel > 1500 then
        -- the scroller stops up to one step PAST right_edge (SCROLL_OVERSHOOT
        -- in make_mk1court.py), so the camera must land in limit..limit+9
        log(("max worldtlx %d, limit %d"):format(maxcam, EXPECT))
        log((shot and maxcam >= EXPECT and maxcam <= EXPECT + 9) and "PASS" or "FAIL")
        f:close(); manager.machine:exit()
    end
end)
