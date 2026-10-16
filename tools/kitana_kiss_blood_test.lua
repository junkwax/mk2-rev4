-- kitana_kiss_blood_test.lua
-- PROVE kissblood (MAINEQU.ASM): Kitana's KISS OF DEATH bursts the body in
-- BLDSPLASH1-5 (MKMORPH2.IMG) - the five-frame blood splash drawn beside the
-- kiss's own inflate/pop/chunk art, of which retail packed ONE frame (a still
-- Pit splat) and never played.  r_kissed (MKDIE.ASM) creates blood slot 1fh,
-- kiss_splash_blood (MKBLOOD.ASM), once, on the frame the body pops.
--
-- The input is the real one (fn1_lk_open, MOVES.ASM): in FINISH HIM, Low Kick
-- held for at least 038h ticks, Forward, Forward, Down, Forward inside
-- scom_fn1_db's 038h window, then Low Kick RELEASED - lk_open is the release.
-- P1 = Kitana on the left (Forward = Right), P2 = the victim, 2-player game;
-- FINISH HIM is forced by emptying P2's bar with P1 on match point.
--
-- What is asserted, from the pop (m_inviso = 020h in oflags2, on the EDGE):
--   * an objlst object draws BLDSPLASH frames - the SAGs are READ from
--     src/MKFAT2.TBL (frame 1, retail's, in MK6MIL) and src/BLDSPLSH.TBL
--     (frames 2-5, the sidecar) every run, since a repack moves them;
--   * ALL FIVE frames are drawn, in order 1..5;
--   * its centre is on the body's chest: within SLOP px of the victim's
--     anchor + (0, 048h), the point kiss_explode throws the chunks from;
--   * it is gone by pop+60 (blood_death), the victim's object never moves,
--     and blood stays under MAX_BLOOD (64).
--
-- KKB_NEG=1 IS THE CONTROL: it overwrites the `calla create_blood_proc` after
-- `movk 01fh,a0` with three NOPs in the :maincpu region, keeps the same
-- expectations, and must FAIL.  The site is found by its bytes; positive mode
-- REQUIRES it, so a kissblood 0 ROM is refused before play.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("KKB_VICTIM") or "subzero"):lower()
local NEG = (os.getenv("KKB_NEG") or "0") ~= "0"
local SNAP_EVERY = tonumber(os.getenv("KKB_SNAP_EVERY") or "3")
local LOG = os.getenv("KKB_LOG") or (ROOT .. "/tools/kitana_kiss_blood_" .. VICTIM .. ".log")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
  local line = "[kkb/" .. VICTIM .. "] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
  raw(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do local fh = assert(io.open(os.getenv("KKB_MAP") or (ROOT .. "/src/mk2.map"), "r"))
  for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
  fh:close() end

local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "p1_obj", "p2_obj", "f_death", "blood_count",
               "create_blood_proc", "objlst" }
local CHEATS = { "f_rain_cheat1", "f_rain_cheat2", "f_ermac_cheat1",
                 "f_ermac_cheat2", "f_jade_cheat1", "f_jade_cheat2" }
