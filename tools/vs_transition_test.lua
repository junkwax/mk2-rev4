-- vs_transition_test.lua
-- Drive a quick two-player character select and monitor the transition into
-- the VS screen / stage picker.  Intended for pre-VS crash debugging.

local frame = 0
local fields = {}
local space = nil
local cpu = nil
local charsel_frame = 0
local last_gstate = -1
local select_logged = false
local did_vs_snap = false
local did_error_snap = false

local ACTIVE   = 0x010dc6d0
local GSTATE   = 0x01129d90
local P1_STATE = 0x01129db0
local P2_STATE = 0x0112a980
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local CURBACK  = 0x0112b680
local BATTLE   = 0x01129d80
local PF_RAM   = 0x0112b660
local OBJLST   = 0x01127030
local OBJLST2  = 0x01127050

local PROC_NEXT = 0x000
local PROC_ID   = 0x020
local PROC_WAKE = 0x0e0

local GS_PSEL = 4
local GS_POST_PSEL = 0x0d
local GS_PFSETUP = 6
local GS_ROUND = 7
local GS_FIGHTING = 2

local PID_P1SEL = 0x0a
local PID_P2SEL = 0x0b

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 High Punch"] = true,
        ["P2 High Punch"] = true,
        ["P1 Low Punch"] = true,
        ["P2 Low Punch"] = true,
        ["P1 Low Kick"] = true,
        ["P2 Low Kick"] = true,
        ["P1 Start"] = true,
        ["P2 Start"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P2 Left"] = true,
        ["P2 Right"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        if fields[name] then
            print(string.format("[vsprobe] input-field found: %s", name))
        end
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
        print(string.format("[vsprobe] SNAP frame=%d label=%s ok=%s %s",
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
        p = space:read_u32(p)
    end
    return count
end

local function find_process(pid)
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid then
            return p
        end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return 0
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    -- Add enough credits, then start a 2-player game.
    if name == "Coin 1" or name == "Coin 2" then
        return (frame >= 700 and frame < 980 and (frame % 80) < 20)
    end
    if name == "1 Player Start" then
        return frame >= 1000 and frame < 1080
    end
    if name == "2 Players Start" then
        return frame >= 1040 and frame < 1140
    end

    if charsel_frame > 0 then
        local r = frame - charsel_frame
        -- Select defaults quickly.  Use staggered confirms to avoid both
        -- cursors racing the shared flash path on the exact same frame.
        if name == "P1 High Punch" then return r >= 130 and r < 170 end
        if name == "P2 High Punch" then return r >= 190 and r < 230 end

        -- On the stage-select screen, confirm after we have had time to render.
        if name == "P1 Low Kick" then return r >= 620 and r < 660 end
    end
    return false
end

local function log_state(force)
    if not space then return end
    local g = space:read_u16(GSTATE)
    if g ~= last_gstate then
        print(string.format("[vsprobe] frame=%d gstate %d -> %d", frame, last_gstate, g))
        last_gstate = g
    end
    if not force and frame % 30 ~= 0 then return end

    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local sp = cpu_reg("SP")
    local b14 = cpu_reg("B14") or cpu_reg("b14")
    local b3 = cpu_reg("B3") or cpu_reg("b3")
    local b4 = cpu_reg("B4") or cpu_reg("b4")
    local a0 = cpu_reg("A0") or cpu_reg("a0")
    local a4 = cpu_reg("A4") or cpu_reg("a4")
    local a6 = cpu_reg("A6") or cpu_reg("a6")
    local a7 = cpu_reg("A7") or cpu_reg("a7")
    local a8 = cpu_reg("A8") or cpu_reg("a8")
    local a10 = cpu_reg("A10") or cpu_reg("a10")
    local p1sel = find_process(PID_P1SEL)
    local p2sel = find_process(PID_P2SEL)
    print(string.format(
        "[vsprobe] frame=%-5d g=%02x p1s=%04x p2s=%04x p1c=%04x p2c=%04x cur=%04x battle=%04x p1sel=%s p2sel=%s obj=%d obj2=%d pc=%s sp=%s b14=%s a0=%s a4=%s a6=%s a7=%s a8=%s a10=%s b3=%s b4=%s pf=%s",
        frame,
        g,
        space:read_u16(P1_STATE),
        space:read_u16(P2_STATE),
        space:read_u16(P1_CHAR),
        space:read_u16(P2_CHAR),
        space:read_u16(CURBACK),
        space:read_u16(BATTLE),
        hx(p1sel),
        hx(p2sel),
        count_list(OBJLST),
        count_list(OBJLST2),
        hx(pc),
        hx(sp),
        hx(b14),
        hx(a0),
        hx(a4),
        hx(a6),
        hx(a7),
        hx(a8),
        hx(a10),
        hx(b3),
        hx(b4),
        hx(space:read_u32(PF_RAM))))

    if charsel_frame == 0 and g == GS_PSEL then
        charsel_frame = frame
        print(string.format("[vsprobe] char select begins at frame=%d", frame))
    end

    if not select_logged and charsel_frame > 0 and frame - charsel_frame > 170 then
        select_logged = true
        print(string.format("[vsprobe] after confirms p1_char=%04x p2_char=%04x p1_state=%04x p2_state=%04x",
            space:read_u16(P1_CHAR), space:read_u16(P2_CHAR),
            space:read_u16(P1_STATE), space:read_u16(P2_STATE)))
    end

    if not did_vs_snap and g == GS_POST_PSEL and frame > 1280 and count_list(OBJLST2) > 20 then
        did_vs_snap = true
        snap("vs_screen")
    end

    local pcv = pc or 0
    if not did_error_snap and pcv >= 0xffa30900 and pcv <= 0xffa30c00 then
        did_error_snap = true
        snap("system_lockup")
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[vsprobe] loaded - driving 2P select into VS screen")
    end

    for name, field in pairs(fields) do
        if pressed(name) then
            field:set_value(1)
        else
            field:clear_value()
        end
    end

    if space then
        log_state(false)
    end
end)
