-- wolf_pit3_wall_check.lua - THE PIT III (curback 22h, Wolf): the fighters stop
-- short of Shao Kahn's throne, and the camera still pans over to show it.
--
-- 2-player fight forced onto the stage.  Both players WALK right (no parking -
-- the clamp under test is gravity_n_bounds, which a written oxpos would race)
-- for WALK frames, then walk back left for BACK frames.  Every frame it checks
-- both fighters are on screen; at the end of the walk it snapshots (Kahn,
-- the fighters at the wall, their shadows on the deck) and asserts:
--   max fighter x <= P3W_WALL (984, up3_wall in UMK3PIT3.ASM)
--   the camera panned past the fighters' scroll limit to >= P3W_CAM_MIN
--   the camera never went past cam_rmax (+ one scroll step)
--   on the walk back the camera returns inside right_edge
-- P3W_NOWALL=1 is the control for the OLD ROM: expects a fighter past the wall.
-- (WALL+2: gravity_n_bounds clamps before that tick's velocity lands, so a
-- fighter walking into any wall reads 1px past it for a frame - stock.)
-- Env: WS_MAP (abs path to the Wolf MK2.MAP).  Driven by run_wolf_boot_probe.ps1.
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_pit3_wall_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "curback", "p1_bar", "p2_bar",
                    "worldtlx", "right_edge", "cam_rmax", "illop_count", "shad_hi", "shad_lo", "up3_kahn_lst", "baklst3"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxpos = 0x090 }
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch",
               "P1 Left", "P1 Right", "P2 Left", "P2 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local WALL = tonumber(os.getenv("P3W_WALL") or "984")
local CAM_MIN = tonumber(os.getenv("P3W_CAM_MIN") or "760")
local NOWALL = os.getenv("P3W_NOWALL") == "1"
local WALK, BACK = 600, 300
local frame, started, sel, fight, confirm = 0, false, nil, nil, nil
local maxx, maxcam, offscreen, backcam = -9999, -9999, 0, nil
local domes = {}          -- baklst3 object -> {distinct art seen}
local function watch_domes()
    local o, n = r32(A.baklst3), 0
    while o ~= 0 and n < 8 do
        local seen = domes[o] or {}
        seen[r32(o + 0x1a0)] = true
        if r32(o + 0x180) ~= 0x04000400 then domes_unscaled = (domes_unscaled or 0) + 1 end
        domes[o] = seen
        o = r32(o); n = n + 1
    end
end
local function finish(ok, why)
    log("%s: %s", ok and "PASS" or "FAIL", why); f:close(); manager.machine:exit()
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0x22)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then
            fight = frame
            log("fight at %d, curback %02X right_edge %d cam_rmax %d shad %d/%d", frame, r16(A.curback),
                s16(r16(A.right_edge)), s16(r16(A.cam_rmax)), r16(A.shad_hi), r16(A.shad_lo))
        end
        if frame > 12000 then finish(false, "no fight - NO VERDICT") end
        return
    end
    if gs ~= 2 then return end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    local rel = frame - fight
    if rel < 60 then return end
    watch_domes()
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    local x1, x2 = s16(r16(p1 + O.oxpos)), s16(r16(p2 + O.oxpos))
    local cam = s16(r16(A.worldtlx + 16))
    for _, x in ipairs({x1, x2}) do
        if x < cam or x > cam + 399 then offscreen = offscreen + 1 end
    end
    if rel < 60 + WALK then
        F["P1 Right"]:set_value(1); F["P2 Right"]:set_value(1)
        maxx = math.max(maxx, x1, x2); maxcam = math.max(maxcam, cam)
        if rel % 100 == 0 then log("walk %d: p1 %d p2 %d cam %d", rel, x1, x2, cam) end
        if rel == 61 then manager.machine.video:snapshot() end      -- the round's opening view
        if rel == 60 + WALK - 1 then
            manager.machine.video:snapshot()
            log("at the wall: p1 %d p2 %d cam %d (max x %d, max cam %d)", x1, x2, cam, maxx, maxcam)
            local o, n = r32(A.up3_kahn_lst), 0
            while o ~= 0 and n < 8 do
                log("  kahn obj %08X: x %d y %d flags %04X size %dx%d img %08X%s", o, s16(r16(o + 0x090)),
                    s16(r16(o + 0x0b0)), r16(o + 0x0f0), r16(o + 0x120), r16(o + 0x130), r32(o + 0x1a0),
                    r16(o + 0x120) == 24 and "  <- SHASITLEG (24x48)" or "")
                o = r32(o); n = n + 1
            end
        end
        return
    end
    if rel < 60 + WALK + BACK then
        F["P1 Left"]:set_value(1); F["P2 Left"]:set_value(1)
        if rel == 60 + WALK + BACK - 1 then
            backcam = cam
            manager.machine.video:snapshot()
            log("walked back: p1 %d p2 %d cam %d", x1, x2, cam)
        end
        return
    end
    local redge, rmax = s16(r16(A.right_edge)), s16(r16(A.cam_rmax))
    local nd, spun = 0, 0
    for o, seen in pairs(domes) do
        local k = 0
        for _ in pairs(seen) do k = k + 1 end
        nd = nd + 1
        if k == 6 then spun = spun + 1 end
        if k ~= 6 and k ~= 1 then return finish(false, string.format("plane-3 object %08X showed %d frames (6 or 1)", o, k)) end
        log("  plane-3 object %08X: %d distinct frames", o, k)
    end
    log("illop_count %d, offscreen fighter-frames %d", r16(A.illop_count), offscreen)
    if NOWALL then
        finish(maxx > WALL, string.format("control: max x %d %s wall %d", maxx, maxx > WALL and ">" or "<=", WALL))
        return
    end
    if maxx > WALL + 2 then return finish(false, string.format("a fighter reached x %d, past the wall %d", maxx, WALL)) end
    if maxcam < CAM_MIN then return finish(false, string.format("camera only reached %d (< %d): throne not shown", maxcam, CAM_MIN)) end
    if maxcam > rmax + 10 then return finish(false, string.format("camera reached %d, past cam_rmax %d", maxcam, rmax)) end
    if offscreen > 0 then return finish(false, string.format("%d fighter-frames off screen", offscreen)) end
    local still = nd - spun
    if domes_unscaled then return finish(false, string.format("%d plane-3 object-frames not at oscale 04000400h (1/4)", domes_unscaled)) end
    if nd ~= 6 or spun ~= 2 or still ~= 4 then
        return finish(false, string.format("plane 3: %d objects, %d spinning through 6 frames, %d still (want 6: 2 domes + 4 cage halves)", nd, spun, still))
    end
    if backcam > redge then return finish(false, string.format("camera stayed at %d after the walk back (right_edge %d)", backcam, redge)) end
    finish(true, string.format("2 lanterns on plane 3 (dome spinning over its cage, all 1/4); max x %d <= %d, camera panned to %d (right_edge %d, cam_rmax %d), back to %d",
        maxx, WALL, maxcam, redge, rmax, backcam))
end)
