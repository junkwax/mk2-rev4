-- sweep_addon_scope.lua - chase level_out_of_scope on The Portal.
--
-- The stock sweep reports `worldtlx=0 bounds=[128,816]` once, deep into a
-- fuzzed round-ending run.  That line does not say which of the two moved:
-- the camera could have been dragged 128px left of the level, or the level's
-- own scroll limits could have been rewritten under a camera that was fine.
--
-- So: log a window around every excursion, and record how long it lasts.  A
-- one-frame straddle during a round restart is a different problem from a
-- camera parked outside the level for a second.
--
-- Rename to sweep_addon.lua to arm it.  Reuses the harness's random P1 input
-- from sweep_addon_fuzz.lua so the same seeds reproduce.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LABEL = os.getenv("SWEEP_LABEL") or "battle"
local SEED = tonumber(os.getenv("FUZZ_SEED") or "1")
local HOLD = tonumber(os.getenv("FUZZ_HOLD") or "6")
local OUT = ROOT .. "/tools/scope_watch.txt"
local MARGIN = 12

local sym = {}
do
  local fh = io.open(ROOT .. "/src/mk2.map", "r")
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
    end
    fh:close()
  end
end
local S = function(n) return sym[n] end
local gstate, worldtlx = S("gstate"), S("worldtlx")
local left_edge, right_edge = S("left_edge"), S("right_edge")
local curback, winner_status = S("curback"), S("winner_status")
local scrollx, worldtly = S("scrollx"), S("worldtly")
local p1_obj, p2_obj, p1_bar, p2_bar = S("p1_obj"), S("p2_obj"), S("p1_bar"), S("p2_bar")
local p1_wins, p2_wins = S("p1_wins"), S("p2_wins")
if not (gstate and worldtlx and left_edge) then print("[scope] symbols missing"); return end

local OWNS = _G.ADDON_OWNS or {}
local logf = io.open(OUT, "a")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[scope] " .. l)
  if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local fields, names = {}, {}
local held = {}
local ring, RING = {}, 24          -- rolling history, printed on the first hit
local excursions, cur = 0, nil
local last_gs, shot_at = -1, nil

local st = (SEED * 1103515245 + 12345) & 0x7fffffff
local function rnd(n)
  st = (st * 1103515245 + 12345) & 0x7fffffff
  return (st >> 16) % n
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end return v end

local function sample()
  local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
  return {
    wx = s16(space:read_u32(worldtlx) >> 16),
    wxraw = s32(space:read_u32(worldtlx)),
    le = s16(space:read_u16(left_edge)),
    re = s16(space:read_u16(right_edge)),
    gs = space:read_u16(gstate),
    cb = curback and space:read_u16(curback) or -1,
    ws = winner_status and space:read_u16(winner_status) or -1,
    sx = scrollx and s32(space:read_u32(scrollx)) or 0,
    wy = worldtly and s32(space:read_u32(worldtly)) or 0,
    x1 = o1 ~= 0 and s16(space:read_u16(o1 + 0x090)) or -1,
    x2 = o2 ~= 0 and s16(space:read_u16(o2 + 0x090)) or -1,
    h1 = space:read_u16(p1_bar), h2 = space:read_u16(p2_bar),
    w1 = p1_wins and space:read_u16(p1_wins) or -1,
    w2 = p2_wins and space:read_u16(p2_wins) or -1,
  }
end

local function fmt(rel, s)
  return string.format(
    "rel=%-5d wx=%-5d (raw %08x) bounds=[%d,%d] gs=%d cb=%d win=%d wins=%d/%d scrollx=%d wy=%d x1=%d x2=%d hp=%d/%d",
    rel, s.wx, s.wxraw & 0xffffffff, s.le, s.re, s.gs, s.cb, s.ws, s.w1, s.w2,
    s.sx, s.wy >> 16, s.x1, s.x2, s.h1, s.h2)
end

emu.register_frame(function()
  frame = frame + 1
  if not space then
    local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
    if not ok or not space then return end
  end
  if next(fields) == nil then
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, fd in pairs(port.fields) do
        if fd.name:sub(1, 3) == "P1 " then
          fields[fd.name] = fd; names[#names + 1] = fd.name; OWNS[fd.name] = true
        end
      end
    end
    log("=== %s seed=%d", LABEL, SEED)
  end
  -- DELIBERATELY NOT GATED ON gstate==2.  The harness's own check_scope is
  -- not either: fighting_frame is set once and never cleared, so it keeps
  -- testing the camera against the level's scroll limits after the round is
  -- over.  Gating here hid the excursion completely on the first run.
  local gs_now = space:read_u16(gstate)
  if fight0 == 0 then
    if gs_now ~= 2 then return end
    fight0 = frame
  end
  local rel = frame - fight0

  local s = sample()
  ring[#ring + 1] = { rel = rel, s = s }
  if #ring > RING then table.remove(ring, 1) end

  -- gstate transitions, and a picture a beat after each one.  An excursion
  -- that is really a torn-down stage has to be followed by the game arriving
  -- somewhere sane; a black screen on its own proves nothing either way.
  if s.gs ~= last_gs then
    log("GSTATE %s rel=%d %d -> %d (cb=%d wx=%d bounds=[%d,%d])",
        LABEL, rel, last_gs, s.gs, s.cb, s.wx, s.le, s.re)
    last_gs = s.gs
    shot_at = rel + 90
  end
  if shot_at and rel == shot_at then
    shot_at = nil
    local sc = manager.machine.screens[":screen"]
    if sc then pcall(function() sc:snapshot() end) end
    log("  SHOT %s rel=%d gs=%d", LABEL, rel, s.gs)
  end

  local bad = s.wx < s.le - MARGIN or s.wx > s.re + MARGIN
  if bad and not cur then
    excursions = excursions + 1
    cur = { first = rel, n = 0, worst = s.wx }
    if excursions <= 3 then
      log("--- excursion %d begins ---", excursions)
      for _, e in ipairs(ring) do log("    %s", fmt(e.rel, e.s)) end
    end
  end
  if bad then
    cur.n = cur.n + 1
    if s.wx < cur.worst then cur.worst = s.wx end
    if excursions <= 3 and cur.n <= 8 then log("  BAD %s", fmt(rel, s)) end
  elseif cur then
    if excursions <= 3 then log("  recovered %s", fmt(rel, s)) end
    log("EXCURSION %s #%d: rel %d..%d (%d frames), worst wx=%d, bounds=[%d,%d]",
        LABEL, excursions, cur.first, rel - 1, cur.n, cur.worst, s.le, s.re)
    cur = nil
  end

  if rel < 45 or gs_now ~= 2 then return end
  if rel % HOLD == 0 then
    held = {}
    local dirs = { "P1 Left", "P1 Right", "P1 Up", "P1 Down" }
    local d = rnd(6)
    if d < 4 then held[dirs[d + 1]] = true end
    for _, b in ipairs({ "P1 High Punch", "P1 Low Punch", "P1 High Kick",
                         "P1 Low Kick", "P1 Block" }) do
      if rnd(5) == 0 then held[b] = true end
    end
  end
  for n, fd in pairs(fields) do fd:set_value(held[n] and 1 or 0) end
end)
