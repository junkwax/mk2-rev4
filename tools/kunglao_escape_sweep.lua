-- kunglao_escape_sweep.lua - try Kung Lao's escape dive at several timings in ONE session.
--
-- do_hh_escape (src/MKHHESC.ASM) reads its timings from .bss knobs, so a config is just a
-- poke: no rebuild between tries. Each config is fired from the same spot, traced tick by
-- tick, and measured - launch/glide/roll ticks, how high the arch goes, how far he travels -
-- with a snapshot every other tick so the shape can be watched, not just read.
--
-- The art's own timing, for reference (HATHED12.IMG "X CAYP"): TMESCAPE1 and TMESCAPE2 one
-- tick each, TMESCAPE3 thirty-two, then the tuck frames one tick each.
--
-- Env:
--   KLS_CONFIGS  name:k=v,k=v;name:...   knobs in PIXELS per tick (lift is up-positive)
--                keys: rate roll rolltix drop xvel lift grav vcap rollspd
--   KLS_LOG      where the report goes        KLS_SNAP  snapshot dir ("" = none)
--   MK2_ROOT     tree holding src/mk2.map     KLS_SPACING  px from the opponent (default 170)
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("KLS_LOG") or (ROOT .. "/tools/kunglao_escape_sweep.log")
local SNAP_DIR = os.getenv("KLS_SNAP") or ""
local SPACING = tonumber(os.getenv("KLS_SPACING") or "170")

local fh = io.open(LOG_PATH, "w")
local function log(f, ...) local s = string.format(f, ...); fh:write(s .. "\n"); fh:flush(); print("[kls] " .. s) end

local symbols = {}
do
  local m = io.open(ROOT .. "/src/mk2.map", "r")
  if not m then log("no src/mk2.map under %s", ROOT); return end
  for line in m:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_]+)") do symbols[n] = symbols[n] or tonumber(a, 16) end
  end
  m:close()
end
local A = {}
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_bar", "p2_bar",
                     "p1_bar_view", "p2_bar_view", "p1_proc", "p2_proc", "ground_y", "f_freeze_timer",
                     "hhesc_kinit", "hhesc_v_rate", "hhesc_v_xvel", "hhesc_v_lift", "hhesc_v_grav",
                     "hhesc_v_vcap", "hhesc_v_drop", "hhesc_v_roll", "hhesc_v_rolltix", "hhesc_v_rollspd",
                     "hhesc_v_xdrag", "hhesc_v_xmin", "hhesc_v_rolldec", "hhesc_v_rollmin", "hhesc_v_rollcarry", "hhesc_v_tuck", "hhesc_v_corner", "left_edge" }) do
  A[n] = symbols[n]
  if not A[n] then log("missing symbol %s - is this the escape build?", n); return end
end

-- Kung Lao's frames are NOT in mk2.map (art labels are not global), so the pose is read the
-- way tools/kunglao_escape_test.lua reads it: SAG -> name out of src/MKHH.TBL.
local sag_name, marker_count = {}, 0
do
  local t = io.open(ROOT .. "/src/MKHH.TBL", "r")
  if not t then log("missing src/MKHH.TBL - cannot name poses"); return end
  local label
  for line in t:lines() do
    local l = line:match("^%s*(%u[%u%d_]*):")
    if l then label = l end
    local sag = label and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
    if sag then sag_name[tonumber(sag, 16) & 0x00ffffff] = label; marker_count = marker_count + 1; label = nil end
  end
  t:close()
end

local scr = manager.machine.screens[":screen"]
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local OIMG, OXVAL, OXPOS, OYPOS = 0x1a0, 0x80, 0x90, 0xb0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_HATHEAD, FT_JAX, MAX_HP = 0, 11, 0x00a1
local FIX = 65536                                   -- px/tick -> the game's 16.16
-- when, after takeoff, the Forward,Forward+LP goes in - swept, because one delay does
-- not catch every jump (the working rig sweeps the same way)
local DELAYS = { 3, 5, 1, 7, 2, 4, 6, 8 }

