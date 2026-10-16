-- adj_toast_roundtrip.lua : prove the whole chain for KOMBAT TOASTS.
--
--   service menu -> gen_adj -> put_adj -> cmos -> soft reset -> dipinit
--   -> get_adj -> f_kalout
--
-- A soft reset is used rather than EXIT TEST MENU because it reaches the same
-- POWERUP/main_init path without needing the menu walk to be perfect, and cmos
-- ram survives it (it is battery ram, not a file), so nothing depends on MAME
-- flushing nvram to disk on the way out.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local logfh = io.open(ROOT.."/tmp/adjprobe/roundtrip.log","w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[rt] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local A={gstate=symbols["gstate"],f_kalout=symbols["f_kalout"],f_kmbcnt=symbols["f_kmbcnt"]}

local space, fields, testsw = nil, {}, nil
local function attach()
  space = manager.machine.devices[":maincpu"].spaces["program"]
  local want={["P1 Up"]=1,["P1 Down"]=1,["P1 High Punch"]=1}
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(port.fields) do
      if want[f.name] then fields[f.name]=f end
      if f.name=="Test Switch" then testsw=f end end end
end
local held={}
local function tap(n,fr) held[n]=fr end

local frame, t0, phase, resetat = 0, nil, "boot", nil
emu.register_frame_done(function()
  frame = frame + 1
  if frame==1 then attach() end
  if not space then return end
  for n,f in pairs(fields) do
    local v=(held[n] and held[n]>0) and 1 or 0; f:set_value(v)
    if held[n] and held[n]>0 then held[n]=held[n]-1 end
  end
  local function st() return space:read_u16(A.gstate), space:read_u16(A.f_kalout), space:read_u16(A.f_kmbcnt) end
  if frame % 55 == 0 then local g,k,c = st()
    log("%-8s t=%3ds gstate=%d f_kalout=%d f_kmbcnt=%d", phase, frame//55, g, k, c) end

  if frame == 55*10 then testsw:set_value(1); t0 = frame; phase="menu"
    log("== TEST SWITCH ON ==") end
  if not t0 then return end
  local d = frame - t0

  -- main test menu: 3 downs -> GAME ADJUSTMENT, button
  if d==55*4 then tap("P1 Down",4) end
  if d==55*5 then tap("P1 Down",4) end
  if d==55*6 then tap("P1 Down",4) end
  if d==55*8 then tap("P1 High Punch",4) end
  -- adjustments list: 6 downs -> KOMBAT TOASTS, button to enter
  for i=0,5 do if d==55*(10+i) then tap("P1 Down",4) end end
  if d==55*17 then tap("P1 High Punch",4) end
  if d==55*19 then tap("P1 Down",4) end            -- OFF -> ON
  if d==55*20 then manager.machine.video:snapshot(); log("snap: value screen") end
  if d==55*21 then tap("P1 High Punch",4) end      -- accept -> put_adj
  if d==55*23 then manager.machine.video:snapshot(); log("snap: back on the list") end
  -- now drop the test switch and soft reset: POWERUP -> main_init -> dipinit
  if d==55*25 then testsw:set_value(0); log("== TEST SWITCH OFF ==") end
  if d==55*27 then
    log("== SOFT RESET - dipinit must now re-read cmos ==")
    manager.machine:soft_reset(); resetat = frame; phase="after"
  end
  if resetat and (frame-resetat)==55*8 then
    local g,k,c = st()
    log("RESULT  f_kalout=%d (expect 1 - toggled ON in the menu)  f_kmbcnt=%d (expect 1 - untouched)", k, c)
    log(k==1 and "PASS - the menu change reached the game flag" or "FAIL - the change did not survive")
  end
end)
log("roundtrip loaded")
