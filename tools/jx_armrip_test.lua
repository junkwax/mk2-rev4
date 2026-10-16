-- jx_armrip_test.lua
--
-- End-to-end MAME harness for Jax's arm-rip fatality (do_arm_rip in
-- MKDEATH.ASM, a_arm_rip in MKJX.ASM).
--
-- THE RIG IS TWO-SIDED.  Which behaviour is expected is READ OUT OF THE
-- SOURCE, not written into the rig, so a deliberate roll back either way is
-- guarded instead of going permanently red: do_arm_rip's count of
-- jsrp ani_with_arms IS the behaviour (5 = retail, 3 = the hold), and a count
-- that is neither is a named refusal - NO VERDICT, never a pass.
--
-- RETAIL (mk2-readonly, what ships as of 2026-10-04 - mode "toss"):
--   JXARMRIP1/2        the grab, arms stretched out
--   JXARMRIP3..7       the pull - the loose arm props walk RIPARM1..5, whose
--                      anipoints march them from +90 to +135 below his head
--                      anchor, i.e. down onto the floor (RIPARM5 lands flat
--                      at 10px tall).  THAT ARC IS THE TOSS, and retail
--                      draws it - the props are EXPECTED to reach it.
--   JXARMRIP8..12      he straightens up and raises his own forearms
--   a_jxvictory        the lane's own ani_jump IS taken - he leaves frame 12
--
-- THE HOLD (this project's version, 2026-08-06..2026-10-04 - mode "hold"):
--   JXARMRIP3,4,5      props stop on RIPARM3, pinned to his hands
--   JXARMRIP6..12      arm_hold_offsets walks the props out to his fists
--   JXARMRIP12         held forever - the a_jxvictory jump is never taken
--
-- What this run proves, either way:
--   1. both loose arm props appear;
--   2. he reaches JXARMRIP12;
--   3. the props' frames and the lane's ending match the mode the source is
--      in - toss: RIPARM4/5 reached AND he leaves frame 12 for the victory
--      pose; hold: those frames never drawn, both props still in his fists
--      on frame 12, and he never leaves it;
--   4. no lockup.
--
-- Modeled on sz_headrip_test.lua.  Same caveat: scripted button presses do
-- not reach the in-fight move dispatch in this MAME build, so the fatality
-- is entered by pointing P1's process wake at do_arm_rip.  do_arm_rip is
-- file-local, so its address is read out of db2_table[11] at runtime -
-- which also proves the dispatch entry itself.
--
-- Env:
--   JXAR_VICTIM=<ochar>   victim (default 8 = Sub-Zero)
--   JXAR_SIDE=left|right  which side Jax stands on (default left)
--   JXAR_STAGE=<id>       stage index (default 5)

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("JXAR_LOG") or (ROOT .. "/tools/jx_armrip_test.log")
local CSV_PATH = os.getenv("JXAR_FRAME_LOG") or (ROOT .. "/tools/jx_armrip_frames.csv")
local STAGE_ID = getenv_int("JXAR_STAGE", 5)
local VICTIM = getenv_int("JXAR_VICTIM", 8)
local SIDE = (os.getenv("JXAR_SIDE") or "left"):lower()
local FATAL_X = getenv_int("JXAR_FATAL_X", 90)
local HOLD_MIN = getenv_int("JXAR_HOLD_MIN", 70)   -- sleep 060h = 96 ticks
local CAPTURE_UNTIL = getenv_int("JXAR_CAPTURE_UNTIL", 260)

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(CSV_PATH, "w")
if csvfh then
    csvfh:write("emu_frame,rel,f_death,jax_frame,props,prop_labels," ..
                "prop_lo_y,jax_y,floor_gap\n")
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
    print("[jxar] " .. msg)
end

local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

-- Resolve symbols from the freshly built linker map.  Never hardcode.
local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if not fh then
        map_path = ROOT .. "/src/MK2.MAP"
        fh = io.open(map_path, "r")
    end
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

local missing_symbols = {}
local function sym(name, fallback)
    local value = symbols[name]
    if value ~= nil then return value end
    missing_symbols[#missing_symbols + 1] = name
    log("WARN missing symbol %s", name)
    return fallback or 0
end

local A = {
    active        = sym("active"),
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),
    p2_state      = sym("p2_state"),
    p1_char       = sym("p1_char"),
    p2_char       = sym("p2_char"),
    p1_obj        = sym("p1_obj"),
    p2_obj        = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),
    p2_proc       = sym("p2_proc"),
    curback       = sym("curback"),
    winner_status = sym("winner_status"),
    f_death       = sym("f_death"),
    pf_ram        = sym("pf_ram"),
    objlst        = sym("objlst"),
    objlst2       = sym("objlst2"),
    objlst3       = sym("objlst3"),
    db2_table     = sym("db2_table"),
    dizzy_dude    = sym("dizzy_dude"),
    dizzy         = sym("dizzy"),
    system_lockup = sym("system_lockup"),
    tvbp          = sym("TVBP"),
}

