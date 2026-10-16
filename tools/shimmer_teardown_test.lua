-- shimmer_teardown_test.lua
--
-- The Kahn's Arena sky shimmer holds a DISPLAY REGISTER, dpytap, at a value
-- that is only correct for the scanlines it is aimed at.  If it survives the
-- stage that armed it, the next screen gets a horizontal shift across part of
-- itself with nothing on screen to explain it - and it would be blamed on
-- whatever screen it showed up in, not on the arena.
--
-- arena_heat_proc is supposed to make that impossible without anyone having
-- to remember a teardown: it refreshes vshim_ttl every tick, vsplit_reset
-- counts it down, and when the background processes die the band puts dpytap
-- back and clears vshim_lo on its own.
--
-- The judgement is gated on curback, NOT on gstate.  Between rounds the game
-- leaves the fighting state with the arena still loaded and the process still
-- alive, and the band SHOULD still be armed there; flagging that would be
-- wrong.  What must be true is: whenever the current background is not the
-- arena, the band is off and dpytap is back at its boot value.
--
-- PASS = armed on the arena, and off on every frame of every other background
-- FAIL = anything else, including never getting off the arena (proves nothing)
--
-- Env: SHIM_LOG, SHIM_WATCH (frames to watch after the match ends)

local ROOT  = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG   = os.getenv("SHIM_LOG") or (ROOT .. "/tools/shimmer_teardown_test.log")
local WATCH = tonumber(os.getenv("SHIM_WATCH") or "2400")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[tear] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  p1_char = sym("p1_char"), p2_char = sym("p2_char"),
  p1_state = sym("p1_state"), p2_state = sym("p2_state"),
  p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
  map_position = sym("map_position", 0), battle_num = sym("battle_num", 0),
  vshim_lo = sym("vshim_lo"), vshim_base = sym("vshim_base"),
  vshim_ttl = sym("vshim_ttl"), vshim_wr = sym("vshim_wr"),
}

local R_DPYTAP = 0xc00001b0
local TAP_BOOT = 56 // 2
local ARENA, GS_PSEL, GS_FIGHTING = 8, 4, 2

local space, fields = nil, {}
local frame, charsel_frame, fighting_frame, p1_confirm = 0, 0, 0, 0
local match_over, done = 0, false
local was_armed = false
local off_arena_frames, bad_tap, bad_lo = 0, 0, 0
local worst_tap, worst_ctx = nil, nil
local backs_seen = {}

local function r16(a) return space:read_u16(a) & 0xffff end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function finish()
  if done then return end
  done = true
  local list = {}
  for b in pairs(backs_seen) do list[#list + 1] = b end
  table.sort(list)
  log("backgrounds seen: %s", table.concat(list, ","))
  log("frames observed on a background other than the arena: %d", off_arena_frames)
  local fails = {}
  if not was_armed then
    fails[#fails + 1] = "the band never armed on Kahn's Arena - this run proves nothing"
  end
  if off_arena_frames < 60 then
    fails[#fails + 1] = string.format(
      "only %d frames off the arena - never got far enough to test the teardown",
      off_arena_frames)
  end
  if bad_tap > 0 then
    fails[#fails + 1] = string.format(
      "dpytap held %s off the arena on %d frames (%s); boot value is %d",
      tostring(worst_tap), bad_tap, tostring(worst_ctx), TAP_BOOT)
  end
  if bad_lo > 0 then
    fails[#fails + 1] = string.format("vshim_lo stayed armed off the arena on %d frames", bad_lo)
  end
  if #fails == 0 then
    log("PASS: armed on the arena, and dpytap back at %d with vshim_lo 0 on every other background",
        TAP_BOOT)
  else
    for _, f in ipairs(fails) do log("FAIL %s", f) end
  end
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
    log("---- sky shimmer teardown ----")
  end
  if not space then return end
  for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end

  local gs = r16(A.gstate)
  if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
  if charsel_frame > 0 and fighting_frame == 0 then
    w16(A.p1_state, 1); w16(A.p2_state, 0)
    w16(A.p1_char, 1); w16(A.p2_char, 11)
    w16(A.curback, ARENA)
    if A.map_position ~= 0 then w16(A.map_position, ARENA) end
    if A.battle_num ~= 0 then w16(A.battle_num, 1) end
    if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
  end
  if gs == GS_FIGHTING and fighting_frame == 0 then
    fighting_frame = frame
    log("fight at frame %d, curback=%d", frame, r16(A.curback))
  end
  if fighting_frame == 0 then
    if frame > 6000 then log("ERROR never reached fight"); finish() end
    return
  end

  local rel = frame - fighting_frame
  local back = r16(A.curback)
  backs_seen[back] = true

  if gs == GS_FIGHTING and back == ARENA then
    if rel > 40 and not was_armed and r16(A.vshim_lo) ~= 0 then
      was_armed = true
      log("armed at rel=%d: lo=%d ttl=%d base=%d dpytap=%d",
          rel, r16(A.vshim_lo), r16(A.vshim_ttl), r16(A.vshim_base), r16(R_DPYTAP))
    end
    -- lose on purpose so the match ends and the stage unloads
    if rel > 60 then w16(A.p1_bar, 0) end
  end

  -- The only judgement that matters: off the arena, the band must be gone.
  if was_armed and back ~= ARENA then
    if off_arena_frames == 0 then
      log("left the arena at frame %d (curback=%d gstate=%d): lo=%d ttl=%d dpytap=%d",
          frame, back, gs, r16(A.vshim_lo), r16(A.vshim_ttl), r16(R_DPYTAP))
      match_over = frame
    end
    off_arena_frames = off_arena_frames + 1
    -- allow the heartbeat its two ticks to lapse on the very first frames
    if off_arena_frames > 6 then
      local tap, lo = r16(R_DPYTAP), r16(A.vshim_lo)
      if tap ~= TAP_BOOT then
        bad_tap = bad_tap + 1
        if worst_tap == nil then
          worst_tap = tap
          worst_ctx = string.format("first at frame %d, curback=%d gstate=%d", frame, back, gs)
        end
      end
      if lo ~= 0 then bad_lo = bad_lo + 1 end
    end
  end

  if match_over > 0 and frame - match_over >= WATCH then finish() end
  if frame > 40000 then log("ERROR timeout"); finish() end
end)
