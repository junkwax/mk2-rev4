-- wolf_sindel_select.lua - the START tap on Mileena's square picks SINDEL
-- (Wolf only, ochar 21; morph_table, MKSEL.ASM).
--
-- 2-player game.  P1 walks the cursor from Liu Kang to Mileena with the
-- real joystick (Down, Down - through Sub-Zero), taps START three times - on, off, on - and
-- after each tap the pending flag (f_sindel_cheat1) and the box wipe frame
-- (sindel_pos: 0 = Mileena's FN2BOX, 8 = FN2BOX9, Sindel) must be 1/8, 0/0, 1/8.
-- Then both players confirm and P1 must reach the fight as ochar 21.
-- SS_NOTAP=1 is the control: no taps, and P1 must fight as Mileena (5).
-- Env: WB_LOG, WS_MAP.
local LOG = os.getenv("WB_LOG")
local NOTAP = os.getenv("SS_NOTAP") == "1"
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "illop_count", "f_sindel_cheat1",
                    "sindel_pos", "curback", "p1_state", "p2_state"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local NAMES = {"Coin 1", "1 Player Start", "2 Players Start", "P1 High Punch", "P2 High Punch",
               "P1 Down", "P1 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local function done(fmt, ...) log(fmt, ...); f:close(); manager.machine:exit() end
-- rel frame (from the select screen) -> action
local steps, t = {}, 100
local function press(n, at, len) steps[#steps + 1] = {at, at + (len or 6), n} end
local checks = {}
local function check(at, fn) checks[at] = fn end
press("P1 Down", t); press("P1 Down", t + 30); t = t + 70
check(t, function()
    local c = r16(A.p1_char)
    log("cursor on %d", c)
    if c ~= 5 then done("FAIL cursor on %d, not Mileena (5)", c) end
end)
local bad = 0
if not NOTAP then
    for i, want in ipairs({{1, 8}, {0, 0}, {1, 8}}) do
        press("1 Player Start", t + 10)
        check(t + 70, function()
            local fl, pos = r16(A.f_sindel_cheat1), r16(A.sindel_pos)
            log("tap %d: flag %d pos %d (want %d/%d)", i, fl, pos, want[1], want[2])
            if fl ~= want[1] or pos ~= want[2] then bad = bad + 1 end
            manager.machine.video:snapshot()
        end)
        t = t + 80
    end
end
press("P1 High Punch", t + 10); press("P2 High Punch", t + 80)
local frame, started, sel, fight, ill0 = 0, false, nil, nil, nil
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    -- attract mode shows a select screen at the same gstate: wait for a real
    -- 2-player game (both states human) with both cursors up
    if gs == 4 and not sel and r16(A.p1_state) ~= 0 and r16(A.p2_state) ~= 0
       and r16(A.p1_char) < 12 and r16(A.p2_char) < 12 then
        sel = frame; ill0 = r16(A.illop_count); log("select at %d", frame)
    end
    if not sel then
        -- P2 joins on the select screen P1's start opened
        if frame >= 1500 and gs == 4 and r16(A.p2_state) == 0 then
            F["2 Players Start"]:set_value((frame % 60) < 6 and 1 or 0)
        elseif frame >= 1500 and gs ~= 4 then
            local k = (frame - 1500) % 200
            F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
            F["1 Player Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
            F["2 Players Start"]:set_value((k >= 120 and k < 126) and 1 or 0)
        end
        if frame > 9000 then done("no select screen - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done("FAIL illop_count moved (a reboot)") return end
    if not fight then
        local rel = frame - sel
        for _, s in ipairs(steps) do
            if rel >= s[1] and rel < s[2] then F[s[3]]:set_value(1) end
        end
        if checks[rel] then checks[rel]() end
        if gs == 0x0d and frame % 10 == 0 then manager.machine.video:snapshot() end
        if gs == 2 then fight = frame; log("fight at %d", frame) end
        if rel > 4000 then done("no fight - NO VERDICT") end
        return
    end
    if frame == fight + 150 then
        manager.machine.video:snapshot()
        local p1o = r32(A.p1_obj)
        local och = p1o ~= 0 and r16(p1o + 0x1f0) or -1
        local want = NOTAP and 5 or 21
        if och == want and bad == 0 then
            done("PASS P1 fights as ochar %d%s", och, NOTAP and " (control: no tap)" or " after the START tap")
        else
            done("FAIL P1 ochar %d (want %d), %d bad taps", och, want, bad)
        end
    end
end)