local O = {
    next = 0x000, oslink = 0x020, oxval = 0x080, oxpos = 0x090,
    oyval = 0x0a0, oypos = 0x0b0, ozval = 0x0c0, oflags = 0x0f0,
    osag = 0x100, oimg = 0x1a0, ochar = 0x1f0,
}
-- pdata = 0x100 (MAINEQU.ASM): p_store1 = pdata+130h, p_store2 = pdata+150h.
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210,
            store1 = 0x230, store2 = 0x250 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_JAX = 11
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local DB2_ARM_RIP = 11          -- db2_table index for do_arm_rip

-- Which loose-arm set the victim's ochar must produce (ochar_flyin_arms in
-- MKDEATH.ASM).  8 sets cover 17 slots: Raiden borrows Kung Lao's, the
-- female ninjas share NJGIRLARM, the three male ninjas share NJRIPARM.
local ARMS_FOR_OCHAR = {
    [0]='HHRIPARM',  [1]='LKRIPARM',    [2]='CAGERIPARM', [3]='UGRIPARM',
    [4]='NJGIRLARM', [5]='NJGIRLARM',   [6]='TSRIPARM',   [7]='HHRIPARM',
    [8]='NJRIPARM',  [9]='NJRIPARM',    [10]='NJRIPARM',  [11]='JXRIPARM',
    [12]='NJGIRLARM',[13]='NJGIRLARM',  [14]='NJRIPARM',  [15]='NJRIPARM',
    [16]='NJGIRLARM',
}
local WANT_ARMS = ARMS_FOR_OCHAR[VICTIM] or 'NJRIPARM'

local cpu, space = nil, nil
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local fight_count, last_gstate = 0, -1
local p1_confirm_start = 0
local did_direct_select = false
local finish_forced_frame, dizzy_ready_frame = 0, 0
local trigger_frame, fatality_frame = 0, 0
local forced_via_wake, fdeath_seen = false, false
local fighter_verified, fighter_verify_logged = false, false
local victim_dizzy_forced = false
local do_arm_rip_addr = 0
local jax_seen, prop_seen = {}, {}
local props_alive_max = 0
local props_gone_frame = 0
local armrip9_frame = 0
local frame12_first, frame12_last = 0, 0
local prop_min_gap = nil           -- smallest (floor - prop y) seen
local jax_frame_last = nil
local toss_frames_seen = {}
local four_arm_frames = 0
-- Which behaviour the ROM under test has, read out of do_arm_rip itself.
-- 5 jsrp ani_with_arms = retail's toss arc; 3 = the hold.  Anything else
-- means the routine has been rewritten again and this rig does not know what
-- to expect - that is NO VERDICT, so it refuses rather than guessing.
local function read_arm_mode()
    local fh = io.open(ROOT .. "/src/MKDEATH.ASM", "r")
    if not fh then return nil, "cannot read src/MKDEATH.ASM" end
    local inside, calls = false, 0
    for line in fh:lines() do
        if line:match("^do_arm_rip%s*$") then
            inside = true
        elseif inside then
            if line:match("^get_arm_object%s*$") then break end
            if line:match("jsrp%s+ani_with_arms") then calls = calls + 1 end
        end
    end
    fh:close()
    if not inside then return nil, "do_arm_rip not found in src/MKDEATH.ASM" end
    if calls == 5 then return "toss", "5 ani_with_arms (retail toss)" end
    if calls == 3 then return "hold", "3 ani_with_arms (held in his fists)" end
    return nil, string.format("%d jsrp ani_with_arms - neither 5 (toss) nor 3 (hold)", calls)
end

local ARM_MODE, ARM_MODE_INFO = read_arm_mode()

