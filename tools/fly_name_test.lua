-- fly_name_test.lua - the fruit fly's name plate (flyname, MAINEQU.ASM).
--
-- Forces Liu Kang (P1, joystick) vs Jax (P2, drone) at the Dead Pool, then
-- holds fly_player = FN_FLY (0, 1 or 2) from character select on, and
-- snapshots the fight.  It HAS to be set before the round: the name plates are
-- queued once, by setup_score_ram (murder_myoinit_score, every round start), so
-- a poke mid-fight changes nothing until the next round.  Run once per value:
--   0 -> LIU KANG / JAX     1 -> FRUIT plate on P1     2 -> FRUIT plate on P2
-- The plates are compared by eye from the snapshot; the log proves the symbol
-- resolved, the value held and nothing locked up.
--
-- Env: FN_MAP (mk2.map matching the ROM), FN_LOG, FN_READY (flag file written
-- once frames run, for mame_dismiss_warning.ps1).

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP = (os.getenv("FN_MAP") or (ROOT .. "/src/mk2.map")):gsub("\\", "/")
local LOG = (os.getenv("FN_LOG") or "C:/tmp/flybrain/fly_name_test.log"):gsub("\\", "/")
local READY = os.getenv("FN_READY")
local FLY = tonumber(os.getenv("FN_FLY") or "2")

local fh = io.open(LOG, "w")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[flyname] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local sym = {}
for line in io.lines(MAP) do
  for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
local need = { "gstate", "p1_state", "p2_state", "p1_char", "p2_char", "curback",
               "p1_bar", "p2_bar", "winner_status", "fly_player", "system_lockup" }
local missing = {}
for _, n in ipairs(need) do if not sym[n] then missing[#missing + 1] = n end end
log("map %s", MAP)
if #missing > 0 then log("ERROR unresolved symbols: %s", table.concat(missing, ",")) end

local GS_PSEL, GS_FIGHTING = 4, 2
local cpu, space, fields = nil, nil, {}
local frame, charsel, fight, confirm = 0, 0, 0, 0
local done = false

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function snap(tag)
  local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
  if ok and s then pcall(function() s:snapshot() end) end
  log("SNAP %s frame=%d fly_player=%d", tag, frame, r16(sym.fly_player))
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, f in pairs(port.fields) do fields[f.name] = f end
    end
  end
  if READY and frame == 120 then local r = io.open(READY, "w"); if r then r:write("ok"); r:close() end end
  if done or #missing > 0 then
    if frame == 2 then manager.machine:exit() end
    return
  end

  local gs = r16(sym.gstate)
  if gs == GS_PSEL and charsel == 0 then charsel = frame; log("select frame=%d", frame) end
  if gs == GS_FIGHTING and charsel > 0 and fight == 0 then fight = frame; log("fight frame=%d", frame) end

  local press = {}
  if charsel == 0 then
    press["UI Select"] = frame >= 5 and frame < 35
    press["Coin 1"] = frame >= 200 and (frame % 80) < 20
    press["1 Player Start"] = frame >= 1000 and (frame % 120) < 30
  elseif fight == 0 then
    w16(sym.p1_state, 1); w16(sym.p2_state, 0)
    w16(sym.p1_char, 1); w16(sym.p2_char, 11); w16(sym.curback, 0)
    w16(sym.fly_player, FLY)
    if confirm == 0 and frame - charsel > 90 then confirm = frame end
    press["P1 High Punch"] = confirm > 0 and frame >= confirm and frame < confirm + 45
  else
    w16(sym.p1_bar, 0xA1); w16(sym.p2_bar, 0xA1); w16(sym.winner_status, 0)
  end
  for _, n in ipairs({ "UI Select", "Coin 1", "1 Player Start", "P1 High Punch" }) do
    if fields[n] then fields[n]:set_value(press[n] and 1 or 0) end
  end

  if frame > 20000 and fight == 0 then log("ERROR no fight by frame %d (gstate=%d)", frame, gs); done = true; manager.machine:exit() end
  if fight == 0 then return end

  local rel = frame - fight
  if rel == 240 then
    snap("fly" .. FLY)
    local ok = gs == GS_FIGHTING and r16(sym.fly_player) == FLY and r16(sym.p1_char) == 1 and r16(sym.p2_char) == 11
    log("%s fly=%d gstate=%d p1_char=%d p2_char=%d", ok and "PASS" or "FAIL", FLY, gs, r16(sym.p1_char), r16(sym.p2_char))
    done = true
    manager.machine:exit()
  end
end)
