-- drone_proj_guard_log.lua - does the drone's GUARD survive a projectile?
--
-- Rides the fly rig as FB_ADDON and writes <FB_OUT>/drone_proj_guard.csv.
--
-- THE PROXY, and why this one is measurable when the backbreaker A/B was not.
--
-- f6448e95 taught three waiting loops to see a projectile: drone_guard_hold,
-- drone_wait_nonattack and drone_wait_non all asked is_he_attacking, which returns
-- false for every one of the 25 projectile actions (001h..019h are category 0, and
-- is_he_attacking tests for category 0100h). So a drone holding its guard through a
-- string would drop it the moment the human switched to a fireball, and counter
-- straight into it.
--
-- That prediction is directly observable, because a drone inside drone_guard_hold has
-- p_action == act_blockhi (do_block_hi set it before the loop was entered). So:
--
--   sample   = a projectile thrown while the drone's action is a block code
--   pre-fix  = the guard drops within a few ticks and the drone takes a CLEAN hit
--   post-fix = the guard holds and the drone takes CHIP damage instead
--
-- The backbreaker gate (269eb3fe) needed a projectile inside 96px, which the fly's
-- catalogue never throws - 0 samples in both arms after 8,000 decisions. This needs a
-- projectile at ANY range while the drone happens to be blocking, which is common.
--
-- Fields from FB_MAP / DISPEQU / MAINEQU: p1_proc p2_proc p1_obj p2_obj p2_bar,
-- p_action +1f0h (16), oxpos +090h (16).
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local OUT = (os.getenv("FB_OUT") or "C:/tmp/flybrain/play") .. "/drone_proj_guard.csv"
local WINDOW = tonumber(os.getenv("PG_WINDOW") or "150")   -- frames to watch a throw out
local WANT = { p1_proc=1, p2_proc=1, p1_obj=1, p2_obj=1, p2_bar=1, diff=1,
               winner_status=1, gstate=1 }
local sym = {}
do
  local fh = io.open(MAP)
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x+)%s+([%w_]+)") do
        if WANT[n] and not sym[n] then sym[n] = tonumber(a, 16) end
      end
    end
    fh:close()
  end
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return a and space:read_u16(a) or 0 end
local function r32(a) return a and space:read_u32(a) or 0 end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

-- a projectile action: non-zero, and its category (high byte) is 0.  This is
-- is_he_projecting's own test, transcribed.
local function is_proj(a) return a ~= 0 and (a >> 8) == 0 end
-- The drone's WAITING states - the ones the three patched loops are entered in:
--   act_blocks 0700h/0701h   drone_block -> do_block_hi -> drone_guard_hold
--   act_duck   0302h         drone_duck_upcut / drone_post_duck_hit -> drone_wait_nonattack
-- Both are held across the wait, so either one at the moment of a throw means the drone
-- was sitting in a loop the fix reaches.  The raw action is logged as well, so the
-- report can split block from duck rather than take my word for which matters.
local function is_guard(a) return (a >> 8) == 0x07 or a == 0x0302 end

local fh = io.open(OUT, "w")
if fh then
  fh:write("frame,diff,dist,proj,d_act_throw,guard_at_throw,hold,dmg,d_act_at_hit," ..
           "guard_at_hit,outcome\n")
  fh:flush()
end

local frame, prev_fa = 0, 0
local prev_da = 0
local live = {}            -- throws being watched out

PROJ_GUARD_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local dp, fp = r32(sym.p2_proc), r32(sym.p1_proc)
  if dp == 0 or fp == 0 then prev_fa = 0 return end
  local da, fa = r16(dp + 0x1f0), r16(fp + 0x1f0)
  local bar = r16(sym.p2_bar)
  local winner = r16(sym.winner_status)

  -- ---- a new throw -------------------------------------------------------
  -- Only the TRANSITION into a projectile action counts; the action stays set for the
  -- whole cast, so sampling the level would log one throw dozens of times.
  if is_proj(fa) and not is_proj(prev_fa) and winner == 0 then
    local dx = s16(r16(r32(sym.p2_obj) + 0x90))
    local fx = s16(r16(r32(sym.p1_obj) + 0x90))
    live[#live + 1] = { f0 = frame, proj = fa, d0 = da, guard0 = is_guard(da),
                        bar0 = bar, dist = math.abs(dx - fx),
                        hold = is_guard(da) and 0 or -1, holding = is_guard(da) }
  end

  -- ---- watch each live throw out ----------------------------------------
  local keep = {}
  for _, e in ipairs(live) do
    local done = false
    -- how long the guard survived the throw, in frames, counted only while it is
    -- unbroken.  -1 means the drone was never guarding to begin with.
    if e.holding then
      if is_guard(da) then e.hold = e.hold + 1 else e.holding = false end
    end
    -- the bar moving DOWN is the outcome.  The action is read one frame LAGGED,
    -- because a clean hit puts the drone into its reaction before the bar is debited -
    -- reading it live would call every clean hit a non-guard by construction, which is
    -- the answer this rig exists to avoid assuming.
    if bar > e.bar0 or winner ~= 0 then
      -- the round reset under us (bar refilled) or ended: this throw has no clean
      -- outcome, so drop it rather than let a refill read as "no damage".
      done = true
    elseif bar < e.bar0 then
      local dmg = e.bar0 - bar
      local g = is_guard(prev_da)
      if fh then
        fh:write(string.format("%d,%d,%d,%04x,%04x,%d,%d,%d,%04x,%d,%s\n",
          e.f0, r16(sym.diff), e.dist, e.proj, e.d0, e.guard0 and 1 or 0, e.hold,
          dmg, prev_da, g and 1 or 0, g and "BLOCKED" or "HIT"))
        fh:flush()
      end
      done = true
    elseif frame - e.f0 > WINDOW then
      if fh then
        fh:write(string.format("%d,%d,%d,%04x,%04x,%d,%d,0,0000,0,NOCONTACT\n",
          e.f0, r16(sym.diff), e.dist, e.proj, e.d0, e.guard0 and 1 or 0, e.hold))
        fh:flush()
      end
      done = true
    end
    if not done then keep[#keep + 1] = e end
  end
  live = keep

  prev_fa, prev_da = fa, da
end)