local announce_forced, did_error, finished = false, false, false
local pending_snaps, capture_index = {}, 0

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end
local function w32(addr, value) space:write_u32(addr, value & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local missing = {}
    for name, _ in pairs(wanted) do
        if not fields[name] then missing[#missing + 1] = name end
    end
    if #missing > 0 then log("inputs MISSING: %s", table.concat(missing, ",")) end
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
    capture_index = capture_index + 1
end

local function flush_snaps()
    if #pending_snaps == 0 then return end
    local screen = main_screen()
    for _, request in ipairs(pending_snaps) do
        local ok = false
        if screen then ok = pcall(function() screen:snapshot() end) end
        log("SNAP index=%04d frame=%d label=%s ok=%s",
            request.index, request.frame, request.label, tostring(ok))
    end
    pending_snaps = {}
end

-- Map visible objects back to their authored frame label via the source TBL
-- SAGs.  The test never patches runtime art.
local sag_labels = {}
local function load_sag_labels(path, pattern)
    local fh = io.open(path, "r")
    if not fh then log("WARN cannot open %s for SAG labels", path); return end
    local current, n = nil, 0
    for line in fh:lines() do
        local label = line:match("^([%w_]+):")
        if label then
            current = label:match(pattern)
        elseif current then
            local raw = line:match("%.long%s+([%x]+)H")
            if raw then
                sag_labels[tonumber(raw, 16) & 0x00ffffff] = current
                current = nil
                n = n + 1
            end
        end
    end
    fh:close()
    log("sag labels %-16s pattern=%s -> %d", path:match("[^/]+$"), pattern, n)
end
-- Jax's own frames are multipart; osag exposes only the FIRST queued piece,
-- so key his beats on the leading piece of each wrapper.
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXARMRIP%d+)A$")
-- The victory poses are loaded too, so "he took the a_jxvictory jump" is a
-- LABEL we can see rather than the absence of one: with only the JXARMRIP
-- frames known, jax_frame simply goes nil on the jump and jax_frame_last
-- stays JXARMRIP12 - which reads exactly like the hold.
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXVICTORY%d+)A$")
-- The loose arm props are single objects, so their own SAG identifies them.
load_sag_labels(ROOT .. "/src/MKMK3.TBL", "^(%u+RIPARM%d)$")
load_sag_labels(ROOT .. "/src/MKMK3.TBL", "^(NJGIRLARM%d)$")

log("victim ochar=%d, expecting loose arms from the %s set", VICTIM, WANT_ARMS)
log("arm mode = %s (%s)", tostring(ARM_MODE), tostring(ARM_MODE_INFO))

local function is_prop(label)
    return label:match("RIPARM%d$") ~= nil or label:match("^NJGIRLARM%d$") ~= nil
end

-- Walk the display lists once: return Jax's current frame label, the set of
-- live prop labels, and the lowest (largest y) prop position.
local function scan()
    local jax_frame, props, lo_y = nil, {}, nil
    local nprops = 0
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag1 = r32(obj + O.osag) & 0x00ffffff
            local img = r32(obj + O.oimg)
            local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
            local label = sag_labels[sag1] or sag_labels[sag2]
            if label then
                if is_prop(label) then
                    props[label] = (props[label] or 0) + 1
                    nprops = nprops + 1
                    local y = r16(obj + O.oypos)
                    if y >= 0x8000 then y = y - 0x10000 end
                    if lo_y == nil or y > lo_y then lo_y = y end
                else
                    jax_frame = label
                end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return jax_frame, props, nprops, lo_y
end

