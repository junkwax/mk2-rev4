-- fan_flip_ab.lua - Kitana's boomerang fan turning in flight, for an A/B
-- between the old ROM (dclipl ORs the object's flip over each piece's, and
-- the fan hook sets the flip without re-laying the pieces) and the new ROM
-- (dclipl takes the flip from the piece alone, and fan_turn re-lays the pieces
-- with ani2 on the tick the facing changes - MKZAP fpt_facing).
--
-- The throw and timing are tools/kitana_fan_catch_test.lua's: P1 Kitana vs an
-- idle P2 Jax, Forward, Forward, HP down and HELD (the boomerang), LP a tick
-- later (the two-button throw).  Every frame the fan object's flip is compared
-- with every piece's.  On the old ROM the turn leaves the pieces a frame or
-- more behind (the OR hid it); on the new ROM they must never disagree.
--
-- Measured: stock does not show it either.  fan_proc runs init_anirate 1, so
-- next_anirate re-lays the pieces with ani2 EVERY tick, and fanp_turn writes
-- the flip after its sleep and before the next next_anirate - the display
-- never sees the pieces behind.  The hook is redundant for this fan.
--
-- env: FF_LOG, MK2_ROOT (map dir), FF_SIDE=right|left (which way she throws)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("FF_LOG") or (ROOT .. "/tools/fan_flip_ab.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[ff] " .. string.format(fmt, ...)
    logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

local A = {
    gstate = sym("gstate"), curback = sym("curback"), active = sym("active"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_state = symbols["p1_state"], p2_state = symbols["p2_state"],
    map_position = symbols["map_position"], battle_num = symbols["battle_num"],
    winner_status = symbols["winner_status"], f_jade_flash = symbols["f_jade_flash"],
    tick = symbols["tick"],
}
local O = { oxval = 0x080, oxpos = 0x090, oxvel = 0x040, oflags = 0x0f0, oimg = 0x1a0 }
local P = { next = 0x000, procid = 0x020, pa8 = 0x0c0 }
local MP_LEN, MP_CONTROL = 112, 64
local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KITANA, FT_JAX, MAX_HP = 4, 11, 0xa1
local PID_PROJ1 = 0x0700
local JFLASH_TICKS = 60
local T_SETUP, T_FWD1, T_FWD2, T_HP, T_LP, T_END = 90, 120, 132, 144, 145, 460
local LEFT = (os.getenv("FF_SIDE") or "right") == "left"
local P1X, P2X = 220, 430
if LEFT then P1X, P2X = 430, 220 end
local FWD = LEFT and "P1 Left" or "P1 Right"

local frame, space, fields = 0, nil, {}
local last_gs, charsel_frame, fighting_frame, p1_confirm = -1, 0, 0, 0
local fan_seen, last_oflip, flips, mismatch, first_turn = 0, nil, 0, 0, nil
local snap_until = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end; return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end; return v end

local function cache_fields()
    local want = { ["UI Select"] = 1, ["Coin 1"] = 1, ["1 Player Start"] = 1, ["2 Players Start"] = 1,
                   ["P1 High Punch"] = 1, ["P1 Low Punch"] = 1, ["P1 Right"] = 1, ["P1 Left"] = 1 }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function find_fan()
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 250 do
        n = n + 1
        if r16(p + P.procid) == PID_PROJ1 then
            local o = r32(p + P.pa8)
            if o ~= 0 then return o end
        end
        p = r32(p + P.next)
    end
    return nil
end

local function force_matchup()
    if A.p1_state then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state then w16(A.p2_state, PS_ACTIVE) end
    w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_JAX)
    w16(A.curback, 0)
    if A.map_position then w16(A.map_position, 0) end
    if A.battle_num then w16(A.battle_num, 1) end
end

local function keep_flash_on_p2()
    if not (A.f_jade_flash and A.tick) then return end
    local v = (r16(A.tick) + JFLASH_TICKS // 2) & 0xffff
    if v == 0 then v = 1 end
    w16(A.f_jade_flash + 16, v)
end

local function pressed(name, rel)
    if fighting_frame == 0 then
        if charsel_frame == 0 then
            if name == "UI Select" then return frame >= 5 and frame < 35 end
            if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
            if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
            return false
        end
        if name == "2 Players Start" then local r = frame - charsel_frame; return r >= 5 and r < 45 end
        if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
        return false
    end
    if name == FWD then return (rel >= T_FWD1 and rel < T_FWD1 + 7) or (rel >= T_FWD2 and rel < T_FWD2 + 7) end
    if name == "P1 Low Punch" then return rel >= T_LP and rel < T_LP + 6 end
    if name == "P1 High Punch" then return rel >= T_HP and rel < T_END - 20 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("start")
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gs then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame; log("FIGHT frame=%d", frame) end
        last_gs = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        force_matchup()
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if frame > 9000 and fighting_frame == 0 then log("ERROR never reached the fight"); logfh:close(); manager.machine:exit(); return end

    local rel = fighting_frame > 0 and (frame - fighting_frame) or -1
    if fighting_frame > 0 then
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        if A.winner_status then w16(A.winner_status, 0) end
        keep_flash_on_p2()
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if rel == T_SETUP and p1o ~= 0 and p2o ~= 0 then
            w32(p1o + O.oxval, P1X << 16); w32(p2o + O.oxval, P2X << 16)
            log("PREARM p1x=%d p2x=%d", P1X, P2X)
        end
        if rel > T_SETUP and p2o ~= 0 then w32(p2o + O.oxval, P2X << 16) end
        if rel == T_FWD1 and p1o ~= 0 then
            log("ARM p1 x=%d oflip=%d fwd=%s field=%s", s16(r16(p1o + O.oxpos)), (r16(p1o + O.oflags) >> 4) & 3,
                FWD, fields[FWD] and "yes" or "MISSING")
        end

        local fan = find_fan()
        if fan then
            fan_seen = fan_seen + 1
            if fan_seen == 1 or fan_seen % 4 == 0 then
                log("TRACE rel=%d x=%d vx=%.2f oflip=%d worldtlx=%d p2x=%d", rel, s16(r16(fan + O.oxpos)),
                    s32(r32(fan + O.oxvel)) / 65536.0, (r16(fan + O.oflags) >> 4) & 3,
                    s16(r16(sym("worldtlx") + 16)), p2o ~= 0 and s16(r16(p2o + O.oxpos)) or -1)
            end
            local oflip = (r16(fan + O.oflags) >> 4) & 3
            local ram = r32(fan + O.oimg)
            local bad, pflips = false, {}
            if ram ~= 0 then
                local p, k = ram, 0
                while k < 13 and r32(p) ~= 0 do
                    local pf = (r16(p + MP_CONTROL) >> 4) & 3
                    pflips[#pflips + 1] = tostring(pf)
                    if pf ~= oflip then bad = true end
                    p = p + MP_LEN; k = k + 1
                end
            end
            if last_oflip ~= nil and oflip ~= last_oflip then
                flips = flips + 1
                if not first_turn then first_turn = rel end
                log("TURN rel=%d oflip %d->%d", rel, last_oflip, oflip)
                for d = -4, 8 do snap_until[rel + d] = true end
            end
            last_oflip = oflip
            if bad then mismatch = mismatch + 1 end
            if bad or (first_turn and rel - first_turn <= 8) then
                log("FAN rel=%d x=%d vx=%.2f oflip=%d pieces=%s%s", rel, s16(r16(fan + O.oxpos)),
                    s32(r32(fan + O.oxvel)) / 65536.0, oflip, table.concat(pflips, ","), bad and " MISMATCH" or "")
            end
        end
        -- a turn is known only once it happens, so snapshot a window from the
        -- turn frame on, plus a fixed early window the runner lines up by rel
        if snap_until[rel] then
            pcall(function() manager.machine.screens[":screen"]:snapshot() end)
            log("SNAP rel=%d", rel)
        end
        if rel == T_END then
            log("RESULT fan_frames=%d turns=%d mismatch_frames=%d first_turn=%s",
                fan_seen, flips, mismatch, first_turn and tostring(first_turn) or "none")
            logfh:close()
            manager.machine:exit()
            return
        end
    end

    for name, f in pairs(fields) do
        if pressed(name, rel) then f:set_value(1) else f:set_value(0) end
    end
end)
