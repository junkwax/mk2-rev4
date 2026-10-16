-- baraka_decap_frames_test.lua - Baraka's head-cut fatality, frame by frame.
--
--   Back, Back, Back, Back + HP during FINISH HIM, inside 0x63 (99px).
--   sa_hi_punch -> scom_sa_decap -> do_fatality_1 -> db1_table[3] = do_decap.
--
-- The question is the same one swipe_frames_test.lua asks about the SPECIAL,
-- and for the same reason: do_decap borrows the special's lane (sa_anitab2
-- slot 1, a_swipe) and walks PART ONE with a bare mframew.  When the special
-- was retimed, UGSWIPE4 - the follow-through - moved out of part one and into
-- part two, and the fatality silently stopped drawing it: the blade sat
-- extended and then jumped to the victory pose.
--
-- So this rig reports the RUN LENGTH of every distinct pose Baraka wears from
-- the moment f_death goes live, and PASSES only if UGSWIPE4 is one of them.
--
-- Env:
--   BDF_LOG=path     log path
--   BDF_SNAP_X=n     range to pin P1 at while the input goes in (default 60)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("BDF_LOG") or (ROOT .. "/tools/baraka_decap_frames_test.log")
local SNAP_X = tonumber(os.getenv("BDF_SNAP_X") or "") or 60

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[#p + 1] = tostring(select(i, ...)) end
    local line = table.concat(p, "\t")
    raw_print(line); if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    print("[bdf] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end
local function hx(v) if v == nil then return "na" end return string.format("0x%08x", v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                if symbols[name] == nil then symbols[name] = tonumber(addr, 16) end
            end
        end
        fh:close()
    end
end
local function sym(n) local v = symbols[n]; if not v then log("WARN missing symbol %s", n) end; return v or 0 end

local A = {
    gstate = sym("gstate"), active = sym("active"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"), dizzy = sym("dizzy"),
}
local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0,
            oflags = 0x0f0, oimg = 0x1a0, ochar = 0x1f0 }
local P = { next = 0x000, wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_SA, FT_JAX = 3, 11
local STAGE_ID = 5              -- Armory: no stage fatality to contend with
local FATAL_NUM = 1             -- init_death_blow a1 for do_decap
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

-- The poses of a_swipe, by the SAG of their first multipart piece
-- (src/MKSA2.TBL).  UGSWIPE4 is the one this rig exists to look for.
local POSE = {
    [0x010a2e64] = "UGSWIPE1", [0x010aa2da] = "UGSWIPE2",
    [0x010b0922] = "UGSWIPE3", [0x010b809a] = "UGSWIPE4",
}

local cpu, space, fields = nil, nil, {}
local frame, last_gstate = 0, -1
local charsel_frame, fighting_frame, fight_count = 0, 0, 0
local p1_confirm_start, finish_forced_frame = 0, 0
local drained, input_start, fatal_frame, fatal_end = false, 0, 0, 0
local runs, last_sag, run_len = {}, nil, 0
local finished, attempts = false, 0
local ko1_logged = -1

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function pose_sag()
    local o = r32(A.p1_obj)
    if o == 0 then return 0 end
    local chain = r32(o + O.oimg)
    if chain == 0 then return 0 end
    return r32(chain)
end

local function gap()
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return -1 end
    return math.abs(s16(r16(b + O.oxpos)) - s16(r16(a + O.oxpos)))
end

local function state(tag)
    return string.format("%s gs=%d ws=%d fdeath=%d p1hp=%d p2hp=%d dx=%d sag=%s",
        tag, r16(A.gstate), r16(A.winner_status), s16(r16(A.f_death)),
        r16(A.p1_bar), r16(A.p2_bar), gap(), hx(pose_sag()))
end

local function finish(ok, why)
    if finished then return end
    finished = true
    if last_sag and run_len > 0 then runs[#runs + 1] = { last_sag, run_len } end
    print("")
    log("===== POSES =====")
    local seen4, total = false, 0
    for i, r in ipairs(runs) do
        total = total + r[2]
        local name = POSE[r[1]] or POSE[r[1] & 0x00ffffff]
        if name == "UGSWIPE4" then seen4 = true end
        log("  %2d  sag=%s  %3d ticks  %s", i, hx(r[1]), r[2], name or "(other)")
    end
    log("  total %d ticks over %d runs", total, #runs)
    log("  UGSWIPE4 (the follow-through) drawn: %s", seen4 and "YES" or "NO")
    if ok and not seen4 then ok, why = false, "follow_through_missing" end
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", why, state("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true,
                   ["P1 Left"] = true, ["P1 Right"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    local ok = true
    for n in pairs(want) do if not fields[n] then log("input %-16s MISSING", n); ok = false end end
    return ok
end

local function fighters_ok()
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    return a ~= 0 and b ~= 0 and r16(a + O.ochar) == FT_SA and r16(b + O.ochar) == FT_JAX
end

local function snap_range()
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return end
    local x = r16(b + O.oxpos) - SNAP_X
    w16(a + O.oxpos, x)
    w32(a + O.oxval, (x << 16) & 0xffffffff)
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 or A.dizzy == 0 then return false end
    local w = r32(p + P.wake)
    return w >= A.dizzy and w < (A.dizzy + 0x120)
end

-- Back x4 then HP.  P1 is on the left, so Back = P1 Left.  A 6-frame cadence
-- keeps all four taps plus the punch inside scom_sa_decap's 0x38 window.
local TAP_ON, TAP_OFF, TAPS = 3, 3, 4
local function drive_input(rel)
    local cycle = TAP_ON + TAP_OFF
    local left, hp = false, false
    if rel < TAPS * cycle then
        left = (rel % cycle) < TAP_ON
    elseif rel < TAPS * cycle + 6 then
        hp = (rel - TAPS * cycle) < 3
    end
    fields["P1 Left"]:set_value(left and 1 or 0)
    fields["P1 High Punch"]:set_value(hp and 1 or 0)
end

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing") return end
        log("Baraka decap (B,B,B,B+HP) frame probe; snap_x=%d", SNAP_X)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if frame % 300 == 0 and fatal_frame == 0 then
        log("hb frame=%d fight=%d drained=%s in=%d | %s",
            frame, fight_count, tostring(drained), input_start, state("hb"))
    end
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d | %s", frame, fight_count, state("fs"))
        end
        last_gstate = gs
    end

    -- attract / select
    if fighting_frame == 0 then
        w16(A.p1_char, FT_SA); w16(A.p2_char, FT_JAX); w16(A.curback, STAGE_ID)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
           and r16(A.p1_char) == FT_SA and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
        for name, f in pairs(fields) do
            local v = 0
            if charsel_frame == 0 then
                if name == "Coin 1" or name == "Coin 2" then
                    v = (frame >= 220 and frame < 6000 and (frame % 80) < 20) and 1 or 0
                elseif name == "2 Players Start" then
                    v = (frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55) and 1 or 0
                end
            elseif p1_confirm_start > 0 then
                if name == "P1 High Punch" then
                    v = (frame >= p1_confirm_start and frame < p1_confirm_start + 40) and 1 or 0
                elseif name == "P2 High Punch" then
                    v = (frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120) and 1 or 0
                end
            end
            f:set_value(v)
        end
        return
    end

    if fatal_frame == 0 then
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "P2 High Punch" }) do
            if fields[n] then fields[n]:set_value(0) end
        end
        if not fighters_ok() then
            if frame > 9000 then finish(false, "never_got_the_fighters") end
            return
        end
        if frame - fighting_frame < 120 then return end

        -- round one: just KO him so round two is the finish-him round
        if fight_count < 2 then
            if r16(A.p2_bar) > 0 then
                w16(A.p2_bar, 0)
                -- Once per round, not once per frame: the between-round
                -- refill walks p1_bar back up over ~80 frames and every one
                -- of them re-enters here.
                if ko1_logged ~= fight_count then
                    ko1_logged = fight_count
                    log("round1_ko frame=%d | %s", frame, state("ko1"))
                end
            end
            return
        end

        if not drained then
            snap_range()
            w16(A.p2_bar, 0)
            drained = true
            log("drained frame=%d | %s", frame, state("kill"))
            return
        end

        local pp = r32(A.p1_proc)
        if pp ~= 0 then
            w16(pp + P.flags, r16(pp + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
        end
        if finish_forced_frame == 0 and r16(A.winner_status) == 3 then
            finish_forced_frame = frame
            log("finish_him frame=%d | %s", frame, state("ff"))
        end
        if input_start == 0 and finish_forced_frame > 0 and victim_ready() then
            input_start = frame
            snap_range()
            log("input_start frame=%d | %s", frame, state("in"))
        end

        if input_start > 0 then
            if r16(A.winner_status) ~= 3 then w16(A.winner_status, 3) end
            snap_range()                     -- Back walks him away; hold range
            local rel = frame - input_start
            drive_input(rel)
            if rel > 40 then                 -- that attempt did not take; retry
                attempts = attempts + 1
                input_start = frame
                if attempts > 8 then finish(false, "fatality_never_triggered") end
            end
        end

        if s16(r16(A.f_death)) == FATAL_NUM then
            fatal_frame = frame
            log("FATALITY LIVE frame=%d attempts=%d | %s", frame, attempts, state("go"))
        end
        if frame > 20000 then finish(false, "global_timeout") end
        return
    end

    -- fatality live: record what he is wearing, tick by tick
    for _, f in pairs(fields) do f:set_value(0) end
    local rel = frame - fatal_frame
    local sag = pose_sag()
    if sag == last_sag then run_len = run_len + 1
    else
        if last_sag then runs[#runs + 1] = { last_sag, run_len } end
        last_sag = sag; run_len = 1
        log("rel=%-4d pose -> %s %s", rel, hx(sag), POSE[sag] or POSE[sag & 0x00ffffff] or "")
    end

    if fatal_end == 0 and s16(r16(A.f_death)) ~= FATAL_NUM then
        fatal_end = frame
        log("death_blow_complete rel=%d | %s", rel, state("done"))
    end
    if fatal_end > 0 and frame - fatal_end > 60 then
        finish(true, string.format("completed_in_%d_ticks", fatal_end - fatal_frame))
    end
    if fatal_end == 0 and rel > 900 then finish(false, "fatality_hung") end
end

emu.register_frame(function()
    if finished then return end
    local ok, err = pcall(on_frame)
    if not ok then log("LUA ERROR frame=%d: %s", frame, tostring(err)); finish(false, "harness_lua_error") end
end)
log("loaded")
