-- frosty_test.lua
-- PROVE frosty (MAINEQU.ASM): UMK3's "Frosty!" - r_ice (MKREACT.ASM) spawns
-- frosty_peek (BGND.ASM) when the man being frozen has <= 8 on his bar, and
-- Dan Forden peeks in saying FROSTY (triple_sndtab 102h = track 0373h..0375h).
--
-- 2P, P1 Sub-Zero throws the standing ice (D,F+LP) at a grounded P2 Reptile.
-- Each trial holds P2's bar at a value until he freezes; the rig logs the bar
-- on the freeze tick, whether a pid_forden (010fh) process came up, the FROSTY
-- track on the sound latch, and whether @toasty was stamped (it must NOT be -
-- only a real Toasty opens Smoke's window).
--
-- PASS: every trial whose bar AT THE FREEZE is <= 8 has forden + FROSTY and
-- leaves @toasty alone; every trial above 8 has neither.  At least one of each.
-- FRO_NEG=1 patches `cmpi 8` to `cmpi -1` (never) in :maincpu: must FAIL.
--
-- env: FRO_LOG, FRO_MAP
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOGP = os.getenv("FRO_LOG") or (ROOT .. "/tools/frosty_test.log")
local NEG = (os.getenv("FRO_NEG") or "0") ~= "0"
local logfh = assert(io.open(LOGP, "w"))
local function log(fmt, ...)
    local s = "[frosty] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do local fh = assert(io.open(os.getenv("FRO_MAP") or (ROOT .. "/src/mk2.map"), "r"))
  for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
  fh:close() end
local need = { "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
  "p1_obj", "p2_obj", "p1_proc", "p2_proc", "p1_bar", "p2_bar", "p1_bar_view",
  "p2_bar_view", "winner_status", "f_freeze_timer", "active", "toasty", "frosty_peek" }
local A, miss = {}, {}
for _, n in ipairs(need) do A[n] = symbols[n]; if not A[n] then miss[#miss+1] = n end end

local OXVAL, OYPOS, P_ACTION = 0x080, 0x0b0, 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_THROW_ICE, ACT_FROZEN = 0x0010, 0x0401
local SND_PORT, SND_LO, SND_HI = 0x01d01030, 0x01d00000, 0x01d01fff
local FRO_LO, FRO_HI = 0x0373, 0x0375
local PID_FORDEN, PROCID, PLINK = 0x010f, 0x20, 0x0

local SZ_X, GAP = 220, 150
local LP_AT = 54                 -- D 40..48, F 48..56, LP 54..60 (juggle rig's beat)
-- jump offset from the LP press; nil = never jump
-- bar = P2's bar, held until the ice is THROWN; the hit then takes its own 10
local TRIALS = { {name = "full", bar = MAX_HP}, {name = "bar19", bar = 19}, {name = "bar18", bar = 18},
                 {name = "bar12", bar = 12}, {name = "bar9", bar = 9} }   -- bar9 is a KO by ice: it ends the round, so it goes last
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
    local ok, why, nlow, nhigh = true, {}, 0, 0
    for _, t in ipairs(TRIALS) do
        local r = results[t.name]
        if not r or not r.froze_at then
            log("RESULT %-6s no freeze (cast=%s) - NO VERDICT for this trial", t.name, r and tostring(r.cast) or "?")
        else
            local fro, codes = false, {}
            for _, s in ipairs(sounds) do
                local d = s.f - r.froze_at
                if d >= -4 and d <= 90 then
                    codes[#codes + 1] = string.format("%04x@%+d", s.code, d)
                    if s.code >= FRO_LO and s.code <= FRO_HI then fro = true end
                end
            end
            local want = r.bar <= 8
            if want then nlow = nlow + 1 else nhigh = nhigh + 1 end
            local good = (fro == want) and ((r.forden or false) == want) and not r.toasty
            if not good then ok = false; why[#why + 1] = string.format("%s: bar %d forden=%s frosty=%s toasty=%s",
                t.name, r.bar, tostring(r.forden), tostring(fro), tostring(r.toasty)) end
            log("RESULT %-6s bar@freeze=%3d  forden=%s(+%s)  FROSTY=%s  toasty_stamped=%s  %s  latch[%s]", t.name, r.bar,
                r.forden and "YES" or "no", tostring(r.forden_at or "-"), fro and "YES" or "no",
                r.toasty and "YES" or "no", good and "ok" or "WRONG", table.concat(codes, " "))
        end
    end
    if nlow == 0 then ok = false; why[#why + 1] = "no freeze at <= 8 - nothing was tested" end
    if nhigh == 0 then ok = false; why[#why + 1] = "no control freeze above 8" end
    log("%s frosty%s%s", ok and "PASS" or "FAIL", NEG and " (NEGATIVE control - FAIL expected)" or "",
        ok and "" or (": " .. table.concat(why, "; ")))
    logfh:close(); manager.machine:exit()
end

local function forden_alive()
    local p = r32(A.active)
    local n = 0
    while p ~= 0 and n < 300 do
        if r16(p + PROCID) == PID_FORDEN then return true end
        p = r32(p + PLINK); n = n + 1
    end
    return false
end

-- create frosty_peek = movi frosty_peek,a7,l: the long address appears exactly once.
local function locate()
    local reg = manager.machine.memory.regions[":maincpu"]
    local t = A.frosty_peek
    local hits = {}
    for i = 0, reg.size - 8, 2 do
        if (reg:read_u8(i) | (reg:read_u8(i + 1) << 8) | (reg:read_u8(i + 2) << 16) | (reg:read_u8(i + 3) << 24)) == t then
            hits[#hits + 1] = i
        end
    end
    return reg, hits
end

local function cache_fields()
    local want = { "Coin 1", "Coin 2", "1 Player Start", "2 Players Start", "P1 High Punch",
                   "P1 Low Punch", "P1 Right", "P1 Down", "P2 High Punch" }
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
    return false
end

emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if #miss > 0 then log("FAIL frosty: missing symbols %s", table.concat(miss, ",")); return finish() end
        local m = cache_fields()
        if #m > 0 then log("FAIL frosty: missing inputs %s", table.concat(m, ",")); return finish() end
        local reg, hits = locate()
        if #hits ~= 1 then log("FAIL frosty: frosty_peek's address found %d times in :maincpu, want 1", #hits); return finish() end
        -- the guard `cmpi 8,a0` in front of the create: dump the words and find 0B20 + imm
        local ci, dump = nil, {}
        for k = hits[1] - 30, hits[1] - 2, 2 do
            local w = reg:read_u8(k) | (reg:read_u8(k + 1) << 8)
            dump[#dump + 1] = string.format("%04x", w)
            if w == 0x0B40 then ci = k end   -- CMPI IW,A0 (0B40|reg; the word holds ~imm)
        end
        log("words before create: %s", table.concat(dump, " "))
        if not ci then log("FAIL frosty: no cmpi a0 in front of create frosty_peek"); return finish() end
        local imm = reg:read_u8(ci + 2) | (reg:read_u8(ci + 3) << 8)
        log("cmpi at :maincpu+%x imm word %04x", ci, imm)
        if NEG then
            -- the word is ~imm: 8000h = cmpi 7fffh, and no bar is unsigned-higher than that
            reg:write_u8(ci + 2, 0x00); reg:write_u8(ci + 3, 0x80)
            log("NEGATIVE: guard immediate zeroed at :maincpu+%x", ci + 2)
        end
        local okt, err = pcall(function() snd_tap = space:install_write_tap(SND_LO, SND_HI, "fro_snd", on_sound) end)
        if not okt then log("FAIL frosty: sound tap %s", tostring(err)); return finish() end
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
        if frame > 6000 then log("FAIL frosty: never reached a fight"); finish() end
        return
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.f_freeze_timer, 1)
    if frame < tstart then
        w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP); w16(A.winner_status, 0)
        return
    end
    if frame == tstart then
        cur = { cast = false, toasty0 = r16(A.toasty) }
        log("trial %s", TRIALS[ti].name)
    end
    local t = TRIALS[ti]
    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    if not cur.cast then setx(A.p1_obj, SZ_X); w16(A.winner_status, 0) end
    if not cur.froze_at then setx(A.p2_obj, SZ_X + GAP) end
    if not cur.cast then w16(A.p2_bar, t.bar); w16(A.p2_bar_view, t.bar) end   -- let go at the throw: the hit's own damage shows
    if a1 == ACT_THROW_ICE and not cur.cast then cur.cast = true; log("  ice thrown at r=%d", frame - tstart) end
    if a2 == ACT_FROZEN and not cur.froze_at then
        cur.froze_at, cur.bar = frame, r16(A.p2_bar)
        log("  FROZE at r=%d, bar %d, winner_status %d", frame - tstart, cur.bar, r16(A.winner_status))
    end
    if cur.froze_at and not cur.forden and frame - cur.froze_at <= 60 and forden_alive() then
        cur.forden, cur.forden_at = true, frame - cur.froze_at
    end
    if cur.froze_at and r16(A.toasty) ~= cur.toasty0 then cur.toasty = true end
    if frame - tstart >= TRIAL_FRAMES then
        results[t.name] = cur
        ti = ti + 1
        if ti > #TRIALS then return finish() end
        tstart = frame + 30
    end
    if frame > 20000 then log("FAIL frosty: backstop"); finish() end
end)
