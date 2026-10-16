-- scorpion_spear_guts_test.lua
-- PROVE spearguts (MAINEQU.ASM): when Scorpion's spear pull lands, the GUTS
-- burst (MK1's, Kano's heart rip) is FLUNG off the wound - Midway's dead tail
-- on speared_blood (MKBLOOD.ASM), restored as written: after the 8 drips, a
-- tail call into spatter_blood_fly with a_guts at speed 5 from [y,x] 020h,1.
--
-- 2-player: P1 = Scorpion on the left (Back = Left), P2 = the victim.  P1
-- throws the spear - Back, Back + Low Punch - once per trial; the pull
-- (do_rope_pull) creates speared_blood, whose tail now throws the guts.
--
-- THE GUTS ARE FOUND BY WHAT THE DMA IS DRAWING, not inferred from blood
-- counts: GUTS1-7's image addresses are read out of src/MKBLOOD.TBL every run
-- (a repack moves them), and objlst is walked for an object whose osag is one
-- of them.  Per trial it reports when they appear after the pull, where they
-- are against the victim, and how many distinct GUTS frames were drawn.
--
-- The tail is found by its bytes: movi 000200001h,a4 / movk 5,a5 / movi
-- a_guts,a9 (spear_spawn_drip also opens on that movi, so the movk is what
-- picks it out).  Positive mode REQUIRES it once, so a spearguts 0 ROM is
-- refused before play.  Per trial it requires 5+ GUTS frames, the burst to
-- START after the drips (>= DRIP_TICKS after the pull) and to TRAVEL
-- (>= MIN_FLY px in x over its life) - played in place it would not.
--
-- SSG_NEG=1 IS THE CONTROL: the a_guts immediate is moved on to GUTS7, the
-- last frame, so one GUTS frame is drawn instead of seven and every trial must
-- FAIL.  (NOPing the jruc proves nothing: spatter_blood_fly is the next
-- instruction, so it would fall through into it anyway.)
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("SSG_VICTIM") or "subzero"):lower()
local NEG = (os.getenv("SSG_NEG") or "0") ~= "0"
local TRIALS = tonumber(os.getenv("SSG_TRIALS") or "3")
local LOG = os.getenv("SSG_LOG") or (ROOT .. "/tools/scorpion_spear_guts_" .. VICTIM .. ".log")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
  local line = "[ssg/" .. VICTIM .. "] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
  raw(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do local fh = assert(io.open(os.getenv("SSG_MAP") or (ROOT .. "/src/mk2.map"), "r"))
  for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
  fh:close() end

-- GUTS1-7: `GUTSn:` then `.word w,h,ax,ay` then `.long <SAG>H` (MKBLOOD.TBL)
local GUTS = {}
do local fh = assert(io.open(ROOT .. "/src/MKBLOOD.TBL", "r"))
  local pend
  for line in fh:lines() do
    local n = line:match("^GUTS(%d):")
    if n then pend = tonumber(n)
    elseif pend then
      local sag = line:match("^%s+%.long%s+(%x+)H")
      if sag then GUTS[tonumber(sag, 16)] = pend; pend = nil end
    end
  end
  fh:close() end

local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj",
               "p1_proc", "p2_proc", "objlst", "getprc", "f_freeze_timer" }
local CHEATS = { "f_rain_cheat1", "f_rain_cheat2", "f_ermac_cheat1",
                 "f_ermac_cheat2", "f_jade_cheat1", "f_jade_cheat2" }
