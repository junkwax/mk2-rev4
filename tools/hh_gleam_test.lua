-- Runtime proof that KUNG LAO'S VICTORY HAT GLEAM is its own object on its own
-- palette (hhgleam, MAINEQU.ASM; hh_victory, MKCANNED.ASM).
--
-- The gleam used to be a PIECE of his victory multipart - a_hh_victory_hat's
-- rows are TMVICTORY8A,TMVICTORY8B,TMHATGLEAMn - and MKDISP loads an object's
-- palette translate ONCE, before its multipart loop, so it could only ever
-- draw in whatever costume he was wearing.  So the thing to prove is not that
-- the gleam animates (it always did) but WHICH PALETTE it is drawn in, and
-- that it is no longer part of him.
--
-- Palette identity comes from `palram`, the allocator's own table: `opal`
-- names a MAP and palram[map] holds that palette's ROM address.  Believed only
-- while that entry's `palcnt` is non-zero - freepal leaves the id behind, so a
-- stale row reads as a palette that is no longer on screen.
--
-- HH_GLEAM_EXPECT=costume is the crossed control: it demands the gleam come
-- out in Kung Lao's own costume palette, which is the pre-change behaviour,
-- and every trial must FAIL.
--
-- fpal_fail is read across the window so an exhausted foreground pool is a
-- named CAUSE rather than a bare "wrong palette": a lane where nothing could
-- be allocated is NO VERDICT, not a failure.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("HH_GLEAM_LOG") or (ROOT .. "/tools/hh_gleam_test.log")
local EXPECT = (os.getenv("HH_GLEAM_EXPECT") or "hatgbl"):lower()
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[hh-gleam] " .. string.format(fmt, ...)
    raw_print(line); logfh:write(line, "\n"); logfh:flush()
end

-- Every address and every expectation is read out of THIS build.  A missing
-- map is a named refusal, never a default: a rig holding a stale address reads
-- the wrong RAM and reports nothing wrong.
local symbols = {}
local function load_symbols()
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if not fh then return false end
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
    return true
end
local have_map = load_symbols()

local REQUIRED = { "gstate", "p1_char", "p2_char", "p1_obj", "p1_bar", "p2_bar",
                   "p1_bar_view", "p2_bar_view", "winner_status", "objlst",
                   "palram", "fpal_fail", "HATGBL_P" }
local A, missing = {}, {}
for _, n in ipairs(REQUIRED) do
    A[n] = symbols[n]
    if not A[n] then missing[#missing + 1] = n end
end

-- TMS34010 BIT offsets, straight out of DISPEQU.ASM.
local OLINK, OZVAL, OPAL, OFLAGS2, OIMG = 0x00, 0x0c0, 0x140, 0x160, 0x1a0
-- set_inviso (MKUTIL.ASM) writes OFLAGS2, not oflags - it reads it as a WORD,
-- so the flag lives in the low 16 bits of the 32-bit field.  Watching oflags
-- (0x0f0) instead reports a gleam that never hides, which is a rig fault
-- wearing a regression's clothes.
local MP_LEN = 0x70                         -- one multipart piece node
local M_INVISO = 0x0020
local PALRSIZ, PALCNT_OFF = 0x40, 0x20      -- MAINEQU.ASM
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_HATHEAD, FT_JAX, MAX_HP = 0, 11, 0x00a1
local GLEAM_RATE, LAST_STAGE = 4, 6         -- mframew 4, six rows

-- SAG -> stage, read off the TBL the build just promoted.  A rebuild moves
-- every SAG in the pack, so these cannot be constants.
local gleam_stage, body_sag = {}, {}
local gleam_markers, body_markers = 0, 0
local function load_markers(path)
    local fh = assert(io.open(path, "r"), "missing src/MKHH.TBL: " .. path)
    local target, stage
    for line in fh:lines() do
        local n = line:match("^%s*TMHATGLEAM(%d+):")
        if n then target, stage = gleam_stage, tonumber(n) end
        local b = line:match("^%s*TMVICTORY8([AB]):")
        if b then target, stage = body_sag, 1 end
        local sag = stage and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
        if sag then
            target[tonumber(sag, 16) & 0x00ffffff] = stage
            if target == gleam_stage then gleam_markers = gleam_markers + 1
            else body_markers = body_markers + 1 end
            stage = nil
        end
    end
    fh:close()
end
load_markers(ROOT .. "/src/MKHH.TBL")

local frame, space, finished = 0, nil, false
local fields, charsel_frame, vs_frame, confirm_frame = {}, 0, 0, 0
local fighting_frame, force_win_frame, victory_start = 0, 0, 0
local next_stage, last_stage, last_change = 1, 0, 0
local gleam_front, pal_verdict, pal_seen = nil, nil, nil
local body_held, inviso_frame, hold_frame = nil, 0, 0
local fpal_fail_at_win = nil
local last_gstate = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("expect=%s palette_seen=%s verdict=%s front=%s body_held=%s stages=%d",
        EXPECT, pal_seen or "none", tostring(pal_verdict), tostring(gleam_front),
        tostring(body_held), next_stage - 1)
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true }
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
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and confirm_frame > 0 then
            return frame >= confirm_frame and frame < confirm_frame + 45
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end
    return false
