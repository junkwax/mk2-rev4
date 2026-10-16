-- freeze_lock_reset_test.lua
--
-- Guards "one air freeze per airborne state" for Sub-Zero.
--
-- MKZAP documented a `freeze_juggle_ok` routine that was never written, so the
-- only limiter on the air freeze was the raw clock in sz_lo_punch:
--     freeze_cooldown .set 0200h      -- 512 ticks, ~8.5 SECONDS of wall time
-- gated on `is_he_airborn`.  Nothing reset it when the victim landed, so he
-- could land, walk around and jump again and the freeze was still refused.
-- That is the "air freeze is difficult to land" report.
--
-- The fix adds MKUTIL.ASM clear_his_freeze_lock, hung off ground_player -- the
-- routine every jump landing, knockdown recovery and reaction goes through.
-- l_freeze is indexed by the THROWER, so the man who LANDS clears his
-- OPPONENT's slot.
--
-- Rather than try to script a real freeze (input timing there has burned whole
-- runs before), poison both l_freeze slots with markers while a fighter is in
-- the air and watch which one the landing clears.  That tests the new code
-- directly AND catches an inverted p1/p2 index, which a "does the move come
-- out" test would not.
--
--   victim_lands : P2 airborne -> poison both -> P2 lands
--                  expect l_freeze[p1] cleared, l_freeze[p2] untouched
--   thrower_lands: P1 airborne -> poison both -> P1 lands
--                  expect l_freeze[p2] cleared, l_freeze[p1] untouched
--
-- Env: FLOCK_LOG
-- Usage: tools/run_freeze_lock_reset_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("FLOCK_LOG") or (ROOT .. "/tools/freeze_lock_reset_test.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[flock] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_obj", "p2_obj",
                     "p1_state", "p2_state", "p1_bar", "p2_bar", "p1_bar_view",
                     "p2_bar_view", "winner_status", "battle_num", "map_position",
                     "l_freeze", "l_dive" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s - results are worthless", n) end
end
-- Both are p1:p2 pairs; get_tsl/update_tsl add 16 bits for player 2.
-- l_dive is Raiden's torpedo, gated by the same "one per airborne state" rule,
-- and clear_his_air_locks clears both from one indexing calculation - so poison
-- all four slots and check that exactly the opponent's two go.
local L_P1, L_P2 = A.l_freeze, A.l_freeze + 16
local D_P1, D_P2 = A.l_dive, A.l_dive + 16
local MARK_P1, MARK_P2 = 0xBEEF, 0xF00D
local MARK_D1, MARK_D2 = 0xCAFE, 0xD00D

local OYPOS = 0x0b0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_SUBZERO = 1, 8
local AIR = 12                      -- px off the floor that counts as airborne

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local floor1, floor2 = nil, nil
local trial, results, done = 1, {}, false
local TRIALS = { "victim_lands", "thrower_lands" }
local st, fields = nil, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true, ["P1 Up"] = true, ["P2 Up"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input field %s", n) end end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 1000 and (frame % 80) < 20
        end
        if name == "1 Player Start"  then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 then
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
            if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
        end
        return false
    end
    -- Both fighters are human here and neither ever attacks, so the ONLY thing
    -- that can ground anybody is his own jump.  The first cut of this test let
    -- the AI drone play, and its knockdowns kept tripping the "landed" check
    -- mid-reaction, before the reaction's own ground_player ran.
    if not st or st.phase ~= "wait_air" then return false end
    local want = (TRIALS[trial] == "thrower_lands") and "P1 Up" or "P2 Up"
    return name == want and (frame % 90) < 10
end

local function new_state() return { phase = "wait_air", poisoned = 0, t0 = frame } end

local function finish()
    if done then return end
    done = true
    log("")
    local pass = true
    for _, k in ipairs(TRIALS) do
        local r = results[k]
        if not r then
            log("RESULT %-14s NO DATA - the fighter never got airborne and back down", k)
            pass = false
        else
            log("RESULT %-14s jump peak %d px | %s cleared %s | l_freeze[p1]=%04x "
                .. "l_freeze[p2]=%04x | l_dive %s | expected %s cleared, %s kept -> %s",
                k, r.peak or -1, r.clear_name,
                (r.frames >= 0) and ("at +" .. r.frames .. " frames") or "NEVER",
                r.p1, r.p2, r.dive_ok and "OK" or "WRONG",
                r.clear_name, r.keep_name, r.ok and "OK" or "WRONG")
            if not r.ok then pass = false end
        end
    end
    log("")
    if pass then
        log("PASS freeze-lock: landing clears the OPPONENT's l_freeze slot and leaves "
            .. "the other one alone - the air freeze resets once per airborne state")
    else
        log("FAIL freeze-lock: the landing reset did not fire on the right slot")
    end
    logfh:close(); manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- does touching the ground reset the air-freeze lock? ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)      -- both human: no AI interference
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG); w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING then w16(A.p2_state, 1) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        floor1, floor2 = gety(A.p1_obj), gety(A.p2_obj)
        st = new_state()
        log("fight start frame=%d  P1 floor oypos=%d  P2 floor oypos=%d  l_freeze @%08x",
            frame, floor1 or -1, floor2 or -1, A.l_freeze)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    local mode = TRIALS[trial]
    local y1, y2 = gety(A.p1_obj), gety(A.p2_obj)
    -- who is the test subject: the one whose LANDING should clear the other slot
    local subject_y, subject_floor = y2, floor2
    local clear_addr, clear_name, keep_addr, keep_name = L_P1, "l_freeze[p1]", L_P2, "l_freeze[p2]"
    local clear_dive, keep_dive = D_P1, D_P2
    if mode == "thrower_lands" then
        subject_y, subject_floor = y1, floor1
        clear_addr, clear_name, keep_addr, keep_name = L_P2, "l_freeze[p2]", L_P1, "l_freeze[p1]"
        clear_dive, keep_dive = D_P2, D_P1
    end
    local airborne = subject_y and subject_floor and (subject_floor - subject_y) > AIR

    local function next_trial()
        trial = trial + 1
        if trial > #TRIALS then finish(); return true end
        st = new_state()
        return false
    end

    if st.phase == "wait_air" then
        if airborne then
            w16(L_P1, MARK_P1); w16(L_P2, MARK_P2)
            w16(D_P1, MARK_D1); w16(D_P2, MARK_D2)
            st.phase, st.poisoned, st.peak = "watch", frame, subject_floor - subject_y
            log("%s: subject airborne (%d px up) - poisoned freeze[%04x,%04x] dive[%04x,%04x]",
                mode, subject_floor - subject_y, MARK_P1, MARK_P2, MARK_D1, MARK_D2)
        elseif frame - st.t0 > 900 then
            log("%s: subject never left the ground", mode)
            if next_trial() then return end
        end
    elseif st.phase == "watch" then
        -- Do NOT try to pin the landing frame; just watch the two slots for a
        -- window that comfortably covers the whole jump arc and report which
        -- one the game cleared and when.
        if airborne and (subject_floor - subject_y) > st.peak then
            st.peak = subject_floor - subject_y
        end
        if not airborne and not st.landed then st.landed = frame end
        local pc, pk = r16(clear_addr), r16(keep_addr)
        if pc == 0 and not st.cleared then
            st.cleared = frame
            log("%s: %s cleared at +%d frames (landed at +%s, peak %d px)", mode,
                clear_name, frame - st.poisoned,
                st.landed and tostring(st.landed - st.poisoned) or "not yet", st.peak)
        end
        if pk ~= MARK_P2 and pk ~= MARK_P1 and not st.collateral then
            st.collateral = frame
            log("%s: WARNING %s also changed at +%d frames", mode, keep_name,
                frame - st.poisoned)
        end
        if frame - st.poisoned > 200 then
            local dive_ok = (r16(clear_dive) == 0) and (r16(keep_dive) ~= 0)
            results[mode] = {
                frames = st.cleared and (st.cleared - st.poisoned) or -1,
                p1 = r16(L_P1), p2 = r16(L_P2), peak = st.peak,
                clear_name = clear_name, keep_name = keep_name,
                dive_ok = dive_ok,
                ok = (st.cleared ~= nil) and (r16(keep_addr) ~= 0) and dive_ok,
            }
            log("%s: window closed - freeze[%04x,%04x] dive[%04x,%04x] (peak %d px up)",
                mode, r16(L_P1), r16(L_P2), r16(D_P1), r16(D_P2), st.peak)
            if next_trial() then return end
        end
    end

    if frame - fighting_frame > 4000 then log("ERROR ran out of fight time"); finish() end
    if frame > 40000 then log("ERROR backstop"); finish() end
end)
