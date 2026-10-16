-- Automated runtime proof for Jade's two-lane victory (JADEVIC.IMG).
-- Puts Jade on one side (JADE_VICTORY_SIDE=1 default, 2 = the flipped run),
-- starts a normal match, empties only the loser's life bar, then verifies all
-- 14 authored body stages (JDVICTORY1-14, on her player object) appear in
-- order at the stock 6-tick cadence AND that the staff overlay
-- (JDVICSTAFF1-14, on its own gmo object) is on the same frame index at the
-- same time, in front of her, and released when the next round starts.
--
-- This is still a pointer-level check: matching SAGs prove the rows advance,
-- not that pixels were written behind them (the pre-2026-07-31 sidecar hole
-- passed this harness for months). Always eyeball the snapshots.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_VICTORY_LOG") or (ROOT .. "/tools/jade_victory_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[jade-victory] " .. string.format(fmt, ...)
    raw_print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
local function load_symbols()
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if not fh then return end
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
load_symbols()
local function sym(name, fallback) return symbols[name] or fallback end

local A = {
    gstate = sym("gstate", 0x0112a7d0), p1_char = sym("p1_char", 0x0112a880),
    p2_char = sym("p2_char", 0x0112b450), p1_obj = sym("p1_obj", 0x0112a820),
    p1_bar = sym("p1_bar", 0x0112a8f0), p2_bar = sym("p2_bar", 0x0112b4c0),
    p1_bar_view = sym("p1_bar_view", 0x011285f0),
    p2_bar_view = sym("p2_bar_view", 0x01128530),
    winner_status = sym("winner_status", 0x0112c110),
    objlst = sym("objlst", nil),
    p2_obj = sym("p2_obj", nil),
}

-- JADE_VICTORY_SIDE=2 runs Jade as P2 instead of P1. She then faces LEFT, so
-- this is the run that proves the staff mirrors with her: match_ani_points
-- copies her flip and ani2 mirrors each piece's anipoint (dx = -anix + width),
-- which has to hold for the body and the staff independently.
local SIDE = tonumber(os.getenv("JADE_VICTORY_SIDE") or "1") == 2 and 2 or 1
local JADE_OBJ = (SIDE == 2) and A.p2_obj or A.p1_obj
local JADE_CHAR = (SIDE == 2) and A.p2_char or A.p1_char
local FOE_CHAR = (SIDE == 2) and A.p1_char or A.p2_char
local JADE_BAR, JADE_BAR_VIEW = (SIDE == 2) and A.p2_bar or A.p1_bar,
                                (SIDE == 2) and A.p2_bar_view or A.p1_bar_view
local FOE_BAR, FOE_BAR_VIEW = (SIDE == 2) and A.p1_bar or A.p2_bar,
                              (SIDE == 2) and A.p1_bar_view or A.p2_bar_view
-- All offsets/addresses here are TMS34010 BIT units, same as DISPEQU.ASM and
-- mk2.map - MAME's tms34010 program space is bit-addressed.
local OIMG, MP_LEN = 0x1a0, 0x70
local ONEXT, OZVAL = 0x00, 0xc0      -- objlst link cell / z sort key
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_JADE, FT_JAX, MAX_HP = 4, 16, 11, 0x00a1
local LAST_STAGE = 14

-- SAG -> frame index, one table per lane.
local body_stage, staff_stage = {}, {}
local body_markers, staff_markers = 0, 0
local function load_markers(path)
    local fh = assert(io.open(path, "r"), "missing generated Jade table: " .. path)
    local target, stage
    for line in fh:lines() do
        local n = line:match("^%s*JDVICTORY(%d+):")
        if n then target, stage = body_stage, tonumber(n) end
        -- Accepts both the composite (JDVICSTAFF1:) and the A/B strip form
        -- (JDVICSTAFF1A:/1B:) the library moved to on 2026-08-01; both pieces
        -- of a frame map to the same stage number.
        local s = line:match("^%s*JDVICSTAFF(%d+)[AB]?:")
        if s then target, stage = staff_stage, tonumber(s) end
        local sag = stage and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
        if sag then
            target[tonumber(sag, 16) & 0x00ffffff] = stage
            if target == body_stage then body_markers = body_markers + 1
            else staff_markers = staff_markers + 1 end
            stage = nil
        end
    end
    fh:close()
end
load_markers(ROOT .. "/src/JADVIC.TBL")

local frame, space, finished = 0, nil, false
local fields, charsel_frame, vs_frame, confirm_frame = {}, 0, 0, 0
local fighting_frame, force_win_frame, victory_start = 0, 0, 0
local next_stage, last_stage, last_change = 1, 0, 0
local staff_seen, staff_mismatch, staff_front, hold_frame = 0, 0, nil, 0
local last_gstate = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function finish(ok, reason)
    if finished then return end
    finished = true
    log("staff frames matched=%d mismatched=%d in_front_of_jade=%s",
        staff_seen, staff_mismatch, tostring(staff_front))
    log("%s reason=%s stages=%d last=%d", ok and "PASS" or "ERROR", reason, next_stage - 1, last_stage)
    logfh:close(); manager.machine:exit()
end
local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do if wanted[field.name] then fields[field.name] = field end end
    end
    for name, _ in pairs(wanted) do log("input %-16s %s", name, fields[name] and "ok" or "MISSING") end
