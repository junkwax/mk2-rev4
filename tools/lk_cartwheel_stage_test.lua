-- lk_cartwheel_stage_test.lua
--
-- Liu Kang's cartwheel (do_wheel_kick) + LP+LK held = the stage fatality.
--
-- Drives the real input (D, F, U, B, D - lk_down, MOVES.ASM) during a forced
-- FINISH HIM, then holds LP+LK once the fatality has started (f_death != 0).
-- wk_stage_arm (MKDEATH.ASM) reads the held buttons before the killer
-- uppercut and hands the victim his stage action; r_lk_dbuc forwards it.
--
--   CW_STAGE=deadpool|pit|tomb|tor
--   CW_HOLD=1  PASS = that stage's payoff happened
--   CW_HOLD=0  PASS = it did NOT, and the plain cartwheel completed (f_death -1)
--
-- Payoffs, each observed on the machine rather than inferred from a flag the
-- rig could have set itself:
--   deadpool  victim p_action act_slime_fall (050ah) and f_death -1 at the end
--   pit       gstate gs_pitfall (9)
--   tomb      victim rises >= 150 rows (r_spike_rise flies him to the ceiling)
--   tor       victim drops >= 300 rows (r_fall_off_mountain, 756 to the sea)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("CW_TEST_LOG") or (ROOT .. "/tools/lk_cartwheel_stage_test.log")
local STAGE_NAME = (os.getenv("CW_STAGE") or "deadpool"):lower()
local HOLD = (os.getenv("CW_HOLD") or "1") ~= "0"
-- The cartwheel flies ~150px toward him (8 px/tick for ~19 ticks) and then
-- needs to be within 048h, so start about one flight away.
local GAP = tonumber(os.getenv("CW_GAP") or "") or 150

local ATTEMPT_LEN = 100   -- ticks per cartwheel attempt; force_finish reads it too

local STAGES = { deadpool = 0, tomb = 1, pit = 6, tor = 0x18 }
local STAGE = STAGES[STAGE_NAME]

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local function log(fmt, ...)
    local line = "[cwstage] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

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
    end
end
local missing = {}
local function sym(name)
    local v = symbols[name]
    if v == nil then missing[#missing + 1] = name; return 0 end
    return v
end

local A = {
    gstate = sym("gstate"), p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"), f_fatal_lock = sym("f_fatal_lock"), f_pit_fall = sym("f_pit_fall"),
    dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
    p1_jcq = sym("p1_jcq"), tick = sym("tick"),
    f_no_violence = sym("f_no_violence"), f_no_blood = sym("f_no_blood"),
}
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, ochar = 0x1f0 }
local P = { wake = 0x0e0, action = 0x1f0, flags = 0x210 }
local GS_PSEL, GS_FIGHTING, GS_PITFALL, PS_ACTIVE = 4, 2, 9, 1
local FT_KANG, FT_JAX = 1, 11
local ACT_STUNNED = 0x0400
local STAGE_ACTS = { [0x050a] = "slime", [0x0506] = "pit", [0x0508] = "spike", [0x050c] = "mtn" }
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

local space, fields = nil, {}
local last_gstate, charsel_frame, fighting_frame, p1_confirm_start = -1, 0, 0, 0
local dizzy_forced, ready_frame, attempt_start, attempt_n = false, 0, 0, 0
local pin_vx = nil
local trigger_frame, start_y, min_y, max_y = 0, nil, nil, nil
local stage_act_seen, pitfall_seen, finished = nil, false, false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function snap()
    pcall(function() manager.machine.screens[":screen"]:snapshot() end)
end

local function p2_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state()
    local v = r32(A.p2_obj)
    local a = r32(A.p1_obj)
    return string.format("gs=%d ws=%d f_death=%d lock=%d pitfall=%d p2act=0x%04x atk_x=%d vic_x=%d vic_y=%d",
        r16(A.gstate), r16(A.winner_status), s16(r16(A.f_death)), r16(A.f_fatal_lock),
        r16(A.f_pit_fall), p2_action(),
        a ~= 0 and r16(a + O.oxpos) or -1, v ~= 0 and r16(v + O.oxpos) or -1,
        v ~= 0 and s16(r16(v + O.oypos)) or -1)
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap()
    log("RESULT %s stage=%s hold=%d reason=%s attempts=%d stage_act=%s pitfall=%s y=%s..%s start_y=%s | %s",
        ok and "PASS" or "FAIL", STAGE_NAME, HOLD and 1 or 0, reason, attempt_n,
        tostring(stage_act_seen), tostring(pitfall_seen), tostring(min_y), tostring(max_y),
        tostring(start_y), state())
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["Coin 1"] = 1, ["Coin 2"] = 1, ["2 Players Start"] = 1,
        ["P1 High Punch"] = 1, ["P2 High Punch"] = 1, ["P1 Low Punch"] = 1,
        ["P1 Low Kick"] = 1, ["P1 Down"] = 1, ["P1 Up"] = 1, ["P1 Left"] = 1, ["P1 Right"] = 1,
        ["P1 Block"] = 1 }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %s MISSING", name); return false end
    end
    return true
