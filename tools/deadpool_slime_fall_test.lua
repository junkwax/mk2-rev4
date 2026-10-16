-- deadpool_slime_fall_test.lua
--
-- Where does the Dead Pool stage fatality actually put the body?
--
-- The fatality is do_uppercut's ucut2 branch (MOVES.ASM): on curback 0, during
-- FINISH HIM, an uppercut that connects while the attacker holds LP+LK hands
-- the victim act_slime_fall, and r_fall_in_slime (BGND.ASM) flies him into the
-- pool BEHIND the walkway.
--
-- The pool is only world x 195..947 (tools/deadpool_acid_band.py measures it
-- off DEDPOOL.BDB).  Fighters reach world x 60..1098.  So the interesting
-- question is not "does the fatality fire" - it always did - but "where does
-- he come down", and that depends entirely on where he was standing.
--
-- One run = one trial.  Pin the victim at DP_VX with the attacker DP_GAP away
-- on side DP_SIDE, fire the uppercut, then let go and watch the arc.
--
--   DP_VX=310 DP_SIDE=right   -- victim at 310, attacker on his right, so he
--                                is knocked LEFT.  Retail's 0130h threshold
--                                takes the long arc here and lands him at
--                                ~184, on the stone ledge.
--   DP_VX=830 DP_SIDE=left    -- the mirror window on the far end.
--
-- Env knobs:
--   DP_VX=N        victim's world x at the moment of the uppercut (default 310)
--   DP_SIDE=left|right   which side the ATTACKER stands on (default right)
--   DP_GAP=N       attacker's distance from the victim (default 55)
--   DP_OBSERVE=N   frames to watch after the fall starts (default 260)
--   DP_TEST_LOG=path

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("DP_TEST_LOG") or (ROOT .. "/tools/deadpool_slime_fall_test.log")
local VICTIM_X = getenv_int("DP_VX", 310)
local GAP = getenv_int("DP_GAP", 55)
local SIDE = (os.getenv("DP_SIDE") or "right"):lower()
local OBSERVE_FRAMES = getenv_int("DP_OBSERVE", 260)

