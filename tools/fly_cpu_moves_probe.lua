-- fly_cpu_moves_probe.lua - what the CPU OPPONENT actually does, per fighter, while the fly
-- plays.  Rides along with tools/flybrain_play.lua (FB_ADDON=<this file>); it only watches.
--
-- Two things, written to CPM_LOG (default <FB_OUT>/cpu_moves.txt):
--   * every p_action the CPU's process STARTS (an edge, not a per-frame count), tallied per
--     CPU ochar - so a move the drone was given and never throws reads as a zero, and
--     tools/fly_cpu_moves_report.py names the codes out of MAINEQU.ASM;
--   * every fatality: the frame f_death takes a fatality number, both fighters and both bars.  The
--     man still standing on more than 1 is the one doing it.
-- A table is rewritten every CPM_EVERY frames (default 3000) so a killed run keeps its data.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local OUT = os.getenv("FB_OUT") or (ROOT .. "/tmp")
local LOG = os.getenv("CPM_LOG") or (OUT .. "/cpu_moves.txt")
local EVERY = tonumber(os.getenv("CPM_EVERY") or "3000")

local sym = {}
for line in io.lines(os.getenv("FB_MAP") or (ROOT .. "/src/mk2.map")) do
  for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
local P_ACTION = 0x100 + 0x0f0          -- pdata + 0f0h (MKSTRUCT.ASM), bit offset

local space, frame = nil, 0
local tally, fatal = {}, {}               -- tally[ochar][action] = starts
local last_act, last_death = nil, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end

local function write()
  local f = io.open(LOG, "w")
  if not f then return end
  f:write(string.format("# frame %d\n", frame))
  for _, e in ipairs(fatal) do f:write(e .. "\n") end
  local chars = {}
  for c in pairs(tally) do chars[#chars + 1] = c end
  table.sort(chars)
  for _, c in ipairs(chars) do
    local acts = {}
    for a, n in pairs(tally[c]) do acts[#acts + 1] = { a, n } end
    table.sort(acts, function(x, y) return x[1] < y[1] end)
    local parts = {}
    for _, an in ipairs(acts) do parts[#parts + 1] = string.format("%04x:%d", an[1], an[2]) end
    f:write(string.format("CPU %d %s\n", c, table.concat(parts, " ")))
  end
  f:close()
end

emu.register_frame_done(function()
  if not space then
    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then return end
    space = cpu.spaces["program"]
  end
  frame = frame + 1
  local gs = r16(sym.gstate)
  local proc = r32(sym.p2_proc)
  if gs == 2 and proc ~= 0 then                 -- the fly is P1, so P2 is the CPU
    local c, a = r16(sym.p2_char), r16(proc + P_ACTION)
    if a ~= last_act then
      tally[c] = tally[c] or {}
      tally[c][a] = (tally[c][a] or 0) + 1
      last_act = a
    end
  else
    last_act = nil
  end
  local d = r16(sym.f_death)
  -- init_death_blow writes the fatality NUMBER (1, 2...); -1 (ffff) is "complete", which an
  -- ordinary round end also leaves behind, so only a small positive value is a fatality
  if d ~= 0 and d < 0x100 and (last_death == 0 or last_death >= 0x100) then
    fatal[#fatal + 1] = string.format("FATALITY frame %d f_death %04x winner_status %d  p1 %d bar %d  p2 %d bar %d",
      frame, d, r16(sym.winner_status), r16(sym.p1_char), r16(sym.p1_bar), r16(sym.p2_char), r16(sym.p2_bar))
    write()
  end
  last_death = d
  if frame % EVERY == 0 then write() end
end)
