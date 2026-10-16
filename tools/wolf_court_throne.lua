-- wolf_court_throne.lua - THE COURTYARD (MK1, Wolf only, curback 01Dh): is
-- Shang Tsung's throne EMPTY when he is one of the fighters, and occupied
-- when he is not?  Plays a 1P game on the Wolf build with curback held at
-- 01Dh and both fighters forced from the select confirm until the fight
-- runs, then reads the one object on mk1c_th_lst (MK1CRT.ASM mk1c_throne):
-- its record's SAG must be MK1CYTHRNE (empty) or MK1CYTHRN (seated), at
-- MK1's block position, for 300 fight frames.  Snapshot at fight +120.
-- Driven by tools/run_wolf_court_throne.ps1, which reads every address and
-- SAG out of the Wolf build:
--   WT_LST WT_CURBACK WT_P1CHAR WT_P2CHAR   map addresses (hex)
--   WT_SEAT WT_EMPTY                        the two records' SAGs (hex)
--   WT_X WT_Y                               mk1c_th_x / mk1c_th_y (decimal)
--   WT_P1 WT_P2                             ochars to force
--   WT_WANT                                 "seat" or "empty"
local LOG = os.getenv("WB_LOG")
local GSTATE = tonumber(os.getenv("WB_GSTATE"), 16)
local function hx(n) return tonumber(os.getenv(n), 16) end
local LST, CURBACK, P1CHAR, P2CHAR = hx("WT_LST"), hx("WT_CURBACK"), hx("WT_P1CHAR"), hx("WT_P2CHAR")
local SAG = { [hx("WT_SEAT")] = "seat", [hx("WT_EMPTY")] = "empty" }
local WX, WY = tonumber(os.getenv("WT_X")), tonumber(os.getenv("WT_Y"))
local P1, P2 = tonumber(os.getenv("WT_P1")), tonumber(os.getenv("WT_P2"))
local WANT = os.getenv("WT_WANT")
local OIMG, OXPOS, OYPOS = 0x1a0, 0x090, 0x0b0

local f = nil
local function log(s)
    if not f then f = io.open(LOG, "w"); f:write("wolf_court_throne start\n") end
    f:write(s .. "\n"); f:flush()
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function field(name)
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[name] then return q.fields[name] end end
end
local F = { coin = field("Coin 1"), start = field("1 Player Start"), hp = field("P1 High Punch") }

local frame, started, fight, sel = 0, false, nil, nil
local tally, bad, samples = {}, 0, 0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log(("start: want %s, p1 %d p2 %d"):format(WANT, P1, P2))
    end
    frame = frame + 1
    local gs = space:read_u16(GSTATE)
    if gs == 4 and not sel then sel = frame; log(("select at %d"):format(frame)) end
    local k = frame - 1500
    F.coin:set_value(((k >= 0 and k < 6) or (k >= 30 and k < 36)) and 1 or 0)
    F.start:set_value((k >= 120 and k < 126) and 1 or 0)
    F.hp:set_value((sel and frame >= sel + 300 and frame < sel + 306) and 1 or 0)
    if sel and gs ~= 2 and not fight then
        space:write_u16(CURBACK, 0x1D)
        if frame >= sel + 330 then               -- after the confirm: a forced
            space:write_u16(P1CHAR, P1)          -- select never confirms
            space:write_u16(P2CHAR, P2)
        end
    end
    if gs == 2 and not fight then
        fight = frame
        log(("fight at %d, curback %02X, p1_char %d p2_char %d"):format(frame,
            space:read_u16(CURBACK), space:read_u16(P1CHAR), space:read_u16(P2CHAR)))
    end
    if fight then
        local rel = frame - fight
        if rel == 120 then manager.machine.video:snapshot() end
        if rel >= 20 and rel < 320 then
            samples = samples + 1
            local o = space:read_u32(LST)
            local what = "none"
            if o ~= 0 then
                local sag = space:read_u32(space:read_u32(o + OIMG) + 0x40)
                what = SAG[sag] or ("sag_%08X"):format(sag)
                local x, y = space:read_u16(o + OXPOS), space:read_u16(o + OYPOS)
                if x ~= WX or y ~= WY or space:read_u32(o) ~= 0 then bad = bad + 1 end
                if rel == 20 then log(("throne obj %08X x %d y %d sag %08X = %s"):format(o, x, y, sag, what)) end
            end
            tally[what] = (tally[what] or 0) + 1
        end
        if rel == 320 then
            local t = {}
            for w, n in pairs(tally) do t[#t + 1] = ("%s:%d"):format(w, n) end
            log(("samples %d  %s  misplaced/extra %d"):format(samples, table.concat(t, " "), bad))
            local ok = tally[WANT] == samples and bad == 0 and
                       space:read_u16(P1CHAR) == P1 and space:read_u16(P2CHAR) == P2
            log(ok and "PASS" or "FAIL")
            f:close(); manager.machine:exit()
        end
    end
    if frame > 9000 then log(("no fight by frame 9000 (gstate %d) - NO VERDICT"):format(gs)); f:close(); manager.machine:exit() end
end)
