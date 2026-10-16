-- wolf_sonya_fatal.lua - MK3 SONYA's fatalities on the Wolf build (ochar 20).
--
-- 2-player Shang Tsung (P1) v Jax (P2, idle).  Shang morphs into Sonya, the
-- rig gives P1 a round already (p1_matchw) and Jax 1 hp, a jab KOs him, and
-- in FINISH HIM she does WF_FATAL:
--   KISS    Back, Forward, Down, Down + Block (anywhere; 100px apart)
--   CRUSH   hold Block, Up, Up, Back, Down (0d0h-140h apart; 260px)
-- PASS: f_death goes to the fatality's number (1 / 2), then to -1
-- (death_blow_complete), and illop_count never moves.  Snapshots every 6
-- frames from the input to snap/.
--
-- (the boot below is wolf_sonya_specials.lua's)
--
-- 2-player Shang Tsung (P1) v Jax (P2, idle).  Shang morphs (Down + Block +
-- LP), then each special is thrown at Jax several times, the pair reset to a
-- set gap before every trial:
--   RINGS   Down, Forward + LP  - P1 must take act_throw_fans (0008h) and
--           Jax's bar must drop while the ring is out (from 200px away);
--   SQUARE  Forward, Back + HP  - P1 must take act_square (0207h) and Jax's
--           bar must drop.
--   LEGS    Down + LP + Block   - act_sa_leggrab (0124h), Jax's bar drops (26);
--   BIKE    Back, Back, Down + HK - act_bike, Jax's bar drops.
-- illop_count must never move.  Snapshots of each trial's middle go to snap/.
-- Env: WS_MAP (tmp/wolf/src/MK2.MAP).  WS_TRIALS (default 3 each).
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
                    "curback", "illop_count", "p1_bar", "p2_bar", "worldtlx",
                    "p1_matchw", "f_death", "winner_status"}) do
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


local WHICH = os.getenv("WF_FATAL") or "KISS"
local FAT = {
    KISS = { num = 1, gap = 100,
             seq = { {4, {"P1 Left"}}, {2, {}}, {4, {"P1 Right"}}, {2, {}}, {4, {"P1 Down"}}, {2, {}},
                     {4, {"P1 Down"}}, {2, {}}, {6, {"P1 Block"}} } },
    CRUSH = { num = 2, gap = 260,
              seq = { {6, {"P1 Block"}}, {4, {"P1 Block", "P1 Up"}}, {2, {"P1 Block"}},
                      {4, {"P1 Block", "P1 Up"}}, {2, {"P1 Block"}}, {4, {"P1 Block", "P1 Left"}},
                      {2, {"P1 Block"}}, {6, {"P1 Block", "P1 Down"}}, {4, {"P1 Block"}} } },
}
local FT = FAT[WHICH] or error("WF_FATAL=KISS|CRUSH")
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local phase, t0, seq_i, seq_t = "morph", 0, 1, 1
local fat_seen, done_at = nil, nil
local ks = { "P1 Up" }
for _, n in ipairs(ks) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    NAMES[#NAMES + 1] = n
end
local function place(gap)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local cam = s16(r16(A.worldtlx + 16))
    local x1 = cam + 60
    w16(p1o + O.oxpos, x1); w32(p1o + O.oxval, (x1 << 16) & 0xffffffff)
    w16(p2o + O.oxpos, x1 + gap); w32(p2o + O.oxval, ((x1 + gap) << 16) & 0xffffffff)
end
local function quit(msg) log("%s", msg); f:close(); manager.machine:exit() end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start %s", WHICH)
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
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); t0 = frame; log("fight at %d", frame) end
        if frame > 12000 then quit("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then
        quit(string.format("FAIL illop_count moved (a reboot): illop_pc %08X phase %s act %04X",
            r32(S.illop_pc), phase, r16(r32(A.p1_proc) + P.action)))
        return
    end
    local p1o = r32(A.p1_obj)
    if p1o == 0 then return end
    local och = r16(p1o + O.ochar)
    local act = r16(r32(A.p1_proc) + P.action)
    local rel = frame - t0
    local fd = r16(A.f_death)
    if phase == "morph" then
        if r16(A.p1_bar) < 60 then w16(A.p1_bar, 0xa1) end
        if rel >= 30 then
            local k = (rel - 30) % 60
            F["P1 Down"]:set_value(k < 20 and 1 or 0)
            F["P1 Block"]:set_value(k < 20 and 1 or 0)
            F["P1 Low Punch"]:set_value((k >= 8 and k < 12) and 1 or 0)
        end
        if och == 20 and act ~= 0x0404 then
            log("MORPHED at %d", frame); phase = "ko"; t0 = frame
            w16(A.p1_matchw, 1); w16(A.p2_bar, 1)
        end
        if rel > 900 then quit("FAIL never morphed") end
        return
    end
    if phase == "ko" then
        place(70)
        if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
        F["P1 High Punch"]:set_value((rel % 16) < 5 and 1 or 0)
        if r16(A.winner_status) == 3 then
            log("FINISH HIM at %d (+%d), ochar %d", frame, rel, och)
            if och ~= 20 then quit("she reverted to Shang before FINISH HIM - NO VERDICT") return end
            phase = "wait"; t0 = frame
        end
        if rel > 1500 then quit("never reached FINISH HIM - NO VERDICT") end
        return
    end
    if phase == "wait" then
        place(FT.gap)
        if rel >= 40 then phase = "input"; t0 = frame; seq_i, seq_t = 1, 0 end
        return
    end
    if phase == "input" then
        local st = FT.seq[seq_i]
        for _, n in ipairs(st[2]) do F[n]:set_value(1) end
        seq_t = seq_t + 1
        if seq_t >= st[1] then seq_i = seq_i + 1; seq_t = 0 end
        if fd ~= 0 and not fat_seen then fat_seen = fd; log("f_death %d at input +%d", fd, rel) end
        if seq_i > #FT.seq then phase = "watch"; t0 = frame end
        return
    end
    if phase == "watch" then
        if rel % 6 == 0 and rel <= 330 then manager.machine.video:snapshot() end
        if fd ~= 0 and not fat_seen then fat_seen = fd; log("f_death %d at watch +%d", fd, rel) end
        if fat_seen and fd == 0xffff and not done_at then done_at = rel; log("death_blow_complete at +%d", rel) end
        if rel % 30 == 0 then
            local p2o = r32(A.p2_obj)
            log("  +%d p1act %04X p2act %04X f_death %04X p2 oflags2 %04X", rel, act,
                r16(r32(A.p2_proc) + P.action), fd, p2o ~= 0 and r16(p2o + 0x160) or 0)
        end
        if rel >= 360 or (done_at and rel >= done_at + 60) then
            local ok = fat_seen == FT.num and done_at ~= nil
            log("%s: f_death %s, complete %s", WHICH, tostring(fat_seen), tostring(done_at))
            quit(ok and "PASS" or "FAIL")
        end
    end
end)
