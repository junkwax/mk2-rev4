-- Combat stress harness.
--
-- The battle stability sweep gets to a fight but leaves both fighters idle
-- (its own log shows objs=2, hp 161/161 for the whole window), so it never
-- measured a busy scene.  This layers on top of it: it drives P1 through a
-- continuous attack pattern, keeps both health bars topped up so the round
-- never ends, and reports the load.
--
-- peak_overload and qdma_drops are latched BY THE ROM (MPROC.ASM), so the
-- peak cannot be missed between samples the way a Lua-side sampler misses it.
-- Object/process counts are still sampled, since those are not latched.
--
-- Addressing: raw TMS bit addresses out of mk2.map, no >>3 (see
-- battle_stability_sweep.lua, which does the same).
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
local S = setmetatable({}, {__index=function(_,k)
  local v = symbols[k]; if not v then error("missing symbol "..k) end; return v end})

local NOBJ, NPROC, MAX_HP = 358, 168, 0xA1
local LABEL = os.getenv("SWEEP_LABEL") or "stress"
local LOG   = os.getenv("PERF_LOG") or (ROOT .. "/tools/perf_stress.log")

-- ROM-latched counters beyond peak_overload/qdma_drops (tools/run_runtime_budget.py
-- reads these).  Optional: an older map without them logs "na".
local function rom16(name)
  local a = symbols[name]
  return a and tostring(sp:read_u16(a)) or "na"
end

-- P1 buttons.  Cached separately from the sweep's own set and written AFTER
-- its handler each frame, so ours win.
local BTN = {"P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick",
             "P1 Block","P1 Left","P1 Right","P1 Up","P1 Down"}
local f2 = {}
local function cache()
  if next(f2) then return end
  local want = {}; for _,n in ipairs(BTN) do want[n]=true end
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,fl in pairs(port.fields) do if want[fl.name] then f2[fl.name]=fl end end
  end
end

local seed = 12345
local function rnd(n) seed = (seed*1103515245 + 12345) & 0x7fffffff; return seed % n end

local function walk(head, cap)
  local n,p = 0, sp:read_u32(head)
  while p ~= 0 and n <= cap+4 do n=n+1; p=sp:read_u32(p) end
  return n
end

