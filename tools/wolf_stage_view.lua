-- wolf_stage_view.lua - park the camera on a Wolf stage and snapshot it.
-- A 2-player fight forced onto WV_STAGE (hex curback, default 1Fh), bars
-- pinned; for each world x in WV_STOPS (comma list) both fighters are parked
-- there for 150 frames so the scroller drags the camera over, then a snapshot
-- and every plane's worldtlx are logged.  For checking a stage against
-- tools/make_umk3lair.py --preview <the logged worldtlx>.
-- Env: WS_MAP (tmp/wolf/src/MK2.MAP), WV_STAGE, WV_STOPS, WV_DX (spread, 40).
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_sonya_specials start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
                    "curback", "illop_count", "p1_bar", "p2_bar", "worldtlx", "round_num", "worldtlx2", "worldtlx3", "worldtlx4", "worldtlx5", "worldtlx6", "worldtlx7", "worldtlx8", "f_skyrows_off", "skr_fixdx", "skr_ran", "skr_plain", "skr_lines"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxval = 0x080, oxpos = 0x090, ochar = 0x1f0 }
local P = { action = 0x1f0 }
local TRIALS = tonumber(os.getenv("WS_TRIALS") or "3")
local ACT_LEGGRAB, ACT_BIKE = 0x0124, 0x0204
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 Block", "P1 Down", "P1 Left", "P1 Right", "P1 High Kick"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end




local STAGE = tonumber(os.getenv("WV_STAGE") or "1f", 16)
local STOPS = {}
for v in (os.getenv("WV_STOPS") or "100,600,1100"):gmatch("[^,]+") do STOPS[#STOPS + 1] = tonumber(v) end
local HOLD = 150
local DX = tonumber(os.getenv("WV_DX") or "40")   -- each fighter this far either side of the stop
-- WV_SKR=m1,m2,...: f_skyrows_off per stop (sky_rows, MKDISP.ASM): 0 haze,
-- 1 plain blocks, 2 every line at skr_fixdx (0 = the offset-0 gate)
local SKR = {}
for v in (os.getenv("WV_SKR") or ""):gmatch("[^,]+") do SKR[#SKR + 1] = tonumber(v) end
local frame, started, sel, fight, confirm = 0, false, nil, nil, nil
local function wx(a) return s16(r16(a + 16)) end
local function park(x)
    for k, o in ipairs({r32(A.p1_obj), r32(A.p2_obj)}) do
        if o ~= 0 then
            local px = x + (k == 1 and -DX or DX)
            w16(o + O.oxpos, px); w32(o + O.oxval, (px & 0xffff) << 16)
        end
    end
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start stage %02X", STAGE)
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
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, STAGE)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; log("fight at %d, curback %02X", frame, r16(A.curback)) end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    local rel = frame - fight
    local k = rel // HOLD + 1
    if k > #STOPS then log("done"); f:close(); manager.machine:exit(); return end
    park(STOPS[k])
    if SKR[k] then w16(A.f_skyrows_off, SKR[k]); w16(A.skr_fixdx, 0) end
    if rel % HOLD == HOLD - 1 then
        manager.machine.video:snapshot()
        log("stop %d x=%d: worldtlx %d  2:%d 3:%d 4:%d 5:%d 6:%d 7:%d 8:%d  p1 %d p2 %d", k, STOPS[k],
            wx(A.worldtlx), wx(A.worldtlx2), wx(A.worldtlx3), wx(A.worldtlx4), wx(A.worldtlx5),
            wx(A.worldtlx6), wx(A.worldtlx7), wx(A.worldtlx8),
            s16(r16(r32(A.p1_obj) + O.oxpos)), s16(r16(r32(A.p2_obj) + O.oxpos)))
        log("   skr mode %d: ran %d plain %d lines %d", SKR[k] or -1, r16(A.skr_ran), r16(A.skr_plain), r16(A.skr_lines))
    end
end)