local function sorted_labels(set)
    local items = {}
    for label, _ in pairs(set) do items[#items + 1] = label end
    table.sort(items)
    return #items > 0 and table.concat(items, "+") or "-"
end

local function force_select()
    w16(A.p1_char, FT_JAX)
    w16(A.p2_char, VICTIM)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Jax(%d) P2=ochar%d stage=%d", FT_JAX, VICTIM, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    return p1char == FT_JAX and p2char == VICTIM, p1char, p2char
end

local function snap_fatal_range()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local p2x = r16(p2obj + O.oxpos)
    local x = (SIDE == "right") and (p2x + FATAL_X) or (p2x - FATAL_X)
    w16(p1obj + O.oxpos, x)
    w32(p1obj + O.oxval, (x << 16) & 0xffffffff)
end

local function force_finish_him()
    if fight_count ~= 1 or fatality_frame ~= 0 or r16(A.f_death) ~= 0 then return end
    local fighters_ok, p1ochar, p2ochar = loaded_fighters_match()
    if not fighters_ok then
        if not fighter_verify_logged then
            fighter_verify_logged = true
            log("waiting_for_visible_fighters p1=%d p2=%d want=%d/%d",
                p1ochar, p2ochar, FT_JAX, VICTIM)
        end
        return
    end
    if not fighter_verified then
        fighter_verified = true
        log("visible_fighters_verified p1=%d p2=%d", p1ochar, p2ochar)
    end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 720 then return end
    w16(A.winner_status, 3); w16(A.f_death, 0)
    local p1proc = r32(A.p1_proc)
    if p1proc ~= 0 then
        w16(p1proc + P.flags, r16(p1proc + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2proc = r32(A.p2_proc)
    if p2proc ~= 0 and not victim_dizzy_forced then
        snap_fatal_range()
        w32(p2proc + P.wake, A.dizzy_dude)
        victim_dizzy_forced = true
    end
    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        log("finish_him_forced frame=%d rel=%d", frame, rel)
        queue_snap("finish_him_forced")
    end
end

local function victim_ready()
    local proc = r32(A.p2_proc)
    if proc == 0 then return false end
    local wake = r32(proc + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(proc + P.action) == ACT_STUNNED
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
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    return false
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
    if not space or A.system_lockup == 0 or A.tvbp == 0 then return false end
    local pc = cpu_pc()
    if pc and pc >= A.system_lockup and pc < A.tvbp then
        log("ERROR lockup pc=%s", hx(pc))
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
    local hold = (frame12_last > 0) and (frame12_last - frame12_first + 1) or 0
    log("%s mode=%s reason=%s fdeath=%s jax=%s props=%s props_max=%d " ..
        "toss_frames=%s four_arm_frames=%d props_gone=%d armrip9=%d " ..
        "frame12_hold=%d(min %d) min_floor_gap=%s",
        ok and "PASS" or "ERROR", tostring(ARM_MODE), reason, tostring(fdeath_seen),
        sorted_labels(jax_seen), sorted_labels(prop_seen), props_alive_max,
        sorted_labels(toss_frames_seen), four_arm_frames,
        props_gone_frame, armrip9_frame, hold, HOLD_MIN,
        tostring(prop_min_gap))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "required_input_missing"); return end
        if #missing_symbols > 0 then
            log("ERROR unresolved symbols: %s", table.concat(missing_symbols, ","))
            finish(false, "unresolved_symbols")
            return
        end
        -- do_arm_rip is file-local; pull it out of the dispatch table.
        do_arm_rip_addr = r32(A.db2_table + DB2_ARM_RIP * 32)
        log("db2_table=%s db2_table[%d]=do_arm_rip=%s",
            hx(A.db2_table), DB2_ARM_RIP, hx(do_arm_rip_addr))
        log("loaded: P1 Jax vs P2 ochar%d; side=%s stage=%d", VICTIM, SIDE, STAGE_ID)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d", frame, fight_count)
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 then
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_JAX and r16(A.p2_char) == VICTIM then
            p1_confirm_start = frame + 25
        end
    end

    force_finish_him()
    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        dizzy_ready_frame = frame
        trigger_frame = frame + 30
        snap_fatal_range()
        log("victim_dizzy_ready frame=%d; trigger at frame=%d", frame, trigger_frame)
    end

    if trigger_frame > 0 and fatality_frame == 0 and frame < trigger_frame + 40 then
        if (frame - trigger_frame) % 8 == 0 then snap_fatal_range() end
    end

    -- Point P1's wake straight at do_arm_rip; scripted buttons do not reach
    -- the in-fight move dispatch in this MAME build.
    if trigger_frame > 0 and fatality_frame == 0 and not forced_via_wake
        and frame >= trigger_frame + 75 then
        forced_via_wake = true
        local p1proc = r32(A.p1_proc)
        if p1proc ~= 0 and do_arm_rip_addr ~= 0 then
            w32(p1proc + P.wake, do_arm_rip_addr)
            log("forced_fatality_via_wake frame=%d p1proc=%s", frame, hx(p1proc))
            queue_snap("forced_fatality_via_wake")
        else
            log("WARN cannot force via wake p1proc=%s do_arm_rip=%s",
                hx(p1proc), hx(do_arm_rip_addr))
        end
    end

    local fdeath = r16(A.f_death)
    if fdeath ~= 0 and fdeath ~= 0xffff and fatality_frame == 0 then
        fatality_frame = frame
        fdeath_seen = true
        log("fatality_started frame=%d f_death=%d", frame, fdeath)
        queue_snap("fatality_start")
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local jax_frame, props, nprops, lo_y = scan()
        local p1obj = r32(A.p1_obj)
        local jax_y = nil
        if p1obj ~= 0 then
            jax_y = r16(p1obj + O.oypos)
            if jax_y >= 0x8000 then jax_y = jax_y - 0x10000 end
        end

        if jax_frame then
            jax_frame_last = jax_frame
            if not jax_seen[jax_frame] then
                jax_seen[jax_frame] = true
                log("JAXFRAME rel=%d %s props=%d (%s)",
                    rel, jax_frame, nprops, sorted_labels(props))
                queue_snap("jax_" .. jax_frame)
            end
            if jax_frame == "JXARMRIP9" and armrip9_frame == 0 then
                armrip9_frame = frame
            end
            if jax_frame == "JXARMRIP12" then
                if frame12_first == 0 then frame12_first = frame end
                frame12_last = frame
            end
        end

        for label, _ in pairs(props) do
            if not prop_seen[label] then
                prop_seen[label] = true
                log("PROP rel=%d %s", rel, label)
            end
            -- RIPARM4/RIPARM5 are the two frames whose anipoints put the arm
            -- on the floor.  Reaching either means the toss is back.
            if label:match("4$") or label:match("5$") then
                toss_frames_seen[label] = true
            end
        end

        if nprops > props_alive_max then props_alive_max = nprops end
        -- The extra pieces in frames 9-12 are HIS OWN forearms, so both
        -- props have to still be alive there or he raises empty fists.
        if jax_frame == "JXARMRIP12" and nprops >= 2 then
            four_arm_frames = four_arm_frames + 1
        end
        if nprops == 0 and props_alive_max > 0 and props_gone_frame == 0 then
            props_gone_frame = frame
            log("props_retired rel=%d", rel)
        end
        if lo_y and jax_y then
            local gap = lo_y - jax_y
            if prop_min_gap == nil or gap > prop_min_gap then prop_min_gap = gap end
        end

        if csvfh and rel <= CAPTURE_UNTIL then
            csvfh:write(string.format("%d,%d,%d,%s,%d,%s,%s,%s,%s\n",
                frame, rel, fdeath, jax_frame or "-", nprops,
                sorted_labels(props), tostring(lo_y), tostring(jax_y),
                tostring(lo_y and jax_y and (lo_y - jax_y) or "na")))
            csvfh:flush()
        end

        if check_lockup() then finish(false, "lockup"); return end

        if rel > CAPTURE_UNTIL then
            local ok, reason = true, "complete"
            -- Shared by both modes.
            if props_alive_max < 2 then ok, reason = false, "props_never_appeared" end
            if not jax_seen["JXARMRIP12"] then ok, reason = false, "no_frame12" end

            if ARM_MODE == "hold" then
                if next(toss_frames_seen) ~= nil then ok, reason = false, "arms_still_tossed" end
                if four_arm_frames < 10 then ok, reason = false, "props_dropped_before_pose" end
                -- The pose is the finish: he never takes the a_jxvictory
                -- jump, so both arms must still be in his hands at the close.
                if props_gone_frame ~= 0 then ok, reason = false, "props_retired_early" end
                if jax_frame_last ~= "JXARMRIP12" then ok, reason = false, "left_frame12" end
                local hold = frame12_last - frame12_first + 1
                if frame12_first > 0 and hold < HOLD_MIN then ok, reason = false, "frame12_not_held" end
            elseif ARM_MODE == "toss" then
                -- Retail walks the props the whole arc and then runs on into
                -- the victory pose.  Both halves are REQUIRED, because the
                -- toss arc alone would also be drawn by a hold version whose
                -- pin failed, and the victory jump alone by one whose props
                -- were never created.
                -- toss_frames_seen is keyed by the FULL record name
                -- (HHRIPARM5, JXRIPARM4, NJGIRLARM5, ...), so the test is
                -- "any of the late frames was drawn", not a fixed key.
                if next(toss_frames_seen) == nil then
                    ok, reason = false, "toss_arc_not_drawn"
                end
                if jax_frame_last == nil or not jax_frame_last:match("^JXVICTORY") then
                    ok, reason = false, "victory_jump_not_taken"
                end
            else
                -- NO VERDICT: do not pass, do not fail the game.
                finish(false, "unknown_arm_mode:" .. tostring(ARM_MODE_INFO))
                return
            end
            finish(ok, reason)
            return
        end
    end

    if frame > 9000 then finish(false, "timeout"); return end
    if not announce_forced and frame % 600 == 0 then
        log("status frame=%d gstate=%d fatality=%d", frame, gs, fatality_frame)
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
    flush_snaps()
end)
