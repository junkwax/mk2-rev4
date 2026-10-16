-- Automated crash repro for the Jade port in the fn1 slot.
-- Requires the temporary MKAMODE test build (P1=fn1, P2=Reptile).

local frame, fight_frame, last_pc, stuck = 0, nil, nil, 0
local cpu, space = nil, nil
local fields = {}
local log = assert(io.open("C:/Users/you/Workplace/mk2-main/tools/jade_move_crash_test.log", "w"))

local function out(s)
    print(s); log:write(s, "\n"); log:flush()
end

local GSTATE, P1_PROC, FLASH_FLAG, DEBUG4 = 0x0112a830, 0x0112a8c0, 0x0112c470, 0x0112c750
local GS_FIGHTING, P_ACTION = 2, 0x1f0
local BUG_LO, BUG_HI = 0xffa30000, 0xffa37000

local wanted = {
    ["P1 Right"] = true, ["P1 Left"] = true,
    ["P1 High Punch"] = true, ["P1 Low Punch"] = true,
    ["P1 High Kick"] = true, ["P1 Low Kick"] = true,
    ["P2 Left"] = true, ["P2 High Punch"] = true,
}

local function input(name)
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    out(string.format("[jade] input %s", fields[name] and "ready" or "MISSING"))
end

-- Each entry is F, B + button, matching the actual trilogy handlers.
local tests = {
    { at=120, button="P1 High Punch", label="high boomerang" },
}

local function pressed(name, r)
    -- P2 Reptile (facing left): Forward, Forward + HP, timed to arrive
    -- during Flash's sixty-tick protection window.
    if name == "P2 Left" and r >= 138 and r < 148 then return true end
    if name == "P2 High Punch" and r >= 150 and r < 156 then return true end
    for _, t in ipairs(tests) do
        local d = r - t.at
        if name == "P1 Right" and d >= 0 and d < 4 then return true end
        if name == "P1 Left" and d >= 6 and d < 10 then return true end
        if t.twice and name == "P1 Left" and d >= 12 and d < 16 then return true end
        local fire = t.twice and 18 or 12
        if name == t.button and d >= fire and d < fire + 6 then return true end
    end
    return false
end

local function reg(n)
    local ok, v = pcall(function() return cpu.state[n].value end)
    return ok and v or nil
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        input("P1 Right")
        out("[jade] harness loaded")
    end
    if not space then return end

    if not fight_frame and space:read_u16(GSTATE) == GS_FIGHTING then
        fight_frame = frame
        out(string.format("[jade] fight begins frame=%d", frame))
    end
    if fight_frame then
        local r = frame - fight_frame
        local proc = space:read_u32(P1_PROC)
        local action = proc ~= 0 and space:read_u16(proc + P_ACTION) or 0xffff
        local pc = reg("PC") or 0
        if r % 20 == 0 then out(string.format("[jade] r=%d pc=%08x action=%04x flash=%d debug4=%04x", r, pc, action, space:read_u16(FLASH_FLAG), space:read_u16(DEBUG4))) end
        for _, t in ipairs(tests) do
            if r == t.at then out("[jade] firing " .. t.label) end
        end
        if pc == last_pc then stuck = stuck + 1 else stuck = 0; last_pc = pc end
        if (pc >= BUG_LO and pc <= BUG_HI) or stuck >= 45 then
            out(string.format("[jade] CRASH pc=%08x action=%04x flash=%d debug4=%04x stuck=%d", pc, action, space:read_u16(FLASH_FLAG), space:read_u16(DEBUG4), stuck))
            manager.machine:exit(); return
        end
        if r > 760 then out("[jade] PASS no CPU lockup"); manager.machine:exit(); return end
        for name, field in pairs(fields) do field:set_value(pressed(name, r) and 1 or 0) end
    end
end)
