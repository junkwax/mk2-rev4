-- scorpion_corner_teleport_test.lua
-- Regression test for Scorpion's teleport punch out of BOTH stage corners.
--
-- The left corner used to fail: gravity_n_bounds clamps players at
-- left_edge+left_padding (0x3a) but crossover_scan's warp window was 0x35,
-- so cornered-left teleports stalled at the wall and landed in place.  The
-- right wall's right_padding (0x30) fit inside the window, so only left
-- broke.  PASS requires the +/-scrrgt warp jump from both corners.
--
-- Flow: boot 1P game, cursor to Scorpion, then in-fight:
--   walk left until pinned at the left wall -> D, B, HP -> expect +399 warp
--   walk right until pinned at the right wall -> D, B, HP -> expect -399 warp
--
-- Usage (via run_mame_small.ps1 -Script or directly):
--   mame.exe -rompath <repo>\rom mk2 -window -skip_gameinfo ^
--     -script <repo>\tools\scorpion_corner_teleport_test.lua

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/scorpion_corner_teleport_test.log", "w")
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

local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/MK2.MAP"
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
        print("[scorp-tele] WARN could not read " .. MAP_PATH)
    end
end

local function symaddr(name, fallback)
    local value = symbols[name]
    if not value then
        print(string.format("[scorp-tele] WARN missing map symbol %s; fallback 0x%08x", name, fallback))
        return fallback
    end
    return value
end

local GSTATE     = symaddr("gstate", 0x0112a830)
local P1_OBJ     = symaddr("p1_obj", 0x01129e10)
local P2_OBJ     = symaddr("p2_obj", 0x0112a9e0)
local P1_PROC    = symaddr("p1_proc", 0x01129e50)
local P1_CHAR    = symaddr("p1_char", 0x01129e70)
local P1_BAR     = symaddr("p1_bar", 0x01129ee0)
local P1_BAR_V   = symaddr("p1_bar_view", 0x01128650)
local P2_BAR     = symaddr("p2_bar", 0x0112aab0)
local P2_BAR_V   = symaddr("p2_bar_view", 0x01128590)
local WORLDTLX   = symaddr("worldtlx", 0x01127490)
local LEFT_EDGE  = symaddr("left_edge", 0x01128e50)
local RIGHT_EDGE = symaddr("right_edge", 0x01128e60)

local OBJ_OXVAL  = 0x080
local OBJ_OXPOS  = 0x090
local PROC_ACTION = 0x1f0
local ACT_DECOY  = 0x020a

local GS_FIGHTING = 0x02
local GS_PSEL     = 0x04
local FT_SCORPION = 10
local MAX_HP      = 0xa1
local SCRRGT      = 399
local LEFT_PIN_DIST  = 0x3e   -- clamp holds at left_padding 0x3a
local RIGHT_PIN_DIST = 0x34   -- clamp holds at right_padding 0x30
local WARP_MIN_JUMP  = 250    -- one-frame |dx| that can only be the warp

local fields, cpu, space = {}, nil, nil
local last_gstate = -1
local charsel_frame, vs_seen_frame, fighting_frame = 0, 0, 0
local scorpion_cursor_frame = 0
local confirm_start = 0

-- fight-phase state machine
local phase = "settle"        -- settle -> walk -> tele -> land -> (next side) -> done
local side = "left"
local phase_start = 0
local pin_count = 0
local attempt_start = 0
local attempts = 0
local back_name = "P1 Left"
local prev_p1x = nil
local warp_frame = 0
local decoy_seen = false
local left_pass, right_pass = false, false
local walk_deadline = 0
local result_printed = false

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, v) space:write_u16(addr, v) end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    local s = main_screen()
    if not s then return end
    local ok = pcall(function() s:snapshot() end)
    print(string.format("[scorp-tele] SNAP frame=%d label=%s ok=%s", frame, label, tostring(ok)))
end

local function p1x()
    local o = r32(P1_OBJ)
    if o == 0 then return nil end
    local x = r16(o + OBJ_OXPOS)
    if x >= 0x8000 then x = x - 0x10000 end
    return x
end