end

-- Highest stage among an object's multipart pieces, looked up in `map`.
local function obj_stage(obj, map)
    if obj == 0 then return 0 end
    local image = r32(obj + OIMG); if image == 0 then return 0 end
    local found = 0
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        local s = map[sag]
        if s and s > found then found = s end
    end
    return found
end

-- The gleam is its own object, so it is found by walking objlst - never off
-- p_slave, which hh_victory never writes.
local function find_gleam()
    local obj = r32(A.objlst)
    local guard = 0
    while obj ~= 0 and guard < 256 do
        local stage = obj_stage(obj, gleam_stage)
        if stage ~= 0 then return obj, stage end
        obj = r32(obj + OLINK)
        guard = guard + 1
    end
    return nil, 0
end

-- What palette is this object actually drawn in?  opal names a MAP; palram
-- holds the id.  Only believed while palcnt is non-zero.
local function obj_palette(obj)
    if obj == 0 then return nil, 0, 0 end
    local map = r16(obj + OPAL) & 0xff
    local entry = A.palram + map * PALRSIZ
    local cnt = r16(entry + PALCNT_OFF)
    if cnt == 0 then return nil, map, 0 end
    return r32(entry), map, cnt
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
        if not have_map then finish(false, "no_src_mk2_map") return end
        if #missing > 0 then finish(false, "map_missing:" .. table.concat(missing, ",")) return end
        if gleam_markers ~= 6 or body_markers ~= 2 then
            finish(false, string.format("markers gleam=%d body=%d", gleam_markers, body_markers))
            return
        end
        log("markers gleam=%d body=%d HATGBL_P=0x%x palram=0x%x expect=%s",
            gleam_markers, body_markers, A.HATGBL_P, A.palram, EXPECT)
    end
    if space and not finished then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d p1=%d p2=%d", frame, last_gstate, gs,
                r16(A.p1_char), r16(A.p2_char))
            last_gstate = gs
        elseif frame % 300 == 0 then
            log("heartbeat frame=%d gstate=%d winner=%d fpal_fail=%d", frame, gs,
                r16(A.winner_status), r16(A.fpal_fail))
        end
        if gs == GS_PSEL then
            if charsel_frame == 0 then charsel_frame = frame end
            w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX)
            if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        elseif gs == GS_POST then
            if vs_frame == 0 then vs_frame = frame end
            w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX)
        elseif gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
        end

        if fighting_frame > 0 and force_win_frame == 0 and frame - fighting_frame >= 180 then
            if r16(A.p1_char) ~= FT_HATHEAD then finish(false, "p1_not_kung_lao") return end
            w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
            w16(A.p2_bar, 0); w16(A.p2_bar_view, 0)
            force_win_frame = frame
            fpal_fail_at_win = r16(A.fpal_fail)
            log("forced normal round win (fpal_fail=%d)", fpal_fail_at_win)
        end

        if force_win_frame > 0 and r16(A.winner_status) ~= 0 then
            local obj, stage = find_gleam()
            local hh = r32(A.p1_obj)

            if obj and stage ~= 0 and stage ~= last_stage then
                -- THE SPLIT.  His own multipart must no longer carry a gleam
                -- piece; if it does, the piece never left the body and no
                -- palette assertion below means anything.
                if obj == hh then finish(false, "gleam_drawn_on_the_player_object") return end
                if obj_stage(hh, gleam_stage) ~= 0 then
                    finish(false, "gleam_still_a_piece_of_kung_lao") return
                end

                if stage ~= next_stage then finish(false, "stage_order") return end
                if last_stage ~= 0 and frame - last_change ~= GLEAM_RATE then
                    finish(false, string.format("stage_cadence %d", frame - last_change))
                    return
                end
                last_stage, last_change, next_stage = stage, frame, next_stage + 1

                if pal_verdict == nil then
                    local id, map, cnt = obj_palette(obj)
                    local hh_id = select(1, obj_palette(hh))
                    if id == nil then
                        -- The row is free: nothing is believed off it.
                        local fails = r16(A.fpal_fail)
                        if fails > (fpal_fail_at_win or 0) then
                            finish(false, string.format(
                                "NO VERDICT: foreground pool dry (fpal_fail %d -> %d)",
                                fpal_fail_at_win or 0, fails))
                            return
                        end
                        finish(false, "NO VERDICT: gleam palette row not claimed") return
                    end
                    pal_seen = string.format("0x%x(map=%d,cnt=%d)", id, map, cnt)
                    local want = (EXPECT == "costume") and hh_id or A.HATGBL_P
                    pal_verdict = (want ~= nil and id == want)
                    log("palette gleam=%s kung_lao=0x%x want=0x%x -> %s",
                        pal_seen, hh_id or 0, want or 0, tostring(pal_verdict))
                    if not pal_verdict then
                        finish(false, string.format("palette_mismatch got=%s want=0x%x",
                                                    pal_seen, want or 0))
                        return
                    end
                end

                if gleam_front == nil then
                    gleam_front = (r32(obj + OZVAL) > r32(hh + OZVAL))
                end
                if victory_start == 0 then victory_start = frame; snap("hh_gleam_01") end
                if stage == 3 then snap("hh_gleam_03") end
                if stage == LAST_STAGE then snap("hh_gleam_06") end
                log("stage=%d rel=%d z_front=%s", stage, frame - victory_start,
                    tostring(gleam_front))
            end

            -- Past the last row: the object must go INVISIBLE (set_inviso) and
            -- his body must still be holding TMVICTORY8.  Checking only that
            -- the gleam stopped animating would pass on a spark parked on the
            -- brim for the rest of the victory, which is how it was reported
            -- for Baraka.
            if last_stage == LAST_STAGE and inviso_frame == 0
               and frame - last_change >= GLEAM_RATE + 4 then
                local gobj = select(1, find_gleam())
                if not gobj then finish(false, "gleam_object_vanished_early") return end
                if (r16(gobj + OFLAGS2) & M_INVISO) == 0 then
                    snap("hh_gleam_not_hidden")
                    finish(false, "gleam_not_hidden_after_last_row") return
                end
                body_held = (obj_stage(hh, body_sag) ~= 0)
                if not body_held then finish(false, "body_left_TMVICTORY8") return end
                if gleam_front ~= true then finish(false, "gleam_not_in_front") return end
                inviso_frame = frame
                snap("hh_gleam_hidden")
                log("gleam hidden and body still on TMVICTORY8 - watching for round 2")
            end
        end

        -- hh_victory deliberately never deletes the object (hand-deleting a gmo
        -- object is what wedged Kahn's glow).  Prove the round teardown
        -- reclaims it rather than dragging it into the next round.
        if inviso_frame > 0 then
            if hold_frame == 0 then hold_frame = inviso_frame end
            if r16(A.winner_status) == 0 and gs == GS_FIGHTING and frame - hold_frame > 60 then
                local leaked = select(1, find_gleam())
                if leaked then snap("hh_gleam_leak") end
                finish(leaked == nil,
                       leaked == nil and "own_object_own_palette_hidden_and_released"
                                      or "gleam_leaked_into_next_round")
                return
            end
            if frame - hold_frame > 3000 then finish(false, "next_round_never_started") return end
        end

        if force_win_frame > 0 and frame - force_win_frame > 1800 and victory_start == 0 then
            finish(false, "gleam_never_seen") return
        end
    end
    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if not finished and frame > 11000 then finish(false, "global_timeout") end
end)
