-- shimmer_probe.lua
--
-- Two questions, both blockers for a Kahn's Arena sky heat shimmer built on
-- dpytap (UNUSED_HARDWARE_EFFECTS #5) + a raster band (UNUSED_GRAPHICS_
-- PRIMITIVES section 4):
--
--   Q1  Can a mid-frame dpytap change be SEEN in MAME at all?  The palette
--       split cannot be (midtunit resolves colour once per frame), so the
--       working assumption has been that nothing raster-timed is observable
--       here.  dpytap is different in kind: it feeds coladdr, which
--       midtunit's scanline_update consumes per line.  If it is per-line the
--       whole effect becomes testable without hardware.
--
--   Q2  Which scanlines can a poll actually reach?  Section 4 measured
--       203..273 from prcdsp's idle wait and concluded a split can only land
--       in the bottom fifth.  The sky is the TOP of the screen, so that would
--       kill this outright.  Here we measure the range a HOST-side poll can
--       reach, which upper-bounds what any in-ROM poll site could do.
--
-- Runs on the stock installed ROM.  No rebuild.
--
-- Env: SHIM_LOG, SHIM_STAGE (curback, default 8 = Kahn's Arena),
--      SHIM_P1, SHIM_P2, SHIM_LINE (split line for the Q1 picture test)

local ROOT  = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG   = os.getenv("SHIM_LOG") or (ROOT .. "/tools/shimmer_probe.log")
local STAGE = tonumber(os.getenv("SHIM_STAGE") or "8")
local P1    = tonumber(os.getenv("SHIM_P1") or "1")
local P2    = tonumber(os.getenv("SHIM_P2") or "11")
local LINE  = tonumber(os.getenv("SHIM_LINE") or "110")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[shim] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
local function sym(n, fb)
  local v = symbols[n]; if v then return v end
  if fb == nil then log("WARN missing symbol %s", n) end
  return fb or 0
end

local A = {
  gstate = sym("gstate"), curback = sym("curback"),
  p1_char = sym("p1_char"), p2_char = sym("p2_char"),
  p1_state = sym("p1_state"), p2_state = sym("p2_state"),
  p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
  p1_bar_view = sym("p1_bar_view", 0), p2_bar_view = sym("p2_bar_view", 0),
  map_position = sym("map_position", 0), battle_num = sym("battle_num", 0),
  winner_status = sym("winner_status", 0), f_freeze_timer = sym("f_freeze_timer", 0),
}

local R_VCOUNT = 0xc00001d0
local R_DPYTAP = 0xc00001b0
local TAP_BASE = 56 // 2

local GS_PSEL, GS_FIGHTING = 4, 2
local space, fields = nil, {}
local frame, charsel_frame, fighting_frame, p1_confirm = 0, 0, 0, 0
local done = false

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v) end

-- ---------------------------------------------------------------- Q2
local hist, polls = {}, 0
for i = 0, 511 do hist[i] = 0 end
local vmin, vmax = 9999, -1

-- ---------------------------------------------------------------- Q1
-- mode 0 = idle, 1 = split the tap at LINE, 2 = restore
local mode, TAP_SHIFT = 0, 6      -- 6 units = 12 px, unmissable
local tap_writes, tap_last = 0, nil

emu.register_periodic(function()
  if not space then return end
  local ok, v = pcall(r16, R_VCOUNT)
  if not ok then return end
  v = v & 0x1ff
  polls = polls + 1
  hist[v] = (hist[v] or 0) + 1
  if v < vmin then vmin = v end
  if v > vmax then vmax = v end

  if mode == 1 then
    -- Everything above LINE gets the shifted tap, everything below the base.
    local want = (v < LINE) and (TAP_BASE + TAP_SHIFT) or TAP_BASE
    if want ~= tap_last then
      w16(R_DPYTAP, want & 0xffff)
      tap_last = want
      tap_writes = tap_writes + 1
    end
  elseif mode == 2 then
    if tap_last ~= TAP_BASE then w16(R_DPYTAP, TAP_BASE); tap_last = TAP_BASE end
  end
end)

