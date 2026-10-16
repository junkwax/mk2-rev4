-- pong_test.lua
-- Forces a genuine 2-player game (both p1_state and p2_state active) so the
-- battle_num==pong_battle_num hidden minigame check in MAIN.ASM actually
-- triggers play_maybe_pong -> play_pong, instead of just showing the
-- "BACK IN TIME" VS-screen text with no player 2 active.

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = ROOT .. "/tools/pong_test.log"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local MAP_PATH = ROOT .. "/src/mk2.map"
local symbols = {}
do
    local fh = io.open(MAP_PATH, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        print("[pong-test] WARN could not read " .. MAP_PATH)
    end
end

local function symaddr(name, fallback)
    local value = symbols[name]
    if value then return value end
    print(string.format("[pong-test] WARN missing map symbol %s; using fallback 0x%08x", name, fallback))
    return fallback
end

local A = {
    gstate        = symaddr("gstate", 0x01129dd0),
    curback       = symaddr("curback", 0x0112b6d0),
    p1_state      = symaddr("p1_state", 0x01129df0),
    p1_char       = symaddr("p1_char", 0x01129e80),
    p2_state      = symaddr("p2_state", 0x0112a9c0),
    p2_char       = symaddr("p2_char", 0x0112aa50),
    map_position  = symaddr("map_position", 0x0112b750),
    battle_num    = symaddr("battle_num", 0x0112b760),
    debug3        = symaddr("debug3", 0x0112c000),
    debug4        = symaddr("debug4", 0x0112bc90),
}

local PS_ACTIVE = 1
local GS_PSEL = 4
local GS_FIGHTING = 2
local FT_KANG = 1
local FT_CAGE = 2

local cpu, space
local r16, w16
local last_debug4 = -1
local last_gstate = -1
local did_force = false
local frames_since_fight = 0
local fighting_frame = 0

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        r16 = function(addr) return space:read_u16(addr) end
        w16 = function(addr, value) space:write_u16(addr, value & 0xffff) end
        print("[pong-test] loaded")
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[pong-test] frame=%d gstate %d -> %d battle_num=%d", frame, last_gstate, gs, r16(A.battle_num)))
        last_gstate = gs
    end

    -- force a genuine 2-player game continuously through character select
    if gs == GS_PSEL then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_ACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_CAGE)
        if not did_force then
            did_force = true
            print(string.format("[pong-test] frame=%d forced p1_state=%d p2_state=%d p1_char=%d p2_char=%d",
                frame, r16(A.p1_state), r16(A.p2_state), r16(A.p1_char), r16(A.p2_char)))
        end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        print(string.format("[pong-test] fight_start frame=%d battle_num=%d p1_state=%d p2_state=%d",
            frame, r16(A.battle_num), r16(A.p1_state), r16(A.p2_state)))
    end

    local d4 = r16(A.debug4)
    if d4 ~= last_debug4 then
        print(string.format("[pong-test] frame=%d debug4 changed -> 0x%04x", frame, d4))
        last_debug4 = d4
    end

    if fighting_frame > 0 then
        frames_since_fight = frames_since_fight + 1
    end

    if frame > 4200 then
        print("[pong-test] TIMEOUT, stopping")
        manager.machine:exit()
    end
end)
