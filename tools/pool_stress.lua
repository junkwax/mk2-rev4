-- Pool occupancy sampled DURING a real scripted battle.
-- Layers on top of battle_stability_sweep.lua, which does the character
-- select / stage setup and drives the fight; both frame_done handlers run.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
dofile(ROOT .. "/tools/battle_stability_sweep.lua")

local sp = manager.machine.devices[":maincpu"].spaces["program"]
local symbols = {}
do local fh = io.open(ROOT.."/src/mk2.map","r")
   for line in fh:lines() do
     for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end
   end
   fh:close()
end
local ACTIVE   = symbols["active"]
local OVERLOAD = symbols["overload"]
local BLOOD    = symbols["blood_count"]
local LISTS    = { symbols["objlst"], symbols["objlst2"], symbols["objlst3"] }
local NOBJ, NPROC = 358, 168

local function walk(head, cap)
  local n, p = 0, sp:read_u32(head)
  while p ~= 0 and n <= cap + 4 do n = n + 1; p = sp:read_u32(p) end
  return n
end

local frames, samples = 0, 0
local pk = { obj=0, proc=0, ov=0, blood=0 }
local ovhist = {}
local label = os.getenv("SWEEP_LABEL") or "battle"

emu.register_frame_done(function()
  frames = frames + 1
  if frames % 2 ~= 0 then return end
  local nobj = walk(LISTS[1],NOBJ) + walk(LISTS[2],NOBJ) + walk(LISTS[3],NOBJ)
  local nproc = walk(ACTIVE,NPROC)
  local ov, bl = sp:read_u16(OVERLOAD), sp:read_u16(BLOOD)
  samples = samples + 1
  ovhist[ov] = (ovhist[ov] or 0) + 1
  if nobj > pk.obj then pk.obj = nobj end
  if nproc > pk.proc then pk.proc = nproc end
  if ov > pk.ov then pk.ov = ov end
  if bl > pk.blood then pk.blood = bl end
  if samples % 250 == 0 then
    local f = assert(io.open(ROOT.."/tools/pool_stress.log","a"))
    f:write(string.format("%-22s samples=%-6d obj_peak=%3d/%d proc_peak=%3d/%d blood_peak=%2d ov_peak=%d",
            label, samples, pk.obj, NOBJ, pk.proc, NPROC, pk.blood, pk.ov))
    local keys={} for k in pairs(ovhist) do keys[#keys+1]=k end table.sort(keys)
    for _,k in ipairs(keys) do f:write(string.format("  ov%d=%.1f%%", k, 100*ovhist[k]/samples)) end
    f:write("\n"); f:close()
  end
end)