-- the configs
local CONFIGS = {}
for entry in (os.getenv("KLS_CONFIGS") or "stock:"):gmatch("[^;]+") do
  local name, kv = entry:match("^%s*([^:]+):(.*)$")
  if name then
    local c = { name = name }
    for k, v in (kv or ""):gmatch("(%w+)=(-?[%d%.]+)") do c[k] = tonumber(v) end
    CONFIGS[#CONFIGS + 1] = c
  end
end

local frame, held, cfg_i, phase, phase_at = 0, {}, 0, "boot", 0
local ground_h, fired_at, takeoff_at, motion_at, x0 = nil, nil, nil, nil, nil
local trace, peak_rise, land_at, glide_from, roll_at, last_pose = {}, 0, nil, nil, nil, nil
local results, tries = {}, 0
local hp0, hit_at = nil, nil
local last_gs, sel_at = -1, nil

local function p1o() return r32(A.p1_obj) end
local function p1x() return s16(r16(p1o() + OXPOS)) end
local function p2x() return s16(r16(r32(A.p2_obj) + OXPOS)) end
local function height() return s16(r16(A.ground_y)) - s16(r16(p1o() + OYPOS)) end
local MP_LEN = 0x70
local function pose()
  local o = p1o(); if o == 0 then return nil end
  local img = r32(o + OIMG); if img == 0 then return nil end
  for i = 0, 7 do
    local sag = r32(img + i * MP_LEN) & 0x00ffffff
    if sag == 0 then break end
    local n = sag_name[sag]
    if n then return n:match("^(%u+%d+)") or n end
  end
  return nil
end
local snaps, snap_err = 0, nil
local function snap(tag)
  if SNAP_DIR == "0" then return end
  -- manager.machine.video:snapshot() is the documented one; screen:snapshot() wrote nothing
  -- here (the folder was created and left empty), so try the video manager and say why if
  -- it fails rather than swallowing it in a pcall.
  local ok, err = pcall(function() manager.machine.video:snapshot() end)
  if ok then snaps = snaps + 1
  elseif not snap_err then snap_err = true; log("SNAPSHOT FAILED: %s", tostring(err)) end
end

-- the inputs, cached once
local fields = {}
local function cache_fields()
  local want = { ["Coin 1"] = true, ["1 Player Start"] = true, ["P1 High Punch"] = true,
                 ["P1 Low Punch"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
                 ["P1 Up"] = true, ["P1 Down"] = true }
  for _, port in pairs(manager.machine.ioport.ports) do
    for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
  end
  for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

-- knobs: defaults are laid down by the move itself the first time it runs, so a config only
-- writes what it names. hhesc_kinit is forced set so our pokes are never overwritten.
-- The move lays its own defaults down the first time it runs, but the rig pokes BEFORE that
-- and forcing hhesc_kinit would leave every knob at zero (measured: xvel 0, so the dive went
-- nowhere). So the rig carries the defaults - these are the .set values in src/MKHHESC.ASM -
-- and writes every knob for every config; a config only overrides what it names.
local DEF = { rate = 2, roll = 2, rolltix = 16, drop = 0x3f,          -- "heavy", 2026-10-10
              xvel = 8, lift = 7, grav = 1.3, vcap = 14, rollspd = 8,
              xdrag = 0, xmin = 0, rolldec = 0.5, rollmin = 2, rollcarry = 1, tuck = 2, corner = 128 }
local function apply(c)
  local v = {}
  for k, d in pairs(DEF) do v[k] = c[k] or d end
  w16(A.hhesc_kinit, 1)
  w16(A.hhesc_v_rate, v.rate)
  w16(A.hhesc_v_roll, v.roll)
  w16(A.hhesc_v_rolltix, v.rolltix)
  w16(A.hhesc_v_drop, v.drop)
  w32(A.hhesc_v_xvel, math.floor(v.xvel * FIX))
  w32(A.hhesc_v_lift, math.floor(-v.lift * FIX))          -- up is negative in oyvel
  w32(A.hhesc_v_grav, math.floor(v.grav * FIX))
  w32(A.hhesc_v_vcap, math.floor(v.vcap * FIX))
  w32(A.hhesc_v_rollspd, math.floor(v.rollspd * FIX))
  w32(A.hhesc_v_xdrag, math.floor(v.xdrag * FIX))
  w32(A.hhesc_v_xmin, math.floor(v.xmin * FIX))
  w32(A.hhesc_v_rolldec, math.floor(v.rolldec * FIX))
  w32(A.hhesc_v_rollmin, math.floor(v.rollmin * FIX))
  w16(A.hhesc_v_rollcarry, v.rollcarry)
  w16(A.hhesc_v_tuck, v.tuck)
  w16(A.hhesc_v_corner, v.corner)
  log("  ease: xdrag=%g xmin=%g rolldec=%g rollmin=%g", v.xdrag, v.xmin, v.rolldec, v.rollmin)
  log("  knobs: rate=%d roll=%d rolltix=%d drop=%d xvel=%g lift=%g grav=%g vcap=%g rollspd=%g",
      v.rate, v.roll, v.rolltix, v.drop, v.xvel, v.lift, v.grav, v.vcap, v.rollspd)
end

-- per-config trial shape: jb=1 back flip, jb=2 straight up (else forward);
-- cn=1 parks P1 against the LEFT wall with P2 SPACING px in front of him
local function place(sp)
  local o = p1o(); if o == 0 then return end
  local c = CONFIGS[cfg_i] or {}
  sp = c.sp or sp
  do
    local x1 = (s16(r16(A.left_edge)) + (c.cn == 1 and 20 or 300)) & 0xffff
    local o2 = r32(A.p2_obj)
    local x2 = (x1 + sp) & 0xffff
    w32(o + OXVAL, x1 << 16); w16(o + OXPOS, x1)
    w32(o2 + OXVAL, x2 << 16); w16(o2 + OXPOS, x2)
    return
  end
  local x = (p2x() - sp) & 0xffff
  w32(o + OXVAL, x << 16); w16(o + OXPOS, x)
end

local function drive_jump(start, delay)
  local rel = frame - start
  local jb = (CONFIGS[cfg_i] or {}).jb
  if rel >= 0 and rel < 6 then
    held["P1 Up"] = true
    if jb == 1 then held["P1 Left"] = true elseif jb ~= 2 then held["P1 Right"] = true end
  end
  if not takeoff_at and rel > 6 and (height() - ground_h) >= 0x10 then takeoff_at = frame end
  if takeoff_at and not motion_at and frame - takeoff_at >= delay then motion_at = frame end
  if motion_at then
    local m = frame - motion_at
    if m >= 0 and m < 3 then held["P1 Right"] = true end
    if m >= 5 and m < 8 then held["P1 Right"] = true end
    if m >= 9 and m < 14 then held["P1 Low Punch"] = true end
  end
end

local function begin(i)
  cfg_i, phase, phase_at, tries = i, "fire", frame, 0
  takeoff_at, motion_at, fired_at, hit_act_at = nil, nil, nil, nil
  try_snap0 = nil
  trace, peak_rise, land_at, glide_from, roll_at, last_pose = {}, 0, nil, nil, nil, nil
  apply(CONFIGS[i])
  place(SPACING)
  ground_h = height()
  local c = CONFIGS[i]
  log("=== config %d/%d  %s", i, #CONFIGS, c.name)
end

local function report()
  local c = CONFIGS[cfg_i]
  log("  SNAPRANGE %s %d %d", c.name, snap_first or 0, snaps - 1)
  local launch = glide_from and (glide_from - fired_at) or -1
  local glide = (land_at and glide_from) and (land_at - glide_from) or -1
  local roll = (roll_at and land_at) and (#trace - (roll_at - fired_at)) or -1
  local dist = trace[#trace] and math.abs(trace[#trace].x - x0) or -1
  log("  launch %d ticks | glide %d | air total %s | roll %s | rise %d px | travel %d px",
      launch, glide, tostring(land_at and land_at - fired_at or -1),
      tostring(roll_at and (#trace + fired_at - roll_at) or -1), peak_rise, dist)
  results[#results + 1] = string.format("%-14s launch=%-3d glide=%-3d air=%-3d rise=%-3d travel=%-4d hit=%s",
      c.name, launch, glide, land_at and land_at - fired_at or -1, peak_rise, dist,
      hit_at and ("t" .. hit_at) or "none")
end

local function step()
  frame = frame + 1
  for k in pairs(held) do held[k] = nil end

  if frame == 1 then cache_fields() end
  if frame % 300 == 0 then log("heartbeat frame %d gstate %d phase %s", frame, r16(A.gstate), phase) end

  local gs = r16(A.gstate)
  if gs ~= last_gs then log("frame %d: gstate %s -> %s", frame, tostring(last_gs), tostring(gs)); last_gs = gs end
  -- attract / buy-in / game over: keep feeding it, the way tools/flybrain_play.lua does.
  -- Fixed frame windows missed (attract does not start on a known frame); this cannot.
  if gs == 1 or gs == 3 or gs == 0xb or gs == 0xa then
    held["Coin 1"] = (frame % 90) < 10
    held["1 Player Start"] = (frame % 90) >= 45 and (frame % 90) < 55
    return
  end
  if gs == GS_PSEL then
    -- a PULSED low punch takes the pick (measured: gstate 4 -> 13 in 43 frames); holding
    -- high punch instead re-triggered and never left the grid
    w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX)
    if frame % 40 < 12 then held["P1 Low Punch"] = true end
    return
  end
  if gs == GS_POST then
    -- the tower/VS screen: let the GAME set the match up, do not keep writing over it
    if frame % 600 == 0 then log("frame %d: still on gstate 13, p1=%d p2=%d", frame, r16(A.p1_char), r16(A.p2_char)) end
    return
  end
  if gs ~= GS_FIGHTING then return end
  if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end          -- no round clock
  w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
  -- the OPPONENT's bar is only topped up when it is nearly gone: pinning it every frame hid
  -- every hit the dive landed, which is the thing being measured here
  if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end

  if phase == "boot" then
    begin(1)                                   -- the fight is up: start the first config
    return
  end

  local p = pose()
  local esc = p and p:sub(1, 8) == "TMESCAPE"
  local tuck = p and p:sub(1, 10) == "TMJUMPFLIP"

  if phase == "fire" then
    if esc then
      fired_at, x0, phase = frame, p1x(), "watch"
      snap_first = try_snap0 or snaps
      hp0, hit_at = r16(A.p2_bar), nil
      log("  fired at frame %d, height %d above standing", frame, height() - ground_h)
    elseif frame - phase_at > 120 then
      tries = tries + 1
      if tries > #DELAYS then
        log("  never fired - giving up on this config")
        results[#results + 1] = string.format("%-14s NEVER FIRED", CONFIGS[cfg_i].name)
        if cfg_i < #CONFIGS then begin(cfg_i + 1) else
          log("---- sweep done ----")
          for _, r in ipairs(results) do log("%s", r) end
          phase = "done"
        end
        return
      end
      takeoff_at, motion_at, phase_at = nil, nil, frame
      try_snap0 = nil
      place(SPACING)
      log("  retry %d (delay %d)", tries, DELAYS[(tries % #DELAYS) + 1])
    else
      drive_jump(phase_at, DELAYS[(tries % #DELAYS) + 1])
      -- film from the jump: the first frame Up goes in, so the take-off shows
      try_snap0 = try_snap0 or snaps
      snap("pre")
    end
    return
  end

  if phase == "watch" then
    local t = frame - fired_at
    local h = height() - ground_h
    trace[#trace + 1] = { t = t, x = p1x(), h = h, pose = p }
    if h > peak_rise then peak_rise = h end
    if not hit_at and hp0 and r16(A.p2_bar) < hp0 then
      hit_at = t
      log("    HIT the opponent at t%d (%s, his bar %d -> %d)", t, tostring(p), hp0, r16(A.p2_bar))
      hit_act_at = frame
    end
    if hit_act_at and (frame - hit_act_at) % 4 == 0 and frame - hit_act_at <= 24 then
      local q = r32(A.p2_proc)
      log("    victim t+%d: p_action %04x  h=%d", frame - hit_act_at, r16(q + 0x1f0),
          s16(r16(A.ground_y)) - s16(r16(r32(A.p2_obj) + OYPOS)))
    end
    if t <= 50 or p ~= last_pose then
      local o = p1o()
      log("    t%-3d %-12s h=%-4d x=%-5d xvel=%+.1f", t, tostring(p), h, p1x(),
          (function(v) return (v >= 0x80000000 and v - 0x100000000 or v) / FIX end)(r32(o + 0x40)))
      if p == "TMESCAPE3" and not glide_from then glide_from = frame end
      if tuck and not roll_at then roll_at = frame; land_at = land_at or frame end
      last_pose = p
    end
    if t <= 90 then snap(string.format("%s_t%03d", CONFIGS[cfg_i].name, t)) end
    if not esc and not tuck and t > 10 and not end_t then end_t = t end
    if (end_t and t > end_t + 16) or t > 160 then
      end_t = nil
      report()
      if cfg_i < #CONFIGS then begin(cfg_i + 1) else
        log("---- sweep done ----")
        for _, r in ipairs(results) do log("%s", r) end
        phase = "done"
      end
    end
    return
  end
end

-- ONE callback: decide the keys, then apply them. Two callbacks meant the applier ran before
-- the decider and every press was a frame stale - the coin never registered and the rig sat
-- in attract for ever.
-- KEEP THE HANDLE in a global: an unkept notifier is collected at the first GC and
-- stops firing (this rig died at frame 300 every run until it was held).
KLS_HANDLE = emu.add_machine_frame_notifier(function()
  local ok, err = pcall(step)
  if not ok and not reported_err then reported_err = true; log("LUA ERROR: %s", tostring(err)) end
  local ok2, err2 = pcall(function()
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
  end)
  if not ok2 and not reported_err2 then reported_err2 = true; log("INPUT ERROR: %s", tostring(err2)) end
end)
