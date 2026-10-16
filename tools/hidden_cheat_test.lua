-- hidden_cheat_test.lua
-- Verify a hidden-fighter select-screen unlock: put the cursor on the base
-- character, press Block N times, and check that after select that player's
-- char has become the hidden fighter.
--
-- Generalised from tools/smoke_cheat_test.lua, which was Smoke-only and had
-- the two character ids and the three RAM variable names baked in.  Noob and
-- Jade had each grown their own near-identical copy; Ermac would have been a
-- fourth.  One rig, driven by env vars:
--
--   CHEAT_NAME    smoke | noob | ermac    (picks c_<name>_cheatN etc.)
--   CHEAT_HOVER   base character's ft_ id - the one the cursor sits on
--   CHEAT_EXPECT  ft_ id the player must end up as
--   CHEAT_PLAYER  1 (tested in a 1P game) or 2 (in a 2P game)
--   CHEAT_LOG     log file path
--
-- Hovering any char OTHER than CHEAT_HOVER switches to the regression check:
-- Block is a CONFIRM button, so a single press off the base character must
-- still confirm that character normally and must never yield the hidden one.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local NAME = os.getenv("CHEAT_NAME") or "smoke"
local P = tonumber(os.getenv("CHEAT_PLAYER") or "1")
local BASE = tonumber(os.getenv("CHEAT_HOVER") or "10")
local EXPECT = tonumber(os.getenv("CHEAT_EXPECT") or "14")
local OTHER = (P==1) and 2 or 1
local TWO_P = (P==2)
local LOG = os.getenv("CHEAT_LOG") or (ROOT .. "/tools/hidden_cheat_test.log")
local logfh=io.open(LOG,"w")
local frame=0
local raw=print
print=function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("["..NAME.."] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) return symbols[n] end

-- Every unlock uses the same three .bss names, differing only by fighter.
local A={ gstate=sym("gstate"), my_char=sym("p"..P.."_char"),
  c=sym("c_"..NAME.."_cheat"..P), f=sym("f_"..NAME.."_cheat"..P),
  held=sym("f_"..NAME.."_blk_held"..P) }
-- held is OPTIONAL.  A fighter whose Block cheat has been retired has no
-- f_<name>_blk_held<P> in the map at all (KHAMELEON since 2026-09-25 - she
-- moved to MILEENA + Start x5), and that row is still run as the REGRESSION
-- control, where the held flag is not part of the assertion.  Treat it as
-- missing rather than fatal, and never read it unguarded.
for _,k in ipairs({"gstate","my_char","c","f"}) do
  if not A[k] then log("FATAL: symbol for '%s' not in mk2.map (name=%s)",k,NAME); end
end
if not A.held then log("note: f_%s_blk_held%d is not in mk2.map - Block cheat retired for this fighter; held reported as n/a",NAME,P) end
local function rheld() if A.held then return r16(A.held) else return -1 end end

local BLK="P"..P.." Block"; local LP="P"..P.." Low Punch"; local OLP="P"..OTHER.." Low Punch"
local GS_PSEL=4
local HOVER=tonumber(os.getenv("CHEAT_HOVER_OVERRIDE") or tostring(BASE))
-- CHEAT_DISABLED=1: this unlock's *_select_enable equate is 0 in MAINEQU.ASM,
-- so check_hidden_blk_cheat does not even compile its branch and Block on the
-- base character is an ORDINARY CONFIRM by design.  Press it five times anyway
-- and assert the negative - that is the real test of a compiled-out unlock,
-- and it stops the rig reporting FAIL for intended behaviour.  (Rain, Ermac,
-- Noob and Smoke all moved to the START-tap morph on 2026-09-22.)
local DISABLED=(os.getenv("CHEAT_DISABLED")=="1")
local ONBASE=(HOVER==BASE)
local CHEAT=ONBASE and not DISABLED
local NPRESS=ONBASE and 5 or 1
local space,fields=nil,{}
local psel=0; local left=0; local p0=0; local phase="boot"; local lc=-1; local lmc=-1; local done=false
local SNAP=tonumber(os.getenv("CHEAT_SNAP") or "0")   -- frames past the unlock
local snap_at=0
local function r16(a) return space:read_u16(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local held={}
local function hold(n,on) held[n]=on and true or false end
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,["UI Select"]=1,
    [BLK]=1,[LP]=1,[OLP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-18s %s",n,fields[n] and "ok" or "MISSING") end
end

-- CHEAT_WATCH = a DCS track in hex (e.g. 0578): also prove the select
-- screen's name call went out.  The latch carries the resolved TRACK, not the
-- triple_sndtab2 index, as two byte writes (0xFFhh then 0xFFll).  The tap
-- handle is kept in a global: a collected tap silently stops firing.
local WATCH=tonumber(os.getenv("CHEAT_WATCH") or "",16)
local SND_PORT=0x01d01030
local snd_hi, snd_seen, snd_tap=nil, 0, nil
local function on_snd(offset,data,mask)
  if offset~=SND_PORT then return data end
  local w=data&0xffff
  if (w&0xff00)~=0xff00 then snd_hi=nil; return data end
  if snd_hi==nil then if (w&0xff)<=0x07 then snd_hi=w&0xff end; return data end
  local code=(snd_hi<<8)|(w&0xff); snd_hi=nil
  if psel>0 then log("  snd $%04x frame=%d",code,frame) end
  -- a triple: the driver sends whichever of WATCH..WATCH+2 has a free channel
  if WATCH and code>=WATCH and code<=WATCH+2 then snd_seen=snd_seen+1 end
  return data
end
local function sound_verdict()
  if not WATCH then return end
  if snd_seen>0 then log("SOUND PASS: track $%04x-$%04x went out %d time(s)",WATCH,WATCH+2,snd_seen)
  else log("SOUND FAIL: none of $%04x-$%04x went out",WATCH,WATCH+2) end
end

emu.register_frame(function()
  frame=frame+1
  if frame==1 then local cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]; cache()
    if WATCH then snd_tap=space:install_write_tap(0x01d00000,0x01d01fff,"cheat_snd",on_snd) end
    log("TEST %s P%d (2P=%s) base=%d expect=%d hover=%d cheat=%s disabled=%s",
        NAME,P,tostring(TWO_P),BASE,EXPECT,HOVER,tostring(CHEAT),tostring(DISABLED)) end
  if not space then return end
  local gs=r16(A.gstate)
  if gs==GS_PSEL and psel==0 then
    psel=frame; log("select reached frame=%d",frame)
    -- The coin/start holds are only refreshed while psel==0, but the apply
    -- loop at the bottom re-asserts held[] EVERY frame - so whatever they
    -- were on the frame before select stayed pressed for the whole test.
    -- Start is one of the confirm bits (p1sf2) that cmove41 checks BEFORE
    -- the hidden-character route, so a stuck Start makes every Block press
    -- an ordinary confirm and the counter never moves.
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start","UI Select"}) do
      hold(n,false)
    end
  end
  if psel==0 then
    hold("Coin 1", frame>=200 and frame<3000 and (frame%80)<20)
    if TWO_P then
      hold("Coin 2", frame>=240 and frame<3000 and (frame%80)>=20 and (frame%80)<40)
      hold("2 Players Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    else
      hold("1 Player Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    end
    hold("UI Select", frame>=5 and frame<35)
  else
    local rel=frame-psel
    if rel==60 then p0=frame; phase="pulsing"; log("pulsing %s %dx (hover char %d, cheat=%s)",BLK,NPRESS,HOVER,tostring(CHEAT)) end
    if phase=="pulsing" then
      w16(A.my_char,HOVER)            -- hover the target char
      local p=frame-p0; local idx=p//10
      if idx<NPRESS then hold(BLK,(p%10)<5)
      else hold(BLK,false)
        if phase~="post" then phase="post"; log("pulses done c=%d f=%d held=%d",r16(A.c),r16(A.f),rheld()) end
      end
      local c=r16(A.c); if c~=lc then log("  c_%s_cheat%d=%d (frame=%d)",NAME,P,c,frame); lc=c end
    end
    -- CHEAT mode: LP fallback confirm. REGRESSION mode: no fallback - Block
    -- itself must confirm off the base char, else we can't tell it's broken.
    if CHEAT and phase=="post" and (frame-p0)>70 then
      hold(LP,(frame%20)<8); if TWO_P then hold(OLP,(frame%20)<8) end
    end
  end
  if psel>0 and phase=="post" and gs~=GS_PSEL then
    if left==0 then left=frame; log("left select frame=%d gs=%d; polling...",frame,gs) end
    local mc=r16(A.my_char); local f=r16(A.f)
    if mc~=lmc then log("  poll rel=%d p%d_char=%d f=%d gs=%d",frame-left,P,mc,f,gs); lmc=mc end
    if CHEAT then
      -- CHEAT_SNAP=<n>: don't stop at the unlock - carry on into the fight and
      -- save a screenshot n frames later, so the lifebar name and the palette
      -- can actually be looked at.  The unlock alone proves p?_char changed;
      -- it proves nothing about whether the fighter RENDERS.
      if mc==EXPECT and SNAP>0 then
        if snap_at==0 then snap_at=frame+SNAP; log("unlocked at rel=%d; running on to frame %d for a snapshot",frame-left,snap_at) end
      elseif mc==EXPECT and not done then done=true; log("PASS %s_p%d: player %d became char %d at rel=%d",NAME,P,P,EXPECT,frame-left); sound_verdict(); log("finished"); manager.machine:exit()
      elseif frame-left>200 and not done then done=true; log("FAIL %s_p%d: p%d_char stayed %d (expected %d) f=%d",NAME,P,P,mc,EXPECT,f); sound_verdict(); log("finished"); manager.machine:exit() end
    else
      local why = DISABLED and "unlock compiled out" or "off-base"
      if mc==EXPECT and not done then done=true; log("FAIL regress_%s_p%d: %s, yet Block still produced char %d (hover=%d)",NAME,P,why,EXPECT,HOVER); sound_verdict(); log("finished"); manager.machine:exit()
      elseif frame-left>90 and not done then done=true; log("PASS regress_%s_p%d: %s - Block confirmed char %d normally (c=%d, no hidden fighter)",NAME,P,why,mc,r16(A.c)); sound_verdict(); log("finished"); manager.machine:exit() end
    end
  end
  if snap_at>0 and frame>=snap_at and not done then
    done=true
    manager.machine.video:snapshot()
    log("PASS %s_p%d: char %d reached the fight; snapshot at frame %d gs=%d",
        NAME,P,EXPECT,frame,r16(A.gstate))
    sound_verdict(); log("finished"); manager.machine:exit()
  end
  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame>6000 then log("FAIL %s timeout phase=%s psel=%d c=%d",NAME,phase,psel,r16(A.c)); sound_verdict(); log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
