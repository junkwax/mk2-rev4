-- kham_moves_test.lua
--
-- Drive every one of KHAMELEON's specials and check each one actually
-- reaches its move.  She is the UNION of the three female ninjas, so this
-- is the check that the merge did not lose or shadow anything: Kitana's
-- four, Mileena's three and Jade's five all live on four buttons, and the
-- ONLY reason they coexist is that no two share a motion.  A regression
-- here looks like "one move stopped coming out", not like a crash.
--
-- Structure and input plumbing follow tools/jade_boomerang_test.lua.  Like
-- that rig it reaches a hidden fighter by picking her BASE character at the
-- select screen and overwriting p1_char at GS_POST - forcing the id at
-- GS_PSEL never confirms.
--
-- The drone is pinned to difficulty 0 so it stands still: an opponent that
-- interrupts a startup turns a passing move into a spurious failure.  Both
-- bars are topped up so the round cannot end mid-script.
--
--   KHAM_MOVES_LOG   log file path

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("KHAM_MOVES_LOG") or (ROOT .. "/tools/kham_moves_test.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[kham-moves] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), diff = sym("diff"),
    p1_proc = sym("p1_proc"), p1_char = sym("p1_char"), p1_bar = sym("p1_bar"),
    p2_char = sym("p2_char"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
}
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k) end end

local P_ACTION = 0x1f0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_JAX, FT_KHAM, MAX_HP = 4, 11, 18, 0xa1

-- The action each special settles into.  Sources: MAINEQU.ASM act_* equates,
-- confirmed against the routine that sets them.
local ACT = {
    square    = 0x207,   -- do_square_wave      (Kitana)
    fanlift   = 0x12c,   -- do_fn_spinfan  -> act_sonic
    fanthrow  = 0x008,   -- do_throw_fans  -> act_throw_fans
    boom      = 0x112,   -- do_jade_boom*  -> act_jade_boom
    flash     = 0x115,   -- do_jade_flash  -> act_jade_flash
    roll      = 0x20e,   -- do_fn2_kano    -> act_kano       (Mileena)
    teleport  = 0x208,   -- do_fn2_teleport-> act_fntele     (Mileena)
    nitro     = 0x205,   -- do_fn1_nitro   -> act_shadk
    spinchop  = 0x111,   -- do_fn1_spinchop-> act_fnspinchop
    sai       = 0x00a,   -- do_throw_sai   -> act_throw_tsai (Mileena)
}

-- Directions are written as FWD / BACK and resolved to a real stick input
-- at the moment each test starts, from the two fighters' x positions.
--
-- THIS IS NOT PEDANTRY.  The first version of this rig hardcoded
-- forward=Right, and the square wave - a travelling move - carried her from
-- x=484 to x=744, straight past an opponent parked at 655.  Every test after
-- it was then entered in the wrong facing and read as a failure: eleven
-- "missing" specials, all of them actually fine.  A rig that drives motions
-- must know which way the fighter is pointing, and it can only know that
-- after the previous move has finished moving her.
--
-- Each entry: at = frames after the fight starts; seq = {input, from, to}.
-- Spacing is ~120 frames: longer than the widest combo window (0x30 = 48
-- ticks) so a previous motion cannot bleed into the next, and long enough
-- for the recovery/sitting-duck state to end.
local TESTS = {
    { at =  120, label = "square_wave      F,D,B+HP", want = ACT.square,
      seq = { {"FWD",0,5}, {"P1 Down",7,12}, {"BACK",14,19}, {"P1 High Punch",21,27} } },
    { at =  260, label = "fan_lift         B,B,B+HP", want = ACT.fanlift,
      seq = { {"BACK",0,5}, {"BACK",7,12}, {"BACK",14,19}, {"P1 High Punch",21,27} } },
    { at =  380, label = "boomerang_hi     B,F+HP",   want = ACT.boom,
      seq = { {"BACK",0,5}, {"FWD",7,12}, {"P1 High Punch",14,20} } },
    { at =  500, label = "boomerang_flat   B,F+LP",   want = ACT.boom,
      seq = { {"BACK",0,5}, {"FWD",7,12}, {"P1 Low Punch",14,20} } },
    { at =  620, label = "boomerang_return B,B,F+LP", want = ACT.boom,
      seq = { {"BACK",0,5}, {"BACK",7,12}, {"FWD",14,19}, {"P1 Low Punch",21,27} } },
    { at =  740, label = "boomerang_lo     B,F+LK",   want = ACT.boom,
      seq = { {"BACK",0,5}, {"FWD",7,12}, {"P1 Low Kick",14,20} } },
    { at =  880, label = "jade_flash       B,F+HK",   want = ACT.flash,
      seq = { {"BACK",0,5}, {"FWD",7,12}, {"P1 High Kick",14,20} } },
    { at = 1020, label = "ground_roll      B,B,D+HK", want = ACT.roll,
      seq = { {"BACK",0,5}, {"BACK",7,12}, {"P1 Down",14,19}, {"P1 High Kick",21,27} } },
    { at = 1160, label = "teleport_kick    F,F+LK",   want = ACT.teleport,
      seq = { {"FWD",0,5}, {"FWD",7,12}, {"P1 Low Kick",14,20} } },
    { at = 1320, label = "nitro_kick       D,F+LK",   want = ACT.nitro,
      seq = { {"P1 Down",0,5}, {"FWD",7,12}, {"P1 Low Kick",14,20} } },
    { at = 1460, label = "spin_chop        BLK+F,F",  want = ACT.spinchop,
      seq = { {"P1 Block",0,34}, {"FWD",8,13}, {"FWD",16,21} } },
    -- Kitana's fan throw is High Punch AND Low Punch together (two_button_check
    -- with the partner press within a couple of ticks), on Forward,Forward.
    { at = 1600, label = "fan_throw        F,F+HP+LP", want = ACT.fanthrow,
      seq = { {"FWD",0,5}, {"FWD",7,12}, {"P1 High Punch",14,22}, {"P1 Low Punch",15,22} } },
    -- Mileena's sai is the ONE move on the button-RELEASE path: hold High
    -- Punch for at least 022h ticks, then let go.  This is also the move
    -- whose animation lanes were relocated to 0ch-0eh of fn4_anitab2, so it
    -- is the single most likely thing in the merge to be silently wrong.
    { at = 1740, label = "sai_throw        hold HP",  want = ACT.sai,
      seq = { {"P1 High Punch",0,60} } },
}
local WINDOW = 100        -- frames after `at` to watch for the wanted action
local RUN_END = 1950

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local results, failures = {}, 0
local last_act = nil
-- facing latched once per test, at d == 0, and held for that test's whole
-- sequence: re-reading it every frame would flip mid-motion on a move that
-- carries her across the opponent, which is the bug this replaced.
local facing = {}

