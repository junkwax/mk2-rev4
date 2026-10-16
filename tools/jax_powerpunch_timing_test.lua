-- jax_powerpunch_timing_test.lua
--
-- Measures how long Jax's back+HP power punch (act_jx_powerp) occupies the
-- player process.  do_jx_power_punch walks a [frame,tick] table and scales
-- each native 12 FPS source tick into game scheduler ticks; the scale used
-- to be x5 (12 source ticks -> 60 ticks ~ 0.96s, with a ~0.5s windup before
-- the strike frame) which read as "way too slow".  Now x2 -> ~24 ticks.
--
-- Reports: frames in act_jx_powerp, and frames from move start to the frame
-- the strike check fires (p_store1 hit flag flips) when it connects.
--
-- Usage:
--   tools\run_mame_small.ps1 -Script <repo>\tools\jax_powerpunch_timing_test.lua ^
--     -NoSound -NoThrottle -WarningDismissCount 5 -Wait

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/jax_powerpunch_timing_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
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
    end
end
local function symaddr(name, fallback)
    local v = symbols[name]
    if not v then print(string.format("[jaxpp] WARN missing %s", name)); return fallback end
    return v
end

local GSTATE   = symaddr("gstate", 0x0112a830)
local P1_OBJ   = symaddr("p1_obj", 0x01129e10)
local P2_OBJ   = symaddr("p2_obj", 0x0112a9e0)
local P1_PROC  = symaddr("p1_proc", 0x01129e50)
local P1_CHAR  = symaddr("p1_char", 0x01129e70)
local P1_BAR   = symaddr("p1_bar", 0x01129ee0)
local P1_BAR_V = symaddr("p1_bar_view", 0x01128650)
local P2_BAR   = symaddr("p2_bar", 0x0112aab0)
local P2_BAR_V = symaddr("p2_bar_view", 0x01128590)

local OBJ_OXVAL = 0x080
local OBJ_OXPOS = 0x090
local PROC_ACTION = 0x1f0

local ACT_JX_POWERP = 0x0110
local GS_FIGHTING, GS_PSEL = 0x02, 0x04
local FT_JAX = 11
local MAX_HP = 0xa1

local fields, space = {}, nil
local last_gstate = -1
local charsel_frame, fighting_frame, confirm_start = 0, 0, 0
local nav_last = 0
local phase, phase_start = "settle", 0
local attempt_start, attempts = 0, 0
local in_move, move_start, move_frames = false, 0, 0
local samples = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function p1x() local o = r32(P1_OBJ); if o == 0 then return nil end return s16(r16(o + OBJ_OXPOS)) end
local function p1_action() local p = r32(P1_PROC); if p == 0 then return 0xffff end return r16(p + PROC_ACTION) end

local function pin_p2(x)
    local o = r32(P2_OBJ); if o == 0 then return end
    space:write_u32(o + OBJ_OXVAL, (x & 0xffff) << 16)
    w16(o + OBJ_OXPOS, x & 0xffff)
end

local function keep_alive()
    w16(P1_BAR, MAX_HP); w16(P1_BAR_V, MAX_HP)
    w16(P2_BAR, MAX_HP); w16(P2_BAR_V, MAX_HP)
end

local function finish(ok)
    if done then return end
    done = true
    print("[jaxpp] ---- results ----")
    local total = 0
    for i, s in ipairs(samples) do
        print(string.format("[jaxpp] rep %d: act_jx_powerp held %d frames (~%.2fs)", i, s, s / 60.0))
        total = total + s
    end
    if #samples > 0 then
        print(string.format("[jaxpp] average %.1f frames (~%.2fs)", total / #samples, total / #samples / 60.0))
    end
    print(ok and "[jaxpp] DONE" or "[jaxpp] FAIL")
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Down"] = true,
        ["P1 High Punch"] = true, ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

local function pressed(name)
    if name == "Coin 1" and charsel_frame == 0 then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" and charsel_frame == 0 then
        return frame >= 1000 and frame < 1080
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if confirm_start > 0 then
            if name == "P1 High Punch" then
                return frame >= confirm_start and frame < confirm_start + 20
            end
            if name == "P1 Low Kick" then
                return frame >= confirm_start + 300 and frame < confirm_start + 380
            end
            return false
        end
        -- generic grid walk: pulse Right, drop to the bottom row every lap
        local r = (frame - charsel_frame) % 80
        if name == "P1 Right" then return r >= 0 and r < 12 end
        if name == "P1 Down" then
            return ((frame - charsel_frame) % 480) >= 240
               and ((frame - charsel_frame) % 480) < 252
        end
        return false
    end
    if fighting_frame > 0 and phase == "punch" and attempt_start > 0 then
        local r = frame - attempt_start
        -- hold Back the whole time, tap HP inside it
        if name == "P1 Left" then return r >= 0 and r < 30 end
        if name == "P1 High Punch" then return r >= 10 and r < 18 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print("[jaxpp] loaded - jax back+HP power punch timing")
    end
    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if not space then return end

    local g = r16(GSTATE)
    if g ~= last_gstate then
        print(string.format("[jaxpp] frame=%d gstate %d -> %d", frame, last_gstate, g))
        last_gstate = g
    end
    if g == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start == 0
       and r16(P1_CHAR) == FT_JAX then
        confirm_start = frame + 8
        print(string.format("[jaxpp] cursor on Jax frame=%d", frame))
    end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start == 0
       and frame - charsel_frame > 1400 then
        print("[jaxpp] ERROR cursor never reached Jax"); finish(false); return
    end
    if g == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; phase = "settle"; phase_start = frame
        print(string.format("[jaxpp] fight_start frame=%d char=%d", frame, r16(P1_CHAR)))
        if r16(P1_CHAR) ~= FT_JAX then
            print("[jaxpp] ERROR p1 is not Jax"); finish(false); return
        end
    end

    if fighting_frame == 0 or g ~= GS_FIGHTING then
        if frame > 18000 then print("[jaxpp] ERROR timeout"); finish(false) end
        return
    end

    keep_alive()
    -- park the drone just inside power-punch range so the move connects
    local x = p1x()
    if x then pin_p2(x + 70) end

    if phase == "settle" then
        if frame - phase_start > 60 then
            phase = "punch"; attempt_start = frame + 5; attempts = attempts + 1
            in_move, move_frames = false, 0
        end
    elseif phase == "punch" then
        local act = p1_action()
        if act == ACT_JX_POWERP then
            if not in_move then
                in_move, move_start, move_frames = true, frame, 0
                print(string.format("[jaxpp] power punch start frame=%d", frame))
            end
            move_frames = move_frames + 1
        elseif in_move then
            in_move = false
            samples[#samples + 1] = move_frames
            print(string.format("[jaxpp] power punch end frame=%d held=%d frames (~%.2fs)",
                frame, move_frames, move_frames / 60.0))
            if #samples >= 3 then finish(true); return end
            phase = "settle"; phase_start = frame
        end
        if not in_move and frame > attempt_start + 180 then
            print(string.format("[jaxpp] attempt %d: no power punch (act=0x%04x)", attempts, act))
            if attempts >= 10 then
                print("[jaxpp] ERROR power punch never fired"); finish(false); return
            end
            phase = "settle"; phase_start = frame
        end
    end

    if frame > 20000 then print("[jaxpp] ERROR global timeout"); finish(false) end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
