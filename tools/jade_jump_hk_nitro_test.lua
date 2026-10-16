-- Regression for the reported transition: Jade lands a forward-jump high
-- kick, then immediately performs Down, Forward + LK (Nitro Kick).

local ROOT = "C:/Users/you/Workplace/mk2-main"
local out = assert(io.open(ROOT .. "/tools/jade_jump_hk_nitro_test.log", "w"))
local function log(fmt, ...)
    local s = "[jade-jhk-nitro] " .. string.format(fmt, ...)
    print(s); out:write(s, "\n"); out:flush()
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
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"), curback=sym("curback"),
    lock_lo=sym("system_lockup"), lock_hi=sym("TVBPX") + 0x200,
}
local P_ACTION, OXPOS, OYPOS, OXVEL, OYVEL = 0x1f0, 0x90, 0xb0, 0xc0, 0xd0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_SUBZERO, FT_NOOB, FT_JADE, PS_ACTIVE = 4, 8, 15, 16, 1
local ACT_STANCE, ACT_LAND, ACT_ANGLE_JUMP = 0x0303, 0x0304, 0x0308
local ACT_FLYKICK, ACT_FK_SD, ACT_NITRO, ACT_NITRO_SD = 0x0200, 0x060d, 0x0205, 0x061c

local frame, cpu, space = 0, nil, nil
local fields, charsel, confirm, fight = {}, 0, 0, 0
local last_action, jump_seen, kick_seen = 0xffff, false, false
local landed, nitro_at, nitro_seen, finished = 0, 0, false, false
local cycle, jump_at, completed = 1, 70, 0
local nitro_forward = "P1 Right"
local p2hp0, p2hp_low, stuck_pc, stuck_count = nil, nil, nil, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v & 0xffff) end
local function proc_action(addr)
    local p=r32(addr); return p ~= 0 and r16(p+P_ACTION) or 0xffff
end
local function obj_info(addr)
    local o=r32(addr)
    if o == 0 then return 0,0,0,0 end
    return r16(o+OXPOS),r16(o+OYPOS),r32(o+OXVEL),r32(o+OYVEL)
end
local function set_x(addr,x)
    local o=r32(addr); if o ~= 0 then w16(o+OXPOS,x) end
end
local function pc_value()
    local ok,v=pcall(function() return cpu.state["PC"].value end)
    return ok and v or 0
end
local function finish(ok, why)
    if finished then return end
    finished=true
    log("%s %s jump=%s kick=%s nitro=%s p2hp=%d->%d pc=%08x",
        ok and "PASS" or "ERROR",why,tostring(jump_seen),tostring(kick_seen),
        tostring(nitro_seen),p2hp0 or -1,p2hp_low or -1,pc_value())
    out:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted={
        ["Coin 1"]=true,["Coin 2"]=true,["1 Player Start"]=true,["2 Players Start"]=true,
        ["P1 Up"]=true,["P1 Left"]=true,["P1 Right"]=true,["P1 Down"]=true,
        ["P1 High Punch"]=true,["P1 High Kick"]=true,["P1 Low Kick"]=true,
        ["P2 High Punch"]=true,
    }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name]=field end
        end
    end
    for name in pairs(wanted) do if not fields[name] then log("missing input %s",name) end end
end

local function inwin(n,s,e) return n >= s and n < e end
local function pressed(name)
    if name == "Coin 1" or name == "Coin 2" then
        return charsel == 0 and frame >= 700 and frame < 980 and frame % 80 < 20
    end
    if name == "1 Player Start" then return charsel == 0 and inwin(frame,1000,1080) end
    if name == "2 Players Start" then
        if charsel > 0 and fight == 0 then return inwin(frame-charsel,5,45) end
        return charsel == 0 and inwin(frame,1040,1140)
    end
    if charsel > 0 and fight == 0 and confirm > 0 then
        if name == "P1 High Punch" then return inwin(frame,confirm,confirm+40) end
        if name == "P2 High Punch" then return inwin(frame,confirm+70,confirm+110) end
    end
    if fight == 0 then return false end
    local r=frame-fight
    -- Forward jump; hit HK after the flip is established.
    if name == "P1 Up" then return inwin(r,jump_at,jump_at+8) end
    if name == "P1 Right" then
        if inwin(r,jump_at,jump_at+8) then return true end
        if nitro_at > 0 and nitro_forward == name then return inwin(frame,nitro_at+6,nitro_at+10) end
    end
    if name == "P1 Left" and nitro_at > 0 and nitro_forward == name then
        return inwin(frame,nitro_at+6,nitro_at+10)
    end
    if name == "P1 High Kick" then return inwin(r,jump_at+18,jump_at+26) end
    if nitro_at > 0 then
        if name == "P1 Down" then return inwin(frame,nitro_at,nitro_at+4) end
        if name == "P1 Low Kick" then return inwin(frame,nitro_at+12,nitro_at+18) end
    end
    return false
