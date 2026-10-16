-- mk1_throne_park_probe.lua
--
-- MK1 (MAME `mk`, rev 5.0 T-unit): park THE THRONE ROOM's camera at several
-- STATIONARY positions and snapshot each one, with all nine worldtlx logged on
-- the same frame.  Launch with tools/run_mk1_throne_park_probe.ps1.
--
-- WHY STATIONARY MATTERS.  The scrolling capture's frames are one or two
-- pixels off the worldtlx logged beside them, which is fine for looking at but
-- useless for deciding WHICH PLANE the seated Shang Tsung is drawn against -
-- the candidate planes are only a few pixels apart in his screen x at some
-- cameras.  Walking, then waiting for the camera to settle, removes the skew.
--
-- Writes park_<n>_cam<x>.png plus park.log (every plane, plus the piece list
-- the animator is showing, at the instant of each shot).

local OUT = (os.getenv("MK1T_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end

local log = io.open(OUT .. "park.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"),
  right = fld(":IN0", "P1 Right"), left = fld(":IN0", "P1 Left"),
}
local function r16(a) return mem:read_u16(a) end
local function r32(a) return mem:read_u32(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

local A = { gstate = 0x01051190, curback = 0x01051820, p1hp = 0x01051300, p2hp = 0x010515E0 }
local GS_SELECT, GS_FIGHT = 4, 2
local THRONE = 4
local PLANEX = {}
for e = 0, 8 do PLANEX[e] = 0x0104F890 - 32 * e end
local FRAME_WORD = 0x01019540     -- found by mk1_throne_anim_probe.lua
local LISTS = { [0xFFD6F300] = "rest",
                [0xFFD6EDC0] = "f1", [0xFFD6EE80] = "f2", [0xFFD6EF40] = "f3",
                [0xFFD6F000] = "f4", [0xFFD6F0C0] = "f5", [0xFFD6F180] = "f6",
                [0xFFD6F240] = "f7" }

-- walk RIGHT for `walk` frames, then stand still for `settle`, then shoot.
local STOPS = { {walk = 0, settle = 150}, {walk = 90, settle = 150},
                {walk = 90, settle = 150}, {walk = 120, settle = 150},
                {walk = 150, settle = 150}, {walk = 200, settle = 200} }

local n, sel0, fight0 = 0, nil, nil
local stop, phase0 = 1, nil
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
  if sel0 and gs ~= GS_FIGHT and not fight0 then w16(A.curback, THRONE) end
  press(F.hp, (n >= 600 and n < 606) or confirm)

  if gs == GS_FIGHT and not fight0 then
    fight0 = n; phase0 = n
    L("f%d FIGHT on curback %d", n, r16(A.curback))
  end
  if not fight0 then
    if n > 30000 then L("ERROR - never reached the fight"); log:close(); manager.machine:exit() end
    return
  end
  w16(A.p1hp, 0xA1); w16(A.p2hp, 0xA1)

  local s = STOPS[stop]
  if not s then L("PASS"); log:close(); manager.machine:exit(); return end
  local rel = n - phase0
  press(F.right, rel < s.walk)
  press(F.left, false)
  if rel == s.walk + s.settle then
    local cam = r32(PLANEX[1]) >> 16
    local name = string.format("park_%d_cam%d", stop, cam)
    scr:snapshot(name .. ".png")
    local t = {}
    for e = 0, 8 do t[#t + 1] = string.format("x%d=%d", e, r32(PLANEX[e]) >> 16) end
    local fv = r32(FRAME_WORD)
    L("%s  %s  frame=%08X %s", name, table.concat(t, " "), fv, LISTS[fv] or "?")
    stop = stop + 1
    phase0 = n
  end
end)
