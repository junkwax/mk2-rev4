-- wolf_scorpion_mk3burn.lua - Scorpion's MK3 skeleton-burn fatality on Wolf.
--
-- D,D,U,U,U + HP in FINISH HIM (scom_sc_mk3, sc_hi_punch) sets p_store6 = 4:
-- do_scortch plays the stock MK2 mask-off and flame halves, and sc_mk2_burn
-- hands the victim to sny_skel_burn (UMK3SNYM.ASM) - MK3's sb_skeleton_burn,
-- the SBFIRE/SKELFIRE art in Sonya's UMK3SNF pack - instead of
-- flaming_skeleton.  That is UMK3's scorpion_fire.
--
-- 2-player Scorpion (P1) v Jax (P2, idle).  The rig gives P1 a round, Jax 1
-- hp, a jab KOs him, then in FINISH HIM it enters the motion at 100px,
-- holding Block throughout (see SEQ).
--
-- PROOF IS WHAT THE BLITTER DREW, not a flag: the DMA's SAG registers are
-- write-tapped (sag_census.lua's method) and every committed SAG is checked
-- against the SBFIRE1..SKELFIRE24A range read out of tmp/wolf/src/UMK3SNF.TBL.
--   SC_MODE=mk3     (default) D,D,U,U,U + HP: f_death 1, death_blow_complete,
--                   >= 20 distinct SKELFIRE-range SAGs blitted -> PASS
--   SC_MODE=toasty  D,D,U,U + HP - the CONTROL: the same fatality slot, but
--                   the stock MK2 burn, so ZERO SKELFIRE blits -> PASS
-- illop_count must never move.  Env: WS_MAP, WB_LOG, SC_TBL.
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_scorpion_mk3burn start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local SYMS = {}
for k, v in pairs(S) do if v >= 0xff800000 then SYMS[#SYMS + 1] = {v, k} end end
table.sort(SYMS, function(a, b) return a[1] < b[1] end)
local function sym(a)
    local lo, hi, best = 1, #SYMS, nil
    while lo <= hi do
        local m = (lo + hi) // 2
        if SYMS[m][1] <= a then best = m; lo = m + 1 else hi = m - 1 end
    end
    if not best then return string.format("%08X", a) end
    return string.format("%s+%X", SYMS[best][2], a - SYMS[best][1])
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
                    "curback", "illop_count", "p1_bar", "p2_bar", "worldtlx",
                    "p1_matchw", "f_death", "winner_status", "active", "rand", "blood_rand"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxval = 0x080, oxpos = 0x090, ochar = 0x1f0 }
local P = { action = 0x1f0 }
local MODE = os.getenv("SC_MODE") or "mk3"
-- SC_WHO=lk: LIU KANG's red dragon (Start+LP costume, bare Block at sweep
-- range, lk_block) - on Wolf its burn is the same MK3 skeleton burn.
local WHO = os.getenv("SC_WHO") or "sc"
local P1CH = (WHO == "lk") and 1 or 10

-- SKELFIRE art range, out of the TBL LOAD2 wrote for the ROM under test
local LO, HI, NREC = nil, nil, 0
local NAME, FIRST, ORDER = {}, {}, {}
local frame = 0
do
    local tbl = os.getenv("SC_TBL") or error("SC_TBL")
    local cur
    for line in io.lines(tbl) do
        local nm = line:match("^(%w+):")
        if nm then cur = nm end
        local sag = line:match("^%s*%.long%s+0*(%x+)H")
        if sag then
            NAME[tonumber(sag, 16)] = cur
            local v = tonumber(sag, 16)
            LO = LO and math.min(LO, v) or v; HI = HI and math.max(HI, v) or v
            NREC = NREC + 1
        end
    end
    if NREC < 30 then error("read only " .. NREC .. " SAGs from " .. tbl) end
    HI = HI + 0x10000   -- the last record's own payload (well under 64Kbit)
end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

