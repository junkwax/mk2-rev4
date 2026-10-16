-- secret_winner_audio_tour.lua
--
-- Manual, normal-arcade secret-opponent tour:
--   P1 Jax vs CPU Noob Saibot -> Smoke -> Jade.
--
-- Let each secret opponent win its normal best-of-three match.  The script
-- then lets the arcade master loop complete its ordinary end-of-match work,
-- re-enters player select, and queues the next opponent.  Every spoken name
-- comes from MAIN.ASM's native winner_speech path; this script never changes
-- health, winner state, match wins, or a DCS sound command.

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
        print("[secret-tour] ERROR: unable to read mk2.map")
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
    battle_num = sym("battle_num", 0x0112a7b0),
    winner_status = sym("winner_status", 0x0112c110),
}

local GS_PSEL = 4
local GS_PFSETUP = 6
local GS_POST = 0x0d
local GS_FIGHTING = 2
local FT_JAX = 11
local OCHAR = 0x1f0

local OPPONENTS = {
    { id = 15, name = "Noob Saibot" },
    { id = 14, name = "Smoke" },
    { id = 16, name = "Jade" },
}

local frame = 0
local charsel_frame = 0
local post_frame = 0
local p1_confirm_start = 0
local opponent_index = 1
local target_battle = -1
local live_opponent_logged_for = 0
local tour_complete = false
local last_gstate = -1
local last_winner_status = -1
local fields = {}

local function r16(space, addr)
    return space:read_u16(addr)
end

local function w16(space, addr, value)
    space:write_u16(addr, value & 0xffff)
end

local function current_opponent()
    return OPPONENTS[opponent_index]
end

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
        print(string.format("[secret-tour] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function pressed(name)
    if name == "Coin 1" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    if name == "P1 Low Kick" and post_frame > 0 then
        return frame >= post_frame + 260 and frame < post_frame + 305
    end
    return false
end

local function queue_target_for_battle(space)
    local battle = r16(space, A.battle_num)
    if battle ~= target_battle then
        if target_battle >= 0 then opponent_index = opponent_index + 1 end
        target_battle = battle
        live_opponent_logged_for = 0
    end

    local foe = current_opponent()
    if not foe then
        if not tour_complete then
            tour_complete = true
            print("[secret-tour] COMPLETE: Noob, Smoke, and Jade each completed a normal arcade match.")
        end
        return
    end

    -- MAIN.ASM has selected its usual CPU drone by gs_pfsetup.  Replace only
    -- its character slot before play_1_round creates the live fighter.
    w16(space, A.p2_char, foe.id)
    print(string.format("[secret-tour] battle=%d queued CPU %s (ochar=%d)", battle, foe.name, foe.id))
end

emu.register_frame(function()
    frame = frame + 1
    local cpu = manager.machine.devices[":maincpu"]
    local space = cpu and cpu.spaces["program"]
    if not space then return end

    if frame == 1 then
        cache_fields()
        print("[secret-tour] Normal arcade sequence: let Noob win two rounds, then Smoke two, then Jade two.")
    end

    local gs = r16(space, A.gstate)
    if gs ~= last_gstate then
        print(string.format("[secret-tour] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL then
            charsel_frame = frame
            post_frame = 0
            p1_confirm_start = 0
        elseif gs == GS_POST then
            post_frame = frame
        end
        last_gstate = gs
    end

    if gs == GS_PSEL then
        -- Select only P1.  P2 remains a stock CPU/drone.
        w16(space, A.p1_char, FT_JAX)
        if p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[secret-tour] Jax selected; confirming at frame=%d", p1_confirm_start))
        end
    elseif gs == GS_PFSETUP then
        queue_target_for_battle(space)
    elseif gs == GS_FIGHTING and not tour_complete then
        local foe = current_opponent()
        local p2_obj = space:read_u32(A.p2_obj)
        local p2_ochar = p2_obj ~= 0 and r16(space, p2_obj + OCHAR) or -1
        if foe and p2_ochar == foe.id and live_opponent_logged_for ~= opponent_index then
            live_opponent_logged_for = opponent_index
            print(string.format("[secret-tour] FIGHT: Jax vs %s. Let %s win the match to advance.", foe.name, foe.name))
        elseif foe and frame % 60 == 0 and p2_ochar ~= foe.id then
            print(string.format("[secret-tour] waiting for %s object; p2_ochar=%d", foe.name, p2_ochar))
        end
    end

    local winner_status = r16(space, A.winner_status)
    if winner_status ~= last_winner_status then
        print(string.format("[secret-tour] frame=%d winner_status %d -> %d", frame, last_winner_status, winner_status))
        local foe = current_opponent()
        if winner_status == 2 and foe then
            print(string.format("[secret-tour] %s won a round; its native winner-name announcement is playing.", foe.name))
        elseif winner_status == 1 and foe then
            print(string.format("[secret-tour] Jax won; %s remains the current arcade opponent.", foe.name))
        end
        last_winner_status = winner_status
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