end
local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and confirm_frame > 0 then return frame >= confirm_frame and frame < confirm_frame + 45 end
        if name == "P1 Low Kick" and vs_frame > 0 then return frame >= vs_frame + 260 and frame < vs_frame + 305 end
    end
    return false
end
-- Highest frame index among an object's multipart pieces, looked up in `map`.
local function obj_stage(obj, map)
    if obj == 0 then return 0 end
    local image = r32(obj + OIMG); if image == 0 then return 0 end
    local found = 0
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        if map[sag] then found = math.max(found, map[sag]) end
    end
    return found
end
local function current_stage() return obj_stage(r32(JADE_OBJ), body_stage) end
-- The staff is its own object, so it has to be found by walking objlst.
-- Returns stage, ozval.
local function current_staff()
    if not A.objlst then return 0, nil end
    local obj = r32(A.objlst)
    local guard = 0
    while obj ~= 0 and guard < 256 do
        local stage = obj_stage(obj, staff_stage)
        if stage ~= 0 then return stage, r32(obj + OZVAL) end
        obj = r32(obj + ONEXT)
        guard = guard + 1
    end
    return 0, nil
end
local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded markers body=%d staff=%d objlst=%s jade_side=P%d", body_markers, staff_markers,
            A.objlst and string.format("0x%x", A.objlst) or "MISSING", SIDE)
    end
    if space and not finished then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d p1=%d p2=%d", frame, last_gstate, gs,
                r16(A.p1_char), r16(A.p2_char))
            last_gstate = gs
        elseif frame % 300 == 0 then
            log("heartbeat frame=%d gstate=%d winner=%d p1=%d p2=%d", frame, gs,
                r16(A.winner_status), r16(A.p1_char), r16(A.p2_char))
        end
        if gs == GS_PSEL then
            if charsel_frame == 0 then charsel_frame = frame end
            -- Jade has no selectable grid portrait. Confirm visible Kitana,
            -- then replace the shared female-ninja slot during post-select.
            w16(JADE_CHAR, FT_KITANA); w16(FOE_CHAR, FT_JAX)
            if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        elseif gs == GS_POST then
            if vs_frame == 0 then vs_frame = frame end
            w16(JADE_CHAR, FT_JADE); w16(FOE_CHAR, FT_JAX)
        elseif gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame; log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
        end
        if fighting_frame > 0 and force_win_frame == 0 and frame - fighting_frame >= 180 then
            if r16(JADE_CHAR) ~= FT_JADE then finish(false, "jade_char_not_set") return end
            w16(JADE_BAR, MAX_HP); w16(JADE_BAR_VIEW, MAX_HP)
            w16(FOE_BAR, 0); w16(FOE_BAR_VIEW, 0)
            force_win_frame = frame; log("forced normal round win")
        end
        if force_win_frame > 0 and r16(A.winner_status) ~= 0 then
            local stage = current_stage()
            if stage ~= 0 and stage ~= last_stage then
                if stage ~= next_stage then finish(false, "stage_order") return end
                if last_stage ~= 0 and frame - last_change ~= 6 then finish(false, "stage_cadence") return end
                last_stage, last_change, next_stage = stage, frame, next_stage + 1

                -- Staff lane must be on the same index on the same frame.
                local sstage, sz = current_staff()
                if sstage == stage then
                    staff_seen = staff_seen + 1
                    if sz and staff_front == nil then
                        local pz = r32(r32(JADE_OBJ) + OZVAL)
                        staff_front = (sz > pz)
                    end
                else
                    staff_mismatch = staff_mismatch + 1
                end

                if victory_start == 0 then victory_start = frame; snap("jade_victory_01") end
                if stage == 5 then snap("jade_victory_05") end
                if stage == 9 then snap("jade_victory_09") end
                if stage == LAST_STAGE then snap("jade_victory_14") end
                log("stage=%d staff=%d rel=%d", stage, sstage, frame - victory_start)
            end
            if last_stage == LAST_STAGE and hold_frame == 0 and frame - last_change >= 18 then
                if current_stage() ~= LAST_STAGE then finish(false, "final_not_held") return end
                if current_staff() ~= LAST_STAGE then finish(false, "staff_final_not_held") return end
                if staff_mismatch ~= 0 then finish(false, "staff_out_of_sync") return end
                if staff_front ~= true then finish(false, "staff_not_in_front_of_jade") return end
                hold_frame = frame
                snap("jade_victory_final_hold")
                log("final pose held - watching for round 2 to prove the staff object is released")
            end
        end
        -- The staff is an object jade_victory deliberately never deletes (it
        -- belongs to the held pose). Prove the round teardown reclaims it
        -- rather than dragging a magenta pole into the next round.
        if hold_frame > 0 then
            if r16(A.winner_status) == 0 and gs == GS_FIGHTING and frame - hold_frame > 60 then
                local leaked = current_staff()
                if leaked ~= 0 then snap("jade_victory_staff_leak") end
                finish(leaked == 0, leaked == 0
                    and "all_14_stages_staff_synced_final_hold_and_released"
                    or "staff_leaked_into_next_round")
                return
            end
            if frame - hold_frame > 3000 then finish(false, "next_round_never_started") return end
        end
        if force_win_frame > 0 and frame - force_win_frame > 1800 and victory_start == 0 then finish(false, "jade_victory_not_seen") return end
    end
    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if not finished and frame > 11000 then finish(false, "global_timeout") end
end)
