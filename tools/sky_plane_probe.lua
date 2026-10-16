-- sky_plane_probe.lua
--
-- Can a heat shimmer be confined to the BACKMOST PLANE only, instead of to a
-- band of scanlines?
--
-- dpytap cannot: it is a display register, so it moves whole rows and knows
-- nothing about z-order.  But Kahn's Arena's sky IS its own plane - baklst7,
-- built from arena6BMOD and drawn first in dlists_arena, so it is behind
-- everything.  Its blocks are ordinary display objects, and bgnd_ud1 only
-- ADDS blocks that scroll on and DELETES ones that scroll off; it does not
-- rewrite the position of a block already on the list.  So an x offset
-- written into a block's oxval should stick.
--
-- This measures, without a rebuild:
--
--   1  WHAT IS IN THE PLANE.  Displace the whole of baklst7 by a large amount
--      and diff the rendered frame - whatever moves is the sky plane, and
--      that is the exact extent any plane-isolated effect could ever cover.
--
--   2  DOES IT STICK.  Hold an offset for a while and check it is still there,
--      i.e. the background update does not fight it.
--
--   3  HOW MANY ROWS OF SHIMMER.  List the blocks with their y and height.
--      A per-object wave can only have as many steps as the plane has
--      distinct vertical bands.
--
--   4  IS IT CONTAINED.  With a per-block wave applied, rows belonging to the
--      wall, the throne, the fighters and the HUD must not move at all -
--      which is exactly what the dpytap band cannot promise.
--
-- Env: SKY_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("SKY_LOG") or (ROOT .. "/tools/sky_plane_probe.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[sky] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
  p1_bar_view = sym("p1_bar_view", 0), p2_bar_view = sym("p2_bar_view", 0),
  winner_status = sym("winner_status", 0), f_freeze_timer = sym("f_freeze_timer", 0),
  vshim_lo = sym("vshim_lo", 0),
  baklst6 = sym("baklst6"), baklst7 = sym("baklst7"),
  worldtlx7 = sym("worldtlx7"), worldtly = sym("worldtly"),
}

-- DISPEQU.ASM
local O = { link = 0, oxval = 0x080, oxpos = 0x090, oyval = 0x0a0, oypos = 0x0b0,
            osize = 0x120 }

local GS_FIGHTING, ARENA = 2, 8
local space = nil
local frame, fighting_frame = 0, 0
local done = false
local results, fails = {}, {}

