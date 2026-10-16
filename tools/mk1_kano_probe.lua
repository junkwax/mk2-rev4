-- mk1_kano_probe.lua - WHAT MK1's KANO SOUNDS LIKE AND HOW HIS KNIFE IS DRAWN.
--
-- Plays a 1P game of MAME `mk` (rev 5.0, a T-unit) as Kano (MK1 ochar 1), runs
-- a script of his moves against the CPU, and logs, per move:
--   * every command the main CPU writes to the ADPCM board (01D01020);
--   * every OKI MSM6295 phrase the sound board STARTS (":adpcm:cpu" 2C00h),
--     with that phrase's bytes read out of the OKI's OWN address space at the
--     moment it starts - so the bank latch is whatever the board really had,
--     and no banking arithmetic is trusted.  Each distinct phrase is dumped to
--     oki_<start>_<end>.bin (raw 4-bit ADPCM) for tools/mk1_kano_sounds.py;
--   * every DMA blit (source SAG, x, y, w, h, control, PALETTE register) and,
--     the first time a colour map is seen, its 64 words of palette RAM - so
--     the knife's palette and where its impact frames land can be read off.
--
-- Bars are pinned.  Launch with tools/run_mk1_kano_probe.ps1.
-- Env: MK1K_OUT (dir).  RAM map as tools/mk1_raiden_stance_probe.lua.

