-- shimmer_preview.lua
--
-- Watch the Kahn's Arena sky shimmer, and A/B it against no shimmer.
--
-- The effect is a +-2 pixel horizontal wave travelling down the burning sky
-- (raw vcount 64..98 = screen rows 44..78).  Two pixels is the finest this
-- hardware goes - one dpytap unit is two pixels - so the honest way to see it
-- is to toggle it off and back on, not to stare at it.
--
-- Nothing here arms the effect.  arena_heat_proc (BGND.ASM) does that when
-- the stage loads; this only holds the round open so it can be looked at, and
-- flattens the wave on request.
--
--   1 (numpad)  shimmer on / off        <- the A/B
--   2 (numpad)  cycle amplitude  1 / 2 / 4 units  (2 / 4 / 8 px)
--   3 (numpad)  cycle wave speed
--   4 (numpad)  cycle band height - shrink toward the sky strip, or grow it
--   0 (numpad)  put everything back to the shipped values
--
-- Env: SHIM_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("SHIM_LOG") or (ROOT .. "/tools/shimmer_preview.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[prev] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  vshim_lo = sym("vshim_lo"), vshim_hi = sym("vshim_hi"),
  vshim_base = sym("vshim_base"), vshim_step = sym("vshim_step"),
  vshim_shift = sym("vshim_shift"), vshim_wave = sym("vshim_wave"),
}

local CELLS = 16
local GS_FIGHTING, ARENA = 2, 8
-- the shipped band, ARENA_HEAT_LO/HI in BGND.ASM
local SHIP_LO, SHIP_HI, SHIP_STEP, SHIP_SHIFT = 64, 98, 85, 2

local space = nil
local frame = 0
local on, amp_ix, step_ix, band_ix = true, 1, 2, 2
local AMPS  = { 1, 2, 4 }
local STEPS = { 32, 85, 170 }
local BANDS = { { 64, 82, "sky strip only (rows 44..62)" },
                { 64, 98, "shipped (rows 44..78)" },
                { 64, 112, "down to the wall (rows 44..92) - edge gets soft" } }

local function r16(a) return space:read_u16(a) & 0xffff end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

-- One cycle of eight cells, twice.  Absolute dpytap values, biased by base.
local SHAPE = { 0, 1, 1, 1, 0, -1, -1, -1, 0, 1, 1, 1, 0, -1, -1, -1 }

local function write_wave()
  local base = r16(A.vshim_base)
  if base == 0 then return end
  local a = on and AMPS[amp_ix] or 0
  for i = 0, CELLS - 1 do
    w16(A.vshim_wave + i * 16, base + SHAPE[i + 1] * a)
  end
end

local function apply_band()
  local b = BANDS[band_ix]
  w16(A.vshim_hi, b[2])
  w16(A.vshim_lo, b[1])
end

local function say()
  local b = BANDS[band_ix]
  log("shimmer %s | amplitude %d unit(s) = %d px | step %d | band %s",
      on and "ON" or "OFF", AMPS[amp_ix], AMPS[amp_ix] * 2, STEPS[step_ix], b[3])
end

local HOTKEYS = {
  { "KEYCODE_1_PAD", function() on = not on; write_wave(); say() end,
    "shimmer on / off  <- the A/B" },
  { "KEYCODE_2_PAD", function() amp_ix = amp_ix % #AMPS + 1; write_wave(); say() end,
    "amplitude 2 / 4 / 8 px" },
  { "KEYCODE_3_PAD", function()
      step_ix = step_ix % #STEPS + 1; w16(A.vshim_step, STEPS[step_ix]); say() end,
    "wave speed" },
  { "KEYCODE_4_PAD", function() band_ix = band_ix % #BANDS + 1; apply_band(); say() end,
    "band height" },
  { "KEYCODE_0_PAD", function()
      on, amp_ix, step_ix, band_ix = true, 1, 2, 2
      w16(A.vshim_step, SHIP_STEP); w16(A.vshim_shift, SHIP_SHIFT)
      apply_band(); write_wave(); say() end,
    "back to the shipped values" },
}

local input_sys, debounce = nil, {}
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

local announced = false

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    input_sys = manager.machine.input
    log("---- Kahn's Arena sky shimmer, preview ----")
    log("keys (NUMPAD):")
    for _, hk in ipairs(HOTKEYS) do
      log("  %-6s %s", hk[1]:gsub("KEYCODE_", ""):gsub("_PAD", ""), hk[3])
    end
    log("the wobble is 2 px - toggle with 1 rather than staring at it")
  end
  if not space then return end
  hotkeys()

  if r16(A.gstate) ~= GS_FIGHTING then return end

  -- hold the round open so there is something to look at
  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.p1_bar_view ~= 0 then w16(A.p1_bar_view, 161) end
  if A.p2_bar_view ~= 0 then w16(A.p2_bar_view, 161) end
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

  if not announced and r16(A.vshim_lo) ~= 0 then
    announced = true
    log("armed by the stage: lo=%d hi=%d base=%d (curback=%d)",
        r16(A.vshim_lo), r16(A.vshim_hi), r16(A.vshim_base), r16(A.curback))
    say()
  end
  if announced and r16(A.curback) ~= ARENA then announced = false end
end)
