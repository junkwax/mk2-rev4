-- Walk attract mode and the front-end screens, snapshotting periodically, so a
-- background-payload removal can be eyeballed on the screens the battle
-- stability sweep never reaches: the logo/title beats, character select, the
-- VS screen and the winner/buy-in screen.
--
-- The retired BBB> payloads sit next to LIVE ones in MK7MIL (MKVERSUS,
-- MKSELECT, MKWINNER, MKHUGE, NUENT1/2), so this is the check that they did
-- not get taken with them.
--
-- Usage:
--   mame.exe mk2 -autoboot_script tools/attract_screens_probe.lua

local INTERVAL = 110          -- frames between shots (~2s at 54.7Hz)
local LIMIT    = tonumber(os.getenv("ATTRACT_SHOTS") or "40")

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")

local mac = manager.machine
local scr = mac.screens[":screen"]
local out = io.open(ROOT .. "/tools/attract_screens_probe.log", "w")

local shots, last = 0, -INTERVAL
local mem = mac.devices[":maincpu"].spaces["program"]

local function log(s)
  out:write(s .. "\n"); out:flush()
  print(s)
end

log("attract screens probe - interval " .. INTERVAL .. "f, limit " .. LIMIT)

local function tick()
  local f = scr:frame_number()
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
