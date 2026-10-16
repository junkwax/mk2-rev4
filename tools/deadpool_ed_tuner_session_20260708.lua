-- deadpool_ed_tuner_session_20260708.lua
--
-- Fresh session entry point for the Dead Pool Ed/body/chain tuner.
-- Keep per-session stage-test Lua files unique; the shared tuner logic stays in
-- tools/deadpool_ed_tuner.lua.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP_PATH = ROOT .. "/src/mk2.map"
local LOG_PATH = ROOT .. "/tmp/dp/deadpool_ed_tuner_session_20260708.log"

local logf = io.open(LOG_PATH, "w")
local function slog(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    local line = string.format("[deadpool-session-20260708] %s", msg)
    print(line)
    if logf then
        logf:write(line .. "\n")
        logf:flush()
    end
end

local function map_symbol(name, fallback)
    local f = io.open(MAP_PATH, "r")
    if not f then return fallback end
    for line in f:lines() do
        for addr, sym in line:gmatch("([0-9A-Fa-f]+)%s+([_%w]+)") do
            if sym == name then
                f:close()
                return tonumber(addr, 16)
            end
        end
    end
    f:close()
    return fallback
end

local space
pcall(function()
    space = manager.machine.devices[":maincpu"].spaces["program"]
end)

local A = {
    gstate = map_symbol("gstate", 0),
    curback = map_symbol("curback", 0),
    p1_char = map_symbol("p1_char", 0),
}

local fields = {}
local input_cached = false
local frame = 0
local charsel_frame = 0
local p1_confirm_start = 0
local armed = false
local last_state_log = -1

local GS_PSEL = 1
local GS_FIGHTING = 2
local GS_POST = 13
local DEAD_POOL = 0
local FT_REPTILE = 9

local function r16(addr)
    if not space or not addr or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(addr) end)
    return ok and v or 0
end

local function w16(addr, value)
    if not space or not addr or addr == 0 then return end
    pcall(function() space:write_u16(addr, value & 0xffff) end)
end

local function cache_fields()
    if input_cached then return end
    input_cached = true
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Right"] = true,
        ["P1 Down"] = true,
        ["P1 High Punch"] = true,
        ["P2 Down"] = true,
        ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for name, field in pairs(port.fields) do
            if wanted[name] then fields[name] = field end
        end
    end
    local n = 0
    for _, _ in pairs(fields) do n = n + 1 end
    slog("cached input fields=%d", n)
end

local function press(name, on)
    local field = fields[name]
    if not field then return end
    if on then field:set_value(1) else field:clear_value() end
end

local function clear_inputs()
    for _, field in pairs(fields) do field:clear_value() end
end

local function drive_to_deadpool_fight()
    if armed then
        clear_inputs()
        return
    end

    cache_fields()
    clear_inputs()

    local gs = r16(A.gstate)
    if gs == GS_PSEL or gs == GS_POST or gs == 6 or gs == 7 then
        w16(A.curback, DEAD_POOL)
    end

    if gs == GS_PSEL and charsel_frame == 0 then
        charsel_frame = frame
        slog("charsel reached frame=%d", frame)
    end

    if frame >= 5 and frame < 35 then press("UI Select", true) end
    if frame >= 700 and frame < 980 and (frame % 80) < 20 then
        press("Coin 1", true)
        press("Coin 2", true)
    end
    if frame >= 1000 and frame < 1080 then press("1 Player Start", true) end
    if frame >= 1040 and frame < 1140 then press("2 Players Start", true) end

    if charsel_frame > 0 and gs == GS_PSEL then
        local rel = frame - charsel_frame
        if (rel >= 80 and rel < 88) or (rel >= 135 and rel < 143) or (rel >= 190 and rel < 198) then
            press("P1 Right", true)
        end
        if p1_confirm_start == 0 and rel >= 225 and r16(A.p1_char) == FT_REPTILE then
            p1_confirm_start = frame
            slog("P1 Reptile reached; confirming")
        end
        if p1_confirm_start > 0 then
            if frame >= p1_confirm_start and frame < p1_confirm_start + 40 then press("P1 High Punch", true) end
            if frame >= p1_confirm_start + 45 and frame < p1_confirm_start + 53 then press("P2 Down", true) end
            if frame >= p1_confirm_start + 90 and frame < p1_confirm_start + 130 then press("P2 High Punch", true) end
        end
    end

    if frame % 120 == 0 and frame ~= last_state_log then
        last_state_log = frame
        slog("boot frame=%d gstate=%d curback=%d p1=%d", frame, gs, r16(A.curback), r16(A.p1_char))
    end

    if gs == GS_FIGHTING and r16(A.curback) == DEAD_POOL then
        armed = true
        clear_inputs()
        slog("Dead Pool fight reached frame=%d", frame)
    elseif frame > 5600 and gs ~= GS_FIGHTING then
        slog("BOOT_TIMEOUT gstate=%d curback=%d", gs, r16(A.curback))
    end
end

emu.register_frame(function()
    frame = frame + 1
    drive_to_deadpool_fight()
end)

slog("Dead Pool session boot driver loaded")

dofile("C:/Users/you/Workplace/mk2-main/tools/deadpool_ed_tuner.lua")
