-- gstate5_probe.lua - catch the post-round freeze IN THE ACT.
--
-- A round ends, the game goes gstate 2 -> 5, and then never leaves (normal is
-- ~3 s). The fly rig's crash ring only records FIGHT frames, so it shows the
-- knockout and not the park. This samples DURING the park: every live process,
-- the address each one is asleep at, and the handful of variables the post-round
-- path (bonus_count / end_of_match_chores, MAIN.ASM) actually waits on.
--
-- Rides along with any rig that drives a fight - it only watches:
--   G5_LOG   where to write (default tools/gstate5_probe.txt)
--   G5_MAP   mk2.map to resolve addresses with (default src/mk2.map)
--   G5_HOLD  frames in gstate 5 before it calls it a freeze (default 400, ~7 s)
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("G5_LOG") or (ROOT .. "/tools/gstate5_probe.txt")
-- 400 was too tight: a match-winning round plus its victory sequence measured 422-458
-- frames and recovered, so three healthy rounds were reported as freezes.
local HOLD = tonumber(os.getenv("G5_HOLD") or "700")

local sym, addr = {}, {}
for line in io.lines(os.getenv("G5_MAP") or (ROOT .. "/src/mk2.map")) do
  for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
    sym[n] = tonumber(a, 16)
    addr[#addr + 1] = { tonumber(a, 16), n }
  end
end
table.sort(addr, function(x, y) return x[1] < y[1] end)
-- nearest symbol at or below an address: the map has only globals, so a parked
-- process usually reads as "<global> + N"
local function name_of(a)
  if a == 0 then return "0" end
  local lo, hi = 1, #addr
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if addr[mid][1] <= a then lo = mid else hi = mid - 1 end
  end
  local s = addr[lo]
  if not s or a - s[1] > 0x40000 then return string.format("%08x", a) end
  return string.format("%s+%x", s[2], a - s[1])
end

local out = io.open(LOG, "w")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[g5] " .. l); out:write(l .. "\n"); out:flush()
end

local P = { plink = 0x000, procid = 0x20, ptime = 0x30, psptr = 0x40, pwake = 0xe0 }
local space, frame, in5, dumps, last_gs = nil, 0, 0, 0, -1
local lost_s, lost_k, lost_m = 0, 0, 0
local ANY = os.getenv("G5_ANY") == "1"
local ANY_HOLD = tonumber(os.getenv("G5_ANY_HOLD") or "900")   -- ~16 s of nothing moving
local last_sig, still = nil, 0
local bad_gs = 0        -- consecutive frames with an out-of-range gstate

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end

local function dump(why)
  dumps = dumps + 1
  log("=== %s at frame %d (gstate 5 for %d frames) ===", why, frame, in5)
  local names = { "winner_status", "round_num", "battle_num", "p1_matchw", "p2_matchw", "p1_bar", "p2_bar",
                  "p1_state", "p2_state", "f_fatal_lock", "f_thatsall", "curback", "tick", "timer",
                  "overload", "peak_overload", "f_soul_silent", "f_ksr_quiet", "gstate" }
  local parts = {}
  for _, n in ipairs(names) do
    if sym[n] then parts[#parts + 1] = string.format("%s=%d", n, r16(sym[n])) end
  end
  log("  state: %s", table.concat(parts, " "))
  -- every live process: who it is and where it is asleep
  local p, n = r32(sym.active), 0
  while p ~= 0 and n < 80 do
    log("  proc %2d  pid %04x  sleep %5d  parked at %s", n, r16(p + P.procid), r16(p + P.ptime),
        name_of(r32(p + P.pwake)))
    p = r32(p + P.plink); n = n + 1
  end
  log("  %d live processes; free list %s", n, r32(sym.free) ~= 0 and "not empty" or "EMPTY")
  local ok, pc = pcall(function() return manager.machine.devices[":maincpu"].state["PC"].value end)
  if ok then log("  cpu PC = %s", name_of(pc)) end
  -- A trap (illegal opcode, divide by zero) pushes the FAULTING address and the status
  -- word on the system stack, and MKBUG's handler is `jauc $` - a deliberate infinite
  -- loop, so any trap is a permanent freeze. Read what it pushed: that address names the
  -- code that ran off, which is the thing to fix.
  local ok2, sp = pcall(function() return manager.machine.devices[":maincpu"].state["SP"].value end)
  if ok2 and sp and sp ~= 0 then
    local parts = {}
    for k = 0, 5 do
      local w = r32(sp + k * 32)
      parts[#parts + 1] = string.format("%s", name_of(w))
    end
    log("  stack at SP %08x: %s", sp, table.concat(parts, " | "))
  end
end

emu.register_frame(function()
  frame = frame + 1
  if not space then
    local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
    if not ok or not space then return end
    log("gstate-5 probe armed (freeze = %d frames in gstate 5)", HOLD)
  end
  -- proclock_fix (MPROC.ASM): every stray kill the game SURVIVED instead of freezing
  if sym.sucide_lost and sym.kill_lost then
    local sl, kl = r16(sym.sucide_lost), r16(sym.kill_lost)
    local mc = (sym.mpart_clip and r16(sym.mpart_clip) or 0)
            + 100 * (sym.palfree_bad and r16(sym.palfree_bad) or 0)
            + 10000 * (sym.illop_count and r16(sym.illop_count) or 0)
            + 1000000 * (sym.delobj_lost and r16(sym.delobj_lost) or 0)
            + 100000000 * (sym.scroll_fast and r16(sym.scroll_fast) or 0)
    if sl ~= (lost_s or 0) or kl ~= (lost_k or 0) or mc ~= (lost_m or 0) then
      log("guard fired at frame %d: sucide_lost=%d kill_lost=%d clip/palfree/illop/delobj/scroll=%d (gstate %d)", frame, sl, kl, mc,
          r16(sym.gstate))
      lost_s, lost_k, lost_m = sl, kl, mc
    end
  end
  local gs = r16(sym.gstate)
  if gs ~= last_gs then
    if last_gs == 5 and in5 > 0 then log("gstate 5 lasted %d frames -> %d (frame %d)", in5, gs, frame) end
    last_gs, in5 = gs, 0
  end
  -- G5_ANY=1: also watch for a hang in ANY state, which is what the mid-fight wedge in
  -- Kahn's Arena is (the rig calls it "nothing changed for 1641 frames in gstate 2").
  -- The signature is the things that always move in a live game; when none of them has
  -- moved for G5_ANY_HOLD frames, dump the same way.
  -- A FINISHER IS NOT A HANG. Kahn's soul rip (winner_status 5) holds the victim still for
  -- 20+ seconds by design - health, positions and round all stop, which is exactly what the
  -- test below looks for. Same for a finisher in progress (f_fatal_lock).
  -- An ILLEGAL gstate is corruption, and it must be reported INSTANTLY rather than
  -- waited out: gs_amode..gs_sec_intro are 001h..00fh (MAINEQU.ASM) plus 0 at power-on,
  -- so anything above 00fh is a clobbered state word. This is the documented Kung Lao
  -- match signature (gstate 2 -> 65535, reference_kahn_ladder_kunglao_flake) and it is
  -- also what "both fighters gone and the background half-drawn" looks like.
  --
  -- It bypasses `busy` ON PURPOSE. Once RAM is being clobbered, winner_status and
  -- f_fatal_lock are no more trustworthy than gstate - a garbage winner_status of 3 or
  -- more would suppress the dump for the one fault the dump exists to catch.
  if gs > 0x00f then
    bad_gs = bad_gs + 1
    if bad_gs == 1 or bad_gs % 550 == 0 then
      log("ILLEGAL gstate %d (%04xh) at frame %d - state word clobbered", gs, gs, frame)
      dump(string.format("ILLEGAL gstate %04xh", gs))
    end
    return
  end
  bad_gs = 0
  local busy = (sym.winner_status and r16(sym.winner_status) >= 3)
             or (sym.f_fatal_lock and r16(sym.f_fatal_lock) ~= 0)
  -- ONLY WATCH THE IN-MATCH STATES. Attract mode parks legitimately - both bars read
  -- 0, round_num 0 and nothing in the signature moves while the title/coin pages cycle -
  -- so watching every state reported a freeze at frame 961 of a perfectly healthy run.
  -- A session that sits in attract between games would bury the real dump in noise.
  -- gs_fighting 2, gs_bonus 5, gs_pfsetup 6, gs_round_intro 7, gs_pitfall 9 (MAINEQU.ASM)
  -- are where a round lives and where every freeze in this family has been seen.
  local in_match = (gs == 2) or (gs == 5) or (gs == 6) or (gs == 7) or (gs == 9)
  if not in_match then last_sig, still = nil, 0 end
  if ANY and in_match and not busy then
    -- NOT the tick: the game's clock keeps counting through every one of these
    -- wedges (that is how the post-round freeze looked too). What stops is the
    -- fighters: their health, their positions, and the round they are in.
    local o1, o2 = r32(sym.p1_obj), r32(sym.p2_obj)
    local sig = string.format("%d/%d/%d/%d/%d/%d", gs, r16(sym.p1_bar), r16(sym.p2_bar),
      r16(sym.round_num), o1 ~= 0 and r16(o1 + 0x090) or 0, o2 ~= 0 and r16(o2 + 0x090) or 0)
    if sig ~= last_sig then last_sig, still = sig, 0 else still = still + 1 end
    -- dump again every 10 s while it is still stuck: one PC sample cannot tell a loop
    -- from a process that merely happened to be running when the sample was taken
    if still == ANY_HOLD or (still > ANY_HOLD and (still - ANY_HOLD) % 550 == 0) then
      dump(string.format("%s in gstate %d", still == ANY_HOLD and "STUCK" or "still stuck", gs))
    end
  end
  if gs ~= 5 then return end
  in5 = in5 + 1
  -- the first dump the moment it is clearly stuck, then every 10 s so a state
  -- that IS changing (a counter ticking down) can be told from one that is not
  if in5 == HOLD or (in5 > HOLD and (in5 - HOLD) % 550 == 0) then dump(in5 == HOLD and "FROZEN" or "still frozen") end
end)

emu.register_stop(function()
  log("probe done: %d freeze dumps", dumps)
end)
