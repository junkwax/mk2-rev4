-- lk_dragonflame_fatality_test.lua
--
-- Drives Liu Kang's new red-dragon flame fatality (do_lk_dragonflame,
-- MKDEATH.ASM) during FINISH HIM and checks it plays its authored frames,
-- draws only art that actually exists in the expected tables, and ends the
-- round cleanly.
--
-- Trigger: bare BLOCK press (no combo, no motion) from SWEEP distance, same
-- shape as Scorpion's bare-HP MK1 scortch remap.  Flow:
--   1. Direct-select P1 Liu Kang (ft_kang=1) vs P2 Jax (ft_jax=11).
--   2. Force FINISH HIM the way the game does (drain + let it declare).
--   3. Snap P1 to sweep range (~180px, inside the 0xc8=200 gate but well
--      outside do_dragon's own 0x70=112 close-range gate).
--   4. Hold P1 Block until f_death == FATAL_NUM (12).
--   5. Watch every frame: unknown-SAG / lockup / hang detectors, snapshots
--      at the morph, the burn, and the return-to-kang.
--
-- Env knobs:
--   LKDF_LOG=path        log path
--   LKDF_OBSERVE=N       frames to keep watching after f_death clears (default 180)
--   LKDF_HANG=N          frames the fatality may stay live before it's a hang (default 900)

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("LKDF_LOG") or (ROOT .. "/tools/lk_dragonflame_fatality_test.log")
local OBSERVE = getenv_int("LKDF_OBSERVE", 180)
local HANG_LIMIT = getenv_int("LKDF_HANG", 900)

local logfh = io.open(LOG_PATH, "w")
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
    print("[lkdf] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end
local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end
local function s16(v)
    v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

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
        log("WARN no linker map found")
    end
end
local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s", name)
    return fallback or 0
end

local A = {
    active        = sym("active"),
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),      p2_state = sym("p2_state"),
    p1_char       = sym("p1_char"),       p2_char  = sym("p2_char"),
    p1_obj        = sym("p1_obj"),        p2_obj   = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),       p2_proc  = sym("p2_proc"),
    p1_bar        = sym("p1_bar"),        p2_bar   = sym("p2_bar"),
    curback       = sym("curback"),
    winner_status = sym("winner_status"),
    f_death       = sym("f_death"),
    objlst        = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    worldtlx      = sym("worldtlx"),
    dizzy_dude    = sym("dizzy_dude"),
    dizzy         = sym("dizzy"),
    system_lockup = sym("system_lockup"),
    tvbp          = sym("TVBP"),
    do_lk_dragonflame = sym("do_lk_dragonflame"),
    a_lkdragonflame   = sym("a_lkdragonflame"),
}

local O = {
    next = 0x000, oxval = 0x080, oxpos = 0x090, oyval = 0x0a0, oypos = 0x0b0,
    oflags = 0x0f0, osag = 0x100, oflags2 = 0x160, oimg = 0x1a0,
    oid = 0x1c0, oshape = 0x1d0, ochar = 0x1f0,
}
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KANG, FT_JAX = 1, 11
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local M_REPALT4_PAL = 0x0400   -- oflags2: the Start+LK alternate costume,
                               -- which the fatality is now gated on
local STAGE_ID = 5           -- Armory: no stage fatality to confuse the input
local SNAP_X = getenv_int("LKDF_SNAP_X", 180)   -- gate is 0xc8=200; do_dragon's is 0x70=112
local FATAL_NUM = 12         -- init_death_blow a1 for do_lk_dragonflame

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, fight_count = 0, 0, 0
local p1_confirm_start, did_direct_select = 0, false
local finish_forced_frame, victim_dizzy_forced = 0, false
local hold_start_frame = 0
local fatal_frame, fatal_end_frame = 0, 0
local finished = false
local snap_index = 0
local baseline_obj_count = 0
local body_seq, fx_seq = {}, {}
local last_body, last_fx = nil, nil
local unknown_hits = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

--------------------------------------------------------------------------
-- SAG -> label maps, straight out of the source art tables.
--------------------------------------------------------------------------
local function load_sags(path, into)
    local fh = io.open(path, "r")
    if not fh then log("WARN cannot open %s", path); return 0 end
    local n, current = 0, nil
    for line in fh:lines() do
        local label = line:match("^([%w_]+):") or line:match("^([%w_]+)%s*$")
        if label then current = label end
        if current then
            local raw = line:match("%.long%s+0?x?([%x]+)[Hh]")
            if raw then
                local sag = tonumber(raw, 16)
                if into[sag] == nil then into[sag] = current end
                sag = sag & 0x00ffffff
                if into[sag] == nil then into[sag] = current end
                current = nil
                n = n + 1
            end
        end
    end
    fh:close()
    return n
