-- wolf_kano_ball_sound_check.lua - MK1 KANO's CANNONBALL SOUNDS (Wolf, ochar 22).
--
-- MK1 (tools/run_mk1_kano_probe.ps1 -TwoPlayer -BallTest [-BallHold 900]) sends
-- 8Ah as he curls and 8Bh as he launches - no voice - and with Block held the
-- curl TIMES OUT 128 ticks after 8Ah.  8Ah is a whirr that runs until 8Bh
-- replaces it, so do_kn_ball (MK1KNM.ASM) sends 8Bh to the channel 8Ah took.
-- Three cannonballs after the morph:
--   tap      Block let go with the rotation's last input: 8Bh at once
--   hold60   Block held 60 ticks more: 8Bh on the release
--   hold200  Block held 200 ticks: 8Bh on its own, 128 ticks after 8Ah
--            (longer and Shang's morph timer turns him back mid-trial)
-- Each must send ball_go then ball_roll ON THE SAME CHANNEL (track - base), and
-- no other mk1kn_ sound between them.  NEG=1 crosses the hold200 expectation
-- (wants the roll on the release) and MUST fail.
-- Env: WB_LOG, WS_MAP (the Wolf build's MK2.MAP), WS_SND (src/WOLFSND.ASM), NEG.
local LOG = os.getenv("WB_LOG")
local NEG = os.getenv("NEG") == "1"
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_kano_ball_sound_check start%s", NEG and " (NEGATIVE)" or "")

local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
-- every mk1kn_ track, with the channel it plays on (rows are ch1,ch2,ch3)
local TRK = {}
for l in io.lines(os.getenv("WS_SND")) do
    local t, key = l:match("%.word%s+%x+h|%d+,0?(%x+)h%s*;%s*%x+%s+(mk1kn_[%w_]+)")
    if t then local n = tonumber(t, 16); for ch = 0, 2 do TRK[n + ch] = {key, ch + 1} end end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "curback", "illop_count",
                    "p1_bar", "p2_bar", "p1_state", "p2_state"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxpos = 0x090, ochar = 0x1f0 }
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch",
               "P1 Block", "P1 Up", "P1 Down", "P1 Left", "P1 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end

local frame = 0
local EV = {}            -- {frame, key, channel}
local prevb
_G.kn_ball_tap = space:install_write_tap(0x01680000, 0x0168001f, "knball", function(o, d, m)
    local v = d & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if TRK[c] then EV[#EV + 1] = {frame, TRK[c][1], TRK[c][2]} end
    return d
end)

local started, sel, fight, confirm, morph_f, ill0
-- trials: {name, extra Block ticks after the rotation}
local TRIALS = {{"tap", 0}, {"hold60", 60}, {"hold200", 200}}
local ti, tstep, tt, trial_start, release_f = 1, 0, 0, nil, nil
local results = {}
local ROT = {{4, {"P1 Block"}}, {4, {"P1 Block", "P1 Right"}}, {4, {"P1 Block", "P1 Down"}},
             {4, {"P1 Block", "P1 Left"}}, {4, {"P1 Block", "P1 Up"}}}

local function finish()
    local ok = #results == #TRIALS
    for _, r in ipairs(results) do ok = ok and r.ok end
    log(ok and "PASS" or "FAIL")
    f:close(); manager.machine:exit()
end

local function judge(tr)
    local go, roll, other
    for _, e in ipairs(EV) do
        if e[1] >= trial_start then
            if e[2] == "mk1kn_ball_go" and not go then go = e
            elseif e[2] == "mk1kn_ball_roll" and go and not roll then roll = e
            elseif not roll then other = other or e end
        end
    end
    local r = {name = tr[1]}
    if not go or not roll then
        log("%s: curl %s roll %s - NO SOUND", tr[1], tostring(go and go[1]), tostring(roll and roll[1]))
        r.ok = false; results[#results + 1] = r; return
    end
    local gap = roll[1] - go[1]
    local rel = release_f and (roll[1] - release_f) or nil
    log("%s: curl ch%d at %d, roll ch%d at %d (+%d after curl, %s after release)%s",
        tr[1], go[3], go[1], roll[3], roll[1], gap, rel and string.format("%+d", rel) or "-",
        other and (" EXTRA " .. other[2]) or "")
    r.ok = go[3] == roll[3] and not other
    if tr[2] >= 128 and not NEG then
        r.ok = r.ok and math.abs(gap - 128) <= 1        -- timed out on its own
    else
        r.ok = r.ok and rel and rel >= 0 and rel <= 2 and gap < 128 -- on the release
    end
    log("  %s", r.ok and "ok" or "BAD")
    results[#results + 1] = r
end

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
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    local rel = frame - fight
    if r16(A.p1_state) ~= 0 and r16(A.p2_state) == 0 then w16(A.p2_state, r16(A.p1_state)) end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local och = r16(p1o + O.ochar)
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    if r16(A.illop_count) ~= ill0 then log("FAIL illop_count moved (a reboot)"); finish(); return end
    local done_roll = false
    if trial_start then
        for _, e in ipairs(EV) do if e[1] >= trial_start and e[2] == "mk1kn_ball_roll" then done_roll = true end end
    end
    if och ~= 22 and tstep ~= 0 and done_roll then  -- the morph wore off after the roll: judge it now
        judge(TRIALS[ti]); ti, tstep, tt = ti + 1, 0, 0
    end
    if och ~= 22 then                     -- (re)morph: Back, Forward + Block; any trial restarts
        if tstep ~= 0 then log("  morph wore off mid-trial - restarting %s", TRIALS[ti][1]); tstep, tt = 0, 0 end
        if rel >= 40 then
            local k = frame % 60
            F["P1 Left"]:set_value(k < 4 and 1 or 0)
            F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
            F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        end
        if rel > 30000 then log("FAIL never Kano"); finish() end
        return
    end
    morph_f = morph_f or frame
    if frame - morph_f < 40 then return end
    if ti > #TRIALS then finish(); return end
    local tr = TRIALS[ti]
    -- tstep 0: place the victim far; 1..#ROT: the rotation; then extra Block; then wait
    if tstep == 0 then
        local x1 = r16(p1o + O.oxpos)
        local nx = x1 + 170
        w16(p2o + O.oxpos, nx); space:write_u32(p2o + 0x080, (nx << 16) & 0xffffffff)
        trial_start, release_f = frame, nil
        tstep, tt = 1, 0
    end
    if tstep <= #ROT then
        for _, n in ipairs(ROT[tstep][2]) do F[n]:set_value(1) end
        tt = tt + 1
        if tt >= ROT[tstep][1] then tstep, tt = tstep + 1, 0 end
        if tstep > #ROT and tr[2] == 0 then release_f = frame + 1 end
        return
    end
    if tt < tr[2] then
        F["P1 Block"]:set_value(1); tt = tt + 1
        if tt >= tr[2] then release_f = frame + 1 end
        return
    end
    tt = tt + 1
    local rolled                          -- judge once he has had 120 ticks to land and stand
    for _, e in ipairs(EV) do if e[1] >= trial_start and e[2] == "mk1kn_ball_roll" then rolled = e[1] end end
    if (rolled and frame - rolled >= 120) or tt >= tr[2] + 260 then
        if NEG and tr[2] >= 128 then release_f = trial_start end   -- crossed: demand "on the release"
        judge(tr)
        ti, tstep, tt = ti + 1, 0, 0
    end
end)