local function r16(a) return space:read_u16(a) & 0xffff end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a & 0xffffffff) end
local function w32a(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return (v >= 0x8000) and (v - 0x10000) or v end

-- Walk a background list. The head holds a pointer to the first object.
local function walk(head, cap)
  local out, o, n = {}, r32(head), 0
  while o ~= 0 and n < (cap or 64) do
    out[#out + 1] = o
    o = r32(o + O.link)
    n = n + 1
  end
  return out
end

local base_x = {}          -- obj -> original oxval
local function snapshot_plane(objs)
  base_x = {}
  for _, o in ipairs(objs) do base_x[o] = r32(o + O.oxval) end
end
local function offset_plane(objs, fn)
  for _, o in ipairs(objs) do
    local b = base_x[o]
    if b then w32a(o + O.oxval, (b + (fn(o) << 16)) & 0xffffffff) end
  end
end
local function restore_plane(objs)
  for _, o in ipairs(objs) do
    local b = base_x[o]
    if b then w32a(o + O.oxval, b) end
  end
end

local SAMPLE_ROWS = {}
for y = 24, 250, 2 do SAMPLE_ROWS[#SAMPLE_ROWS + 1] = y end

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
local function differs(a, b)
  if not a or not b then return 0 end
  local d = 0
  for i = 1, #a do if a:byte(i) ~= b:byte(i) then d = d + 1 end end
  return d / #a
end
local function grab()
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

-- Compress a set of rows into readable ranges.
local function ranges(rows)
  table.sort(rows)
  local out, i = {}, 1
  while i <= #rows do
    local j = i
    while j < #rows and rows[j + 1] - rows[j] <= 2 do j = j + 1 end
    out[#out + 1] = (i == j) and tostring(rows[i])
                    or string.format("%d-%d", rows[i], rows[j])
    i = j + 1
  end
  return table.concat(out, ",")
end

local baseline, objs7 = nil, nil

local function finish()
  if done then return end
  done = true
  if objs7 then restore_plane(objs7) end
  for _, r in ipairs(results) do log("%s", r) end
  if #fails == 0 then log("no hard failures") else
    for _, f in ipairs(fails) do log("FAIL %s", f) end end
  manager.machine:exit()
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    log("---- back-plane isolation probe ----")
    if #missing > 0 then log("ERROR missing symbols: %s", table.concat(missing, ",")) end
  end
  if not space then return end
  if r16(A.gstate) ~= GS_FIGHTING then
    if frame > 6000 then log("ERROR never reached a fight"); finish() end
    return
  end
  if fighting_frame == 0 then
    fighting_frame = frame
    log("fight at frame %d, curback=%d", frame, r16(A.curback))
  end
  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.p1_bar_view ~= 0 then w16(A.p1_bar_view, 161) end
  if A.p2_bar_view ~= 0 then w16(A.p2_bar_view, 161) end
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

  local rel = frame - fighting_frame

  -- turn the dpytap shimmer OFF so it cannot contaminate the measurement
  if rel < 30 and A.vshim_lo ~= 0 then w16(A.vshim_lo, 0) end

  ------------------------------------------------------------------ 3 census
  if rel == 40 then
    objs7 = walk(A.baklst7)
    local o6 = walk(A.baklst6)
    results[#results + 1] = string.format(
      "PLANE baklst7 (backmost) holds %d live objects; baklst6 (wall) holds %d",
      #objs7, #o6)
    local rows = {}
    for _, o in ipairs(objs7) do
      local sz = r32(o + O.osize)
      local h, w = (sz >> 16) & 0xffff, sz & 0xffff
      rows[#rows + 1] = string.format("y=%d h=%d w=%d",
        s16(r16(o + O.oypos)), h, w)
    end
    results[#results + 1] = "PLANE blocks: " .. table.concat(rows, " | ")
    snapshot_plane(objs7)
    baseline = grab(); snap()
  end

  ------------------------------------------------------- 1 what is the plane
  if rel == 44 then offset_plane(objs7, function() return 40 end) end
  if rel == 48 then
    local now = grab(); snap()
    local moved = {}
    for _, y in ipairs(SAMPLE_ROWS) do
      if differs(baseline[y], now[y]) > 0.02 then moved[#moved + 1] = y end
    end
    results[#results + 1] = string.format(
      "EXTENT displacing the whole back plane by 40px changes rows: %s",
      #moved == 0 and "NONE" or ranges(moved))
    if #moved == 0 then
      fails[#fails + 1] = "moving baklst7 changed nothing - wrong list, or the writes are being overwritten"
    end
  end

  ------------------------------------------------------------- 2 does it stick
  if rel == 80 then
    local drift = 0
    for _, o in ipairs(objs7) do
      local want = (base_x[o] + (40 << 16)) & 0xffffffff
      if r32(o + O.oxval) ~= want then drift = drift + 1 end
    end
    results[#results + 1] = string.format(
      "STICKS after 36 ticks: %d of %d blocks had their offset overwritten",
      drift, #objs7)
    if drift > 0 then
      fails[#fails + 1] = "the background update rewrites block positions - a per-object wave would need a different hook"
    end
    restore_plane(objs7)
  end

  ---------------------------------------------------- 4 per-block wave, contained
  if rel >= 90 and rel < 130 then
    local ph = (rel - 90) // 3
    offset_plane(objs7, function(o)
      local y = s16(r16(o + O.oypos))
      local cell = ((y >> 3) + ph) % 8
      return ({ 0, 1, 2, 1, 0, -1, -2, -1 })[cell + 1]
    end)
  end
  if rel == 100 or rel == 106 then
    local now = grab(); snap()
    local moved = {}
    for _, y in ipairs(SAMPLE_ROWS) do
      local sh = best_shift(baseline[y], now[y], 6)
      if sh ~= 0 then moved[#moved + 1] = y end
    end
    results[#results + 1] = string.format(
      "WAVE rel=%d rows that moved: %s", rel, #moved == 0 and "NONE" or ranges(moved))
  end
  if rel == 131 then restore_plane(objs7) end

  ------------------------------------------- 5 static ramp: does the art tear?
  -- The blocks are 22..71 px tall and they OVERLAP.  If two overlapping
  -- blocks take different offsets, continuous artwork drawn across both
  -- splits.  Hold a big static ramp by block y and look at it - a moving
  -- wave hides a seam, a still one does not.
  if rel >= 140 and rel < 160 then
    local ys = {}
    for _, o in ipairs(objs7) do ys[#ys + 1] = s16(r16(o + O.oypos)) end
    table.sort(ys)
    local rank, seen = {}, 0
    for _, y in ipairs(ys) do
      if rank[y] == nil then rank[y] = seen; seen = seen + 1 end
    end
    offset_plane(objs7, function(o)
      local y = s16(r16(o + O.oypos))
      return ({ 0, 3, 6, 9, 6, 3, 0, 3 })[(rank[y] % 8) + 1]
    end)
  end
  if rel == 150 then
    snap()
    local now = grab()
    local moved = {}
    for _, y in ipairs(SAMPLE_ROWS) do
      local sh = best_shift(baseline[y], now[y], 12)
      if sh ~= 0 then moved[#moved + 1] = string.format("%d:%+d", y, sh) end
    end
    results[#results + 1] = "RAMP static, row:shift = " .. table.concat(moved, " ")
  end
  if rel == 161 then restore_plane(objs7) end

  if rel >= 170 then finish() end
  if frame > 20000 then log("ERROR timeout"); finish() end
end)