end

-- Everything Liu Kang's own player object may legally point at (dragon +
-- normal art).
local lk_sags = {}
-- Everything the flame / skeleton overlay may legally point at.
local fx_sags = {}
-- Whole-tree map so any surprise object can still be named.
local all_sags = {}

do
    local body_files = { "MKLK.TBL", "MKLK2.TBL", "MKLK3.TBL", "MKLK.ASM",
                         "MKFATAL.TBL", "MKFALL.TBL", "MKGUYS.ASM" }
    local parts = {}
    for _, f in ipairs(body_files) do
        parts[#parts + 1] = string.format("%s=%d", f, load_sags(ROOT .. "/src/" .. f, lk_sags))
    end
    local nf1 = load_sags(ROOT .. "/src/MKFX.ASM", fx_sags)
    local nf2 = load_sags(ROOT .. "/src/MK1SKULL.TBL", fx_sags)
    local nf3 = load_sags(ROOT .. "/src/ROBOFIRE.TBL", fx_sags)
    log("body SAGs: %s | fx SAGs: MKFX.ASM=%d MK1SKULL.TBL=%d ROBOFIRE.TBL=%d", table.concat(parts, " "), nf1, nf2, nf3)

    local total = 0
    local lfs_ok, dirlist = pcall(function()
        local t, p = {}, io.popen('dir /b "' .. ROOT:gsub("/", "\\") .. '\\src\\*.TBL"')
        if p then for l in p:lines() do t[#t + 1] = l end p:close() end
        return t
    end)
    if lfs_ok and dirlist then
        for _, f in ipairs(dirlist) do
            total = total + load_sags(ROOT .. "/src/" .. f, all_sags)
        end
    end
    log("all-tree SAGs: %d records from %d TBLs", total, dirlist and #dirlist or 0)
end

local function obj_label(obj, tbl)
    if obj == 0 then return nil, 0 end
    local cands = { r32(obj + O.osag) }
    local img = r32(obj + O.oimg)
    if img ~= 0 then cands[#cands + 1] = r32(img) end
    for _, raw in ipairs(cands) do
        local lab = tbl[raw] or tbl[raw & 0x00ffffff]
        if lab then return lab, raw end
    end
    return nil, cands[#cands]
end

local function walk(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if list ~= 0 then
            local obj, guard, seen = r32(list), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then return "cycle" end
                seen[obj] = true
                fn(obj)
                obj = r32(obj + O.next)
                guard = guard + 1
            end
        end
    end
    return nil
end

local function object_count()
    local n = 0
    local err = walk(function() n = n + 1 end)
    return n, err
end

local function count_procs()
    local p, n, guard, seen = r32(A.active), 0, 0, {}
    while p ~= 0 and guard < 400 do
        if seen[p] then return n, true end
        seen[p] = true
        n = n + 1
        p = r32(p + P.next)
        guard = guard + 1
    end
    return n, false
end

-- The flame column / skeleton is a separate multipart object.  Find it by
-- matching its SAG against the fx family (and excluding the two players).
local function find_fx()
    local found, fsag = nil, 0
    walk(function(obj)
        if found then return end
        if obj == r32(A.p1_obj) or obj == r32(A.p2_obj) then return end
        local lab, sag = obj_label(obj, fx_sags)
        if lab then found, fsag = lab, sag end
    end)
    return found, fsag
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function on_display(target)
    local hit = false
    walk(function(obj) if obj == target then hit = true end end)
    return hit
end

local function state_line(tag)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local flab = select(1, find_fx())
    local llab = select(1, obj_label(p1o, lk_sags))
    local vlab, vsag = obj_label(p2o, all_sags)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1o ~= 0 then p1x, p1y = s16(r16(p1o + O.oxpos)), s16(r16(p1o + O.oypos)) end
    if p2o ~= 0 then p2x, p2y = s16(r16(p2o + O.oxpos)), s16(r16(p2o + O.oypos)) end
    local nobj, oerr = object_count()
    local nproc, pcyc = count_procs()
    return string.format(
        "%s gs=%d ws=%d fdeath=%d cam=%d p1act=0x%04x p1hp=%d p2hp=%d p1=(%d,%d) p2=(%d,%d) dx=%d vflip=%d body=%s fx=%s vic=%s%s objs=%d%s procs=%d%s",
        tag, r16(A.gstate), r16(A.winner_status), s16(r16(A.f_death)),
        (A.worldtlx ~= 0) and s16(r16(A.worldtlx + 16)) or -1,
        p1_action(),
        r16(A.p1_bar), r16(A.p2_bar), p1x, p1y, p2x, p2y,
        math.abs(p2x - p1x),
        (p2o ~= 0) and ((r16(p2o + O.oflags) & 0x10) ~= 0 and 1 or 0) or -1,
        llab or ("?" .. hx(select(2, obj_label(p1o, lk_sags)))),
        flab or "-",
        vlab or ("?" .. hx(vsag)),
        (p2o ~= 0 and on_display(p2o)) and "" or "[OFFLIST]",
        nobj, oerr and ("!" .. oerr) or "", nproc, pcyc and "!cycle" or "")
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s", snap_index, frame, label, tostring(ok))
    snap_index = snap_index + 1
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_ok" or ("final_" .. reason))
    log("body frames seen: %s", table.concat(body_seq, ","))
    log("fx frames seen: %s", table.concat(fx_seq, ","))
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", reason, state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function cpu_pc()
    if not cpu then return nil end
    for _, name in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, item = pcall(function() return cpu.state[name] end)
        if ok and item then
            local okv, v = pcall(function() return item.value end)
            if okv then return v end
        end
    end
    return nil
end

local function detect_corruption()
    local pc = cpu_pc()
    if pc and A.system_lockup ~= 0 and A.tvbp ~= 0
        and pc >= A.system_lockup and pc < A.tvbp then
        return "lockup_pc_" .. hx(pc)
    end
    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then return string.format("bad_gstate_0x%04x", gs) end
    local nobj, oerr = object_count()
    if oerr then return "objlist_" .. oerr end
    if nobj > 220 then return "object_explosion_" .. nobj end
    local _, pcyc = count_procs()
    if pcyc then return "active_proc_cycle" end
    return nil
end

--------------------------------------------------------------------------
-- Setup / input
--------------------------------------------------------------------------
local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Block"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-16s MISSING", name); ok = false end
    end
    return ok
end

local function force_select()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Kang(%d) P2=Jax(%d) stage=%d", FT_KANG, FT_JAX, STAGE_ID)
    end
end

local function fighters_ok()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return false end
    return r16(p1o + O.ochar) == FT_KANG and r16(p2o + O.ochar) == FT_JAX
end

local snap_range   -- forward declaration: force_finish_him below calls it

-- Reach FINISH HIM the way the game does: drain the victim and let the round
-- logic declare it.  fatality_xfer requires the victim's process parked in
-- dizzy, which only really happens via the normal KO -> finish-him path.
local function force_finish_him()
    if fatal_frame ~= 0 then return end
    if not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 120 then return end
    if fight_count < 2 then
        if r16(A.p2_bar) > 0 then
            w16(A.p2_bar, 0)
            log("round1_ko frame=%d | %s", frame, state_line("ko1"))
        end
        return
    end
    if not victim_dizzy_forced then
        -- Snap the range BEFORE draining him, not after.  dizzy_dude's first
        -- act is face_opponent, and that is the ONLY thing that turns the
        -- victim around; snapping once he is already dizzy leaves him facing
        -- the way he happened to be and quietly tests one geometry twice.
        snap_range()
        -- The fatality only exists on the Start+LK costume (lk_block,
        -- MOVES.ASM), so put Kang in it.  Selecting it for real means
        -- holding Start and pressing LK on the select screen; the flag is
        -- what the move actually reads, so setting it here tests the same
        -- path without depending on select-screen timing.
        local p1o = r32(A.p1_obj)
        if p1o ~= 0 and getenv_int("LKDF_NO_COSTUME", 0) == 0 then
            w16(p1o + O.oflags2, r16(p1o + O.oflags2) | M_REPALT4_PAL)
            log("start+lk costume flag set on P1 (oflags2=0x%04x)",
                r16(p1o + O.oflags2))
        end
        w16(A.p2_bar, 0)
        victim_dizzy_forced = true
        log("drained_p2 frame=%d | %s", frame, state_line("kill"))
    end
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then
        w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    if finish_forced_frame == 0 and r16(A.winner_status) == 3 then
        finish_forced_frame = frame
        baseline_obj_count = select(1, object_count())
        log("finish_him frame=%d objs=%d | %s", frame, baseline_obj_count, state_line("ff"))
        snap("finish_him")
    end
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return A.dizzy ~= 0 and wake >= A.dizzy and wake < (A.dizzy + 0x120)
end

function snap_range()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local p2x = r16(p2o + O.oxpos)
    local x = p2x - SNAP_X
    w16(p1o + O.oxpos, x)
    w32(p1o + O.oxval, (x << 16) & 0xffffffff)
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
    if hold_start_frame > 0 and fatal_frame == 0 and fighting_frame > 0 then
        if name == "P1 Block" then return true end
    end
    return false
end

--------------------------------------------------------------------------
local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("Liu Kang bare-BLOCK red dragon flame fatality probe; observe=%d hang=%d do_lk_dragonflame=%s a_lkdragonflame=%s",
            OBSERVE, HANG_LIMIT, hx(A.do_lk_dragonflame), hx(A.a_lkdragonflame))
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d | %s", frame, fight_count, state_line("fs"))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        force_select()
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_KANG and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    if fatal_frame == 0 then
        force_finish_him()
        if hold_start_frame == 0 and finish_forced_frame > 0 and victim_ready() then
            hold_start_frame = frame
            snap_range()
            log("hold_start frame=%d | %s", frame, state_line("hs"))
        end
        if hold_start_frame > 0 then
            -- Hold the finish-him window open the whole time we wait.
            if r16(A.winner_status) ~= 3 then w16(A.winner_status, 3) end
            if (frame - hold_start_frame) % 60 == 0 then
                snap_range()
                log("holding frame=%d rel=%d | %s", frame, frame - hold_start_frame, state_line("hold"))
            end
        end
        if s16(r16(A.f_death)) == FATAL_NUM then
            fatal_frame = frame
            log("FATALITY STARTED frame=%d | %s", frame, state_line("go"))
            snap("fatality_start")
        end
        if hold_start_frame > 0 and frame - hold_start_frame > 600 then
            finish(false, "fatality_never_triggered"); return
        end
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    -- ---- fatality is live: watch it ----
    for name, field in pairs(fields) do field:set_value(0) end

    local rel = frame - fatal_frame

    local bad = detect_corruption()
    if bad then finish(false, bad .. "_at_rel_" .. rel); return end

    local p1o = r32(A.p1_obj)
    local llab, lsag = obj_label(p1o, lk_sags)
    if llab ~= last_body then
        body_seq[#body_seq + 1] = llab or ("?" .. hx(lsag))
        last_body = llab
    end
    local flab, fsag = find_fx()
    if flab ~= last_fx then
        if flab then fx_seq[#fx_seq + 1] = flab end
        last_fx = flab
    end

    if fatal_end_frame == 0 and llab == nil and p1o ~= 0 then
        unknown_hits = unknown_hits + 1
        if unknown_hits == 1 then
            log("UNKNOWN body SAG %s at rel=%d | %s", hx(lsag), rel, state_line("bad"))
            snap("unknown_body_sag")
        end
        if unknown_hits > 3 then
            finish(false, string.format("body_off_table_sag_%s_rel_%d", hx(lsag), rel))
            return
        end
    end

    if rel <= 40 or rel % 15 == 0 then log("rel=%-4d | %s", rel, state_line("obs")) end
    local dense_lo = getenv_int("LKDF_DENSE_LO", -1)
    local dense_hi = getenv_int("LKDF_DENSE_HI", -1)
    local dense_step = getenv_int("LKDF_DENSE_STEP", 3)
    if dense_lo >= 0 and rel >= dense_lo and rel <= dense_hi and (rel - dense_lo) % dense_step == 0 then
        snap(string.format("d_%03d", rel))
    elseif rel == 1 or rel == 30 or rel == 60 or rel == 90 or rel == 130 or rel == 180 or rel == 230 or rel == 280 then
        snap(string.format("fat_%03d", rel))
    end

    if fatal_end_frame == 0 and s16(r16(A.f_death)) ~= FATAL_NUM then
        fatal_end_frame = frame
        log("death_blow_complete frame=%d rel=%d | %s", frame, rel, state_line("done"))
        snap("fatality_complete")
    end

    if fatal_end_frame == 0 and rel > HANG_LIMIT then
        finish(false, "fatality_hung_rel_" .. rel)
        return
    end

    if fatal_end_frame > 0 and frame - fatal_end_frame >= OBSERVE then
        if unknown_hits > 0 then
            finish(false, "off_table_frames_" .. unknown_hits)
        else
            finish(true, string.format("completed_in_%d_frames_body=%d_fx=%d",
                fatal_end_frame - fatal_frame, #body_seq, #fx_seq))
        end
        return
    end

    if frame > 12000 then finish(false, "global_timeout"); return end
end

emu.register_frame(function()
    if finished then return end
    local ok, err = pcall(on_frame)
    if not ok then
        log("LUA ERROR frame=%d: %s", frame, tostring(err))
        finish(false, "harness_lua_error")
    end
end)
