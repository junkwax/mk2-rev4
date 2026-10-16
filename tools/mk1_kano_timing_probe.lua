-- mk1_kano_timing_probe.lua - MK1 KANO's normals, their timing and knockback,
-- and his own knockback when he is hit - in MAME `mk` (rev 5.0).
--
-- A 2-player game, Kano (P1) against Sonya (P2), both bars pinned.  For every
-- move each side WALKS IN until the two are 8 px apart (measured off the
-- blits), settles, holds the direction first (MK1 reads a direction pressed on
-- the button's own tick as none), presses, and waits it out.  Kano attacks
-- first, then Sonya attacks him.
--   MOVE lines   which move, when
--   P lines      every tick: both fighters' drawn left/right (world x =
--                screen x + MK1's camera, 0104F890h)
--   blits.log    every blit, for the frames he was drawn on
-- Read with tools/mk1_kano_timing.py.  Env MK1T_OUT (dir).
local OUT = (os.getenv("MK1T_OUT") or "C:/tmp/mk1t/"):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local log = io.open(OUT .. "kano.log", "w")
local blog = io.open(OUT .. "blits.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end
local F = {}
for _, port in pairs(manager.machine.ioport.ports) do
  for name, f in pairs(port.fields) do F[name] = f end
end
local function r16(a) return mem:read_u16(a) end
local function w16(a, v) mem:write_u16(a, v) end
local A = { gstate = 0x01051190, p1char = 0x01051290, p2char = 0x01051570,
            p1hp = 0x01051300, p2hp = 0x010515E0 }
local GS_SELECT, GS_TOWER, GS_FIGHT = 4, 7, 2
local DMA, CAM = 0x01A80000, 0x0104F890

local frame, move = 0, "-"
local reg, box = {}, {}
local cam = 0
_G.mk1t_dma = mem:install_write_tap(DMA, DMA + 0xff, "mk1tdma", function(o, d, m)
  local r = (o - DMA) >> 4
  reg[r] = d
  if r == 1 and (d & 0x8000) ~= 0 then
    local cm = (reg[8] or 0) & 0xffff
    blog:write(string.format("%d %s %08x %d %d %d %d %04x %04x\n", frame, move,
      ((reg[3] or 0) << 16) | (reg[2] or 0), reg[4] or 0, reg[5] or 0, reg[6] or 0,
      reg[7] or 0, reg[0] or 0, cm))
    if cm == 0x0303 or cm == 0x0202 then
      local x0, x1 = (reg[4] or 0) + cam, (reg[4] or 0) + (reg[6] or 0) + cam
      local b = box[cm]
      if not b then box[cm] = {x0, x1} else b[1] = math.min(b[1], x0); b[2] = math.max(b[2], x1) end
    end
  end
  return d
end)

-- {who, name, direction-or-nil, button}; directions are P1's view for Kano
-- and "toward"/"away" for both
-- {who, name, direction-or-nil, button, gap}: walk in until the two are
-- `gap` px apart (8 = close range: MK1 turns High Punch into his elbow and
-- either kick into his knee there)
local KANO_MOVES = {
  {"kano", "hipunch_close", nil, "hp", 8}, {"kano", "hikick_close", nil, "hk", 8},
  {"kano", "hipunch", nil, "hp", 34}, {"kano", "lopunch", nil, "lp", 34}, {"kano", "hikick", nil, "hk", 40},
  {"kano", "lokick", nil, "lk", 40}, {"kano", "uppercut", "down", "hp", 12}, {"kano", "duckkick", "down", "lk", 24},
  {"kano", "duckhikick", "down", "hk", 24}, {"kano", "sweep", "away", "lk", 24}, {"kano", "roundhouse", "away", "hk", 24},
}
local SONYA_MOVES = {
  {"sonya", "hipunch", nil, "hp", 30}, {"sonya", "hikick", nil, "hk", 36}, {"sonya", "lokick", nil, "lk", 36},
  {"sonya", "uppercut", "down", "hp", 12}, {"sonya", "sweep", "away", "lk", 24}, {"sonya", "roundhouse", "away", "hk", 24},
}
-- the same moves out of range (a WHIFF): a move's hold at extension can
-- differ between a hit and a miss
local WHIFF_MOVES = {
  {"kano", "hipunch", nil, "hp", 110}, {"kano", "lopunch", nil, "lp", 110}, {"kano", "hikick", nil, "hk", 110},
  {"kano", "lokick", nil, "lk", 110}, {"kano", "uppercut", "down", "hp", 110}, {"kano", "duckkick", "down", "lk", 110},
  {"kano", "duckhikick", "down", "hk", 110}, {"kano", "sweep", "away", "lk", 110}, {"kano", "roundhouse", "away", "hk", 110},
}
-- where his close moves start: High Punch / High Kick at shrinking gaps
local RANGE_MOVES = {
  {"kano", "hp_g28", nil, "hp", 28}, {"kano", "hp_g22", nil, "hp", 22}, {"kano", "hp_g16", nil, "hp", 16},
  {"kano", "hp_g12", nil, "hp", 12}, {"kano", "hk_g8", nil, "hk", 8}, {"kano", "hk_g4", nil, "hk", 4},
  {"kano", "hk_g0", nil, "hk", 0}, {"kano", "hk_gm6", nil, "hk", -6},
  {"kano", "sweep_g4", "away", "lk", 4}, {"kano", "rh_g4", "away", "hk", 4},
}
-- how far each move REACHES: the same move at falling gaps (largest that
-- connects = his reach)
local REACH_MOVES = {}
for _, m in ipairs({{"hk", nil, "hk", {64, 56, 50, 45, 41}}, {"lk", nil, "lk", {64, 56, 50, 45, 41}},
                    {"upper", "down", "hp", {36, 30, 25, 20, 15}}, {"duckk", "down", "lk", {42, 36, 31, 27, 23}},
                    {"sweep", "away", "lk", {50, 42, 36, 31, 26}}, {"rh", "away", "hk", {34, 28, 22, 17, 12}}}) do
  for _, g in ipairs(m[4]) do
    REACH_MOVES[#REACH_MOVES + 1] = {"kano", m[1] .. "_g" .. g, m[2], m[3], g}
  end
end
-- ... half of it per run (MK1T_PART=1|2): the round clock is ~99 s
if os.getenv("MK1T_PART") then
  local part, keep = tonumber(os.getenv("MK1T_PART")), {}
  local half = math.ceil(#REACH_MOVES / 2)
  for i, m in ipairs(REACH_MOVES) do
    if (part == 1 and i <= half) or (part == 2 and i > half) then keep[#keep + 1] = m end
  end
  REACH_MOVES = keep
end
-- Down + LK against Down + HK at the same gaps (MK1 KANO's one duck kick:
-- does the button change the knockback?)
local DUCK_MOVES = {
  {"kano", "dlk_g28", "down", "lk", 28}, {"kano", "dhk_g28", "down", "hk", 28},
  {"kano", "dlk_g22", "down", "lk", 22}, {"kano", "dhk_g22", "down", "hk", 22},
  {"kano", "dlk_g16", "down", "lk", 16}, {"kano", "dhk_g16", "down", "hk", 16},
}
-- the round clock outlasts neither list together: MK1T_WHO picks one
local WHO = os.getenv("MK1T_WHO")
local MOVES = (WHO == "sonya") and SONYA_MOVES or (WHO == "whiff") and WHIFF_MOVES or (WHO == "range") and RANGE_MOVES or (WHO == "reach") and REACH_MOVES or (WHO == "duck") and DUCK_MOVES or KANO_MOVES
local function key(who, what)
  local p = (who == "kano") and "P1 " or "P2 "
  local m = {hp = "High Punch", lp = "Low Punch", hk = "High Kick", lk = "Low Kick", down = "Down"}
  if what == "toward" then return p .. ((who == "kano") and "Right" or "Left") end
  if what == "away" then return p .. ((who == "kano") and "Left" or "Right") end
  return p .. m[what]
end

local sel0, fight0, mi, phase, pt = nil, nil, 1, "approach", 0
emu.register_frame_done(function()
  frame = frame + 1
  cam = mem:read_u32(CAM) >> 16
  local k1, s1 = box[0x0303], box[0x0202]
  if fight0 and k1 and s1 then L("P %d %d %d %d %d", frame, k1[1], k1[2], s1[1], s1[2]) end
  box = {}
  for _, f in pairs(F) do f:set_value(0) end
  local gs = r16(A.gstate)
  local kk = (frame - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and frame >= 600)
  if in_menus and frame >= 1000 then
    F["Coin 1"]:set_value((kk < 6 or (kk >= 30 and kk < 36)) and 1 or 0)
    F["1 Player Start"]:set_value((kk >= 120 and kk < 126) and 1 or 0)
    F["2 Players Start"]:set_value((kk >= 140 and kk < 146) and 1 or 0)
  end
  if gs == GS_SELECT and not sel0 then sel0 = frame end
  if gs == GS_SELECT or gs == GS_TOWER or not fight0 then w16(A.p1char, 1); w16(A.p2char, 6) end
  if not fight0 then
    local confirm = sel0 and frame >= sel0 + 300 and frame < sel0 + 306
    F["P1 High Punch"]:set_value(((frame >= 600 and frame < 606) or confirm) and 1 or 0)
    F["P2 High Punch"]:set_value(confirm and 1 or 0)
    if gs == GS_FIGHT then fight0 = frame; L("FIGHT %d", frame) end
    return
  end
  w16(A.p1hp, 0xA1); w16(A.p2hp, 0xA1)
  if frame < fight0 + 120 then return end
  local mv = MOVES[mi]
  if not mv then L("DONE"); log:close(); blog:close(); manager.machine:exit(); return end
  local who, name, dir, btn, want = mv[1], mv[2], mv[3], mv[4], mv[5] or 8
  pt = pt + 1
  if phase == "approach" then
    move = "approach"
    local gap = (s1 and k1) and (s1[1] - k1[2]) or 99
    if gap > want and pt < 150 then F[key(who, "toward")]:set_value(1)
    elseif gap < want - 10 and pt < 150 then F[key(who, "away")]:set_value(1)
    else phase, pt = "settle", 0 end
  elseif phase == "settle" then
    if pt >= 25 then
      phase, pt = "go", 0; move = who .. "_" .. name
      L("MOVE %d %s gap %d", frame, move, (s1 and k1) and (s1[1] - k1[2]) or -1)
    end
  elseif phase == "go" then
    if dir and pt <= 14 then F[key(who, dir)]:set_value(1) end
    if pt >= 10 and pt < 15 then F[key(who, btn)]:set_value(1) end
    if pt >= 150 then
      -- back off a little so the next approach starts apart
      phase, pt = "backoff", 0
    end
  elseif phase == "backoff" then
    move = "backoff"
    if pt < 25 then F[key(who, "away")]:set_value(1) end
    if pt >= 40 then phase, pt = "approach", 0; mi = mi + 1 end
  end
  if frame > 60000 then L("ERROR out of frames"); log:close(); blog:close(); manager.machine:exit() end
end)
