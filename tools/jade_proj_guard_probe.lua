-- jade_proj_guard_probe.lua - where the drone's projectile guard falls out.
--
-- Rides the fly rig as FB_ADDON. bew_incoming_proj (MKDRONE.ASM) is a funnel and
-- proj_guard_debug .set 1 counts each stage into @debug2/3/4:
--
--   debug2  the check RAN at all (past the every-4th-tick throttle)
--   debug3  ...and one of HIS projectiles was in the air (get_his_proj_proc)
--   debug4  ...and it was within proj_guard_dist (060h = 96 px)
--
-- The last stage (ask_mr_diff rpt_proj_guard) has no counter: there is no fourth global
-- debug word free without editing RAM.ASM/MAINEQU, which other sessions have open, and at a
-- pinned difficulty the odds are known anyway (750/1000 at diff 8). "looked" is the stage
-- worth having instead - the first run could not tell "the check never ran" from "it ran and
-- found nothing", and those need opposite fixes.
--
-- Read as a funnel those three separate four plausible causes of the measured
-- defect - Jade's boomerang hits ~50% at difficulty 8 exactly as at 3, flat across
-- the whole rpt_proj_guard 200..750 ramp:
--
--   debug2 low          -> the drone never sees the boomerang (pid / active walk)
--   debug2>>debug3      -> the distance gate rejects it: 96 px sampled every 4th
--                          tick is too coarse for this projectile's speed, or the
--                          test is |dx| so a RECEDING pass is being counted
--   debug3>>debug4      -> the odds are the limit, and raising rpt_proj_guard is
--                          the fix
--   all three high      -> the guard is reached and does not work: block height or
--                          a return pass arriving behind the drone, and no amount
--                          of tuning the odds will help
--
-- Addresses come from the MAP THIS ROM WAS BUILT WITH (FB_MAP), never hardcoded -
-- .bss moves whenever anything ahead of it changes size.
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local sym = {}
do
  local fh = io.open(MAP)
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x+)%s+([%w_]+)") do
        if n == "debug2" or n == "debug3" or n == "debug4" then sym[n] = tonumber(a, 16) end
      end
    end
    fh:close()
  end
end

local cpu = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
-- read_u32 takes the RAW bit address from the map, not addr/8
local function r32(a) return a and space:read_u32(a) or 0 end

-- GROUND TRUTH, independent of the ROM's own counters. The funnel can say the drone looked
-- and found nothing; it cannot say whether there was anything to find. So walk the active
-- process list the same way get_his_proj_proc does and count the frames on which one of HIS
-- projectiles really was live. If projectiles are live far more often than the ROM reports
-- seeing them, the lookup is broken; if the two agree, the boomerang simply is not in the air
-- much and the throttle is the problem instead.
--   active 010b40a0 (map), plink +0 (32), procid +20h (16), pid_proj1 0700h, pid_proj2 0800h
--                                                      (all MAINEQU.ASM)
-- HOW HIGH DOES EACH THROW ACTUALLY FLY?  drone_block_proj does `jsrp do_block_hi` and so
-- always blocks HIGH, and the per-variant hit rates say that is the defect: high boomerang
-- 40/41%, level 53/57%, LOW 59/59%, return 56/54% across two matched runs.  Picking the block
-- height needs a THRESHOLD, and a guessed one is how the last two fixes went wrong - so
-- measure the y each variant flies at, against the drone's own y, before writing the test.
-- oypos is a WORD and y grows DOWNWARD, so a bigger number is lower on screen.
-- oypos is 0b0h, NOT 0x70 - the first cut of this probe used 0x70 and produced a histogram
-- with 83% of samples at y=0 and the rest reading as small negatives, which is what a wrong
-- field offset looks like rather than a finding. oxval 080h / oxpos 090h / oyval 0a0h /
-- oypos 0b0h (DISPEQU.ASM:45-48).
local OYPOS = 0x0b0           -- *obj(oypos): the INTEGER part of y, 16 bits
local yhist = {}              -- bucketed projectile y, 16 px buckets
local ACTIVE = sym.active or 0x010b40a0
local live_f, total_f = 0, 0
local pid_seen = {}
local function proj_live()
  local p = space:read_u32(ACTIVE)
  local n, found = 0, false
  while p ~= 0 and n < 200 do
    local id = space:read_u16(p + 0x20)
    local fam = id & 0xff00
    if fam == 0x0700 or fam == 0x0800 then
      pid_seen[fam] = (pid_seen[fam] or 0) + 1
      found = true
      if fam == 0x0700 then                       -- HIS projectile: log how high it flies
        local ob = space:read_u32(p + 0xc0)       -- pa8 = the proc's object
        if ob ~= 0 then
          local y = space:read_u16(ob + OYPOS)
          local b = (y // 16) * 16
          yhist[b] = (yhist[b] or 0) + 1
        end
      end
    end
    p = space:read_u32(p)      -- plink is offset 0
    n = n + 1
  end
  return found
end

local last = { 0, 0, 0 }
local frame = 0

-- the handle MUST live in a global or the collector takes the notifier at ~frame 300
JPG_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  total_f = total_f + 1
  if proj_live() then live_f = live_f + 1 end
  if frame % 600 ~= 0 then return end
  local d2, d3, d4 = r32(sym.debug2), r32(sym.debug3), r32(sym.debug4)
  if d2 == last[1] and d3 == last[2] and d4 == last[3] then return end
  last = { d2, d3, d4 }
  local fams = {}
  for k, v in pairs(pid_seen) do fams[#fams + 1] = string.format("%04x:%d", k, v) end
  table.sort(fams)
  print(string.format(
    "[projguard] frame %d  looked %d  saw %d (%.1f%% of looks)  in-range %d (%.0f%% of saw)"
    .. "  | GROUND TRUTH: a projectile was live on %.1f%% of frames [%s]",
    frame, d2, d3, d2 > 0 and 100 * d3 / d2 or 0, d4, d3 > 0 and 100 * d4 / d3 or 0,
    total_f > 0 and 100 * live_f / total_f or 0,
    #fams > 0 and table.concat(fams, " ") or "none seen"))
  local ys, n = {}, 0
  for b, c in pairs(yhist) do ys[#ys + 1] = { b, c }; n = n + c end
  table.sort(ys, function(x, y) return x[1] < y[1] end)
  if n > 0 then
    local out = {}
    for _, e in ipairs(ys) do out[#out + 1] = string.format("y%d:%d", e[1], e[2]) end
    -- the drone's own y and ground_y make the numbers mean something: a threshold has to be
    -- expressed relative to the fighter, not as a screen coordinate
    print(string.format("[projguard]   his projectile y (16 px buckets, %d samples): %s",
          n, table.concat(out, " ")))
  end
end)

if not sym.debug2 then
  print("[projguard] debug2/3/4 not in " .. MAP ..
        " - is proj_guard_debug still 0, or is this the wrong map for this ROM?")
else
  print(string.format("[projguard] watching debug2/3/4 at %x/%x/%x",
        sym.debug2, sym.debug3, sym.debug4))
end