end

local function fighters_ok()
    local a, v = r32(A.p1_obj), r32(A.p2_obj)
    return a ~= 0 and v ~= 0 and r16(a + O.ochar) == FT_KANG and r16(v + O.ochar) == FT_JAX
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

-- FINISH HIM with the victim dizzy, attacker GAP to his RIGHT (facing left).
-- Only until the fatality starts: after that the machine is on its own.
local function force_finish()
    w16(A.winner_status, 3)
    w16(A.f_death, 0)
    w16(A.f_fatal_lock, 0)
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then
        w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2p = r32(A.p2_proc)
    if p2p ~= 0 and not dizzy_forced then
        w32(p2p + P.wake, A.dizzy_dude)
        dizzy_forced = true
    end
    -- Pin only BEFORE the final Down.  The cartwheel is a flight of ~150px,
    -- and a pin written while it flies drags him back and turns every attempt
    -- into kang_death_miss - which is what the first runs measured.
    if attempt_start > 0 and frame >= attempt_start
        and (frame - attempt_start) % ATTEMPT_LEN >= 27 then
        return
    end
    local a, v = r32(A.p1_obj), r32(A.p2_obj)
    if pin_vx == nil then pin_vx = r16(v + O.oxpos) end
    w16(v + O.oxpos, pin_vx); w32(v + O.oxval, pin_vx << 16)
    w16(a + O.oxpos, pin_vx + GAP); w32(a + O.oxval, (pin_vx + GAP) << 16)
end

