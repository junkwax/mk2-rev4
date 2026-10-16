-- kahn_stone_capture.lua - capture Shao Kahn's turn-to-stone ending frame by frame.
--
-- Graphics audit row 30: BGSTONECRACK1, 2 and 4-7 are now the shared statue plus
-- crack-only patches (tools/make_stonecrk_img.py).  This plays a REAL game to the
-- ending so the result can be compared against a ROM from before the repack:
--
--   * a one-player game, P1 Liu Kang, the CPU forced to Shao Kahn (ft_final_boss 13)
--     at the select screen;
--   * P1's bar pinned full, Kahn's held at 1, P1 walks in punching;
--   * results_retp (MAIN.ASM) sends a 2-0 win over ft_final_boss to game_finished
--     -> boss_die_sequence -> the stone Kahn (make_kahn_obj, MKFX.ASM), whose
--     shape RAM is p1_ram.
--
-- After game over it reads p1_ram's piece SAGs every frame.  Each time the list
-- changes, that is a new animation frame: it logs the SAG list (and the MKSK.TBL
-- labels it can match) and takes a snapshot 2 frames later, when the new frame
-- is on screen.  It keeps snapshotting every 6 frames for a while after the last
-- change, to cover the stone explosion (a_bigstone / a_lilstone chunks).
--
-- Env: MK2_ROOT (map dir, with src/mk2.map), KSC_TBL (MKSK.TBL for labels, optional),
--      KSC_LOG
local ROOT = (os.getenv("MK2_ROOT") or "."):gsub("\\", "/")
local LOG = assert(os.getenv("KSC_LOG"), "KSC_LOG")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[ksc] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local S = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local function sym(n) return assert(S[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"), p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"), p1_ram = sym("p1_ram"), curback = sym("curback"),
    p1_matchw = S["p1_matchw"], p2_matchw = S["p2_matchw"],
}

-- SAG -> label, from MKSK.TBL (labels are local to MKSK.OBJ, so not in the map)
local LABELS = {}
local tbl = os.getenv("KSC_TBL")
if tbl and tbl ~= "" then
    local last = nil
    for line in io.lines(tbl) do
        local l = line:match("^([%w_]+):%s*$")
        if l then last = l
        else
            local sag = line:match("^%s*%.long%s+0?(%x+)[Hh]")
            if sag and last then LABELS[tonumber(sag, 16)] = last; last = nil end
        end
    end
end

-- MAINEQU.ASM: gs_fighting 002h, gs_psel 004h, gs_gameover 00Bh.  (006h is
-- gs_pfsetup, the pre-fight setup - the first version armed on that between
-- rounds and recorded round 2 instead of the ending.)
local GS_PSEL, GS_FIGHTING, GS_GAMEOVER = 4, 2, 0x0b
-- boss_die_sequence switches the display list to dlists_bogus ("blackness")
-- right before make_kahn_obj builds the stone Kahn: that, not the game state,
-- is the moment the crack animation can start.
local DLISTS, DLISTS_BOGUS = S["dlists"], S["dlists_bogus"]
local MAX_HP = 0xa1
local FT_KANG, FT_BOSS = 1, 13
local MP_LENGTH = 112

local frame, space, fields = 0, nil, {}
local charsel, confirm, fight, over = 0, 0, 0, 0
local last_sig, anim_k, pending_snap, last_change = nil, 0, nil, 0
local tail_until = nil
local last_gs = nil
local stone_labelled = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function pressed(name)
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fight == 0 then
        return name == "P1 High Punch" and confirm > 0 and frame >= confirm and frame < confirm + 30
    end
    if over > 0 or r16(A.gstate) ~= GS_FIGHTING then return false end
    local t = frame % 16
    if name == "P1 Right" then return true end
    if name == "P1 High Punch" then return t < 3 end
    if name == "P1 Low Punch" then return t >= 8 and t < 11 end
    return false
end