local A, missing = {}, {}
for _, n in ipairs(WANT) do A[n] = symbols[n]; if not A[n] then missing[#missing+1] = n end end

local O_LINK, O_OXPOS, O_OXVAL, O_OYPOS, O_FLAGS2 = 0x000, 0x090, 0x080, 0x0b0, 0x160
local O_OSAG, O_SIZEX, O_SIZEY = 0x100, 0x120, 0x130
local SLOP = 12                  -- px either way of the chest point
local CHEST = 0x48               -- kiss_explode: oypos + 048h
local M_INVISO = 0x020           -- DISPEQU.ASM
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_FN1 = 4
local VICTIMS = { kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
                  shang = 6, raiden = 7, subzero = 8, reptile = 9, scorpion = 10, jax = 11 }
local WANT_P2 = VICTIMS[VICTIM]
local KISS_DIST = 0x3c          -- inside fn1_lk_open's fatality_xfer_close 045h
local CHARGE_DIST = 0x90        -- where the low kick a held LK throws cannot reach
local MAX_BLOOD = 64

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local done = false
local function finish() if not done then done = true; log("finished"); manager.machine:exit() end end
local function refuse(why) log("FAIL kiss_blood: %s", why); finish() end

-- BLDSPLASH SAG -> frame number, out of the TBLs this build linked
local SPLASH = {}
local function load_sags()
  for _, spec in ipairs({ { "src/MKFAT2.TBL", 1, 1 }, { "src/BLDSPLSH.TBL", 2, 5 } }) do
    local fh = io.open(ROOT .. "/" .. spec[1], "r")
    if not fh then return "cannot read " .. spec[1] end
    local cur
    for line in fh:lines() do
      local n = line:match("^BLDSPLASH(%d+):")
      if n then cur = tonumber(n) end
      local sag = line:match("^%s*%.long%s+0*(%x+)H")
      if cur and sag and cur >= spec[2] and cur <= spec[3] then
        SPLASH[tonumber(sag, 16)] = cur; cur = nil end
    end
    fh:close()
  end
  local n = 0; for _ in pairs(SPLASH) do n = n + 1 end
  if n ~= 5 then return string.format("read %d BLDSPLASH SAGs, want 5", n) end
end

-- BLDXPD SAGs: Ermac's teleslam-fatality burst (ermac_splash_blood, slot 017h),
-- thrown beside the kiss splash.  Three splat OBJECTS must appear after the pop.
local XPD = {}
local function load_xpd()
  local fh = io.open(ROOT .. "/src/BLDXPD.TBL", "r")
  if not fh then return "cannot read src/BLDXPD.TBL" end
  local cur
  for line in fh:lines() do
    local n = line:match("^BLDXPD(%d+):")
    if n then cur = tonumber(n) end
    local sag = line:match("^%s*%.long%s+0*(%x+)H")
    if cur and sag then XPD[tonumber(sag, 16)] = cur; cur = nil end
  end
  fh:close()
  if not next(XPD) then return "read no BLDXPD SAGs" end
end
local xpd_objs, xpd_n, xpd_first = {}, 0, nil
local function scan_xpd(pr)
  local o, guard = r32(A.objlst), 0
  while o ~= 0 and guard < 400 do
    if XPD[r32(o + O_OSAG)] and not xpd_objs[o] then
      xpd_objs[o] = pr; xpd_n = xpd_n + 1; xpd_first = xpd_first or pr
      log("  pop+%2d BLDXPD splat #%d at x=%d y=%d", pr, xpd_n,
          s16(r16(o + O_OXPOS)), s16(r16(o + O_OYPOS)))
    end
    o = r32(o + O_LINK); guard = guard + 1
  end
end

local function splash_object()
  local o, guard = r32(A.objlst), 0
  while o ~= 0 and guard < 400 do
    local f = SPLASH[r32(o + O_OSAG)]
    if f then return o, f end
    o = r32(o + O_LINK); guard = guard + 1
  end
end

-- movk 01fh,a0 (1BE0h) then calla (0D5Fh) create_blood_proc
local function locate_loop()
  local reg = manager.machine.memory.regions[":maincpu"]
  if not reg then return nil, "no :maincpu region" end
  local cbp = A.create_blood_proc
  local pat = {0xE0, 0x1B, 0x5F, 0x0D, cbp & 0xff, (cbp >> 8) & 0xff, (cbp >> 16) & 0xff, (cbp >> 24) & 0xff}
  local hits = {}
  for i = 0, reg.size - 16, 2 do
    if reg:read_u8(i) == 0xE0 and reg:read_u8(i + 1) == 0x1B then
      local ok = true
      for k = 3, #pat do if reg:read_u8(i + k - 1) ~= pat[k] then ok = false; break end end
      if ok then hits[#hits+1] = i end
    end
  end
  if #hits ~= 1 then
    return nil, string.format("movk 01fh + calla create_blood_proc found %d times, expected exactly 1 -"
      .. " a kissblood 0 ROM has none; refusing rather than measuring a build without it", #hits)
  end
  return reg, hits[1]
end

local function cache()
  local need = { "Coin 1", "Coin 2", "2 Players Start", "P1 High Punch", "P1 Low Punch",
                 "P1 Low Kick", "P1 Right", "P1 Down", "P2 Low Punch" }
  local want = { ["UI Select"] = true }
  for _, n in ipairs(need) do want[n] = true end
  for _, p in pairs(manager.machine.ioport.ports) do
    for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end end
  local miss = {}
  for _, n in ipairs(need) do if not fields[n] then miss[#miss+1] = n end end
  return miss
end

local function place(obj, x) w16(obj + O_OXPOS, x); w32(obj + O_OXVAL, (x << 16)) end
local function snap_to(dist)
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  if p1o == 0 or p2o == 0 then return end
  local x1, x2 = r16(p1o + O_OXPOS), r16(p2o + O_OXPOS)
  local mid = (x1 + x2) // 2
  place(p1o, mid - dist // 2); place(p2o, mid + dist - dist // 2)
end

local snaps = 0
local function snap() snaps = snaps + 1; manager.machine.video:snapshot() end

local frame, psel, phase, fight_at, armed_at, ko_at, finish_at = 0, 0, "boot", 0, 0, 0, 0
local kiss_at, tries, fatal_at, pop_at = 0, 0, 0, 0
local seen, order_ok, last_f, gone_at, centre_off = {}, true, 0, nil, nil
local vx, vy, moved = nil, nil, 0
local peak = 0
local was_inviso = nil
local prev_bc = 0

-- the kiss: LK held from c=0, Forward,Forward,Down,Forward late in the charge,
-- LK released at c=KISS_REL (>= 038h after the press, motion inside 038h)
local KISS_REL = 70
local function kiss_input(c)
  hold("P1 Low Kick", c >= 0 and c < KISS_REL)
  hold("P1 Right", (c >= 40 and c < 44) or (c >= 48 and c < 52) or (c >= 60 and c < 64))
  hold("P1 Down", c >= 54 and c < 58)
end

emu.register_frame_done(function()
  if done then return end
  if not space then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    if #missing > 0 then return refuse("missing symbols: " .. table.concat(missing, ",")) end
    if not WANT_P2 then return refuse("unknown KKB_VICTIM " .. VICTIM) end
    local miss = cache()
    if #miss > 0 then return refuse("missing inputs: " .. table.concat(miss, ",")) end
    local e = load_sags() or load_xpd()
    if e then return refuse(e) end
    local reg, off = locate_loop()
    if not reg then return refuse(off) end
    if NEG then
      for k = 2, 7, 2 do reg:write_u8(off + k, 0x00); reg:write_u8(off + k + 1, 0x03) end  -- NOP x3
      log("NEGATIVE: the splash's calla NOPd at :maincpu+%x - nothing may be drawn", off + 2)
    else
      log("kiss splash create present at :maincpu+%x, calla -> create_blood_proc", off)
    end
  end
  frame = frame + 1
  local gs = r16(A.gstate)

  if psel == 0 and gs == GS_PSEL then psel = frame; for n in pairs(fields) do hold(n, false) end end
  if psel == 0 then
    hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
    hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
    hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
    hold("UI Select", frame >= 5 and frame < 35)
  elseif fight_at == 0 then
    local rel = frame - psel
    if gs == GS_PSEL then
      w16(A.p1_char, FT_FN1); w16(A.p2_char, WANT_P2)
      for _, n in ipairs(CHEATS) do if symbols[n] then w16(symbols[n], 0) end end
      hold("2 Players Start", rel < 60 and (frame % 20) < 8)
      if rel > 130 then hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8) end
    end
    if gs == GS_FIGHTING then
      fight_at = frame; for n in pairs(fields) do hold(n, false) end
      log("fight at %d: p1=%d p2=%d", frame, r16(A.p1_char), r16(A.p2_char))
      if r16(A.p1_char) ~= FT_FN1 or r16(A.p2_char) ~= WANT_P2 then return refuse("wrong pair") end
    end
    if frame > 6000 then return refuse("never reached a fight") end
  else
    if armed_at == 0 and frame - fight_at == 60 then
      armed_at = frame; w16(A.p1_matchw, 1); w16(A.p2_bar, 1); log("armed: match point, p2_bar=1")
    end
    if armed_at > 0 and ko_at == 0 then
      snap_to(60); hold("P1 High Punch", (frame % 12) < 5)
      if r16(A.p2_bar) == 0 then ko_at = frame; hold("P1 High Punch", false); log("KO at %d", frame) end
    end
    if ko_at > 0 and finish_at == 0 and r16(A.winner_status) == 3 then
      finish_at = frame; log("FINISH HIM at %d", frame)
    end

    if finish_at > 0 and fatal_at == 0 then
      -- START THE CHARGE OUT OF RANGE, as a player does.  Pressing Low Kick
      -- also throws an ordinary low kick (act 0104h), and against a wide body
      -- (Jax) that kick CONNECTS from KISS_DIST: the dizzy man is hit,
      -- winner_status drops 3 -> 1 and FINISH HIM is simply over.  So the
      -- pair is held CHARGE_DIST apart while the kick whiffs, then brought
      -- in for the motion and the release.
      if kiss_at > 0 and frame - kiss_at < 30 then snap_to(CHARGE_DIST) else snap_to(KISS_DIST) end
      if (frame - finish_at) % 10 == 0 and frame - finish_at <= 120 then
        local q2 = symbols.p2_proc and r32(symbols.p2_proc) or 0
        local q1 = symbols.p1_proc and r32(symbols.p1_proc) or 0
        local wake = q2 ~= 0 and r32(q2 + 0xe0) or 0
        log("  fh+%3d victim %s act=%04x | kitana act=%04x | ws=%d", frame - finish_at,
            wake == symbols.dizzy and "DIZZY  " or string.format("%08x", wake),
            q2 ~= 0 and r16(q2 + 0x1f0) or 0, q1 ~= 0 and r16(q1 + 0x1f0) or 0, r16(A.winner_status))
      end
      if kiss_at == 0 and frame - finish_at >= 15 then kiss_at = frame; tries = tries + 1
        -- fatality_xfer refuses unless the victim's process is parked in
        -- `dizzy` (its pwake) - say what it IS, so a refusal is explained
        local q2 = symbols.p2_proc and r32(symbols.p2_proc) or 0
        local wake = q2 ~= 0 and r32(q2 + 0xe0) or 0
        log("kiss: hold LK, F,F,D,F, release (try %d) - victim pwake=%08x%s act=%04x", tries,
            wake, symbols.dizzy and (wake == symbols.dizzy and " (= dizzy)" or " (NOT dizzy)") or "",
            q2 ~= 0 and r16(q2 + 0x1f0) or 0) end
      if kiss_at > 0 then
        local c = frame - kiss_at
        kiss_input(c)
        if c > KISS_REL + 30 and tries < 3 then kiss_at = 0 end
      end
      if r16(A.f_death) ~= 0 and r16(A.f_death) ~= 0xffff then
        fatal_at = frame; for n in pairs(fields) do hold(n, false) end
        log("fatality started at %d (f_death=%04x)", frame, r16(A.f_death))
      end
      if frame - finish_at > 700 then snap(); return refuse("the kiss never started") end
    end

    if fatal_at > 0 then
      local rel = frame - fatal_at
      local p2o = r32(A.p2_obj)
      local bc = r16(A.blood_count)
      peak = math.max(peak, bc)
      local inv = p2o ~= 0 and (r16(p2o + O_FLAGS2) & M_INVISO) ~= 0
      local edge = inv and was_inviso == false
      if was_inviso == nil or p2o ~= 0 then was_inviso = inv end
      if pop_at == 0 and edge then
        pop_at = frame
        vx, vy = s16(r16(p2o + O_OXPOS)), s16(r16(p2o + O_OYPOS))
        log("  +%3d POP: body inviso at x=%d y=%d, blood_count=%d", rel, vx, vy, bc)
        snap()
      end
      if pop_at > 0 then
        local pr = frame - pop_at
        scan_xpd(pr)
        local so, f = splash_object()
        if so then
          if not seen[f] then
            seen[f] = pr
            if f < last_f then order_ok = false end
            last_f = f
            local sx, sy = s16(r16(so + O_OXPOS)), s16(r16(so + O_OYPOS))
            local cx, cy = sx + r16(so + O_SIZEX) / 2, sy + r16(so + O_SIZEY) / 2
            local dx, dy = cx - vx, cy - (vy + CHEST)
            log("  pop+%2d BLDSPLASH%d at x=%d y=%d %dx%d, centre off the chest by (%.1f,%.1f)",
                pr, f, sx, sy, r16(so + O_SIZEX), r16(so + O_SIZEY), dx, dy)
            centre_off = centre_off or {}
            if math.abs(dx) > SLOP or math.abs(dy) > SLOP then centre_off.bad = true end
          end
        elseif next(seen) and not gone_at then gone_at = pr end
        if p2o ~= 0 then
          local x, y = s16(r16(p2o + O_OXPOS)), s16(r16(p2o + O_OYPOS))
          if x ~= vx or y ~= vy then moved = moved + 1
            if moved == 1 then log("  pop+%2d VICTIM OBJECT MOVED to x=%d y=%d", pr, x, y) end end
        end
        if SNAP_EVERY > 0 and pr % SNAP_EVERY == 0 and pr <= 30 then snap() end
        if pr == 60 then
          local ok, why = true, {}
          local n = 0; for _ in pairs(seen) do n = n + 1 end
          if n < 5 then ok = false; why[#why+1] = string.format("%d of 5 BLDSPLASH frames drawn", n) end
          if not order_ok then ok = false; why[#why+1] = "frames out of order" end
          if centre_off and centre_off.bad then ok = false; why[#why+1] = "splash not centred on the chest" end
          if n > 0 and not gone_at then ok = false; why[#why+1] = "splash still up at pop+60" end
          if xpd_n < 3 then ok = false; why[#why+1] = string.format("%d of 3 BLDXPD splats (Ermac's burst)", xpd_n) end
          if moved > 0 then ok = false; why[#why+1] = "the victim object moved" end
          if peak >= MAX_BLOOD then ok = false; why[#why+1] = "blood hit MAX_BLOOD" end
          local st = {}
          for k = 1, 5 do st[#st+1] = seen[k] and string.format("%d@+%d", k, seen[k]) or (k .. "@-") end
          log("RESULT frames=[%s] gone=%s bldxpd=%d peak blood=%d victim moved=%d snapshots=%d",
              table.concat(st, " "), gone_at and ("+" .. gone_at) or "-", xpd_n, peak, moved, snaps)
          if NEG then
            log("%s kiss_blood (NEGATIVE control: splash NOPd - FAIL is the expected result)%s",
                ok and "PASS" or "FAIL", ok and "" or (": " .. table.concat(why, "; ")))
          else
            log("%s kiss_blood%s", ok and "PASS" or "FAIL", ok and "" or (": " .. table.concat(why, "; ")))
          end
          return finish()
        end
      end
      prev_bc = bc
      if rel > 600 then return refuse("the body never popped") end
    end
    if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then return refuse("never landed a KO") end
  end

  for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
  if frame > 15000 then refuse("timeout") end
end)
