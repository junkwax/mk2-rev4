-- backplane_hide.lua
--
-- Does the back plane (baklst7) draw the dragon medallion, or is the
-- medallion a separate sprite sitting on top of it?
--
-- Every attempt to answer this by DISPLACING the plane and diffing frames was
-- contaminated: Kahn idles, the camera scrolls, and the dragon logo is itself
-- an animated flaming sprite, so a diff blames the effect for motion it did
-- not cause.  Correlating a 24 px shift out of that noise is hopeless.
--
-- HIDING is not.  b_inviso (bit 5 of oflags2, DISPEQU.ASM:138) makes dclipl
-- skip the object entirely.  A thing is either on screen or it is not, and no
-- amount of animation can fake its absence.  So: screenshot the stage, hide
-- every block of baklst7, screenshot again.  Whatever vanished IS the back
-- plane - exactly and completely.
--
-- Then hide them one at a time to attribute individual blocks.
--
-- Env: HIDE_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("HIDE_LOG") or (ROOT .. "/tools/backplane_hide.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[hide] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  baklst7 = sym("baklst7"),
}

local O = { link = 0, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, osize = 0x120 }
local SHOVE = 60          -- big enough that no animation can mimic it
local GS_FIGHTING = 2

local space, frame, ff, done = nil, 0, 0, false
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
-- b_inviso is NOT usable here: dclipl tests it inside the b_multipart branch
-- (MKDISP.ASM), so a single-part background block never looks at it.  Shove
-- the block instead - 60 px is unmistakable and animation cannot fake it.
local saved = {}
local function hide(o)
  if saved[o] == nil then saved[o] = r32(o + O.oxval) end
  w32(o + O.oxval, (saved[o] + (SHOVE << 16)) & 0xffffffff)
end
local function show(o)
  if saved[o] then w32(o + O.oxval, saved[o]) end
end

local function snap()
  local scr = manager.machine.screens[":screen"]
  if scr then pcall(function() scr:snapshot() end) end
end

local objs, step, cur = nil, 0, 0
local results = {}

local function finish()
  if done then return end
  done = true
  if objs then for _, o in ipairs(objs) do show(o) end end
  for _, r in ipairs(results) do log("%s", r) end
  log("snapshots: 0000 = stage as-is, 0001 = ALL of baklst7 shoved 60px,")
  log("           0002.. = one block shoved at a time, in the order listed above")
  manager.machine:exit()
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    log("---- shove the back plane, 60px, held ----")
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

  if rel == 80 then
    objs = walk(A.baklst7)
    results[#results + 1] = string.format("baklst7 holds %d blocks:", #objs)
    for i, o in ipairs(objs) do
      local sz = r32(o + O.osize)
      local h, w = (sz >> 16) & 0xffff, sz & 0xffff
      results[#results + 1] = string.format(
        "  block %2d  screen x %4d..%4d  y %3d..%3d",
        i, s16(r16(o + O.oxpos)) - 400, s16(r16(o + O.oxpos)) - 400 + w - 1,
        s16(r16(o + O.oypos)), s16(r16(o + O.oypos)) + h - 1)
    end
    snap()                                   -- 0000: as-is
    return
  end

  -- 0001: everything in the back plane hidden
  if rel == 84 then for _, o in ipairs(objs) do hide(o) end; return end
  if rel == 88 then snap(); return end
  if rel == 92 then for _, o in ipairs(objs) do show(o) end; return end

  -- then one block at a time
  local base = 96
  if rel < base then return end
  local phase = (rel - base) % 6
  cur = (rel - base) // 6 + 1
  if cur > #objs then finish(); return end
  if phase == 0 then hide(objs[cur])
  elseif phase == 3 then snap()
  elseif phase == 4 then show(objs[cur]) end

  if frame > 20000 then log("ERROR timeout"); finish() end
end)
