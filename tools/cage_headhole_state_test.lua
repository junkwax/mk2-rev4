-- cage_headhole_state_test.lua
-- Loads from a MAME save-state setup and performs Cage's head-hole fatality:
-- Back, Forward, Down+High Punch.  Intended for quick visual verification.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/cage_headhole_state_test.log", "w")
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
local did_initial_snap = false
local did_input_snap = false
local did_pull_snap = false
local did_head_snap = false
local did_fall_snap = false
local did_win_snap = false
local last_gstate = -1

local GSTATE  = 0x01129d90
local P1_CHAR = 0x01129e40
local P2_CHAR = 0x0112aa10
local P1_PROC = 0x01129e20
local P2_PROC = 0x0112a9f0
local P1_OBJ  = 0x01129de0
local P2_OBJ  = 0x0112a9b0
local F_DEATH = 0x0112b580
local PF_RAM  = 0x0112b660

local PROC_ACTION = 0x1f0
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OIMG    = 0x1a0

local MKBUG_START = 0xffa30000
local MKBUG_END   = 0xffa36000

local function cache_fields()
    local wanted = {
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 Down"] = true,
        ["P1 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[cage-headhole] input %-14s %s", name, fields[name] and "ok" or "MISSING"))
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
        print(string.format("[cage-headhole] SNAP frame=%d label=%s ok=%s %s",
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

local function pressed(name)
    -- Save-state path: Cage is facing left in quick.sta, so Back,Forward is Right,Left.
    if name == "P1 Right" then
        return frame >= 45 and frame < 51
    end
    if name == "P1 Left" then
        return frame >= 58 and frame < 64
    end
    if name == "P1 Down" then
        return frame >= 71 and frame < 91
    end
    if name == "P1 High Punch" then
        return frame >= 75 and frame < 95
    end
    return false
end

local function log_state(force)
    if not space then return end
    if not force and frame % 20 ~= 0 then return end
    local p1proc = space:read_u32(P1_PROC)
    local p2proc = space:read_u32(P2_PROC)
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p2act = p2proc ~= 0 and space:read_u16(p2proc + PROC_ACTION) or 0xffff
    local p1x, p1y, p2x, p2y, p1sag, p2sag = 0, 0, 0, 0, 0, 0
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = space:read_u16(p1obj + OBJ_OYPOS)
        local img = space:read_u32(p1obj + OBJ_OIMG)
        if img ~= 0 then p1sag = space:read_u32(img) end
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = space:read_u16(p2obj + OBJ_OYPOS)
        local img = space:read_u32(p2obj + OBJ_OIMG)
        if img ~= 0 then p2sag = space:read_u32(img) end
    end
    print(string.format(
        "[cage-headhole] frame=%d gs=%d p1c=%d p2c=%d fdeath=%d p1act=0x%04x p2act=0x%04x p1=(%d,%d sag=%s) p2=(%d,%d sag=%s) pc=%s pf=%s",
        frame,
        space:read_u16(GSTATE),
        space:read_u16(P1_CHAR),
        space:read_u16(P2_CHAR),
        space:read_u16(F_DEATH),
        p1act,
        p2act,
        p1x, p1y, hx(p1sag),
        p2x, p2y, hx(p2sag),
        hx(cpu_reg("PC")),
        hx(space:read_u32(PF_RAM))
    ))
end

local function check_lockup()
    local pc = cpu_reg("PC")
    if pc and pc >= MKBUG_START and pc <= MKBUG_END then
        print(string.format("[cage-headhole] ERROR mkbug lockup pc=%s", hx(pc)))
        log_state(true)
        snap("mkbug_lockup")
        manager.machine:exit()
        return true
    end
    return false
end

emu.add_machine_frame_notifier(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[cage-headhole] loaded: save-state quick, performing B,F,D+HP")
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[cage-headhole] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            last_gstate = gs
        end
        if check_lockup() then return end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    if frame >= 25 and not did_initial_snap then
        did_initial_snap = true
        log_state(true)
        snap("state_loaded")
    end
    if frame >= 100 and not did_input_snap then
        did_input_snap = true
        log_state(true)
        snap("after_input")
    end
    if frame >= 170 and not did_pull_snap then
        did_pull_snap = true
        log_state(true)
        snap("pull")
    end
    if frame >= 245 and not did_head_snap then
        did_head_snap = true
        log_state(true)
        snap("headhole")
    end
    if frame >= 330 and not did_fall_snap then
        did_fall_snap = true
        log_state(true)
        snap("fall")
    end
    if frame >= 470 and not did_win_snap then
        did_win_snap = true
        log_state(true)
        snap("win")
    end

    log_state(false)

    if frame >= 620 then
        log_state(true)
        snap("final")
        print("[cage-headhole] finished")
        manager.machine:exit()
    end
end)
