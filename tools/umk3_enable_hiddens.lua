-- umk3_enable_hiddens.lua
-- Unlock UMK3's three hidden fighters - ERMAC, MILEENA and CLASSIC SUB-ZERO -
-- by making the game run its OWN "ENABLE HIDDENS" handler, then letting MAME
-- persist the result to nvram.  Run once; the unlock survives every later boot
-- because it lives in CMOS, exactly as if a technician had done it.
--
-- HOW IT WAS FOUND
--
-- UMK3 carries Ed Boon's developer menu, the "ULTIMATE EJB MENU" (string table
-- at byte 0x070964).  Two of its entries are ENABLE HIDDENS / DISABLE HIDDENS,
-- and their handlers sit four bytes apart:
--
--     FFB84FB0  CLR  A1                 <- DISABLE HIDDENS
--     FFB84FC0  JR   FFB85000
--     FFB84FD0  MOVI 0EDB0h,A1          <- ENABLE HIDDENS
--     FFB85000  ... writes A1 to CMOS slots 1Fh, 20h and 21h
--
-- Three slots, one per hidden fighter, and 0EDB0h is the "unlocked" magic.
-- The CMOS address maths is at FFB90E50:
--     MOVI 40h,A7 / MPYU A0,A7 / ADDI 1408000h,A7
--
-- WHY NOT JUST POKE CMOS
--
-- Two reasons, both tried and both fail:
--   * CMOS is WRITE-PROTECTED until FFB910C0 opens it (MOVI 40h,A1 /
--     CALLA FFB91A40h).  Lua writes into that region are simply dropped.
--   * Hand-patching MAME's nvram file fails the game's own CMOS checksum, and
--     the next boot wipes it back to defaults - the "CMOS INVALID -- FACTORY
--     SETTINGS RESTORED" screen.
-- Running the game's handler does the unlock, the checksum and the save the
-- way the game does them, so none of that applies.
--
--   mame umk3 -autoboot_script tools/umk3_enable_hiddens.lua -seconds_to_run 60
--
-- Then start MAME normally: the three dragon-logo tiles on SELECT YOUR FIGHTER
-- are replaced by Mileena, Ermac and Classic Sub-Zero (row 2, tiles 2-4).
local LOG = os.getenv("U3_LOG") or "umk3_enable_hiddens.log"
local AT  = tonumber(os.getenv("U3_AT") or "900")   -- frame to jump the handler
local fh  = io.open(LOG, "w")
local function log(f, ...)
  local s = "[umk3] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
  print(s); if fh then fh:write(s, "\n"); fh:flush() end
end

local ENABLE_HIDDENS = 0xFFB84FD0
local cpu, fields, frame, poked = nil, {}, 0, false
local function h(n, v) local f = fields[n]; if f then f:set_value(v and 1 or 0) end end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]
    for _, p in pairs(manager.machine.ioport.ports) do
      for _, f in pairs(p.fields) do fields[f.name] = f end
    end
    log("will run ENABLE HIDDENS (%#010x) at frame %d", ENABLE_HIDDENS, AT)
  end

  -- Walk the boot screens.  UMK3 stops on a CMOS/error page that wants a GAME
  -- button, not a UI key, so tap High Punch as well as pressing UI Select for
  -- MAME's own warning screen.
  h("UI Select", frame >= 5 and frame < 40)
  h("P1 High Punch", frame >= 60 and frame < AT - 60 and (frame % 55) < 10)

  if frame == AT and not poked then
    poked = true
    log("PC was %#010x; forcing the handler", cpu.state["PC"].value)
    cpu.state["PC"].value = ENABLE_HIDDENS
  end

  -- Let it finish and settle so MAME writes nvram on the way out.  Exiting via
  -- manager.machine:exit() is what makes the save happen - killing the process
  -- loses the unlock.
  if frame > AT + 600 then
    log("done - exit cleanly so nvram is written")
    manager.machine:exit()
  end
end)
emu.register_stop(function() if fh then fh:flush(); fh:close() end end)
