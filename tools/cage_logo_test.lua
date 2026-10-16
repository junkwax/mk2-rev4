-- cage_logo_test.lua - is Johnny Cage's OTOMIX logo left out on EVERY display
-- pass he is drawn mirrored, and drawn on every pass he is not?
-- (cagelogo, MAINEQU.ASM; clip41, MKDISP.ASM; data/JCLOGO.LOD)
--
-- The logo is its own multipart piece (<PIECE>L, SAG inside JCLOGO's slot),
-- listed straight after the piece it was cut off.  The walker drops it when the
-- piece's control word is flipped.  This rig checks the DMA object queue on every
-- single display pass, from a write tap on `last_dmaq` - dsa9 writes it once per
-- pass right after the last object is queued, so inside the tap the queue is
-- complete and no game process has run since the objects were walked.
--
-- A queue cell is [ctrl, sag, dest, size, const:map, scale]: MMTM stores the
-- highest register lowest, and the walker pushes a6,a8,a9,a10,a11,a12.
--
--   FLIPPED_LOGO  a logo cell drawn with its flip bit set (switch on)
--   MISSING_LOGO  a fighter facing right whose logo'd piece was drawn but whose
--                 logo piece was not
--   SKIP_WRONG    a fighter facing left whose logo piece WAS drawn (switch on)
--
-- Scenes, both fighters Cage in a two-player game, positions pinned:
--   A: P1 left facing right, P2 right facing left; P1 punches (hit reactions)
--   B: sides swapped so both turn round; P2 punches
--   C: P2's bar to 0 - the round must END and the next one must START, because
--      growing a fighter's piece lists has wedged round teardown before
--      (Baraka's victory gleam) - and the checks carry on into round 2.
-- CL_ENABLE=0 is the control: flipped logo cells MUST appear, which proves the
-- skip is what hides them.
-- CL_WINNER=2 knocks P1 out instead at C, so the winner is P2 - standing on the
-- right, FACING LEFT at the KO.  His victory must be drawn un-mirrored
-- (jc_face_front, MKCANNED.ASM) with his logo piece on screen: the victory faces
-- the camera, so it is shown as painted no matter which side he won from.
--
-- env: CL_ENABLE (1|0), CL_WINNER (1|2), CL_LOG, MK2_ROOT (src/mk2.map + src/MKDISP.ASM)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local ENABLE = tonumber(os.getenv("CL_ENABLE") or "1")
local WINNER = tonumber(os.getenv("CL_WINNER") or "1")
local LOG = os.getenv("CL_LOG") or (ROOT .. "/tools/cage_logo_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[cl] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

-- the walker's own slot constants, read from the source it was built from
local disp = assert(io.open(ROOT .. "/src/MKDISP.ASM")):read("a")
local SAG_LO = tonumber(assert(disp:match("\nCL_SAG_LO%s+%.set%s+0?(%x+)h"), "CL_SAG_LO"), 16)
local SAG_HI = tonumber(assert(disp:match("\nCL_SAG_HI%s+%.set%s+0?(%x+)h"), "CL_SAG_HI"), 16)
local function is_logo(sag) return sag >= SAG_LO and sag < SAG_HI end

local A = {
    gstate = sym("gstate"), curback = sym("curback"), round_num = sym("round_num"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    dma_q = sym("dma_q"), last_dmaq = sym("last_dmaq"), f_cagelogo = sym("f_cagelogo"),
}
local OBJQ_1 = A.dma_q + 192 * 500
local OFLAGS, OXVAL, OIMG, OCHAR = 0x0f0, 0x080, 0x1a0, 0x1f0
local FT_CAGE, GS_PSEL, GS_FIGHTING, MAXBAR = 2, 4, 2, 0xa1
local SCENE_A, SCENE_B, SCENE_C = 60, 760, 1460

local space, fields, frame = nil, {}, 0
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm, finished = 0, 0, false
local round1, round2_at, ko_at = nil, nil, nil
local V = { flipped_at_ko = nil, front_logo = 0, front_passes = 0 }

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local S = { passes = 0, cells = 0, logo_cells = 0, flipped_logo = 0, missing_logo = 0, skip_wrong = 0,
    drawn_right = { 0, 0 }, hidden_left = { 0, 0 }, turns = { 0, 0 }, last_flip = {},
    round2_passes = 0, first_bad = {} }
local function bad(kind, fmt, ...)
    S[kind] = S[kind] + 1
    if (S.first_bad[kind] or 0) < 5 then
        S.first_bad[kind] = (S.first_bad[kind] or 0) + 1
        log("%s pass=%d " .. fmt, kind:upper(), S.passes, ...)
    end
end

local function check_pass(words)
    -- from the pass after the rig writes f_cagelogo (rel 30): POWERUP sets it to 1
    if fighting_frame == 0 or frame - fighting_frame <= 31 then return end
    -- the round-end victory runs outside gs_fighting: keep checking from the KO to round 2
    if r16(A.gstate) ~= GS_FIGHTING and not (ko_at and not round2_at) then return end
    S.passes = S.passes + 1
    if round2_at then S.round2_passes = S.round2_passes + 1 end
    local on = r16(A.f_cagelogo) ~= 0
    local drawn = {}                        -- [sag*2 + flip] = true
    for k = 1, words // 6 do
        local c = OBJQ_1 - k * 192
        local sag = r32(c + 32)
        local flip = (r32(c) >> 20) & 1
        drawn[sag * 2 + flip] = true
        S.cells = S.cells + 1
        if is_logo(sag) then
            S.logo_cells = S.logo_cells + 1
            if on and flip == 1 then bad("flipped_logo", "cell=%d sag=%08x", k, sag) end
        end
    end
    for p = 1, 2 do
        local o = r32(p == 1 and A.p1_obj or A.p2_obj)
        if o ~= 0 then
            local flip = r16(o + OFLAGS) & 0x10 ~= 0
            if S.last_flip[p] ~= nil and S.last_flip[p] ~= flip then S.turns[p] = S.turns[p] + 1 end
            S.last_flip[p] = flip
            local fb = flip and 1 or 0
            local piece, prev = r32(o + OIMG), nil
            for _ = 1, 13 do
                local sag = r32(piece)
                if sag == 0 then break end
                if is_logo(sag) and prev then
                    local base_drawn = drawn[prev * 2 + fb]
                    local logo_drawn = drawn[sag * 2 + fb]
                    if not flip or not on then
                        if base_drawn and not logo_drawn then
                            bad("missing_logo", "P%d logo %08x after %08x not drawn", p, sag, prev)
                        elseif logo_drawn then
                            S.drawn_right[p] = S.drawn_right[p] + 1
                        end
                    else
                        if logo_drawn then
                            bad("skip_wrong", "P%d facing left drew logo %08x", p, sag)
                        elseif base_drawn then
                            S.hidden_left[p] = S.hidden_left[p] + 1
                        end
                    end
                end
                prev = sag
                piece = piece + 112
            end
            -- the winner, from the KO until round 2
            if ko_at and not round2_at and p == WINNER then
                if V.flipped_at_ko == nil then V.flipped_at_ko = flip end
                if not flip then
                    V.front_passes = V.front_passes + 1
                    local q = r32(o + OIMG)
                    for _ = 1, 13 do
                        local sag = r32(q)
                        if sag == 0 then break end
                        if is_logo(sag) and drawn[sag * 2] then V.front_logo = V.front_logo + 1; break end
                        q = q + 112
                    end
                end
            end
        end
    end
end

local function finish(reason)
    if finished then return end
    finished = true
    log("RESULT enable=%d passes=%d cells=%d logo_cells=%d flipped_logo=%d missing_logo=%d skip_wrong=%d",
        ENABLE, S.passes, S.cells, S.logo_cells, S.flipped_logo, S.missing_logo, S.skip_wrong)
    log("COVER p1_logo_right=%d p1_hidden_left=%d p2_logo_right=%d p2_hidden_left=%d turns=%d,%d round2=%s round2_passes=%d",
        S.drawn_right[1], S.hidden_left[1], S.drawn_right[2], S.hidden_left[2], S.turns[1], S.turns[2],
        tostring(round2_at ~= nil), S.round2_passes)
    local ok = S.passes >= 1000 and S.missing_logo == 0 and round2_at ~= nil and S.round2_passes >= 200
        and S.drawn_right[1] >= 200 and S.drawn_right[2] >= 200 and S.turns[1] >= 1 and S.turns[2] >= 1
    if ENABLE ~= 0 then
        ok = ok and S.flipped_logo == 0 and S.skip_wrong == 0
            and S.hidden_left[1] >= 200 and S.hidden_left[2] >= 200
    else
        -- the control: with the skip off, a flipped fighter's logo must be drawn
        ok = ok and S.hidden_left[1] == 0 and S.hidden_left[2] == 0
    end
    if WINNER == 2 then
        log("VICTORY winner=P2 flipped_at_ko=%s unmirrored_passes=%d logo_drawn_passes=%d",
            tostring(V.flipped_at_ko), V.front_passes, V.front_logo)
        -- he won FACING LEFT; the victory must still show him as painted, logo and all
        ok = ok and V.flipped_at_ko == true and (ENABLE == 0 or V.front_logo >= 30)
    end
    log("%s reason=%s", ok and "PASS" or "FAIL", reason)
    logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if f.name:match("^P[12] ") or f.name == "Coin 1" or f.name == "UI Select"
                or f.name == "1 Player Start" or f.name == "2 Players Start" then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if rel >= SCENE_C then return false end
        local hitter = rel < SCENE_B and "P1" or "P2"
        if name == hitter .. " High Punch" then return rel >= SCENE_A + 20 and (rel % 40) < 4 end
        return false
    end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        S.tap = space:install_write_tap(A.last_dmaq, A.last_dmaq + 15, "cl_pass",
            function(offset, data, mask)
                if not finished then check_pass(data & 0xffff) end
                return data
            end)
        log("loaded enable=%d logo slot %08x..%08x", ENABLE, SAG_LO, SAG_HI)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_CAGE); w16(A.p2_char, FT_CAGE)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, 0) end
    if frame > 9000 and fighting_frame == 0 then log("never reached the fight"); finish("no_fight"); return end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
        if rel == 30 then
            assert(o1 ~= 0 and o2 ~= 0, "fighters missing")
            assert(r16(o1 + OCHAR) == FT_CAGE and r16(o2 + OCHAR) == FT_CAGE, "both fighters must be Cage")
            w16(A.f_cagelogo, ENABLE)
            round1 = r16(A.round_num)
            log("round %d, f_cagelogo=%d", round1, ENABLE)
        end
        if rel >= SCENE_A and rel < SCENE_C and o1 ~= 0 and o2 ~= 0 then
            local left, right = 500, 560
            -- CL_WINNER=2: back to scene A's sides 150 passes before the KO, so both
            -- have turned round and P2 is on the right FACING LEFT when he wins
            if rel < SCENE_B or (WINNER == 2 and rel >= SCENE_C - 150) then
                w32(o1 + OXVAL, left << 16); w32(o2 + OXVAL, right << 16)
            else
                w32(o1 + OXVAL, right << 16); w32(o2 + OXVAL, left << 16)
            end
            w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
        end
        if rel == SCENE_A + 200 or rel == SCENE_B + 200 or (ko_at and frame - ko_at == 1 or ko_at and frame - ko_at == 200) then
            pcall(function() manager.machine.screens[":screen"]:snapshot() end)
            log("SNAP rel=%d", rel)
        end
        if rel == SCENE_C then
            ko_at = frame
            w16(WINNER == 2 and A.p1_bar or A.p2_bar, 0)
            log("SCENE_C round %d: P%d's bar to 0", r16(A.round_num), 3 - WINNER)
        end
        if rel > SCENE_C and not round2_at and round1 and r16(A.round_num) > round1
            and gs == GS_FIGHTING and o1 ~= 0 and o2 ~= 0 then
            round2_at = frame
            log("ROUND %d started at rel=%d", r16(A.round_num), rel)
        end
        if round2_at and frame - round2_at == 400 then finish("round_advanced"); return end
        if rel > SCENE_C + 3000 and not round2_at then finish("round_never_advanced"); return end
    end
    for name, f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end
end)
