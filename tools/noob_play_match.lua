-- noob_play_match.lua
--
-- Manual, arcade-flow match: P1 Jax versus CPU Noob Saibot.
--
-- This starts a normal one-player game, uses the normal player-select path
-- for Jax, and substitutes Noob only after MAIN.ASM has chosen the standard
-- CPU opponent.  Once the fight begins it changes no health, winner, sound,
-- input, or process state.  A Noob win therefore reaches the stock
-- results_of_round -> bonus_count -> winner_speech sequence.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if not fh then
        map_path = ROOT .. "/src/MK2.MAP"
        fh = io.open(map_path, "r")
    end
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        print("[noob-play] ERROR: unable to read mk2.map")
    end
end

local function sym(name, fallback)
    return symbols[name] or fallback
end

local A = {
    gstate = sym("gstate", 0x0112a7d0),
    p1_char = sym("p1_char", 0x0112a880),
    p2_char = sym("p2_char", 0x0112b450),
    p2_obj = sym("p2_obj", 0x0112b3f0),
}

local GS_PSEL = 4
local GS_PFSETUP = 6
local GS_POST = 0x0d
local GS_FIGHTING = 2
local FT_JAX = 11
local FT_NOOB = 15
local OCHAR = 0x1f0

local frame = 0
local charsel_frame = 0
local post_frame = 0
local p1_confirm_start = 0
local injected_noob = false
local announced_ready = false
local last_gstate = -1
local fields = {}

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true,
        ["1 Player Start"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[noob-play] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function pressed(name)
    -- Let MAME finish its startup screens, then enter one normal arcade game.
    if name == "Coin 1" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then
        return frame >= 1000 and frame < 1080
    end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    -- Confirm the normal stage-selection screen; this is not a fight input.
    if name == "P1 Low Kick" and post_frame > 0 then
        return frame >= post_frame + 260 and frame < post_frame + 305
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    local cpu = manager.machine.devices[":maincpu"]
    local space = cpu and cpu.spaces["program"]
    if not space then return end

    if frame == 1 then
        cache_fields()
        print("[noob-play] Starting normal arcade game: P1 Jax vs CPU Noob. Let Noob win to hear the native announcement.")
    end

    local gs = space:read_u16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[noob-play] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_POST and post_frame == 0 then post_frame = frame end
        last_gstate = gs
    end

    if gs == GS_PSEL then
        -- Confirm only P1.  Leave P2 unselected so the stock game creates a
        -- drone opponent instead of a second human.
        space:write_u16(A.p1_char, FT_JAX)
        if p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[noob-play] Jax selected; confirming at frame=%d", p1_confirm_start))
        end
    elseif gs == GS_PFSETUP and not injected_noob then
        -- MAIN.ASM set_drone_ochar has just picked a normal CPU opponent.  Its
        -- slot is still mutable here, before play_1_round creates the fighters.
        space:write_u16(A.p2_char, FT_NOOB)
        injected_noob = true
        print(string.format("[noob-play] Replaced stock CPU opponent with Noob at frame=%d", frame))
    elseif gs == GS_FIGHTING and injected_noob and not announced_ready then
        local p2_obj = space:read_u32(A.p2_obj)
        local p2_ochar = p2_obj ~= 0 and space:read_u16(p2_obj + OCHAR) or -1
        if p2_ochar == FT_NOOB then
            announced_ready = true
            print("[noob-play] Ready: live P2 object is Noob (ochar=15). Manual play is now untouched.")
        elseif frame % 30 == 0 then
            print(string.format("[noob-play] Waiting for Noob object; p2_ochar=%d", p2_ochar))
        end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
