-- mk1_throne_capture.lua
--
-- MK1 (MAME `mk`, rev 5.0 T-unit): play a 1P game on THE THRONE ROOM and
-- snapshot it - the reference for MK2's import (tools/make_mk1throne.py,
-- doc/MK1_THRONE_ROOM.md).  Launch with tools/run_mk1_throne_capture.ps1.
--
-- Addresses (tools/mk1_pit_capture.lua; plane mapping in make_mk1throne.py):
--   @1051190  gstate (16-bit)   4 select, 2 fight, 5 round over
--   @1051820  curback (16-bit)  4 = THE THRONE ROOM (FFCB8080)
--   @104F650  worldtly (16.16)
--   @104F870  worldtlx of MK1 plane 1 (the floor lip), @104F850 plane 2 (the
--             frieze), @104F830 plane 3 (the columns, 01A000h - slower)
--
-- WHAT IT WRITES (MK1T_OUT)
--   start_NNN.png   the first frames of round one: both fighters in their
--                   stance at the start camera
--   right_NNN.png   P1 walked to the right scroll limit
--   left_NNN.png    ...and back to the left one
--   capture.log     camera per plane at every shot

local OUT = (os.getenv("MK1T_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end

local log = io.open(OUT .. "capture.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"), right = fld(":IN0", "P1 Right"),
  left = fld(":IN0", "P1 Left"),
}
local function r16(a) return mem:read_u16(a) end
local function r32(a) return mem:read_u32(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

local A = { gstate = 0x01051190, curback = 0x01051820, p1hp = 0x01051300, p2hp = 0x010515E0,
            wty = 0x0104F650 }
-- MK1 plane e's worldtlx is 0104F890h - 32e (make_mk1shrine.PLANE_WORLDTLX0)
local PLANEX = {}
for e = 0, 8 do PLANEX[e] = 0x0104F890 - 32 * e end
local GS_SELECT, GS_FIGHT = 4, 2
local THRONE = 4

local n, sel0, fight0 = 0, nil, nil
local function press(f, on) f:set_value(on and 1 or 0) end
local function cam()
  local t = { string.format("wty %d", r32(A.wty) >> 16) }
  for e = 0, 8 do t[#t + 1] = string.format("x%d %d", e, r32(PLANEX[e]) >> 16) end
  return table.concat(t, " ")
end
local function shot(name)
  scr:snapshot(name .. ".png")
  L("%s  %s", name, cam())
end

emu.register_frame_done(function()
  n = n + 1
  local gs = r16(A.gstate)
  local k = (n - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and n >= 600)
  press(F.coin, in_menus and n >= 1000 and (k < 6 or (k >= 30 and k < 36)))
  press(F.start, in_menus and n >= 1000 and k >= 120 and k < 126)
  if gs == GS_SELECT and not sel0 then sel0 = n; L("f%d select screen", n) end
  local confirm = sel0 and n >= sel0 + 300 and n < sel0 + 306
  if sel0 and gs ~= GS_FIGHT and not fight0 then w16(A.curback, THRONE) end
  press(F.hp, (n >= 600 and n < 606) or confirm)

  if gs == GS_FIGHT and not fight0 then
    fight0 = n
    L("f%d FIGHT on curback %d", n, r16(A.curback))
  end
  if not fight0 then
    if n > 30000 then L("ERROR - never reached the fight"); log:close(); manager.machine:exit() end
    return
  end

  w16(A.p1hp, 0xA1); w16(A.p2hp, 0xA1)
  local rel = n - fight0
  press(F.right, rel >= 120 and rel < 900)
  press(F.left, rel >= 1000 and rel < 2200)
  if rel == 2 or rel == 10 or rel == 40 then shot(string.format("start_%03d", rel)) end
  if rel == 880 or rel == 890 then shot(string.format("right_%03d", rel)) end
  if rel == 2180 or rel == 2190 then shot(string.format("left_%03d", rel)) end
  if rel % 60 == 0 then L("rel %d gs %d %s", rel, gs, cam()) end
  if rel >= 2200 then L("PASS"); log:close(); manager.machine:exit() end
end)
