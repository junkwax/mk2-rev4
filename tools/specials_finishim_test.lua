--- specials_finishim_test.lua - "does this special still work during FINISH HIM?"
---
--- The finish-him window is not a cutscene: the fight is still live, and a
--- special whose input does not collide with a fatality has no business being
--- switched off there.  Several were, for different reasons (a projectile
--- soft-lock workaround, a fatality fork that jumped over the special, a
--- bare-button fatality remap that ate every press).  This harness pins the
--- behaviour down per move so it cannot quietly regress again.
---
--- Flow (modeled on baraka_spark_finishim_test.lua):
---   1. Direct-select P1 = the case's character vs P2 Jax, reach the fight.
---   2. Force FINISH HIM: winner_status=3, f_death=0, victim wake=dizzy_dude.
---   3. Wait for the victim to be genuinely dizzy (ACT_STUNNED in dizzy window).
---   4. Snap P1 to a fixed range, then replay the move's input until the
---      expected p_action shows up (or the attempts run out).
---   5. Observe afterwards for lockups / stuck actions.
---
--- Env knobs:
---   SPEC_CASE=name       which case to run (see CASES below)
---   SPEC_LOG=path        log file
---   SPEC_CONTROL=1       run the same input in a NORMAL fight (ws stays 0)
---                        - the A/B baseline that proves the input itself works
---
--- A case FAILS if the move never fires; that is the regression we care about.

local ROOT = "C:/Users/you/Workplace/mk2-main"

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

