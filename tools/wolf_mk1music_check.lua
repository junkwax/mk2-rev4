-- wolf_mk1music_check.lua - MK1 stage music on the Wolf build: a 2-player
-- fight forced onto WM_STAGE (curback, default 1Dh THE COURTYARD), both bars
-- pinned, run WM_FRAMES frames and exit.  Run it with -Listen (and the
-- private tools\mame_wolf build, which loads sound sockets u6-u9); then
-- tools/mk1_music_listen.py finds the intro and the loop in the recording.
-- Env: WS_MAP (tmp/wolf/src/MK2.MAP), WM_STAGE (hex), WM_FRAMES.
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
                    "curback", "illop_count", "p1_bar", "p2_bar", "worldtlx", "round_num"}) do
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



local STAGE = tonumber(os.getenv("WM_STAGE") or "1d", 16)
local FRAMES = tonumber(os.getenv("WM_FRAMES") or "4200")
local frame, started, sel, fight, confirm = 0, false, nil, nil, nil
-- WM_TAP=1: log every code written to the Wolf sound port (01680000h) from
-- the VS screen on - the stage tune's TRACK number is among them
local tap, seen, prevb = nil, {}, nil
local function on_sound(offset, data, mask)
    -- the latch takes a code as two byte writes: pair them ROLLING
    local v = data & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if sel and not seen[c] and c >= 0x0600 and c < 0x0800 then
        seen[c] = true
        log("sound code %04X at frame %d (gstate %02X)", c, frame, r16(A.gstate))
    end
    return data
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start stage %02X", STAGE)
    end
    frame = frame + 1
    if os.getenv("WM_TAP") and not tap then
        tap = space:install_write_tap(0x01680000, 0x0168001f, "wmus_snd", on_sound)
    end
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
        if gs == 2 then
            fight = frame
            log("fight at %d, curback %02X round %d", frame, r16(A.curback), r16(A.round_num))
        end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    if (frame - fight) % 600 == 0 then log("+%d gstate %d curback %02X", frame - fight, gs, r16(A.curback)) end
    if frame - fight >= FRAMES then log("done"); f:close(); manager.machine:exit() end
end)
