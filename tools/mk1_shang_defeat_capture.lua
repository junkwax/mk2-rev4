-- mk1_shang_defeat_capture.lua
--
-- MK1 (MAME `mk`, rev 5.0 T-unit): play a 1P game straight to Shang Tsung,
-- win both rounds, and record the "souls escape" sequence frame by frame.
-- Fully automatic - no input needed.  Launch with
-- tools/run_mk1_shang_defeat_capture.ps1; read doc/MK1_SHANG_SOUL_ESCAPE.md.
--
-- mk has no symbol map, so every address below was found in the disassembly:
--   @1051190  gstate (16-bit; MK1's field 0 is 16 bits).  1 attract, 4 select,
--             7 tower, 6 pre-fight, 2 fight, 5 round over, 0Bh = Shang beaten
--             (written by FFCA53C0 on the way into FFDD2160)
--   @10519F0  ladder table pointer (32-bit), @1051A10 ladder position
--   @1051290 / @1051570   P1 / P2 ochar         (8 = Shang Tsung)
--   @1051300 / @10515E0   P1 / P2 health        (max 0A1h)
--   01A80000..01A800F0    the DMA blitter's registers, as in MK2's SYSEQU
--
-- HOW IT GETS THERE
--   Every ladder has ladder slot 7 (= Shang) at position 14, so position 14 is
--   forced until the opponent is picked.  The tower screen then scrolls forever
--   looking for a rung that position has not got, so it is shown position 0
--   instead, and 14 goes back once the fight starts: after the match the game
--   looks at table[pos+1], finds FFFFh (end of ladder), and runs the defeat.
--   P1's health is pinned at max and Shang's held at 1 while P1 walks in
--   punching, so the first clean hit ends each round.
--
-- WHAT IT WRITES (MK1S_OUT)
--   cap_NNNNN.png  one snapshot per frame from gstate 0Bh on
--   blits.log      every blit that frame: SAG x y w h cmap control offset
--   cram.bin       colour RAM slots 0-15 per frame (256 x 16-bit each)
--   capture.log    progress
--
-- The tap handle is pinned in a global.  install_write_tap returns a
-- passthrough handler; if nothing keeps it reachable, GC collects it and the
-- tap goes silent - the first version of this recorded zero blits that way.

local OUT = (os.getenv("MK1S_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local CAP_FRAMES = tonumber(os.getenv("MK1S_FRAMES") or "620")

local log = io.open(OUT .. "capture.log", "w")
local blog = io.open(OUT .. "blits.log", "w")
local cram = io.open(OUT .. "cram.bin", "wb")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"), lp = fld(":IN1", "P1 Low Punch"),
  right = fld(":IN0", "P1 Right"),
}
local function r16(a) return mem:read_u16(a) end
local function r32(a) return mem:read_u32(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end

local A = {
  gstate = 0x01051190, ladpos = 0x01051A10, ladptr = 0x010519F0,
  p1char = 0x01051290, p2char = 0x01051570, p1hp = 0x01051300, p2hp = 0x010515E0,
}
local GS_ATTRACT, GS_SELECT, GS_TOWER, GS_FIGHT, GS_SHANG_DEAD = 1, 4, 7, 2, 0x0B
local SHANG, SHANG_LADDER_POS = 8, 14
local DMA = 0x01A80000

local reg, blits, capturing = {}, {}, false
local ok, err = pcall(function()
  _G.mk1s_dma_tap = mem:install_write_tap(DMA, DMA + 0xff, "mk1dma", function(offset, data, mask)
    local r = (offset - DMA) >> 4
    reg[r] = data
    if r == 1 and (data & 0x8000) ~= 0 and capturing then
      blits[#blits + 1] = string.format("%04x%04x %d %d %d %d %04x %04x %04x",
        reg[3] or 0, reg[2] or 0, reg[4] or 0, reg[5] or 0, reg[6] or 0, reg[7] or 0,
        reg[8] or 0, data, reg[0] or 0)
    end
    return data
  end)
end)
L("dma tap %s %s", ok and "ok" or "FAILED", tostring(err or ""))

local n, phase, cap0, sel0 = 0, 0, nil, nil
local function press(f, on) f:set_value(on and 1 or 0) end

emu.register_frame_done(function()
  n = n + 1
  local gs = r16(A.gstate)

  -- menus: HP dismisses a CMOS-error screen on a fresh nvram; then coin and
  -- start, retried every 400 frames until the select screen shows up
  local k = (n - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and n >= 600)
  press(F.coin, in_menus and n >= 1000 and (k < 6 or (k >= 30 and k < 36)))
  press(F.start, in_menus and n >= 1000 and k >= 120 and k < 126)
  if gs == GS_SELECT and not sel0 then sel0 = n; L("f%d select screen", n) end
  local confirm = sel0 and n >= sel0 + 300 and n < sel0 + 306

  local fighting = (gs == GS_FIGHT and phase == 2)
  local t = n % 16
  press(F.right, fighting)
  press(F.hp, (n >= 600 and n < 606) or confirm or (fighting and t < 3))
  press(F.lp, fighting and t >= 8 and t < 11)

  if phase == 0 and sel0 then
    if r16(A.p2char) == SHANG and r32(A.ladptr) ~= 0 then
      phase = 1; w16(A.ladpos, 0)
      L("f%d Shang picked as the opponent (P1 ochar %d)", n, r16(A.p1char))
    else
      w16(A.ladpos, SHANG_LADDER_POS)
    end
  elseif phase == 1 and gs ~= GS_TOWER then
    phase = 2; w16(A.ladpos, SHANG_LADDER_POS)
    L("f%d tower done (gstate %04x), ladder position back to %d", n, gs, SHANG_LADDER_POS)
  end
  if fighting then
    w16(A.p1hp, 0xA1)
    if r16(A.p2hp) > 1 then w16(A.p2hp, 1) end
  end

  if phase == 2 and gs == GS_SHANG_DEAD then
    capturing = true; cap0 = n; phase = 3
    L("f%d SHANG DEFEATED - capturing %d frames", n, CAP_FRAMES)
  end
  if n % 120 == 0 then
    L("f%d gstate %04x p1 %d p2 %d hp %d/%d ladder %d", n, gs, r16(A.p1char), r16(A.p2char),
      r16(A.p1hp), r16(A.p2hp), r16(A.ladpos))
  end
  if capturing then
    local rel = n - cap0
    blog:write(string.format("F %d gs=%04x n=%d\n", rel, gs, #blits))
    for _, b in ipairs(blits) do blog:write(b .. "\n") end
    blits = {}
    local c = {}
    for i = 0, 16 * 256 - 1 do
      local v = mem:read_u16(0x01800000 + i * 16)
      c[#c + 1] = string.char(v & 0xff, v >> 8)
    end
    cram:write(table.concat(c))
    scr:snapshot(string.format("cap_%05d.png", rel))
    if rel >= CAP_FRAMES then
      L("PASS - %d frames captured", rel)
      cram:close(); blog:close(); log:close(); manager.machine:exit()
    end
  end
  if n > 30000 then
    L("ERROR - never reached gstate 0Bh (phase %d, gstate %04x)", phase, gs)
    log:close(); manager.machine:exit()
  end
end)
