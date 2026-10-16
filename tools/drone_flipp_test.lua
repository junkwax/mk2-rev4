-- drone_flipp_test.lua
-- MEASURE drnflipp (MAINEQU.ASM): the CPU's jump-in can carry a flip PUNCH
-- (Midway's shelved drone_flip_punch, restored as drone_fp_try in MKDRNEW.ASM).
--
-- What has to be true for it to be worth having, each counted separately:
--   1. the CPU actually throws it        (act_flypunch 0201h, off a jump-in)
--   2. it connects                        (the human's bar drops WHILE the CPU
--                                          is in that action, and by how much -
--                                          stk_??flipp is 16, the kick is 26)
--   3. the landing follow-up is taken     (damage in the window after landing,
--                                          and which action dealt it)
-- ...and the A/B that decides it: mean damage per jump-in, punch vs kick.  A
-- punch is 10 less than a kick on its own, so it only earns its place through
-- what follows it.
--
-- AN IDLE OPPONENT PRODUCES NO JUMP-INS.  rt_drone_start is rolled once at
-- round start; after that the CPU's flips come from avoiding projectiles
-- (standard_proj / ochar_avoid_pro).  So the human is Liu Kang throwing high
-- fireballs on a fixed period, as drone_airzap_test.lua's "convert" mode does,
-- and is nudged back when the gap closes so the flip reaction has room.
--
-- A HIT IS A BAR DROP WHILE THE MOVE IS LIVE, WITH THE AMOUNT.  "His bar went
-- down some time after" credits a follow-up jab to the jump-in, which is the
-- fault drone_airzap_test.lua's CONNECTED counter has (every character's
-- "connect" there is exactly 8).
--
-- WHAT THIS RIG CANNOT DO, measured rather than hoped:
--   * JUMP-INS ARE RARE HERE - at most 3 in 20,000 frames - so it proves the
--     move exists, connects for the right amount and is followed up; it does
--     NOT produce enough of them to rank the punch against the kick.  Not one
--     flip KICK came out in any run, so there is no kick baseline at all.
--   * THE MACHINE REBOOTED at fight+9,931 - FIXED 2026-10-04.  drone_kl_escape
--     sat right after dajc_nosk, so every non-Kung-Lao CPU fell into it; a
--     roll that hit popped three return addresses (the dispatcher's among
--     them) and the next RETS jumped to 0.  The same fall-through returned
--     out of the jump-in early, which is why no flip KICK ever showed here.
--     The FAULT dump (write tap on illop_count), DFP_SPWATCH and -TraceAt N
--     are what found it; keep them for the next "reboot".
--   * The follow-up window is 100 frames wide, so its damage can include a
--     later, unrelated hit.  The action names beside it are the evidence.
--
-- DFP_NEG=1 IS THE CONTROL: it zeroes rpt_flip_punch in the loaded ROM - the
-- ten per-difficulty odds, found by their bytes - so the same build must throw
-- NO punches.  That proves the roll gates the move, and its kick-only numbers
-- are the baseline the punch is compared against.  Positive mode requires the
-- table to be present exactly once, so a drnflipp 0 ROM is refused.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("DFP_LOG") or (ROOT .. "/tools/drone_flipp_test.log")
local NEG = (os.getenv("DFP_NEG") or "0") ~= "0"
local DIFF = tonumber(os.getenv("DFP_DIFF") or "9")
local FRAMES = tonumber(os.getenv("DFP_FRAMES") or "9000")
local CHARS = { cage = 2, baraka = 3, shang = 6, raiden = 7, scorpion = 10, kunglao = 0, liukang = 1 }
local CHAR = (os.getenv("DFP_CHAR") or "scorpion"):lower()

local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
  local l = table.concat(t, "\t"); raw(l); if logfh then logfh:write(l, "\n"); logfh:flush() end end
