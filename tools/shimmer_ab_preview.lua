-- shimmer_ab_preview.lua
--
-- A/B the two ways of shimmering Kahn's sky, live, in one session:
--
--   MODE 1  back-plane object wave - drives baklst7's 15 blocks directly.
--           Only the back plane can move, by construction.  Measured: that
--           plane is the FIRE GLOW and nothing else, so the dragon
--           medallions, Kahn's staff and orb, the pagodas, the throne, the
--           fighters and the HUD are all in front of it and untouchable.
--           1 px steps, but only as many steps as the plane has blocks.
--
--   MODE 2  dpytap raster band - the built one.  The video hardware re-taps
--           the shift register per scanline, so it moves EVERY plane on those
--           rows: fire, pagodas, the staff, the medallions, and any fighter
--           who jumps into the band.  Smooth, but it cannot be aimed at a
--           layer.  2 px minimum, because one dpytap unit is two pixels.
--
-- Toggling between them in the same instant is the only honest comparison.
-- A pair of still screenshots taken seconds apart is NOT: sitting_kahn
-- animates, the camera scrolls, and the dragon logo is itself an animated
-- flaming sprite, so a still diff blames whichever effect was on for motion
-- it did not cause.  That confounded three separate measurements before the
-- held 60 px shove settled it.
--
--   1 (numpad)  cycle  OFF -> back-plane wave -> dpytap band -> OFF
--   2 (numpad)  amplitude
--   3 (numpad)  wave speed
--   4 (numpad)  freeze the wave (hold one shape) - makes seams visible
--   5 (numpad)  displace the WHOLE back plane 24px, held - shows its extent
--   0 (numpad)  everything off
--
-- Env: AB_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("AB_LOG") or (ROOT .. "/tools/shimmer_ab_preview.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[ab] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
  print(l); if logfh then logfh:write(l, "\n"); logfh:flush() end
end

local symbols = {}
do
  local fh = io.open(ROOT .. "/src/mk2.map", "r")
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
  end
end
local function sym(n, fb) return symbols[n] or fb or 0 end

local A = {
  gstate = sym("gstate"), curback = sym("curback"),
  p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
  p1_bar_view = sym("p1_bar_view", 0), p2_bar_view = sym("p2_bar_view", 0),
  winner_status = sym("winner_status", 0), f_freeze_timer = sym("f_freeze_timer", 0),
  vshim_lo = sym("vshim_lo"), vshim_base = sym("vshim_base"),
  vshim_wave = sym("vshim_wave"), vshim_step = sym("vshim_step"),
  baklst7 = sym("baklst7"), baklst1 = sym("baklst1"),
  worldtlx7 = sym("worldtlx7"), worldtlx2 = sym("worldtlx2"), worldtly = sym("worldtly"),
}

local O = { link = 0, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, osize = 0x120 }
local CELLS, GS_FIGHTING, ARENA = 16, 2, 8
local SHIP_LO, SHIP_HI = 64, 98

local space, input_sys = nil, nil
local frame, fighting_frame = 0, 0
local mode, amp_ix, speed_ix, frozen, extent = 0, 2, 2, false, false
local AMPS, SPEEDS = { 1, 2, 4 }, { 6, 3, 1 }
-- Measured 2026-08-26 by shoving baklst7 60px and holding it: the back
-- plane is the FIRE GLOW and nothing else.  The dragon medallions, Kahn's
-- staff and orb, the pagodas, the throne, the fighters and the HUD are all
-- in front of it and cannot be touched by mode 1.
local MODES = { "OFF", "back-plane wave (fire only)", "dpytap band (whole scanlines)" }
local phase, tick = 0, 0

local function r16(a) return space:read_u16(a) & 0xffff end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return (v >= 0x8000) and (v - 0x10000) or v end

local function walk(head)
  local out, o, n = {}, r32(head), 0
  while o ~= 0 and n < 128 do out[#out + 1] = o; o = r32(o + O.link); n = n + 1 end
  return out
end

-- ---------------------------------------------------------------- back plane
local base_x, base_n = {}, 0
local function plane_restore()
  for o, v in pairs(base_x) do w32(o + O.oxval, v) end
end
local function plane_sync()
  local objs = walk(A.baklst7)
  if #objs ~= base_n then                 -- list changed: start over cleanly
    plane_restore(); base_x, base_n = {}, #objs
    for _, o in ipairs(objs) do base_x[o] = r32(o + O.oxval) end
  end
  return objs
end

local SHAPE = { 0, 1, 1, 1, 0, -1, -1, -1 }
local function plane_apply(objs)
  local a = AMPS[amp_ix]
  for _, o in ipairs(objs) do
    local b = base_x[o]
    if b then
      local y = s16(r16(o + O.oypos))
      local cell = ((y >> 2) + phase) % 8
      w32(o + O.oxval, (b + ((SHAPE[cell + 1] * a) << 16)) & 0xffffffff)
    end
  end
end
local function plane_shove(objs, px)
  for _, o in ipairs(objs) do
    local b = base_x[o]
    if b then w32(o + O.oxval, (b + (px << 16)) & 0xffffffff) end
  end
end

-- ---------------------------------------------------------------- dpytap band
local function band_wave(on)
  local b = r16(A.vshim_base)
  if b == 0 then return end
  local a = on and AMPS[amp_ix] or 0
  -- dpytap units are 2px, so halve the pixel amplitude, min 1 when on
  local u = on and math.max(1, a // 2) or 0
  for i = 0, CELLS - 1 do
    w16(A.vshim_wave + i * 16, b + SHAPE[(i % 8) + 1] * u)
  end
end
local function band_set(on)
  if on then band_wave(true); w16(A.vshim_lo, SHIP_LO)
  else w16(A.vshim_lo, 0) end
end

local function say()
  log("MODE %s | amplitude %d px | speed %d ticks/step | wave %s%s",
      MODES[mode + 1], AMPS[amp_ix], SPEEDS[speed_ix],
      frozen and "FROZEN" or "travelling",
      extent and " | BACK PLANE SHOVED 24px" or "")
end

local function set_mode(m)
  mode = m
  plane_restore()
  band_set(false)
  if mode == 2 then band_set(true) end
  say()
end

local HOTKEYS = {
  { "KEYCODE_1_PAD", function() extent = false; set_mode((mode + 1) % 3) end,
    "cycle OFF / back-plane wave (fire only) / dpytap band" },
  { "KEYCODE_2_PAD", function() amp_ix = amp_ix % #AMPS + 1
      if mode == 2 then band_wave(true) end; say() end, "amplitude" },
  { "KEYCODE_3_PAD", function() speed_ix = speed_ix % #SPEEDS + 1; say() end, "wave speed" },
  { "KEYCODE_4_PAD", function() frozen = not frozen; say() end,
    "freeze the wave - hold one shape so seams are visible" },
  { "KEYCODE_5_PAD", function() extent = not extent
      if extent then set_mode(0) end; say() end,
    "shove the WHOLE back plane 24px - shows exactly what it contains" },
  { "KEYCODE_0_PAD", function() extent = false; set_mode(0) end, "everything off" },
}

local debounce = {}
local function hotkeys()
  for _, hk in ipairs(HOTKEYS) do
    local ok, code = pcall(function() return input_sys:code_from_token(hk[1]) end)
    if ok and code then
      local ok2, down = pcall(function() return input_sys:code_pressed(code) end)
      if ok2 then
        if down and not debounce[hk[1]] then hk[2]() end
        debounce[hk[1]] = down
      end
    end
  end
end

local reported = false

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    input_sys = manager.machine.input
    log("---- shimmer A/B ----")
    for _, hk in ipairs(HOTKEYS) do
      log("  %-5s %s", hk[1]:gsub("KEYCODE_", ""):gsub("_PAD", ""), hk[3])
    end
  end
  if not space then return end
  hotkeys()
  if r16(A.gstate) ~= GS_FIGHTING then return end
  if fighting_frame == 0 then fighting_frame = frame end

  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.p1_bar_view ~= 0 then w16(A.p1_bar_view, 161) end
  if A.p2_bar_view ~= 0 then w16(A.p2_bar_view, 161) end
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

  local objs = plane_sync()

  if not reported and #objs > 0 and r16(A.curback) == ARENA then
    reported = true
    -- where each back-plane block actually lands on screen
    local wx = (r32(A.worldtlx7) >> 16) & 0xffff
    local wy = (r32(A.worldtly) >> 16) & 0xffff
    log("back plane: %d blocks, worldtlx7=%d worldtly=%d", #objs, s16(wx), s16(wy))
    for _, o in ipairs(objs) do
      local sz = r32(o + O.osize)
      local h, w = (sz >> 16) & 0xffff, sz & 0xffff
      local sx = s16(r16(o + O.oxpos)) - s16(wx)
      local sy = s16(r16(o + O.oypos)) - s16(wy)
      log("   block screen x %4d..%4d  y %3d..%3d", sx, sx + w - 1, sy, sy + h - 1)
    end
    set_mode(0)
  end

  -- start OFF so the first thing seen is the untouched stage
  if mode == 0 and not extent then
    band_set(false)
    plane_restore()
    return
  end

  tick = tick + 1
  if not frozen and tick % SPEEDS[speed_ix] == 0 then phase = (phase + 1) % 8 end

  if extent then
    plane_shove(objs, 24)
  elseif mode == 1 then
    plane_apply(objs)
  end
end)
