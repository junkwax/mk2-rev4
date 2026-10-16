-- wolf_sindel_fatal.lua - UMK3 SINDEL's finishers on the Wolf build (ochar 21).
--
-- 2-player game, P1 forced to WF_P1 (default 21, Sindel) v an idle P2 (WF_P2,
-- default Jax 11) on stage WF_STAGE.  The rig gives P1 a round already
-- (p1_matchw) and P2 1 hp, a HIGH KICK KOs him (a punch would spoil the
-- babality), and in FINISH HIM P1 does WF_FATAL:
--   RIP     Back, Back, Forward + Block (close)             f_death 1
--   HAIR    Down, Down, Back + Block (up to 0c0h apart)     f_death 2
--           also logs the victim's dizzy shape at the input and his shape
--           under the coil (must be the SAME still pose whatever WF_HOLD
--           does to the input-time one), fails unless he is >= 98h out at
--           the coil, and with WF_TAP=1 fails unless the tornado, quake
--           rumble and both crunches reach the sound latch.  WF_WALL=1 parks
--           him on the right-hand clamp so SHE has to give ground instead.
--   BABY    Down, Down, Down + Low Kick                     f_death 5
--   PIT     Down, Forward, Forward + Block, stage 1 (tomb)  f_death 8 (the spikes)
--   PIT2    the same on stage 6 (Pit II) by SCORPION against SINDEL: she has
--           no Pit II fall art, so it must NOT start (f_death stays 0) and
--           she takes the plain uppercut - WF_P1=10 WF_P2=21 WF_STAGE=6
-- PASS: f_death goes to the number, then to -1 (death_blow_complete) for the
-- two fatalities; illop_count never moves.  Snapshots every 6 frames.
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
               "P1 Block", "P1 Down", "P1 Left", "P1 Right", "P1 High Kick", "P1 Low Kick"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end


local WHICH = os.getenv("WF_FATAL") or "RIP"
local P1C = tonumber(os.getenv("WF_P1") or "21")
local P2C = tonumber(os.getenv("WF_P2") or "11")
local STAGE = tonumber(os.getenv("WF_STAGE") or "0")
local PITSEQ = { {4, {"P1 Down"}}, {2, {}}, {4, {"P1 Right"}}, {2, {}}, {4, {"P1 Right"}}, {2, {}}, {6, {"P1 Block"}} }
local FAT = {
    RIP = { num = 1, gap = 60, done = true,
            seq = { {4, {"P1 Left"}}, {2, {}}, {4, {"P1 Left"}}, {2, {}}, {4, {"P1 Right"}}, {2, {}}, {6, {"P1 Block"}} } },
    HAIR = { num = 2, gap = tonumber(os.getenv("WF_GAP") or "110"), done = true,
             seq = { {4, {"P1 Down"}}, {2, {}}, {4, {"P1 Down"}}, {2, {}}, {4, {"P1 Left"}}, {2, {}}, {6, {"P1 Block"}} } },
    BABY = { num = 5, gap = 100,
             seq = { {4, {"P1 Down"}}, {2, {}}, {4, {"P1 Down"}}, {2, {}}, {4, {"P1 Down"}}, {2, {}}, {6, {"P1 Low Kick"}} } },
    -- MK1 KANO's heart rip (WF_P1=22): Back, Down, Forward + Low Punch, close
    HEART = { num = 1, gap = 60, done = true,
              seq = { {4, {"P1 Left"}}, {2, {}}, {4, {"P1 Down"}}, {2, {}}, {4, {"P1 Right"}}, {2, {}}, {6, {"P1 Low Punch"}} } },
    PIT = { num = 8, gap = 60, seq = PITSEQ },      -- the tomb spikes report 8
    PIT2 = { num = 0, gap = 60, seq = PITSEQ },
}
local FT = FAT[WHICH] or error("WF_FATAL=RIP|HAIR|BABY|PIT|PIT2|HEART")
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local phase, t0, seq_i, seq_t = "ko", 0, 1, 1
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
    -- WF_WALL=1: the victim on the right-hand clamp (400 - right_padding 48),
    -- so the hair spin's slide cannot carry him out to the coil
    if os.getenv("WF_WALL") then x1 = cam + 352 - gap end
    w16(p1o + O.oxpos, x1); w32(p1o + O.oxval, (x1 << 16) & 0xffffffff)
    w16(p2o + O.oxpos, x1 + gap); w32(p2o + O.oxval, ((x1 + gap) << 16) & 0xffffffff)