-- Facing LEFT, so D,F,U,B,D is Down, Left, Up, Right, Down.  4 on / 3 off:
-- the scanner diffs port-to-port, and a 2-tick gap was not a new closure.
-- The span is 28 ticks against scom_lk_db2's 32; the last Down fires lk_down.
--
-- BLOCK is held through the first four.  The stance loop (joy_entry, JOY.ASM)
-- starts a jump the tick it sees Up, and restricted_xfer refuses an airborne
-- caller - so an Up tap from stance eats the fatality.  Block is checked
-- first, which keeps him on the ground, and the closure still reaches the
-- queue.  It is let go three ticks before the final Down because button_mask
-- refuses a combo while it is held.
local SEQ = {
    { 0, 4, "P1 Down" }, { 7, 11, "P1 Left" }, { 14, 18, "P1 Up" },
    { 21, 25, "P1 Right" }, { 28, 32, "P1 Down" },
}
local BLOCK_UNTIL = 25
local function stick_for(name, rel)
    if name == "P1 Block" then return rel < BLOCK_UNTIL end
    for _, s in ipairs(SEQ) do
        if s[3] == name and rel >= s[1] and rel < s[2] then return true end
    end
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
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    if trigger_frame > 0 then
        -- the modifier: held from the moment the fatality starts
        return HOLD and (name == "P1 Low Punch" or name == "P1 Low Kick")
    end
    if attempt_start > 0 and frame >= attempt_start then
        return stick_for(name, (frame - attempt_start) % ATTEMPT_LEN)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if STAGE == nil then finish(false, "unknown_stage_" .. STAGE_NAME); return end
        if #missing > 0 then finish(false, "missing_symbols_" .. table.concat(missing, ",")); return end
        if not cache_fields() then finish(false, "input_missing"); return end
        log("stage=%s curback=%d hold=%d gap=%d", STAGE_NAME, STAGE, HOLD and 1 or 0, GAP)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        if gs == GS_PITFALL then pitfall_seen = true end
        log("gstate %d->%d frame=%d", last_gstate, gs, frame)
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX); w16(A.curback, STAGE)
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_ACTIVE)
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90 then
            p1_confirm_start = frame + 25
        end
    elseif trigger_frame == 0 then
        if fighters_ok() and frame - fighting_frame >= 90 then
            -- f_fatal_lock, not f_death: do_wheel_kick raises f_death in
            -- init_death_blow and clears it again on the SAME tick, so a
            -- once-a-frame read never sees it.  The lock stays up all round.
            if (r16(A.f_fatal_lock) ~= 0 or r16(A.f_death) ~= 0) and attempt_start > 0 then
                trigger_frame = frame
                local v = r32(A.p2_obj)
                start_y = s16(r16(v + O.oypos)); min_y = start_y; max_y = start_y
                log("TRIGGER frame=%d attempt=%d | %s", frame, attempt_n, state())
                snap()
            else
                force_finish()
                if attempt_start == 0 and victim_ready() then
                    ready_frame = frame
                    attempt_start = frame + 10
                    log("victim dizzy frame=%d | %s", frame, state())
                end
                -- what LK is doing around the final Down: a jump or a refusal
                -- shows up here instead of as a silent "never triggered"
                if attempt_start > 0 and frame >= attempt_start then
                    local r = (frame - attempt_start) % ATTEMPT_LEN
                    if r == 16 or r == 20 or r == 26 or r == 29 or r == 31 or r == 34 then
                        local p1p, a = r32(A.p1_proc), r32(A.p1_obj)
                        log("  rel=%d p1act=0x%04x p1y=%d | %s", r,
                            p1p ~= 0 and r16(p1p + P.action) or 0xffff,
                            a ~= 0 and s16(r16(a + O.oypos)) or -1, state())
                    end
                    -- the joystick CLOSE queue, newest first, as combo_look_lr
                    -- walks it: [stamp|switch : time].  5=U 6=D 7=L 8=R,
                    -- stamp 8000 = made facing left.
                    -- every input fatality_xfer / restricted_xfer tests, on the
                    -- frames the final Down closes
                    if r == 27 or r == 28 or r == 29 or r == 30 then
                        local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
                        local a, v = r32(A.p1_obj), r32(A.p2_obj)
                        log("  gate rel=%d nov=%d noblood=%d ws=%d fdeath=%d lock=%d p1flags=0x%04x p2wake=%08x dizzy=%08x dist=%d p1y=%d p2y=%d",
                            r, r16(A.f_no_violence), r16(A.f_no_blood), r16(A.winner_status),
                            s16(r16(A.f_death)), r16(A.f_fatal_lock),
                            p1p ~= 0 and r16(p1p + P.flags) or 0xffff,
                            p2p ~= 0 and r32(p2p + P.wake) or 0, A.dizzy,
                            math.abs(r16(a + O.oxpos) - r16(v + O.oxpos)),
                            s16(r16(a + O.oypos)), s16(r16(v + O.oypos)))
                    end
                    if r == 31 and A.p1_jcq ~= 0 then
                        local top = A.p1_jcq
                        local p = r32(top)
                        local now = r16(A.tick)
                        local out = {}
                        for i = 1, 8 do
                            p = p - 32
                            if p <= top then p = p + 32 * 20 end
                            local e = r32(p)
                            local sw = (e >> 16) & 0x7fff
                            local face = ((e >> 31) & 1) == 1 and "L" or "R"
                            local age = (now - (e & 0xffff)) & 0xffff
                            out[#out + 1] = string.format("%d%s@-%d", sw, face, age)
                        end
                        log("  jcq newest-first: %s  (tick=%d)", table.concat(out, " "), now)
                    end
                end
                if attempt_start > 0 and frame >= attempt_start and (frame - attempt_start) % ATTEMPT_LEN == 0 then
                    attempt_n = attempt_n + 1
                    log("cartwheel attempt %d frame=%d | %s", attempt_n, frame, state())
                    if attempt_n > 6 then finish(false, "cartwheel_never_triggered"); return end
                end
            end
        end
    else
        local rel = frame - trigger_frame
        local v = r32(A.p2_obj)
        if v ~= 0 then
            local y = s16(r16(v + O.oypos))
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end
        end
        local act = p2_action()
        if STAGE_ACTS[act] and not stage_act_seen then
            stage_act_seen = STAGE_ACTS[act]
            log("stage action %s rel=%d | %s", stage_act_seen, rel, state())
            snap()
        end
        if rel % 60 == 0 then log("obs rel=%d | %s", rel, state()) end
        if rel == 150 or rel == 300 then snap() end

        if rel >= 700 then
            local payoff
            if STAGE_NAME == "deadpool" then
                payoff = stage_act_seen == "slime" and act == 0x050a and s16(r16(A.f_death)) == -1
            elseif STAGE_NAME == "pit" then
                payoff = pitfall_seen
            elseif STAGE_NAME == "tomb" then
                payoff = start_y - min_y >= 150
            else
                payoff = max_y - start_y >= 300
            end
            if HOLD then
                if payoff then finish(true, "stage_fatality_performed")
                else finish(false, "no_stage_payoff") end
            else
                if payoff or stage_act_seen then finish(false, "stage_fatality_without_the_buttons")
                elseif s16(r16(A.f_death)) ~= -1 then finish(false, "plain_cartwheel_did_not_complete")
                else finish(true, "plain_cartwheel") end
            end
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if fighting_frame == 0 and frame > 9000 then finish(false, "never_reached_fight")
    elseif frame > 22000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:close(); logfh = nil end
end)