-- The pool, straight out of BGND.ASM's equates so the rig cannot drift away
-- from what the ROM was built to aim at.
local ACID_RAW_L, ACID_RAW_R, ACID_MARGIN = 195, 947, 30
do
    local fh = io.open(ROOT .. "/src/BGND.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n = line:match("^dp_acid_raw_lft%s+%.equ%s+(%d+)")
            if n then ACID_RAW_L = tonumber(n) end
            n = line:match("^dp_acid_raw_rgt%s+%.equ%s+(%d+)")
            if n then ACID_RAW_R = tonumber(n) end
            n = line:match("^dp_acid_margin%s+%.equ%s+(%d+)")
            if n then ACID_MARGIN = tonumber(n) end
        end
        fh:close()
    end
end

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
    print("[dpslime] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end
local function hx(v) if v == nil then return "na" end return string.format("0x%08x", v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end return v end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        log("WARN no linker map")
    end
end
local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s", name)
    return fallback or 0
end

local A = {
    active = sym("active"), gstate = sym("gstate"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_xvel = sym("p1_xvel"), p2_xvel = sym("p2_xvel"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"), worldtlx = sym("worldtlx"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
    system_lockup = sym("system_lockup"), tvbp = sym("TVBP"),
}

local O = { next = 0x000, oxvel = 0x040, oxval = 0x080, oxpos = 0x090,
            oyval = 0x0a0, oypos = 0x0b0, oflags = 0x0f0, osag = 0x100,
            oflags2 = 0x160, oimg = 0x1a0, oid = 0x1c0, ochar = 0x1f0 }
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KANG, FT_JAX = 1, 11
local STAGE_DEADPOOL = 0
local ACT_UPPERCUT, ACT_SLIME_FALL, ACT_STUNNED = 0x0107, 0x050a, 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local M_INVISO = 0x0020

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, fight_count, p1_confirm_start = 0, 0, 0, 0
local finish_forced_frame, victim_dizzy_forced, dizzy_ready_frame = 0, false, 0
local attempt_start, attempt_n = 0, 0
local fall_start_frame, land_frame = 0, 0
local land_x, min_x, max_x = nil, nil, nil
local splash_x, skel_x = nil, nil
local finished, snap_index = false, 0
local last_status = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

-- SAG -> label, for the acid splash / skeleton art the fatality spawns.
local sag_labels = {}
do
    local fh = io.open(ROOT .. "/src/MKBGANI.TBL", "r")
    if fh then
        local current = nil
        for line in fh:lines() do
            local label = line:match("^([%w_]+):")
            if label then
                current = (label:match("^acidsplash") or label:match("^acidskel")) and label or nil
            elseif current then
                local raw = line:match("%.long%s+0?(%x+)[hH]")
                if raw then sag_labels[tonumber(raw, 16) & 0x00ffffff] = current; current = nil end
            end
        end
        fh:close()
    end
    local n = 0
    for _ in pairs(sag_labels) do n = n + 1 end
    log("acid art SAGs loaded: %d", n)
end

local function walk_objects(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj, guard, seen = r32(list), 0, {}
        while obj ~= 0 and guard < 400 do
            if seen[obj] then return "cycle" end
            seen[obj] = true
            fn(obj)
            obj = r32(obj + O.next)
            guard = guard + 1
        end
        if guard >= 400 then return "overflow" end
    end
    return nil
end

local function find_acid_art()
    local out = {}
    walk_objects(function(obj)
        local label = sag_labels[r32(obj + O.osag) & 0x00ffffff]
        if label then out[#out + 1] = { label = label, x = r16(obj + O.oxpos) } end
    end)
    return out
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    if s then pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s", snap_index, frame, label)
    snap_index = snap_index + 1
end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Low Punch"] = true, ["P1 Low Kick"] = true,
        ["P1 Down"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
    }
    local all = {}
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            all[#all + 1] = field.name
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    table.sort(all)
    log("ports: %s", table.concat(all, " | "))
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-16s MISSING", name); ok = false end
    end
    return ok
end

local function victim_obj() return r32(A.p2_obj) end
local function attacker_obj() return r32(A.p1_obj) end
local function p1_action()
    local p = r32(A.p1_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end
local function p2_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state_line(tag)
    local a, v = attacker_obj(), victim_obj()
    local ax = a ~= 0 and r16(a + O.oxpos) or -1
    local vx = v ~= 0 and r16(v + O.oxpos) or -1
    local vy = v ~= 0 and s16(r16(v + O.oypos)) or -1
    local vv = v ~= 0 and s32(r32(v + O.oxvel)) or 0
    local art = {}
    for _, e in ipairs(find_acid_art()) do art[#art + 1] = e.label .. "@" .. e.x end
    return string.format(
        "%s gs=%d ws=%d fdeath=%d p1act=0x%04x p2act=0x%04x atk_x=%d vic_x=%d vic_y=%d vic_xvel=%d wtlx=%d art=[%s]",
        tag, r16(A.gstate), r16(A.winner_status), r16(A.f_death), p1_action(), p2_action(),
        ax, vx, vy, vv // 65536, s16(r16(A.worldtlx + 16)), table.concat(art, ","))
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_pass" or "final_fail")
    log("RESULT %s reason=%s vx=%d side=%s gap=%d land_x=%s min=%s max=%s splash_x=%s skel_x=%s band=%d..%d",
        ok and "PASS" or "FAIL", reason, VICTIM_X, SIDE, GAP,
        tostring(land_x), tostring(min_x), tostring(max_x),
        tostring(splash_x), tostring(skel_x), ACID_RAW_L, ACID_RAW_R)
    log("%s", state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_DEADPOOL)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
end

local function fighters_ok()
    local a, v = attacker_obj(), victim_obj()
    return a ~= 0 and v ~= 0 and r16(a + O.ochar) == FT_KANG and r16(v + O.ochar) == FT_JAX
end

local function force_finish_him()
    if fall_start_frame ~= 0 then return end
    if not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 900 then return end
    w16(A.winner_status, 3)
    w16(A.f_death, 0)
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then
        w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2p = r32(A.p2_proc)
    if p2p ~= 0 and not victim_dizzy_forced then
        w32(p2p + P.wake, A.dizzy_dude)
        victim_dizzy_forced = true
    end
    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        w16(A.curback, STAGE_DEADPOOL)
        log("finish_him frame=%d | %s", frame, state_line("ff"))
        snap("finish_him")
    end
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

-- Hold both fighters where the trial wants them.  Released the instant the
-- victim is handed act_slime_fall, so the arc itself is never touched.
local function pin()
    local a, v = attacker_obj(), victim_obj()
    if a == 0 or v == 0 then return end
    local ax = SIDE == "left" and (VICTIM_X - GAP) or (VICTIM_X + GAP)
    w16(v + O.oxpos, VICTIM_X); w32(v + O.oxval, (VICTIM_X << 16) & 0xffffffff)
    w16(a + O.oxpos, ax);       w32(a + O.oxval, (ax << 16) & 0xffffffff)
end

-- One uppercut attempt.  LP+LK are held all the way through (they are the
-- stage-fatality modifier, switch2 bits 0 and 1 - see ucut1 in MOVES.ASM), and
-- because they are HELD they only ever edge-trigger once, at the start.
local ATTEMPT_LEN = 70
local function press_for(name, rel)
    if name == "P1 Low Punch" or name == "P1 Low Kick" then return rel >= 0 end
    if name == "P1 Down" then return rel >= 20 end
    if name == "P1 High Punch" then return rel >= 34 and rel < 42 end
    return false
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
    if attempt_start > 0 and fall_start_frame == 0 and fighting_frame > 0 then
        return press_for(name, (frame - attempt_start) % ATTEMPT_LEN)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("trial vx=%d side=%s gap=%d  acid=%d..%d margin=%d",
            VICTIM_X, SIDE, GAP, ACID_RAW_L, ACID_RAW_R, ACID_MARGIN)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d | %s", frame, state_line("fs"))
        end
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0
        and frame > charsel_frame + 90 and r16(A.p1_char) == FT_KANG and r16(A.p2_char) == FT_JAX then
        p1_confirm_start = frame + 25
    end

    if fighting_frame > 0 and fall_start_frame == 0 then
        force_finish_him()
        if attempt_start == 0 and finish_forced_frame > 0 and victim_ready() then
            dizzy_ready_frame = frame
            attempt_start = frame + 10
            log("victim_ready frame=%d attempts begin %d | %s", frame, attempt_start, state_line("vr"))
        end
        if attempt_start > 0 then
            pin()
            if frame >= attempt_start and (frame - attempt_start) % ATTEMPT_LEN == 0 then
                attempt_n = attempt_n + 1
                log("uppercut_attempt=%d frame=%d | %s", attempt_n, frame, state_line("try"))
                if attempt_n > 8 then finish(false, "uppercut_never_connected"); return end
            end
        end
        if p2_action() == ACT_SLIME_FALL then
            fall_start_frame = frame
            local v = victim_obj()
            min_x = r16(v + O.oxpos); max_x = min_x
            log("SLIME_FALL frame=%d start_x=%d | %s", frame, min_x, state_line("fall"))
            snap("slime_fall_start")
        end
    end

    if fall_start_frame > 0 then
        local rel = frame - fall_start_frame
        local v = victim_obj()
        if v ~= 0 then
            local x = r16(v + O.oxpos)
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            -- the body stops when flight lands it; that is the landing x.
            if land_x == nil and rel > 8 and s32(r32(v + O.oxvel)) == 0 then
                land_x = x
                land_frame = frame
                log("LANDED frame=%d rel=%d x=%d | %s", frame, rel, x, state_line("land"))
                snap("landed")
            end
        end
        for _, e in ipairs(find_acid_art()) do
            if splash_x == nil and e.label:match("^acidsplash") then
                splash_x = e.x
                log("SPLASH frame=%d rel=%d %s@%d | %s", frame, rel, e.label, e.x, state_line("splash"))
                snap("splash")
            end
            if skel_x == nil and e.label:match("^acidskel") then
                skel_x = e.x
                log("SKELETON frame=%d rel=%d %s@%d | %s", frame, rel, e.label, e.x, state_line("skel"))
                snap("skeleton")
            end
        end
        if rel <= 24 or rel % 8 == 0 then
            log("obs rel=%03d | %s", rel, state_line("obs"))
            if rel % 24 == 0 then snap(string.format("obs_%03d", rel)) end
        end
        if rel >= OBSERVE_FRAMES then
            local x = land_x or (victim_obj() ~= 0 and r16(victim_obj() + O.oxpos) or nil)
            land_x = x
            if x == nil then finish(false, "no_landing_x"); return end
            local inside = x >= ACID_RAW_L and x <= ACID_RAW_R
            local margin_ok = x >= (ACID_RAW_L + ACID_MARGIN) and x <= (ACID_RAW_R - ACID_MARGIN)
            if inside and margin_ok then finish(true, "landed_in_acid")
            elseif inside then finish(true, "landed_in_acid_but_inside_margin")
            else finish(false, "landed_on_the_ledge_x_" .. x) end
            return
        end
    end

    if frame - last_status >= 180 then
        last_status = frame
        log("status | %s", state_line("status"))
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 9000 then finish(false, "never_reached_fight")
    elseif frame > 20000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
