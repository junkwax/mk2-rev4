-- hidden_fighters_adj_test.lua : the HIDDEN FIGHTERS operator adjustment, end
-- to end.
--
--   service menu -> gen_adj -> put_adj -> cmos -> soft reset -> dipinit
--   -> get_adj(adj_hidlock) -> f_jade_unlocked / f_ermac_unlocked /
--   f_rain_unlocked
--
-- Same shape as adj_toast_roundtrip.lua.  The value is a LOCK mask (bit 0
-- Jade, 1 Ermac, 2 Rain) and the menu starts on 0 (all pickable) on a fresh
-- cmos, so HF_STEPS Up presses land on mask HF_STEPS (negative = Down
-- presses, which wrap: -1 is 7, nobody).
--
-- Run it against a PRIVATE nvram directory.  On exit MAME saves the cmos it
-- left there, so a second rig (ermac_start_toggle_test.lua) can boot on the
-- setting and prove the select screen honours it.
--
--   HF_STEPS   signed Up count (default 4 = Rain locked)
--   HF_LOG     log path
--   MK2_ROOT   tree whose src/mk2.map matches the ROM
--
-- MAME RE-RUNS an autoboot script on soft_reset.  Without this guard the
-- second copy reopens (truncates) the log and registers a second set of
-- callbacks, whose own "BEFORE" check then reads the LOCKED flags and FAILs
-- the run if it gets there first.
if _G.HF_LOADED then return end
_G.HF_LOADED = true
local ROOT  = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local STEPS = tonumber(os.getenv("HF_STEPS") or "4")
local LOG   = os.getenv("HF_LOG") or (ROOT.."/tools/hidden_fighters_adj_test.log")
local logfh = io.open(LOG,"w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[hf] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local A = { gstate=symbols["gstate"], jade=symbols["f_jade_unlocked"],
            ermac=symbols["f_ermac_unlocked"], rain=symbols["f_rain_unlocked"] }
for k,v in pairs(A) do if not v then log("FATAL: %s not in mk2.map", k) end end

local MASK = STEPS % 8
local WANT = { jade = (MASK & 1)==0 and 1 or 0, ermac = (MASK & 2)==0 and 1 or 0,
               rain = (MASK & 4)==0 and 1 or 0 }
log("TEST steps=%d -> mask %d; expect jade=%d ermac=%d rain=%d", STEPS, MASK, WANT.jade, WANT.ermac, WANT.rain)

local space, fields, testsw = nil, {}, nil
local function attach()
  space = manager.machine.devices[":maincpu"].spaces["program"]
  local want={["P1 Up"]=1,["P1 Down"]=1,["P1 High Punch"]=1,["UI Select"]=1}
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(port.fields) do
      if want[f.name] then fields[f.name]=f end
      if f.name=="Test Switch" then testsw=f end end end
  if not testsw then log("FATAL: no Test Switch field") end
end
local held={}
local function tap(n,fr) held[n]=fr end
local function flags() return space:read_u16(A.jade), space:read_u16(A.ermac), space:read_u16(A.rain) end

local frame, t0, phase, resetat, done = 0, nil, "boot", nil, false
local function finish(v, f, ...) if done then return end done=true
  log("%s "..f, v, ...); log("finished"); manager.machine:exit() end

emu.register_frame_done(function()
  frame = frame + 1
  if frame==1 then attach() end
  if not space then return end
  if frame>=5 and frame<35 then held["UI Select"]=1 end  -- the ROM warning box
  for n,f in pairs(fields) do
    local v=(held[n] and held[n]>0) and 1 or 0; f:set_value(v)
    if held[n] and held[n]>0 then held[n]=held[n]-1 end
  end

  -- the control: before anybody touches the menu, all three are pickable
  if frame == 55*9 then
    local j,e,r = flags()
    log("BEFORE jade=%d ermac=%d rain=%d gstate=%d", j, e, r, space:read_u16(A.gstate))
    if j~=1 or e~=1 or r~=1 then finish("FAIL","factory cmos should leave all three pickable") return end
  end

  if frame == 55*10 then testsw:set_value(1); t0 = frame; phase="menu"; log("== TEST SWITCH ON ==") end
  if not t0 then return end
  local d = frame - t0

  -- main test menu: 3 downs -> GAME ADJUSTMENT, button
  if d==55*4 then tap("P1 Down",4) end
  if d==55*5 then tap("P1 Down",4) end
  if d==55*6 then tap("P1 Down",4) end
  if d==55*8 then tap("P1 High Punch",4) end
  -- adjustments list: 8 downs -> HIDDEN FIGHTERS (after KOMBO KOUNTER), enter
  for i=0,7 do if d==55*(10+i) then tap("P1 Down",4) end end
  if d==55*19 then manager.machine.video:snapshot(); log("snap: the list") end
  if d==55*20 then tap("P1 High Punch",4) end
  local n = math.abs(STEPS)
  local dir = STEPS >= 0 and "P1 Up" or "P1 Down"
  for i=0,n-1 do if d==55*22+30*i then tap(dir,4) end end
  local after = 55*22 + 30*n + 40
  if d==after then manager.machine.video:snapshot(); log("snap: value screen") end
  if d==after+20 then tap("P1 High Punch",4) end            -- accept
  if d==after+90 then testsw:set_value(0); log("== TEST SWITCH OFF ==") end
  if d==after+150 then
    log("== SOFT RESET - dipinit must now re-read cmos ==")
    manager.machine:soft_reset(); resetat = frame; phase="after"
  end
  if resetat and (frame-resetat)==55*8 then
    local j,e,r = flags()
    log("AFTER  jade=%d ermac=%d rain=%d", j, e, r)
    if j==WANT.jade and e==WANT.ermac and r==WANT.rain then
      finish("PASS","mask %d reached the game flags", MASK)
    else
      finish("FAIL","wanted jade=%d ermac=%d rain=%d", WANT.jade, WANT.ermac, WANT.rain)
    end
  end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
log("loaded")