local function resolve(tok, label)
    if tok ~= "FWD" and tok ~= "BACK" then return tok end
    local right = facing[label]
    if right == nil then right = true end
    if tok == "FWD" then return right and "P1 Right" or "P1 Left" end
    return right and "P1 Left" or "P1 Right"
end

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end

local function obj_x(p)
    local o = r32(p); if o == 0 then return -1 end
    return r16(o + 0x90)
end

local function p1_action()
    local proc = r32(A.p1_proc)
    if proc == 0 then return 0xffff end
    return r16(proc + P_ACTION)
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- results ----")
    for _, t in ipairs(TESTS) do
        local r = results[t.label]
        log("%-28s %s", t.label, r or "NOT REACHED")
    end
    log("%s reason=%s failures=%d", ok and "PASS" or "FAIL", reason, failures)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Right"] = true, ["P1 Left"] = true, ["P1 Up"] = true, ["P1 Down"] = true,
        ["P1 High Punch"] = true, ["P1 Low Punch"] = true,
        ["P1 Low Kick"] = true, ["P1 High Kick"] = true, ["P1 Block"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %-16s MISSING", name) end
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end
    local r = frame - fighting_frame
    for _, t in ipairs(TESTS) do
        local d = r - t.at
        for _, sq in ipairs(t.seq) do
            if name == resolve(sq[1], t.label) and d >= sq[2] and d < sq[3] then return true end
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("harness loaded, %d specials to drive", #TESTS)
    end
    if not space or finished then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_KITANA)
        w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d (hovering Kitana)", frame)
        end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_KHAM)      -- the hidden id only takes here
        w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
        if r16(A.p1_char) ~= FT_KHAM then
            finish(false, "p1_char_overwrite_failed"); return
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end          -- drone stands still
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)

        local act = p1_action()
        if act ~= last_act then
            log("  r=%4d p1act 0x%04x -> 0x%04x  x: p1=%d p2=%d",
                r, last_act or 0, act, obj_x(A.p1_obj), obj_x(A.p2_obj))
            last_act = act
        end
        for _, t in ipairs(TESTS) do
            local d = r - t.at
            if d == 0 and facing[t.label] == nil then
                local p1x, p2x = obj_x(A.p1_obj), obj_x(A.p2_obj)
                facing[t.label] = (p1x <= p2x)
                log("%-28s facing %s (p1=%d p2=%d)", t.label,
                    facing[t.label] and "right" or "left", p1x, p2x)
            end
            if d >= 0 and d < WINDOW and not results[t.label] then
                if act == t.want then
                    results[t.label] = string.format("OK   action=0x%03x at +%d", act, d)
                    log("%-28s OK   action=0x%03x at +%d", t.label, act, d)
                end
            elseif d == WINDOW and not results[t.label] then
                results[t.label] = string.format("FAIL wanted 0x%03x, last seen 0x%03x", t.want, act)
                failures = failures + 1
                log("%-28s FAIL wanted 0x%03x, saw 0x%03x", t.label, t.want, act)
            end
        end
        if r > RUN_END then
            finish(failures == 0, failures == 0 and "all_specials_reached" or "specials_missing")
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 6000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
