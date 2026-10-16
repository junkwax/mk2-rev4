-- mk1_music_cmd_probe.lua
--
-- HOW MK1 SEQUENCES ITS STAGE MUSIC: plays a real 1P match in MAME `mk` and
-- logs every command the game writes to the sound board, with the frame, the
-- game state and both health bars, so the cues can be read off as round start
-- / FINISH HIM / round end.  Launch with tools/run_mk1_music_cmd_probe.ps1.
--
-- mk rev 5.0 is a T-UNIT: the ADPCM board is written at 01D01020 (MAME
-- midtunit.cpp sound_w, as MK2).  NOT 01480000 - the CMOS write-enable latch,
-- DCSExplorer/mk1_audio/mk1_music_capture.lua's dead end.
-- Addresses as tools/mk1_shang_defeat_capture.lua found them (no symbol map).
--
-- Round 1: P2's bar is held at 1, P1 walks in punching.  Round 2: the same,
-- then once the bar is empty and the fight state holds (FINISH HIM) P1 lets go
-- of everything for MK1P_FINWAIT frames so the finish cue plays out, then
-- punches him.  Env: MK1P_OUT (dir), MK1P_FINWAIT (frames, default 700),
-- MK1P_LADDER (force this ladder position, e.g. 14 = Shang; default unforced).

local OUT = (os.getenv("MK1P_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local FINWAIT = tonumber(os.getenv("MK1P_FINWAIT") or "700")
local LADDER = tonumber(os.getenv("MK1P_LADDER") or "")

local log = io.open(OUT .. "cmds.log", "w")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local ports = manager.machine.ioport.ports
local function fld(port, name) return ports[port].fields[name] end
local F = {
  coin = fld(":IN1", "Coin 1"), start = fld(":IN1", "1 Player Start"),
  hp = fld(":IN0", "P1 High Punch"), lp = fld(":IN1", "P1 Low Punch"),
  right = fld(":IN0", "P1 Right"),
}
local function r16(a) return mem:read_u16(a) end
local function w16(a, v) mem:write_u16(a, v) end
local function L(fmt, ...) log:write(string.format(fmt, ...) .. "\n"); log:flush() end
local A = {
  gstate = 0x01051190, ladpos = 0x01051A10,
  p1char = 0x01051290, p2char = 0x01051570, p1hp = 0x01051300, p2hp = 0x010515E0,
}
local GS_SELECT, GS_FIGHT = 4, 2
local SND = 0x01D01020

local n, gs = 0, 0
_G.mk1p_snd_tap = mem:install_write_tap(SND, SND + 0x1f, "mk1snd", function(offset, data, mask)
  L("f%6d  t=%7.2fs  CMD %04x  (gstate %04x hp %d/%d)", n, n / 54.7, data & 0xffff, gs,
    r16(A.p1hp), r16(A.p2hp))
  return data
end)
L("sound tap installed at %08x", SND)

-- MK1P_YM=1: also log every YM2151 register write on the sound board
-- (":adpcm:cpu", 2400h even = register select, odd = data; williamssound.cpp)
-- to ym.log as "frame reg data" - so a music change can be read off the chip
-- itself: all channels keyed off at once is a hard cut, TL (60h-7Fh) stepping
-- down over several frames is a fade.
if os.getenv("MK1P_YM") == "1" then
  local ylog = io.open(OUT .. "ym.log", "w")
  local snd = manager.machine.devices[":adpcm:cpu"].spaces["program"]
  local yreg = 0
  _G.mk1p_ym_tap = snd:install_write_tap(0x2400, 0x27ff, "mk1ym", function(offset, data, mask)
    if offset & 1 == 0 then yreg = data & 0xff
    else ylog:write(string.format("%d %02x %02x\n", n, yreg, data & 0xff)) end
    return data
  end)
  L("YM2151 tap installed on :adpcm:cpu 2400h")
end

local sel0, lastgs, rounds_won, fin0 = nil, -1, 0, nil
local function press(f, on) f:set_value(on and 1 or 0) end

emu.register_frame_done(function()
  n = n + 1
  gs = r16(A.gstate)
  if gs ~= lastgs then
    L("f%6d  t=%7.2fs  gstate %04x -> %04x  (P1 %d P2 %d hp %d/%d)", n, n / 54.7, lastgs, gs,
      r16(A.p1char), r16(A.p2char), r16(A.p1hp), r16(A.p2hp))
    if lastgs == GS_FIGHT then rounds_won = rounds_won + 1 end
    lastgs = gs
  end
  local k = (n - 600) % 400
  local in_menus = (not sel0 and gs ~= GS_SELECT and n >= 600)
  press(F.coin, in_menus and n >= 1000 and (k < 6 or (k >= 30 and k < 36)))
  press(F.start, in_menus and n >= 1000 and k >= 120 and k < 126)
  if gs == GS_SELECT and not sel0 then sel0 = n end
  if LADDER and sel0 and gs ~= GS_FIGHT then w16(A.ladpos, LADDER) end
  local confirm = sel0 and n >= sel0 + 300 and n < sel0 + 306

  local fighting = (gs == GS_FIGHT)
  if fighting then
    w16(A.p1hp, 0xA1)
    if r16(A.p2hp) > 1 and not fin0 then w16(A.p2hp, 1) end
    if rounds_won >= 1 and r16(A.p2hp) == 0 and not fin0 then
      fin0 = n; L("f%6d  t=%7.2fs  FINISH HIM - hands off for %d frames", n, n / 54.7, FINWAIT)
    end
  end
  local hold = fin0 and n < fin0 + FINWAIT
  local t = n % 16
  local attack = fighting and not hold
  press(F.right, attack)
  press(F.hp, (n >= 600 and n < 606) or confirm or (attack and t < 3))
  press(F.lp, attack and t >= 8 and t < 11)

  if fin0 and gs ~= GS_FIGHT and n > fin0 + FINWAIT + 900 then
    L("DONE"); log:close(); manager.machine:exit()
  end
  if n > 40000 then L("ERROR - ran out of frames (gstate %04x)", gs); log:close(); manager.machine:exit() end
end)
