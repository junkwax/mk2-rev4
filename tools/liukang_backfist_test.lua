-- liukang_backfist_test.lua
-- Drives a 2P match, keeps P1 on Liu Kang, performs back+HP, and snapshots
-- the LKBFIST image-ROM animation path.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/liukang_backfist_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local fields = {}
local cpu = nil
local space = nil
local charsel_frame = 0
local vs_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local last_gstate = -1
local did_move_snap = false
local did_hit_snap = false
local did_error = false

local ACTIVE   = 0x010dc6d0
local GSTATE   = 0x01129d90
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local P1_OBJ   = 0x01129de0
local P2_OBJ   = 0x0112a9b0
local P1_PROC  = 0x01129e20
local P2_BAR   = 0x0112aa80
local PF_RAM   = 0x0112b660
local OBJLST   = 0x01127030
local OBJLST2  = 0x01127050

local PROC_ACTION = 0x1f0

local OBJ_NEXT    = 0x000
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OFLAGS  = 0x0f0
local OBJ_OFLAGS2 = 0x160
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_LIUKANG  = 1
local ACT_LKBACKFIST = 0x010c
local MKBUG_START = 0xffa30000
local MKBUG_END   = 0xffa36000

local p2_bar_start = nil

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Left"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
        ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[lkbfist] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    local s = main_screen()
    if s then
        local ok, err = pcall(function() s:snapshot() end)
        print(string.format("[lkbfist] SNAP frame=%d label=%s ok=%s %s",
            frame, label, tostring(ok), ok and "" or tostring(err)))
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
    if not space then return 0 end
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
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        local cycle = r % 120
        if r > 80 and r < 720 then
            -- P1 starts on the left, facing right, so left is back.
            if name == "P1 Left" then
                return cycle >= 22 and cycle < 56
            end
            if name == "P1 High Punch" then
                return cycle >= 30 and cycle < 56
            end
        end
    end

    return false
end

local function log_state(force)
    if not space then return end
    if not force and frame % 20 ~= 0 then return end

    local gs = space:read_u16(GSTATE)
    local p1c = space:read_u16(P1_CHAR)
    local p2c = space:read_u16(P2_CHAR)
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p1x, p1y, p1flags, p1flags2, p1ochar, p1sag = 0, 0, 0, 0, 0xffff, 0
    local p2x, p2y, p2ochar = 0, 0, 0xffff
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = space:read_u16(p1obj + OBJ_OYPOS)
        p1flags = space:read_u16(p1obj + OBJ_OFLAGS)
        p1flags2 = space:read_u16(p1obj + OBJ_OFLAGS2)
        p1ochar = space:read_u16(p1obj + OBJ_OCHAR)
        local p1img = space:read_u32(p1obj + OBJ_OIMG)
        if p1img ~= 0 then p1sag = space:read_u32(p1img) end
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = space:read_u16(p2obj + OBJ_OYPOS)
        p2ochar = space:read_u16(p2obj + OBJ_OCHAR)
    end
    local p2bar = space:read_u16(P2_BAR)
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local sp = cpu_reg("SP")
    local b14 = cpu_reg("B14") or cpu_reg("b14")
    local pf = space:read_u32(PF_RAM)

    print(string.format(
        "[lkbfist] frame=%d gs=%d p1=%d p2=%d p1objchar=%d p2objchar=%d act=0x%04x p1xy=%d,%d p2xy=%d,%d flags=0x%04x flags2=0x%04x sag=0x%08x p2bar=%d obj=%d obj2=%d pc=%s sp=%s b14=%s pf=%s",
        frame, gs, p1c, p2c, p1ochar, p2ochar, p1act, p1x, p1y, p2x, p2y,
        p1flags, p1flags2, p1sag, p2bar, count_list(OBJLST), count_list(OBJLST2),
        hx(pc), hx(sp), hx(b14), hx(pf)))

    if p1act == ACT_LKBACKFIST and not did_move_snap then
        did_move_snap = true
        snap("backfist_action")
    end
    if p2_bar_start and p2bar < p2_bar_start and not did_hit_snap then
        did_hit_snap = true
        snap("backfist_hit")
        print(string.format("[lkbfist] hit detected p2bar %d -> %d", p2_bar_start, p2bar))
    end
end

local function check_cpu_lockup()
    if did_error or not space or fighting_frame == 0 then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = space:read_u32(PF_RAM)
    if pf == 0xffffffff or (pc and pc >= MKBUG_START and pc <= MKBUG_END) then
        did_error = true
        log_state(true)
        snap("mkbug_lockup")
        print(string.format("[lkbfist] ERROR mkbug_lockup pc=%s pf=%s", hx(pc), hx(pf)))
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
        print("[lkbfist] loaded: selecting P1 Liu Kang, then firing back+HP")
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[lkbfist] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                p2_bar_start = space:read_u16(P2_BAR)
                snap("fight_start")
            end
            last_gstate = gs
        end

        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 70 then
            local p1c = space:read_u16(P1_CHAR)
            if p1c == FT_LIUKANG then
                p1_confirm_start = frame + 25
                print(string.format("[lkbfist] P1 Liu Kang selected; confirm starts at %d", p1_confirm_start))
            end
        end

        log_state(false)
        if check_cpu_lockup() then return end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame > 0 and frame > fighting_frame + 820 then
        log_state(true)
        snap("final")
        if not did_move_snap then
            print("[lkbfist] ERROR action 0x010c was never observed")
        elseif not did_hit_snap then
            print("[lkbfist] ERROR hit was never observed")
        else
            print("[lkbfist] finished")
        end
        manager.machine:exit()
    end
end)
