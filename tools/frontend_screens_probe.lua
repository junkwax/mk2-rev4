-- Coin up, start a 1P game, and snapshot the front-end screens the battle
-- stability sweep never reaches: character SELECT, the VS screen, and the
-- winner/continue screen.
--
-- Those three are LIVE BBB> payloads in MK7MIL (MKSELECT / MKVERSUS /
-- MKWINNER) that sit immediately next to the retired ones removed on
-- 2026-09-09, so this is the check that LOAD2's block dedup really did keep
-- them when their neighbours went.
--
-- Usage:
--   mame.exe mk2 -autoboot_script tools/frontend_screens_probe.lua

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LIMIT = tonumber(os.getenv("FRONTEND_SHOTS") or "34")
local INTERVAL = 70

local mac = manager.machine
local scr = mac.screens[":screen"]
local out = io.open(ROOT .. "/tools/frontend_screens_probe.log", "w")

local function log(s)
  out:write(s .. "\n"); out:flush(); print(s)
end

-- find the coin and start fields by name, whatever the port tags are
local coin, start1
for tag, port in pairs(mac.ioport.ports) do
  for name, field in pairs(port.fields) do
    if name:find("Coin 1") then coin = field end
    if name:find("1 Player Start") or name == "P1 Start" then start1 = field end
  end
end
log("coin=" .. tostring(coin ~= nil) .. " start=" .. tostring(start1 ~= nil))

local shots, last = 0, 0
local phase = 0

local function tick()
  local f = scr:frame_number()

  -- boot for a bit, then coin up, then press start, then let it run
  if phase == 0 and f > 400 then
    if coin then coin:set_value(1) end
    phase = 1; last = f
  elseif phase == 1 and f > last + 12 then
    if coin then coin:set_value(0) end
    phase = 2; last = f
  elseif phase == 2 and f > last + 40 then
    if start1 then start1:set_value(1) end
    phase = 3; last = f
  elseif phase == 3 and f > last + 12 then
    if start1 then start1:set_value(0) end
    phase = 4; last = f
    log("coined and started at frame " .. f)
  end

  if phase < 4 then return end
  if f - last < INTERVAL then return end
  last = f
  shots = shots + 1
  mac.video:snapshot()
  log(string.format("shot %02d  frame %d", shots, f))
  if shots >= LIMIT then
    log("done")
    mac:exit()
  end
end

emu.register_frame_done(tick)
