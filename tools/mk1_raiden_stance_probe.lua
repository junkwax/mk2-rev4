-- mk1_raiden_stance_probe.lua - does MK1's Raiden crackle in his NORMAL STANCE?
--
-- A static shape scan of mk.zip said no.  That scan was never calibrated, and
-- when it was, it turned out to catch only 12 of 102 of MK2's OWN ambient bolt
-- records - real bolt art is fat and dense, not the hairline stroke it
-- screened for.  So ask the running game instead.
--
-- Forces a 1P game with Raiden (ochar 2), parks him standing with both bars
-- pinned, and write-taps the DMA blitter so EVERY blit is recorded with its
-- source address.  Anything drawn that is not one of Raiden's own animation
-- records is what we are looking for; the post-pass does that diff in Python.
--
--   mk1_raiden_stance.log    per-frame state
--   mk1_raiden_blits.log     sag x y w h ctrl, one line per blit, with frame
--   snapshots                via MAME's -snapshot_directory
--
-- RAM map from doc/MK1_SHANG_SOUL_ESCAPE.md: MK1's field 0 is 16 bits, so
-- gstate and ochar are r16.  The tap handle MUST be pinned in a global or the
-- GC collects it and it silently never fires again.

local OUT = os.getenv("MK1RD_OUT") or "C:/tmp/mk1raiden/"
local RUN_FRAMES = tonumber(os.getenv("MK1RD_FRAMES") or "") or 4200
local SNAP_EVERY = tonumber(os.getenv("MK1RD_SNAP_EVERY") or "") or 7
local SNAP_MAX = tonumber(os.getenv("MK1RD_SNAP_MAX") or "") or 40

local log = io.open(OUT .. "mk1_raiden_stance.log", "w")
local blog = io.open(OUT .. "mk1_raiden_blits.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"),
  up = fld(":IN0", "P1 Up"), down = fld(":IN0", "P1 Down"),
  right = fld(":IN0", "P1 Right"), left = fld(":IN0", "P1 Left"),
}
-- MK1RD_MOVE=1 cycles jump / angle jump / duck / walk instead of standing
-- idle, so the capture shows whether MK1 keeps the crackle outside the stance.
local MOVE = (os.getenv("MK1RD_MOVE") or "") ~= ""
local function r16(a) return mem:read_u16(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

local A = {
  gstate = 0x01051190, ladpos = 0x01051A10,
  p1char = 0x01051290, p2char = 0x01051570, p1hp = 0x01051300, p2hp = 0x010515E0,
}
local GS_ATTRACT, GS_SELECT, GS_TOWER, GS_FIGHT = 1, 4, 7, 2
local RAIDEN, FULL_HP = 2, 0xA1
local DMA = 0x01A80000

local reg, capturing, nblit = {}, false, 0
local frame = 0
local ok, err = pcall(function()
  _G.mk1rd_dma_tap = mem:install_write_tap(DMA, DMA + 0xff, "mk1rddma", function(offset, data, mask)
    local r = (offset - DMA) >> 4
    reg[r] = data
    -- register 1 with bit 15 set is the "go" write that commits a blit
    if r == 1 and (data & 0x8000) ~= 0 and capturing then
      nblit = nblit + 1
      blog:write(string.format("%d %08x %d %d %d %d %04x\n", frame,
        ((reg[3] or 0) << 16) | (reg[2] or 0),
        reg[4] or 0, reg[5] or 0, reg[6] or 0, reg[7] or 0, reg[0] or 0))
    end
    return data
  end)
end)
L("dma tap %s %s", ok and "ok" or "FAILED", tostring(err or ""))

local sel0, fight0, snaps = nil, nil, 0
local function press(f, on) f:set_value(on and 1 or 0) end

emu.register_frame_done(function()
  frame = frame + 1
  local gs = r16(A.gstate)

  -- HP clears the CMOS-invalid screen on fresh nvram, then coin + start,
  -- retried until the select screen appears.
  local k = (frame - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and frame >= 600)
  press(F.coin, in_menus and frame >= 1000 and (k < 6 or (k >= 30 and k < 36)))
  press(F.start, in_menus and frame >= 1000 and k >= 120 and k < 126)
  if gs == GS_SELECT and not sel0 then sel0 = frame; L("f%d select screen", frame) end

  -- Hold Raiden into P1's slot across the select screen and the fight setup;
  -- MK1 builds the fighter from ochar, so this has to stick past the confirm.
  if gs == GS_SELECT or gs == GS_TOWER or not fight0 then w16(A.p1char, RAIDEN) end
  local confirm = sel0 and frame >= sel0 + 300 and frame < sel0 + 306
  press(F.hp, (frame >= 600 and frame < 606) or confirm)

  if gs == GS_FIGHT and not fight0 then
    fight0 = frame
    capturing = true
    L("f%d FIGHT starts - p1 ochar %d, p2 ochar %d", frame, r16(A.p1char), r16(A.p2char))
  end

  if fight0 then
    -- Pin both bars: a decided round ends the stance long before we are done.
    w16(A.p1hp, FULL_HP)
    w16(A.p2hp, FULL_HP)
    local rel = frame - fight0
    if MOVE then
      local d = rel % 220
      press(F.up,    (d >= 20 and d < 26) or (d >= 100 and d < 106) or (d >= 150 and d < 156))
      press(F.down,  d >= 40 and d < 90)
      press(F.right, (d >= 95 and d < 120) or (d >= 175 and d < 200))
      press(F.left,  d >= 145 and d < 170)
    end
    if rel % 60 == 0 then
      L("f%d rel=%d gs=%04x p1=%d blits=%d", frame, rel, gs, r16(A.p1char), nblit)
    end
    if rel > 90 and snaps < SNAP_MAX and rel % SNAP_EVERY == 0 then
      local okk = pcall(function() scr:snapshot() end)
      L("SNAP %d frame=%d rel=%d ok=%s", snaps, frame, rel, tostring(okk))
      snaps = snaps + 1
    end
  end

  if frame >= RUN_FRAMES then
    L("done: frames=%d blits=%d snaps=%d fight0=%s", frame, nblit, snaps, tostring(fight0))
    log:close(); blog:close()
    manager.machine:exit()
  end
end)
