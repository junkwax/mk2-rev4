-- Paired real-input Wasteland shadow trial; private runner compares modes.
-- wasteland_shadow_test.lua
--
-- Boots two human fighters into a stage and exercises walking, jumping,
-- crouching and basic attacks. Records fighter/camera state and DMA starts
-- for 781 refreshes, with 27 screenshots. Health is replenished to keep
-- the fight running. This is a rendering comparison, not a full move audit.
--
-- Env: MK2_ROOT (frozen map), SHADOW_LOG, SHADOW_TRACE, SHADOW_STAGE (default 2),
-- SHADOW_P1/P2 (fighter indices), SHADOW_FAST (-1 observes native stage mode).
-- Usage: python tools/run_wasteland_shadow.py --p1 8 --p2 1

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("SHADOW_LOG") or (ROOT .. "/tools/stage_shadow_snap.log")
local STAGE = tonumber(os.getenv("SHADOW_STAGE") or "") or 2
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[shadow] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "p1_obj", "p2_obj", "p1_bar", "p2_bar", "p1_bar_view",
                     "p2_bar_view", "winner_status", "battle_num", "map_position",
                     "f_shadows", "ground_y", "shad_fast", "tick", "last_dmaq", "dmaq_late", "dmaq_lost", "worldtlx", "worldtly", "overload" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s", n) end
end

local OXVAL, OYPOS = 0x080, 0x0b0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO = tonumber(os.getenv("SHADOW_P1") or "8")
local FT_KANG = tonumber(os.getenv("SHADOW_P2") or "1")
local FAST = tonumber(os.getenv("SHADOW_FAST") or "0")
local EXPECTED_MODE = tonumber(os.getenv("SHADOW_EXPECTED_MODE") or "")
if FAST<0 then assert(EXPECTED_MODE,"native check requires SHADOW_EXPECTED_MODE") end
local DURATION = 900
local traces = assert(io.open(assert(os.getenv("SHADOW_TRACE")), "w"))
traces:write("r,x1,y1,shape1,flags1,x2,y2,shape2,flags2,worldx,worldy,uncompressed,blits,last_start,late,lost,queue,overload\n")
local taps, t0, last, blits = {}, nil, nil, 0
local ready, last_count, last_fraction = false, 0, 0

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local shots, done = 0, false
local fields = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] or f.name:match("^P[12] ") then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if fighting_frame > 0 then
        local r=frame-fighting_frame
        local phase=(r//90)%8
        local t=r%90
        if phase==1 then return name=="P1 Left" or name=="P2 Right" end
        if phase==2 then return name=="P1 Right" or name=="P2 Left" end
        if phase==3 then return t<12 and (name=="P1 Up" or name=="P2 Up") end
        if phase==4 then return name=="P1 Down" or name=="P2 Down" end
        if phase==5 then return t%24<4 and (name=="P1 High Punch" or name=="P2 Low Kick") end
        if phase==6 then return t%30<5 and (name=="P1 Low Punch" or name=="P2 High Kick") end
        return false
    end
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 1000 and (frame % 80) < 20
        end
        if name == "1 Player Start"  then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 and p1_confirm > 0 then
        if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
        if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        taps[1]=space:install_write_tap(A.tick,A.tick+15,"shadow_tick",function(_,data)
            local now=manager.machine.time:as_double()
            if t0 and last and now>t0 then last_count=blits;last_fraction=(last-t0)/(now-t0) end
            t0=now;last=nil;blits=0;return data
        end)
        taps[2]=space:install_write_tap(0x01a80010,0x01a8001f,"shadow_dma",function(_,data)
            if data&0x8000~=0 then blits=blits+1;last=manager.machine.time:as_double() end
            return data
        end)
        log("---- stage %d shadow snapshot ----", STAGE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, STAGE)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING then w16(A.p2_state, 1);w16(A.p1_state,1) end
    if FAST>=0 then w16(A.shad_fast,FAST) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d curback=%d ground_y=%d f_shadows=%d",
            frame, r16(A.curback), s16(r16(A.ground_y)), r16(A.f_shadows))
        log("P1 oypos=%s P2 oypos=%s", tostring(gety(A.p1_obj)), tostring(gety(A.p2_obj)))
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); logfh:close(); manager.machine:exit() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    local r = frame - fighting_frame
    if r==60 then
        local c1=r16(r32(A.p1_obj)+0x1f0);local c2=r16(r32(A.p2_obj)+0x1f0)
        log("fighters actual=%d,%d requested=%d,%d fast=%d",c1,c2,FT_SUBZERO,FT_KANG,FAST)
        assert(c1==FT_SUBZERO and c2==FT_KANG,"wrong selected fighters")
        assert(r16(A.curback)==STAGE and r16(A.f_shadows)~=0,"wrong stage or no shadows")
        if FAST<0 then
            log("native shadow mode actual=%d expected=%d",r16(A.shad_fast),EXPECTED_MODE)
            assert(r16(A.shad_fast)==EXPECTED_MODE,"wrong native stage shadow mode")
        end
    end
    if r>=120 and r<=DURATION then
        local vals={r}
        local uncomp=0
        for _,op in ipairs({A.p1_obj,A.p2_obj}) do
            local obj=r32(op)
            for _,off in ipairs({0x80,0xa0,0x1d0,0xf0}) do vals[#vals+1]=(off==0xf0 and r16(obj+off) or r32(obj+off)) end
            local node=r32(obj+0x1a0)
            if node~=0 then
                for k=0,10 do
                    if r32(node+k*112)==0 then break end
                    if r16(node+k*112+64)&0x80==0 then uncomp=uncomp+1 end
                end
            end
        end
        vals[#vals+1]=r32(A.worldtlx);vals[#vals+1]=r32(A.worldtly);vals[#vals+1]=uncomp
        vals[#vals+1]=last_count;vals[#vals+1]=last_fraction
        vals[#vals+1]=r16(A.dmaq_late);vals[#vals+1]=r16(A.dmaq_lost)
        vals[#vals+1]=r16(A.last_dmaq);vals[#vals+1]=r16(A.overload)
        traces:write(table.concat(vals,","),"\n")
        if r%30==0 then manager.machine.video:snapshot();shots=shots+1 end
    end
    if r>DURATION and not done then
        done=true;log("PASS %d captures; 781 measured frames",shots)
        traces:close();logfh:close();manager.machine:exit()
    end
    if frame>12000 then log("FAIL backstop");manager.machine:exit() end
end)