-- DMA tap (Wolf block at 01a00000h; bit addresses, learn byte vs bit)
local CTRL, SAGL, SAGH = 0x01a00010, 0x01a00020, 0x01a00030
local scale, lo, hi = nil, nil, nil
local armed, skel = false, {}
local skel_n, skel_commits = 0, 0
local function on_write(offset, data, mask)
    if scale == nil then
        if offset == CTRL or offset == SAGL or offset == SAGH then scale = 1
        elseif offset * 8 == CTRL or offset * 8 == SAGL or offset * 8 == SAGH then scale = 8 end
        if scale == nil then return data end
    end
    local bit = offset * scale
    if bit == SAGL then lo = data & 0xffff
    elseif bit == SAGH then hi = data & 0xffff
    elseif bit == CTRL and lo and hi and armed then
        local sag = (hi << 16) | lo
        if sag >= LO and sag < HI then
            skel_commits = skel_commits + 1
            if not skel[sag] then
                skel[sag] = true; skel_n = skel_n + 1
                if (NAME[sag] or "") == "SKELFIRE17A" then _G.SC_PROBE = frame end
                if (NAME[sag] or "") == "SKELFIRE24A" then _G.SC_LAST = frame end
                ORDER[#ORDER + 1] = string.format("%s@%d", NAME[sag] or string.format("%08X", sag), frame)
            end
        end
    end
    return data
end
local taps = {}
for _, r in ipairs({ {0x01a00000, 0x01a000ff}, {0x01a00000 // 8, 0x01a000ff // 8} }) do
    local ok, h = pcall(function() return space:install_write_tap(r[1], r[2], "scmk3_" .. r[1], on_write) end)
    if ok and h then taps[#taps + 1] = h end   -- keep the handles or the taps are collected
end

local SND, prevb = {}, nil
local TRK = {}            -- 16-bit tracks, paired ROLLING from the latch bytes
local function saw(lo, hi) for _, t in ipairs(TRK) do if t[2] >= lo and t[2] <= hi then return t[1] end end end
local SNDA = tonumber(os.getenv("SC_SNDLATCH") or "01680000", 16)   -- T-unit: 01d01030
_G.scmk3_snd = space:install_write_tap(SNDA, SNDA + 0x1f, "scmk3snd", function(o, d, m)
    local v = d & 0xff
    if armed then
        SND[#SND + 1] = string.format("%d:%02X", frame, v)
        if prevb then TRK[#TRK + 1] = {frame, (prevb << 8) | v} end
        prevb = v
    end
    return d
end)

local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 Block", "P1 Down", "P1 Up", "P1 Left", "P1 Right", "P1 High Kick"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end

-- Block is HELD through the whole motion: joy_stance_loop tests it before the
-- stick, so Up does not jump (an Up tap otherwise launches him and the HP is
-- an air punch), and the fatality's button mask f1b1|f1b3|f1b4 permits it.
local B = "P1 Block"
local D, U, N, H = {B, "P1 Down"}, {B, "P1 Up"}, {B}, {B, "P1 High Punch"}
local SEQ = {
    mk3    = { {6, N}, {4, D}, {2, N}, {4, D}, {2, N}, {4, U}, {2, N}, {4, U}, {2, N}, {4, U}, {2, N},
               {6, H} },
    toasty = { {6, N}, {4, D}, {2, N}, {4, D}, {2, N}, {4, U}, {2, N}, {4, U}, {2, N},
               {6, H} },
    lk     = { {6, {}}, {5, {B}}, {4, {}} },
}
if WHO == "lk" then MODE = "lk" end
local seq = SEQ[MODE] or (MODE == "peek" and {}) or error("SC_MODE=mk3|toasty|peek")

-- DAN FORDEN'S LINE.  crispy_roll (MAIN.ASM) is blood_randper(333) and the
-- peek's own gate is randper(40): both xorshift32, hit iff (x*1000)>>32 < odds.
-- SC_FORCE=crispy|toasty pins the outcome by re-writing the seed every frame,
-- so whatever draw happens next comes out of that one seed.
local FORCE = os.getenv("SC_FORCE")
local function xs(x)
    x = x ~ ((x << 13) & 0xffffffff); x = x ~ (x >> 17); x = x ~ ((x << 5) & 0xffffffff)
    return x & 0xffffffff
end
local function seed_for(test)
    for sd = 1, 100000 do if test(((xs(sd) * 1000) >> 32)) then return sd end end
    error("no seed")
end
local BSEED = FORCE == "crispy" and seed_for(function(v) return v < 333 end)
           or FORCE == "toasty" and seed_for(function(v) return v >= 333 end) or nil
local RSEED = seed_for(function(v) return v < 40 end)    -- the peek's 4% gate, forced on
local TOASTY_TRK, CRISPY_TRK = {0x0285, 0x0287}, {0x00b5, 0x00b7}

local started, sel, fight, confirm, ill0 = false, nil, nil, nil, nil
local phase, t0, seq_i, seq_t = "ko", 0, 1, 0
local fat_seen, done_at = nil, nil
local function place(gap)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local cam = s16(r16(A.worldtlx + 16))
    local x1 = cam + 120
    w16(p1o + O.oxpos, x1); w32(p1o + O.oxval, (x1 << 16) & 0xffffffff)
    w16(p2o + O.oxpos, x1 + gap); w32(p2o + O.oxval, ((x1 + gap) << 16) & 0xffffffff)
end
local function quit(msg) log("%s", msg); f:close(); manager.machine:exit() end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
        log("start mode=%s  SKELFIRE range %08X..%08X (%d records)  taps %d", MODE, LO, HI, NREC, #taps)
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
            w16(A.p1_char, P1CH); w16(A.p2_char, 11); w16(A.curback, 0)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then
            fight = frame; ill0 = r16(A.illop_count); t0 = frame
            log("fight at %d, p1 ochar %d", frame, r16(r32(A.p1_obj) + O.ochar))
            w16(A.p1_matchw, 1); w16(A.p2_bar, 1)
        end
        if frame > 12000 then quit("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then
        quit(string.format("FAIL illop_count moved (a reboot), phase %s", phase)); return
    end
    local p1o = r32(A.p1_obj)
    if p1o == 0 then return end
    local rel = frame - t0
    local fd = r16(A.f_death)
    if armed and BSEED then w32(A.blood_rand, BSEED) end
    if MODE == "peek" and phase == "ko" then phase = "peek"; t0 = frame; armed = true; rel = 0 end
    if phase == "peek" then
        -- 2P, nobody dies: both bars pinned.  Uppercut (Down + HP) at 50px,
        -- every 90 ticks; @rand pinned so upcut_comment's randper(40) always
        -- takes the peek, @blood_rand by SC_FORCE so the line is decided.
        w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
        w32(A.rand, RSEED)
        local k = rel % 90
        if k < 30 then place(50) end
        F["P1 Down"]:set_value((k >= 30 and k < 50) and 1 or 0)
        F["P1 High Punch"]:set_value((k >= 38 and k < 42) and 1 or 0)
        local said_c, said_t = saw(CRISPY_TRK[1], CRISPY_TRK[2]), saw(TOASTY_TRK[1], TOASTY_TRK[2])
        if said_c or said_t then
            if not _G.SC_SAID then _G.SC_SAID = frame; log("Forden said %s at %d", said_c and "CRISPY (00B5)" or "TOASTY (0285)", frame) end
            if frame == _G.SC_SAID + 12 then manager.machine.video:snapshot() end
            if frame >= _G.SC_SAID + 30 then
                local want = FORCE == "crispy" and said_c and not said_t or FORCE == "toasty" and said_t and not said_c
                quit(want and ("PASS (peek, forced " .. FORCE .. ")") or ("FAIL - peek forced " .. tostring(FORCE) ..
                    string.format(", heard crispy %s toasty %s", tostring(said_c), tostring(said_t))))
            end
        end
        if rel > 1200 then quit("FAIL - no Forden peek in 1200 ticks (uppercuts not connecting?)") end
        return
    end
    if phase == "ko" then
        if r16(A.p1_bar) < 60 then w16(A.p1_bar, 0xa1) end
        place(70)
        if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
        F["P1 High Punch"]:set_value((rel % 16) < 5 and 1 or 0)
        if r16(A.winner_status) == 3 then
            log("FINISH HIM at +%d, p1 ochar %d", rel, r16(p1o + O.ochar))
            if r16(p1o + O.ochar) ~= P1CH then quit("P1 is the wrong fighter - NO VERDICT") return end
            phase = "wait"; t0 = frame
        end
        if rel > 1500 then quit("never reached FINISH HIM - NO VERDICT") end
        return
    end
    if phase == "wait" then
        if WHO == "lk" then
            w16(p1o + 0x160, r16(p1o + 0x160) | 0x0040)   -- m_ugly_pal: the Start+LP Kang
            place(150)
        else
            place(100)
        end
        if rel >= 40 then phase = "input"; t0 = frame; seq_i, seq_t = 1, 0; armed = true end
        return
    end
    if phase == "input" then
        local st = seq[seq_i]
        for _, n in ipairs(st[2]) do F[n]:set_value(1) end
        seq_t = seq_t + 1
        if seq_t >= st[1] then seq_i = seq_i + 1; seq_t = 0 end
        if fd ~= 0 and not fat_seen then fat_seen = fd; log("f_death %d at input +%d", fd, rel) end
        if seq_i > #seq then phase = "watch"; t0 = frame end
        return
    end
    if phase == "watch" and _G.SC_PROBE and frame <= _G.SC_PROBE + 10 then
        local p, n, out = r32(A.active), 0, {}
        while p ~= 0 and n < 200 do
            if r16(p + 0x20) == 0x0100 then
                out[#out + 1] = string.format("[%08X wake %s t%d a8 %08X]", p, sym(r32(p + 0xe0)),
                    r16(p + 0x30), r32(p + 0xc0))
            end
            p = r32(p); n = n + 1
        end
        log("PROBE f%d (+%d) pid_fx: %s", frame, frame - _G.SC_PROBE, table.concat(out, " "))
    end
    if phase == "watch" then
        if rel % 8 == 0 and rel <= 700 then manager.machine.video:snapshot() end
        if fd ~= 0 and not fat_seen then fat_seen = fd; log("f_death %d at watch +%d", fd, rel) end
        if fat_seen and fd == 0xffff and not done_at then done_at = rel; log("death_blow_complete at +%d", rel) end
        if rel % 30 == 0 then
            local p2o = r32(A.p2_obj)
            log("  +%d p1act %04X p2act %04X f_death %04X p2 oflags2 %04X  skelfire sags %d blits %d",
                rel, r16(r32(A.p1_proc) + P.action), r16(r32(A.p2_proc) + P.action), fd,
                p2o ~= 0 and r16(p2o + 0x160) or 0, skel_n, skel_commits)
        end
        if rel >= 900 then
            log("SKELFIRE first-drawn (name@frame): %s", table.concat(ORDER, " "))
            log("missing: %d of %d records", NREC - skel_n, NREC)
            log("sound latch bytes (frame:byte): %s", table.concat(SND, " "))
            log("mode %s: f_death %s, complete %s, SKELFIRE-range SAGs %d (%d blits)",
                MODE, tostring(fat_seen), tostring(done_at), skel_n, skel_commits)
            local fired = fat_seen == (MODE == "lk" and 12 or 1) and done_at ~= nil
            if not fired then quit("FAIL - the fatality did not run") return end
            if MODE == "mk3" or MODE == "lk" then
                -- the whole burn, collapse included: every record in the pack
                local scream = saw(0x027c, 0x027e) or saw(0x02e0, 0x02e2) or saw(0x030f, 0x0311)
                local fall = saw(0x00b2, 0x00b4)
                log("burn scream (027C/02E0/030F) at %s, ScorpFall (00B2) at %s, SKELFIRE24A drawn %s",
                    tostring(scream), tostring(fall), tostring(_G.SC_LAST))
                local why = {}
                if skel_n < NREC then why[#why + 1] = string.format("only %d of %d SKELFIRE records drawn", skel_n, NREC) end
                if not scream then why[#why + 1] = "no burn scream" end
                if not fall then why[#why + 1] = "no ScorpFall" end
                if MODE == "mk3" and not saw(CRISPY_TRK[1], CRISPY_TRK[2]) then why[#why + 1] = "Dan did not say CRISPY" end
                if MODE == "mk3" and saw(TOASTY_TRK[1], TOASTY_TRK[2]) then why[#why + 1] = "Dan said TOASTY" end
                if fall and _G.SC_PROBE and fall < _G.SC_PROBE - 2 then why[#why + 1] = "ScorpFall before the collapse" end  -- sent the tick before SKELFIRE17 is blitted
                quit(#why == 0 and "PASS" or ("FAIL - " .. table.concat(why, "; ")))
            else
                local c, t = saw(CRISPY_TRK[1], CRISPY_TRK[2]), saw(TOASTY_TRK[1], TOASTY_TRK[2])
                log("toasty pop-up: crispy %s toasty %s (forced %s)", tostring(c), tostring(t), tostring(FORCE))
                local why = {}
                if skel_n ~= 0 then why[#why + 1] = "control drew SKELFIRE" end
                if FORCE == "crispy" and not (c and not t) then why[#why + 1] = "forced CRISPY not heard alone" end
                if FORCE == "toasty" and not (t and not c) then why[#why + 1] = "forced TOASTY not heard alone" end
                if not FORCE and not (c or t) then why[#why + 1] = "no Forden line at all" end
                quit(#why == 0 and "PASS (control: stock MK2 burn, no SKELFIRE)" or ("FAIL - " .. table.concat(why, "; ")))
            end
        end
    end
end)
