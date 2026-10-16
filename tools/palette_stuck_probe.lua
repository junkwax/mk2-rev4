-- palette_stuck_probe.lua - rides along with flybrain_play.lua (FB_ADDON=<this file>).
--
-- Watches player 2's palette every frame and says when it is wearing a FREEZE palette
-- (any *NUFRZ_P / *FREZ_P / FREEZE_P) while it is NOT frozen - the "Shang as Jax, white and
-- blue" report from the 2026-09-22 stream. The suspect: swpal (MKUTIL.ASM) keeps the old
-- palette, silently, when getfpal finds no free colour map, so a thaw that asks for the
-- normal palette while the 35 foreground maps are full leaves the ice on.
--
-- Logs to <FB_OUT>/palprobe.log:
--   PAL   every change of p2's palette: frame, ochar, action, palette, foreground maps in use
--   STUCK a freeze palette held 27+ ticks outside act_frozen/act_super_froze, with the map count
--   PEAK  the most foreground maps in use so far, every 5000 frames
-- Addresses are RAW map (bit) addresses - Lua's read_u16/read_u32 take those directly.

local MAP = os.getenv("FB_MAP")
local OUT = (os.getenv("FB_OUT") or "C:/tmp/flybrain") .. "/palprobe.log"
local fh = io.open(OUT, "w")
local function log(f, ...) fh:write(string.format(f, ...) .. "\n"); fh:flush() end

local sym, name_of = {}, {}
for line in io.lines(MAP) do
  for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_]+)") do
    local v = tonumber(a, 16)
    sym[n] = sym[n] or v
    if n:match("_P$") or n:match("_p$") then name_of[v] = name_of[v] or n end
  end
end
for _, n in ipairs({ "p2_obj", "p2_proc", "fpalram" }) do
  if not sym[n] then log("probe: missing symbol %s - giving up", n); fh:close(); return end
end

-- ALT[name] = { [ochar] = table# } for character_palettes_2..7: a costume that belongs on
-- player 2 only in a mirror (2 = the automatic "ugly" one) or after a Start+button pick
local ALT, DEF = {}, {}   -- DEF[ochar] = table 1 (default); a table reusing it is no costume
do
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]") or ".") .. "/../src/MKGUYS.ASM"
  local tab, row = nil, 0
  for line in io.lines(src) do
    local t = line:match("^character_palettes_(%d)")
    if t then tab, row = tonumber(t), 0
    elseif tab then
      local n = line:match("^%s*%.long%s+([%w_]+)")
      if n then
        if tab == 1 then DEF[row] = n
        elseif DEF[row] ~= n then ALT[n] = ALT[n] or {}; ALT[n][row] = ALT[n][row] or tab end
        row = row + 1
        if row > 19 then tab = nil end
      elseif line:match("^%S") then tab = nil end
    end
  end
end

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return mem:read_u16(a) end
local function r32(a) return mem:read_u32(a) end
local NMFPAL, PALRSIZ, PALCNT = 35, 0x40, 0x20
local OCHAR, OPAL, P_ACTION = 0x1f0, 0x140, 0x1f0
local ACT_FROZEN, ACT_SUPER_FROZE = 0x0401, 0x0616

local function icy(n) return n and (n:find("NUFRZ") or n:find("FREZ") or n == "FREEZE_P") end
local function used()
  local c = 0
  for i = 0, NMFPAL - 1 do if r16(sym.fpalram + i * PALRSIZ + PALCNT) ~= 0 then c = c + 1 end end
  return c
end

local frame, last_name, stuck, peak, stuck_logged = 0, nil, 0, 0, false
log("probe: watching p2's palette; %d foreground colour maps", NMFPAL)
do
  local n = 0; for _ in pairs(ALT) do n = n + 1 end
  local j = ALT.JAXBLU_P and next(ALT.JAXBLU_P)
  log("probe: %d alternate-costume palettes parsed; JAXBLU_P belongs to ochar %s", n, tostring(j))
end
PALPROBE_HANDLE = emu.add_machine_frame_notifier(function()   -- global: a dropped handle stops firing
  frame = frame + 1
  local o, p = r32(sym.p2_obj), r32(sym.p2_proc)
  if o == 0 or p == 0 then return end
  local slot = r16(o + OPAL) & 0xff
  if slot >= NMFPAL then return end
  local id = r32(sym.fpalram + slot * PALRSIZ)
  local nm = name_of[id] or string.format("%08x", id)
  local och, act, u = r16(o + OCHAR), r16(p + P_ACTION), used()
  if u > peak then peak = u end
  if nm ~= last_name then
    log("PAL   f%d ochar %d act %04x -> %s (slot %d, fg maps in use %d/%d)", frame, och, act, nm, slot, u, NMFPAL)
    last_name = nm
  end
  if icy(nm) and act ~= ACT_FROZEN and act ~= ACT_SUPER_FROZE then
    stuck = stuck + 1
    if stuck == 27 then   -- half a second
      log("STUCK f%d ochar %d act %04x wearing %s, not frozen - fg maps in use %d/%d (peak %d)",
          frame, och, act, nm, u, NMFPAL, peak)
    end
  else
    stuck = 0
  end
  -- ALTERNATE COSTUME with no mirror to justify it (the "Shang as Jax, white and blue" case)
  local p1o = sym.p1_obj and r32(sym.p1_obj) or 0
  local p1ch = p1o ~= 0 and r16(p1o + OCHAR) or -1
  if ALT[nm] and ALT[nm][och] and p1ch ~= och then
    altwrong = (altwrong or 0) + 1
    if altwrong == 27 then
      log("ALT   f%d ochar %d wearing %s (costume table %d) but player 1 is ochar %d - no mirror. oflags2 %04x alt_pal_owner %04x act %04x",
          frame, och, nm, ALT[nm][och], p1ch, r16(o + 0x160), sym.alt_pal_owner and r16(sym.alt_pal_owner) or 0, act)
    end
  else
    altwrong = 0
  end
  if frame % 5000 == 0 then log("PEAK  f%d most foreground maps in use so far: %d/%d", frame, peak, NMFPAL) end
end)
