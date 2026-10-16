-- sz_floorice_corner_test.lua - SUB-ZERO'S GROUND FREEZE IN THE CORNER (szicecorner).
--
-- Retail refused the floor ice when the victim was within 060h of a stage
-- edge (sz_lo_kick, MOVES.ASM; dzl_puddle, MKDRONE.ASM).  The reason is in
-- r_floor_ice (MKREACT.ASM): each slip leg sets the velocity ONCE and runs
-- until the victim is 5px from that end of the puddle.  In a corner the
-- puddle reaches past the wall clamp (gravity_n_bounds), which zeroes his
-- velocity short of the end, so the leg never finishes and he stands still in
-- the slip pose until the timer runs out.  szicecorner drops the gate and pulls
-- both puddle ends in to the clamp before the slip starts.
--
-- Three trials, each a real D,B+LK cast at a pinned 090h gap:
--   mid    - the middle of the stage: retail behaviour, must be unchanged
--   right  - victim against the right wall
--   left   - victim against the left wall (Sub-Zero faces left, Back = Right)
-- Verdict per trial: the cast came out, the victim slipped, and he was never
-- STUCK - no run of more than SZC_STUCK consecutive slipping ticks with his x
-- unchanged.  Reversals and the x range are logged for the reader.
--
-- SZC_NEG=1 NOPs the two `move a0,a10` / `move a0,a11` that do the clamp, in
-- the :maincpu region (located by their bytes - a ROM without the clamp is
-- refused, not measured).  Both corner trials must then FAIL as stuck, and the
-- mid trial must still PASS: that is what says the detector is measuring the
-- clamp and not something else.
--
--   SZC_LOG  log path   SZC_MAP  the map that belongs to the zip   SZC_NEG 0/1

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOGP = os.getenv("SZC_LOG") or (ROOT .. "/tools/sz_floorice_corner_test.log")
local NEG = (os.getenv("SZC_NEG") or "0") ~= "0"
local STUCK_MAX = tonumber(os.getenv("SZC_STUCK") or "3")
local logfh = assert(io.open(LOGP, "w"))
local function log(fmt, ...)
    local s = "[szc] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do local fh = assert(io.open(os.getenv("SZC_MAP") or (ROOT .. "/src/MK2.MAP"), "r"))
  for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
  fh:close() end
local need = { "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
  "p1_obj", "p2_obj", "p1_proc", "p2_proc", "p1_bar", "p2_bar", "p1_bar_view",
  "p2_bar_view", "winner_status", "f_freeze_timer", "left_edge", "right_edge" }
local A, miss = {}, {}
for _, n in ipairs(need) do A[n] = symbols[n]; if not A[n] then miss[#miss+1] = n end end

local OXVAL, OXPOS, P_ACTION = 0x080, 0x090, 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_FLOOR_ICE, ACT_SLIPPING = 0x0134, 0x060e
local SCRRGT, LEFT_PAD, RIGHT_PAD = 399, 0x3a, 0x30     -- DISPEQU / MAINEQU
-- the gap is per trial (TRIALS below)
local SETTLE, TRIAL_FRAMES = 120, 420                    -- > l_pud's 040h*3 between casts

-- gap = Sub-Zero to victim.  At 090h the victim stands on the FAR part of the
-- puddle and slides back toward Sub-Zero, so the wall is never touched and
-- the clamp is not exercised (measured: the clamp-NOPd ROM slides too).  At a
-- close gap he is on the NEAR part and slides toward the far end - the wall.
local TRIALS = { {name = "mid", gap = 0x90}, {name = "midnear", gap = 0x70},
                 {name = "right", gap = 0x90}, {name = "left", gap = 0x90},
                 {name = "rightnear", gap = 0x68, off = 30}, {name = "leftnear", gap = 0x68, off = 30},
                 {name = "rightwall", gap = 0x68, off = 50}, {name = "leftwall", gap = 0x68, off = 50} }
-- The wall trials put him 50px off it, where the two ends are equidistant and
-- the first leg goes RIGHT/toward the wall end, so the fixed ROM must turn him
-- AT the wall.  50px off is OUTSIDE retail's 060h refusal (it measures from
-- left_edge/right_edge, 58/48px beyond the clamp), so a clamp-less ROM sticking
-- here is retail's own bug, not one this change exposed.
-- The near trials stand him OFF the wall (off px - still inside retail's 060h
-- refusal) and close enough that he is caught on the near part of the puddle.
-- r_floor_ice slides toward the FARTHER end first, so his first leg heads for
-- the wall end, which on a clamp-less ROM is behind the wall: he arrives at the
-- wall in ~off ticks and stands there for the rest of the slip.  Pinned AT the
-- wall instead, the first leg goes away from it and 80 ticks never bring him
-- back (measured - both ROMs identical).

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local ti, tstart = 1, 0
local fields, done = {}, false
local cur, results = nil, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function pact(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + P_ACTION) end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end
local function getx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end

