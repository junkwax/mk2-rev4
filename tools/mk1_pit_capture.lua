-- mk1_pit_capture.lua
--
-- MK1 (MAME `mk`, rev 5.0 T-unit): play a 1P game on THE PIT, win two rounds,
-- uppercut the opponent during FINISH HIM and record the stage fatality - the
-- reference for MK2's MK1 PIT import (tools/make_mk1pit.py, doc/MK1_PIT_STAGE.md).
-- Launch with tools/run_mk1_pit_capture.ps1.
--
-- Addresses (all from the disassembly, see mk1_shang_defeat_capture.lua):
--   @1051190  gstate (16-bit)   1 attract, 4 select, 7 tower, 6 pre-fight, 2 fight
--   @1051820  curback (16-bit)  table_o_mods at FFCA7E30; 3 = THE PIT (FFCB8690)
--   @1051300 / @10515E0   P1 / P2 health (max 0A1h)
--   @104F650  worldtly (32-bit, 16.16), @104F7A0 worldtlx (32-bit)
--
-- WHAT IT WRITES (MK1P_OUT)
--   stage_NNNNN.png   a few frames of the fight, to see the stage as MK1 draws it
--   fat_NNNNN.png     every 2nd frame from the second knockout (FINISH HIM) onwards
--   capture.log       gstate / curback / camera every 30 frames

local OUT = (os.getenv("MK1P_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local CAP_FRAMES = tonumber(os.getenv("MK1P_FRAMES") or "1400")

local log = io.open(OUT .. "capture.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"), right = fld(":IN0", "P1 Right"),
  down = fld(":IN0", "P1 Down"),
}
local function r16(a) return mem:read_u16(a) end
local function r32(a) return mem:read_u32(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

local A = { gstate = 0x01051190, curback = 0x01051820, p1hp = 0x01051300, p2hp = 0x010515E0,
            wty = 0x0104F650, wtx = 0x0104F7A0 }
local GS_SELECT, GS_FIGHT, GS_ROUNDOVER = 4, 2, 5
local PIT = 3

local n, sel0, rounds, lastgs, cap0, shots = 0, nil, 0, 0, nil, 0
local function press(f, on) f:set_value(on and 1 or 0) end

emu.register_frame_done(function()
  n = n + 1
  local gs = r16(A.gstate)

  local k = (n - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and n >= 600)
  press(F.coin, in_menus and n >= 1000 and (k < 6 or (k >= 30 and k < 36)))
  press(F.start, in_menus and n >= 1000 and k >= 120 and k < 126)
  if gs == GS_SELECT and not sel0 then sel0 = n; L("f%d select screen", n) end
  local confirm = sel0 and n >= sel0 + 300 and n < sel0 + 306

  -- the stage: hold curback on THE PIT until the fight is running
  if sel0 and gs ~= GS_FIGHT and rounds == 0 then w16(A.curback, PIT) end

  -- walk in and uppercut, forever.  An uppercut ends a round at 1 HP, and in
  -- FINISH HIM on the Pit it IS the stage fatality.
  local fighting = (gs == GS_FIGHT)
  local finish = fighting and rounds == 1 and r16(A.p2hp) == 0
  if finish and not cap0 then cap0 = n; L("f%d FINISH HIM - capturing", n) end
  if cap0 then
    -- one clean uppercut: let the banner arm, close in, crouch, then HP.  An
    -- uppercut thrown into the knockout stagger is a plain knockdown.
    local rel = n - cap0
    press(F.right, rel >= 40 and rel < 70)
    press(F.down, rel >= 74 and rel < 96)
    press(F.hp, rel >= 82 and rel < 85)
  else
    local t = n % 40
    press(F.right, fighting and t < 24)
    press(F.down, fighting and t >= 26 and t < 36)
    press(F.hp, (n >= 600 and n < 606) or confirm or (fighting and t >= 29 and t < 32))
  end

  if fighting then
    w16(A.p1hp, 0xA1)
    if rounds < 2 and r16(A.p2hp) > 1 then w16(A.p2hp, 1) end
    if shots < 4 and rounds == 0 and n % 90 == 0 then
      shots = shots + 1
      scr:snapshot(string.format("stage_%05d.png", n))
    end
  end

  if gs == GS_ROUNDOVER and lastgs ~= GS_ROUNDOVER then
    rounds = rounds + 1
    L("f%d round over #%d (curback %d)", n, rounds, r16(A.curback))

  end
  lastgs = gs
  -- FINISH HIM is still gstate 2: the second knockout leaves P2 standing at 0 HP

  if cap0 then
    local rel = n - cap0
    if rel % 2 == 0 then scr:snapshot(string.format("fat_%05d.png", rel)) end
    if rel % 10 == 0 then
      L("rel %d gs %04x wty %08x wtx %08x p2hp %d", rel, gs, r32(A.wty), r32(A.wtx), r16(A.p2hp))
    end
    if rel >= CAP_FRAMES then L("PASS"); log:close(); manager.machine:exit() end
  end
  if n % 120 == 0 then
    L("f%d gstate %04x curback %d rounds %d wty %08x hp %d/%d", n, gs, r16(A.curback), rounds,
      r32(A.wty), r16(A.p1hp), r16(A.p2hp))
  end
  if n > 40000 then L("ERROR - timeout"); log:close(); manager.machine:exit() end
end)
