-- Pool-occupancy + frame-overrun probe.
--
-- Caps (DISPEQU.ASM / MAINEQU.ASM, both stock Midway values):
--   nobj  = 358 display objects        (qdma silently DROPS a sprite when the
--   nproc = 168 processes               dma queue is full - MKDISP.ASM:1698)
--   dmaq  = 358 cells of bqcell=0xA0 bits, grows DOWN from dmaq+qsize
--
-- MKDISP .bss addresses derived from the map (MKDISP.OBJ .bss @ 0x01045010,
-- length 0x53950 - the layout arithmetic reproduces that exactly).
-- Addressing: raw TMS bit addresses, NOT bit//8, for this MAME build.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]

local OVERLOAD  = 0x0109f720
local ACTIVE    = 0x0109f6c0
local OBJLST    = { 0x010ea580, 0x010ea5a0, 0x010ea5c0 }
local DMAQCUR   = 0x0105C710
local DMAQ_TOP  = 0x0106A700          -- dmaq + qsize, where dmaqcur starts
local BQCELL    = 0xA0

local NOBJ, NPROC = 358, 168
local logpath = os.getenv("POOL_LOG") or "tools/pool_probe.log"

local function walk(head, cap)
  local n, p = 0, sp:read_u32(head)
  while p ~= 0 and n <= cap + 4 do
    n = n + 1
    p = sp:read_u32(p)
  end
  return n
end

local frames, samples = 0, 0
local pk = { obj = 0, proc = 0, q = 0, ov = 0 }
local sum = { obj = 0, proc = 0, q = 0 }

local function dump(tag)
  local f = assert(io.open(logpath, "w"))
  f:write(string.format("%s samples=%d\n", tag, samples))
  f:write(string.format("  objects   peak %3d / %3d  (%4.1f%%)   mean %5.1f\n",
          pk.obj, NOBJ, 100*pk.obj/NOBJ, sum.obj/math.max(samples,1)))
  f:write(string.format("  processes peak %3d / %3d  (%4.1f%%)   mean %5.1f\n",
          pk.proc, NPROC, 100*pk.proc/NPROC, sum.proc/math.max(samples,1)))
  f:write(string.format("  dma queue peak %3d / %3d  (%4.1f%%)   mean %5.1f\n",
          pk.q, NOBJ, 100*pk.q/NOBJ, sum.q/math.max(samples,1)))
  f:write(string.format("  overload  peak %3d        (2 = no frame overrun)\n", pk.ov))
  f:close()
end

emu.register_frame_done(function()
  frames = frames + 1
  if frames <= 300 or frames % 2 ~= 0 then return end
  local nobj = walk(OBJLST[1], NOBJ) + walk(OBJLST[2], NOBJ) + walk(OBJLST[3], NOBJ)
  local nproc = walk(ACTIVE, NPROC)
  local cur = sp:read_u32(DMAQCUR)
  local q = (cur > 0 and cur <= DMAQ_TOP) and ((DMAQ_TOP - cur) // BQCELL) or 0
  local ov = sp:read_u16(OVERLOAD)
  samples = samples + 1
  sum.obj = sum.obj + nobj; sum.proc = sum.proc + nproc; sum.q = sum.q + q
  if nobj > pk.obj then pk.obj = nobj end
  if nproc > pk.proc then pk.proc = nproc end
  if q > pk.q then pk.q = q end
  if ov > pk.ov then pk.ov = ov end
  if samples % 1500 == 0 then
    print(string.format("[pool] f=%d obj=%d/%d proc=%d/%d q=%d ov=%d", frames, nobj, pk.obj, nproc, pk.proc, q, ov))
    dump("partial")
  end
end)
