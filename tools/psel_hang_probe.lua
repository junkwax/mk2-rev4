-- psel_hang_probe.lua - black-box recorder for the character-select hang.
--
-- The hang is `cmovea` in cmove9 (MKSEL.ASM:1644).  `ochar_to_menu` indexes a
-- 12-entry table with no range check, so an ochar of ft_jade (16) or ft_rain
-- (19) reads a NEGATIVE word past the table and the dsjs walk of the mugshot
-- oslink chain runs ~4.3 billion times.  For that to happen a cursor process
-- has to reach cmove9 with @p?_char ALREADY holding a hidden ft_*.
--
-- This records every write to p1_char / p2_char with the writer's PC, plus
-- gstate / p?_state transitions, and fires when the CPU parks in the loop.
-- Play the select screen normally; when it locks up, close MAME and read
-- tools/psel_hang_probe.log.  Resolve any pc with: python sym_resolve.py <pc>
--
--   mame.exe mk2 -window -autoboot_script tools/psel_hang_probe.lua

local ROOT = "C:/Users/you/Workplace/mk2-main"
local out = assert(io.open(ROOT.."/tools/psel_hang_probe.log", "w"))
local function log(f, ...)
  local s = string.format(f, ...)
  print("[psel] "..s); out:write(s, "\n"); out:flush()
end

local syms = {}
local m = assert(io.open(ROOT.."/src/mk2.map", "r"))
for l in m:lines() do
  for a, n in l:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n] = tonumber(a, 16) end
end
m:close()
local function s(n) assert(syms[n], n); return syms[n] end

-- raw BIT addresses: space:read_u16 and install_write_tap both take these
local A = { gstate = s("gstate"), p1_char = s("p1_char"), p2_char = s("p2_char"),
            p1_state = s("p1_state"), p2_state = s("p2_state") }
