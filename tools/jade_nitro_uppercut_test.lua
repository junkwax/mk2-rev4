-- Runtime regression: a ducking P2 uppercut must punish Jade's Nitro Kick
-- recovery instead of passing through the old, extra-wide KTLOKICK1 bounds.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local logfh = assert(io.open(ROOT .. "/tools/jade_nitro_uppercut_test.log", "w"))
local function log(fmt, ...)
    local s = "[jade-nitro-upcut] " .. string.format(fmt, ...)
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
local function sym(name) assert(symbols[name], "missing symbol " .. name); return symbols[name] end

local A = {
    gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
}
local P_ACTION, OXPOS, OYPOS, OFLAGS, OIMG = 0x1f0, 0x90, 0xb0, 0xf0, 0x1a0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_REPTILE, FT_JADE = 4, 9, 16
local PS_ACTIVE, ACT_SHADK, ACT_JADE_NITRO_SD = 1, 0x0205, 0x061c

local frame, cpu, space = 0, nil, nil
local fields = {}
local charsel, confirm, fight, recover = 0, 0, 0, 0
local p1hp0, p1hp_low, p2hp0, p2hp_low = nil, nil, nil, nil
local nitro_seen, upcut_pressed, finished = false, false, false
local last_p1act, last_p2act = 0xffff, 0xffff

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v & 0xffff) end
local function action(procaddr)
    local p = r32(procaddr); return p ~= 0 and r16(p + P_ACTION) or 0xffff
end
local function objx(objaddr)
    local o = r32(objaddr); return o ~= 0 and r16(o + OXPOS) or 0
end
local function set_objx(objaddr, x)
    local o = r32(objaddr); if o ~= 0 then space:write_u16(o + OXPOS, x & 0xffff) end
end
local function sag(objaddr)
    local o = r32(objaddr); if o == 0 then return 0 end
    local img = r32(o + OIMG); return img ~= 0 and r32(img) or 0
end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function bounds(objaddr)
    local o=r32(objaddr); if o==0 then return 0,0,0,0 end
    local img=r32(o+OIMG); if img==0 then return 0,0,0,0 end
    local x,y=s16(r16(o+OXPOS)),s16(r16(o+OYPOS))
    local l,t,r,b=0x7fff,0x7fff,-0x7fff,-0x7fff
    for i=0,15 do
        local q=img+i*0x70
        local xs,ys=s16(r16(q+0x20)),s16(r16(q+0x30))
        local xo,yo=s16(r16(q+0x50)),s16(r16(q+0x60))
        local pl,pt=x-xo,y-yo
        l=math.min(l,pl); t=math.min(t,pt); r=math.max(r,pl+xs); b=math.max(b,pt+ys)
        if r32(q+0x70)==0 then break end
    end
    return l,t,r,b
end