local function pieces()
    local out, p = {}, A.p1_ram
    for i = 0, 10 do
        local sag = r32(p + i * MP_LENGTH)
        if sag == 0 then break end
        out[#out + 1] = sag
    end
    return out
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = 1, ["1 Player Start"] = 1, ["P1 High Punch"] = 1, ["P1 Low Punch"] = 1,
                       ["P1 Right"] = 1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("START labels=%d", (function() local n = 0 for _ in pairs(LABELS) do n = n + 1 end return n end)())
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end
    local gs = r16(A.gstate)

    if gs == GS_PSEL and charsel == 0 then charsel = frame; log("select frame=%d", frame) end
    if charsel > 0 and fight == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_BOSS); w16(A.p2_state, 0)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
        if gs == GS_FIGHTING then
            fight = frame
            log("FIGHT frame=%d curback=%d p1=%d p2=%d", frame, r16(A.curback), r16(A.p1_char), r16(A.p2_char))
        end
        if frame > 9000 then log("END never_reached_fight"); logfh:close(); manager.machine:exit() end
        return
    end

    if over == 0 then
        -- pin through EVERY round, not just the first: P1 full, Kahn at 1
        if gs == GS_FIGHTING then
            w16(A.p1_bar, MAX_HP)
            if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
        end
        if gs ~= last_gs then
            log("gstate %d -> %d frame=%d winner_status=%d p1_matchw=%s p2_matchw=%s", last_gs or -1, gs, frame,
                r16(A.winner_status), A.p1_matchw and tostring(r16(A.p1_matchw)) or "na",
                A.p2_matchw and tostring(r16(A.p2_matchw)) or "na")
            last_gs = gs
        end
        local armed
        if DLISTS and DLISTS_BOGUS then
            armed = gs == GS_GAMEOVER and r32(DLISTS) == DLISTS_BOGUS
        else
            armed = gs == GS_GAMEOVER
        end
        if armed and fight > 0 then
            over = frame
            log("STONE_ARMED frame=%d winner_status=%d p1_matchw=%s dlists_gate=%s", frame, r16(A.winner_status),
                A.p1_matchw and tostring(r16(A.p1_matchw)) or "na", tostring(DLISTS ~= nil and DLISTS_BOGUS ~= nil))
        end
        if frame - fight > 30000 then log("END never_reached_stone"); logfh:close(); manager.machine:exit() end
        return
    end

    -- KSC_EVERY=N: also a snapshot every N frames for the first 100 after the
    -- screen goes black - where kahn_stone_creep (MKFX.ASM) lays the stone on
    -- the flesh Kahn; his own frame never changes then, so the k-snaps miss it
    local every = tonumber(os.getenv("KSC_EVERY") or "0")
    if every > 0 and frame - over <= 100 and (frame - over) % every == 0 then
        manager.machine.video:snapshot()
        log("SNAP every frame=%d rel=%d", frame, frame - over)
    end
    -- after game over: watch the stone Kahn's shape RAM
    local ps = pieces()
    local sig = table.concat((function() local t = {} for i, s in ipairs(ps) do t[i] = string.format("%08x", s) end return t end)(), ",")
    if sig ~= last_sig and #ps > 0 then
        local first = ps[1]
        local names = {}
        for i, s in ipairs(ps) do names[i] = LABELS[s] or string.format("%08x", s) end
        anim_k = anim_k + 1
        if names[1]:match("STONE") then stone_labelled = stone_labelled + 1 end
        log("ANIM k=%d frame=%d rel=%d pieces=%d %s", anim_k, frame, frame - over, #ps, table.concat(names, ","))
        pending_snap = { at = frame + 2, k = anim_k }
        last_change = frame
        last_sig = sig
    end
    if pending_snap and frame == pending_snap.at then
        manager.machine.video:snapshot()
        log("SNAP k=%d frame=%d", pending_snap.k, frame)
        pending_snap = nil
    end
    -- the explosion: every 6 frames for 240 frames after the animation settles
    if last_change > 0 and frame - last_change > 40 and not tail_until then
        tail_until = frame + 240
        log("TAIL from frame=%d", frame)
    end
    if tail_until then
        if (frame - last_change) % 6 == 0 then
            manager.machine.video:snapshot()
            log("SNAP tail frame=%d rel=%d", frame, frame - over)
        end
        if frame >= tail_until then
            log("END anim_frames=%d stone_labelled=%d armed=%d frames=%d", anim_k, stone_labelled, over, frame)
            logfh:close(); manager.machine:exit()
        end
    end
    if frame - over > 6000 then log("END timeout anim_frames=%d", anim_k); logfh:close(); manager.machine:exit() end
end)
