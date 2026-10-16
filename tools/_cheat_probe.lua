-- _cheat_probe.lua
-- Verifies the two start-button cheats on a real 1P flow:
--   CHEAT_MODE=kahn : press Start 5x on character select -> expect
--                     f_kahn_cheat=1 and map_position=14 (fight Kahn next)
--   CHEAT_MODE=noob : hold Start through the pre-match handoff -> expect
--                     p2_char=15 (Noob Saibot) when the fight starts

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local MODE = os.getenv("CHEAT_MODE") or "kahn"
local LOG_PATH = ROOT .. "/tools/_cheat_probe_" .. MODE .. ".log"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(name, fb)
    local v = symbols[name]
    if v then return v end
    print("[cheat] WARN missing symbol " .. name)
    return fb or 0
end

local A = {
    gstate       = sym("gstate"),
    p1_char      = sym("p1_char"),
    p2_char      = sym("p2_char"),
    f_kahn_cheat = sym("f_kahn_cheat"),
    c_kahn_cheat = sym("c_kahn_cheat"),
    map_position = sym("map_position"),
    winner_status = sym("winner_status"),
}

local GS_PSEL, GS_FIGHTING = 4, 2
local fields = {}
local cpu, space
local last_gstate = -1
local charsel_frame = 0
local fighting_frame = 0
local start_presses = 0
local next_press = 0
local done = false

local function r16(a) return space:read_u16(a) end

local function cache_fields()
    local wanted = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if wanted[f.name] then fields[f.name] = f end
        end
    end
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end) end
    print("[cheat] SNAP " .. label)
end

local function pressed(name)
    if name == "Coin 1" then
        return frame >= 700 and frame < 940 and (frame % 80) < 16
    end
    if name == "1 Player Start" then
        -- initial game start
        if frame >= 960 and frame < 1020 then return true end
        if MODE == "kahn" then
            -- five deliberate presses during character select
            if charsel_frame > 0 and start_presses < 5 and fighting_frame == 0 then
                local rel = frame - charsel_frame
                if rel >= 60 then
                    local phase = (rel - 60) % 40
                    return phase < 12
                end
            end
        elseif MODE == "noob" then
            -- hold Start continuously from just before character confirm all
            -- the way to the fight: set_drone_ochar samples the raw switch at
            -- the pre-match handoff, whose exact frame varies
            if charsel_frame > 0 and frame - charsel_frame > 55 and fighting_frame == 0 then
                return true
            end
        end
    end
    if name == "P1 High Punch" and MODE == "noob" then
        -- confirm default character quickly
        if charsel_frame > 0 and fighting_frame == 0 then
            local rel = frame - charsel_frame
            return rel >= 60 and rel < 100
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[cheat] mode=%s f_kahn_cheat@%08x c_kahn_cheat@%08x", MODE, A.f_kahn_cheat, A.c_kahn_cheat))
    end
    if space and not done then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            print(string.format("[cheat] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                print(string.format("[cheat] FIGHT START p1_char=%d p2_char=%d f_kahn_cheat=%d map_position=%d",
                    r16(A.p1_char), r16(A.p2_char), r16(A.f_kahn_cheat), r16(A.map_position)))
                snap("fight_start")
            end
            last_gstate = gs
        end
        -- track the 5 presses and cheat counters during psel
        if MODE == "kahn" and charsel_frame > 0 and fighting_frame == 0 then
            local rel = frame - charsel_frame
            if rel >= 60 and (rel - 60) % 40 == 0 and start_presses < 5 then
                start_presses = start_presses + 1
                print(string.format("[cheat] start_press %d frame=%d c_kahn_cheat=%d f_kahn_cheat=%d",
                    start_presses, frame, r16(A.c_kahn_cheat), r16(A.f_kahn_cheat)))
            end
        end
        if fighting_frame > 0 and frame - fighting_frame > 120 then
            local p2c = r16(A.p2_char)
            if MODE == "kahn" then
                local f = r16(A.f_kahn_cheat)
                local mp = r16(A.map_position)
                print(string.format("[cheat] RESULT mode=kahn f_kahn_cheat=%d map_position=%d p2_char=%d %s",
                    f, mp, p2c, (mp == 14 or p2c == 13) and "PASS" or "FAIL"))
            else
                print(string.format("[cheat] RESULT mode=noob p2_char=%d %s",
                    p2c, p2c == 15 and "PASS" or "FAIL"))
            end
            snap("result")
            done = true
            manager.machine:exit()
            return
        end
        if frame > 6000 then
            print("[cheat] TIMEOUT")
            manager.machine:exit()
        end
    end
    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
