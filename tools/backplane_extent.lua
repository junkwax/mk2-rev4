-- backplane_extent.lua
--
-- Which display list actually draws Kahn's staff, the dragon medallions, and
-- the sky - measured, not eyeballed.
--
-- Two earlier attempts at this were wrong, both for the same reason:
--
--   * Comparing screenshots seconds apart blamed the effect for animation.
--     sitting_kahn, kano_proc, sonya_proc, crowd_ani and both fighters are
--     all animating, so Kahn's staff "moves" between any two distant frames.
--   * Comparing frames ONE tick apart did not help either: consecutive
--     frames already differ by ~2800 pixels, which is MORE than a 24 px
--     displacement of a whole background plane changes. The signal was
--     smaller than the noise.
--
-- What works: build the animation mask from a whole idle cycle. Capture 24
-- untouched frames and union every pixel that changes across any of them.
-- That is everything capable of moving on its own. Then displace one list and
-- diff against a stored clean frame, subtracting the mask. Background blocks
-- are static art - bgnd_ud1 only adds and deletes them - so they survive the
-- subtraction while animation does not.
--
-- Env: BPE_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("BPE_LOG") or (ROOT .. "/tools/backplane_extent.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[bpe] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  vshim_lo = sym("vshim_lo", 0),
}
local LISTS = {
  { "baklst7 sky (backmost)", sym("baklst7") },
  { "baklst6 wall",           sym("baklst6") },
  { "baklst5 crowd",          sym("baklst5") },
  { "baklst4",                sym("baklst4") },
  { "baklst3",                sym("baklst3") },
  { "baklst2 parapet",        sym("baklst2") },
  { "baklst1 throne actors",  sym("baklst1") },
}

local O = { link = 0, oxval = 0x080 }
local GS_FIGHTING = 2
local SHOVE = 24
local W, H = 400, 254
local MASK_FRAMES = 24

local space, frame, ff, done = nil, 0, 0, false
local function r16(a) return space:read_u16(a) & 0xffff end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function walk(head)
  local out, o, n = {}, r32(head), 0
  while o ~= 0 and n < 128 do out[#out + 1] = o; o = r32(o + O.link); n = n + 1 end
  return out
end

local function grab()
  local scr = manager.machine.screens[":screen"]
  if not scr then return nil end
  local ok, pix, w = pcall(function() return scr:pixels() end)
  if not ok or type(pix) ~= "string" then return nil end
  return { pix = pix, w = w or scr.width }
end
local function px(g, x, y)
  return string.unpack("<I4", g.pix, ((y * g.w) + x) * 4 + 1) & 0xffffff
end
local function snap()
  local scr = manager.machine.screens[":screen"]
  if scr then pcall(function() scr:snapshot() end) end
end

local clean, anim_mask, anim_n = nil, {}, 0

local REGIONS = {
  { "left dragon medallion",  6,   46, 46,  76 },
  { "right dragon medallion", 352, 46, 396, 76 },
  { "Kahn's staff + orb",     188, 44, 214, 108 },
  { "Kahn on the throne",     170, 100, 232, 150 },
  { "sky / flames upper",     0,   44, 399, 80 },
  { "life bars / HUD",        0,   0,  399, 43 },
  { "floor + fighters",       0,   150, 399, 253 },
}

local results = {}
local li, sub, saved = 1, 0, {}

local function measure(name)
  local g = grab()
  local m, raw = {}, 0
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local k = y * W + x
      if not anim_mask[k] and px(clean, x, y) ~= px(g, x, y) then
        m[k] = true; raw = raw + 1
      end
    end
  end
  local parts = {}
  for _, r in ipairs(REGIONS) do
    local n, tot = 0, 0
    for y = r[3], r[5] do
      for x = r[2], r[4] do
        tot = tot + 1
        if m[y * W + x] then n = n + 1 end
      end
    end
    if n * 200 > tot then parts[#parts + 1] = r[1] end
  end
  local ys = {}
  for k in pairs(m) do ys[k // W] = (ys[k // W] or 0) + 1 end
  local list = {}
  for y, c in pairs(ys) do if c >= 4 then list[#list + 1] = y end end
  table.sort(list)
  local rng, i = {}, 1
  while i <= #list do
    local j = i
    while j < #list and list[j + 1] - list[j] <= 2 do j = j + 1 end
    rng[#rng + 1] = (i == j) and tostring(list[i]) or string.format("%d-%d", list[i], list[j])
    i = j + 1
  end
  results[#results + 1] = string.format("%-24s %5d px  rows %s", name, raw,
    #rng > 0 and table.concat(rng, ",") or "none")
  results[#results + 1] = string.format("%-24s        regions: %s", "",
    #parts > 0 and table.concat(parts, ", ") or "NONE")
end

local function finish()
  if done then return end
  done = true
  log("animation mask covers %d of %d pixels (%.1f%%)", anim_n, W * H, anim_n * 100 / (W * H))
  for _, r in ipairs(results) do log("%s", r) end
  manager.machine:exit()
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    log("---- which list draws what ----")
  end
  if not space then return end
  if r16(A.gstate) ~= GS_FIGHTING then
    if frame > 6000 then log("ERROR no fight"); finish() end
    return
  end
  if ff == 0 then ff = frame; log("fight at frame %d curback=%d", frame, r16(A.curback)) end

  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.p1_bar_view ~= 0 then w16(A.p1_bar_view, 161) end
  if A.p2_bar_view ~= 0 then w16(A.p2_bar_view, 161) end
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
  if A.vshim_lo ~= 0 then w16(A.vshim_lo, 0) end

  local rel = frame - ff
  if rel < 80 then return end

  -- ---- build the animation mask over a full idle cycle
  if rel == 80 then clean = grab(); snap(); return end
  if rel > 80 and rel <= 80 + MASK_FRAMES then
    local g = grab()
    for y = 0, H - 1 do
      for x = 0, W - 1 do
        local k = y * W + x
        if not anim_mask[k] and px(clean, x, y) ~= px(g, x, y) then
          anim_mask[k] = true; anim_n = anim_n + 1
        end
      end
    end
    return
  end

  -- ---- then shove each list in turn: apply, settle one frame, measure
  local base = 80 + MASK_FRAMES + 4
  local phase = (rel - base) % 4
  if rel < base then return end
  if li > #LISTS then finish(); return end
  local name, head = LISTS[li][1], LISTS[li][2]

  if phase == 0 then
    local objs = walk(head)
    saved = {}
    for _, o in ipairs(objs) do
      saved[o] = r32(o + O.oxval)
      w32(o + O.oxval, (saved[o] + (SHOVE << 16)) & 0xffffffff)
    end
  elseif phase == 1 then
    measure(name)
    snap()
  elseif phase == 2 then
    for o, v in pairs(saved) do w32(o + O.oxval, v) end
  elseif phase == 3 then
    li = li + 1
  end

  if frame > 20000 then log("ERROR timeout"); finish() end
end)