end
local function quit(msg) log("%s", msg); f:close(); manager.machine:exit() end

-- WF_TAP=1: log every music-range code (0600h-07FFh) written to the sound port
local tap, prevb = nil, nil
-- HAIR: the spin's sounds (sound/wolf_patch.txt; the latch carries one of each
-- triple's three tracks) - all four must be heard when WF_TAP is on
HAIR_SND = { tornado = 0x0627, quake = 0x0615, crunch1 = 0x0663, crunch2 = 0x0666 }
HAIR_HEARD = {}
-- HAIR: the victim's drawn shape (oimg, 1d0h) from the fatality's start to
-- the spin - it must never change (one still pose under the coil)
local hair_shapes, hair_last, hair_spin, hair_gap = {}, nil, nil, nil
local function on_sound(offset, data, mask)
    local v = data & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if c >= 0x0600 and c < 0x0800 then
        log("  sound code %04X at frame %d ws %d", c, frame, r16(A.winner_status))
        for k, base in pairs(HAIR_SND) do if c >= base and c <= base + 2 then HAIR_HEARD[k] = frame end end
    end
    return data
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start %s", WHICH)
    end
    frame = frame + 1
    if os.getenv("WF_POOL") and frame % 6 == 0 and r16(A.winner_status) ~= 0 then
        local q, n = r32(S.ofree), 0
        while q ~= 0 and n < 400 do q = r32(q); n = n + 1 end
        local pq, pn = r32(S.active), 0
        while pq ~= 0 and pn < 300 do pq = r32(pq); pn = pn + 1 end
        log("  pool: %d objects free, %d procs active (frame %d)", n, pn, frame)
    end
    if os.getenv("WF_TAP") and not tap then tap = space:install_write_tap(0x01680000, 0x0168001f, "wf_snd", on_sound) end
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
            w16(A.p1_char, P1C); w16(A.p2_char, P2C); w16(A.curback, STAGE)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); t0 = frame + 120; log("fight at %d", frame) end
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
    if frame < t0 then w16(A.curback, STAGE); return end
    if phase == "ko" then
        place(80)
        w16(A.p1_matchw, 1)
        if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
        w16(A.p1_bar, 0xa1)
        F["P1 High Kick"]:set_value((rel % 30) < 5 and 1 or 0)
        if r16(A.winner_status) == 3 then
            log("FINISH HIM at %d (+%d), P1 ochar %d", frame, rel, och)
            if och ~= P1C then quit("P1 is not the fighter asked for - NO VERDICT") return end
            phase = "wait"; t0 = frame
        end
        if os.getenv("WF_TRACE") and rel >= 300 and rel < 380 and rel % 5 == 0 then manager.machine.video:snapshot() end
        if os.getenv("WF_TRACE") and (rel % 30 == 10 or (rel == 600)) then
            local p2o = r32(A.p2_obj)
            if rel == 310 or rel == 317 or rel == 600 then
                log("   f_start %d clk %d%d", r16(S.f_start), r16(S.clk_tens), r16(S.clk_ones))
                local q, n = r32(S.active), 0
                while q ~= 0 and n < 80 do
                    log("    proc %08X id %04X time %d wake %08X psptr %08X stk0 %08X", q, r16(q + 0x20), r16(q + 0x30),
                        r32(q + 0xe0), r32(q + 0x40), r32(q + 0xc0))
                    q = r32(q); n = n + 1
                end
            end
            log("  tick %s pc %08X", tostring(S.tick and r16(S.tick)), manager.machine.devices[":maincpu"].state["PC"].value)
            log("  ko +%d p1act %04X p2act %04X p2bar %d ws %d gap %d round %s", rel, act,
                r16(r32(A.p2_proc) + P.action), r16(A.p2_bar), r16(A.winner_status),
                s16(r16(p2o + O.oxpos)) - s16(r16(p1o + O.oxpos)), tostring(S.round_num and r16(S.round_num)))
        end
        if rel > 1500 then quit("never reached FINISH HIM - NO VERDICT") end
        return
    end
    if phase == "wait" then
        place(FT.gap)
        -- WF_HOLD=n: stand in FINISH HIM for n frames first (to hear its tune)
        if rel >= 40 + tonumber(os.getenv("WF_HOLD") or "0") then phase = "input"; t0 = frame; seq_i, seq_t = 1, 0 end
        return
    end
    if phase == "input" then
        if seq_i == 1 and seq_t == 0 and WHICH == "HAIR" then
            local p2o = r32(A.p2_obj)
            local cam = s16(r16(A.worldtlx + 16))
            log("  HAIR dizzy shape at input %08X  p1 x %d p2 x %d (screen)", r32(p2o + 0x1d0),
                s16(r16(p1o + O.oxpos)) - cam, s16(r16(p2o + O.oxpos)) - cam)
        end
        local st = FT.seq[seq_i]
        for _, n in ipairs(st[2]) do F[n]:set_value(1) end
        seq_t = seq_t + 1
        if seq_t >= st[1] then seq_i = seq_i + 1; seq_t = 0 end
        if fd ~= 0 and not fat_seen then fat_seen = fd; log("f_death %d at input +%d", fd, rel) end
        if seq_i > #FT.seq then phase = "watch"; t0 = frame end
        return
    end
    if phase == "watch" then
        if rel % (tonumber(os.getenv("WF_EVERY") or "6")) == 0 and rel <= 330 then manager.machine.video:snapshot() end
        if WHICH == "HAIR" then
            local p2o = r32(A.p2_obj)
            if p2o ~= 0 then
                local sh = r32(p2o + 0x1d0)
                local gap = math.abs(s16(r16(p2o + O.oxpos)) - s16(r16(p1o + O.oxpos)))
                if rel == 0 then log("  HAIR input-time shape %08X gap %d", sh, gap) end
                if sh ~= hair_last then
                    log("  HAIR +%d victim shape %08X gap %d p2act %04X", rel, sh, gap, r16(r32(A.p2_proc) + P.action))
                    hair_last = sh
                end
                if rel == 80 then
                    hair_gap = gap
                    local cam = s16(r16(A.worldtlx + 16))
                    log("  HAIR coil shape %08X gap %d (want >= 152)  p1 x %d p2 x %d (screen)", sh, gap,
                        s16(r16(p1o + O.oxpos)) - cam, s16(r16(p2o + O.oxpos)) - cam)
                end
            end
        end
        if fd ~= 0 and not fat_seen then fat_seen = fd; log("f_death %d at watch +%d", fd, rel) end
        if fat_seen and fd == 0xffff and not done_at then done_at = rel; log("death_blow_complete at +%d", rel) end
        if rel % 30 == 0 then
            local p2o = r32(A.p2_obj)
            log("  +%d p1act %04X p2act %04X f_death %04X p2 oflags2 %04X", rel, act,
                r16(r32(A.p2_proc) + P.action), fd, p2o ~= 0 and r16(p2o + 0x160) or 0)
        end
        if rel >= 420 or (done_at and rel >= done_at + 60) then
            local ok
            if FT.num == 0 then
                ok = fat_seen == nil            -- the pit must not have started
            else
                ok = fat_seen == FT.num and (done_at ~= nil or not FT.done)
            end
            log("%s: f_death %s (want %d), complete %s", WHICH, tostring(fat_seen), FT.num, tostring(done_at))
            if WHICH == "HAIR" then
                if not hair_gap or hair_gap < 0x98 then log("HAIR: victim not out at the coil (gap %s)", tostring(hair_gap)); ok = false end
                if os.getenv("WF_TAP") then
                    for k, base in pairs(HAIR_SND) do
                        log("HAIR sound %-8s %04X %s", k, base, HAIR_HEARD[k] and ("heard at frame " .. HAIR_HEARD[k]) or "MISSING")
                        if not HAIR_HEARD[k] then ok = false end
                    end
                end
            end
            quit(ok and "PASS" or "FAIL")
        end
    end
end)
