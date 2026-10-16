-- scorpion_pointblank_teleport_test.lua
--
-- Repro for "Scorpion flips over the opponent, teleports, and gets stuck
-- right next to him".
--
-- Hypothesis under test: flight_call's away_x_vel only writes the REQUEST
-- (p1_xvel/p2_xvel).  The repell process (MAIN.ASM) is what copies that
-- request into the object's oxvel via stuff_velocities -- but its
-- "repell_now" early-out (x distance < repell_distance-3 = 0x3d = 61px)
-- jumps straight back to the top of the loop when repell is DISABLED, which
-- is exactly what do_decoy does (f_norepell = 0x40).  So a teleport started
-- inside 61px never gets its x velocity onto the object: Scorpion hops
-- straight up and lands in place, and crossover_scan sees oxvel == 0 and
-- takes the screen-half fallback instead of warping.
--
-- Two trials, same session:
--   FAR   - opponent pinned ~150px away -> expect real horizontal travel
--   CLOSE - opponent pinned ~40px away  -> expect ~0 travel if the bug is real
--
-- Usage:
--   tools\run_mame_small.ps1 -Script <repo>\tools\scorpion_pointblank_teleport_test.lua -Wait

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/scorpion_pointblank_teleport_test.log", "w")
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
        print("[pb-tele] WARN could not read " .. MAP_PATH)
    end
end

local function symaddr(name, fallback)
    local v = symbols[name]
    if not v then
        print(string.format("[pb-tele] WARN missing map symbol %s; fallback 0x%08x", name, fallback))
        return fallback
    end
    return v
end

local GSTATE    = symaddr("gstate", 0x0112a830)
local P1_OBJ    = symaddr("p1_obj", 0x01129e10)
local P2_OBJ    = symaddr("p2_obj", 0x0112a9e0)
local P1_PROC   = symaddr("p1_proc", 0x01129e50)
local P1_CHAR   = symaddr("p1_char", 0x01129e70)
local P1_BAR    = symaddr("p1_bar", 0x01129ee0)
local P1_BAR_V  = symaddr("p1_bar_view", 0x01128650)
local P2_BAR    = symaddr("p2_bar", 0x0112aab0)
local P2_BAR_V  = symaddr("p2_bar_view", 0x01128590)
local WORLDTLX  = symaddr("worldtlx", 0x01127490)
local P1_XVEL   = symaddr("p1_xvel", 0)
local F_NOREPELL = symaddr("f_norepell", 0)

local OBJ_OXVEL   = 0x040
local OBJ_OXVAL   = 0x080
local OBJ_OXPOS   = 0x090
local PROC_ACTION = 0x1f0
local ACT_DECOY   = 0x020a

local GS_FIGHTING = 0x02
local GS_PSEL     = 0x04
local FT_SCORPION = 10
local MAX_HP      = 0xa1

-- trial table: label, gap in pixels between the two fighters
local TRIALS = {
    { label = "FAR",   gap = 150 },
    { label = "CLOSE", gap = 30 },
}

local fields, cpu, space = {}, nil, nil
local last_gstate = -1
local charsel_frame, fighting_frame = 0, 0
local confirm_start = 0

local phase, phase_start = "settle", 0
local trial_idx = 1
local attempt_start = 0
local back_name = "P1 Left"
local pin_x, base_x = nil, nil
local decoy_seen, decoy_frames = false, 0
local minx, maxx = nil, nil
local nonzero_oxvel, max_abs_oxvel = false, 0
local results = {}
local result_printed = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end

local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end

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
    pcall(function() s:snapshot() end)
    print(string.format("[pb-tele] SNAP frame=%d label=%s", frame, label))
end

local function p1x()
    local o = r32(P1_OBJ); if o == 0 then return nil end
    return s16(r16(o + OBJ_OXPOS))
end
local function p2x()
    local o = r32(P2_OBJ); if o == 0 then return nil end
    return s16(r16(o + OBJ_OXPOS))
end
local function p1xvel()
    local o = r32(P1_OBJ); if o == 0 then return 0 end
    return s32(r32(o + OBJ_OXVEL))
end
local function p1_req_xvel()
    if P1_XVEL == 0 then return 0 end
    return s32(r32(P1_XVEL))
end
local function wtlx() return s16(r16(WORLDTLX + 16)) end
local function p1_action()
    local p = r32(P1_PROC); if p == 0 then return 0xffff end
    return r16(p + PROC_ACTION)
end

local function keep_alive()
    w16(P1_BAR, MAX_HP); w16(P1_BAR_V, MAX_HP)
    w16(P2_BAR, MAX_HP); w16(P2_BAR_V, MAX_HP)
end

local function pin_obj(objptr, x)
    local o = r32(objptr)
    if o == 0 then return end
    space:write_u32(o + OBJ_OXVAL, (x & 0xffff) << 16)
    w16(o + OBJ_OXPOS, x & 0xffff)
end