end

emu.register_frame(function()
    frame=frame+1
    if frame == 1 then
        cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]
        cache_fields(); log("loaded lock=%08x..%08x",A.lock_lo,A.lock_hi)
    end
    if finished then return end

    local gs=r16(A.gstate)
    if gs == GS_PSEL then
        if charsel == 0 then charsel=frame; log("character select frame=%d",frame) end
        w16(A.p1_state,PS_ACTIVE); w16(A.p2_state,PS_ACTIVE)
        w16(A.p1_char,FT_KITANA); w16(A.p2_char,FT_SUBZERO)
        if confirm == 0 and frame-charsel > 90 then confirm=frame end
    elseif gs == GS_POST then
        w16(A.p1_char,FT_JADE); w16(A.p2_char,FT_NOOB)
        w16(A.curback,5) -- Armory, matching the supplied crash screenshot
    elseif gs == GS_FIGHTING and fight == 0 then
        fight=frame; p2hp0=r16(A.p2_bar); p2hp_low=p2hp0
        set_x(A.p2_obj,620)
        log("fight=%d chars=%d/%d stage=%d",frame,r16(A.p1_char),r16(A.p2_char),r16(A.curback))
        if r16(A.p1_char) ~= FT_JADE or r16(A.p2_char) ~= FT_NOOB then
            finish(false,"secret character setup failed"); return
        end
    end

    if fight > 0 then
        local r=frame-fight
        local act=proc_action(A.p1_proc)
        local x,y,xv,yv=obj_info(A.p1_obj)
        local pc=pc_value()
        p2hp_low=math.min(p2hp_low,r16(A.p2_bar))

        if act ~= last_action then
            log("r=%d action=%04x->%04x pos=%d,%d vel=%08x,%08x p2act=%04x hp2=%d",
                r,last_action,act,x,y,xv,yv,proc_action(A.p2_proc),r16(A.p2_bar))
            last_action=act
        end
        if act == ACT_ANGLE_JUMP then jump_seen=true end
        if act == ACT_FLYKICK or act == ACT_FK_SD then kick_seen=true end
        if act == ACT_NITRO or act == ACT_NITRO_SD then nitro_seen=true end

        -- Queue Nitro immediately after the jump-kick landing animation yields
        -- back to stance. This is the transition reported by the player.
        if kick_seen and landed == 0 and act == ACT_LAND then landed=frame end
        if landed > 0 and nitro_at == 0 and act == ACT_STANCE then
            local p1x=obj_info(A.p1_obj); local p2x=obj_info(A.p2_obj)
            nitro_forward=(p1x < p2x) and "P1 Right" or "P1 Left"
            nitro_at=frame+1
            log("queue Nitro frame=%d rel=%d forward=%s x=%d/%d",nitro_at,nitro_at-fight,nitro_forward,p1x,p2x)
        end

        -- Once Nitro has fully yielded back to stance, stage the same hit
        -- sequence again. Five cycles cover the previously reported second-use
        -- failure and overlap successive smoke-process lifetimes.
        if nitro_seen and act == ACT_STANCE and frame > nitro_at+25 then
            completed=completed+1
            log("cycle %d complete rel=%d",cycle,r)
            if completed >= 5 then
                finish(true,"five jump-HK to Nitro hit cycles completed without lockup"); return
            end
            cycle=cycle+1
            jump_seen=false; kick_seen=false; nitro_seen=false
            landed=0; nitro_at=0; jump_at=r+45
            w16(A.p2_bar,161)
            set_x(A.p1_obj,469); set_x(A.p2_obj,620)
            log("stage cycle %d jump rel=%d",cycle,jump_at)
        end

        if pc >= A.lock_lo and pc <= A.lock_hi then
            finish(false,string.format("entered lockup/illegal-opcode block at %08x",pc)); return
        end
        if pc == stuck_pc then stuck_count=stuck_count+1 else stuck_pc=pc; stuck_count=0 end
        if stuck_count > 90 then finish(false,string.format("CPU stuck at %08x",pc)); return end

        if r > 1150 then finish(false,"repeated sequence did not complete"); return end
    end

    if charsel == 0 and frame > 1700 then finish(false,"never reached character select"); return end
    for name,field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
end)
