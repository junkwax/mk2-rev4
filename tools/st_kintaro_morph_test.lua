-- ============================ OBSOLETE =================================
-- The Goro-reveal half of this harness no longer applies: `stgoro_roll` and
-- `stdive_goro` were REMOVED on 2026-08-05 along with the MK2STGO art, to
-- reclaim the 28,672-byte STGORO video-ROM slot. This script drives that path
-- by patching stgoro_roll's randper immediate in the :maincpu ROM region, and
-- that label no longer exists -- so the goro mode cannot work.
--
-- Shang's dive fatality now ends on the STOCK burst-out. The RETAIL Kintaro
-- morph (do_kintaro_fatal, the ~15s LP hold) is untouched, so the "direct"
-- mode's subject still exists, but the frame labels this script matches on
-- (MK2STGO*) do not.
--
-- Kept for reference only. Do not trust a PASS from it without rewriting it
-- against the current code.
-- =======================================================================

-- st_kintaro_morph_test.lua
--
-- End-to-end MAME harness for the Goro morph on Shang Tsung's inner-explosion
-- fatality (do_kintaro_fatal in MKDEATH.ASM), after its three Kintaro-anitab
-- beats were replaced with the STGORO sidecar art:
--
--   beat 1 emerge -> STGORO2 (STGORO2A + STGORO2B)
--   beat 2 strike -> STGORO3 (STGORO3A + STGORO3B)
--   beat 3 gloat  -> STGORO4 (STGORO4A + STGORO4B)
--
-- Design under test (2026-07-21): the inner explosion ALWAYS plays (the old
-- top-of-dive roll into do_kintaro_fatal is retired); the same 1-in-8 roll now
-- lives at the END of do_st_dive (exported label stgoro_roll) and decides the
-- victory reveal.  The trigger was remapped to a plain HK PRESS during Finish
-- Him (MOVES.ASM st_hi_kick, distance >= 0x50) - the retail hold-and-release
-- in st_hk_open still exists but the press path wins first.
--
-- Reaching a genuine Finish Him (modeled on jc_headhole_fatality_test.lua):
-- MOVES.ASM queue_and_jump runs p1/p2_die_check BEFORE dispatching button
-- handlers, so the fatality input is only accepted when the victim is actually
-- the dying loser of the deciding round.  So this test wins round 1 (drain the
-- victim, set winner_status=3), then in round 2 forces the match-ending KO:
-- victim bar -> 0, winner_status=3, the ATTACKER bar back to MAX (a low
-- attacker bar blocks the trigger), blocking flags cleared, action -> stance,
-- and a non-zero round clock (a zero clock makes MAIN skip finish_him_sequence
-- entirely as a "timeout round").  The victim then falls into the real dizzy
-- loop and the HK press is accepted.
--
-- The end-of-dive Goro roll is only 125/1000, so the harness forces it by
-- rewriting stgoro_roll's randper immediate 125 -> 1000 in the :maincpu ROM
-- *region* (the CPU program space serves ROM read-only - a space:write is
-- silently dropped; the debugger's loadr writes the region, and so do we).
--
-- Validation: walk the object lists, map each visible osag to its authored
-- STGORO.TBL label, assert all six subframes appear in 2 -> 3 -> 4 pose order,
-- and assert pm_alt_pal latches on P1 (proof the explicit STGORO1_P player_swpal
-- ran - the sidecar is POF>, so nothing else would assign a palette).

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("ST_KINTARO_LOG") or (ROOT .. "/tools/st_kintaro_morph_test.log")
local FRAME_LOG_PATH = os.getenv("ST_KINTARO_FRAME_LOG") or (ROOT .. "/tools/st_kintaro_morph_frames.csv")
-- The full explosion (dizzy poses, squeeze, inflate, shakes, burst) runs
-- before the reveal, so the pass window is generous.
local CAPTURE_UNTIL = getenv_int("ST_KINTARO_CAPTURE_UNTIL", 1800)
local PASS_REL = getenv_int("ST_KINTARO_PASS_REL", 1800)
local STAGE_ID = getenv_int("ST_KINTARO_STAGE", 5)
-- st_hk_open needs x_dist >= 0x50; 0x64 keeps a margin and stays inside the
-- kintaro roll's own [0x50,0x78] band too.
local MORPH_X = getenv_int("ST_KINTARO_X", 0x64)

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(FRAME_LOG_PATH, "w")
if csvfh then
    csvfh:write("capture_index,emu_frame,rel,f_death,stgoro_labels,p1_opal,p1_altpal,p1_x,p2_x\n")
    csvfh:flush()
end

local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[st-kintaro] " .. msg)
end

local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

-- Resolve symbols from the freshly built linker map.
local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if not fh then map_path = ROOT .. "/src/MK2.MAP"; fh = io.open(map_path, "r") end
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
        log("loaded symbols from %s", map_path)
    else
        log("WARN no linker map found; using address fallbacks")
    end
end

local function sym(name, fallback)
    local value = symbols[name]
    if value ~= nil then return value end
    log("WARN missing symbol %s; fallback=%s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    active        = sym("active", 0x010dc6d0),
    gstate        = sym("gstate", 0x0112a7f0),
    p1_state      = sym("p1_state", 0x0112a810),
    p2_state      = sym("p2_state", 0x0112b3e0),
    p1_char       = sym("p1_char", 0x0112a8a0),
    p2_char       = sym("p2_char", 0x0112b470),
    p1_obj        = sym("p1_obj", 0x0112a840),
    p2_obj        = sym("p2_obj", 0x0112b410),
    p1_proc       = sym("p1_proc", 0x0112a860),
    p2_proc       = sym("p2_proc", 0x0112b430),
    p1_bar        = sym("p1_bar", 0x0112a910),
    p2_bar        = sym("p2_bar", 0x0112b4e0),
    p1_bar_view   = sym("p1_bar_view", 0x011285f0),
    p2_bar_view   = sym("p2_bar_view", 0x01128530),
    curback       = sym("curback", 0x0112c0f0),
    worldtlx      = sym("worldtlx", 0x01127430),
    winner_status = sym("winner_status", 0x0112c130),
    f_death       = sym("f_death", 0x0112c020),
    f_no_blood    = sym("f_no_blood", 0x0112c1f0),
    f_no_violence = sym("f_no_violence", 0x0112c200),
    pf_ram        = sym("pf_ram", 0x0112c0b0),
    p1_matchw     = sym("p1_matchw", 0xffc0a350),
    p2_matchw     = sym("p2_matchw", 0xffb467a0),
    round_num     = sym("round_num", 0xffc08bb0),
    f_thatsall    = sym("f_thatsall", 0xffc083d0),
    clk_ones      = sym("clk_ones", 0xffbc0bd0),
    clk_tens      = sym("clk_tens", 0xffb37ab0),
    objlst        = sym("objlst", 0x01127570),
    objlst2       = sym("objlst2", 0x01127590),
    objlst3       = sym("objlst3", 0x011275b0),
    dizzy         = sym("dizzy", 0xffa27e40),
    system_lockup = sym("system_lockup", 0xffa74d60),
    tvbp          = sym("TVBP", 0xffa74f70),
    -- End-of-dive Goro reveal roll, exported from MKDEATH.ASM.
    stgoro_roll   = sym("stgoro_roll", 0),
}

local O = {
    next = 0x000, oxvel = 0x040, oyvel = 0x060, oxval = 0x080, oxpos = 0x090,
    oyval = 0x0a0, oypos = 0x0b0, osag = 0x100, opal = 0x140, oimg = 0x1a0,
    ochar = 0x1f0,
}
local P = {
    next = 0x000, id = 0x020, wake = 0x0e0, otherguy = 0x140, otherproc = 0x170,
    action = 0x1f0, ganiy = 0x200, flags = 0x210, store4 = 0x290,
}

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local PS_ACTIVE = 1
local FT_ST, FT_JAX = 6, 11
local MAX_HP = 0x00a1
local ACT_STANCE, ACT_STUNNED = 0x0303, 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local PM_ALT_PAL = 0x0020
-- do_st_dive calls init_death_blow with a1=2, so f_death latches 2.
local EXPECTED_FDEATH = 2

local cpu, space = nil, nil
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local fight_count, last_gstate = 0, -1
local p1_confirm_start, did_direct_select = 0, false
local did_force_round1, round1_forced_frame = false, 0
local finish_forced_frame = 0
local dizzy_ready_frame, hk_window_start, did_input_log = 0, 0, false
local roll_forced = false
local fatality_frame, fdeath_seen = 0, false
local seen = {}
local pose_rel = {}
local pose_order = {}
local altpal_seen, altpal_rel = false, nil
local completed, did_error, finished = false, false, false
local pending_snaps, capture_index, last_status_frame = {}, 0, 0

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end
local function w32(addr, value) space:write_u32(addr, value & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 High Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local missing = {}
    for name, _ in pairs(wanted) do
        if fields[name] then log("input %-16s ok", name)
        else log("input %-16s MISSING", name); missing[#missing + 1] = name end
    end
    return #missing == 0
end

local function main_screen()
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then return screen end
    ok, screen = pcall(function() return manager.machine.screens:at(1) end)
    return ok and screen or nil
end

local function queue_snap(label)
    pending_snaps[#pending_snaps + 1] = { index = capture_index, frame = frame, label = label }
    log("SNAPQUEUED index=%04d frame=%d label=%s", capture_index, frame, label)
    capture_index = capture_index + 1
end

local function flush_snaps()
    if #pending_snaps == 0 then return end
    local screen = main_screen()
    for _, request in ipairs(pending_snaps) do
        local ok, err = false, "no screen"
        if screen then ok, err = pcall(function() screen:snapshot() end) end
        log("SNAP index=%04d frame=%d label=%s ok=%s%s", request.index, request.frame,
            request.label, tostring(ok), ok and "" or (" error=" .. tostring(err)))
    end
    pending_snaps = {}
end

-- Map runtime SAGs back to authored STGORO.TBL labels.  Masking to 24 bits
-- normalizes the LOD's 0x05c80000 runtime window against the 0x03c80000 the
-- table records, exactly as the other sidecar harnesses do.
local sag_labels = {}
local sag_count = 0
local function load_sag_labels(path, pattern)
    local fh = io.open(path, "r")
    if not fh then log("WARN cannot open %s for SAG labels", path); return end
    local current = nil
    for line in fh:lines() do
        local label = line:match("^([%w_]+):")
        if label then
            current = label:match(pattern)
        elseif current then
            local raw = line:match("%.long%s+([%x]+)H")
            if raw then
                sag_labels[tonumber(raw, 16) & 0x00ffffff] = current
                sag_count = sag_count + 1
                current = nil
            end
        end
    end
    fh:close()
end
load_sag_labels(ROOT .. "/src/STGORO.TBL", "^(MK2STGO%d+[AB])")
log("loaded %d MK2STGO SAG labels", sag_count)

-- Multipart RAM entries are 0x70 bits each (sag:L, y:x size:L, control:W,
-- dx:W, dy:W) terminated by a zero sag - walk the whole chain so B strips
-- are seen, not just the first-queued A piece.
local MP_LEN = 0x70
local function marker_set()
    local found = {}
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag1 = r32(obj + O.osag) & 0x00ffffff
            local label = sag_labels[sag1]
            if label then found[label] = true end
            local img = r32(obj + O.oimg)
            if img ~= 0 then
                for part = 0, 7 do
                    local psag = r32(img + part * MP_LEN)
                    if psag == 0 then break end
                    local plabel = sag_labels[psag & 0x00ffffff]
                    if plabel then found[plabel] = true end
                end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return found
end

local function sorted_labels(set)
    local items = {}
    for label, _ in pairs(set) do items[#items + 1] = label end
    table.sort(items)
    return #items > 0 and table.concat(items, "+") or "-"
end

local function force_select()
    w16(A.p1_char, FT_ST); w16(A.p2_char, FT_JAX); w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=ShangTsung(%d) P2=Jax(%d) stage=%d", FT_ST, FT_JAX, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    return p1char == FT_ST and p2char == FT_JAX, p1char, p2char
end

local function pxy()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p2x = 0, 0
    if p1obj ~= 0 then p1x = r16(p1obj + O.oxpos) end
    if p2obj ~= 0 then p2x = r16(p2obj + O.oxpos) end
    return p1x, p2x
end

local function p1_palette_state()
    local p1obj, p1proc = r32(A.p1_obj), r32(A.p1_proc)
    local opal = p1obj ~= 0 and r16(p1obj + O.opal) or 0
    local flags = p1proc ~= 0 and r16(p1proc + P.flags) or 0
    return opal, (flags & PM_ALT_PAL) ~= 0
end

local function normalize_player_links()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1proc, p2proc = r32(A.p1_proc), r32(A.p2_proc)
    if p1proc ~= 0 and p2proc ~= 0 and p1obj ~= 0 and p2obj ~= 0 then
        w32(p1proc + P.otherguy, p2obj); w32(p1proc + P.otherproc, p2proc)
        w32(p1proc + P.store4, p1proc)
        w32(p2proc + P.otherguy, p1obj); w32(p2proc + P.otherproc, p1proc)
        w32(p2proc + P.store4, p2proc)
    end
end

-- Ground both fighters, kill velocity, and set P1<-MORPH_X->P2 so st_hk_open's
-- x_dist gate (>= 0x50) is satisfied and they face each other.
local function position_for_fatality()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local world_left = r16(A.worldtlx + 16)
    if world_left == 0xffff then world_left = 0 end
    local p1x = world_left + 136
    local p2x = p1x + MORPH_X
    local p1proc, p2proc = r32(A.p1_proc), r32(A.p2_proc)
    local p1y = r16(p1obj + O.oypos); if p1y == 0 and p1proc ~= 0 then p1y = r16(p1proc + P.ganiy) end
    local p2y = r16(p2obj + O.oypos); if p2y == 0 and p2proc ~= 0 then p2y = r16(p2proc + P.ganiy) end
    w16(p1obj + O.oxpos, p1x); w32(p1obj + O.oxval, p1x << 16)
    w32(p1obj + O.oxvel, 0); w32(p1obj + O.oyvel, 0)
    w16(p2obj + O.oxpos, p2x); w32(p2obj + O.oxval, p2x << 16)
    w32(p2obj + O.oxvel, 0); w32(p2obj + O.oyvel, 0)
    if p1y ~= 0 then
        w16(p1obj + O.oypos, p1y); w32(p1obj + O.oyval, p1y << 16)
        if p1proc ~= 0 then w16(p1proc + P.ganiy, p1y) end
    end
    if p2y ~= 0 then
        w16(p2obj + O.oypos, p2y); w32(p2obj + O.oyval, p2y << 16)
        if p2proc ~= 0 then w16(p2proc + P.ganiy, p2y) end
    end
end

local function clear_blocking_flags(proc)
    if proc == 0 then return end
    w16(proc + P.flags, r16(proc + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
end

-- Round 1: win it so round 2 is the deciding round.  P1 is the attacker
-- (Shang), P2 the victim (Jax): drain P2, declare the round.
local function force_round1_win()
    if fight_count ~= 1 or fighting_frame == 0 or did_force_round1 then return end
    local rel = frame - fighting_frame
    if rel < 120 then return end
    did_force_round1 = true
    round1_forced_frame = frame
    position_for_fatality()
    normalize_player_links()
    w16(A.p2_bar, 0); w16(A.p2_bar_view, 0)
    w16(A.winner_status, 3)
    log("round1_forced frame=%d rel=%d", frame, rel)
    queue_snap("round1_forced")
end

-- Round 2 (deciding): match-ending KO of the victim WITH the attacker healthy,
-- which is the posture queue_and_jump's die-check requires before it will hand
-- a switch-opening (st_hk_open) to the fatality path.
local function force_finish_him()
    -- Hands off the moment the fatality starts: keeping these writes running
    -- would zero f_death mid-fatality and snap positions during the sequence.
    if fight_count ~= 2 or fighting_frame == 0 or fatality_frame ~= 0
        or r16(A.f_death) ~= 0 then return end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 620 then return end
    w16(A.winner_status, 3); w16(A.f_death, 0)
    w16(A.f_no_blood, 0); w16(A.f_no_violence, 0)
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, 0); w16(A.p2_bar_view, 0)
    -- MAIN.ASM play_1_round skips finish_him_sequence when clk_ones+clk_tens==0
    -- (timeout round, line 430).  Keep the clock non-zero so the real 8-second
    -- fatality window opens instead of dropping straight to the winner/bonus.
    w16(A.clk_ones, 0); w16(A.clk_tens, 3)
    normalize_player_links()
    local p1proc = r32(A.p1_proc)
    if p1proc ~= 0 then clear_blocking_flags(p1proc); w16(p1proc + P.action, ACT_STANCE) end
    position_for_fatality()
    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        local p2proc = r32(A.p2_proc)
        log("finish_him_forced frame=%d rel=%d victim_wake=%s dizzy=%s", frame, rel,
            hx(p2proc ~= 0 and r32(p2proc + P.wake) or 0), hx(A.dizzy))
        queue_snap("finish_him_forced")
    end
end

local function victim_ready()
    local proc = r32(A.p2_proc)
    if proc == 0 then return false end
    local wake = r32(proc + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(proc + P.action) == ACT_STUNNED
end

-- Rewrite stgoro_roll's `movi 125,a0` percentage immediate to 1000 so randper
-- always sets carry and the Goro reveal is taken.  125 fits 16 bits, so GSPA
-- picks the short MOVI IW form: one opcode word then a single immediate word.
-- 1000 also fits 16 bits, so the patch is length-preserving.  The immediate is
-- in program ROM (0xFF800000 window); the CPU program space serves it
-- read-only, so this patches the :maincpu ROM region (byte-addressed) like the
-- debugger's loadr, then confirms via a space read-back.
local ROM_BASE_BIT = 0xFF800000
local rom_region = nil
local function force_kintaro_roll()
    if roll_forced then return true end
    if A.stgoro_roll == 0 then
        log("ERROR stgoro_roll not in mk2.map - stale build?")
        return false
    end
    local imm_bit = A.stgoro_roll + 16
    local imm = r16(imm_bit)
    log("stgoro_roll=%s roll_immediate=%d", hx(A.stgoro_roll), imm)
    if imm == 1000 then
        -- Source is in TEMP always-reveal mode for self-testing; nothing to do.
        roll_forced = true
        log("roll already always-on (1000) - no patch needed")
        return true
    end
    if imm ~= 125 then
        log("ERROR unexpected roll immediate %d (want 125 or 1000) - refusing to patch", imm)
        return false
    end
    if not rom_region then
        rom_region = manager.machine.memory.regions[":maincpu"]
        if not rom_region then log("ERROR :maincpu region unavailable"); return false end
    end
    local off = (imm_bit - ROM_BASE_BIT) // 8
    local region_imm = rom_region:read_u16(off)
    log("region off=%s region_imm=%d size=%d", hx(off), region_imm, rom_region.size)
    if region_imm ~= 125 then
        log("ERROR region immediate %d != 125 at off=%s; offset math wrong - refusing", region_imm, hx(off))
        return false
    end
    rom_region:write_u16(off, 1000)
    local via_region, via_space = rom_region:read_u16(off), r16(imm_bit)
    if via_region ~= 1000 or via_space ~= 1000 then
        log("ERROR roll patch not visible (region=%d space=%d)", via_region, via_space)
        return false
    end
    roll_forced = true
    log("kintaro_roll_forced 125 -> 1000 (region off=%s, space confirms)", hx(off))
    return true
end

-- The remapped trigger fires on the HK PRESS (st_hi_kick finish-him branch),
-- so short presses with gaps suffice; repeat in case an early edge lands
-- before the joy process is ready.
local HK_PRESS, HK_GAP = 8, 22
local function hk_held(rel)
    return (rel % (HK_PRESS + HK_GAP)) < HK_PRESS
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    if name == "P1 High Kick" and hk_window_start > 0 and fatality_frame == 0 then
        local rel = frame - hk_window_start
        if rel >= 0 and rel < 360 then return hk_held(rel) end
    end
    return false
end

local function write_frame_log(rel, found)
    if not csvfh then return end
    local p1x, p2x = pxy()
    local opal, altpal = p1_palette_state()
    csvfh:write(string.format("%d,%d,%d,%d,%s,%d,%d,%d,%d\n", capture_index, frame, rel,
        r16(A.f_death), sorted_labels(found), opal, altpal and 1 or 0, p1x, p2x))
    csvfh:flush()
end

local function cpu_pc()
    if not cpu then return nil end
    for _, name in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, item = pcall(function() return cpu.state[name] end)
        if ok and item then
            local okv, value = pcall(function() return item.value end)
            if okv then return value end
        end
    end
    return nil
end

local function check_lockup()
    if not space then return false end
    local pc = cpu_pc()
    if pc and pc >= A.system_lockup and pc < A.tvbp then
        log("ERROR lockup pc=%s pf=%s", hx(pc), hx(r32(A.pf_ram)))
        did_error = true
        return true
    end
    return false
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    queue_snap(ok and "pass_final" or ("error_" .. reason))
    flush_snaps()
    if csvfh then csvfh:close(); csvfh = nil end
    local order = #pose_order > 0 and table.concat(pose_order, "->") or "-"
    log("%s reason=%s fdeath_seen=%s poses=%s order=%s altpal=%s(rel=%s) seen=%s",
        ok and "PASS" or "ERROR", reason, tostring(fdeath_seen),
        string.format("1=%s 2=%s 3=%s 4=%s", tostring(pose_rel[1]), tostring(pose_rel[2]), tostring(pose_rel[3]), tostring(pose_rel[4])),
        order, tostring(altpal_seen), tostring(altpal_rel), sorted_labels(seen))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "required_input_missing"); return end
        if sag_count < 8 then finish(false, "stgoro_tbl_labels_missing"); return end
        log("loaded: P1 ShangTsung vs P2 Jax; route=st_hi_kick press -> do_fatality_2 -> do_st_dive; reveal roll at stgoro_roll=%s",
            hx(A.stgoro_roll))
    end

    if not space then return end
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d mw=%d/%d rnd=%d ws=%d tha=%d fdeath=%d", frame, last_gstate, gs,
            r16(A.p1_matchw), r16(A.p2_matchw), r16(A.round_num),
            r16(A.winner_status), r16(A.f_thatsall), r16(A.f_death))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d", frame, fight_count)
            queue_snap("fight_" .. tostring(fight_count) .. "_start")
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 then
        force_select()
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_ST and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
    end

    -- Reset per-round tracking when a new fight begins.
    force_round1_win()
    force_finish_him()

    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        if not force_kintaro_roll() then finish(false, "roll_patch_failed"); return end
        dizzy_ready_frame = frame
        hk_window_start = frame + 20
        log("victim_dizzy_ready frame=%d; HK pulse window at frame=%d", frame, hk_window_start)
        queue_snap("victim_dizzy_ready")
    end

    if hk_window_start > 0 and frame >= hk_window_start and not did_input_log then
        did_input_log = true
        log("hk_window_open frame=%d", frame)
        queue_snap("input_hk")
    end

    -- unconditional morph capture: snapshot the whole post-HK window regardless
    -- of pose/fdeath detection, so the original Kintaro morph is captured even
    -- though the STGORO pose labels no longer appear.
    if hk_window_start > 0 and frame >= hk_window_start then
        local hrel = frame - hk_window_start
        if hrel > 0 and hrel <= 340 and hrel % 18 == 0 then
            queue_snap(string.format("hkcap_rel_%03d", hrel))
        end
    end

    local fdeath = r16(A.f_death)
    if fdeath == EXPECTED_FDEATH and fatality_frame == 0 and hk_window_start > 0 then
        fatality_frame = frame
        fdeath_seen = true
        log("explosion_started frame=%d f_death=%d", frame, fdeath)
        queue_snap("morph_start")
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local found = marker_set()
        for label, _ in pairs(found) do
            seen[label] = true
            local pose = tonumber(label:match("^MK2STGO(%d+)"))
            if pose and not pose_rel[pose] then
                pose_rel[pose] = rel
                pose_order[#pose_order + 1] = tostring(pose)
                log("pose_seen MK2STGO%d frame=%d rel=%d label=%s", pose, frame, rel, label)
                queue_snap(string.format("pose_mk2goro%d_rel_%03d", pose, rel))
            end
        end

        local _, altpal = p1_palette_state()
        if altpal and not altpal_seen then
            altpal_seen = true
            altpal_rel = rel
            log("pm_alt_pal_latched frame=%d rel=%d (per-pose MK2GO*_P player_swpal ran)", frame, rel)
        end

        local capture = (rel <= CAPTURE_UNTIL and rel % 25 == 0) or rel == PASS_REL
        if capture then
            write_frame_log(rel, found)
            queue_snap(string.format("morph_rel_%03d_%s", rel, sorted_labels(found)))
        end

        if rel > 250 and (fdeath == 0 or fdeath == 0xffff) then completed = true end

        if rel >= PASS_REL then
            if did_error then finish(false, "runtime_error")
            elseif not fdeath_seen then finish(false, "f_death_2_not_seen")
            elseif not (seen["MK2STGO1A"] and seen["MK2STGO1B"]) then finish(false, "mk2goro1_subframes_missing")
            elseif not (seen["MK2STGO2A"] and seen["MK2STGO2B"]) then finish(false, "mk2goro2_subframes_missing")
            elseif not (seen["MK2STGO3A"] and seen["MK2STGO3B"]) then finish(false, "mk2goro3_subframes_missing")
            elseif not (seen["MK2STGO4A"] and seen["MK2STGO4B"]) then finish(false, "mk2goro4_subframes_missing")
            elseif not (pose_rel[1] and pose_rel[2] and pose_rel[3] and pose_rel[4]
                and pose_rel[1] <= pose_rel[2] and pose_rel[2] <= pose_rel[3]
                and pose_rel[3] <= pose_rel[4]) then
                finish(false, "pose_order_wrong")
            elseif not altpal_seen then finish(false, "mk2goro_p_swpal_never_ran")
            else finish(true, "reveal_mk2goro1_4_with_mk2goro_p") end
            return
        end
    end

    if check_lockup() then finish(false, "mkbug_lockup"); return end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        local _, p1ochar, p2ochar = loaded_fighters_match()
        local opal, altpal = p1_palette_state()
        log("status frame=%d gs=%d fight=%d p1=%d/%d p2=%d/%d ws=%d fdeath=%d mw=%d/%d rnd=%d tha=%d clk=%d/%d opal=%d altpal=%s",
            frame, gs, fight_count, r16(A.p1_char), p1ochar, r16(A.p2_char), p2ochar,
            r16(A.winner_status), r16(A.f_death), r16(A.p1_matchw), r16(A.p2_matchw),
            r16(A.round_num), r16(A.f_thatsall), r16(A.clk_tens), r16(A.clk_ones), opal, tostring(altpal))
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif fight_count < 2 and fighting_frame > 0 and frame - fighting_frame > 3200 then
        finish(false, "round2_never_reached")
    elseif hk_window_start > 0 and fatality_frame == 0 and frame - hk_window_start > 420 then
        finish(false, "morph_never_started_after_hk")
    elseif frame > 16000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function() flush_snaps() end)
