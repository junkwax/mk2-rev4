-- shimmer_gone_check.lua
--
-- Confirms the Kahn's Arena heat shimmer is genuinely gone from the ROM.
--
-- The strong assertion is not "the picture looks right" - it is that dpytap,
-- the register the whole effect was built on, never changes from the value
-- MKINIT.ASM installs at boot.  If it holds 56/2 for a whole fight on the
-- arena, nothing is banding the raster, whatever the screen looks like.
--
-- Also checks the vshim symbols are absent from mk2.map, which is what
-- vshim .set 0 should produce.
--
-- Env: GONE_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("GONE_LOG") or (ROOT .. "/tools/shimmer_gone_check.log")

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[gone] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
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
  gstate = sym("gstate", 0), curback = sym("curback", 0),
  p1_char = sym("p1_char", 0), p2_char = sym("p2_char", 0),
  p1_state = sym("p1_state", 0), p2_state = sym("p2_state", 0),
  p1_bar = sym("p1_bar", 0), p2_bar = sym("p2_bar", 0),
  map_position = sym("map_position", 0), battle_num = sym("battle_num", 0),
  winner_status = sym("winner_status", 0), f_freeze_timer = sym("f_freeze_timer", 0),
}

local R_DPYTAP = 0xc00001b0
local TAP_BOOT = 56 // 2
local ARENA, GS_PSEL, GS_FIGHTING = 8, 4, 2

local space, fields = nil, {}
local frame, charsel_frame, fighting_frame, p1_confirm = 0, 0, 0, 0
local done, seen, bad, worst = false, 0, 0, nil

local function r16(a) return space:read_u16(a) & 0xffff end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function finish()
  if done then return end
  done = true
  local fails = {}
  for _, n in ipairs({ "vshim_lo", "vshim_wave", "arena_heat_proc", "vsplit_hist" }) do
    if symbols[n] then fails[#fails + 1] = n .. " is still linked - vshim did not compile out" end
  end
  if seen < 200 then fails[#fails + 1] = "never observed enough fight frames on the arena" end
  if bad > 0 then
    fails[#fails + 1] = string.format(
      "dpytap moved off its boot value on %d of %d frames (saw %s)", bad, seen, tostring(worst))
  end
  log("observed %d fight frames on Kahn's Arena; dpytap held %d throughout on %d of them",
      seen, TAP_BOOT, seen - bad)
  if #fails == 0 then
    log("PASS: no vshim symbols linked, and dpytap never moves - the shimmer is gone")
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
    log("---- is the shimmer gone? ----")
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
    log("fight at frame %d, curback=%d, dpytap=%d", frame, r16(A.curback), r16(R_DPYTAP))
  end
  if fighting_frame == 0 then
    if frame > 6000 then log("ERROR never reached a fight"); finish() end
    return
  end

  w16(A.p1_bar, 161); w16(A.p2_bar, 161)
  if A.winner_status ~= 0 then w16(A.winner_status, 0) end
  if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

  if r16(A.curback) == ARENA then
    seen = seen + 1
    local tap = r16(R_DPYTAP)
    if tap ~= TAP_BOOT then bad = bad + 1; if worst == nil then worst = tap end end
    if seen == 60 then
      local scr = manager.machine.screens[":screen"]
      if scr then pcall(function() scr:snapshot() end) end
    end
  end

  if seen >= 400 then finish() end
  if frame > 20000 then log("ERROR timeout"); finish() end
end)