local function log(f, ...) print("[dfp] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))) end

local symbols = {}
local fault_tap = nil
do local fh = io.open(os.getenv("DFP_MAP") or (ROOT .. "/src/mk2.map"), "r")
  if fh then for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
    fh:close() end end

local NEED = {"gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
              "p1_obj", "p2_obj", "p1_proc", "p2_proc", "p1_bar", "p2_bar",
              "p1_bar_view", "p2_bar_view", "winner_status", "diff", "f_freeze_timer", "rand"}
local A, missing = {}, {}
for _, n in ipairs(NEED) do A[n] = symbols[n]; if not A[n] then missing[#missing+1] = n end end
A.battle_num, A.map_position = symbols.battle_num, symbols.map_position

local OXVAL, OXPOS = 0x080, 0x090
local P_ACTION = 0x1f0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG = 1
local ACT_FLYKICK, ACT_FLYPUNCH = 0x0200, 0x0201
local ACT_NAMES = { [0x0101] = "hi punch", [0x0102] = "lo punch", [0x0106] = "SWEEP",
                    [0x0107] = "uppercut", [0x0200] = "fly kick", [0x0201] = "fly punch" }
local FOLLOW_WINDOW = 100   -- frames after the air move ends that count as its follow-up
local FB_PERIOD = 150

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function objx(sym) local o = r32(A[sym]); return o ~= 0 and s16(r16(o + OXPOS)) or nil end

local finished = false
local function finish() if not finished then finished = true; log("finished"); manager.machine:exit() end end
local function refuse(why) log("FAIL drone_flipp: %s", why); finish() end

-- rpt_flip_punch: .word 0,0,100,150,200,250,300,350,400,450 (MKDRNEW.ASM)
local ODDS = {0, 0, 100, 150, 200, 250, 300, 350, 400, 450}
local function locate_odds()
  local reg = manager.machine.memory.regions[":maincpu"]
  if not reg then return nil, "no :maincpu region" end
  local pat = {}
  for _, v in ipairs(ODDS) do pat[#pat+1] = v & 0xff; pat[#pat+1] = (v >> 8) & 0xff end
  local hits = {}
  for i = 0, reg.size - #pat, 2 do
    -- cheap first test: bytes 4..7 are 64 00 96 00
    if reg:read_u8(i + 4) == 0x64 and reg:read_u8(i + 6) == 0x96 then
      local ok = true
      for k = 1, #pat do if reg:read_u8(i + k - 1) ~= pat[k] then ok = false; break end end
      -- THE SAME TEN WORDS EXIST TWICE: MKDRONE.ASM has another odds table
      -- with identical numbers.  Ours is the one directly after code - it
      -- follows `dfpc_no rets`, and RETS is 0960h - where MKDRONE's sits among
      -- other data words.  Without this the control would zero the wrong
      -- table half the time and still look like it had run.
      if ok and i >= 2 and reg:read_u8(i - 2) == 0x60 and reg:read_u8(i - 1) == 0x09 then
        hits[#hits+1] = i
      end
    end
  end
  if #hits ~= 1 then
    return nil, string.format("rpt_flip_punch found %d times, expected exactly 1 - a drnflipp 0"
      .. " ROM has none; refusing rather than measuring a build without the move", #hits)
  end
  return reg, hits[1], #pat
end

-- BISECT SWITCH: DFP_NOLKZ=1 turns `callr no_unlimited_airhits` at the top of
-- ar_lkzap (lkzapair, MKREACT.ASM) into two NOPs in memory.  That is the one
-- other change on the path this rig exercises - a Liu Kang fireball meeting an
-- AIRBORNE opponent - so it has to be possible to take it out without a second
-- build.  Found by ar_lkzap's own signature: the callr (0D3Fh + offset), then
-- x 038000h / y -060000h / gravity 07000h, and 07000h occurs nowhere else.
local function nop_lkzapair()
  local reg = manager.machine.memory.regions[":maincpu"]
  local tail = {0xE0,0x09,0x00,0x80,0x03,0x00, 0xE1,0x09,0x00,0x00,0xFA,0xFF, 0xC2,0x09,0x00,0x70}
  local hits = {}
  for i = 0, reg.size - 24, 2 do
    if reg:read_u8(i) == 0x3F and reg:read_u8(i + 1) == 0x0D then
      local ok = true
      for k = 1, #tail do if reg:read_u8(i + 3 + k) ~= tail[k] then ok = false; break end end
      if ok then hits[#hits+1] = i end
    end
  end
  if #hits ~= 1 then return nil, #hits end
  reg:write_u8(hits[1], 0x00); reg:write_u8(hits[1] + 1, 0x03)   -- NOP = 0300h
  reg:write_u8(hits[1] + 2, 0x00); reg:write_u8(hits[1] + 3, 0x03)
  return hits[1]
end

local function cache()
  local need = {"Coin 1", "1 Player Start", "P1 High Punch", "P1 Right", "P1 Left"}
  local want = {}
  for _, n in ipairs(need) do want[n] = true end
  for _, p in pairs(manager.machine.ioport.ports) do
    for _, fld in pairs(p.fields) do if want[fld.name] then fields[fld.name] = fld end end end
  local miss = {}
  for _, n in ipairs(need) do if not fields[n] then miss[#miss+1] = n end end
  return miss
end

local frame, charsel, confirm_at, fight = 0, 0, 0, 0
local last_gs = nil
local p2_acts, fireballs, p1_prev, gap_sum, gap_n = {}, 0, 0, 0, 0
local pin1, last_reset, resets = nil, 0, 0
local p1_acts = {}
local RESET_GAP, RESET_EVERY = 230, 45
-- THE GAP RESET IS OFF UNLESS ASKED FOR (DFP_GAPRESET=1).  Putting the CPU back
-- out at range raised the jump-in rate, and it also reset the machine: against
-- a CPU Cage 16 frames into the round, and in four of four long runs somewhere
-- between fight+219 and fight+2974.  A rig that crashes the game it is
-- measuring measures nothing, so the default moves nobody.
local NORESET = (os.getenv("DFP_GAPRESET") or "0") == "0"
local NOSTIR = (os.getenv("DFP_NOSTIR") or "0") ~= "0"     -- diagnostic: leave @rand alone
local recent = {}   -- the last distinct (cpu, human) action pairs
local hist = {}     -- the game's own bars / winner_status / PC, last few fight frames
local p1_forward = "R"

local function pressed(name)
  if charsel == 0 then
    if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    return false
  end
  if fight == 0 then
    if name == "P1 High Punch" and confirm_at > 0 then return frame >= confirm_at and frame < confirm_at + 45 end
    return false
  end
  -- Liu Kang's high fireball: Forward, Forward + HP inside 024h ticks.
  local t = (frame - fight) % FB_PERIOD
  if name == (p1_forward == "L" and "P1 Left" or "P1 Right") then return t < 6 or (t >= 12 and t < 18) end
  if name == "P1 High Punch" then return t >= 18 and t < 26 end
  return false
end

-- per-kind tallies
local function tally() return { thrown = 0, hit = 0, hit_dmg = 0, amounts = {}, fu = 0, fu_dmg = 0, fu_acts = {} } end
local T = { [ACT_FLYKICK] = tally(), [ACT_FLYPUNCH] = tally() }
local cur, follow = nil, nil      -- the air move in progress / its follow-up window
local prev_act = 0

-- Score a follow-up window and close it.  Called when it runs out AND when the
-- next jump-in starts inside it, so an early second jump cannot drop the
-- first one's damage unrecorded.
local function close_follow()
  if not follow then return end
  local t = T[follow.kind]
  if follow.dmg > 0 then
    t.fu = t.fu + 1; t.fu_dmg = t.fu_dmg + follow.dmg
    local parts = {}
    for nm, d in pairs(follow.acts) do
      parts[#parts+1] = nm .. " " .. d; t.fu_acts[nm] = (t.fu_acts[nm] or 0) + 1 end
    log("   follow-up after the %s (%s): +%d  [%s]", ACT_NAMES[follow.kind],
        follow.landed and "landed" or "missed", follow.dmg, table.concat(parts, ", "))
  end
  follow = nil
end

-- DFP_SPWATCH=1: the system stack pointer at the end of every frame.  Between
-- frames the dispatcher is idle and SP should sit at one constant; log every
-- change, so a slow drift or a single jump is visible.
local SPWATCH = (os.getenv("DFP_SPWATCH") or "0") ~= "0"
local TRACE_AT = tonumber(os.getenv("DFP_TRACE_AT") or "")
local TRACE_FILE = (os.getenv("DFP_TRACE") or (ROOT .. "/tmp/dfp_trace.log")):gsub("\\", "/")
local last_sp = nil
emu.register_frame(function()
  frame = frame + 1
  -- DFP_TRACE_AT=N (needs -debug, run_drone_flipp_test.ps1 -Trace): an
  -- instruction trace of the CPU from fight+N to the fault, into DFP_TRACE.
  -- The fault is deterministic for a given build and stream, so N can sit a
  -- couple of frames before it and the trace stays small.
  if TRACE_AT and fight > 0 and frame - fight == TRACE_AT then
    -- every line carries SP and the long at the stack top, so the instruction
    -- that pops past the main loop's return address - or writes over it - shows
    pcall(function() manager.machine.debugger:command(string.format(
      'trace "%s",:maincpu,noloop,{tracelog "SP=%%08X TOP=%%08X ",sp,d@0x022FFFA}', TRACE_FILE)) end)
    log("TRACE on at fight+%d -> %s", frame - fight, TRACE_FILE)
  end
  if SPWATCH and fight > 0 then
    local v = 0
    pcall(function() v = manager.machine.devices[":maincpu"].state["SP"].value end)
    if v ~= last_sp then
      log("SP fight+%d %08x (%+d bits)", frame - fight, v, last_sp and (v - last_sp) or 0)
      last_sp = v
    end
  end
  if finished then return end
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    if #missing > 0 then return refuse("missing symbols: " .. table.concat(missing, ",")) end
    if not CHARS[CHAR] then return refuse("unknown DFP_CHAR " .. CHAR) end
    local miss = cache()
    if #miss > 0 then return refuse("missing inputs: " .. table.concat(miss, ",")) end
    local reg, off, n = locate_odds()
    if not reg then return refuse(off) end
    if NEG then
      for k = 0, n - 1 do reg:write_u8(off + k, 0) end
      log("NEGATIVE: zeroed rpt_flip_punch at :maincpu+%x - this build must now throw no punch", off)
    else
      log("move present: rpt_flip_punch at :maincpu+%x", off)
    end
    if (os.getenv("DFP_NOLKZ") or "0") ~= "0" then
      local at, n = nop_lkzapair()
      if not at then return refuse(string.format("DFP_NOLKZ: ar_lkzap's callr found %d times, expected 1", n)) end
      log("BISECT: lkzapair's callr at :maincpu+%x replaced with NOPs", at)
    end
    log("mode=%s cpu=%s diff=%d frames=%d", NEG and "NEGATIVE" or "positive", CHAR, DIFF, FRAMES)
    -- THE "REBOOT" IS illop_recover (MKBUG.ASM): an illegal opcode, an error
    -- trap or any `lockup` reaches `recovery`, which bumps illop_count and
    -- jumps to POWERUP.  Tap that write and dump the CPU as it happens, so
    -- the fault names itself: B14 holds system_lockup's caller, A7 the
    -- return address recovery records, A13 the process that faulted.
    if symbols.illop_count then
      local cpu = manager.machine.devices[":maincpu"]
      local function st(n) local v = 0; pcall(function() v = cpu.state[n].value end); return v end
      fault_tap = space:install_write_tap(symbols.illop_count, symbols.illop_count + 15, "dfp_fault",
        function(offset, data, mask)
          local regs = {}
          for _, n in ipairs({"PC", "SP", "A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8",
                              "A9", "A10", "A11", "A12", "A13", "A14", "B14"}) do
            regs[#regs+1] = string.format("%s=%08x", n, st(n))
          end
          log("FAULT at frame %d (fight+%d): %s", frame, frame - fight, table.concat(regs, " "))
          local a13 = st("A13")
          if a13 ~= 0 then
            pcall(function()
              log("FAULT   a13 proc: procid=%04x pwake=%08x p_action=%04x",
                  space:read_u16(a13 + 0x20), space:read_u32(a13 + 0xe0), space:read_u16(a13 + 0x1f0))
            end)
          end
          -- the system stack, ALIGNED, from 16 longs under the stack top up:
          -- a trap pushes PC then ST, so the faulting PC is in here
          local top = 0x013f72f0; local stk = {}  -- stckst, SYSEQU.ASM
          for k = 16, 1, -1 do pcall(function()
            stk[#stk+1] = string.format("%x:%08x", top - k * 32, space:read_u32(top - k * 32)) end) end
          log("FAULT   stack: %s", table.concat(stk, " "))
          -- every process: a wake address outside the program ROM is the corpse
          if symbols.active then
            local q, n, bad = space:read_u32(symbols.active), 0, {}
            while q ~= 0 and n < 300 do
              local w = space:read_u32(q + 0xe0)
              local line = string.format("%08x id=%04x wake=%08x time=%d", q,
                space:read_u16(q + 0x20), w, space:read_u16(q + 0x30))
              if w < 0xff800000 then bad[#bad+1] = line end
              if n < 80 then log("FAULT   proc %s", line) end
              q = space:read_u32(q); n = n + 1
            end
            log("FAULT   %d processes, %d with a wake address outside ROM: %s", n, #bad, table.concat(bad, " | "))
          end
          if TRACE_AT then pcall(function() manager.machine.debugger:command("trace off") end) end
          fault_tap:remove()          -- the next write is POWERUP's RAM clear
          return data
        end)
      log("fault tap on illop_count at %08x", symbols.illop_count)
    end
  end
  for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end

  local gs = r16(A.gstate)
  if gs == GS_PSEL and charsel == 0 then charsel = frame end
  if charsel > 0 and fight == 0 then
    w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, FT_KANG); w16(A.p2_char, CHARS[CHAR])
    w16(A.curback, 0)
    if A.map_position then w16(A.map_position, 0) end
    if A.battle_num then w16(A.battle_num, 1) end
    if confirm_at == 0 and frame - charsel > 90 then confirm_at = frame end
  end
  if gs == GS_FIGHTING and fight == 0 then
    fight = frame
    log("fight at frame %d (p1=%d human, p2=%d cpu)", frame, r16(A.p1_char), r16(A.p2_char))
    if r16(A.p2_char) ~= CHARS[CHAR] then return refuse("the CPU is not the fighter asked for") end
  end
  if fight == 0 then
    if frame > 6000 then return refuse("never reached a fight") end
    return
  end
  -- SAY SO when the game leaves the fight - a silent early return here read
  -- as "a run in which nothing happened" for 293 emulated seconds.
  if gs ~= last_gs then
    -- What was happening when it left the fight?  The last actions of both men,
    -- so a reset can be tied to a move rather than guessed at.
    local trail = {}
    for i = 1, #recent do trail[#trail+1] = string.format("%04x/%04x", recent[i][1], recent[i][2]) end
    log("gstate %d -> %d at fight+%d  p1_state=%d p2_state=%d  last cpu/human actions: %s",
        last_gs or -1, gs, frame - fight, r16(A.p1_state), r16(A.p2_state), table.concat(trail, " "))
    for i = 1, #hist do log("     before: %s", hist[i]) end
    do local pc = 0
       pcall(function() pc = manager.machine.devices[":maincpu"].state["PC"].value end)
       log("     now: gs=%d pc=%08x", gs, pc) end
    last_gs = gs
  end
  if (frame - fight) % 1800 == 0 then
    log("  .. fight+%d gs=%d kicks=%d punches=%d", frame - fight, gs,
        T[ACT_FLYKICK].thrown, T[ACT_FLYPUNCH].thrown)
  end
  if gs ~= GS_FIGHTING and frame - fight < FRAMES then return end

  -- THE GAME'S OWN VALUES, read before this rig writes over them.  Dumped when
  -- the game leaves the fight, so "why did it leave" is answered from RAM.
  do
    local pc = 0
    pcall(function() pc = manager.machine.devices[":maincpu"].state["PC"].value end)
    -- the build's own guard counters: did the scroll clamp fire (the only way
    -- the Kano-row deletion can execute), did a palette claim fail, did ani2
    -- clip a runaway list, did the DMA queue run late ?
    local g = {}
    for _, n in ipairs({"scroll_fast", "fpal_fail", "ani2_clip", "dmaq_late", "peak_overload"}) do
      g[#g+1] = n .. "=" .. (symbols[n] and tostring(r16(symbols[n])) or "?")
    end
    hist[#hist+1] = string.format("f+%d ws=%d p1bar=%d p2bar=%d rnd=%s pc=%08x  %s", frame - fight,
      r16(A.winner_status), r16(A.p1_bar), r16(A.p2_bar),
      symbols.round_num and tostring(r16(symbols.round_num)) or "?", pc, table.concat(g, " "))
    if #hist > 6 then table.remove(hist, 1) end
  end
  -- hold the fight open: difficulty, the CPU's bar, the clock, the outcome
  w16(A.diff, DIFF)
  w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP); w16(A.p1_bar_view, MAX_HP)
  w16(A.winner_status, 0); w16(A.f_freeze_timer, 1)
  -- stir the RNG, or the whole run is one roll (doc/AI_DRONE.md)
  if not NOSTIR then w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345) & 0xffffffff) end

  -- the human's bar is the measurement: read the drop, THEN refill it
  local drop = MAX_HP - r16(A.p1_bar)
  w16(A.p1_bar, MAX_HP)

  local x1, x2 = objx("p1_obj"), objx("p2_obj")
  if x1 and x2 then p1_forward = (x1 < x2) and "R" or "L" end
  local q = r32(A.p2_proc)
  local act = q ~= 0 and r16(q + P_ACTION) or 0
  -- KEEP THE FLIP REACTION IN RANGE.  standard_proj refuses inside 0b6h, and
  -- left alone the CPU walks to ~100px and sweeps: nudging the human back
  -- only walks him into the wall (measured: mean gap 100, 0 jump-ins, 399
  -- frames of sweep).  So the HUMAN is held where he started, and the CPU is
  -- put back out at RESET_GAP - but only while it is standing in its STANCE
  -- with nothing in progress, and at most once per RESET_EVERY frames.
  -- Pinning the CPU every frame overrides its walk and it never reaches a
  -- decision; a reset between decisions is just the human having backed off.
  local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
  if o1 ~= 0 and o2 ~= 0 and x1 and x2 then
    if not pin1 then pin1 = x1 end
    -- BOTH must be in their stance.  The human was pinned every frame at
    -- first, and a CPU Scorpion's spear then held him in the rope-pull
    -- reaction for the rest of the run (1 fireball in 6000 frames): never
    -- move a man who is in the middle of a move that relocates him.
    local q1r = r32(A.p1_proc)
    local a1r = q1r ~= 0 and r16(q1r + P_ACTION) or 0
    -- NOT IN THE FIRST 120 FRAMES: teleporting the pair as the round opens reset the
    -- machine against a CPU Cage (gstate 2 -> 0 -> attract at fight+16, with the
    -- punch path zeroed too, and not at all with DFP_NORESET) - the rig, not the ROM.
    if not NORESET and frame - fight >= 120
       and act == 0x0303 and (a1r == 0x0303 or a1r == 0) and math.abs(x2 - x1) < 0xc8
       and frame - last_reset >= RESET_EVERY then
      local nx = pin1 + RESET_GAP
      w32(o1 + OXVAL, (pin1 & 0xffff) << 16); w32(o1 + 0x040, 0)
      w32(o2 + OXVAL, (nx & 0xffff) << 16); w32(o2 + 0x040, 0)
      last_reset = frame; resets = resets + 1
    end
  end
  -- what did each of them actually do?  Reported, so "no jump-ins" can be
  -- told apart from "the human never threw anything".
  p2_acts[act] = (p2_acts[act] or 0) + 1
  local q1 = r32(A.p1_proc)
  local act1 = q1 ~= 0 and r16(q1 + P_ACTION) or 0
  if act1 == 0x0003 and p1_prev ~= 0x0003 then fireballs = fireballs + 1 end
  p1_prev = act1
  p1_acts[act1] = (p1_acts[act1] or 0) + 1
  if #recent == 0 or recent[#recent][1] ~= act or recent[#recent][2] ~= act1 then
    recent[#recent+1] = { act, act1 }
    if #recent > 8 then table.remove(recent, 1) end
  end
  if x1 and x2 then gap_sum = gap_sum + math.abs(x2 - x1); gap_n = gap_n + 1 end

  -- an air move starts
  if (act == ACT_FLYKICK or act == ACT_FLYPUNCH) and prev_act ~= act then
    close_follow()
    cur = { kind = act, at = frame, dmg = 0 }
    T[act].thrown = T[act].thrown + 1
  end
  if cur and act == cur.kind then
    if drop > 0 then cur.dmg = cur.dmg + drop end
  elseif cur then
    -- it ended: score the hit, open the follow-up window
    local t = T[cur.kind]
    if cur.dmg > 0 then
      t.hit = t.hit + 1; t.hit_dmg = t.hit_dmg + cur.dmg
      t.amounts[cur.dmg] = (t.amounts[cur.dmg] or 0) + 1
    end
    log("%s #%d  %s%s", ACT_NAMES[cur.kind], t.thrown,
        cur.dmg > 0 and ("CONNECTED for " .. cur.dmg) or "missed",
        cur.dmg > 0 and "" or "")
    follow = { kind = cur.kind, at = frame, dmg = 0, acts = {}, landed = cur.dmg > 0 }
    cur = nil
    if drop > 0 then follow.dmg = follow.dmg + drop end
  elseif follow then
    if drop > 0 then
      follow.dmg = follow.dmg + drop
      local nm = ACT_NAMES[act] or string.format("act %04x", act)
      follow.acts[nm] = (follow.acts[nm] or 0) + drop
    end
    if frame - follow.at >= FOLLOW_WINDOW then close_follow() end
  end
  prev_act = act

  if frame - fight >= FRAMES then
    close_follow()
    local top = {}
    for a, n in pairs(p2_acts) do top[#top+1] = { a, n } end
    table.sort(top, function(x, y) return x[2] > y[2] end)
    local parts = {}
    for i = 1, math.min(#top, 10) do parts[#parts+1] = string.format("%04x:%d", top[i][1], top[i][2]) end
    do
      local tp = {}
      for a, n in pairs(p1_acts) do tp[#tp+1] = { a, n } end
      table.sort(tp, function(x, y) return x[2] > y[2] end)
      local pp = {}
      for i = 1, math.min(#tp, 8) do pp[#pp+1] = string.format("%04x:%d", tp[i][1], tp[i][2]) end
      log("HUMAN actions (frames): %s", table.concat(pp, " "))
    end
    log("HUMAN threw %d fireballs; mean gap %d px; %d gap resets; CPU actions (frames): %s",
        fireballs, gap_n > 0 and gap_sum // gap_n or -1, resets, table.concat(parts, " "))
    for _, k in ipairs({ACT_FLYKICK, ACT_FLYPUNCH}) do
      local t = T[k]
      local am, fa = {}, {}
      for d, n in pairs(t.amounts) do am[#am+1] = n .. "x" .. d end
      for nm, n in pairs(t.fu_acts) do fa[#fa+1] = n .. "x " .. nm end
      log("SUMMARY %-9s thrown=%d connected=%d [%s] follow-ups=%d (+%d) [%s]  mean dmg/jump-in=%.1f",
          ACT_NAMES[k], t.thrown, t.hit, table.concat(am, " "), t.fu, t.fu_dmg, table.concat(fa, ", "),
          t.thrown > 0 and (t.hit_dmg + t.fu_dmg) / t.thrown or 0)
    end
    local P, K = T[ACT_FLYPUNCH], T[ACT_FLYKICK]
    if NEG then
      if P.thrown == 0 and K.thrown >= 2 then
        log("PASS drone_flipp CONTROL: odds zeroed -> %d jump-ins, every one a kick", K.thrown)
      elseif P.thrown > 0 then
        log("FAIL drone_flipp CONTROL: %d punch(es) with the odds zeroed - the roll does not gate it", P.thrown)
      else
        log("NO VERDICT drone_flipp CONTROL: only %d jump-in(s) in the run", K.thrown)
      end
    elseif P.thrown < 2 then
      log("NO VERDICT drone_flipp: only %d punch jump-in(s) of %d - run longer", P.thrown, P.thrown + K.thrown)
    else
      log("PASS drone_flipp: the CPU threw %d punch and %d kick jump-ins", P.thrown, K.thrown)
    end
    return finish()
  end
end)