local function p2x()
    local o = r32(P2_OBJ)
    if o == 0 then return nil end
    local x = r16(o + OBJ_OXPOS)
    if x >= 0x8000 then x = x - 0x10000 end
    return x
end

local function wtlx()
    local x = r16(WORLDTLX + 16)
    if x >= 0x8000 then x = x - 0x10000 end
    return x
end

local function p1_action()
    local p = r32(P1_PROC)
    if p == 0 then return 0xffff end
    return r16(p + PROC_ACTION)
end

local function status()
    local x1, x2, w = p1x() or -999, p2x() or -999, wtlx()
    return string.format("p1x=%d p2x=%d wtlx=%d le=%d re=%d dl=%d dr=%d act=0x%04x",
        x1, x2, w, r16(LEFT_EDGE), r16(RIGHT_EDGE),
        x1 - w, (w + SCRRGT) - x1, p1_action())
end

local function keep_alive()
    w16(P1_BAR, MAX_HP)
    w16(P1_BAR_V, MAX_HP)
    w16(P2_BAR, MAX_HP)
    w16(P2_BAR_V, MAX_HP)
end

local function finish(pass)
    if result_printed then return end
    result_printed = true
    print(string.format("[scorp-tele] left=%s right=%s", tostring(left_pass), tostring(right_pass)))
    print(pass and "[scorp-tele] PASS" or "[scorp-tele] FAIL")
    snap(pass and "pass_final" or "fail_final")
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["1 Player Start"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 Down"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[scorp-tele] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    -- Boot into a one-player game.
    if name == "Coin 1" and charsel_frame == 0 then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" and charsel_frame == 0 then
        return frame >= 1000 and frame < 1080
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        if confirm_start > 0 then
            -- normal confirm (no Start+Coin aura chord)
            if name == "P1 High Punch" then
                return frame >= confirm_start and frame < confirm_start + 20
            end
            -- skip bio / VS pages once select is done
            if name == "P1 Low Kick" then
                return frame >= confirm_start + 300 and frame < confirm_start + 360
            end
            return false
        end
        -- Liu Kang default -> Scorpion: right, right, down, left.
        if name == "P1 Right" then
            return (r >= 80 and r < 102) or (r >= 160 and r < 182)
        end
        if name == "P1 Down" then
            return r >= 240 and r < 262
        end
        if name == "P1 Left" then
            return r >= 320 and r < 328
        end
        return false
    end

    if fighting_frame > 0 then
        if phase == "walk" then
            return name == (side == "left" and "P1 Left" or "P1 Right")
        end
        if phase == "tele" and attempt_start > 0 then
            local r = frame - attempt_start
            -- D, B, HP rolled like a real stick: Back stays held while
            -- HP is pressed (releasing it first drops the combo)
            if name == "P1 Down" then return r >= 0 and r < 6 end
            if name == back_name and r >= 6 and r < 20 then return true end
            if name == "P1 High Punch" then return r >= 12 and r < 20 end
        end
        return false
    end

    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[scorp-tele] loaded - corner teleport regression (left then right)")
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if not space then return end

    local g = r16(GSTATE)
    if g ~= last_gstate then
        print(string.format("[scorp-tele] frame=%d gstate %d -> %d", frame, last_gstate, g))
        last_gstate = g
    end
    if g == GS_PSEL and charsel_frame == 0 then
        charsel_frame = frame
        print(string.format("[scorp-tele] char select at frame=%d", frame))
    end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start == 0
       and r16(P1_CHAR) == FT_SCORPION then
        scorpion_cursor_frame = frame
        confirm_start = frame + 10
        print(string.format("[scorp-tele] cursor on Scorpion at frame=%d", frame))
    end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start == 0
       and frame - charsel_frame > 700 then
        print("[scorp-tele] ERROR cursor never reached Scorpion")
        finish(false)
        return
    end
    if g == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase = "settle"
        phase_start = frame
        print(string.format("[scorp-tele] fight_start frame=%d p1_char=%d %s",
            frame, r16(P1_CHAR), status()))
        if r16(P1_CHAR) ~= FT_SCORPION then
            print("[scorp-tele] ERROR p1 is not Scorpion")
            finish(false)
            return
        end
        snap("fight_start")
    end

    if fighting_frame > 0 and g == GS_FIGHTING then
        keep_alive()
        local x = p1x()
        local w = wtlx()

        if phase == "settle" then
            if frame - phase_start > 60 then
                phase = "walk"
                phase_start = frame
                walk_deadline = frame + 1500
                pin_count = 0
                print(string.format("[scorp-tele] walking %s %s", side, status()))
            end

        elseif phase == "walk" then
            if x then
                local pinned
                -- camera near its scroll limit (worldtlx can settle a few
                -- pixels past left_edge/right_edge, so no strict equality)
                if side == "left" then
                    pinned = (x - w) <= LEFT_PIN_DIST and w <= r16(LEFT_EDGE) + 4
                else
                    pinned = ((w + SCRRGT) - x) <= RIGHT_PIN_DIST and w >= r16(RIGHT_EDGE) - 4
                end
                pin_count = pinned and (pin_count + 1) or 0
                if pin_count >= 20 then
                    attempts = attempts + 1
                    attempt_start = frame + 5
                    prev_p1x = nil
                    warp_frame = 0
                    decoy_seen = false
                    local ox = p2x() or (x + 100)
                    back_name = (x < ox) and "P1 Left" or "P1 Right"
                    phase = "tele"
                    print(string.format("[scorp-tele] pinned %s attempt=%d back=%s %s",
                        side, attempts, back_name, status()))
                    if attempts == 1 then snap(side .. "_pinned") end
                end
            end
            if frame > walk_deadline then
                print(string.format("[scorp-tele] ERROR never pinned at %s wall %s", side, status()))
                finish(false)
                return
            end

        elseif phase == "tele" then
            -- hold the drone out of poke range so it can't interrupt the
            -- combo input (kahn-harness pin_players pattern)
            local p2o = r32(P2_OBJ)
            if p2o ~= 0 and warp_frame == 0 then
                local hold = (side == "left") and (w + 300) or (w + 90)
                space:write_u32(p2o + OBJ_OXVAL, (hold & 0xffff) << 16)
                w16(p2o + OBJ_OXPOS, hold)
            end
            local act = p1_action()
            if act == ACT_DECOY and not decoy_seen then
                decoy_seen = true
                print(string.format("[scorp-tele] decoy engaged frame=%d %s", frame, status()))
            end
            if x and prev_p1x then
                local dx = x - prev_p1x
                if (side == "left" and dx >= WARP_MIN_JUMP)
                   or (side == "right" and dx <= -WARP_MIN_JUMP) then
                    warp_frame = frame
                    print(string.format("[scorp-tele] WARP %s dx=%d frame=%d %s",
                        side, dx, frame, status()))
                    snap(side .. "_warp")
                    phase = "land"
                    phase_start = frame
                end
            end
            prev_p1x = x
            if phase == "tele" and frame > attempt_start + 140 then
                print(string.format("[scorp-tele] no warp on attempt %d (%s) %s",
                    attempts, side, status()))
                if attempts >= 8 then
                    print(string.format("[scorp-tele] ERROR teleport never warped from %s corner", side))
                    snap(side .. "_stuck")
                    finish(false)
                    return
                end
                phase = "walk"
                walk_deadline = frame + 1500
                pin_count = 0
            end

        elseif phase == "land" then
            if frame - phase_start > 110 then
                local dl = x and (x - w) or -999
                if x and dl >= -20 and dl <= SCRRGT + 20 then
                    print(string.format("[scorp-tele] landed after %s warp %s", side, status()))
                    snap(side .. "_landed")
                    if side == "left" then
                        left_pass = true
                        side = "right"
                        attempts = 0
                        phase = "settle"
                        phase_start = frame
                    else
                        right_pass = true
                        finish(true)
                        return
                    end
                else
                    print(string.format("[scorp-tele] ERROR lost p1 after %s warp %s", side, status()))
                    finish(false)
                    return
                end
            end
        end
    end

    if frame > 16000 then
        print("[scorp-tele] ERROR global timeout " .. status())
        finish(false)
    end
end)

emu.register_stop(function()
    if logfh then
        logfh:close()
        logfh = nil
    end
end)
