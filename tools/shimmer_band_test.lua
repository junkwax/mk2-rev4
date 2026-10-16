-- shimmer_band_test.lua
--
-- Kahn's Arena heat shimmer over the burning sky, built from the two things
-- doc/GRAPHICS_CAPABILITIES.md names for it: dpytap (UNUSED_HARDWARE_EFFECTS
-- #5) restricted to a band of scanlines by the vcount poll
-- (UNUSED_GRAPHICS_PRIMITIVES S4).
--
-- The effect ARMS ITSELF: arena_heat_proc (BGND.ASM) is created by
-- arena_calla when the stage loads.  This rig does not turn it on; it
-- watches it and tries to break it.
--
--   COVERAGE   which scanlines the in-ROM poll reaches, full frame and then
--              zoomed into the gap.  S4 measured 203..273 from prcdsp's idle
--              wait alone and called the top of the frame "the open
--              problem"; the second poll site in the dispatch loop is what
--              changed that, and this is the number that says so.
--
--   FLAT       baseline with the wave table flattened to vshim_base.  Same
--              code path, zero displacement - so anything that moves between
--              this and the next capture is the wave and nothing else.
--
--   WAVE       per-row horizontal shift, sampled across the band and across
--              several frames.  A shimmer has to vary with ROW (it is a wave
--              down the screen, not a block shift) and with TIME (it
--              travels).  Both are checked; a uniform band would pass a
--              naive "did anything move" test and is exactly what this is
--              built to reject.
--
--   CONTAINED  rows outside the band must not move at all.  The band's
--              bottom edge is only as sharp as the poll is dense there,
--              which is why the edge was placed at vcount 98 rather than
--              further down.
--
-- Coordinates: veblnk is 014h, so screen row R is raw vcount R+20.
--
-- Env: SHIM_LOG, SHIM_P1, SHIM_P2

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("SHIM_LOG") or (ROOT .. "/tools/shimmer_band_test.log")
local P1   = tonumber(os.getenv("SHIM_P1") or "1")
local P2   = tonumber(os.getenv("SHIM_P2") or "11")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[band] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
local missing = {}
local function sym(n, fb)
  local v = symbols[n]; if v then return v end
  if fb == nil then missing[#missing + 1] = n end
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
  peak_overload = sym("peak_overload", 0), qdma_drops = sym("qdma_drops", 0),
  vsplit_ran = sym("vsplit_ran"),
  vsplit_vmin = sym("vsplit_vmin"), vsplit_vmax = sym("vsplit_vmax"),
  vsplit_hist = sym("vsplit_hist"),
  vshist_org = sym("vshist_org"), vshist_shift = sym("vshist_shift"),
  vshim_lo = sym("vshim_lo"), vshim_hi = sym("vshim_hi"),
  vshim_base = sym("vshim_base"), vshim_cur = sym("vshim_cur"),
  vshim_shift = sym("vshim_shift"), vshim_phase = sym("vshim_phase"),
  vshim_step = sym("vshim_step"), vshim_ttl = sym("vshim_ttl"),
  vshim_wr = sym("vshim_wr"), vshim_wave = sym("vshim_wave"),
}

local R_DPYTAP = 0xc00001b0
local BIAS     = 20            -- veblnk: screen row R == vcount R+BIAS
local HIST_N   = 18
local CELLS    = 16

local STAGE = 8                -- Kahn's Arena
local GS_PSEL, GS_FIGHTING = 4, 2

local space, fields = nil, {}
local frame, charsel_frame, fighting_frame, p1_confirm = 0, 0, 0, 0
local done = false
local results, fails = {}, {}

local function r16(a) return space:read_u16(a) & 0xffff end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function hist_window(org, shift)
  w16(A.vshist_org, org); w16(A.vshist_shift, shift)
  for i = 0, HIST_N - 1 do w16(A.vsplit_hist + i * 16, 0) end
  w16(A.vsplit_vmin, 0xffff); w16(A.vsplit_vmax, 0)
end
local function hist_read(org, shift)
  local h, tot = {}, 0
  for i = 0, HIST_N - 1 do
    local v = r16(A.vsplit_hist + i * 16)
    h[i] = v; tot = tot + v
  end
  local p = {}
  for i = 0, HIST_N - 1 do p[#p + 1] = string.format("%d:%d", org + (i << shift), h[i]) end
  return h, tot, table.concat(p, " ")
end

local function wave_read()
  local w = {}
  for i = 0, CELLS - 1 do w[i] = r16(A.vshim_wave + i * 16) end
  return w
end
local function wave_write(w)
  for i = 0, CELLS - 1 do w16(A.vshim_wave + i * 16, w[i]) end
end

-- Sample rows: dense through the band, sparse outside it, so "did it stay
-- put" is answered for the rest of the picture too.
local BAND_ROWS = {}
for y = 46, 76, 3 do BAND_ROWS[#BAND_ROWS + 1] = y end
local OUT_ROWS = { 24, 32, 40, 84, 92, 110, 140, 170, 200, 230, 248 }
local SAMPLE_ROWS = {}
for _, y in ipairs(BAND_ROWS) do SAMPLE_ROWS[#SAMPLE_ROWS + 1] = y end
for _, y in ipairs(OUT_ROWS) do SAMPLE_ROWS[#SAMPLE_ROWS + 1] = y end

local function row_signature(pix, w, y)
  local s, lim = {}, math.min(w, 400)
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
  for sh = -maxs, maxs do
    local d, n = 0, 0
    for i = maxs + 1, #a - maxs do
      local ca, cb = a:byte(i), b:byte(i + sh)
      if ca and cb then
        if ca ~= cb then d = d + 1 end
        n = n + 1
      end
    end
    if n > 0 then d = d / n end
    if d < bestd then bestd, bests = d, sh end
  end
  return bests, bestd
end

local function grab_rows()
  local scr = manager.machine.screens[":screen"]
  if not scr then return nil end
  local ok, pix, w = pcall(function() return scr:pixels() end)
  if not ok or type(pix) ~= "string" then return nil end
  w = w or scr.width
  local rows = {}
  for _, y in ipairs(SAMPLE_ROWS) do rows[y] = row_signature(pix, w, y) end
  return rows
end

local function snap()
  local scr = manager.machine.screens[":screen"]
  if scr then pcall(function() scr:snapshot() end) end
end

local flat_rows = nil
local saved_wave = nil
local captures = {}            -- {frame=, shifts={row->px}}

local function measure(tag)
  local rows = grab_rows()
  if not rows or not flat_rows then
    fails[#fails + 1] = tag .. ": could not read rendered pixels"
    return nil
  end
  local shifts = {}
  for _, y in ipairs(SAMPLE_ROWS) do
    shifts[y] = (best_shift(flat_rows[y], rows[y], 12))
  end
  captures[#captures + 1] = { tag = tag, shifts = shifts }
  return shifts
end

local function finish()
  if done then return end
  done = true
  if saved_wave then wave_write(saved_wave) end
  for _, r in ipairs(results) do log("%s", r) end

  -- ---- report the wave captures
  local band_profiles, moved_any = {}, false
  for _, c in ipairs(captures) do
    local p = {}
    for _, y in ipairs(BAND_ROWS) do
      p[#p + 1] = string.format("%+d", c.shifts[y])
      if c.shifts[y] ~= 0 then moved_any = true end
    end
    band_profiles[#band_profiles + 1] = table.concat(p, ",")
    log("WAVE %s band rows %d..%d: %s", c.tag, BAND_ROWS[1], BAND_ROWS[#BAND_ROWS],
        table.concat(p, ","))
    local out = {}
    for _, y in ipairs(OUT_ROWS) do
      if c.shifts[y] ~= 0 then out[#out + 1] = string.format("y%d=%+d", y, c.shifts[y]) end
    end
    log("     %s outside the band: %s", c.tag,
        #out == 0 and "all rows unmoved" or table.concat(out, " "))
    if #out > 0 then
      fails[#fails + 1] = string.format("%s leaked outside the band: %s",
        c.tag, table.concat(out, " "))
    end
  end

  if not moved_any then
    fails[#fails + 1] = "no row in the band ever moved - the shimmer is not running"
  end

  -- varies with ROW?  a block shift would give one value across the band
  local varied_rows = 0
  for _, p in ipairs(band_profiles) do
    local seen = {}
    for v in p:gmatch("[^,]+") do seen[v] = true end
    local n = 0; for _ in pairs(seen) do n = n + 1 end
    if n > 1 then varied_rows = varied_rows + 1 end
  end
  -- varies with TIME?  a static distortion would give the same profile twice
  local distinct = {}
  for _, p in ipairs(band_profiles) do distinct[p] = true end
  local n_distinct = 0; for _ in pairs(distinct) do n_distinct = n_distinct + 1 end

  log("SHAPE: %d of %d captures vary across rows; %d distinct profiles over time",
      varied_rows, #band_profiles, n_distinct)
  if varied_rows == 0 then
    fails[#fails + 1] = "the band shifts as one block - that is a slide, not a shimmer"
  end
  if n_distinct < 2 then
    fails[#fails + 1] = "the profile never changes - the wave is not travelling"
  end

  log("sentinels: vshim_wr=%d vshim_lo=%d vshim_ttl=%d phase=%d dpytap=%d",
      r16(A.vshim_wr), r16(A.vshim_lo), r16(A.vshim_ttl),
      r16(A.vshim_phase), r16(R_DPYTAP))
  log("peak_overload=%d qdma_drops=%d",
      A.peak_overload ~= 0 and r16(A.peak_overload) or -1,
      A.qdma_drops ~= 0 and r16(A.qdma_drops) or -1)

  if #fails == 0 then log("PASS: travelling wave, confined to the band")
  else for _, f in ipairs(fails) do log("FAIL %s", f) end end
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
    log("---- Kahn's Arena sky shimmer ----")
    if #missing > 0 then
      log("ERROR missing symbols: %s (stale map, or vshim/vsprobe compiled out)",
          table.concat(missing, ","))
    end
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
    log("fight at frame %d", frame)
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

  -- ------------------------------------------------- did it arm itself?
  if rel == 20 then
    local base = r16(A.vshim_base)
    saved_wave = wave_read()
    local wv = {}
    for i = 0, CELLS - 1 do wv[#wv + 1] = saved_wave[i] - base end
    results[#results + 1] = string.format(
      "ARMED BY THE STAGE: lo=%d hi=%d (screen rows %d..%d) shift=%d step=%d ttl=%d base=%d",
      r16(A.vshim_lo), r16(A.vshim_hi), r16(A.vshim_lo) - BIAS, r16(A.vshim_hi) - BIAS,
      r16(A.vshim_shift), r16(A.vshim_step), r16(A.vshim_ttl), base)
    results[#results + 1] = "wave, as offsets from base (1 unit = 2 px): " ..
      table.concat(wv, ",")
    if r16(A.vshim_lo) == 0 then
      fails[#fails + 1] = "arena_heat_proc never armed the band"
    end
  end

  -- ------------------------------------------------- coverage, full frame
  if rel == 24 then hist_window(0, 4) end
  if rel == 39 then
    local h, tot, txt = hist_read(0, 4)
    results[#results + 1] = string.format(
      "COVERAGE full frame, 15 frames: %d polls, vcount %d..%d",
      tot, r16(A.vsplit_vmin), r16(A.vsplit_vmax))
    results[#results + 1] = "COVERAGE 16-line buckets " .. txt
    -- density where the band actually lives
    local lo, hi = r16(A.vshim_lo), r16(A.vshim_hi)
    local n = 0
    for i = 0, HIST_N - 1 do
      local b0, b1 = i * 16, i * 16 + 16
      if b0 < hi and b1 > lo then n = n + h[i] end
    end
    results[#results + 1] = string.format(
      "COVERAGE inside the band (vcount %d..%d): %.1f polls/frame over %d lines",
      lo, hi, n / 15, hi - lo)
    hist_window(96, 2)
  end
  if rel == 54 then
    local _, tot, txt = hist_read(96, 2)
    results[#results + 1] = string.format(
      "COVERAGE zoomed on the gap below the band, 4-line buckets (%d polls): %s", tot, txt)
  end

  -- ------------------------------------------------- cost, isolated
  -- peak_overload is a high-water mark since BOOT, and attract mode plus
  -- character select run before any of this, so reading it at the end
  -- measures the menus.  It is write-only as far as the game is concerned
  -- (MPROC.ASM: nothing branches on it), so zero it and let it re-accumulate
  -- over a known window instead.  Flat wave = the poll runs and compares but
  -- almost never writes; live wave = the same poll plus the register writes.
  if rel == 56 then
    results[#results + 1] = string.format(
      "COST peak_overload was %d on arrival (attract + select, not this)",
      r16(A.peak_overload))
    w16(A.peak_overload, 0)
  end

  -- ------------------------------------------------- flat baseline
  if rel == 60 then
    local base = r16(A.vshim_base)
    local flat = {}
    for i = 0, CELLS - 1 do flat[i] = base end
    wave_write(flat)
  end
  if rel == 64 then
    flat_rows = grab_rows(); snap()
    results[#results + 1] = string.format(
      "COST peak_overload %d over the 8 ticks before the wave was restored",
      r16(A.peak_overload))
    w16(A.peak_overload, 0)
    w16(A.vshim_wr, 0)
    results[#results + 1] = "FLAT baseline captured (wave flattened to base, band still armed)"
    if not flat_rows then fails[#fails + 1] = "flat baseline: no rendered pixels" end
    wave_write(saved_wave)
  end

  -- ------------------------------------------------- the wave, over time
  for i, at in ipairs({ 68, 71, 74, 77, 80, 83 }) do
    if rel == at then measure(string.format("t%d", i)); if i == 1 or i == 4 then snap() end end
  end

  if rel == 88 then
    results[#results + 1] = string.format(
      "COST peak_overload %d over 24 ticks of live shimmer (%d dpytap writes = %.0f/frame)",
      r16(A.peak_overload), r16(A.vshim_wr), r16(A.vshim_wr) / 24)
  end

  if rel >= 90 then finish() end
  if frame > 20000 then log("ERROR timeout"); finish() end
end)
