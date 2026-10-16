-- Runtime regression: Jade can perform Nitro Kick twice in one round after
-- restoring the move's native NROKICK_P palette.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG = ROOT .. "/tools/jade_nitro_repeat_test.log"
local out = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[jade-nitro-repeat] " .. string.format(fmt, ...)
    print(line); out:write(line, "\n"); out:flush()
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
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"), p1_proc=sym("p1_proc"),
}
local P_ACTION, OXPOS, OPAL = 0x1f0, 0x90, 0x140
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_REPTILE, FT_JADE, PS_ACTIVE = 4, 9, 16, 1
local ACT_SHADK = 0x0205

local frame, space, charsel, confirm, fight = 0, nil, 0, 0, 0
local fields, finished, last_action = {}, false, 0xffff
local nitro_count, second_seen = 0, 0
local move_times = {80, 230}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v & 0xffff) end
local function action()
    local p = r32(A.p1_proc)
    return p ~= 0 and r16(p + P_ACTION) or 0xffff
end
local function set_x(addr, x)
    local obj = r32(addr)
    if obj ~= 0 then w16(obj + OXPOS, x) end
end
local function p1_opal()
    local obj = r32(A.p1_obj)
    return obj ~= 0 and r16(obj + OPAL) or 0xffff
end
local function finish(ok, why)
    if finished then return end
    finished = true
    log("%s reason=%s nitro_count=%d gstate=%d char=%d opal=%04x",
        ok and "PASS" or "ERROR", why, nitro_count, r16(A.gstate),
        r16(A.p1_char), p1_opal())
    out:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 Down"]=true, ["P1 Right"]=true, ["P1 Low Kick"]=true,
        ["P1 High Punch"]=true, ["P2 High Punch"]=true,
    }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name]=field end
        end
    end
end

local function in_window(rel, start, length) return rel >= start and rel < start + length end
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
    local rel = frame - fight
    for _,start in ipairs(move_times) do
        if name == "P1 Down" and in_window(rel,start,4) then return true end
        if name == "P1 Right" and in_window(rel,start+6,4) then return true end
        if name == "P1 Low Kick" and in_window(rel,start+12,6) then return true end
    end
    return false
end

emu.register_frame(function()
    frame=frame+1
    if frame == 1 then
        space=manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields(); log("loaded")
    end
    if finished then return end
    local gs=r16(A.gstate)
    if gs == GS_PSEL then
        if charsel == 0 then charsel=frame end
        w16(A.p1_state,PS_ACTIVE); w16(A.p2_state,PS_ACTIVE)
        w16(A.p1_char,FT_KITANA); w16(A.p2_char,FT_REPTILE)
        if confirm == 0 and frame-charsel > 90 then confirm=frame end
    elseif gs == GS_POST then
        w16(A.p1_char,FT_JADE)
    elseif gs == GS_FIGHTING and fight == 0 then
        fight=frame
        set_x(A.p2_obj,900)
        log("fight frame=%d chars=%d/%d",frame,r16(A.p1_char),r16(A.p2_char))
    end

    if fight > 0 then
        set_x(A.p2_obj,900)
        local act=action()
        if act == ACT_SHADK and last_action ~= ACT_SHADK then
            nitro_count=nitro_count+1
            log("nitro %d entered frame=%d rel=%d opal=%04x",nitro_count,frame,frame-fight,p1_opal())
            if nitro_count == 2 then second_seen=frame end
        end
        last_action=act
        if second_seen > 0 and frame-second_seen >= 120 then
            if gs ~= GS_FIGHTING then finish(false,"left_fighting_state_after_second_kick")
            elseif r32(A.p1_obj) == 0 or r32(A.p1_proc) == 0 then finish(false,"player_object_or_process_lost")
            elseif r16(A.p1_char) ~= FT_JADE then finish(false,"Jade_character_lost")
            else finish(true,"second_nitro_kick_completed_without_crash") end
            return
        end
        if frame-fight > 520 then finish(false,"second_nitro_kick_not_seen"); return end
    end

    for name,field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if charsel == 0 and frame > 1700 then finish(false,"never_reached_character_select") end
end)
