-- fly_wins_test.lua - FRUIT FLY WINS banner + announcer (flyname, MAIN.ASM fly_won).
--
-- One-player game as Liu Kang. FW_FLY (1 or 0) is held in fly_player from the
-- select screen on. P1 is kept alive, the CPU's life is capped at 5 and P1 walks
-- in punching, so P1 takes round 1. When the round is won the rig snapshots the
-- banner 40 frames in and logs the winner_status/gstate path, then exits after the
-- announcer has had time to finish. Run MAME with -wavwrite to capture the line.
--   FW_FLY=1 -> "FRUIT FLY WINS" + FRUITFLY.wav     FW_FLY=0 -> "LIU KANG WINS" (control)
-- Env: FW_MAP FW_LOG FW_READY FW_FLY
local MAP = os.getenv("FW_MAP"):gsub("\\", "/")
local LOG = os.getenv("FW_LOG"):gsub("\\", "/")
local READY = os.getenv("FW_READY")
local FLY = tonumber(os.getenv("FW_FLY") or "1")
local fh = io.open(LOG, "w")
local function log(f, ...) local l = string.format(f, ...); print("[fw] " .. l); fh:write(l, "\n"); fh:flush() end
local sym = {}
for line in io.lines(MAP) do for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end end
for _, n in ipairs({ "gstate", "p1_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj", "winner_status", "fly_player" }) do
  if not sym[n] then log("ERROR missing symbol %s", n) end
end
local space, fields, frame = nil, {}, 0
local charsel, confirm, won_at, lastws = 0, 0, 0, -1
-- sound command tap (tools/ermac_fireball_test.lua): the game sends each DCS track
-- to 0x01d01030 as two bytes tagged 0xff00; a real track is $0000-$04ff, so a high
-- byte is always <= 7. Logs every track sent after the round is won.
local SND_PORT, snd_hi = 0x01d01030, nil
local function on_sound_write(offset, data, mask)
  if offset ~= SND_PORT then return data end
  local w = data & 0xffff
  if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
  if snd_hi == nil then
    if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
    return data
  end
  local code = (snd_hi << 8) | (w & 0xff)
  snd_hi = nil
  if won_at and won_at > 0 then
    log("  SOUND frame=%d (+%d after the win) SEND $%04x%s", frame, frame - won_at, code,
        (code >= 0x0323 and code <= 0x0325) and "  <- FRUITFLY.wav" or "")
  end
  return data
end
local function r16(x) return space:read_u16(x) end
local function w16(x, v) space:write_u16(x, v & 0xffff) end
emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    local ok, tap = pcall(function() return space:install_write_tap(0x01d00000, 0x01d01fff, "fwsnd", on_sound_write) end)
    snd_tap = ok and tap or nil
    log("sound tap %s", snd_tap and "installed" or ("FAILED: " .. tostring(tap)))
    for _, p in pairs(manager.machine.ioport.ports) do for _, f in pairs(p.fields) do fields[f.name] = f end end
    log("fly_player will be %d", FLY)
  end
  if READY and frame == 120 then local r = io.open(READY, "w"); r:write("ok"); r:close() end
  local gs = r16(sym.gstate)
  local press = {}
  if gs == 4 and charsel == 0 then charsel = frame end
  if charsel == 0 then
    press["UI Select"] = frame >= 5 and frame < 35
    press["Coin 1"] = frame >= 200 and (frame % 80) < 20
    press["1 Player Start"] = frame >= 1000 and (frame % 120) < 30
  else
    w16(sym.fly_player, FLY)
    if gs == 4 then
      w16(sym.p1_char, 1)
      if confirm == 0 and frame - charsel > 90 then confirm = frame end
      press["P1 High Punch"] = confirm > 0 and frame >= confirm and frame < confirm + 45
    end
  end
  local ws = r16(sym.winner_status)
  if ws ~= lastws then log("frame %d winner_status %d gstate %d", frame, ws, gs); lastws = ws end
  if gs == 2 and won_at == 0 then
    w16(sym.p1_bar, 0xa1)
    if r16(sym.p2_bar) > 5 then w16(sym.p2_bar, 5) end
    local p1 = space:read_u32(sym.p1_obj); local p2 = space:read_u32(sym.p2_obj)
    if p1 ~= 0 and p2 ~= 0 then
      local x1 = space:read_u16(p1 + 0x90); local x2 = space:read_u16(p2 + 0x90)
      if math.abs(x2 - x1) > 60 then press[(x2 > x1) and "P1 Right" or "P1 Left"] = true
      else press["P1 High Punch"] = (frame % 12) < 3 end
    end
  end
  if won_at == 0 and ws == 1 then won_at = frame; log("P1 won the round at frame %d", frame) end
  if won_at > 0 then
    local rel = frame - won_at
    if rel == 60 or rel == 120 or rel == 200 then
      pcall(function() manager.machine.screens[":screen"]:snapshot() end)
      log("SNAP rel=%d gstate=%d ws=%d", rel, gs, ws)
    end
    if rel == 420 then log("DONE fly_player=%d", r16(sym.fly_player)); manager.machine:exit() end
  end
  for n, f in pairs(fields) do
    if n:sub(1, 3) == "P1 " or n == "Coin 1" or n == "1 Player Start" or n == "UI Select" then f:set_value(press[n] and 1 or 0) end
  end
  if frame > 20000 then log("TIMEOUT"); manager.machine:exit() end
end)