local FLAGS = {}
for _, n in ipairs({"f_jade_cheat1","f_jade_cheat2","f_rain_cheat1","f_rain_cheat2",
                    "f_ermac_cheat1","f_ermac_cheat2","f_smoke_cheat1","f_smoke_cheat2",
                    "f_noob_cheat1","f_noob_cheat2","f_kham_cheat1","f_kham_cheat2"}) do
  FLAGS[#FLAGS+1] = { n = n:gsub("^f_",""):gsub("_cheat", ""), a = s(n) }
end

local GS_PSEL = 4
local cpu, space, frame = nil, nil, 0
local last = { gs = -1, p1s = -1, p2s = -1 }
local pcmin, pcmax, pcrun, fired = nil, nil, 0, false

local function r16(a) return space:read_u16(a) end

local function flagline()
  local t = {}
  for _, f in ipairs(FLAGS) do
    local v = r16(f.a)
    if v ~= 0 then t[#t+1] = string.format("%s=%d", f.n, v) end
  end
  return #t > 0 and table.concat(t, " ") or "(none set)"
end

local function state()
  return string.format("gs=%d p1s=%d p2s=%d p1c=%d p2c=%d", r16(A.gstate),
    r16(A.p1_state), r16(A.p2_state), r16(A.p1_char), r16(A.p2_char))
end

-- ft_* ids that ochar_to_menu cannot index (its table is 12 entries)
local function bad(v) return v > 11 and v ~= 0xffff end


-- ---------------------------------------------------------------- fuzz mode
-- PSEL_FUZZ=1 mashes both players' controls on the select screen, so the
-- re-entry paths (START pressed again by a player who has already confirmed;
-- both players confirming the same mugshot; the select timeout landing inside
-- someone's confirm flash) get exercised without a human at the cabinet.
local FUZZ  = os.getenv("PSEL_FUZZ") == "1"
local SEED  = tonumber(os.getenv("PSEL_SEED") or "1")
local fields, held = {}, {}
local WANT = {"Coin 1","Coin 2","1 Player Start","2 Players Start",
  "P1 Up","P1 Down","P1 Left","P1 Right","P1 High Punch","P1 Low Punch",
  "P1 High Kick","P1 Low Kick","P1 Block",
  "P2 Up","P2 Down","P2 Left","P2 Right","P2 High Punch","P2 Low Punch",
  "P2 High Kick","P2 Low Kick","P2 Block"}

local function cache_inputs()
  for _, port in pairs(manager.machine.ioport.ports) do
    for _, f in pairs(port.fields) do
      for _, n in ipairs(WANT) do if f.name == n then fields[n] = f end end
    end
  end
  local miss = {}
  for _, n in ipairs(WANT) do if not fields[n] then miss[#miss+1] = n end end
  if #miss > 0 then log("MISSING INPUTS: %s", table.concat(miss, ", ")) end
end

local function hold(n, on)
  local f = fields[n]; if not f then return end
  if held[n] ~= on then f:set_value(on and 1 or 0); held[n] = on end
end

-- deterministic xorshift so a hit can be replayed with the same PSEL_SEED
local rng = SEED & 0xffffffff
local function rnd(n)
  rng = rng ~ ((rng << 13) & 0xffffffff); rng = rng ~ (rng >> 17)
  rng = rng ~ ((rng << 5) & 0xffffffff)
  return rng % n
end

local FUZZ_BTN = {"P1 Up","P1 Down","P1 Left","P1 Right","P1 High Punch",
  "P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block","1 Player Start",
  "P2 Up","P2 Down","P2 Left","P2 Right","P2 High Punch","P2 Low Punch",
  "P2 High Kick","P2 Low Kick","P2 Block","2 Players Start"}

local booted = false
local function fuzz_tick(gs)
  -- do not touch the controls until the game has reached attract mode, or a
  -- press during the power-on CMOS check drops it into diagnostics (gs_diag 8)
  if gs == 1 or gs == GS_PSEL then booted = true end
  if not booted then return end
  -- keep credits topped up so START is always live
  hold("Coin 1", frame % 200 < 6)
  hold("Coin 2", frame % 200 >= 100 and frame % 200 < 106)
  if gs ~= GS_PSEL then
    for _, n in ipairs(FUZZ_BTN) do hold(n, false) end
    -- outside select, press both STARTs to get a 2P game going again
    hold("1 Player Start", frame % 90 < 8)
    hold("2 Players Start", frame % 90 >= 40 and frame % 90 < 48)
    return
  end
  -- on the select screen: short random taps, a few at a time
  if frame % 7 == 0 then
    for _, n in ipairs(FUZZ_BTN) do hold(n, false) end
    for _ = 1, 1 + rnd(3) do hold(FUZZ_BTN[1 + rnd(#FUZZ_BTN)], true) end
  end
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    -- the tap handles MUST be kept alive or they are collected and stop firing
    for _, n in ipairs({"p1_char", "p2_char"}) do
      _G["tap_"..n] = space:install_write_tap(A[n], A[n] + 15, "psel_"..n,
        function(off, data, mask)
          local v = data & 0xffff
          log("%7d  %s <= %-5d pc=%08X  %s%s", frame, n, v,
              cpu.state["PC"].value, state(), bad(v) and "   <<< HIDDEN ft_*" or "")
        end)
    end
    log("psel_hang_probe: p1_char=%08x p2_char=%08x  (play the select screen)",
        A.p1_char, A.p2_char)
    return
  end
  if not space or fired then return end

  local gs, p1s, p2s = r16(A.gstate), r16(A.p1_state), r16(A.p2_state)
  if gs ~= last.gs then
    log("%7d  gstate %d -> %d   %s   flags: %s", frame, last.gs, gs, state(), flagline())
    last.gs = gs
  end
  if p1s ~= last.p1s or p2s ~= last.p2s then
    log("%7d  pstate p1 %d->%d  p2 %d->%d   %s", frame, last.p1s, p1s, last.p2s, p2s, state())
    last.p1s, last.p2s = p1s, p2s
  end

  if FUZZ then
    if frame == 2 then cache_inputs(); log("FUZZ seed=%d", SEED) end
    -- arm every hidden unlock so a confirm can commit a hidden ft_*; this is
    -- exactly the state the START tap / Block x5 counters leave behind, and
    -- only MAIN.ASM's *_select_cheat_apply clears them
    if gs == GS_PSEL and frame % 31 == 0 then
      for _, f in ipairs(FLAGS) do
        if f.n == "rain1" or f.n == "rain2" or f.n == "jade1" or f.n == "jade2" then
          space:write_u16(f.a, 1)
        end
      end
    end
    fuzz_tick(gs)
  end

  -- hang detector: in the spin the PC only ever sits on the two loop words
  local pc = cpu.state["PC"].value
  if pcmin and pc >= pcmin - 0x40 and pc <= pcmax + 0x40 then
    if pc < pcmin then pcmin = pc end
    if pc > pcmax then pcmax = pc end
    pcrun = pcrun + 1
  else
    pcmin, pcmax, pcrun = pc, pc, 1
  end
  if pcrun >= 90 and gs == GS_PSEL then
    fired = true
    log("")
    log("*** HANG: pc parked in %08X..%08X for %d frames", pcmin, pcmax, pcrun)
    log("    %s", state())
    log("    flags: %s", flagline())
    local r = {}
    for _, n in ipairs({"PC","SP","A0","A1","A2","A8","A13"}) do
      r[#r+1] = string.format("%s=%08X", n, cpu.state[n].value)
    end
    log("    %s", table.concat(r, " "))
    log("    resolve the pc values above with: python sym_resolve.py <pc>")
  end
end)