local frame, samples = 0, 0
-- PERF_POKE="sym=value,...": written every frame (an A/B on one ROM)
local POKES = {}
for kv in (os.getenv("PERF_POKE") or ""):gmatch("[^,]+") do
  local n, v = kv:match("^%s*([%w_]+)=(%-?%d+)%s*$")
  if n and symbols[n] then POKES[#POKES + 1] = {symbols[n], tonumber(v)} end
end
-- the line sky (sky_rows): blits and lines queued, fight-only means
local skr_bs, skr_ls, skr_n = 0, 0, 0
-- CPU meter (MPROC.ASM cpumeter): raster lines per process pass.  The ROM's
-- sums run from power-on, so the fight's share is taken from the first
-- fighting frame; cpu_busy is sampled every frame for a fight-only peak.
local cpu_b_sum, cpu_b_n, cpu_pk = nil, nil, 0
-- DISPLAY METER (MKINIT dirq / MKDISP shadow block + drain point): per-frame
-- lines for dqi (dirq), dqs (shadow block), dqd (dirq start -> queue empty).
-- Fight-only means from base sums; peaks sampled from *_last every frame.
local DQ = {"dqi", "dqs", "dqd"}
local dq_b, dq_pk = nil, {dqi = 0, dqs = 0, dqd = 0}
-- queued blits per frame: last_dmaq is the frame's object-queue depth in
-- WORDS, six to a cell (MPROC/MKDISP).  Sampled every fighting frame.
local blit_sum, blit_n, blit_pk = 0, 0, 0
local function dq_str()
  if not (symbols.dqi_sum and dq_b) then return "dq=na" end
  local t = {}
  for _, k in ipairs(DQ) do
    local ds = sp:read_u32(symbols[k .. "_sum"]) - dq_b[k][1]
    local dn = sp:read_u32(symbols[k .. "_n"]) - dq_b[k][2]
    t[#t + 1] = string.format("%s=%.1f/%d", k, dn > 0 and ds / dn or 0, dq_pk[k])
  end
  if blit_n > 0 then t[#t + 1] = string.format("blits=%.1f/%d", blit_sum / blit_n, blit_pk) end
  if skr_n > 0 then t[#t + 1] = string.format("skr=%.1f/%.1f", skr_bs / skr_n, skr_ls / skr_n) end
  return table.concat(t, " ")
end
local function cpu_str()
  if not (symbols.cpu_sum and cpu_b_sum) then return "cpu=na" end
  local ds = sp:read_u32(symbols.cpu_sum) - cpu_b_sum
  local dn = sp:read_u32(symbols.cpu_frames) - cpu_b_n
  if dn <= 0 then return "cpu=na" end
  return string.format("cpu=%.1f%% cpu_peak=%d", 100.0 * ds / (dn * 289), cpu_pk)
end
local pk = {obj=0, proc=0, blood=0}
local hold = {}

emu.register_frame_done(function()
  frame = frame + 1
  cache()
  local fighting = sp:read_u16(S.p1_bar) > 0 and sp:read_u16(S.p2_bar) > 0

  for _, pk in ipairs(POKES) do sp:write_u16(pk[1], pk[2] & 0xffff) end
  if fighting then
    if symbols.skr_blits then
      skr_bs = skr_bs + sp:read_u16(symbols.skr_blits)
      skr_ls = skr_ls + sp:read_u16(symbols.skr_lines)
      skr_n = skr_n + 1
    end
    if symbols.cpu_sum then
      if not cpu_b_sum then
        cpu_b_sum, cpu_b_n = sp:read_u32(symbols.cpu_sum), sp:read_u32(symbols.cpu_frames)
      end
      local b = sp:read_u16(symbols.cpu_busy); if b > cpu_pk then cpu_pk = b end
    end
    if symbols.dqi_sum then
      if not dq_b then
        dq_b = {}
        for _, n in ipairs(DQ) do dq_b[n] = {sp:read_u32(symbols[n .. "_sum"]), sp:read_u32(symbols[n .. "_n"])} end
      end
      for _, n in ipairs(DQ) do
        local v = sp:read_u16(symbols[n .. "_last"]); if v > dq_pk[n] then dq_pk[n] = v end
      end
      if symbols.last_dmaq then
        local c = (sp:read_u16(symbols.last_dmaq) + 5) // 6
        blit_sum, blit_n = blit_sum + c, blit_n + 1
        if c > blit_pk then blit_pk = c end
      end
    end
    -- top both bars up so the round never ends and the fight keeps generating
    -- hits, blood and reaction objects for the whole window
    if frame % 30 == 0 then
      sp:write_u16(S.p1_bar, MAX_HP); sp:write_u16(S.p2_bar, MAX_HP)
    end
    -- re-roll the held inputs every 12 frames: one direction + one attack
    if frame % 12 == 0 then
      hold = {}
      hold[BTN[rnd(4)+1]] = true                       -- an attack button
      local d = rnd(4); if d < 3 then hold[BTN[6+d]] = true end  -- left/right/up
      if rnd(6) == 0 then hold["P1 Block"] = true end
    end
    for n,fl in pairs(f2) do fl:set_value(hold[n] and 1 or 0) end

    if frame % 2 == 0 then
      local nobj = walk(S.objlst,NOBJ) + walk(S.objlst2,NOBJ) + walk(S.objlst3,NOBJ)
      local nproc = walk(S.active,NPROC)
      local bl = sp:read_u16(S.blood_count)
      samples = samples + 1
      if nobj > pk.obj then pk.obj = nobj end
      if nproc > pk.proc then pk.proc = nproc end
      if bl > pk.blood then pk.blood = bl end
    end
  end

  if frame % 600 == 0 and samples > 0 then
    local f = assert(io.open(LOG,"a"))
    f:write(string.format(
      "%-20s f=%-6d samples=%-6d obj=%3d/%d proc=%3d/%d blood=%2d/64  ROM: peak_overload=%d qdma_drops=%d deep_dmaq=%s dmaq_over=%s dmaq_late=%s dmaq_lost=%s palq_drops=%s %s %s\n",
      LABEL, frame, samples, pk.obj, NOBJ, pk.proc, NPROC, pk.blood,
      sp:read_u16(S.peak_overload), sp:read_u16(S.qdma_drops),
      rom16("deep_dmaq"), rom16("dmaq_over"), rom16("dmaq_late"), rom16("dmaq_lost"), rom16("palq_drops"), cpu_str(), dq_str()))
    f:close()
  end
end)