local function finish(pass)
    if result_printed then return end
    result_printed = true
    print("[pb-tele] ---- results ----")
    for _, r in ipairs(results) do
        print(string.format("[pb-tele] %-5s gap=%3d travel=%4d oxvel_nonzero=%-5s max|oxvel|=%d decoy_frames=%d",
            r.label, r.gap, r.travel, tostring(r.nonzero), r.maxvel, r.frames))
    end
    print(pass and "[pb-tele] DONE" or "[pb-tele] FAIL")
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Down"] = true,
        ["P1 High Punch"] = true, ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[pb-tele] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" and charsel_frame == 0 then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" and charsel_frame == 0 then
        return frame >= 1000 and frame < 1080
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        if confirm_start > 0 then
            if name == "P1 High Punch" then
                return frame >= confirm_start and frame < confirm_start + 20
            end
            if name == "P1 Low Kick" then
                return frame >= confirm_start + 300 and frame < confirm_start + 360
            end
            return false
        end
        if name == "P1 Right" then
            return (r >= 80 and r < 102) or (r >= 160 and r < 182)
        end
        if name == "P1 Down" then return r >= 240 and r < 262 end
        if name == "P1 Left" then return r >= 320 and r < 328 end
        return false
    end
    if fighting_frame > 0 and phase == "tele" and attempt_start > 0 then
        local r = frame - attempt_start
        if name == "P1 Down" then return r >= 0 and r < 6 end
        if name == back_name and r >= 6 and r < 20 then return true end
        if name == "P1 High Punch" then return r >= 12 and r < 20 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[pb-tele] loaded - point-blank teleport repro")
        print(string.format("[pb-tele] p1_xvel=0x%08x f_norepell=0x%08x", P1_XVEL, F_NOREPELL))
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
    if not space then return end

    local g = r16(GSTATE)
    if g ~= last_gstate then
        print(string.format("[pb-tele] frame=%d gstate %d -> %d", frame, last_gstate, g))
        last_gstate = g
    end
    if g == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start == 0
       and r16(P1_CHAR) == FT_SCORPION then
        confirm_start = frame + 10
        print(string.format("[pb-tele] cursor on Scorpion frame=%d", frame))
    end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start == 0
       and frame - charsel_frame > 700 then
        print("[pb-tele] ERROR cursor never reached Scorpion")
        finish(false); return
    end
    if g == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase = "settle"; phase_start = frame
        print(string.format("[pb-tele] fight_start frame=%d char=%d", frame, r16(P1_CHAR)))
        if r16(P1_CHAR) ~= FT_SCORPION then
            print("[pb-tele] ERROR p1 is not Scorpion"); finish(false); return
        end
    end

    if fighting_frame == 0 or g ~= GS_FIGHTING then
        if frame > 16000 then print("[pb-tele] ERROR timeout"); finish(false) end
        return
    end

    keep_alive()

    if phase == "settle" then
        if frame - phase_start > 60 then
            local t = TRIALS[trial_idx]
            local x = p1x()
            if not x then return end
            -- park the opponent to Scorpion's right at the requested gap;
            -- Scorpion will teleport away = leftward
            base_x = x
            pin_x = x + t.gap
            back_name = "P1 Left"
            attempt_start = frame + 10
            decoy_seen, decoy_frames = false, 0
            minx, maxx = x, x
            nonzero_oxvel, max_abs_oxvel = false, 0
            phase = "tele"; phase_start = frame
            print(string.format("[pb-tele] trial %s gap=%d p1x=%d pin_p2=%d wtlx=%d",
                t.label, t.gap, x, pin_x, wtlx()))
        end

    elseif phase == "tele" then
        local act = p1_action()
        -- Hold BOTH fighters at the requested gap right up to the moment the
        -- decoy engages.  repell's separation push normally forces them apart
        -- again, so the point-blank geometry only exists transiently in real
        -- play (right after a jump-over); pinning reproduces it on demand.
        if pin_x and not decoy_seen and act ~= ACT_DECOY then
            pin_obj(P1_OBJ, base_x)
            pin_obj(P2_OBJ, pin_x)
        end
        local x = p1x()
        if act == ACT_DECOY then
            if not decoy_seen then
                decoy_seen = true
                print(string.format("[pb-tele]   decoy engaged frame=%d p1x=%d p2x=%d dist=%d",
                    frame, x or -999, p2x() or -999, math.abs((x or 0) - (p2x() or 0))))
            end
            decoy_frames = decoy_frames + 1
            local v = p1xvel()
            if v ~= 0 then nonzero_oxvel = true end
            if math.abs(v) > max_abs_oxvel then max_abs_oxvel = math.abs(v) end
            if x then
                if x < minx then minx = x end
                if x > maxx then maxx = x end
            end
            if decoy_frames <= 40 or (decoy_frames % 5) == 0 then
                print(string.format("[pb-tele]   f=%3d x=%4d oxvel=%9d req_xvel=%9d dist=%4d",
                    decoy_frames, x or -999, v, p1_req_xvel(),
                    math.abs((x or 0) - (p2x() or 0))))
            end
        elseif decoy_seen then
            local t = TRIALS[trial_idx]
            local travel = maxx - minx
            results[#results + 1] = {
                label = t.label, gap = t.gap, travel = travel,
                nonzero = nonzero_oxvel, maxvel = max_abs_oxvel, frames = decoy_frames,
            }
            print(string.format("[pb-tele] trial %s DONE travel=%d oxvel_nonzero=%s max|oxvel|=%d",
                t.label, travel, tostring(nonzero_oxvel), max_abs_oxvel))
            snap("trial_" .. t.label)
            trial_idx = trial_idx + 1
            if trial_idx > #TRIALS then finish(true); return end
            phase = "settle"; phase_start = frame
            pin_x = nil
        end
        if not decoy_seen and frame > attempt_start + 200 then
            print(string.format("[pb-tele] trial %s: teleport never engaged (act=0x%04x)",
                TRIALS[trial_idx].label, act))
            -- retry the input
            attempt_start = frame + 10
            phase_start = frame
            if frame > fighting_frame + 6000 then
                print("[pb-tele] ERROR teleport never engaged"); finish(false); return
            end
        end
    end

    if frame > 20000 then print("[pb-tele] ERROR global timeout"); finish(false) end
end)

emu.register_stop(function()
    if logfh then logfh:close(); logfh = nil end
end)