-- ---------------------------------------------------------------- cases ----
-- dir1/dir2 are stick-relative: "back"/"fwd" resolve against which side P1 is
-- standing on, "down"/"up" are absolute.  attempt = frames per retry; it must
-- be long enough that two consecutive attempts cannot chain into a LONGER
-- combo (Kung Lao's F,F,F fatality is a superset of his F,F spin).
local CASES = {
    baraka_spark = {
        char = 3,  dirs = { "down", "back" }, button = "P1 High Punch",
        action = 0x0007, attempt = 44, range = 80,
        desc = "Baraka Down,Back+HP blade spark",
    },
    sz_tornado = {
        char = 8,  dirs = { "down", "back" }, button = "P1 Low Punch",
        action = 0x0210, attempt = 60, range = 80,
        desc = "Sub-Zero Down,Back+LP ice tornado",
    },
    hh_spin = {
        char = 0,  dirs = { "fwd", "fwd" }, button = "P1 Low Kick",
        action = 0x0108, attempt = 96, range = 80,
        desc = "Kung Lao Forward,Forward+LK whirlwind spin",
    },
    sc_teleport = {
        char = 10, dirs = { "down", "back" }, button = "P1 High Punch",
        action = 0x020a, attempt = 44, range = 80,
        desc = "Scorpion Down,Back+HP teleport punch",
    },
    -- Heliport moved off HP (where it shared a button with the blade spark)
    -- onto LK.  Normal fight is the real test; it is not a finish-him move.
    sa_heliport = {
        char = 3,  dirs = { "up", "up" }, button = "P1 Low Kick",
        action = 0x0121, attempt = 60, range = 80,
        desc = "Baraka Up,Up+LK heliport (moved off HP)",
    },
    -- Jax air lightwave: the SAME Forward,Down,Back+HK motion as his ground
    -- wave, but thrown from a jump.  The leading Up is deliberate here - it
    -- is what gets him airborne - so unlike the grounded cases this one must
    -- NOT hold block.
    jx_airzap = {
        char = 11, dirs = { "up", "fwd", "down", "back" }, button = "P1 High Kick",
        action = 0x0014, attempt = 90, range = 110,
        desc = "Jax (jump) Forward,Down,Back+HK air lightwave",
    },
    -- Regression guard: the GROUND wave still has to fire after the airborne
    -- branch was added ahead of it in jx_hi_kick.
    jx_zap = {
        char = 11, dirs = { "fwd", "down", "back" }, button = "P1 High Kick",
        action = 0x0014, attempt = 70, range = 110,
        desc = "Jax Forward,Down,Back+HK ground lightwave (regression)",
    },
    -- Kung Lao head butt (the "elbow" slot, do_hh_elbow_glow).  Close-range
    -- HP with no stick motion.  The point of this case is the follow-through:
    -- the strike check used to break out of the frame loop, freezing the move
    -- on the frame that connected.
    hh_headbutt = {
        char = 0, dirs = nil, button = "P1 High Punch",
        action = 0x0114, attempt = 40, range = 42,
        desc = "Kung Lao close HP head butt (animation follow-through)",
    },
    -- Kung Lao back+HP backfist.  Not a combo - hh_hi_punch checks
    -- is_stick_away, so Back has to still be HELD when HP is pressed (the
    -- single-direction schedule overlaps the button, which is what we want).
    hh_backfist = {
        char = 0, dirs = { "back" }, button = "P1 High Punch",
        action = 0x010b, attempt = 44, range = 70,
        desc = "Kung Lao Back+HP backfist",
    },
    -- Scorpion's stock MK2 burn.  The point of this case is NOT the input -
    -- it is the explosion that follows: retail's bone/quadrant counts used to
    -- exhaust the object pool, and object_setup answers that with ermac
    -- (`jauc $`), hanging the CPU right at the white flash.  So this one keeps
    -- watching well past f_death and fails on a lockup.
    sc_toasty_fatality = {
        char = 10, dirs = { "down", "down", "up", "up" }, button = "P1 High Punch",
        hold = "P1 Block",   -- the two Ups would otherwise jump him
        fatality = true, watch_after_fatality = 600,
        attempt = 70, range = 80,
        desc = "Scorpion Down,Down,Up,Up+HP toasty burn (explosion pool stress)",
    },
    -- Scorpion's MK1 scortch: a BARE HP in FINISH HIM, but only from sweep
    -- distance a step back (sc_scortch_min..max = 080h..0c0h, MOVES.ASM
    -- sc_hi_punch).  The _close/_far cases are the negatives: same press,
    -- out of the band, and it must NOT burn him.
    sc_scortch = {
        char = 10, dirs = nil, button = "P1 High Punch",
        fatality = true, attempt = 40, range = 160,
        desc = "Scorpion bare HP MK1 scortch at 160px (in band)",
    },
    sc_scortch_close = {
        char = 10, dirs = nil, button = "P1 High Punch",
        fatality = true, refuse = true, attempt = 40, range = 100,
        desc = "Scorpion bare HP at 100px - too close, must not burn",
    },
    sc_scortch_far = {
        char = 10, dirs = nil, button = "P1 High Punch",
        fatality = true, refuse = true, attempt = 40, range = 220,
        desc = "Scorpion bare HP at 220px - too far, must not burn",
    },
    -- Counter-case: giving a special its input back must not cost the
    -- fatality that shares the button.  Also pins the head rip's new input.
    sz_headrip_fatality = {
        char = 8, dirs = { "fwd", "down", "fwd" }, button = "P1 Low Punch",
        fatality = true, attempt = 60, range = 80,
        desc = "Sub-Zero Forward,Down,Forward+LP head rip (fatality counter-case)",
    },
}

local CASE_NAME = os.getenv("SPEC_CASE") or "baraka_spark"
local CASE = CASES[CASE_NAME]
local LOG_PATH = os.getenv("SPEC_LOG") or (ROOT .. "/tools/specials_finishim_" .. CASE_NAME .. ".log")
local CONTROL = os.getenv("SPEC_CONTROL") == "1"
local OBSERVE_FRAMES = getenv_int("SPEC_OBSERVE", 150)
local MAX_ATTEMPTS = getenv_int("SPEC_ATTEMPTS", 8)

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
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[spec] " .. msg)
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

-- Resolve symbols from the freshly built linker map (never hardcode: RAM
-- moves on every rebuild).
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
local function sym(name)
    local v = symbols[name]
    if v == nil then log("WARN missing symbol %s", name) end
    return v or 0
end

local A = {
    active = sym("active"), gstate = sym("gstate"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"), f_death2 = sym("f_death2"),
    ofree = sym("ofree"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
    system_lockup = sym("system_lockup"), tvbp = sym("TVBP"),
}

local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, ochar = 0x1f0 }
local P = { next = 0x000, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_JAX = 11
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local STAGE_ID = 5   -- Armory: no stage fatality route to confuse the input

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, fight_count = 0, 0, 0
local p1_confirm_start = 0
local did_direct_select = false
local finish_forced_frame = 0
local victim_dizzy_forced = false
local combo_start_frame = 0
local combo_attempt = 0
local move_fired_frame = 0
local fatality_frame = 0
local min_free_objects = 0   -- peak live-object count seen during the fatality
local observe_start = 0
local finished = false
local last_status_frame = 0
local snap_index = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Low Punch"] = true, ["P1 Low Kick"] = true, ["P1 Block"] = true,
        ["P1 High Kick"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Up"] = true, ["P1 Down"] = true,
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

local function count_procs()
    local p = r32(A.active)
    local n, guard = 0, 0
    local seen = {}
    while p ~= 0 and guard < 400 do
        if seen[p] then return n, true end
        seen[p] = true
        n = n + 1
        p = r32(p + P.next)
        guard = guard + 1
    end
    return n, false
end

-- Free display objects: the pool that ermac (`jauc $`) hangs on when it runs
-- dry.  The free list links through offset 0, same as getobj walks it.
local function free_objects()
    if A.ofree == 0 then return -1 end
    local o = r32(A.ofree)
    local n, guard = 0, 0
    while o ~= 0 and guard < 512 do
        n = n + 1
        o = r32(o)
        guard = guard + 1
    end
    return n
end

-- Live display objects across the three lists.  This is the number that shows
-- whether the bone/explosion shower actually put pieces on screen.
local function object_count()
    local n = 0
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if list ~= 0 then
            local obj, guard, seen = r32(list), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then break end
                seen[obj] = true
                n = n + 1
                obj = r32(obj)
                guard = guard + 1
            end
        end
    end
    return n
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function xy(objaddr)
    if objaddr == 0 then return 0, 0 end
    return r16(objaddr + O.oxpos), s16(r16(objaddr + O.oypos))
end

local function state_line(tag)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y = xy(p1o)
    local p2x, p2y = xy(p2o)
    local nproc, pcycle = count_procs()
    return string.format(
        "%s gs=%d ws=%d fdeath=%d p1act=0x%04x p1hp=%d p2hp=%d p1=(%d,%d) p2=(%d,%d) procs=%d%s freeobj=%d",
        tag, r16(A.gstate), r16(A.winner_status), r16(A.f_death),
        p1_action(), r16(A.p1_bar), r16(A.p2_bar), p1x, p1y, p2x, p2y,
        nproc, pcycle and "!cycle" or "", free_objects()) ..
        string.format(" objs=%d", object_count())
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

-- CPU hang detector.  `ermac` is `jauc $` - a jump to itself - and it sits at
-- whatever call site ran out of resources, NOT at system_lockup, so the
-- address-range guard below cannot see it.  MK2's scheduler is cooperative, so
-- one wedged process stops the whole main loop and only interrupt code keeps
-- running: the sampled PC collapses onto a couple of addresses.  Healthy play
-- shows dozens of distinct PCs per second.
local pc_window = {}
local function hang_reason()
    local pc = cpu_pc()
    if not pc then return nil end
    pc_window[#pc_window + 1] = pc
    if #pc_window > 90 then table.remove(pc_window, 1) end
    if #pc_window < 90 then return nil end
    local seen, distinct = {}, 0
    for _, v in ipairs(pc_window) do
        if not seen[v] then seen[v] = true; distinct = distinct + 1 end
    end
    if distinct <= 3 then
        return string.format("cpu_hang_%ddistinct_pc_%s", distinct, hx(pc))
    end
    return nil
end

-- Corrupted-state guard.  A run that ends with garbage in the globals is NOT a
-- pass, however cleanly the move itself fired: an off-the-end animation walk
-- leaves p1 at (0xFFFF,-1) with nonsense gstate/health while the CPU keeps
-- running, so neither the hang detector nor "did the action change" sees it.
local function corrupt_reason()
    local gs = r16(A.gstate)
    if gs > 20 then return "gstate_" .. gs end
    if r16(A.p1_bar) > 200 or r16(A.p2_bar) > 200 then
        return string.format("health_%d_%d", r16(A.p1_bar), r16(A.p2_bar))
    end
    local p1o = r32(A.p1_obj)
    if p1o ~= 0 then
        local x, y = xy(p1o)
        if x > 4000 or y < -200 then return string.format("p1_pos_%d_%d", x, y) end
    end
    return nil
end

local function finish(ok, reason)
    if finished then return end
    if ok then
        local bad = corrupt_reason()
        if bad then ok, reason = false, "corrupt_state_" .. bad .. "_after_" .. reason end
    end
    finished = true
    snap(ok and "final_ok" or ("final_" .. reason))
    log("%s case=%s mode=%s reason=%s | %s", ok and "PASS" or "FAIL", CASE_NAME,
        CONTROL and "control_normal_fight" or "finish_him", reason, state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    w16(A.p1_char, CASE.char)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=%d P2=Jax(%d) stage=%d", CASE.char, FT_JAX, STAGE_ID)
    end
end

local function fighters_ok()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return false end
    return r16(p1o + O.ochar) == CASE.char and r16(p2o + O.ochar) == FT_JAX
end

local function force_finish_him()
    if CONTROL then return end
    if fight_count ~= 1 or move_fired_frame ~= 0 then return end
    if not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 900 then return end
    w16(A.winner_status, 3)
    -- Only hold f_death down while we are still SETTING UP.  Once inputs
    -- start, a fatality that fires must be allowed to keep it - otherwise the
    -- harness silently interrupts the very thing it is watching for.
    if combo_start_frame == 0 then w16(A.f_death, 0) end
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
        log("finish_him_forced frame=%d rel=%d | %s", frame, rel, state_line("ff"))
        snap("finish_him_forced")
    end
end

local function victim_ready()
    if CONTROL then return fighters_ok() end
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

local function snap_range()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local p2x = r16(p2o + O.oxpos)
    local x = p2x - CASE.range
    w16(p1o + O.oxpos, x)
    w32(p1o + O.oxval, (x << 16) & 0xffffffff)
end

-- Stick directions are resolved LIVE against which side P1 stands on: a
-- hardcoded Left is FORWARD once he crosses over, the combo never matches,
-- and the run reports "the special is disabled" when the truth is the input
-- was never made.
local function dir_field(dir)
    if dir == "down" then return "P1 Down" end
    if dir == "up" then return "P1 Up" end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local left = true
    if p1o ~= 0 and p2o ~= 0 then left = r16(p1o + O.oxpos) <= r16(p2o + O.oxpos) end
    if dir == "back" then return left and "P1 Left" or "P1 Right" end
    return left and "P1 Right" or "P1 Left"   -- fwd
end

-- Directions are replayed in order, DIR_STEP apart with a gap between each so
-- a repeated direction registers as two separate presses; the button lands
-- just before the last one ends.
local DIR_STEP = 11
local function combo_press(name, rel)
    local dirs = CASE.dirs or {}
    -- optional held button (Block) for motions whose leading Up would jump
    if CASE.hold and name == CASE.hold then
        return rel >= 0 and rel < #dirs * DIR_STEP + 8
    end
    for i, d in ipairs(dirs) do
        local start = (i - 1) * DIR_STEP
        if rel >= start and rel < start + 9 and name == dir_field(d) then return true end
    end
    local btn = math.max(0, #dirs * DIR_STEP - 5)
    if rel >= btn and rel < btn + 12 and name == CASE.button then return true end
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
    -- frame >= combo_start_frame matters: Lua's % is non-negative, so the
    -- frames BEFORE the first attempt would otherwise wrap into the tail of
    -- the schedule and fire a stray bare button press.  During finish him a
    -- bare HP is a fatality trigger for some characters, so that stray press
    -- started a fatality before the special was ever input.
    if combo_start_frame > 0 and frame >= combo_start_frame
        and move_fired_frame == 0 and fatality_frame == 0 and fighting_frame > 0 then
        return combo_press(name, (frame - combo_start_frame) % CASE.attempt)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not CASE then finish(false, "unknown_case_" .. CASE_NAME); return end
        if not cache_fields() then finish(false, "input_missing"); return end
        log("case=%s (%s) mode=%s expect=%s", CASE_NAME, CASE.desc,
            CONTROL and "control_normal_fight" or "finish_him",
            CASE.fatality and "fatality" or string.format("action=0x%04x", CASE.action))
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d | %s", frame, state_line("fs"))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0
        and frame > charsel_frame + 90 and r16(A.p1_char) == CASE.char and r16(A.p2_char) == FT_JAX then
        p1_confirm_start = frame + 25
    end

    -- Fatality watch: keep running past f_death so the explosion itself is
    -- under observation.  Track the low-water mark of the object pool - that
    -- is the number the ermac hang depends on.
    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local fo = object_count()
        if fo > min_free_objects then min_free_objects = fo end
        if rel % 20 == 0 then log("fatal rel=%d | %s", rel, state_line("fw")) end
        if rel == 40 or rel == 120 then snap("fatal_" .. rel) end
        if rel >= CASE.watch_after_fatality then
            log("peak_objects=%d during the fatality", min_free_objects)
            finish(true, "fatality_ran_clean_peakobjs_" .. min_free_objects)
            return
        end
    end

    if fighting_frame > 0 and move_fired_frame == 0 and fatality_frame == 0 then
        force_finish_him()
        if combo_start_frame == 0 and (finish_forced_frame > 0 or CONTROL) and victim_ready() then
            snap_range()
            combo_start_frame = frame + 20
            log("victim_ready frame=%d; combo begins at %d | %s", frame, combo_start_frame, state_line("vr"))
            snap("victim_ready")
        end
        if combo_start_frame > 0 and frame >= combo_start_frame then
            if (frame - combo_start_frame) % CASE.attempt == 0 then
                combo_attempt = combo_attempt + 1
                snap_range()
                local names = {}
                for _, d in ipairs(CASE.dirs or {}) do names[#names + 1] = dir_field(d) end
                log("attempt=%d frame=%d dirs=%s | %s", combo_attempt, frame,
                    table.concat(names, ","), state_line("try"))
            end
            -- SPEC_TRACE=1: per-frame action/position for the first two
            -- attempts.  This is how you tell "the input never matched" apart
            -- from "the move was refused after matching".
            if os.getenv("SPEC_TRACE") == "1" then
                local rel = frame - combo_start_frame
                if rel < 2 * CASE.attempt then
                    local p1o = r32(A.p1_obj)
                    local px, py = xy(p1o)
                    log("trace rel=%d p1act=0x%04x p1=(%d,%d)", rel, p1_action(), px, py)
                end
            end
            if CASE.fatality and (CONTROL or CASE.refuse) then
                -- A fatality must NOT be reachable in a normal fight; the
                -- control run asserts the refusal instead of the firing.
                -- A `refuse` case asserts the same during FINISH HIM - the
                -- input is right but the range is not.
                local where = CONTROL and "normal_fight" or ("range_" .. CASE.range)
                if r16(A.f_death) ~= 0 then
                    finish(false, "fatality_fired_" .. where)
                elseif combo_attempt >= MAX_ATTEMPTS then
                    finish(true, "fatality_correctly_refused_" .. where)
                end
                return
            end
            if CASE.fatality and r16(A.f_death) ~= 0 then
                log("FATALITY_FIRED frame=%d attempt=%d | %s", frame, combo_attempt, state_line("fatal"))
                snap("fatality_fired")
                if CASE.watch_after_fatality then
                    -- keep running: the interesting part is what the fatality
                    -- DOES (object-pool stress at the explosion), not that it
                    -- started.  The lockup guard below stays armed throughout.
                    fatality_frame = frame
                else
                    finish(true, "fatality_fired")
                end
                return
            elseif not CASE.fatality and p1_action() == CASE.action then
                move_fired_frame = frame
                observe_start = frame
                log("MOVE_FIRED frame=%d attempt=%d | %s", frame, combo_attempt, state_line("fired"))
                snap("move_fired")
            elseif not CASE.fatality and r16(A.f_death) ~= 0 then
                -- a fatality started instead: the fatality won the input race
                finish(false, "fatality_fired_instead")
                return
            elseif combo_attempt >= MAX_ATTEMPTS then
                finish(false, CASE.fatality and "fatality_never_fired" or "move_never_fired")
                return
            end
        end
    end

    if move_fired_frame > 0 then
        local rel = frame - observe_start
        if rel % 15 == 0 then log("obs rel=%d | %s", rel, state_line("obs")) end
        -- SPEC_TRACE also snapshots the first ticks of the move, which is
        -- where the contact pose lives (striker holds part one's last frame).
        if os.getenv("SPEC_TRACE") == "1" and rel <= 10 then
            snap(string.format("hit_%02d", rel))
        end
        if rel == 30 then snap("obs_030") end
        if rel >= OBSERVE_FRAMES then
            -- Still stuck in the move long after it should have ended = freeze.
            if p1_action() == CASE.action then
                finish(false, "stuck_in_move_rel_" .. rel)
            else
                finish(true, "fired_and_recovered")
            end
            return
        end
    end

    if fighting_frame > 0 then
        local hung = hang_reason()
        if hung then
            log("HANG frame=%d %s | %s", frame, hung, state_line("hang"))
            snap("hang")
            finish(false, hung)
            return
        end
        local pc = cpu_pc()
        if pc and A.system_lockup ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
            log("LOCKUP frame=%d pc=%s | %s", frame, hx(pc), state_line("lock"))
            finish(false, "lockup_" .. hx(pc))
            return
        end
    end

    if frame - last_status_frame >= 180 then
        last_status_frame = frame
        log("status | %s", state_line("status"))
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
