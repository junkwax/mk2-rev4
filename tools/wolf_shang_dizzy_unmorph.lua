-- wolf_shang_dizzy_unmorph.lua - a MORPHED Shang who loses the match turns
-- back into himself before he sways for FINISH HIM (dizzy_dude, MKCANNED.ASM).
-- Playtest 2026-10-11: "he stays in Kano".
--
-- 2-player, Shang (P1) v Jax (P2), Dead Pool.  P1 becomes MK1 KANO (Wolf,
-- ochar 22: Back, Forward + Block) at the start of every round and stands
-- still; P2 walks in punching while P1's bar is held at 1, so a REAL hit
-- decides each round (writing a bar to 0 does not).  At FINISH HIM (round 2,
-- winner_status 3) P1 must:
--   * be Kano when it starts (or the trial proves nothing - NO VERDICT),
--   * be Shang (ochar 6) within 60 ticks, and stay Shang for 200,
--   * be stunned (p_action act_stunned 0400h) once he is Shang.
-- Run: tools/run_wolf_boot_probe.ps1 -Script wolf_shang_dizzy_unmorph.lua
--      -Env WS_MAP=<abs>\tmp\wolf\src\MK2.MAP
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_shang_dizzy_unmorph start")

local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "curback",
                    "illop_count", "p1_bar", "p2_bar", "p1_state", "p2_state", "winner_status"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxpos = 0x090, ochar = 0x1f0 }
local P_ACTION = 0x1f0
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Block",
               "P1 Left", "P1 Right", "P2 Left", "P2 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end

local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local fin_f, och0, back_f, stunned, shot = nil, nil, nil, false, 0
local function done(msg) log(msg); f:close(); manager.machine:exit() end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
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
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0)
            if r16(A.p1_state) ~= 0 then w16(A.p2_state, r16(A.p1_state)) end
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); log("fight at %d", frame) end
        if frame > 12000 then done("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done(string.format("FAIL illop_count moved at %d (a reboot)", frame)); return end
    if r16(A.p1_state) ~= 0 and r16(A.p2_state) == 0 then w16(A.p2_state, r16(A.p1_state)) end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local och = r16(p1o + O.ochar)
    local ws = r16(A.winner_status)
    w16(A.p2_bar, 0xa1)

    if ws == 3 then
        if not fin_f then
            fin_f = frame; och0 = och
            log("FINISH HIM at %d, P1 ochar %d", frame, och)
            if och ~= 22 then done("he was not Kano when the round was decided - NO VERDICT") return end
        end
        local rel = frame - fin_f
        if och == 6 and not back_f then back_f = rel; log("Shang again at FINISH HIM +%d", rel) end
        if back_f and och ~= 6 then done(string.format("FAIL he turned back into ochar %d at +%d", och, rel)) return end
        if back_f and r16(r32(A.p1_proc) + P_ACTION) == 0x0400 then stunned = true end
        if (rel == 10 or rel == 90) and shot < 2 then shot = shot + 1; manager.machine.video:snapshot() end
        if rel == 260 then
            log("Shang at +%s, stunned %s", tostring(back_f), tostring(stunned))
            done((back_f and back_f <= 60 and stunned) and "PASS" or "FAIL")
        end
        return
    end
    if fin_f then done("FAIL FINISH HIM ended early") return end
    if gs ~= 2 then return end
    if och ~= 22 then                         -- become Kano (again, each round)
        local k = frame % 60
        F["P1 Left"]:set_value(k < 4 and 1 or 0)
        F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
        F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        return
    end
    if ws == 0 then                           -- P2 beats him: his bar held at 1
        if r16(A.p1_bar) > 1 then w16(A.p1_bar, 1) end
        local toward = (r16(p1o + O.oxpos) < r16(p2o + O.oxpos)) and "P2 Left" or "P2 Right"
        F[toward]:set_value(1)
        F["P2 High Punch"]:set_value((frame % 16) < 3 and 1 or 0)
    end
    if frame - fight > 14000 then done("FAIL out of frames") end
end)
