-- layer_id_probe.lua
--
-- Which display list owns which pixels on Kahn's Arena?
--
-- "Isolate the effect to the back plane" is only worth anything if the things
-- that must NOT move are in some other list.  Eyeballing a screenshot cannot
-- settle that - the crowd, the throne actors and both fighters are all
-- animating, so a raw frame diff blames them for movement they did not do.
--
-- Method: displace ONE list by a known amount for a single frame and compare
-- against the frame immediately before it, so animation has one tick to
-- interfere instead of eight.  A mask taken from two consecutive UNDISTURBED
-- frames says which columns move on their own; those are excluded.
--
-- Run per list: baklst7 (sky), baklst6 (wall), baklst2 + baklst1 (throne
-- actors and the foreground parapet), objlst (the fighters).
--
-- Output is a per-list bounding box of what actually moved, plus a snapshot
-- with the list displaced so it can be looked at directly.
--
-- Env: LAYER_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("LAYER_LOG") or (ROOT .. "/tools/layer_id_probe.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[layer] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  { "baklst7 (sky, backmost)", sym("baklst7") },
  { "baklst6 (wall)",          sym("baklst6") },
  { "baklst5 (crowd)",         sym("baklst5") },
  { "baklst2 (parapet)",       sym("baklst2") },
  { "baklst1 (throne actors)", sym("baklst1") },
  { "objlst  (fighters)",      sym("objlst") },
}

local O = { link = 0, oxval = 0x080, oypos = 0x0b0, osize = 0x120 }
local GS_FIGHTING = 2
local SHIFT_PX = 24

local space, frame, fighting_frame, done = nil, 0, 0, false
local results = {}

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

-- Full-frame pixel grab as a flat table of 400*254 keys.
local W, H = 400, 254
local function grab()
  local scr = manager.machine.screens[":screen"]
  if not scr then return nil end
  local ok, pix, w = pcall(function() return scr:pixels() end)
  if not ok or type(pix) ~= "string" then return nil end
  w = w or scr.width
  return { pix = pix, w = w }
end
local function px(g, x, y)
  local off = ((y * g.w) + x) * 4 + 1
  return string.unpack("<I4", g.pix, off) & 0xffffff
end
local function snap()
  local scr = manager.machine.screens[":screen"]
  if scr then pcall(function() scr:snapshot() end) end
end

-- pixels that differ between two grabs, as a set of (x,y)
local function diffset(a, b)
  local s, n = {}, 0
  for y = 0, H - 1 do
    for x = 0, W - 1, 2 do
      if px(a, x, y) ~= px(b, x, y) then s[y * W + x] = true; n = n + 1 end
    end
  end
  return s, n
end

local function bbox(s)
  local x0, y0, x1, y1, n = 1e9, 1e9, -1, -1, 0
  for k in pairs(s) do
    local y, x = k // W, k % W
    if x < x0 then x0 = x end
    if x > x1 then x1 = x end
    if y < y0 then y0 = y end
    if y > y1 then y1 = y end
    n = n + 1
  end
  if n == 0 then return nil end
  return x0, y0, x1, y1, n
end

local function rowset(s)
  local rows = {}
  for k in pairs(s) do rows[k // W] = (rows[k // W] or 0) + 1 end
  local list = {}
  for y, c in pairs(rows) do if c >= 3 then list[#list + 1] = y end end
  table.sort(list)
  local out, i = {}, 1
  while i <= #list do
    local j = i
    while j < #list and list[j + 1] - list[j] <= 3 do j = j + 1 end
    out[#out + 1] = (i == j) and tostring(list[i]) or string.format("%d-%d", list[i], list[j])
    i = j + 1
  end
  return table.concat(out, ",")
end

local step, li = 0, 1
local g_prev, g_mask, saved = nil, nil, nil

local function finish()
  if done then return end
  done = true
  for _, r in ipairs(results) do log("%s", r) end
  manager.machine:exit()
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    log("---- which list owns which pixels ----")
  end
  if not space then return end
  if r16(A.gstate) ~= GS_FIGHTING then
    if frame > 6000 then log("ERROR never reached a fight"); finish() end
    return
  end
  if fighting_frame == 0 then
    fighting_frame = frame
    log("fight at frame %d curback=%d", frame, r16(A.curback))
  end
  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.p1_bar_view ~= 0 then w16(A.p1_bar_view, 161) end
  if A.p2_bar_view ~= 0 then w16(A.p2_bar_view, 161) end
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
  if A.vshim_lo ~= 0 then w16(A.vshim_lo, 0) end   -- dpytap band OFF throughout

  local rel = frame - fighting_frame
  if rel < 60 then return end

  -- 4-frame cycle per list: mask_a, mask_b, displace, measure+restore
  local phase = (rel - 60) % 5
  if li > #LISTS then finish(); return end
  local name, head = LISTS[li][1], LISTS[li][2]

  if phase == 0 then
    g_prev = grab()
  elseif phase == 1 then
    local g = grab()
    g_mask = diffset(g_prev, g)         -- what moves on its own
    g_prev = g
  elseif phase == 2 then
    saved = {}
    local objs = walk(head)
    for _, o in ipairs(objs) do
      saved[o] = r32(o + O.oxval)
      w32(o + O.oxval, (saved[o] + (SHIFT_PX << 16)) & 0xffffffff)
    end
    results[#results + 1] = string.format("%-26s %d objects", name, #objs)
  elseif phase == 3 then
    local g = grab()
    snap()
    local d = diffset(g_prev, g)
    for k in pairs(g_mask) do d[k] = nil end     -- drop self-animating pixels
    local x0, y0, x1, y1, n = bbox(d)
    if n then
      results[#results + 1] = string.format(
        "%-26s moved %d px, box x %d..%d y %d..%d | rows %s",
        "", n, x0, x1, y0, y1, rowset(d))
    else
      results[#results + 1] = string.format("%-26s moved NOTHING", "")
    end
    for o, v in pairs(saved) do w32(o + O.oxval, v) end
  elseif phase == 4 then
    li = li + 1
  end

  if frame > 20000 then log("ERROR timeout"); finish() end
end)
