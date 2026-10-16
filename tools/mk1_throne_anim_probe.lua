-- mk1_throne_anim_probe.lua
--
-- MK1 (MAME `mk`, rev 5.0 T-unit): MEASURE how the seated Shang Tsung on THE
-- THRONE ROOM's throne animates - which of his eight piece lists is showing on
-- every frame, and for how long.  Launch with tools/run_mk1_throne_anim_probe.ps1.
--
-- WHY IT SCANS RAM RATHER THAN READING THE CODE.  MK1's process (FFD6E660)
-- hands a frame list to an animator whose semantics are not transcribed here.
-- The one thing that cannot lie is the value the animator leaves in RAM: the
-- pointer to the piece list being drawn.  So this finds the words that hold one
-- of the eight known list heads, then logs them every frame.  The sequence and
-- the hold times fall out of the log.
--
-- Addresses: see tools/mk1_throne_capture.lua.  RAM is 01000000h..01100000h
-- (bit addresses - worldtlx lives at 0104F890h, gstate at 01051190h).

local OUT = (os.getenv("MK1T_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local FRAMES = tonumber(os.getenv("MK1T_FRAMES") or "") or 900

local log = io.open(OUT .. "anim.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"),
}
local function r16(a) return mem:read_u16(a) end
local function r32(a) return mem:read_u32(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

local A = { gstate = 0x01051190, curback = 0x01051820, p1hp = 0x01051300, p2hp = 0x010515E0 }
local GS_SELECT, GS_FIGHT = 4, 2
local THRONE = 4

-- the eight piece lists, in the order make_mk1throne.py names them
local LISTS = { [0xFFD6F300] = "rest",
                [0xFFD6EDC0] = "f1", [0xFFD6EE80] = "f2", [0xFFD6EF40] = "f3",
                [0xFFD6F000] = "f4", [0xFFD6F0C0] = "f5", [0xFFD6F180] = "f6",
                [0xFFD6F240] = "f7" }
-- ...and the frame TABLE MK1 walks them with (FFD6ED40 + 4k, and the three at
-- FFD6ECE0 before it), so a pointer INTO the table is recognised too
local TAB_LO, TAB_HI = 0xFFD6ECE0, 0xFFD6EDB0

local RAM_LO, RAM_HI, STEP = 0x01000000, 0x01100000, 32

local n, sel0, fight0, scanned = 0, nil, nil, false
local watch = {}            -- [addr] = last value
local function press(f, on) f:set_value(on and 1 or 0) end

local function scan()
  local hits = {}
  for a = RAM_LO, RAM_HI - STEP, STEP do
    local v = r32(a)
    if LISTS[v] or (v >= TAB_LO and v <= TAB_HI and (v - TAB_LO) % 32 == 0) then
      hits[#hits + 1] = a
    end
  end
  return hits
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

  -- give the object a moment to exist, then find the words that hold a list
  if rel == 30 and not scanned then
    scanned = true
    local hits = scan()
    L("scan at rel=%d: %d candidate word(s)", rel, #hits)
    for _, a in ipairs(hits) do
      watch[a] = -1
      L("  watch %08X = %08X", a, r32(a))
    end
    if #hits == 0 then L("ERROR - no RAM word holds one of the eight lists") end
  end

  if scanned then
    for a, last in pairs(watch) do
      local v = r32(a)
      if v ~= last then
        watch[a] = v
        L("rel=%-5d %08X -> %08X  %s", rel, a, v,
          LISTS[v] or ((v >= TAB_LO and v <= TAB_HI) and
            string.format("table[%d]", (v - TAB_LO) // 32) or "?"))
      end
    end
  end
  if rel >= FRAMES then L("PASS"); log:close(); manager.machine:exit() end
end)
