-- umk3_observe.lua
-- PASSIVE capture rig for a human-played UMK3 session.  It drives NOTHING -
-- every input is yours - it only records frames so a move can be measured
-- afterwards.
--
-- NO TRIGGER KEY.  An earlier version armed on F5 and captured nothing: the
-- keypress never reached `input:code_pressed`, and because that call was
-- wrapped in a pcall that fell back to "not pressed", it failed SILENTLY for a
-- whole session.  Recording unconditionally has nothing to go wrong, and
-- finding the move afterwards is cheap - tools/find_umk3_slam.py does it by
-- looking for a body high on the screen.
--
-- WHY ONE PNG PER FRAME AND NOT A VIDEO:
-- The one thing Ermac's telekinetic slam lanes do NOT carry in the ROM is the
-- TICK RATE - neither lane has a sleep, the caller sets it (see
-- doc/UMK3_ERMAC_TELESLAM.md).  So the rate has to be counted off the screen:
-- with exactly one snapshot per emulated frame, the number of identical
-- consecutive frames IS the number of ticks that pose is held.  A recorded
-- video re-times everything and destroys precisely that.
--
-- HOW TO USE
--   1. Start it, coin up, pick ERMAC (row 2, third tile).
--   2. Do Back, Down, Back + High Kick two or three times.
--   3. Close MAME.
-- Recording begins at U3_START and stops after U3_MAX frames.
local LOG   = os.getenv("U3_LOG")   or "umk3_observe.log"
local START = tonumber(os.getenv("U3_START") or "1")
local MAX   = tonumber(os.getenv("U3_MAX")   or "9000")

local fh = io.open(LOG, "w")
local function log(f, ...)
  local s = "[obs] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
  print(s); if fh then fh:write(s, "\n"); fh:flush() end
end

local frame, shots, stopped = 0, 0, false

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    log("recording every frame from %d, up to %d frames", START, MAX)
    log("no trigger key - just play; close MAME when you have done the move")
  end
  if stopped or frame < START then return end

  manager.machine.video:snapshot()
  shots = shots + 1
  if shots % 500 == 0 then log("%d frames captured (emu frame %d)", shots, frame) end
  if shots >= MAX then
    stopped = true
    log("hit the %d frame cap at emu frame %d - recording stopped", MAX, frame)
    log("close MAME whenever you like; what is captured is already on disk")
  end
end)
emu.register_stop(function()
  log("session over: %d frames captured", shots)
  if fh then fh:flush(); fh:close() end
end)