local A, missing = {}, {}
for _, n in ipairs(WANT) do A[n] = symbols[n]; if not A[n] then missing[#missing+1] = n end end

local O_LINK, O_OXPOS, O_OXVAL, O_OYPOS, O_OSAG = 0x000, 0x090, 0x080, 0x0b0, 0x100
local P_ACTION = 0x1f0
local ACT_ROPE_PULL = 0x0405     -- Scorpion pulling the other man in
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_SCORP = 10
local VICTIMS = { kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
                  shang = 6, raiden = 7, subzero = 8, reptile = 9, jax = 11 }
local WANT_P2 = VICTIMS[VICTIM]
local GAP = 150
local DRIP_TICKS = 14   -- 8 drips at sleep 2 = 16; a tick or two of slack
local MIN_FLY = 30      -- spatter_blood_fly throws 3-5 px a tick for 35 ticks
local MAXHP = 0xa1

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
local function refuse(why) log("FAIL spear_guts: %s", why); finish() end

local function locate_spawn()
  local reg = manager.machine.memory.regions[":maincpu"]
  if not reg then return nil, "no :maincpu region" end
  local pre = {0xE4,0x09,0x01,0x00,0x20,0x00, 0xA5,0x18, 0xE9,0x09}
  local hits = {}
  for i = 0, reg.size - 16, 2 do
    if reg:read_u8(i) == 0xE4 and reg:read_u8(i + 1) == 0x09 then
      local ok = true
      for k = 3, #pre do if reg:read_u8(i + k - 1) ~= pre[k] then ok = false; break end end
      if ok then hits[#hits+1] = i end
    end
  end
  if #hits ~= 1 then
    return nil, string.format("the guts spawn found %d times, expected exactly 1 - a spearguts 0 ROM"
      .. " has none; refusing rather than measuring a build without it", #hits)
  end
  local o = hits[1]
  local lane = reg:read_u8(o+10) | (reg:read_u8(o+11) << 8) | (reg:read_u8(o+12) << 16) | (reg:read_u8(o+13) << 24)
  if lane < 0xff800000 then return nil, string.format("its a9 immediate %08x is not a ROM lane", lane) end
  return reg, o, lane
end

local function cache()
  local need = { "Coin 1", "Coin 2", "2 Players Start", "P1 Low Punch", "P1 Left", "P2 Low Punch" }
  local want = { ["UI Select"] = true }
  for _, n in ipairs(need) do want[n] = true end
  for _, p in pairs(manager.machine.ioport.ports) do
    for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end end
  local miss = {}
  for _, n in ipairs(need) do if not fields[n] then miss[#miss+1] = n end end
  return miss
end

-- every object on objlst drawing a GUTS frame: { obj, frame# }
local function guts_objects()
  local out, o, guard = {}, r32(A.objlst), 0
  while o ~= 0 and guard < 400 do
    local f = GUTS[r32(o + O_OSAG)]
    if f then out[#out+1] = { o, f } end
    o = r32(o + O_LINK); guard = guard + 1
  end
  return out
end

local snaps = 0
local function snap() snaps = snaps + 1; manager.machine.video:snapshot() end

local frame, psel, fight_at = 0, 0, 0
local trial, t0, phase = 0, 0, "settle"
local pull_at, first_at, frames_seen, hits_ok, nov, fails = nil, nil, {}, 0, 0, 0
local pin1, rel_dx, rel_dy, gx0, gxmax

emu.register_frame_done(function()
  if done then return end
  if not space then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    if #missing > 0 then return refuse("missing symbols: " .. table.concat(missing, ",")) end
    if not WANT_P2 then return refuse("unknown SSG_VICTIM " .. VICTIM) end
    local n = 0; for _ in pairs(GUTS) do n = n + 1 end
    if n ~= 7 then return refuse(string.format("found %d GUTS records in MKBLOOD.TBL, want 7", n)) end
    local miss = cache()
    if #miss > 0 then return refuse("missing inputs: " .. table.concat(miss, ",")) end
    local reg, off, lane = locate_spawn()
    if not reg then return refuse(off) end
    if NEG then
      local l2 = lane + 6 * 32
      for k = 0, 3 do reg:write_u8(off + 10 + k, (l2 >> (8 * k)) & 0xff) end
      log("NEGATIVE: the tail's lane at :maincpu+%x moved %08x -> %08x (GUTS7 only) - must FAIL", off + 10, lane, l2)
    else
      log("guts tail present at :maincpu+%x, lane %08x", off, lane)
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
      w16(A.p1_char, FT_SCORP); w16(A.p2_char, WANT_P2)
      for _, n in ipairs(CHEATS) do if symbols[n] then w16(symbols[n], 0) end end
      hold("2 Players Start", rel < 60 and (frame % 20) < 8)
      if rel > 130 then hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8) end
    end
    if gs == GS_FIGHTING then
      fight_at = frame; for n in pairs(fields) do hold(n, false) end
      log("fight at %d: p1=%d p2=%d", frame, r16(A.p1_char), r16(A.p2_char))
      if r16(A.p1_char) ~= FT_SCORP or r16(A.p2_char) ~= WANT_P2 then return refuse("wrong pair") end
      trial = 1; t0 = frame
    end
    if frame > 6000 then return refuse("never reached a fight") end
  elseif gs == GS_FIGHTING then
    w16(A.p1_bar, MAXHP); w16(A.p2_bar, MAXHP); w16(A.f_freeze_timer, 1)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local q1 = r32(A.p1_proc)
    local a1 = q1 ~= 0 and r16(q1 + P_ACTION) or 0
    local rel = frame - t0

    if phase == "settle" then
      for n in pairs(fields) do hold(n, false) end
      -- park the pair GAP apart, only between trials and only while both stand
      if p1o ~= 0 and p2o ~= 0 and rel == 40 then
        if not pin1 then pin1 = s16(r16(p1o + O_OXPOS)) end
        w32(p1o + O_OXVAL, pin1 << 16); w32(p2o + O_OXVAL, (pin1 + GAP) << 16)
      end
      if rel >= 70 and #guts_objects() == 0 then
        pull_at, first_at, frames_seen, rel_dx, rel_dy, gx0, gxmax = nil, nil, {}, nil, nil, nil, 0
        phase = "throw"; t0 = frame; log("trial %d: Back, Back + Low Punch", trial)
      end
    elseif phase == "throw" then
      hold("P1 Left", (rel < 4) or (rel >= 8 and rel < 12))
      hold("P1 Low Punch", rel >= 14 and rel < 20)
      if a1 == ACT_ROPE_PULL and not pull_at then pull_at = frame; log("  pull at +%d", rel) end
      -- snapshots on the PULL's clock, so the control is photographed at the
      -- same moments and the two can be set side by side
      if pull_at and trial == 1 then
        local pr = frame - pull_at
        if pr >= 16 and pr <= 52 and (pr - 16) % 6 == 0 then snap() end
      end
      local g = guts_objects()
      if #g > 0 then
        for _, e in ipairs(g) do frames_seen[e[2]] = true end
        if not first_at then
          first_at = frame
          local go = g[1][1]
          rel_dx = s16(r16(go + O_OXPOS)) - s16(r16(p2o + O_OXPOS))
          rel_dy = s16(r16(go + O_OYPOS)) - s16(r16(p2o + O_OYPOS))
          gx0 = s16(r16(go + O_OXPOS))
          log("  GUTS appear %s, %d object(s), at dx=%d dy=%d off the victim (top-left vs top-left)",
              pull_at and string.format("+%d after the pull", frame - pull_at) or "(no pull seen)",
              #g, rel_dx, rel_dy)
        end
        -- how far the burst has flown (x; it is thrown back off him)
        do local d = math.abs(s16(r16(g[1][1] + O_OXPOS)) - gx0); if d > gxmax then gxmax = d end end
        if (frame - first_at) % 5 == 0 then
          local go = g[1][1]
          local gx = s16(r16(go + O_OXPOS))
          local vx = s16(r16(p2o + O_OXPOS))
          log("    +%2d guts x=%d frame=GUTS%d | victim x=%d  (gap %d, was %d)", frame - first_at,
              gx, g[1][2], vx, gx - vx, rel_dx)
        end
      end
      if rel >= 180 then
        local nf = 0; for _ in pairs(frames_seen) do nf = nf + 1 end
        if not pull_at then
          nov = nov + 1; log("  trial %d: NO VERDICT - the spear never pulled", trial)
        elseif first_at and nf >= 5 and (first_at - pull_at) >= DRIP_TICKS and gxmax >= MIN_FLY then
          hits_ok = hits_ok + 1
          log("  trial %d: PASS - %d of 7 GUTS frames, started +%d after the pull, flew %d px",
              trial, nf, first_at - pull_at, gxmax)
        elseif first_at then
          fails = fails + 1
          log("  trial %d: FAIL - %d of 7 GUTS frames (want 5+), started +%d (want >= %d), flew %d px (want >= %d)",
              trial, nf, first_at - pull_at, DRIP_TICKS, gxmax, MIN_FLY)
        else
          fails = fails + 1
          log("  trial %d: FAIL - pull landed, %s", trial,
              first_at and string.format("only %d GUTS frame(s) seen", nf) or "no guts drawn")
        end
        trial = trial + 1; phase = "settle"; t0 = frame
        if trial > TRIALS then
          log("RESULT pass=%d fail=%d no-verdict=%d snapshots=%d", hits_ok, fails, nov, snaps)
          local verdict = (fails == 0 and hits_ok >= 2) and "PASS" or (fails > 0 and "FAIL" or "NO VERDICT")
          log("%s spear_guts%s", verdict, NEG and " (NEGATIVE control: lane cut to GUTS7 - FAIL is the expected result)" or "")
          return finish()
        end
      end
    end
  end

  for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
  if frame > 20000 then refuse("timeout") end
end)