local function finish(ok, why)
    if finished then return end
    finished = true
    log("%s %s p1hp=%d->%d p2hp=%d->%d", ok and "PASS" or "ERROR", why,
        p1hp0 or -1, p1hp_low or -1, p2hp0 or -1, p2hp_low or -1)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 Down"]=true, ["P1 Right"]=true, ["P1 Low Kick"]=true,
        ["P1 High Punch"]=true, ["P2 Down"]=true, ["P2 High Punch"]=true,
    }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do log("input %-16s %s", name, fields[name] and "ok" or "MISSING") end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return charsel == 0 and frame >= 700 and frame < 980 and frame % 80 < 20
    end
    if name == "1 Player Start" then return charsel == 0 and frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then
        if charsel > 0 and fight == 0 then local r=frame-charsel; return r>=5 and r<45 end
        return charsel == 0 and frame >= 1040 and frame < 1140
    end
    if charsel > 0 and fight == 0 and confirm > 0 then
        if name == "P1 High Punch" then return frame >= confirm and frame < confirm+40 end
        if name == "P2 High Punch" then return frame >= confirm+70 and frame < confirm+110 end
    end
    if fight == 0 then return false end

    local r = frame - fight
    if name == "P2 Down" then return r >= 55 and r < 260 end
    if recover > 0 and name == "P2 High Punch" then
        local d = frame - recover
        if d >= 6 and d < 12 then upcut_pressed = true; return true end
    end
    if name == "P1 Down" then return r >= 80 and r < 84 end
    if name == "P1 Right" then return r >= 86 and r < 90 end
    if name == "P1 Low Kick" then return r >= 92 and r < 98 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]
        cache_fields(); log("loaded")
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel == 0 then charsel=frame; log("character select frame=%d", frame) end
        w16(A.p1_state,PS_ACTIVE); w16(A.p2_state,PS_ACTIVE)
        w16(A.p1_char,FT_KITANA); w16(A.p2_char,FT_REPTILE)
        if confirm == 0 and frame-charsel > 90 then confirm=frame end
    elseif gs == GS_POST then
        w16(A.p1_char,FT_JADE)
    elseif gs == GS_FIGHTING then
        w16(A.p2_state,PS_ACTIVE)
        if fight == 0 then
            fight=frame; p1hp0=r16(A.p1_bar); p2hp0=r16(A.p2_bar)
            p1hp_low=p1hp0; p2hp_low=p2hp0
            log("fight frame=%d chars=%d/%d x=%d/%d",frame,r16(A.p1_char),r16(A.p2_char),objx(A.p1_obj),objx(A.p2_obj))
            if r16(A.p1_char) ~= FT_JADE then finish(false,"Jade selection failed"); return end
        end
    end

    if fight > 0 then
        local r=frame-fight
        -- Keep P2 outside Nitro Kick's active reach.  Once the whiff enters
        -- recovery, put the already-ducking P2 at an ordinary uppercut range;
        -- this isolates Jade's victim bounds from Nitro's own strike result.
        if r == 50 then
            set_objx(A.p2_obj, 900)
            log("staged whiff range x=%d/%d",objx(A.p1_obj),objx(A.p2_obj))
        end
        local p1act=action(A.p1_proc)
        local p2act=action(A.p2_proc)
        p1hp_low=math.min(p1hp_low,r16(A.p1_bar)); p2hp_low=math.min(p2hp_low,r16(A.p2_bar))
        if p1act == ACT_SHADK then nitro_seen=true end
        if p1act == ACT_JADE_NITRO_SD and recover == 0 then
            recover=frame
            set_objx(A.p2_obj, objx(A.p1_obj)+45)
            log("recovery frame=%d r=%d x=%d/%d sag=%08x",frame,frame-fight,objx(A.p1_obj),objx(A.p2_obj),sag(A.p1_obj))
        end
        if p1act ~= last_p1act then
            log("r=%d p1act %04x->%04x x=%d/%d sag=%08x hp=%d/%d",frame-fight,last_p1act,p1act,objx(A.p1_obj),objx(A.p2_obj),sag(A.p1_obj),r16(A.p1_bar),r16(A.p2_bar))
            last_p1act=p1act
        end
        if p2act ~= last_p2act then
            local l,t,r,b=bounds(A.p1_obj)
            log("r=%d p2act %04x->%04x x=%d/%d jadebox=%d,%d..%d,%d",frame-fight,last_p2act,p2act,objx(A.p1_obj),objx(A.p2_obj),l,t,r,b)
            last_p2act=p2act
        end
        if p2act == 0x0107 then
            local p2o=r32(A.p2_obj); local px=s16(r16(p2o+OXPOS)); local py=s16(r16(p2o+OYPOS)); local fl=r16(p2o+OFLAGS)
            local sx=((fl & 0x10)~=0) and (px-0x4e) or (px+0x4e-0x38)
            local l,t,r,b=bounds(A.p1_obj)
            local p2p=r32(A.p2_proc); local hisproc=p2p~=0 and r32(p2p+0x170) or 0; local hisobj=p2p~=0 and r32(p2p+0x140) or 0
            log("  uppercut rel=%d flags=%04x strike=%d,%d..%d,%d jade=%d,%d..%d,%d proc=%08x/%08x obj=%08x/%08x",frame-fight,fl,sx,py-0x10,sx+0x38,py-0x10+0x40,l,t,r,b,hisproc,r32(A.p1_proc),hisobj,r32(A.p1_obj))
        end
        if p1hp_low < p1hp0 then
            finish(nitro_seen and upcut_pressed, "ducking uppercut damaged Jade during Nitro recovery")
            return
        end
        if frame-fight > 300 then
            finish(false,string.format("no punish hit nitro=%s recovery=%d upcut=%s",tostring(nitro_seen),recover,tostring(upcut_pressed)))
            return
        end
    end

    if charsel == 0 and frame > 1600 then finish(false,"never reached character select"); return end
    for name,field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
end)