local function coverage_report()
  local seen = 0
  for i = 0, 511 do if hist[i] > 0 then seen = seen + 1 end end
  log("Q2 host poll: %d polls, vcount seen %d..%d, %d distinct lines",
      polls, vmin, vmax, seen)
  local buckets = {}
  for b = 0, 17 do
    local n = 0
    for i = b * 16, b * 16 + 15 do n = n + (hist[i] or 0) end
    buckets[#buckets + 1] = string.format("%d:%d", b * 16, n)
  end
  log("Q2 buckets (line:polls) %s", table.concat(buckets, " "))
end

local SAMPLE_ROWS = { 40, 60, 80, 100, 130, 160, 190, 220, 245 }

local function row_signature(pix, w, y)
  local s = {}
  local lim = math.min(w, 400)
  for x = 0, lim - 1 do
    local off = ((y * w) + x) * 4 + 1
    local v = string.unpack("<I4", pix, off)
    s[#s + 1] = string.char(((v >> 16) & 0xff) ~ ((v >> 8) & 0xff) ~ (v & 0xff))
  end
  return table.concat(s)
end

local function best_shift(a, b, maxs)
  if not a or not b then return 0, 1 end
  local bestd, bests = math.huge, 0
  for s = -maxs, maxs do
    local d, n = 0, 0
    for i = maxs + 1, #a - maxs do
      local ca, cb = a:byte(i), b:byte(i + s)
      if ca and cb then
        if ca ~= cb then d = d + 1 end
        n = n + 1
      end
    end
    if n > 0 then d = d / n end
    if d < bestd then bestd, bests = d, s end
  end
  return bests, bestd
end

local function grab_rows()
  local scr = manager.machine.screens[":screen"]
  if not scr then return nil end
  local ok, pix, w, h = pcall(function() return scr:pixels() end)
  if not ok or type(pix) ~= "string" then return nil end
  w = w or scr.width
  local rows = {}
  for _, y in ipairs(SAMPLE_ROWS) do rows[y] = row_signature(pix, w, y) end
  return rows
end

local base_rows = nil
local results = {}

local function finish()
  if done then return end
  done = true
  w16(R_DPYTAP, TAP_BASE)
  coverage_report()
  for _, r in ipairs(results) do log("%s", r) end
  log("Q1 tap writes issued: %d", tap_writes)
  manager.machine:exit()
end

local function pressed(name)
  if charsel_frame == 0 then
    if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    return false
  end
  if fighting_frame == 0 then
    return name == "P1 High Punch" and p1_confirm > 0 and
           frame >= p1_confirm and frame < p1_confirm + 45
  end
  return false
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    local want = { ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["P1 High Punch"] = true, ["UI Select"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    log("---- shimmer probe: stage=%d split line=%d tap shift=%+d units (%+d px) ----",
        STAGE, LINE, TAP_SHIFT, TAP_SHIFT * 2)
  end
  if not space then return end
  for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end

  local gs = r16(A.gstate)
  if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
  if charsel_frame > 0 and fighting_frame == 0 then
    w16(A.p1_state, 1); w16(A.p2_state, 0)
    w16(A.p1_char, P1); w16(A.p2_char, P2)
    w16(A.curback, STAGE)
    if A.map_position ~= 0 then w16(A.map_position, STAGE) end
    if A.battle_num ~= 0 then w16(A.battle_num, 1) end
    if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
  end
  if gs == GS_FIGHTING and fighting_frame == 0 then
    fighting_frame = frame
    log("fight at frame %d (dpytap reads %d)", frame, r16(R_DPYTAP))
  end
  if fighting_frame == 0 then
    if frame > 6000 then log("ERROR never reached fight"); finish() end
    return
  end

  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.p1_bar_view ~= 0 then w16(A.p1_bar_view, 161) end
  if A.p2_bar_view ~= 0 then w16(A.p2_bar_view, 161) end
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

  local rel = frame - fighting_frame
  local scr = manager.machine.screens[":screen"]

  if rel == 60 then
    base_rows = grab_rows()
    if scr then pcall(function() scr:snapshot() end) end
    results[#results + 1] = "Q1 baseline captured (tap = base everywhere): " ..
        (base_rows and "ok" or "PIXEL READ FAILED")
    for i = 0, 511 do hist[i] = 0 end
    polls, vmin, vmax = 0, 9999, -1
  end

  if rel == 70 then mode = 1; log("Q1 split armed at line %d", LINE) end

  if rel == 90 then
    local rows = grab_rows()
    if scr then pcall(function() scr:snapshot() end) end
    if rows and base_rows then
      local parts = {}
      for _, y in ipairs(SAMPLE_ROWS) do
        local s, d = best_shift(base_rows[y], rows[y], 16)
        parts[#parts + 1] = string.format("y%d=%+d(%.2f)", y, s, d)
      end
      results[#results + 1] = "Q1 per-row shift vs baseline: " .. table.concat(parts, " ")
    else
      results[#results + 1] = "Q1 could not read rendered pixels"
    end
  end

  -- control: does dpytap move anything at all in this build?
  if rel == 100 then mode = 0; w16(R_DPYTAP, TAP_BASE + TAP_SHIFT); tap_last = nil end
  if rel == 110 then
    local rows = grab_rows()
    if scr then pcall(function() scr:snapshot() end) end
    if rows and base_rows then
      local parts = {}
      for _, y in ipairs({ 40, 130, 245 }) do
        local s, d = best_shift(base_rows[y], rows[y], 16)
        parts[#parts + 1] = string.format("y%d=%+d(%.2f)", y, s, d)
      end
      results[#results + 1] = "Q1 control, whole-frame tap shift: " .. table.concat(parts, " ")
    end
  end
  if rel == 115 then mode = 2 end

  if rel >= 130 then finish() end
  if frame > 20000 then log("ERROR timeout"); finish() end
end)
