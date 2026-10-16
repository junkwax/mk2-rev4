-- sweep_addon_fuzz.lua - random P1 input + a PROCESS-STACK BOUNDS check.
--
-- Why: a hard lockup was reported from real play (Reptile vs the Noob drone,
-- the PC parked in illegal_opcode's jauc $).  The register dump named the
-- mechanism: a7 held drone_retreat, and `retp` is `mmfm a12,a7 / exgpc a7`,
-- so a7 after a retp is the instruction FOLLOWING it - drone_retreat is the
-- instruction after drone_approach's retp.  a1 held p2_xvel (stop_me had just
-- run) and a3 held 048h (drone_approach's target distance).  So the drone
-- finished a walk and its retp pulled a return address that was not code.
--
-- The process stack lives INSIDE the process block: reset_proc_stack sets
-- a12 = a13+prcsiz and pushes grow DOWN.  Pop one more than was pushed and
-- a12 climbs past prcsiz, so retp reads the next block's link word and jumps
-- into RAM.  MPROC.ASM's prcslp already has exactly this check behind
-- `.if debug`, but it is compiled out and it only sticks on `jrlt $` with no
-- report.  This does the same test from outside, on the shipping ROM, and
-- names the process's wakeup PC so the offending loop is identified.
--
-- The stock sweep passes this matchup: it walks P1 back and forth and presses
-- nothing, so the drone's reaction tree - which dispatches on the opponent's
-- ACTION changing - is barely entered.  So P1 is driven from a seeded PRNG.
-- FUZZ_SEED changes the stream; the ROM's own @rand reseeds identically every
-- round, so varying this is the only way to get a different fight.
--
-- Rename to sweep_addon.lua to arm it.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LABEL = os.getenv("SWEEP_LABEL") or "battle"
local SEED = tonumber(os.getenv("FUZZ_SEED") or "1")
local HOLD = tonumber(os.getenv("FUZZ_HOLD") or "6")   -- ticks per decision
local OUT = ROOT .. "/tools/pstack_watch.txt"

local sym = {}
do
  local fh = io.open(ROOT .. "/src/mk2.map", "r")
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
    end
    fh:close()
  end
end
local gstate, active = sym["gstate"], sym["active"]
if not (gstate and active) then print("[fuzz] no symbols - disabled"); return end

-- MAINEQU.ASM process block layout, in BITS (these are raw map offsets)
local PLINK, PROCID, PSPTR, PWAKE = 0x00, 0x20, 0x40, 0xe0
local PSDATA, PRCSIZ = 0x3d0, 0x6f0

-- drone_approach / drone_retreat loop bodies, from the map.  Both end in
-- `retp`, and both call drone_beware every tick - which is how a second
-- reaction gets dispatched while the first one is still walking in.
local APPROACH_LO = sym["drone_approach"]
local APPROACH_HI = sym["drone_retreat"]
local RETREAT_LO  = sym["drone_retreat"]
local RETREAT_HI  = RETREAT_LO and (RETREAT_LO + 0x100) or nil

-- p_beware_return / p_beware_a10 / p_beware_a11.  MAINEQU.ASM aliases these
-- onto p_joyport / p_butport / p_store6, so the offsets are those slots'.
local P_BEWARE_RETURN = 0x100          -- p_joyport = pdata

local OWNS = _G.ADDON_OWNS
if not OWNS then print("[fuzz] harness did not export ADDON_OWNS - disabled"); return end

local logf = io.open(OUT, "a")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[pstack] " .. l)
  if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local fields, names = {}, {}
local held = {}
local reported = 0
local nested = 0
local last_beware = {}

local st = (SEED * 1103515245 + 12345) & 0x7fffffff
local function rnd(n)
  st = (st * 1103515245 + 12345) & 0x7fffffff
  return (st >> 16) % n
end

-- Bounded walk, like every other list walk here: a list caught mid-edit by a
-- probe that loops until it sees zero hangs MAME instead of reporting.
-- One-shot self-check.  A bounds probe that never fires is indistinguishable
-- from a broken one, so print real psptr values once and let the depths be
-- read: a fighter mid-move is several frames deep, an idle one is at 0.
local selfcheck = false
local function check_stacks(rel)
  local p, n = space:read_u32(active), 0
  if rel == 60 and not selfcheck then
    selfcheck = true
    local q, m = p, 0
    while q ~= 0 and m < 6 do
      m = m + 1
      log("  selfcheck proc=%08x id=%04x psptr=%08x depth=%d", q,
          space:read_u16(q + PROCID), space:read_u32(q + PSPTR),
          (q + PRCSIZ - space:read_u32(q + PSPTR)) // 32)
      q = space:read_u32(q + PLINK)
    end
  end
  while p ~= 0 and n < 200 do
    n = n + 1
    local sp = space:read_u32(p + PSPTR)
    -- THE DOOMED STATE, one or more ticks before the jump into RAM: parked
    -- inside a loop that ends in `retp` with nothing left on the process
    -- stack.  The pop that follows reads the NEXT block's link word.  This
    -- is what the reported lockup looks like from outside, and it is visible
    -- while the game is still running.
    if sp == p + PRCSIZ and APPROACH_LO then
      local wake = space:read_u32(p + PWAKE)
      if (wake >= APPROACH_LO and wake < APPROACH_HI) or
         (wake >= RETREAT_LO and wake < RETREAT_HI) then
        if reported < 8 then
          reported = reported + 1
          log("DOOMED %s rel=%d proc=%08x id=%04x wake=%08x - empty proc stack inside a retp loop",
              LABEL, rel, p, space:read_u16(p + PROCID), wake)
        end
      end
    end
    -- THE PRECONDITION, and it is visible long before anything breaks:
    -- bew_fire stored a NEW p_beware_return while the process stack was
    -- DEEPER than it was for the previous one.  That is a second reaction
    -- dispatched from inside the first one's nested walk, and it has just
    -- overwritten the outer loop's resume address with the inner loop's.
    -- p_beware_return is ALIASED onto p_joyport, which is a live joystick
    -- port slot for every process that is not mid-reaction. So only a value
    -- in ROM is a beware resume address; anything else is the other tenant.
    local br = space:read_u32(p + P_BEWARE_RETURN)
    if br < 0xff800000 then br = 0 end
    local prev = last_beware[p]
    if prev and br ~= 0 and br ~= prev.br and sp < prev.sp then
      if nested < 6 then
        nested = nested + 1
        log("NESTED %s rel=%d proc=%08x outer_return=%08x(depth %d) -> inner=%08x(depth %d)",
            LABEL, rel, p, prev.br, (p + PRCSIZ - prev.sp) // 32,
            br, (p + PRCSIZ - sp) // 32)
      end
    end
    if br ~= 0 then last_beware[p] = { br = br, sp = sp } end

    if sp ~= 0 and (sp > p + PRCSIZ or sp < p + PSDATA) then
      if reported < 8 then
        reported = reported + 1
        log("PSTACK %s rel=%d proc=%08x id=%04x psptr=%08x (%+d from empty) wake=%08x",
            LABEL, rel, p, space:read_u16(p + PROCID), sp,
            (p + PRCSIZ - sp) // 32, space:read_u32(p + PWAKE))
      end
    end
    p = space:read_u32(p + PLINK)
  end
end

emu.register_frame(function()
  frame = frame + 1
  if not space then
    local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
    if not ok or not space then return end
  end
  if next(fields) == nil then
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, fd in pairs(port.fields) do
        if fd.name:sub(1, 3) == "P1 " then
          fields[fd.name] = fd; names[#names + 1] = fd.name; OWNS[fd.name] = true
        end
      end
    end
    table.sort(names)
    log("=== %s seed=%d P1: %s", LABEL, SEED, table.concat(names, ", "))
  end
  if space:read_u16(gstate) ~= 2 then return end
  if fight0 == 0 then fight0 = frame end
  local rel = frame - fight0
  check_stacks(rel)
  if rel < 45 then return end

  if rel % HOLD == 0 then
    held = {}
    local dirs = { "P1 Left", "P1 Right", "P1 Up", "P1 Down" }
    local d = rnd(6)
    if d < 4 then held[dirs[d + 1]] = true end
    for _, b in ipairs({ "P1 High Punch", "P1 Low Punch", "P1 High Kick",
                         "P1 Low Kick", "P1 Block" }) do
      if rnd(5) == 0 then held[b] = true end
    end
  end
  for n, fd in pairs(fields) do fd:set_value(held[n] and 1 or 0) end
end)
