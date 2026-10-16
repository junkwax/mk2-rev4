-- kitana_fan_duel_test.lua
-- Selects Kitana vs Kitana, repeatedly throws and steers fans, and exits on
-- obvious runaway object/state corruption.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/kitana_fan_duel_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local fields, cpu, space = {}, nil, nil
local charsel_frame, vs_frame, fighting_frame = 0, 0, 0
local p1_confirm_start = 0
local last_gstate = -1
local did_error = false

local ACTIVE   = 0x010dc6d0
local GSTATE   = 0x01129d90
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local P1_OBJ   = 0x01129de0
local P2_OBJ   = 0x0112a9b0
local P1_PROC  = 0x01129e20
local P2_PROC  = 0x0112a9f0
local P1_BAR   = 0x01129eb0
local P2_BAR   = 0x0112aa80
local OBJLST   = 0x01127030
local OBJLST2  = 0x01127050

local PROC_NEXT   = 0x000
local PROC_ID     = 0x020
local PROC_ACTION = 0x1f0
local OBJ_NEXT    = 0x000
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OCHAR   = 0x1f0

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_KITANA   = 4

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Up"] = true,
        ["P1 Down"] = true,
        ["P1 Right"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Punch"] = true,
        ["P1 Low Kick"] = true,
        ["P2 Up"] = true,
        ["P2 Down"] = true,
        ["P2 Left"] = true,
        ["P2 High Punch"] = true,
        ["P2 Low Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[fan-duel] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, value = pcall(function() return item.value end)
    if okv then return value end
    okv, value = pcall(function() return item() end)
    if okv then return value end
    return nil
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value)
end

local function count_list(addr)
    local p = space:read_u32(addr)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
    end
    return count
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame

        if vs_frame > 0 then
            if name == "P1 Low Kick" then
                return frame >= vs_frame + 260 and frame < vs_frame + 315
            end
            return false
        end

        -- P1 Liu Kang -> Kitana: right, right, down.
        if name == "P1 Right" then
            return (r >= 80 and r < 88) or (r >= 135 and r < 143)
        end
        if name == "P1 Down" then return r >= 190 and r < 198 end
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end

        -- P2 Reptile -> Kitana: left, down.
        if name == "P2 Left" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 45 and frame < p1_confirm_start + 53
        end
        if name == "P2 Down" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 90 and frame < p1_confirm_start + 98
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 135 and frame < p1_confirm_start + 175
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if r > 60 and r < 2400 then
            local c = r % 124
            -- Fan throw is toward, toward, LP; keep HP/up/down active afterward
            -- to stress boomerang and vertical steering.
            if name == "P1 Right" then return (c >= 6 and c < 14) or (c >= 22 and c < 30) end
            if name == "P1 Low Punch" then return c >= 34 and c < 48 end
            if name == "P1 High Punch" then return c >= 48 and c < 110 end
            if name == "P1 Up" then return c >= 52 and c < 70 end
            if name == "P1 Down" then return c >= 78 and c < 98 end

            if name == "P2 Left" then return (c >= 6 and c < 14) or (c >= 22 and c < 30) end
            if name == "P2 Low Punch" then return c >= 34 and c < 48 end
            if name == "P2 High Punch" then return c >= 48 and c < 110 end
            if name == "P2 Down" then return c >= 52 and c < 70 end
            if name == "P2 Up" then return c >= 78 and c < 98 end
        end
    end
    return false
end

local function log_state(force)
    if not space or (not force and frame % 60 ~= 0) then return end
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p2proc = space:read_u32(P2_PROC)
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p2act = p2proc ~= 0 and space:read_u16(p2proc + PROC_ACTION) or 0xffff
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1obj ~= 0 then p1x = space:read_u16(p1obj + OBJ_OXPOS); p1y = space:read_u16(p1obj + OBJ_OYPOS) end
    if p2obj ~= 0 then p2x = space:read_u16(p2obj + OBJ_OXPOS); p2y = space:read_u16(p2obj + OBJ_OYPOS) end
    print(string.format(
        "[fan-duel] frame=%d gs=%d chars=%d/%d acts=0x%04x/0x%04x xy=%d,%d/%d,%d hp=%d/%d obj=%d obj2=%d pc=%s",
        frame, space:read_u16(GSTATE), space:read_u16(P1_CHAR), space:read_u16(P2_CHAR),
        p1act, p2act, p1x, p1y, p2x, p2y, space:read_u16(P1_BAR), space:read_u16(P2_BAR),
        count_list(OBJLST), count_list(OBJLST2), hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC"))))
end

local function check_bad_state()
    if did_error or not space or fighting_frame == 0 then return false end
    local obj_count = count_list(OBJLST)
    if obj_count > 160 then
        did_error = true
        log_state(true)
        print(string.format("[fan-duel] ERROR object runaway obj_count=%d", obj_count))
        manager.machine:exit()
        return true
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[fan-duel] start")
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[fan-duel] gstate %d -> %d at frame %d", last_gstate, gs, frame))
            last_gstate = gs
        end
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
        if charsel_frame > 0 and p1_confirm_start == 0 and space:read_u16(P1_CHAR) == FT_KITANA then
            p1_confirm_start = frame + 30
            print(string.format("[fan-duel] p1 kitana locked at frame %d", frame))
        end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            print(string.format("[fan-duel] fighting at frame %d", frame))
        end
        log_state(false)
        if check_bad_state() then return end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame > 0 and frame > fighting_frame + 2200 then
        log_state(true)
        print("[fan-duel] PASS reached end of stress window")
        manager.machine:exit()
    end

    if fighting_frame == 0 and frame > 6200 then
        log_state(true)
        print("[fan-duel] ERROR never reached fighting state")
        manager.machine:exit()
    end
end)

emu.register_stop(function()
    if logfh then logfh:close(); logfh = nil end
end)
