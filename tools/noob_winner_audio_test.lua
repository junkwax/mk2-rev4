-- noob_winner_audio_test.lua
--
-- Native audio review harness for Noob Saibot's winner announcement.  It
-- starts a normal one-player arcade game, selects P1 Jax, installs Noob only
-- at the stock CPU-setup point, then sets only P1's health to zero.
--
-- A normal master-game round reaches MAIN.ASM's winner_speech table, which
-- sends Noob's 5Ah entry through DCS call 0046.  This script deliberately
-- does not write a sound command, winner state, or process PC.  If a direct
-- test-fight loop bypasses the ceremony, the test fails rather than faking a
-- pass.
--
-- Keep MAME sound enabled and listen for: "Noob Saibot wins."  The script
-- saves a start and end snapshot and waits long enough for the complete
-- 164-tick NOOBWINS announcement to finish.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local LOG_PATH = os.getenv("NOOB_AUDIO_LOG")
    or (ROOT .. "/tools/noob_winner_audio_test.log")

local logfh = io.open(LOG_PATH, "w")
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

local function log(fmt, ...)
    local message = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[noob-audio] " .. message)
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value & 0xffffffff)
end

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
        log("loaded symbols from %s", map_path)
    else
        log("ERROR unable to read mk2.map")
    end
end

local function sym(name, fallback)
    local value = symbols[name]
    if value ~= nil then return value end
    log("WARN missing symbol %s; using %s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    gstate        = sym("gstate", 0x0112a7d0),
    p1_char       = sym("p1_char", 0x0112a880),
    p2_char       = sym("p2_char", 0x0112b450),
    p2_obj        = sym("p2_obj", 0x0112b3f0),
    p1_bar        = sym("p1_bar", 0x0112a8f0),
    p2_bar        = sym("p2_bar", 0x0112b4c0),
    p1_bar_view   = sym("p1_bar_view", 0x011285f0),
    p2_bar_view   = sym("p2_bar_view", 0x01128530),
    winner_status = sym("winner_status", 0x0112c110),
}

local GS_PSEL = 4
local GS_POST = 0x0d
local GS_PFSETUP = 6
local GS_FIGHTING = 2
local FT_JAX = 11
local FT_NOOB = 15
local MAX_HP = 0x00a1
local AUDIO_WINDOW_TICKS = 300

local O = {
    ochar = 0x1f0,
}

local frame = 0
local cpu = nil
local space = nil
local fields = {}
local charsel_frame = 0
local vs_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local p1_selected = false
local noob_injected = false
local force_loss_frame = 0
local p2_win_frame = 0
local audio_start_frame = 0
local last_gstate = -1
local last_winner_status = -1
local finished = false

local function r16(addr)
    return space and space:read_u16(addr) or 0
end

local function r32(addr)
    return space and space:read_u32(addr) or 0
end

local function w16(addr, value)
    if space then space:write_u16(addr, value & 0xffff) end
end

local function p2_live_ochar()
    local obj = r32(A.p2_obj)
    if obj == 0 then return -1 end
    return r16(obj + O.ochar)
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
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
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end

    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 45
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end
    return false
end

local function main_screen()
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then return screen end
    ok, screen = pcall(function() return manager.machine.screens:at(1) end)
    if ok and screen then return screen end
    return nil
end

local function snap(label)
    local screen = main_screen()
    if not screen then
        log("ERROR no screen for snapshot label=%s", label)
        return false
    end
    local ok, err = pcall(function() screen:snapshot() end)
    log("SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err))
    return ok
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    if ok then
        log("PASS reason=%s", reason)
    else
        log("ERROR reason=%s", reason)
    end
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function prepare_arcade_matchup(gs)
    if not space then return end
    if gs == GS_PSEL then
        -- Confirm only P1; leaving P2 alone makes the stock game create a
        -- drone rather than a second human player.
        w16(A.p1_char, FT_JAX)
        if not p1_selected then
            p1_selected = true
            log("selecting P1 Jax through normal arcade player select")
        end
    elseif gs == GS_PFSETUP and not noob_injected then
        -- MAIN.ASM has already chosen the normal CPU opponent.  Replace only
        -- its character slot before play_1_round constructs the fighters.
        w16(A.p2_char, FT_NOOB)
        noob_injected = true
        log("replaced stock CPU opponent with Noob during gs_pfsetup")
    end
end

local function begin_audio_review()
    if audio_start_frame ~= 0 then return end
    audio_start_frame = frame
    snap("noob_wins_audio_start_native_winner_speech")
    log("Noob winner audio review begins at frame=%d path=native_winner_speech", frame)
end

local function force_normal_noob_win()
    if force_loss_frame ~= 0 or fighting_frame == 0 then return end
    if frame - fighting_frame < 180 then return end
    local live_ochar = p2_live_ochar()
    if r16(A.p1_char) ~= FT_JAX or r16(A.p2_char) ~= FT_NOOB or live_ochar ~= FT_NOOB then
        finish(false, string.format("wrong_matchup_p1=%d_p2=%d_p2_ochar=%d", r16(A.p1_char), r16(A.p2_char), live_ochar))
        return
    end

    -- Preserve P2/Noob at full health, exhaust P1 only, then let normal combat
    -- and winner-selection code reach MAIN.ASM's winner_speech table.
    w16(A.p1_bar, 0)
    w16(A.p1_bar_view, 0)
    w16(A.p2_bar, MAX_HP)
    w16(A.p2_bar_view, MAX_HP)
    force_loss_frame = frame
    log("forced ordinary P2 Noob round win at frame=%d (P1 bar only)", frame)
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("loaded: normal arcade P1 Jax versus CPU Noob, force an ordinary P2 win, listen for Noob Saibot wins")
    end

    if space and not finished then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING then
                if fighting_frame == 0 then
                    fighting_frame = frame
                    log("fight started frame=%d P1=%d P2=%d P2-ochar=%d", frame, r16(A.p1_char), r16(A.p2_char), p2_live_ochar())
                else
                    finish(false, "unexpected_round_restart_before_native_winner_speech")
                    return
                end
            end
            last_gstate = gs
        end

        prepare_arcade_matchup(gs)

        if gs == GS_PSEL and charsel_frame > 0 then
            if p1_confirm_start == 0 and frame - charsel_frame > 90 and r16(A.p1_char) == FT_JAX then
                p1_confirm_start = frame
                log("P1 Jax selected; confirm starts frame=%d", p1_confirm_start)
            end
        end

        force_normal_noob_win()

        local winner_status = r16(A.winner_status)
        if winner_status ~= last_winner_status then
            log("frame=%d winner_status %d -> %d", frame, last_winner_status, winner_status)
            last_winner_status = winner_status
        end
        if force_loss_frame ~= 0 and winner_status == 2 and p2_win_frame == 0 then
            p2_win_frame = frame
            snap("noob_wins_start")
            log("P2 Noob won normally at frame=%d; audio review window begins", frame)
            begin_audio_review()
        end

        if audio_start_frame ~= 0 and frame - audio_start_frame == AUDIO_WINDOW_TICKS then
            snap("noob_wins_audio_end_native_winner_speech")
            finish(true, "noob_won_audio_window_elapsed_path=native_winner_speech")
            return
        end

        if force_loss_frame ~= 0 and frame - force_loss_frame > 2500 and audio_start_frame == 0 then
            finish(false, "noob_winner_audio_never_started")
            return
        end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if not finished and frame > 11000 then
        finish(false, "global_timeout")
    end
end)
