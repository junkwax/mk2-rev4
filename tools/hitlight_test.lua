-- hitlight_test.lua - does the owned-palette hit light touch ONLY the fighter
-- who was hit, and always give his colours back?  (graphics audit prototype #6,
-- doc/graphics_opportunities/HITLIGHT_PROTOTYPE.md)
--
-- getfpal keys a colour map by the palette's ADDRESS, so every object on one
-- palette shares one map, and a light that tinted that map in place would
-- light all of them.  The obvious sharer turns out not to exist: a MIRROR
-- MATCH does not share, because MKGUYS check_same_character_pal hands P2
-- character_palettes_2 (the "ugly" alternate).  So the sharer is CONSTRUCTED,
-- which is also the stricter test:
--
--   1. at fight start take P1's map and add one reference to its palcnt - a
--      second owner as far as the allocator is concerned, so that map can never
--      be released or re-let while the test runs;
--   2. snapshot that map's 64 colours as the baseline;
--   3. P2 punches an idle P1 over and over (2-player game, bars refilled so the
--      round never ends);
--   4. every refresh read which map P1 wears and what palette id it was
--      allocated for.  A private buffer is RAM (scratch), every fighter palette
--      is ROM - so "lit" is simply "P1's id is a RAM address";
--   5. while P1 is lit the ORIGINAL map must hold the baseline colours EXACTLY
--      (the sharer check), P1's own map must differ from them on some tick (the
--      light is visible), no single light may outlast the envelope (a stuck
--      private palette is what the first version of this rig caught), and when
--      a light ends P1 must be back on the original id with the private map's
--      count back at 0 (restore + no leak).
--
-- HL_ENABLE=0 is the negative control: same punches, hits must land, and no
-- private map may ever appear.
-- HL_BLOCK=1 instead holds P1 Block against P2 high kicks. Every measured
-- health loss must occur in a block action; neither switch state may light.
--
-- HL_SIDE=2 reverses attacker/victim roles and monitors P2's alternate palette.
-- The P1-victim walkthrough above describes the default HL_SIDE=1.
--
-- env: HL_SIDE (1|2), HL_ENABLE (1|0), HL_BLOCK (1|0), HL_CHAR (ft_* index, default 1 = Liu Kang),
--      HL_LOG (log path), MK2_ROOT (dir holding src/mk2.map)
-- All addresses are TMS34010 BIT addresses; Lua reads take them raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local ENABLE = tonumber(os.getenv("HL_ENABLE") or "1")
local CHAR = tonumber(os.getenv("HL_CHAR") or "1")
local SIDE = tonumber(os.getenv("HL_SIDE") or "1")
assert(SIDE == 1 or SIDE == 2, "HL_SIDE must be 1 or 2")
local BLOCK = os.getenv("HL_BLOCK") == "1"
local INTERRUPT = os.getenv("HL_INTERRUPT") or "none"
assert(({none=true, terminate=true, disable=true, death=true, state=true, round=true, freeze=true, ["freeze-replace"]=true})[INTERRUPT], "invalid HL_INTERRUPT")
local ROUND = INTERRUPT == "round"
local REPLACE = INTERRUPT == "freeze-replace"
local FREEZE = INTERRUPT == "freeze" or REPLACE
local ATTACKER_CHAR = FREEZE and 8 or CHAR
local LOG = os.getenv("HL_LOG") or (ROOT .. "/tools/hitlight_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[hl] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[n] = tonumber(a, 16)
    end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

local A = {
    gstate = sym("gstate"), curback = sym("curback"), f_death = sym("f_death"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    victim_obj = sym("p" .. SIDE .. "_obj"), attacker_obj = sym("p" .. (3 - SIDE) .. "_obj"),
    victim_proc = sym("p" .. SIDE .. "_proc"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    victim_bar = sym("p" .. SIDE .. "_bar"), attacker_bar = sym("p" .. (3 - SIDE) .. "_bar"),
    palram = sym("palram"), f_hitlight = sym("f_hitlight"),
}
local OPAL, OXVAL = 0x140, 0x080
local PALRSIZ, PALCNT, NUMPAL = 0x40, 0x20, 80
local COLRAM = 0x01800000          -- SYSEQU.ASM colram (T-unit branch)
local SCRATCH_LO, SCRATCH_HI = 0x01000000, 0x02000000
local NCOLS = 64
local GS_PSEL, GS_FIGHTING = 4, 2
local MAXBAR = 0xa1
local MAX_LIT_RUN = 12             -- 1 tick of patience + 5 envelope rows + slack

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Block"] = true, ["P2 High Kick"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] or f.name:match("^P[12] ") then fields[f.name] = f end
        end
    end
end

local function slot_of(objptr)
    local o = r32(objptr)
    if o == 0 then return nil end
    return r16(o + OPAL) & 0xff
end
local function id_of(slot) return r32(A.palram + slot * PALRSIZ) end
local function count_of(slot) return r16(A.palram + slot * PALRSIZ + PALCNT) end
local function colours(slot)
    local t = {}
    for i = 0, NCOLS - 1 do t[i] = r16(COLRAM + ((slot << 8) + i) * 16) end
    return t
end
local function same(a, b)
    for i = 0, NCOLS - 1 do if a[i] ~= b[i] then return false end end
    return true
end
local function is_ram(id) return id >= SCRATCH_LO and id < SCRATCH_HI end

-- Forward-declared: snap() logs each fighter's screen x, and the helper is
-- defined further down with the other diagnostics.  As a plain later local
-- it was a nil GLOBAL inside snap(), which errored after every snapshot and
-- silently dropped the SNAP lines the strip script pairs frames with.
local screen_x

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then
        pcall(function() s:snapshot() end)
        log("SNAP %s frame=%d p1x=%d p2x=%d", label, frame,
            screen_x(SIDE == 1 and A.victim_obj or A.attacker_obj),
            screen_x(SIDE == 1 and A.attacker_obj or A.victim_obj))
    end
end

local S = {
    sharer_pinned = false, shared_slot = nil, shared_id = nil, baseline = nil,
    hits = 0, block_contacts = 0, last_bar = MAXBAR,
    lights = 0, lit = false, lit_slot = nil, lit_ticks = 0, lit_run = 0, max_lit_run = 0,
    tinted_ticks = 0, sharer_changes = 0, same_slot_while_lit = 0,
    unrestored = 0, leaked = 0, pending_release = nil, snapped = false,
    max_private = 0, interrupted = 0, interrupt_at = nil, interrupt_late = 0,
    original_count = nil, original_ref_leaks = 0,
    wrong_owner = 0,
    guard_restore = nil,
    -- diagnostics for WHY a light lasts as long as it does
    cur_procs = nil, cur_vals = nil, cur_nvals = 0, cur_last = nil, cur_frozen = 0,
    multi_proc_lights = 0, logged_lights = 0,
    ncols = NCOLS, cur_first_a11 = nil,
    formula_checked = 0, formula_mismatches = 0, max_palq = nil,
    first_pending_ok = 0, first_bad = 0, prev_sample = nil,
}

-- The light's own processes, found by walking the active list (MPROC.ASM
-- `active`; plink at 0, procid at 20h).  Optional: a map without the symbol
-- just loses this diagnostic, not the verdict.
local ACTIVE = symbols["active"]
local PID_HL = 0x011e + SIDE - 1
local function hitlight_procs()
    local found = {}
    if not ACTIVE then return found end
    local p, guard = r32(ACTIVE), 0
    while p ~= 0 and guard < 200 do
        if r16(p + 0x20) == PID_HL then found[#found + 1] = p end
        p = r32(p); guard = guard + 1
    end
    return found
end
local SAMPLE = 20                  -- one colour index to watch the envelope move

-- MKFX.ASM hl_env, row by row: rm, gm, bm (each /128) and a blue lift.  The
-- rig recomputes every tinted colour from these and the ORIGINAL palette, so
-- "the light is right" is an exact comparison, not an eyeball.
local ENV = { {80,128,176,10}, {72,120,192,12}, {88,124,176,8},
              {104,128,160,5}, {120,128,140,2} }
local function tint(c, row)
    local e = ENV[row]
    local r = math.min(31, (((c >> 10) & 31) * e[1]) >> 7)
    local g = math.min(31, (((c >> 5) & 31) * e[2]) >> 7)
    local b = math.min(31, ((((c & 31) * e[3]) >> 7) + e[4]))
    return (r << 10) | (g << 5) | b
end
local function same_n(a, b, n)
    for i = 0, n - 1 do if a[i] ~= b[i] then return false end end
    return true
end
local function matches_row(cols, base, row, n)
    for i = 0, n - 1 do if cols[i] ~= tint(base[i], row) then return false end end
    return true
end

-- The palette transfer queue (PALL.ASM): 32 cells of 64 bits, one kept empty.
local PQS, PQE = symbols["paltrans_start"], symbols["paltrans_end"]
local function palq_depth()
    if not (PQS and PQE) then return nil end
    return ((r32(PQE) - r32(PQS)) % (32 * 64)) // 64
end
local OXPOS = 0x090
local WORLDTLX = symbols["worldtlx"]
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
screen_x = function(objptr)
    local o = r32(objptr)
    if o == 0 or not WORLDTLX then return -9999 end
    return s16(r16(o + OXPOS)) - s16(r32(WORLDTLX) >> 16)
end

local TEST_START, TEST_LEN = 90, 1600
local R = {trigger=nil, number=nil, ready=nil, reaped=0, cleared=false, reaper_pc=false,
    bad=0, taps={}, armed_proc=nil}
local F = {trigger=nil, proc=nil, taken=nil, samples=0, bad=0, returned=nil,
    proc_bad=0, private_bad=0, id_bad=0, colour_bad=0, reaped=false,
    new_ticks=0, tint_checked=0, first_a11=nil, base={}, ncols=0}
local FROZE_NAMES = {[1]="LKNUFRZ_P",[4]="KTNUFRZ_P",[8]="NJNUFRZ_P"}

local function freeze_finish(ok,reason)
    if finished then return end
    finished=true
    log("RESULT enable=%d side=%d char=%d frozen_samples=%d bad=%d taken=%s returned=%s",
        ENABLE,SIDE,CHAR,F.samples,F.bad,tostring(F.taken),tostring(F.returned))
    log("FREEZE_DIAG proc=%d private=%d id=%d colour=%d original_refs=%d expected_refs=%d",
        F.proc_bad,F.private_bad,F.id_bad,F.colour_bad,count_of(S.shared_slot),S.original_count)
    log("REPLACEMENT mode=%s old_reaped=%s new_ticks=%d tint_checked=%d",
        tostring(REPLACE),tostring(F.reaped),F.new_ticks,F.tint_checked)
    log("%s reason=%s",ok and "PASS" or "FAIL",reason)
    logfh:close();manager.machine:exit()
end

local function freeze_trigger()
    assert(FROZE_NAMES[CHAR],"freeze rig supports victims 1,4,8")
    F.trigger=frame
    local expected=sym(FROZE_NAMES[CHAR])
    F.ncols=math.min(64,r16(expected)&0x1ff)
    for i=0,F.ncols-1 do F.base[i]=r16(expected+16+i*16) end
    if ENABLE~=0 then
        local procs=hitlight_procs();assert(#procs==1,"freeze requires one owned light")
        F.proc=procs[1];assert(r32(F.proc+0x270)==1,"light not armed")
        w16(F.proc+0x30,0x7fff)
        if REPLACE then
            F.tap=space:install_write_tap(F.proc+0x270,F.proc+0x27f,"hl_replace_reap",
                function(offset,data,mask)
                    if not F.reaped and (data & 0xffff)==0 then
                        local pc=manager.machine.devices[":maincpu"].state["PC"].value
                        F.reaped=pc>=sym("hitlight_reap") and pc<sym("hitlight_reap")+0x200
                        log("REPLACEMENT_REAP frame=%d pc=%08x valid=%s",frame,pc,tostring(F.reaped))
                    end
                    return data
                end)
        end
    end
    -- r_ice calls reaction_start_chores, which would kill/reallocate the
    -- old light (often in the same process slot). Suppress NEW lights while
    -- the held one remains armed; otherwise we test a new freeze-hit tint.
    if not REPLACE then w16(A.f_hitlight,0) end
    log("FREEZE_TRIGGER frame=%d sleeper=%08x",frame,F.proc or 0)
end

local function freeze_observe()
    local slot=slot_of(A.victim_obj)
    if not slot then freeze_finish(false,"lost_victim");return end
    local id=id_of(slot)
    local action=r16(r32(A.victim_proc)+0x1f0)
    local expected=sym(FROZE_NAMES[CHAR])
    if not F.taken and action==0x401 and id==expected then
        F.taken=frame
        if ENABLE~=0 and not REPLACE then
            assert(#hitlight_procs()==1 and hitlight_procs()[1]==F.proc,"held light disappeared before takeover")
            assert(r32(F.proc+0x270)==1 and r32(F.proc+0x80)==S.shared_id,"held light ownership context changed")
            w16(F.proc+0x30,1)
        end
        log("FREEZE_TAKEOVER frame=%d palette=%08x",frame,id)
    end
    if F.taken and frame>F.taken then
        local replacing=REPLACE and ENABLE~=0 and id==sym("hl_pal"..SIDE)
        local procs=hitlight_procs()
        if #procs~=(replacing and 1 or 0) then F.bad=F.bad+1;F.proc_bad=F.proc_bad+1 end
        for s=0,NUMPAL-1 do
            if id_of(s)==sym("hl_pal"..SIDE) and count_of(s)>0 and not (replacing and s==slot and count_of(s)==1) then
                F.bad=F.bad+1;F.private_bad=F.private_bad+1
            end
        end
        if action==0x401 then
            F.samples=F.samples+1
            if id~=expected and not replacing then F.bad=F.bad+1;F.id_bad=F.id_bad+1 end
            if replacing then
                F.new_ticks=F.new_ticks+1
                if #procs~=1 or r32(procs[1]+0x80)~=expected or r32(procs[1]+0x270)~=1 then
                    F.bad=F.bad+1;F.proc_bad=F.proc_bad+1
                else
                    local a11=r32(procs[1]+0x60)
                    if not F.first_a11 then F.first_a11=a11 end
                    local k=((a11-F.first_a11)//0x40)+1
                    if F.new_ticks>1 then
                        local cols=colours(slot)
                        local good=false
                        for _,row in ipairs({k,k-1}) do
                            if row>=1 and row<=#ENV then good=good or matches_row(cols,F.base,row,F.ncols) end
                        end
                        F.tint_checked=F.tint_checked+1
                        if not good then F.bad=F.bad+1;F.colour_bad=F.colour_bad+1 end
                    end
                end
            end
            -- Allow one palette-transfer refresh, then require exact stock
            -- freeze colours. The old light must not repaint the new owner.
            if not replacing and frame>F.taken+1 then
                for i=0,(r16(expected)&0x1ff)-1 do
                    if r16(COLRAM+((slot<<8)+i)*16)~=r16(expected+16+i*16) then F.bad=F.bad+1;F.colour_bad=F.colour_bad+1 end
                end
            end
        elseif not F.returned and id==S.shared_id then
            F.returned=frame;log("FREEZE_RETURN frame=%d palette=%08x",frame,id)
        end
        if F.returned and frame-F.returned>=60 then
            local refs_ok=count_of(S.shared_slot)==S.original_count
            local replacement_ok=not (REPLACE and ENABLE~=0) or (F.reaped and F.new_ticks==5 and F.tint_checked==4)
            freeze_finish(F.samples>=60 and F.bad==0 and refs_ok and id==S.shared_id and replacement_ok,"freeze_takeover_and_restore")
            return
        end
    end
    if frame-F.trigger>600 then freeze_finish(false,"freeze_takeover_timeout") end
end

local function round_finish(ok, reason)
    if finished then return end
    finished = true
    log("RESULT enable=%d side=%d char=%d round_reaped=%d cleared_before_reap=%s reaper_pc=%s bad=%d next_round=%s",
        ENABLE,SIDE,CHAR,R.reaped,tostring(R.cleared),tostring(R.reaper_pc),R.bad,tostring(R.ready))
    local maps = {}
    for slot=0,NUMPAL-1 do
        if count_of(slot)>0 then maps[#maps+1]=string.format("%08x:%d",id_of(slot),count_of(slot)) end
    end
    table.sort(maps)
    log("ROUND_MAPS %s",table.concat(maps,","))
    log("%s reason=%s",ok and "PASS" or "FAIL",reason)
    logfh:close(); manager.machine:exit()
end

local function round_trigger()
    R.trigger=frame; R.number=r16(sym("round_num"))
    if ENABLE ~= 0 then
        local procs=hitlight_procs()
        assert(#procs==1,"round test requires one owned sleeper")
        local p=procs[1]; R.armed_proc=p
        assert(r32(p+0x270)==1,"round sleeper not armed")
        -- Keep ownership live until the real scheduler sweep. No direct call
        -- to oinit, clrpal, murder, kilall or hitlight_reap is injected.
        w16(p+0x30,0x7fff)
        R.taps[#R.taps+1]=space:install_write_tap(p+0x270,p+0x27f,"hl_round_reap",
            function(offset,data,mask)
                if R.reaped==0 and (data & 0xffff)==0 then
                    R.reaped=1
                    local pc=manager.machine.devices[":maincpu"].state["PC"].value
                    -- The marker clear is in the first 64 bytes of the
                    -- reaper. Local hlr_* labels are not exported in the map.
                    R.reaper_pc=pc>=sym("hitlight_reap") and pc<sym("hitlight_reap")+0x200
                    local private_live=false
                    for slot=0,NUMPAL-1 do
                        if id_of(slot)==sym("hl_pal"..SIDE) and count_of(slot)>0 then private_live=true end
                    end
                    R.cleared=r32(A.victim_obj)==0 and r32(A.attacker_obj)==0 and not private_live
                    log("ROUND_REAP frame=%d pc=%08x objects=%08x,%08x private_live=%s cleared=%s",
                        frame,pc,r32(A.victim_obj),r32(A.attacker_obj),tostring(private_live),tostring(R.cleared))
                end
                return data
            end)
    end
    w16(A.victim_bar,0)
    log("ROUND_TRIGGER frame=%d round=%d sleeper=%08x",frame,R.number,R.armed_proc or 0)
end

local function round_observe()
    if frame-R.trigger>2500 then round_finish(false,"round_transition_timeout");return end
    if r16(sym("round_num"))>R.number and r16(A.gstate)==GS_FIGHTING
        and r32(A.victim_obj)~=0 and r32(A.attacker_obj)~=0 then
        if not R.ready then R.ready=frame;log("ROUND_READY frame=%d round=%d",frame,r16(sym("round_num"))) end
        if frame-R.ready>=60 then
            local private=0
            for slot=0,NUMPAL-1 do
                if is_ram(id_of(slot)) and count_of(slot)>0 then private=private+1 end
            end
            if private~=0 or #hitlight_procs()~=0 then R.bad=R.bad+1 end
            for _,obj in ipairs({A.victim_obj,A.attacker_obj}) do
                local slot=slot_of(obj)
                if not slot or is_ram(id_of(slot)) or count_of(slot)==0 then R.bad=R.bad+1 end
            end
        end
        if frame-R.ready>=240 then
            round_finish(R.bad==0 and (ENABLE==0 or (R.reaped==1 and R.cleared and R.reaper_pc)),"round_teardown_and_reallocation")
        end
    end
end

local function finish()
    if finished then return end
    finished = true
    log("OWNER victim=P%d attacker=P%d wrong_owner=%d", SIDE, 3 - SIDE, S.wrong_owner)
    log("RESULT enable=%d char=%d sharer_pinned=%s hits=%d lights=%d lit_ticks=%d " ..
        "max_lit_run=%d tinted_ticks=%d sharer_changes=%d same_slot_while_lit=%d " ..
        "unrestored=%d leaked=%d max_private=%d",
        ENABLE, CHAR, tostring(S.sharer_pinned), S.hits, S.lights, S.lit_ticks,
        S.max_lit_run, S.tinted_ticks, S.sharer_changes, S.same_slot_while_lit,
        S.unrestored, S.leaked, S.max_private)
    log("DIAG active_list=%s multi_proc_lights=%d formula_checked=%d formula_mismatches=%d " ..
        "first_pending_ok=%d first_bad=%d max_palq_depth=%s ncols=%d",
        tostring(ACTIVE ~= nil), S.multi_proc_lights, S.formula_checked,
        S.formula_mismatches, S.first_pending_ok, S.first_bad, tostring(S.max_palq), S.ncols)
    local ok
    log("GUARD block=%s contacts_in_block_action=%d",tostring(BLOCK),S.block_contacts)
    log("INTERRUPT mode=%s count=%d late_restores=%d",INTERRUPT,S.interrupted,S.interrupt_late)
    log("REFERENCES original_ref_leaks=%d",S.original_ref_leaks)
    if BLOCK then
        ok = S.sharer_pinned and S.hits >= 3 and S.block_contacts == S.hits
             and S.lights == 0 and S.max_private == 0
        log("%s reason=%s",ok and "PASS" or "FAIL",
            ok and "blocked_contacts_no_hitlight" or "see_RESULT")
    elseif ENABLE ~= 0 then
        ok = S.sharer_pinned and S.hits >= 3 and S.lights >= 3 and S.tinted_ticks > 0
             and S.max_lit_run <= MAX_LIT_RUN
             and S.formula_checked > 0 and S.formula_mismatches == 0
             and S.first_pending_ok > 0 and S.first_bad == 0
             and S.max_palq ~= nil and S.max_palq <= 8
             and S.sharer_changes == 0 and S.same_slot_while_lit == 0
             and S.unrestored == 0 and S.leaked == 0
             and S.original_ref_leaks == 0
             and S.wrong_owner == 0
        if INTERRUPT ~= "none" then
            ok = ok and S.interrupted >= 3 and S.interrupt_late == 0
        end
        log("%s reason=%s", ok and "PASS" or "FAIL",
            ok and "lit_only_the_struck_fighter" or "see_RESULT")
    else
        ok = S.sharer_pinned and S.hits >= 3 and S.lights == 0 and S.max_private == 0
        log("%s reason=%s", ok and "PASS" or "FAIL",
            ok and "control_no_private_map" or "see_RESULT")
    end
    logfh:close()
    manager.machine:exit()
end

local function pressed(name)
    if R.trigger then return false end
    if F.trigger then
        -- Attacker remains left of the victim; down, forward, LP after
        -- recovering from the punch. Input edges fit the stock 0x10 window.
        local t=frame-F.trigger
        local prefix="P"..(3-SIDE).." "
        if name==prefix.."Down" then return t>=40 and t<43 end
        if name==prefix.."Right" then return t>=44 and t<47 end
        if name==prefix.."Low Punch" then return t>=48 and t<51 end
        return false
    end
    if fighting_frame > 0 then
        if BLOCK and name == "P" .. SIDE .. " Block" then return true end
        if name == "P" .. (3 - SIDE) .. (BLOCK and " High Kick" or " High Punch") then
            local rel = frame - fighting_frame
            return rel >= TEST_START and ((rel - TEST_START) % 30) < 4
        end
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

local function measure(rel)
    local s1 = slot_of(A.victim_obj)
    if not (s1 and S.baseline) then return end
    local id1 = id_of(s1)
    if not is_ram(id1) and S.original_count and count_of(S.shared_slot) ~= S.original_count then
        S.original_ref_leaks = S.original_ref_leaks + 1
    end
    if S.interrupt_at and rel > S.interrupt_at then
        -- Restore the injected round guard after exactly one sampled refresh,
        -- even on failure. This tests hl_live, not full round teardown.
        if S.guard_restore then
            w16(S.guard_restore.addr, S.guard_restore.value)
            S.guard_restore = nil
        end
        if is_ram(id1) then S.interrupt_late = S.interrupt_late + 1 end
        if not is_ram(id1) then
            S.interrupt_at = nil
            if INTERRUPT == "disable" then w16(A.f_hitlight, ENABLE) end
        end
    end

    local private = 0
    for s = 0, NUMPAL - 1 do
        if is_ram(id_of(s)) and count_of(s) > 0 then private = private + 1 end
    end
    if private > S.max_private then S.max_private = private end

    if is_ram(id1) then
        if id1 ~= sym("hl_pal" .. SIDE) or #hitlight_procs() ~= 1 then
            S.wrong_owner = S.wrong_owner + 1
        end
        S.lit_ticks = S.lit_ticks + 1
        S.lit_run = S.lit_run + 1
        if S.lit_run > S.max_lit_run then S.max_lit_run = S.lit_run end
        if S.lit_run == MAX_LIT_RUN + 1 then
            log("STUCK at rel=%d: victim on private id 0x%08x for %d refreshes", rel, id1, S.lit_run)
        end
        if not S.lit then
            S.lit, S.lit_slot = true, s1
            S.lights = S.lights + 1
            S.cur_procs, S.cur_vals, S.cur_nvals, S.cur_last, S.cur_frozen = {}, {}, 0, nil, 0
            S.cur_start = rel
            S.cur_first_a11 = nil
        end
        if s1 == S.shared_slot then S.same_slot_while_lit = S.same_slot_while_lit + 1 end
        -- THE sharer check: the original map, still held by the pinned owner
        if not same(colours(S.shared_slot), S.baseline) then
            S.sharer_changes = S.sharer_changes + 1
            if S.sharer_changes <= 5 then log("SHARER CHANGED at rel=%d (map %d)", rel, S.shared_slot) end
        end
        local mine = colours(s1)
        if not same(mine, S.baseline) then
            S.tinted_ticks = S.tinted_ticks + 1
        end
        -- the light's process: its saved a11 (pa11 = 60h) IS the envelope
        -- pointer, and its sleep count sits at 30h
        local pa11 = nil
        for _, p in ipairs(hitlight_procs()) do
            S.cur_procs[p] = true
            pa11 = r32(p + 0x60)
            if S.logged_lights < 3 and pa11 ~= S.cur_a11 then
                S.cur_a11 = pa11
                S.cur_trace = (S.cur_trace or "") ..
                    string.format(" %d:%08x/s%d", rel, pa11, r16(p + 0x30))
            end
        end
        -- EXACT colours.  The process has just written row k (the first lit
        -- tick is row 1, and pa11 has already stepped past it); a palset lands
        -- on the NEXT vblank, so row k-1 is also right.  Row 0 is the untinted
        -- copy getfpal loads when he first moves onto the private map.
        if pa11 then
            if not S.cur_first_a11 then S.cur_first_a11 = pa11 end
            local k = ((pa11 - S.cur_first_a11) // 0x40) + 1
            if k == 1 then
                -- FIRST lit tick.  getfpal's copy and row 1 were both only
                -- QUEUED this tick; they land on the next vblank, while opal
                -- already names the new map.  So the map must still hold
                -- EXACTLY what it held a tick ago - pending, not wrong.  Anything
                -- else would mean something wrote it early, and that fails.
                local prev = S.prev_sample and S.prev_sample[s1]
                if prev ~= nil and mine[SAMPLE] == prev then
                    S.first_pending_ok = S.first_pending_ok + 1
                else
                    S.first_bad = S.first_bad + 1
                    if S.first_bad <= 5 then
                        log("FIRST TICK NOT PENDING at rel=%d: colour %d is %04x, a tick ago %s",
                            rel, SAMPLE, mine[SAMPLE],
                            prev and string.format("%04x", prev) or "unknown")
                    end
                end
            else
                -- Row k was just written and row k-1 is the one that has
                -- landed; both are exact values, recomputed from the original.
                local good = false
                for _, row in ipairs({ k, k - 1 }) do
                    if row >= 1 and row <= #ENV then
                        good = good or matches_row(mine, S.baseline, row, S.ncols)
                    end
                end
                S.formula_checked = S.formula_checked + 1
                if not good then
                    S.formula_mismatches = S.formula_mismatches + 1
                    if S.formula_mismatches <= 5 then
                        local kk = math.max(1, math.min(k, #ENV))
                        log("TINT MISMATCH at rel=%d row=%d: colour %d is %04x, row %d says %04x",
                            rel, k, SAMPLE, mine[SAMPLE], kk, tint(S.baseline[SAMPLE], kk))
                    end
                end
            end
        end
        local d = palq_depth()
        if d and (S.max_palq == nil or d > S.max_palq) then S.max_palq = d end
        local v = mine[SAMPLE]
        if not S.cur_vals[v] then S.cur_vals[v] = true; S.cur_nvals = S.cur_nvals + 1 end
        if v == S.cur_last then S.cur_frozen = S.cur_frozen + 1 else S.cur_frozen = 0 end
        S.cur_last = v
    else
        local ended_len = S.lit_run
        S.lit_run = 0
        if S.lit then
            local nprocs = 0
            for _ in pairs(S.cur_procs) do nprocs = nprocs + 1 end
            if nprocs > 1 then S.multi_proc_lights = S.multi_proc_lights + 1 end
            if S.logged_lights < 8 then
                S.logged_lights = S.logged_lights + 1
                log("LIGHT %d rel=%d..%d len=%d procs=%d distinct_tints=%d frozen_tail=%d",
                    S.lights, S.cur_start, rel - 1, ended_len, nprocs, S.cur_nvals, S.cur_frozen)
                if S.cur_trace then log("   a11 trace (rel:pa11/sleep):%s", S.cur_trace) end
            end
            S.cur_trace, S.cur_a11 = nil, nil
            S.lit = false
            if id1 ~= S.shared_id then
                S.unrestored = S.unrestored + 1
                log("NOT RESTORED at rel=%d: victim id 0x%08x (expected 0x%08x)", rel, id1, S.shared_id)
            end
            S.pending_release = { slot = S.lit_slot, at = rel }
        end
    end
    if S.pending_release and rel > S.pending_release.at + 1 then
        local ps = S.pending_release.slot
        if is_ram(id_of(ps)) and count_of(ps) > 0 and ps ~= s1 then
            S.leaked = S.leaked + 1
            log("LEAK at rel=%d: map %d count %d", rel, ps, count_of(ps))
        end
        S.pending_release = nil
    end
    -- one colour of every map, so the next tick can tell "pending" from "wrong"
    local cache = {}
    for s = 0, NUMPAL - 1 do cache[s] = r16(COLRAM + ((s << 8) + SAMPLE) * 16) end
    S.prev_sample = cache
    if not ROUND and not FREEZE and ENABLE ~= 0 and INTERRUPT ~= "none" and S.lit_run == 2 and not S.interrupt_at then
        if INTERRUPT == "terminate" then
            local procs = hitlight_procs()
            assert(#procs == 1, "expected exactly one light to terminate")
            -- Bypass hlp_done: dispatch directly to the scheduler's terminal
            -- path, retaining the sleeper's saved ownership context.
            w32(procs[1] + 0xe0, sym("sucide"))
        elseif INTERRUPT == "disable" then
            w16(A.f_hitlight, 0)
        else
            local addr = INTERRUPT == "death" and A.f_death or A.gstate
            local value = r16(addr)
            assert(value == (INTERRUPT == "death" and 0 or GS_FIGHTING), "round guard already active")
            S.guard_restore = {addr=addr, value=value}
            -- 1 = gs_amode, a defined non-fighting state; no transition code
            -- is invoked by the rig. Both guards are restored above.
            w16(addr, 1)
        end
        S.interrupted = S.interrupted + 1
        S.interrupt_at = rel
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded enable=%d char=%d victim=P%d", ENABLE, CHAR, SIDE)
    end
    if not space or finished then return end
    if F.trigger then
        freeze_observe()
        if not finished then
            for name,f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end
        end
        return
    end
    if R.trigger then
        for _,f in pairs(fields) do f:set_value(0) end
        round_observe()
        return
    end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, SIDE==1 and CHAR or ATTACKER_CHAR)
        w16(A.p2_char, SIDE==2 and CHAR or ATTACKER_CHAR)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, 0) end
    if frame > 9000 and fighting_frame == 0 then log("never reached the fight"); finish(); return end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if rel == 30 then
            log("PLAYERS states=%d,%d characters=%d,%d",r16(A.p1_state),r16(A.p2_state),
                r16(r32(A.victim_obj)+0x1f0),r16(r32(A.attacker_obj)+0x1f0))
            assert(r16(A.p1_state)==1 and r16(A.p2_state)==1,"test requires two human players")
            assert(r16(r32(A.victim_obj)+0x1f0)==CHAR and r16(r32(A.attacker_obj)+0x1f0)==ATTACKER_CHAR,"wrong selected fighters")
            w16(A.f_hitlight, ENABLE)
            local s1, s2 = slot_of(A.victim_obj), slot_of(A.attacker_obj)
            if s1 then
                local cnt = count_of(s1)
                w16(A.palram + s1 * PALRSIZ + PALCNT, cnt + 1)   -- the synthetic second owner
                S.sharer_pinned = (count_of(s1) == cnt + 1)
                S.original_count = cnt + 1
                S.shared_slot, S.shared_id = s1, id_of(s1)
                S.baseline = colours(s1)
                -- only the palette's own colours are copied (hl_maxcols caps it)
                S.ncols = math.min(NCOLS, r16(S.shared_id) & 0x1ff)
            end
            log("start: victim map %s (id 0x%08x, count now %d)  attacker map %s  sharer_pinned=%s",
                tostring(s1), S.shared_id or 0, s1 and count_of(s1) or -1,
                tostring(s2), tostring(S.sharer_pinned))
        end
        if rel >= TEST_START then
            local o1, o2 = r32(A.victim_obj), r32(A.attacker_obj)
            if o1 ~= 0 and o2 ~= 0 then
                w32(o1 + OXVAL, (560 & 0xffff) << 16)
                w32(o2 + OXVAL, (500 & 0xffff) << 16)
            end
            w16(A.attacker_bar, MAXBAR)
            local bar = r16(A.victim_bar)
            if bar < S.last_bar then
                S.hits = S.hits + 1
                local proc = r32(A.victim_proc)
                local action = proc ~= 0 and r16(proc + 0x1f0) or -1
                if action == 0x700 or action == 0x701 then
                    S.block_contacts = S.block_contacts + 1
                end
            end
            if bar < 60 then w16(A.victim_bar, MAXBAR); bar = MAXBAR end
            S.last_bar = bar
            -- every refresh across light 1 (lit at 131..135), one either side:
            -- the displayed frames are the evidence for the pending first tick
            if rel >= 129 and rel <= 138 then snap(string.format("rel%d", rel)) end
            measure(rel)
            if FREEZE and ((ENABLE~=0 and S.lights>=3 and S.lit_run==2) or (ENABLE==0 and rel>=200)) then
                freeze_trigger()
            end
            if ROUND and ((ENABLE~=0 and S.lights>=3 and S.lit_run==2) or (ENABLE==0 and rel>=200)) then
                round_trigger()
            end
            if rel >= TEST_START + TEST_LEN then finish(); return end
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
