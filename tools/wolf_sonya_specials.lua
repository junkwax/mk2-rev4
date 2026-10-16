-- wolf_sonya_specials.lua - MK3 SONYA's specials on the Wolf build (ochar 20).
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
                    "curback", "illop_count", "p1_bar", "p2_bar", "worldtlx"}) do
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

-- each special: name, gap, inputs per frame (frame -> list), expected action
local SPECIALS = {
    { name = "RINGS", gap = 200, act = 0x0008,
      seq = { {4, {"P1 Down"}}, {3, {"P1 Down", "P1 Right"}}, {3, {"P1 Right"}}, {4, {"P1 Low Punch"}} } },
    { name = "SQUARE", gap = 170, act = 0x0207,
      seq = { {4, {"P1 Right"}}, {3, {}}, {4, {"P1 Left"}}, {4, {"P1 High Punch"}} } },
    { name = "LEGS", gap = 75, act = ACT_LEGGRAB,
      seq = { {6, {"P1 Down"}}, {6, {"P1 Down", "P1 Block"}}, {6, {"P1 Down", "P1 Block", "P1 Low Punch"}} } },
    { name = "BIKE", gap = 110, act = ACT_BIKE,
      seq = { {4, {"P1 Left"}}, {3, {}}, {4, {"P1 Left"}}, {4, {"P1 Down"}}, {4, {"P1 High Kick"}} } },
}

-- WS_ONLY=NAME,...: run just those
if os.getenv("WS_ONLY") then
    local keep = {}
    for _, sp in ipairs(SPECIALS) do
        if (","..os.getenv("WS_ONLY")..","):find(","..sp.name..",", 1, true) then keep[#keep + 1] = sp end
    end
    SPECIALS = keep
end
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local phase, t0, sp_i, trial, seq_i, seq_t = "morph", 0, 1, 1, 1, 0
-- WS_SND=1: log what is written to the Wolf sound port (01680000h) per trial
local snd_log, snd_tap = {}, nil
local function on_sound(offset, data, mask)
    snd_log[#snd_log + 1] = string.format("%04X@%d", data & 0xffff, frame - t0)
    return data
end
local res = {}
local saw_act, bar0, hit, snapped = false, 0, 0, false

local function place(gap)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local cam = s16(r16(A.worldtlx + 16))
    local x1 = cam + 100
    w16(p1o + O.oxpos, x1); w32(p1o + O.oxval, (x1 << 16) & 0xffffffff)
    w16(p2o + O.oxpos, x1 + gap); w32(p2o + O.oxval, ((x1 + gap) << 16) & 0xffffffff)
end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    if os.getenv("WS_SND") and not snd_tap then
        snd_tap = space:install_write_tap(0x01680000, 0x0168001f, "wsny_snd", on_sound)
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
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); t0 = frame; log("fight at %d", frame) end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    if r16(A.illop_count) ~= ill0 then
        local cpu = manager.machine.devices[":maincpu"]
        log("FAIL illop_count moved (a reboot): illop_pc %08X, %s act %04X", r32(S.illop_pc),
            SPECIALS[sp_i] and SPECIALS[sp_i].name or "?", r16(r32(A.p1_proc) + P.action))
        f:close(); manager.machine:exit(); return
    end
    local p1o = r32(A.p1_obj)
    if p1o == 0 then return end
    local och = r16(p1o + O.ochar)
    local act = r16(r32(A.p1_proc) + P.action)
    if r16(A.p1_bar) < 60 then w16(A.p1_bar, 0xa1) end
    local rel = frame - t0
    if phase == "morph" then
        if rel >= 30 then
            local k = (rel - 30) % 60
            F["P1 Down"]:set_value(k < 20 and 1 or 0)
            F["P1 Block"]:set_value(k < 20 and 1 or 0)
            F["P1 Low Punch"]:set_value((k >= 8 and k < 12) and 1 or 0)
        end
        if och == 20 and act ~= 0x0404 then
            log("MORPHED at %d", frame); phase = "reset"; t0 = frame
        end
        if rel > 900 then log("FAIL never morphed"); f:close(); manager.machine:exit() end
        return
    end
    local sp = SPECIALS[sp_i]
    if phase == "reset" then
        if och ~= 20 then phase = "morph"; t0 = frame; return end
        place(sp.gap)
        w16(A.p2_bar, 0xa1)
        if rel >= 40 then
            phase = "input"; t0 = frame; seq_i, seq_t = 1, 0
            snd_log = {}
            saw_act, hit, snapped = false, 0, false
            bar0 = r16(A.p2_bar)
        end
        return
    end
    if phase == "input" then
        local st = sp.seq[seq_i]
        for _, n in ipairs(st[2]) do F[n]:set_value(1) end
        seq_t = seq_t + 1
        if seq_t >= st[1] then seq_i = seq_i + 1; seq_t = 0 end
        if seq_i > #sp.seq then phase = "watch"; t0 = frame end
        return
    end
    if phase == "watch" then
        if act == sp.act then saw_act = true end
        if os.getenv("WS_TRACE") and rel < 150 and (os.getenv("WS_TRACE") == "1" or os.getenv("WS_TRACE") == sp.name) then
            log("  %s+%d p1act %04X p2act %04X p2bar %d sudden %d round %d", sp.name, rel, act,
                r16(r32(A.p2_proc) + P.action), r16(A.p2_bar), r16(S.f_sudden), r16(S.round_num))
        end
        if false then
            log("  %s+%d act %04X oypos %d oyvel %08X ganiy %d ograv %08X", sp.name, rel, act,
                s16(r16(p1o + 0x0b0)), r32(p1o + 0x060), s16(r16(r32(A.p1_proc) + 0x200)), r32(p1o + 0x020))
        end
        local b = r16(A.p2_bar)
        if b < bar0 then
            if hit == 0 and os.getenv("WS_SND") then log("  %s: Jax hit at +%d", sp.name, rel) end
            hit = bar0 - b
        end
        if os.getenv("WS_COLBOX") then space:write_u16(S.f_colbox, 5) end
        if (rel == 14 or (os.getenv("WS_COLBOX") and rel % 4 == 0 and rel <= 40)
            or (os.getenv("WS_FILM") and trial == 1 and rel % 5 == 0 and rel <= 110)) then manager.machine.video:snapshot() end
        if rel >= 150 then
            log("%s trial %d: action %04X seen %s, Jax took %d", sp.name, trial,
                sp.act, tostring(saw_act), hit)
            res[#res + 1] = { sp.name, saw_act and hit > 0 }
            if os.getenv("WS_SND") then
                local t = {}
                for _, v in ipairs(snd_log) do t[#t + 1] = v end
                log("  %s sound port: %s", sp.name, table.concat(t, " "))
            end
            trial = trial + 1
            if trial > TRIALS then trial = 1; sp_i = sp_i + 1 end
            if sp_i > #SPECIALS then
                local ok = 0
                for _, r in ipairs(res) do if r[2] then ok = ok + 1 end end
                log("%d of %d trials thrown and landed", ok, #res)
                log(ok == #res and "PASS" or "FAIL")
                f:close(); manager.machine:exit(); return
            end
            phase = "reset"; t0 = frame
        end
    end
end)
