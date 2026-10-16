-- iceooo_test.lua
-- PROVE iceooo (MAINEQU.ASM): the crowd goes "ooo" when somebody is frozen
-- IN THE AIR (r_ice, MKREACT.ASM - Midway's dead hook, now a direct
-- triple_sound2 34h = track 024bh, "crowd ooo").
--
-- 2P, P1 Sub-Zero vs P2 Reptile, both driven by the rig.  Each trial Sub-Zero
-- throws the standing ice blast (D,F+LP) at a fixed beat, and Reptile jumps
-- STRAIGHT UP (Up) at a different offset from that beat, so the ice meets him
-- at different heights - or on the ground.  `ground` never jumps: the control.
--
-- On the tick P2 enters act_frozen (0401h) the rig records his height above
-- the floor; every sound-latch code in the 8 ticks either side is attributed
-- to that freeze.  The latch carries the DCS TRACK (raiden_dive_force_probe),
-- and triple_sound* adds the channel it lands on (0-2), so "ooo" is
-- 024bh..024dh.
--
-- PASS: the grounded control froze with NO ooo; at least one trial froze him
-- IN THE AIR; and every airborne freeze had the ooo and every grounded one
-- did not.  Nothing else in these trials plays 024bh (no uppercut lands).
--
-- IOO_NEG=1 is the control: NOPs the `calla triple_sound2` after `movi 034h`
-- in the :maincpu region and keeps the expectations, so it must FAIL.
--
-- env: IOO_LOG, IOO_MAP
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOGP = os.getenv("IOO_LOG") or (ROOT .. "/tools/iceooo_test.log")
local NEG = (os.getenv("IOO_NEG") or "0") ~= "0"
local logfh = assert(io.open(LOGP, "w"))
local function log(fmt, ...)
    local s = "[iceooo] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do local fh = assert(io.open(os.getenv("IOO_MAP") or (ROOT .. "/src/mk2.map"), "r"))
  for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
  fh:close() end
local need = { "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
  "p1_obj", "p2_obj", "p1_proc", "p2_proc", "p1_bar", "p2_bar", "p1_bar_view",
  "p2_bar_view", "winner_status", "f_freeze_timer", "triple_sound2", "am_i_airborn" }