-- where each trial puts the pair (world x), read off the stage's own limits
local function place(t)
    local GAP = t.gap
    local le, re = s16(r16(A.left_edge)), s16(r16(A.right_edge))
    local wl, wr = le + LEFT_PAD, re + SCRRGT - RIGHT_PAD
    if t.name:sub(1, 3) == "mid" then
        local m = (wl + wr) // 2
        return m - GAP // 2, m + GAP // 2, "Left", wl, wr
    elseif t.name:sub(1, 5) == "right" then
        local v = wr - (t.off or 0)
        return v - GAP, v, "Left", wl, wr
    else
        local v = wl + (t.off or 0)
        return v + GAP, v, "Right", wl, wr
    end
end

-- move @left_edge,a0,w / addi 03ah,a0 / cmp a0,a10 / jrge / move a0,a10
local function locate()
    local reg = manager.machine.memory.regions[":maincpu"]
    local function rw(i) return reg:read_u8(i) | (reg:read_u8(i + 1) << 8) end
    local L = A.left_edge
    local pat = { 0x05a0, L & 0xffff, (L >> 16) & 0xffff, 0x0b00, 0x003a, 0x480a }
    local hits = {}
    for i = 0, reg.size - 40, 2 do
        if reg:read_u8(i) == 0xa0 and reg:read_u8(i + 1) == 0x05 then
            local ok = true
            for k = 2, #pat do if rw(i + (k - 1) * 2) ~= pat[k] then ok = false; break end end
            if ok and rw(i + 14) == 0x4c0a and rw(i + 30) == 0x4c0b then hits[#hits + 1] = i end
        end
    end
    return reg, hits
end

local function finish()
    if done then return end
    done = true
    local ok, why = true, {}
    for _, t in ipairs(TRIALS) do
        local r = results[t.name]
        local good, desc
        if not r or not r.cast then
            good, desc = false, "the move never came out"
        elseif not r.slip then
            good, desc = false, "cast, but he never slipped"
        else
            good = r.stuck <= STUCK_MAX
            desc = string.format("slipped %d ticks, x %d..%d (walls %d/%d), %d reversal(s), longest stand-still %d tick(s)",
                r.ticks, r.xmin, r.xmax, r.wl, r.wr, r.rev, r.stuck)
        end
        local want = good
        if NEG and (t.name:find("near") or t.name:find("wall")) and t.name ~= "midnear" then want = not good end   -- near corners must stick without the clamp
        if not want then ok = false; why[#why + 1] = t.name end
        log("RESULT %-5s %s  %s", t.name, good and "slides" or "STUCK/NONE", desc)
    end
    if NEG then
        log("%s szicecorner NEGATIVE (clamp NOPd: near corners must be stuck, the rest slide)%s",
            ok and "PASS" or "FAIL", ok and "" or (": wrong on " .. table.concat(why, ",")))
    else
        log("%s szicecorner%s", ok and "PASS" or "FAIL", ok and "" or (": wrong on " .. table.concat(why, ",")))
    end
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { "Coin 1", "Coin 2", "1 Player Start", "2 Players Start", "P1 High Punch",
                   "P2 High Punch", "P1 Left", "P1 Right", "P1 Down", "P1 Low Kick" }
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
    if not cur then return false end
    local r = frame - tstart - SETTLE
    if name == "P1 Down" then return r >= 0 and r < 8 end
    if name == cur.back then return r >= 8 and r < 30 end
    if name == "P1 Low Kick" then return r >= 16 and r < 30 end
    return false
end

local function start_trial()
    local t = TRIALS[ti]
    local szx, vx, back, wl, wr = place(t)
    cur = { name = t.name, szx = szx, vx = vx, back = "P1 " .. back, wl = wl, wr = wr,
            cast = false, slip = false, ticks = 0, xmin = 99999, xmax = -99999,
            rev = 0, stuck = 0, run = 0, lastx = nil, lastdx = 0 }
    results[t.name] = cur
    tstart = frame
    log("trial %s: Sub-Zero %d, victim %d, back = %s, clamp band %d..%d", t.name, szx, vx, back, wl, wr)
end

emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if #miss > 0 then log("FAIL szicecorner: missing symbols %s", table.concat(miss, ",")); return finish() end
        local m = cache_fields()
        if #m > 0 then log("FAIL szicecorner: missing inputs %s", table.concat(m, ",")); return finish() end
        local reg, hits = locate()
        if #hits ~= 1 then
            log("FAIL szicecorner: the puddle clamp found %d times, want 1 - a szicecorner 0 ROM has none", #hits)
            return finish()
        end
        if NEG then
            for _, o in ipairs({14, 30}) do reg:write_u8(hits[1] + o, 0x00); reg:write_u8(hits[1] + o + 1, 0x03) end
            log("NEGATIVE: both clamp moves NOPd at :maincpu+%x", hits[1])
        else
            log("puddle clamp present at :maincpu+%x", hits[1])
        end
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
        fighting_frame = frame
        log("fight start frame=%d", frame)
        start_trial()
    end
    if fighting_frame == 0 then
        if frame > 8000 then log("FAIL szicecorner: never reached the fight - NO VERDICT"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    w16(A.f_freeze_timer, 1)

    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    if not cur.cast then setx(A.p1_obj, cur.szx) end
    if not cur.slip then setx(A.p2_obj, cur.vx) end

    if not cur.cast and a1 == ACT_FLOOR_ICE then cur.cast = true; log("  %s: cast at +%d", cur.name, frame - tstart) end
    if cur.cast and a2 == ACT_SLIPPING then
        if not cur.slip then
            cur.slip = true
            local q = r32(A.p2_proc)
            log("  %s: slipping at +%d, puddle ends %d..%d (his saved a10/a11 - clamped already on the fixed ROM)", cur.name, frame - tstart,
                s16(r32(q + 0x80) & 0xffff), s16(r32(q + 0x60) & 0xffff))
        end
        local x = getx(A.p2_obj)
        if x then
            cur.ticks = cur.ticks + 1
            if x < cur.xmin then cur.xmin = x end
            if x > cur.xmax then cur.xmax = x end
            if cur.lastx then
                local dx = x - cur.lastx
                if dx == 0 then
                    cur.run = cur.run + 1
                    if cur.run > cur.stuck then cur.stuck = cur.run end
                else
                    cur.run = 0
                    if cur.lastdx ~= 0 and (dx > 0) ~= (cur.lastdx > 0) then cur.rev = cur.rev + 1 end
                    cur.lastdx = dx
                end
            end
            cur.lastx = x
        end
    end

    if frame - tstart > TRIAL_FRAMES then
        ti = ti + 1
        if ti > #TRIALS then return finish() end
        start_trial()
    end
    if frame > 20000 then log("FAIL szicecorner: backstop"); finish() end
end)