local OUT = (os.getenv("MK1K_OUT") or "C:/tmp/mk1kano/"):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local log = io.open(OUT .. "kano.log", "w")
local blog = io.open(OUT .. "blits.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

-- every input field by name, whatever port it is on
local F = {}
for ptag, port in pairs(manager.machine.ioport.ports) do
  for name, f in pairs(port.fields) do F[name] = f end
end
local function need(n) if not F[n] then L("NO FIELD %s", n) end return F[n] end
local K = {
  coin = need("Coin 1"), start = need("1 Player Start"), start2 = need("2 Players Start"),
  p2hp = need("P2 High Punch"), p2lk = need("P2 Low Kick"), p2right = need("P2 Right"), p2left = need("P2 Left"), p2down = need("P2 Down"), p2lp = need("P2 Low Punch"), p2bl = need("P2 Block"),
  hp = need("P1 High Punch"), lp = need("P1 Low Punch"), hk = need("P1 High Kick"),
  lk = need("P1 Low Kick"), bl = need("P1 Block"),
  up = need("P1 Up"), down = need("P1 Down"), left = need("P1 Left"), right = need("P1 Right"),
}
local function r16(a) return mem:read_u16(a) end
local function w16(a, v) mem:write_u16(a, v) end
local A = {
  gstate = 0x01051190, p1char = 0x01051290, p2char = 0x01051570,
  p1hp = 0x01051300, p2hp = 0x010515E0,
}
local GS_SELECT, GS_TOWER, GS_FIGHT = 4, 7, 2
local KANO, SONYA = 1, 6
-- MK1K_2P=1: a 2-player game, P2 = Sonya standing idle, so every male voice
-- logged is Kano's; the "gethit" step then has P2 attack HIM.
local TWO = os.getenv("MK1K_2P") == "1"
-- MK1K_VICTIM=1: 1P, the CPU forced to Sonya, Kano idle with his bar NOT
-- pinned - every male voice is his, as the CPU uppercuts, sweeps, throws and
-- beats him.  Runs MK1K_GETHIT frames of fight, across rounds.
local VICTIM = os.getenv("MK1K_VICTIM") == "1"
-- MK1K_KO=1 (with MK1K_2P=1): Kano does nothing and his bar is NOT pinned;
-- Sonya walks in and uppercuts him until he loses both rounds, then does her
-- fatality (Forward, Forward, Back, Back, Block) - his uppercut and death voices.
local KO = os.getenv("MK1K_KO") == "1"
local SWEPT = os.getenv("MK1K_SWEPT") == "1"       -- with MK1K_2P: Sonya sweeps him, over and over
-- MK1K_WIN=1 (with MK1K_2P=1): Sonya's bar is held at 1 and Kano walks in
-- punching, so he wins both rounds - everything MK1 plays through his victory.
local WIN = os.getenv("MK1K_WIN") == "1"
local HEART = os.getenv("MK1K_HEART") == "1"     -- with MK1K_WIN: his fatality in round 2
local fin0
local SND, DMA, PAL = 0x01D01020, 0x01A80000, 0x01800000

local frame, move = 0, "-"
_G.mk1k_snd = mem:install_write_tap(SND, SND + 0x1f, "mk1ksnd", function(o, d, m)
  L("f%6d  [%s]  CMD %04x", frame, move, d & 0xffff); return d
end)

-- OKI: a byte with bit 7 set picks a phrase, the next byte starts it on the
-- channels in its high nibble; anything else is a stop.
local okidev = manager.machine.devices[":adpcm:oki"]
local okisp
for nm, sp in pairs(okidev.spaces) do okisp = sp; L("oki space %s", nm) end
local snd = manager.machine.devices[":adpcm:cpu"].spaces["program"]
local pend, bank, dumped = nil, -1, {}
_G.mk1k_bank = snd:install_write_tap(0x3400, 0x37ff, "mk1kbank", function(o, d, m)
  bank = d & 0xff; return d
end)
_G.mk1k_oki = snd:install_write_tap(0x2c00, 0x2fff, "mk1koki", function(o, d, m)
  d = d & 0xff
  if pend then
    local ph = pend; pend = nil
    local s = (okisp:read_u8(ph * 8) << 16 | okisp:read_u8(ph * 8 + 1) << 8 | okisp:read_u8(ph * 8 + 2)) & 0x3ffff
    local e = (okisp:read_u8(ph * 8 + 3) << 16 | okisp:read_u8(ph * 8 + 4) << 8 | okisp:read_u8(ph * 8 + 5)) & 0x3ffff
    local key = string.format("%05x_%05x", s, e)
    L("f%6d  [%s]  OKI phrase %3d ch%x att%x bank %02x  %s (%d bytes)", frame, move, ph,
      d >> 4, d & 15, bank, key, e - s + 1)
    if not dumped[key] and e > s and e - s < 0x20000 then
      dumped[key] = true
      local fh = io.open(OUT .. "oki_" .. key .. ".bin", "wb")
      local t = {}
      for a = s, e do t[#t + 1] = string.char(okisp:read_u8(a)) end
      fh:write(table.concat(t)); fh:close()
    end
  elseif d & 0x80 ~= 0 then
    pend = d & 0x7f
  end
  return d
end)

local reg, pals = {}, {}
_G.mk1k_dma = mem:install_write_tap(DMA, DMA + 0xff, "mk1kdma", function(o, d, m)
  local r = (o - DMA) >> 4
  reg[r] = d
  if r == 1 and (d & 0x8000) ~= 0 then
    local cm = (reg[8] or 0) & 0x7f00
    blog:write(string.format("%d %s %08x %d %d %d %d %04x %04x\n", frame, move,
      ((reg[3] or 0) << 16) | (reg[2] or 0), reg[4] or 0, reg[5] or 0, reg[6] or 0,
      reg[7] or 0, reg[0] or 0, reg[8] or 0))
    -- a colour map is re-dumped whenever its CONTENTS change (a palette
    -- swapped onto an object mid-move, as MK1's knife at impact)
    local w = {}
    for i = 0, 63 do w[#w + 1] = string.format("%04x", mem:read_u16(PAL + (cm + i) * 16)) end
    local txt = table.concat(w, " ")
    if pals[cm] ~= txt then
      pals[cm] = txt
      L("f%6d  [%s]  CMAP %04x  %s", frame, move, cm, txt)
    end
  end
  return d
end)

-- the move script: {name, frames, {inputs held}}; a step with inputs nil is a
-- pause.  Motions are written as separate one-tick-apart steps.
local function tap(name, keys, n) return {name, n or 4, keys} end
local S = {}
local function add(...) for _, s in ipairs({...}) do S[#S + 1] = s end end
local function gap(n) add({"-", n or 70, nil}) end
local function walkin() add({"walk", 45, {"right"}}) end
if os.getenv("MK1K_JUMPS") == "1" then          -- walking: forward and back, 60 ticks each
  add({"walk_fwd", 45, {"right"}}, {"-", 30, nil}, {"walk_back", 40, {"left"}}, {"-", 30, nil})
end
if os.getenv("MK1K_VICTIM") ~= "1" and not KO and not WIN and not SWEPT then
-- MK1K_MOVES2=1: the normals with the DIRECTION HELD FIRST (MK1 reads a
-- direction pressed on the button's own tick as no direction), a long block,
-- a crouch block, and the cannonball with Block KEPT held afterwards
-- MK1K_BALLTEST=1: which rotation starts the cannonball, and what holding
-- Block afterwards does - each variant from the same spot, idle P2
-- MK1K_JUMPS=1: a straight jump, a forward flip and a back flip, nothing
-- pressed in the air - his own arcs, for tools/kano_arcs.py
if os.getenv("MK1K_JUMPS") == "1" then
  for _, j in ipairs({{"jump_up", {"up"}}, {"flip_fwd", {"up", "right"}}, {"flip_back", {"up", "left"}}}) do
    add({j[1], 6, j[2]}, {j[1] .. "_air", 120, nil}, {"-", 30, nil})
  end
end
if os.getenv("MK1K_BALLTEST") == "1" then
  local rot = {fdbu = {"right", "down", "left", "up"}, bdfu = {"left", "down", "right", "up"},
               fubd = {"right", "up", "left", "down"}, bufd = {"left", "up", "right", "down"}}
  -- MK1K_BALLHOLD=N: ONE variant, Block held N ticks after the rotation -
  -- does the curl time out on its own (8Bh sent while Block is still down)?
  local bh = tonumber(os.getenv("MK1K_BALLHOLD") or "")
  local variants = bh and {{"fdbu", bh}} or {{"fdbu", 0}, {"bdfu", 0}, {"fubd", 0}, {"bufd", 0}, {"fdbu", 120}, {"bdfu", 120}}
  for _, v in ipairs(variants) do
    local r, hold = rot[v[1]], v[2]
    local tag = "ball_" .. v[1] .. (hold > 0 and "_hold" or "")
    add({tag .. "_bl", 6, {"bl"}})
    for i = 1, 4 do add({tag .. "_" .. r[i], 3, {"bl", r[i]}}) end
    if hold > 0 then add({tag .. "_held", hold, {"bl"}}) end
    add({tag .. "_go", 150, nil}, {"walkback", 40, {"left"}}, {"-", 30, nil})
  end
end
if os.getenv("MK1K_MOVES2") == "1" then
  for _, mv in ipairs({
    {"hikick", nil, "hk"}, {"lokick", nil, "lk"}, {"uppercut", "down", "hp"}, {"duckkick", "down", "lk"},
    {"duckpunch", "down", "lp"}, {"sweep", "left", "lk"}, {"roundhouse", "left", "hk"},
    {"throw", "right", "lp"}, {"elbow", "right", "hp"},
  }) do
    walkin()
    if mv[2] then add({mv[1] .. "_dir", 10, {mv[2]}}) end
    add({mv[1], 5, mv[2] and {mv[2], mv[3]} or {mv[3]}}); gap(80)
  end
  add({"block", 90, {"bl"}}, {"-", 40, nil}, {"duckblock", 90, {"bl", "down"}}, {"-", 40, nil})
  add({"backoff", 60, {"left"}}, {"-", 20, nil})
  for _, hold in ipairs({0, 150}) do
    add({"ball_bl", 4, {"bl"}}, {"ball_f", 3, {"bl", "right"}}, {"ball_d", 3, {"bl", "down"}},
        {"ball_b", 3, {"bl", "left"}}, {"ball_u", 3, {"bl", "up"}})
    if hold > 0 then add({"ballhold", hold, {"bl"}}) end
    add({"ball", 160, nil}, {"backoff", 60, {"left"}}, {"-", 20, nil})
  end
end
-- normals, each from close range
if os.getenv("MK1K_MOVES2") ~= "1" then
for _, mv in ipairs({
  {"hipunch", {"hp"}}, {"lopunch", {"lp"}}, {"hikick", {"hk"}}, {"lokick", {"lk"}},
  {"uppercut", {"down", "hp"}}, {"duckkick", {"down", "lk"}}, {"sweep", {"left", "lk"}},
  {"roundhouse", {"left", "hk"}}, {"throw", {"right", "lp"}}, {"knee", {"hk"}},
}) do walkin(); add(tap(mv[1], mv[2], 4)); gap(80) end
end
-- the air: a flip kick, a jump punch
add({"flipkick_up", 6, {"up", "right"}}, {"flipkick_air", 14, nil}, tap("flipkick", {"hk"}), {"-", 80, nil})
add({"jumppunch_up", 6, {"up"}}, {"jumppunch_air", 14, nil}, tap("jumppunch", {"hp"}), {"-", 80, nil})
-- the knife: hold Block, Back, Forward - from range
add({"backoff", 60, {"left"}}, {"-", 20, nil})
for i = 1, 3 do
  add({"knife_bl", 4, {"bl"}}, {"knife_b", 3, {"bl", "left"}}, {"knife_n", 2, {"bl"}},
      {"knife_f", 3, {"bl", "right"}}, {"knife", 150, nil})
end
-- the cannonball: hold Block, Forward, Down, Back, Up
for i = 1, 2 do
  add({"ball_bl", 4, {"bl"}}, {"ball_f", 3, {"bl", "right"}}, {"ball_d", 3, {"bl", "down"}},
      {"ball_b", 3, {"bl", "left"}}, {"ball_u", 3, {"bl", "up"}}, {"ball", 160, nil})
end
end
-- stand still and get hit by the CPU for a while (his hit/fall voices)
add({"gethit", tonumber(os.getenv("MK1K_GETHIT") or "") or 900, nil})

local sel0, fight0, step, stepend = nil, nil, 0, 0
local function press(f, on) if f then f:set_value(on and 1 or 0) end end
local held = {}
local ko_hp, ko_zero, win_gs

local camlog = io.open(OUT .. "camera.log", "w")
emu.register_frame_done(function()
  frame = frame + 1
  -- the camera: worldtlx of MK1's main plane (0104F890h, 32-bit, integer in
  -- the high word) - blit x is SCREEN x, so a distance needs it added back
  camlog:write(string.format("%d %d\n", frame, mem:read_u32(0x0104F890) >> 16))
  local gs = r16(A.gstate)
  local k = (frame - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and frame >= 600)
  press(K.coin, in_menus and frame >= 1000 and (k < 6 or (k >= 30 and k < 36)))
  press(K.start, in_menus and frame >= 1000 and k >= 120 and k < 126)
  press(K.start2, TWO and in_menus and frame >= 1000 and k >= 140 and k < 146)
  if gs == GS_SELECT and not sel0 then sel0 = frame; L("f%d select", frame) end
  if gs == GS_SELECT or gs == GS_TOWER or not fight0 then w16(A.p1char, KANO); if TWO or VICTIM then w16(A.p2char, SONYA) end end
  local confirm = sel0 and frame >= sel0 + 300 and frame < sel0 + 306

  if gs == GS_FIGHT and not fight0 then
    fight0 = frame
    L("f%d FIGHT p1 ochar %d p2 ochar %d", frame, r16(A.p1char), r16(A.p2char))
  end
  for _, n in ipairs({"hp", "lp", "hk", "lk", "bl", "up", "down", "left", "right"}) do held[n] = false end
  if fight0 then
    if not VICTIM and not KO then w16(A.p1hp, 0xA1) end
    if WIN then
      if gs == GS_FIGHT and r16(A.p2hp) > 1 then w16(A.p2hp, 1) end
      if gs ~= win_gs then L("f%6d  GSTATE %04x -> %04x (bars %d/%d)", frame, win_gs or -1, gs, r16(A.p1hp), r16(A.p2hp)); win_gs = gs end
    else w16(A.p2hp, 0xA1) end
    if frame > fight0 + 120 and frame >= stepend then
      step = step + 1
      local s = S[step]
      if not s then
        L("DONE"); log:close(); blog:close(); manager.machine:exit(); return
      end
      move = s[1]; stepend = frame + s[2]
      L("f%6d  MOVE %s", frame, move)
    end
    local s = S[step]
    if s and s[3] then for _, n in ipairs(s[3]) do held[n] = true end end
    if s and (move == "knife" or move == "ball") and (frame - (stepend - s[2])) % 6 == 0 then
      pcall(function() scr:snapshot() end)
    end
  end
  if WIN and fight0 and gs == GS_FIGHT and r16(A.p2hp) > 0 then
    held.right = true
    held.hp = (frame % 16) < 3
    fin0 = nil
  elseif WIN and HEART and fight0 and gs == GS_FIGHT then
    -- FINISH HIM: the heart rip - Back, Down, Forward + Low Punch, close
    fin0 = fin0 or frame
    local rel = frame - fin0
    if rel < 45 then held.right = true                 -- walk in: the stunning hit knocked her back
    elseif rel < 420 then
      local k = (rel - 50) // 50                       -- attempt #, a different timing each
      local t = (rel - 50) % 50
      if rel >= 50 then
        if t == 0 then L("f%6d  HEART input, variant %d", frame, k % 3) end
        local v = k % 3
        if v == 0 then          -- B, D, F, then LP on its own
          held.left = t < 3; held.down = t >= 3 and t < 6; held.right = t >= 6 and t < 9
          held.lp = t >= 9 and t < 12
        elseif v == 1 then      -- a rolled half circle, LP with forward
          held.left = t < 6; held.down = t >= 3 and t < 12; held.right = t >= 9 and t < 16
          held.lp = t >= 13 and t < 16
        else                    -- slow taps with gaps
          held.left = t < 4; held.down = t >= 6 and t < 10; held.right = t >= 12 and t < 16
          held.lp = t >= 17 and t < 20
        end
      end
    end
  end
  for n, on in pairs(held) do press(K[n], on) end
  if not fight0 then press(K.hp, (frame >= 600 and frame < 606) or confirm); press(K.p2hp, TWO and confirm) end
  if SWEPT and fight0 and move == "gethit" then
    -- Sonya (P2, facing left: Back = Right) walks in, holds Back, sweeps
    for _, n in ipairs({"p2hp", "p2lk", "p2lp", "p2left", "p2right", "p2down", "p2bl"}) do press(K[n], false) end
    local t = frame % 140
    press(K.p2left, t < 40)
    press(K.p2right, t >= 50 and t < 66)
    press(K.p2lk, t >= 60 and t < 64)
    if t == 60 then L("f%6d  SONYA sweep", frame) end
  elseif KO and fight0 and move == "gethit" then
    for _, n in ipairs({"p2hp", "p2lk", "p2lp", "p2left", "p2right", "p2down", "p2bl"}) do press(K[n], false) end
    local hp = r16(A.p1hp)
    if gs == GS_FIGHT then
      if hp ~= ko_hp then L("f%6d  KANO BAR %d -> %d", frame, ko_hp or -1, hp); ko_hp = hp end
      if hp == 0 then ko_zero = ko_zero or frame else ko_zero = nil end
      if ko_zero and frame - ko_zero > 70 and frame - ko_zero < 400 then
        -- FINISH HIM (or the round is over): her fatality, forward = Left for P2
        local t = (frame - ko_zero - 70) % 90
        if t == 0 then L("f%6d  SONYA fatality input", frame) end
        press(K.p2left, (t < 4) or (t >= 7 and t < 11))
        press(K.p2right, (t >= 14 and t < 18) or (t >= 21 and t < 25))
        press(K.p2bl, t >= 28 and t < 34)
      elseif hp > 0 then
        local t = frame % 110
        press(K.p2left, t < 50)
        press(K.p2down, t >= 50 and t < 64)
        press(K.p2hp, t >= 58 and t < 62)
        if t == 58 then L("f%6d  SONYA uppercut", frame) end
      end
    else ko_zero = nil end
  elseif TWO and fight0 and move == "gethit" then
    -- Sonya walks in and, in turn: a high punch, an uppercut, a sweep, a throw
    local t = frame % 120
    local kind = (frame // 120) % 4
    press(K.p2left, t < 30)
    press(K.p2down, kind == 1 and t >= 36 and t < 44)
    press(K.p2right, kind == 2 and t >= 38 and t < 44)
    press(K.p2hp, (kind == 0 or kind == 1) and t >= 40 and t < 44)
    press(K.p2lk, kind == 2 and t >= 40 and t < 44)
    press(K.p2lp, kind == 3 and t >= 40 and t < 44)
    if t == 40 then L("f%6d  SONYA %s", frame, ({"hipunch", "uppercut", "sweep", "throw"})[kind + 1]) end
  elseif TWO and fight0 then for _, n in ipairs({"p2hp", "p2lk", "p2lp", "p2left", "p2right", "p2down"}) do press(K[n], false) end end
  if frame > 30000 then L("ERROR out of frames gs=%04x", gs); log:close(); blog:close(); manager.machine:exit() end
end)