local A, miss = {}, {}
for _, n in ipairs(need) do A[n] = symbols[n]; if not A[n] then miss[#miss+1] = n end end

local OXVAL, OYPOS, P_ACTION = 0x080, 0x0b0, 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_THROW_ICE, ACT_FROZEN = 0x0010, 0x0401
local SND_PORT, SND_LO, SND_HI = 0x01d01030, 0x01d00000, 0x01d01fff
local OOO_LO, OOO_HI = 0x024b, 0x024d

local SZ_X, GAP = 220, 150
local LP_AT = 54                 -- D 40..48, F 48..56, LP 54..60 (juggle rig's beat)
-- jump offset from the LP press; nil = never jump
local TRIALS = { {name = "ground"}, {name = "j-20", j = -20}, {name = "j-14", j = -14},
                 {name = "j-8", j = -8}, {name = "j-2", j = -2}, {name = "j+4", j = 4},
                 {name = "j+10", j = 10} }
local TRIAL_FRAMES = 360

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local ti, tstart = 1, 0
local fields, done = {}, false
local FLOOR_Y = 0
local cur, results = nil, {}
local sounds, snd_hi, snd_tap = {}, nil, nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function pact(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + P_ACTION) end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end

local function on_sound(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    sounds[#sounds + 1] = { code = (snd_hi << 8) | (w & 0xff), f = frame }; snd_hi = nil
    return data
end

local function finish()
    if done then return end
    done = true
    local ok, why, nair = true, {}, 0
    for _, t in ipairs(TRIALS) do
        local r = results[t.name]
        if not r or not r.froze_at then
            log("RESULT %-5s no freeze (cast=%s) - NO VERDICT for this trial", t.name, r and tostring(r.cast) or "?")
        else
            local codes = {}
            for _, s in ipairs(sounds) do
                if math.abs(s.f - r.froze_at) <= 8 then codes[#codes + 1] = string.format("%04x@%+d", s.code, s.f - r.froze_at) end
            end
            local ooo = false
            for _, s in ipairs(sounds) do
                if math.abs(s.f - r.froze_at) <= 8 and s.code >= OOO_LO and s.code <= OOO_HI then ooo = true end
            end
            local air = r.h > 0
            if air then nair = nair + 1 end
            local want = air
            local good = (ooo == want)
            if not good then ok = false; why[#why + 1] = string.format("%s: %s freeze %s the ooo",
                t.name, air and "AIRBORNE" or "grounded", ooo and "WITH" or "WITHOUT") end
            log("RESULT %-5s froze %s (%dpx up)  ooo=%s  %s  latch[%s]", t.name,
                air and "IN THE AIR" or "on the ground", r.h, ooo and "YES" or "no",
                good and "ok" or "WRONG", table.concat(codes, " "))
        end
    end
    local g = results["ground"]
    if not g or not g.froze_at then ok = false; why[#why + 1] = "the grounded control never froze - the rig, not the ROM" end
    if nair == 0 then ok = false; why[#why + 1] = "no trial froze him in the air - nothing was tested" end
    if NEG then
        log("%s iceooo (NEGATIVE control: the ooo call is NOPd - FAIL is the expected result)%s",
            ok and "PASS" or "FAIL", ok and "" or (": " .. table.concat(why, "; ")))
    else
        log("%s iceooo%s", ok and "PASS" or "FAIL", ok and "" or (": " .. table.concat(why, "; ")))
    end
    logfh:close(); manager.machine:exit()
end

-- calla am_i_airborn / jrnc / movi 034h,a0 (09C0 0034) / calla (0D5F) triple_sound2
local function locate()
    local reg = manager.machine.memory.regions[":maincpu"]
    local t = A.triple_sound2
    local pat = {0xC0, 0x09, 0x34, 0x00, 0x5F, 0x0D, t & 0xff, (t >> 8) & 0xff, (t >> 16) & 0xff, (t >> 24) & 0xff}
    local hits = {}
    for i = 0, reg.size - 12, 2 do
        if reg:read_u8(i) == 0xC0 and reg:read_u8(i + 1) == 0x09 then
            local okp = true
            for k = 3, #pat do if reg:read_u8(i + k - 1) ~= pat[k] then okp = false; break end end
            -- r_ice's: calla am_i_airborn (6 bytes) + jrnc (2) right before it
            local c = A.am_i_airborn
            if okp and i >= 8 and reg:read_u8(i - 8) == 0x5F and reg:read_u8(i - 7) == 0x0D
               and (reg:read_u8(i - 6) | (reg:read_u8(i - 5) << 8) | (reg:read_u8(i - 4) << 16)
                    | (reg:read_u8(i - 3) << 24)) == c then hits[#hits + 1] = i end
        end
    end
    return reg, hits
end

local function cache_fields()
    local want = { "Coin 1", "Coin 2", "1 Player Start", "2 Players Start", "P1 High Punch",
                   "P1 Low Punch", "P1 Right", "P1 Down", "P2 High Punch", "P2 Up" }
    local w = {}
    for _, n in ipairs(want) do w[n] = true end
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if w[f.name] then fields[f.name] = f end end
    end
    local m = {}
    for _, n in ipairs(want) do if not fields[n] then m[#m + 1] = n end end
    return m
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 then
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
            if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
        end
        return false
    end
    local r = frame - tstart
    if name == "P1 Down" then return r >= 40 and r < 48 end
    if name == "P1 Right" then return r >= 48 and r < 56 end
    if name == "P1 Low Punch" then return r >= LP_AT and r < LP_AT + 6 end
    local t = TRIALS[ti]
    if name == "P2 Up" and t and t.j then local s = LP_AT + t.j; return r >= s and r < s + 4 end
    return false
end

emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if #miss > 0 then log("FAIL iceooo: missing symbols %s", table.concat(miss, ",")); return finish() end
        local m = cache_fields()
        if #m > 0 then log("FAIL iceooo: missing inputs %s", table.concat(m, ",")); return finish() end
        local reg, hits = locate()
        if #hits ~= 1 then
            log("FAIL iceooo: movi 034h + calla triple_sound2 found %d times, want 1 - an iceooo 0 ROM has none", #hits)
            return finish()
        end
        if NEG then
            for k = 4, 9, 2 do reg:write_u8(hits[1] + k, 0x00); reg:write_u8(hits[1] + k + 1, 0x03) end
            log("NEGATIVE: the ooo call NOPd at :maincpu+%x", hits[1] + 4)
        else
            log("ooo call present at :maincpu+%x", hits[1])
        end
        local okt, err = pcall(function() snd_tap = space:install_write_tap(SND_LO, SND_HI, "ioo_snd", on_sound) end)
        if not okt then log("FAIL iceooo: sound tap %s", tostring(err)); return finish() end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_REPTILE); w16(A.curback, 0)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; tstart = frame + 60
        log("fight at %d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("FAIL iceooo: never reached a fight"); finish() end
        return
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    w16(A.winner_status, 0); w16(A.f_freeze_timer, 1)
    if frame < tstart then return end
    if frame == tstart then
        FLOOR_Y = gety(A.p2_obj) or 0
        cur = { cast = false }
        log("trial %s: floor y %d", TRIALS[ti].name, FLOOR_Y)
    end

    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    if not cur.cast then setx(A.p1_obj, SZ_X) end
    if not cur.froze_at then setx(A.p2_obj, SZ_X + GAP) end
    if a1 == ACT_THROW_ICE and not cur.cast then cur.cast = true; log("  ice thrown at r=%d", frame - tstart) end
    if a2 == ACT_FROZEN and not cur.froze_at then
        local y = gety(A.p2_obj) or FLOOR_Y
        cur.froze_at, cur.h = frame, FLOOR_Y - y
        log("  FROZE at r=%d, %d px up", frame - tstart, cur.h)
    end
    if frame - tstart >= TRIAL_FRAMES then
        results[TRIALS[ti].name] = cur
        ti = ti + 1
        if ti > #TRIALS then return finish() end
        tstart = frame + 1
    end
    if frame > 20000 then log("FAIL iceooo: backstop"); finish() end
end)
