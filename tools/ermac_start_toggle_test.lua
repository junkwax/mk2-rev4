-- ermac_start_toggle_test.lua  (EST_TARGET=jade: the same for Kitana -> Jade)
-- The select screen's Reptile <-> Ermac toggle (MKSEL.ASM ermac_start_tap):
-- a clean tap of START with the cursor on Reptile flips that player to Ermac
-- and wipes Reptile's grid box across (REPERM1-7 -> ERBOX); the next tap
-- wipes it back.  Driven by env vars:
--
--   EST_PLAYER  1 (in a 1P game) or 2 (in a 2P game)
--   EST_MODE    toggle - five taps on Reptile (Ermac, Reptile, Ermac,
--                        Reptile, Ermac), a snapshot after each of the
--                        first two, then confirm: must come out Ermac.  In a
--                        1P game five Start presses is also the Kahn cheat,
--                        so the run fails if select ends before the confirm
--                        or c_kahn_cheat moved.
--               leave  - one tap (Ermac), then walk LEFT off Reptile and
--                        confirm Johnny Cage: must come out Cage, with the
--                        flag gone and the box back on RPBOX.
--               cross  - 2P: P1 walks onto the square, toggles, PICKS the
--                        hidden fighter; P2 sits on the same square
--                        untoggled.  The box must come back to the roster
--                        face for P2, and P2 must come out as the roster
--                        fighter (it used to stay on Ermac/Jade).
--   EST_LOG     log file
--   EST_SNAPDIR where snapshots go (MAME's -snapshot_directory)
--
-- The cursor is moved with the real joystick, never by poking p?_char, so
-- new_cursor_position (which clears the toggle on the way out) really runs.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local P = tonumber(os.getenv("EST_PLAYER") or "1")
local MODE = os.getenv("EST_MODE") or "toggle"
-- EST_TARGET ermac (Scorpion square) | jade (Kitana) | rain (Sub-Zero)
--            kham (Mileena, -Mode count: a COUNTER, not a toggle)
local TARGET = os.getenv("EST_TARGET") or "ermac"
local TGT = ({
  -- Ermac moved from Reptile to SCORPION on 2026-09-23 (row2 col2 of the
  -- grid); Reptile has no morph at all now.
  ermac={ base=10, hidden=17, flag="f_ermac_cheat", pos="ermac_pos", leave_to=7,
          p1moves={"DOWN","DOWN","RIGHT","RIGHT"}, p2moves={"DOWN","DOWN","LEFT"}, leave="RIGHT" },
  -- Jade moved from Mileena to KITANA on 2026-09-25 (row2 col3 of the grid:
  -- SZBOX STBOX FN1BOX JXBOX).  Leaving her RIGHT lands on Jax, which has no
  -- morph of its own.
  jade ={ base=4, hidden=16, flag="f_jade_cheat",  pos="jade_pos", leave_to=11,
          p1moves={"DOWN","RIGHT","RIGHT"}, p2moves={"DOWN","LEFT"}, leave="RIGHT" },
  -- reptile is for -Mode inert only: it has NO morph since 2026-09-23, so a
  -- Start tap on his square must do nothing at all.
  reptile={ base=9, hidden=9, flag="f_ermac_cheat", pos="ermac_pos", leave_to=2,
          p1moves={"RIGHT","RIGHT","RIGHT"}, p2moves={}, leave="LEFT" },
  rain ={ base=8, hidden=19, flag="f_rain_cheat",  pos="rain_pos", leave_to=6,
          p1moves={"DOWN"}, p2moves={"DOWN","LEFT","LEFT","LEFT"}, leave="RIGHT" },
  -- KHAMELEON is not a morph: five clean Start taps on MILEENA COUNT to a
  -- pending flag (kham_start_tap, MKSEL.ASM) and there is no box wipe, so she
  -- runs -Mode count.  She moved here from Kitana + Block x5 on 2026-09-25,
  -- when Jade's wipe took Kitana's square.  `pos` is Jade's, which must stay
  -- 0 throughout - Mileena has no morph any more.
  kham ={ base=5, hidden=18, flag="f_kham_cheat",  pos="jade_pos", leave_to=3,
          count="c_kham_cheat", p1moves={"DOWN","DOWN"},
          p2moves={"DOWN","DOWN","LEFT","LEFT","LEFT"}, leave="RIGHT" },
})[TARGET]
local TWO_P = (P==2)
local LOG = os.getenv("EST_LOG") or (ROOT .. "/tools/ermac_start_toggle.log")
local logfh=io.open(LOG,"w")
local raw=print
print=function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[est] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local A={ gstate=symbols["gstate"], my_char=symbols["p"..P.."_char"],
  f=symbols[TGT.flag..P], tap=symbols["f_ermac_start"..P],
  pos=symbols[TGT.pos], kahn=symbols["c_kahn_cheat"],
  cnt=TGT.count and symbols[TGT.count..P] or nil,
  sw=0x01600000, sw2=0x01600020 }
for _,k in ipairs({"gstate","my_char","f","tap","pos","kahn"}) do
  if not A[k] then log("FATAL: '%s' not in mk2.map",k) end
end

local FT_LEAVE, FT_BASE, FT_HIDDEN = TGT.leave_to, TGT.base, TGT.hidden
local GS_PSEL=4
local START=TWO_P and "2 Players Start" or "1 Player Start"
local RIGHT="P"..P.." Right"; local LEFT="P"..P.." Left"; local LP="P"..P.." Low Punch"
local DIR={RIGHT=RIGHT,LEFT=LEFT,DOWN="P"..P.." Down"}
local space,fields=nil,{}
local frame, psel, left, done = 0, 0, 0, false
local held={}
local function hold(n,on) held[n]=on and true or false end
local function r16(a) return space:read_u16(a) end
local CROSS=(MODE=="cross")
local INERT=(MODE=="inert")     -- the square has no morph: Start is inert
-- A COUNTER square (kham): taps accumulate into c_* and the 5th raises the
-- pending flag.  It is a property of the SQUARE, so it holds in every mode -
-- -Mode leave taps once, which must leave the flag down and the count at 1.
local COUNT=(TGT.count~=nil)
local COUNTMODE=(MODE=="count")  -- ...and this mode drives the full five
local LADDER=(MODE=="ladder")   -- 1P: pick the hidden fighter, then film the
                                -- battle-plan screen (gs_post_psel) where
                                -- mini_mug_table draws his ladder mug
local function cache()
  local want={["P1 Right"]=1,["P1 Down"]=1,["P1 Left"]=1,["P2 Right"]=1,["P2 Down"]=1,["P2 Left"]=1,["P2 Low Punch"]=1,["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,["UI Select"]=1,
    [RIGHT]=1,[LEFT]=1,[DIR.DOWN]=1,[LP]=1,["P1 Low Punch"]=1}
  for _,p in pairs(manager.machine.ioport.ports) do for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-18s %s",n,fields[n] and "ok" or "MISSING") end
end
local function finish(verdict, f, ...)
  if done then return end
  done=true; log(verdict.." "..MODE.."_p"..P..": "..f, ...); log("finished"); manager.machine:exit()
end

-- The script, as {rel frame, action}.  A tap is 6 frames down; 40 frames
-- between taps lets the 24-tick wipe land.
local steps={}
local function at(t,fn) steps[#steps+1]={t=t,fn=fn} end
local function press(n,t,len) at(t,function() hold(n,true) end); at(t+(len or 6),function() hold(n,false) end) end
local t=60
local cross_done=false
if CROSS then
  -- P1 joins on the select screen (Start while not in the game), then P1
  -- and P2 both walk onto the square (P2 first); P1 toggles and picks.
  press("Coin 1",2,10)
  press("Coin 1",30,10)
  press("1 Player Start",60)
  at(100,function() log("cross: p1_state=%d p1_char=%d",r16(symbols["p1_state"]),r16(symbols["p1_char"])) end)
  t=t+80
  for i,m in ipairs(TGT.p2moves) do press("P2 "..m:sub(1,1)..m:sub(2):lower(),t+(i-1)*24) end
  t=t+#TGT.p2moves*24+10
  for i,m in ipairs(TGT.p1moves) do press("P1 "..m:sub(1,1)..m:sub(2):lower(),t+(i-1)*24) end
  t=t+#TGT.p1moves*24+20
  at(t,function()
    local c1,c2=r16(symbols["p1_char"]),r16(symbols["p2_char"])
    log("cross: p1 on %d, p2 on %d",c1,c2)
    if c1~=FT_BASE or c2~=FT_BASE then finish("FAIL","cursors on %d/%d, want both on %d",c1,c2,FT_BASE) end
  end)
  t=t+10
  press("1 Player Start",t)
  local F1=symbols[TGT.flag.."1"]
  at(t+50,function()
    log("cross: P1 toggled f1=%d pos=%d",r16(F1),r16(A.pos))
    if r16(F1)~=1 or r16(A.pos)~=8 then finish("FAIL","P1 toggle: f1=%d pos=%d",r16(F1),r16(A.pos)) return end
    manager.machine.video:snapshot()
  end)
  t=t+60
  press("P1 Low Punch",t,8)
  at(t+90,function()
    log("cross: after P1's pick p1_char=%d pos=%d (P2 still on the square, untoggled)",r16(symbols["p1_char"]),r16(A.pos))
    manager.machine.video:snapshot()
    if r16(A.pos)~=0 then finish("FAIL","box stayed on frame %d while P2 (untoggled) is on the square",r16(A.pos)) end
  end)
  t=t+100
  press("P2 Low Punch",t,8)
  at(t+30,function() manager.machine.video:snapshot(); log("cross: P2 pick snapshot pos=%d",r16(A.pos)) end)
  t=t+40
end
-- P1 starts on Liu Kang, P2 on Reptile
local moves=(CROSS and {}) or (TWO_P and TGT.p2moves or TGT.p1moves)
for i,m in ipairs(moves) do press(DIR[m],t+(i-1)*24) end
if #moves>0 then t=t+#moves*24+20 end
if not CROSS then at(t,function()
  local c=r16(A.my_char)
  if c~=FT_BASE then finish("FAIL","cursor on char %d, not %d",c,FT_BASE) else log("cursor on base %d, f=%d pos=%d",c,r16(A.f),r16(A.pos)) end
end) end
t=t+10
local expect_f={1,0,1,0,1}
local ntaps=(MODE=="toggle" or COUNTMODE) and 5 or (CROSS and 0 or (INERT and 3 or 1))
for i=1,ntaps do
  press(START,t)
  at(t+50,function()
    local f,pos=r16(A.f),r16(A.pos)
    local want=INERT and 0 or (COUNT and (i==5 and 1 or 0) or expect_f[i])
    if COUNT then
      log("tap %d: f=%d c=%d pos=%d tap=%d kahn=%d gs=%d",i,f,r16(A.cnt),pos,r16(A.tap),r16(A.kahn),r16(A.gstate))
    else
      log("tap %d: f=%d pos=%d tap=%d kahn=%d gs=%d",i,f,pos,r16(A.tap),r16(A.kahn),r16(A.gstate))
    end
    if r16(A.gstate)~=GS_PSEL then finish("FAIL","select ended after tap %d (Kahn cheat?)",i) return end
    if f~=want then finish("FAIL","tap %d left f=%d, wanted %d",i,f,want) return end
    -- the counter climbs 1..4 and is zeroed by the 5th, which raises the flag
    if COUNT and r16(A.cnt)~=(i<5 and i or 0) then
      finish("FAIL","tap %d left c=%d, wanted %d",i,r16(A.cnt),(i<5 and i or 0)) return end
    -- a square with no morph must never move a box
    if pos~=(COUNT and 0 or want*8) then finish("FAIL","tap %d left the box on frame %d, wanted %d",i,pos,COUNT and 0 or want*8) return end
    if i<=2 then manager.machine.video:snapshot() end
  end)
  -- one snapshot mid-wipe on the first tap
  if i==1 and not COUNT then at(t+6+10,function() log("mid-wipe pos=%d",r16(A.pos)); manager.machine.video:snapshot() end) end
  t=t+60
end
local expect
if MODE=="leave" then
  press(DIR[TGT.leave],t)
  at(t+50,function()
    log("left base: char=%d f=%d pos=%d",r16(A.my_char),r16(A.f),r16(A.pos))
    if r16(A.f)~=0 then finish("FAIL","flag still up after leaving the square") return end
    if r16(A.pos)~=0 then finish("FAIL","box still on frame %d after leaving",r16(A.pos)) return end
    if A.cnt and r16(A.cnt)~=0 then finish("FAIL","counter still %d after leaving",r16(A.cnt)) return end
    manager.machine.video:snapshot()
  end)
  t=t+60
  expect=FT_LEAVE
else
  -- A square WITH a morph must not feed the 1P Kahn cheat (5 Starts).  A
  -- square without one still does, which is stock MK2 - so inert mode, which
  -- is only run on such a square, does not check it.
  if not TWO_P and not INERT then   -- COUNT squares are in the skip list too
    at(t,function() if r16(A.kahn)~=0 then finish("FAIL","c_kahn_cheat=%d after Start on the square",r16(A.kahn)) end end)
  end
  expect=FT_HIDDEN
end
if CROSS or INERT then expect=FT_BASE end
local confirm_t=t
if not CROSS then
press(LP,t,8)
if TWO_P then press("P1 Low Punch",t+20,8) end   -- P1 picks too, so select ends
end
at(t+30,function() manager.machine.video:snapshot(); log("confirm flash/dim snapshot") end)

emu.register_frame(function()
  frame=frame+1
  if frame==1 then local cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]; cache()
    if os.getenv("EST_TRACE") then
      _G.est_tap=space:install_write_tap(A.tap, A.tap+15, "esttap", function(off,data,mask)
        log("  WRITE tap @%x data=%x mask=%x frame=%d pc=%x",off,data,mask,frame,cpu.state["PC"].value) end)
      _G.est_tap2=space:install_write_tap(A.my_char, A.my_char+15, "estchar", function(off,data,mask)
        log("  WRITE char @%x data=%x mask=%x frame=%d pc=%x",off,data,mask,frame,cpu.state["PC"].value) end)
    end
    log("TEST target=%s mode=%s P%d 2P=%s",TARGET,MODE,P,tostring(TWO_P)) end
  if not space then return end
  local gs=r16(A.gstate)
  if gs==GS_PSEL and psel==0 then
    psel=frame; log("select reached frame=%d",frame)
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start","UI Select"}) do hold(n,false) end
  end
  if psel==0 then
    hold("Coin 1", frame>=200 and frame<3000 and (frame%80)<20)
    if TWO_P then
      hold("Coin 2", frame>=240 and frame<3000 and (frame%80)>=20 and (frame%80)<40)
      hold("2 Players Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
      if CROSS then   -- both players in: P1 joins on the other half of the cycle
        hold("1 Player Start", frame>=340 and frame<3000 and (frame%80)>=5 and (frame%80)<15)
      end
    else
      hold("1 Player Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    end
    hold("UI Select", frame>=5 and frame<35)
  else
    local rel=frame-psel
    if os.getenv("EST_TRACE") and rel<400 and (rel%1==0) and A.sw then
      log("  rel=%d tap=%d f=%d sw=%08x sw2=%08x",rel,r16(A.tap),r16(A.f),space:read_u32(A.sw),space:read_u32(A.sw2))
    end
    for _,s in ipairs(steps) do if s.t==rel and not done then s.fn() end end
    if rel>confirm_t and gs~=GS_PSEL and not done then
      if left==0 then left=frame; log("left select rel=%d gs=%d",rel,gs) end
      local mc=r16(A.my_char)
      if LADDER then
        local d=frame-left
        -- log every gstate change and film each one: the battle plan is drawn
        -- by do_ladder (MAIN.ASM), after the VS screen
        if gs~=_G.est_lastgs then
          _G.est_lastgs=gs
          log("  gstate -> %d at +%d (p%d_char=%d)",gs,d,P,mc)
          _G.est_shot=d+12
        end
        -- the VS screen and the battle plan both run under gs 7, so sample
        -- across it rather than trusting a single offset
        if d>=40 and d<=430 and (d%50)==0 then
          manager.machine.video:snapshot(); log("  snapshot at +%d gs=%d",d,gs)
        end
        if d>=900 then
          if mc==FT_HIDDEN then finish("PASS","player %d is char %d on the battle plan",P,mc)
          else finish("FAIL","p%d_char=%d, wanted %d",P,mc,FT_HIDDEN) end
        end
        return
      end
      if CROSS then
        local c1=r16(symbols["p1_char"])
        if c1==FT_HIDDEN and mc==FT_BASE and r16(A.pos)~=0 then finish("FAIL","P2 picked the roster face but the box ended on frame %d",r16(A.pos))
        elseif c1==FT_HIDDEN and mc==FT_BASE then finish("PASS","P1 came out as %d, P2 as %d, box on frame %d (P2's face)",c1,mc,r16(A.pos))
        elseif frame-left>200 then finish("FAIL","p1_char=%d p2_char=%d, want %d/%d",c1,mc,FT_HIDDEN,FT_BASE) end
      elseif mc==expect then finish("PASS","player %d came out as char %d",P,mc)
      elseif frame-left>200 then finish("FAIL","p%d_char=%d, expected %d (f=%d)",P,mc,expect,r16(A.f)) end
    end
  end
  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame>8000 then finish("FAIL","timeout psel=%d",psel) end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
