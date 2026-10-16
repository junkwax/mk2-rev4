-- drone_shoruken_guard_log.lua - does the drone's duck actually GUARD the shoruken?
--
-- Rides the fly rig as FB_ADDON and writes <FB_OUT>/drone_shoruken.csv.
--
-- THE BUG (drnshoru, MAINEQU.ASM).  av_shoruken (MKDRONE.ASM) means to mark itself
-- blocking - its comment says "in case Im hit" - but it loads act_blocklo into A0 and
-- writes p_action itself, then calls drone_duck_act, whose FIRST instruction is
-- `move a1,*a13(p_action),w`.  A1 still holds what c_shoruken put there: act_shoruken,
-- 0206h.  So the guard is overwritten by the attacker's OWN move code, and since
-- is_he_blocking answers a drone off p_action alone, the drone ducks the shoruken
-- deliberately and then takes it clean.  Midway's bug - byte-identical in the retail
-- tree.
--
-- WHY THIS IS A DIRECT PROOF AND NOT A PROXY.  The defect has a signature that cannot
-- occur any other way: the DRONE's p_action equal to 0206h, the move the OTHER man is
-- doing.  So this rig does not have to argue from damage rates at all -
--
--   retail (drnshoru 0) : the drone shows 0206h during its duck
--   fixed  (drnshoru 1) : the drone shows 0701h (act_blocklo) instead
--
-- and the damage is logged alongside as the consequence, not as the evidence.
--
-- Force the fly to Cage (FB_CHARS=2) and to throw the move (FB_PATTERN=jc_shoruken,
-- which needs -NoLearn - a learner fed a forced choice learns the forcing).
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local OUT = (os.getenv("FB_OUT") or "C:/tmp/flybrain/play") .. "/drone_shoruken.csv"
local WINDOW = tonumber(os.getenv("SH_WINDOW") or "90")
local ACT_SHORUKEN, ACT_BLOCKLO, ACT_BLOCKHI = 0x0206, 0x0701, 0x0700
local WANT = { p1_proc=1, p2_proc=1, p1_obj=1, p2_obj=1, p2_bar=1, diff=1,
               winner_status=1 }
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

local fh = io.open(OUT, "w")
if fh then
  fh:write("frame,diff,dist,saw_0206,saw_blocklo,saw_blockhi,dmg,drone_acts\n")
  fh:flush()
end

local frame, prev_fa = 0, 0
local ev = nil

SHORU_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local dp, fp = r32(sym.p2_proc), r32(sym.p1_proc)
  if dp == 0 or fp == 0 then prev_fa = 0 return end
  local da, fa = r16(dp + 0x1f0), r16(fp + 0x1f0)
  local bar = r16(sym.p2_bar)

  -- a new shoruken: only the TRANSITION counts, the action stays set for the whole move
  if fa == ACT_SHORUKEN and prev_fa ~= ACT_SHORUKEN and r16(sym.winner_status) == 0
     and not ev then
    local dx = s16(r16(r32(sym.p2_obj) + 0x90))
    local fx = s16(r16(r32(sym.p1_obj) + 0x90))
    ev = { f0 = frame, bar0 = bar, dist = math.abs(dx - fx),
           seen = {}, order = {}, n206 = 0, nlo = 0, nhi = 0 }
  end

  if ev then
    -- record the drone's own action each frame, de-duplicated but in order, so the CSV
    -- shows the sequence it actually went through rather than a count
    if not ev.seen[da] then
      ev.seen[da] = true
      ev.order[#ev.order + 1] = string.format("%04x", da)
    end
    if da == ACT_SHORUKEN then ev.n206 = ev.n206 + 1 end
    if da == ACT_BLOCKLO then ev.nlo = ev.nlo + 1 end
    if da == ACT_BLOCKHI then ev.nhi = ev.nhi + 1 end
    if frame - ev.f0 >= WINDOW then
      local dmg = ev.bar0 - bar
      if dmg < 0 then dmg = 0 end            -- round reset refilled the bar
      if fh then
        fh:write(string.format("%d,%d,%d,%d,%d,%d,%d,%s\n", ev.f0, r16(sym.diff),
          ev.dist, ev.n206, ev.nlo, ev.nhi, dmg, table.concat(ev.order, "|")))
        fh:flush()
      end
      ev = nil
    end
  end
  prev_fa = fa
end)
