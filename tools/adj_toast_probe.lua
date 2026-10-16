-- adj_toast_probe.lua : verify the two new operator adjustments.
--
--  phase 1  normal boot   - read f_kalout / f_kmbcnt and confirm the
--                           factory defaults land (toasts OFF, kounter ON)
--  phase 2  test switch   - flip MAME's "Test Switch" dip on, walk into
--                           GAME ADJUSTMENTS and snapshot the page so the
--                           two new rows can be seen to fit the box.
--
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT.."/tmp/adjprobe"
local logfh = io.open(OUT.."/probe.log","w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[adj] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) local v=symbols[n]; if not v then log("WARN missing %s",n) end; return v end

local A = { gstate=sym("gstate"), f_kalout=sym("f_kalout"), f_kmbcnt=sym("f_kmbcnt") }
log("f_kalout=%08x f_kmbcnt=%08x gstate=%08x", A.f_kalout, A.f_kmbcnt, A.gstate)

local space, fields, testsw = nil, {}, nil
local function attach()
  space = manager.machine.devices[":maincpu"].spaces["program"]
  local want={["P1 Up"]=1,["P1 Down"]=1,["P1 High Punch"]=1,["1 Player Start"]=1}
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(port.fields) do
      if want[f.name] then fields[f.name]=f end
      if f.name=="Test Switch" then testsw=f end
    end
  end
  log("attached: space=%s testsw=%s", tostring(space~=nil), tostring(testsw~=nil))
end

local held = {}
local function tap(n,frames) held[n] = frames end

local frame, phase, shots = 0, 1, 0
local script = {}   -- {frame_offset, action}
local p2start = nil

emu.register_frame_done(function()
  frame = frame + 1
  if frame == 1 then attach() end
  if not space then return end

  -- drive any held inputs
  for n,f in pairs(fields) do
    local v = (held[n] and held[n] > 0) and 1 or 0
    f:set_value(v)
    if held[n] and held[n] > 0 then held[n] = held[n] - 1 end
  end

  if frame % 55 == 0 then
    log("t=%3ds  gstate=%d  f_kalout=%d  f_kmbcnt=%d",
        frame//55, space:read_u16(A.gstate),
        space:read_u16(A.f_kalout), space:read_u16(A.f_kmbcnt))
  end

  -- phase 2: after 12s of normal boot, flip the test switch
  if frame == 55*12 and testsw then
    testsw:set_value(1)
    p2start = frame
    log("== TEST SWITCH ON - entering service menu ==")
  end

  if p2start then
    local d = frame - p2start
    -- snapshot every second so the walk can be followed
    if d % 55 == 0 and shots < 40 then
      manager.machine.video:snapshot(); shots = shots + 1
      log("snap %d at d=%ds gstate=%d", shots, d//55, space:read_u16(A.gstate))
    end
    -- MAIN TEST MENU is:  DIAGNOSTIC TESTS / COIN BOOKKEEPING / GAME AUDITS /
    -- GAME ADJUSTMENT / UTILITIES / VOLUME ADJUST / EXIT.  Three downs off the
    -- top lands on GAME ADJUSTMENT; any button activates.
    if d == 55*5  then tap("P1 Down",4) end
    if d == 55*6  then tap("P1 Down",4) end
    if d == 55*7  then tap("P1 Down",4) end
    if d == 55*9  then tap("P1 High Punch",4) end
    -- then walk DOWN the adjustments list so the new rows get highlighted
    if d == 55*12 then tap("P1 Down",4) end
    if d == 55*13 then tap("P1 Down",4) end
    if d == 55*14 then tap("P1 Down",4) end
    if d == 55*15 then tap("P1 Down",4) end
    if d == 55*16 then tap("P1 Down",4) end
    if d == 55*17 then tap("P1 Down",4) end
    -- ... which lands on KOMBAT TOASTS (index 6).  Now the ROUND TRIP:
    -- enter it, flip the value, back out, and leave the test menu - exiting
    -- is a warmset, so dipinit re-reads cmos and f_kalout must follow.
    if d == 55*19 then tap("P1 High Punch",4) end   -- enter the adjustment
    if d == 55*21 then tap("P1 Down",4) end         -- OFF -> ON
    if d == 55*23 then tap("P1 High Punch",4) end   -- accept, back to the list
    if d == 55*25 then tap("P1 Down",4) end         -- -> KOMBO KOUNTER
    if d == 55*26 then tap("P1 Down",4) end         -- -> RETURN TO MAIN MENU
    if d == 55*28 then tap("P1 High Punch",4) end   -- back to the test menu
    if d == 55*30 then tap("P1 Down",4) end         -- GAME ADJUSTMENT -> UTILITIES
    if d == 55*31 then tap("P1 Down",4) end         -- -> VOLUME ADJUST
    if d == 55*32 then tap("P1 Down",4) end         -- -> EXIT TEST MENU
    if d == 55*34 and testsw then testsw:set_value(0)
      log("== TEST SWITCH OFF ==") end
    if d == 55*35 then tap("P1 High Punch",4) end   -- exit -> warmset
  end
end)
log("adj_toast_probe loaded")
