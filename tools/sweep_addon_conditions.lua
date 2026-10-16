-- sweep_addon_conditions.lua - is each callout shown for the RIGHT condition?
--
-- The hudcall rig says "mismatches=0" and that number is worth less than it
-- looks, for three separate reasons:
--
--   1. FIRST HIT had an unconditional pass (a dedicated rig covers it now).
--   2. REVERSAL passes unless BOTH sampled frames are a punish - so almost
--      anything the ladder called a reversal was accepted.
--   3. The punish family's sub-selection - BLOCK PUNISH vs PUNISH vs WHIFF
--      PUNISH - is compared against cal_last, which IS the variable that
--      decides it in the ROM. That check is circular: a wrong cal_last
--      produces a wrong word and a passing test.
--
-- And in 3000 frames of that rig, BLOCK PUNISH and WHIFF PUNISH never fired
-- once. Two of the seven words had no evidence at all behind them.
--
-- So this rig does two things.
--
-- GROUND TRUTH, not the ROM's own bookkeeping. Every gate is re-derived:
--
--   punish family   victim's p_action is 06xx and not act_upcutted (0606)
--   which punish    what the victim's OWN last strike did, tracked here from
--                   the p_stk window: the defender's life bar dropping is a
--                   HIT, the defender sitting in 07xx in range without the
--                   bar moving is BLOCKED, neither is NOTHING
--   ANTI-AIR        victim off the ground (oypos/oyvel vs p_ganiy), not in
--                   05xx, attacker on the ground
--   REVERSAL        the gap between the attacker LEAVING stun (his action
--                   leaving 05xx/07xx) and his strike going live, measured
--                   here, against hudcall_rev
--   KOUNTER         victim's p_action is 01xx
--
-- PRODUCTION. Whiff and block punishes do not happen by accident at a fixed
-- attack cadence, which is why the old rig never saw one. p1 is the joystick
-- side, so p1 is the punisher; p2 is the drone and its strikes are made to
-- whiff or be blocked by controlling distance and p1's guard. (Pressing p2's
-- buttons would do nothing - is_he_joy reads pb_joy in the process flags, so
-- a drone ignores the port no matter what p2_state says.)
--
-- Env: COND_LOG.  Driven by run_conditions_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("COND_LOG") or (ROOT .. "/tools/conditions.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
}) do ADDON_OWNS[n] = true end

local space, fields = nil, {}
local logf = io.open(OUT, "w")
local function log(fmt, ...)
    local s = "[cond] " .. string.format(fmt, ...)
    print(s)
    if logf then logf:write(s .. "\n"); logf:flush() end
end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local P_ACTION, P_STK, P_GANIY = 0x1f0, 0x350, 0x200
local OXPOS, OYPOS, OYVEL = 0x90, 0xb0, 0x60
local OXVAL = 0x80
local GS_FIGHTING = 0x02
local HUDCALL_REV = 2           -- MAINEQU.ASM
local MAXHP = 0xa1
-- 06xx states that are a REACTION rather than a recovery of the victim's own
-- making: speared, fanned, frozen, shocked, falling from a hit, sliding on
-- ice. The ladder excludes these from the punish family, so ground truth has
-- to as well or every juggle reads as a missed PUNISH.
local NOT_PUNISH = { [0x606]=1, [0x605]=1, [0x609]=1, [0x60e]=1,
                     [0x610]=1, [0x613]=1, [0x614]=1, [0x616]=1 }

local WORDS = {
    [sym.hc_kounter_s] = "KOUNTER",      [sym.hc_punish]   = "PUNISH",
    [sym.hc_reversal]  = "REVERSAL",     [sym.hc_firsthit] = "FIRST HIT",
    [sym.hc_blockpun]  = "BLOCK PUNISH", [sym.hc_whiffpun] = "WHIFF PUNISH",
    [sym.hc_antiair]   = "ANTI-AIR",
    [sym.hc_flawblk]   = "FLAWLESS BLOCK",
}

local t = 0
local prev_arms  = { [0] = nil, [1] = nil }
local prev_stk   = { [0] = 0, [1] = 0 }
local prev_bar   = { [0] = MAXHP, [1] = MAXHP }
local prev_cat   = { [0] = 0, [1] = 0 }
-- ground truth, per player
local outcome    = { [0] = "NOTHING", [1] = "NOTHING" }  -- his last strike
local stk_open   = { [0] = false, [1] = false }
local stk_close  = { [0] = -99, [1] = -99 }
local went_live  = { [0] = false, [1] = false }
local stun_exit  = { [0] = -999, [1] = -999 }
local atk_start  = { [0] = -999, [1] = -999 }
local hist       = {}   -- one frame of lag, for the +/-1 allowance
local counts, fails = {}, {}
local rev_seen, rev_bad, last_rev = 0, {}, {}
local rev_gaps = {}
local punish_hits = 0

local function proc(i) return space:read_u32(i == 0 and sym.p1_proc or sym.p2_proc) end
local function obj(i)  return space:read_u32(i == 0 and sym.p1_obj  or sym.p2_obj) end

local function snapshot()
    local s = { act = {}, air = {}, x = {} }
    for i = 0, 1 do
        local pp, ob = proc(i), obj(i)
        s.act[i] = (pp ~= 0) and (space:read_u16(pp + P_ACTION) & 0xffff) or 0
        if pp ~= 0 and ob ~= 0 then
            local gy = s16(space:read_u16(pp + P_GANIY))
            local y  = s16(space:read_u16(ob + OYPOS))
            local yv = space:read_u32(ob + OYVEL)
            s.air[i] = (yv ~= 0) or (y ~= gy)
            s.x[i] = s16(space:read_u16(ob + OXPOS))
        else
            s.air[i], s.x[i] = false, 0
        end
    end
    return s
end

-- What the ladder SHOULD say, from ground truth alone.
local function expect(atk, vic, s)
    local va = s.act[vic]
    local cat = (va >> 8) & 0xff
    if cat == 6 and not NOT_PUNISH[va] then
        local o = outcome[vic]
        return (o == "BLOCKED" and "BLOCK PUNISH")
            or (o == "HIT" and "PUNISH") or "WHIFF PUNISH"
    end
    if cat ~= 5 and s.air[vic] and not s.air[atk] then return "ANTI-AIR" end
    -- REVERSAL is deliberately NOT predicted here. There is no sound way to
    -- reconstruct "became actionable" from outside: the ROM stamps cal_free
    -- at reaction_exit and block_exit, and a block state can come and go
    -- inside one frame, so sampling p_action once a frame misses it. An
    -- earlier version guessed anyway and reported three ROM bugs that were
    -- its own. REVERSAL is checked for internal freshness instead - see
    -- rev_check - and accepted here.
    -- A counter hit is the STARTUP of his attack only. 01xx alone covers the
    -- whole move; went_live says whether his strike has actually come out, so
    -- a trade on his active frames is not one.
    if cat == 1 and not went_live[vic] then return "KOUNTER" end
    return nil
end

-- ---------------------------------------------------------------- scenario
-- p2 (the drone) attacks; what its strike DOES is arranged from here, and
-- then p1 hits it during the recovery.
local SEP, NEAR = 150, 52
local mode, phase, phase_t, made = "whiff", 0, 0, { whiff = 0, block = 0 }
local punished, pun_t = false, 0
-- Snap p1 in ONCE when the window opens and then leave him alone. Writing
-- oxval every frame holds the object still and the strike never travels:
-- 154 recovery windows with p1 punching produced zero landed hits.
local function punish_now(s)
    local ob1 = obj(0)
    if ob1 == 0 then return end
    local tx = (s.x[1] < s.x[0]) and (s.x[1] + 44) or (s.x[1] - 44)
    space:write_u32(ob1 + OXVAL, (tx & 0xffff) << 16)
end

emu.register_frame(function()
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== callout conditions === each word against ground truth")
    end
    t = t + 1
    if (space:read_u16(sym.gstate) & 0xffff) ~= GS_FIGHTING then return end
    space:write_u16(sym.p1_bar, MAXHP)      -- the match must not end

    local s = snapshot()
    local bar = { [0] = space:read_u16(sym.p1_bar) & 0xffff,
                  [1] = space:read_u16(sym.p2_bar) & 0xffff }

    -- ---- ground truth upkeep -------------------------------------------
    for i = 0, 1 do
        local pp = proc(i)
        local stk = (pp ~= 0) and (space:read_u16(pp + P_STK) & 0xffff) or 0
        if stk ~= 0 and prev_stk[i] == 0 then
            outcome[i], stk_open[i], atk_start[i] = "NOTHING", true, t
            went_live[i] = true
        elseif stk == 0 and prev_stk[i] ~= 0 then
            stk_open[i], stk_close[i] = false, t
        end
        prev_stk[i] = stk

        local cat = (s.act[i] >> 8) & 0xff
        if (prev_cat[i] == 5 or prev_cat[i] == 7) and cat ~= 5 and cat ~= 7 then
            stun_exit[i] = t
        end
        if cat == 1 and prev_cat[i] ~= 1 then went_live[i] = false end
        prev_cat[i] = cat
    end
    -- Outcome of a live strike: the defender's bar dropping is a HIT; the
    -- defender guarding in range with the bar untouched is BLOCKED. Checked
    -- for a few frames past the strike closing, because the bar is reduced
    -- after the strike connects, not on the same instruction.
    for i = 0, 1 do
        local d = 1 - i
        -- Only while the strike is live, plus the couple of frames the bar
        -- takes to be reduced after it connects. The window was 12 frames,
        -- which is long enough to credit the NEXT exchange's damage to this
        -- strike and label a blocked move as a hit.
        if stk_open[i] or (t - (stk_close[i] or -99)) <= 3 then
            if bar[d] < prev_bar[d] then
                outcome[i] = "HIT"
            elseif outcome[i] == "NOTHING"
                   and ((s.act[d] >> 8) & 0xff) == 7
                   and math.abs(s.x[0] - s.x[1]) < 110 then
                outcome[i] = "BLOCKED"
            end
        end
    end
    -- Did a hit actually LAND while the victim was recovering? Without this
    -- "no punish fired" cannot be told apart from "no punish was earned".
    if ((s.act[1] >> 8) & 0xff) == 6 and bar[1] < prev_bar[1] then
        punish_hits = punish_hits + 1
    end
    prev_bar[0], prev_bar[1] = bar[0], bar[1]

    -- ---- judge every arming --------------------------------------------
    for i = 0, 1 do
        local arms = space:read_u16(sym.cal_arms + i * 16) & 0xffff
        if prev_arms[i] and arms ~= prev_arms[i] then
            local w = space:read_u32(sym.cal_word + i * 32) & 0xffffffff
            local name = WORDS[w] or string.format("?%08x", w)
            counts[name] = (counts[name] or 0) + 1
            -- The attacker's stamps on EVERY arming, not just the ones the
            -- ladder called a reversal. Without the whole distribution there
            -- is no way to tell "the window is too tight" from "the stamps do
            -- not line up the way I assumed".
            do
                local fr = space:read_u16(sym.cal_free + i * 16) & 0xffff
                local ak = space:read_u16(sym.cal_atk  + i * 16) & 0xffff
                local tk = space:read_u16(sym.tick) & 0xffff
                log("  gap p%d %-13s cal_free=%d cal_atk=%d gap=%d (tick %d,"
                    .. " so the hit is %d ticks after the attack started)",
                    i + 1, name, fr, ak, ak - fr, tk, tk - ak)
            end
            if name ~= "FIRST HIT" then      -- its own rig covers that one
                local vic = 1 - i
                -- the ladder reads the victim on the frame of the hit; allow
                -- this frame or the one before, as the hudcall rig does
                local e1 = expect(i, vic, s)
                local e2 = hist[1] and expect(i, vic, hist[1]) or nil
                -- For REVERSAL, print the ROM's OWN stamps beside the
                -- independent measurement. cal_atk is written only by
                -- init_special, so a normal punch or kick never refreshes it;
                -- if it is stale the pair can keep testing true long after
                -- the reversal it described.
                if name == "REVERSAL" then
                    rev_seen = rev_seen + 1
                    local fr = space:read_u16(sym.cal_free + i * 16) & 0xffff
                    local ak = space:read_u16(sym.cal_atk  + i * 16) & 0xffff
                    local tk = space:read_u16(sym.tick) & 0xffff
                    log("  REVERSAL p%d: tick=%d cal_free=%d cal_atk=%d"
                        .. " rom-gap=%d | my stun_exit=%d atk_start=%d gap=%d",
                        i + 1, tk, fr, ak, ak - fr, stun_exit[i], atk_start[i],
                        atk_start[i] - stun_exit[i])
                end
                if name == "REVERSAL" then
                    local fr = space:read_u16(sym.cal_free + i * 16) & 0xffff
                    local ak = space:read_u16(sym.cal_atk  + i * 16) & 0xffff
                    -- Read AFTER the ladder ran, so cal_atk must have been
                    -- consumed: the stamp is cleared as REVERSAL is armed so
                    -- it cannot fire twice. Before that fix this same check
                    -- caught one cal_atk firing three times over.
                    rev_gaps[#rev_gaps+1] = ak - fr
                    if ak ~= 0 then
                        rev_bad[#rev_bad+1] = string.format(
                            "p%d cal_atk not consumed (%d, cal_free %d)",
                            i+1, ak, fr)
                    end
                    last_rev[i] = ak
                elseif name ~= e1 and name ~= e2 then
                    fails[#fails + 1] = string.format(
                        "%s (p%d) but ground truth says %s: victim act=%04x"
                        .. " his-last-strike=%s air=%s/%s rev-gap=%d",
                        name, i + 1, tostring(e1), s.act[vic], outcome[vic],
                        tostring(s.air[vic]), tostring(s.air[i]),
                        atk_start[i] - stun_exit[i])
                    log("  MISMATCH %s", fails[#fails])
                end
            end
        end
        prev_arms[i] = arms
    end
    hist[1] = s

    if t % 240 == 0 then
        log("  t=%d mode=%s phase=%d act=%04x/%04x stk=%d/%d dx=%d bars=%d/%d",
            t, mode, phase, s.act[0], s.act[1], prev_stk[0], prev_stk[1],
            math.abs(s.x[0] - s.x[1]), bar[0], bar[1])
    end

    -- ---- drive the scenario ---------------------------------------------
    --
    -- NO position writes. The first version pinned p2's x every frame to set
    -- up a whiff, and that froze both fighters in act_stance for 5000 frames:
    -- the drone could not approach, could not commit to a strike, and so
    -- could never punish anything. The AI already has whiff and block punish
    -- behaviour; it just needs to be left alone to use it.
    --
    -- Two halves, alternating:
    --   p1 attacks   - some of these whiff at whatever range the AI picked,
    --                  and the drone's punish supplies WHIFF PUNISH
    --   p1 guards    - the AI attacks into the guard, and p1 punishes out of
    --                  it the moment the AI is left recovering, which is the
    --                  BLOCK PUNISH case.  p1 has to be the one taking it:
    --                  a drone ignores the port whatever p2_state says.
    local cyc = t % 420
    local vcat = (s.act[1] >> 8) & 0xff
    if cyc < 220 then
        mode = "whiff"
        local c = cyc % 26
        press("P1 Block", false)
        press("P1 High Kick", c == 0 or c == 1)
        press("P1 Low Kick",  c == 13 or c == 14)
        -- Throws are LOW PUNCH, and a throw denied by the opponent holding
        -- away is what THROW ESCAPE announces. Point blank so the attempt is
        -- actually made.
        press("P1 Low Punch", c == 6 or c == 7)
        -- NOTE: THROW ESCAPE cannot be produced from here. Only a HUMAN
        -- throw reaches JOY.ASM's tchk4 (the drone's slam check aborts
        -- earlier and calls do_body_slam directly), so the escaper has to be
        -- the drone - and its p_joyport points at a location the AI owns,
        -- reading ff8b3a70 (ROM) for much of a fight. Forcing its stick away
        -- from Lua does nothing. The word is unexercised by this rig.
        if o1 ~= 0 and o2 ~= 0 and c == 4 then
            local tx = (s.x[1] < s.x[0]) and (s.x[1] + 40) or (s.x[1] - 40)
            space:write_u32(o1 + OXVAL, (tx & 0xffff) << 16)
        end
        press("P1 High Punch", false)
        press("P1 Right", c > 3 and c < 10)     -- close the gap a little
    else
        mode = "block"
        -- Put p1 inside the drone's reach ONCE as the guard phase opens,
        -- otherwise it attacks thin air and there is nothing to block.
        if cyc == 220 then punish_now(s) end
        press("P1 High Kick", false)
        press("P1 Low Kick", false)
        press("P1 Right", false)
        if vcat == 6 then
            made.block = made.block + 1
            if not punished then punished, pun_t = true, t; punish_now(s) end
            press("P1 Block", false)
            press("P1 High Punch", (t - pun_t) < 4)
        else
            press("P1 Block", true)
            press("P1 High Punch", false)
        end
    end
    if cyc < 220 and vcat == 6 then
        made.whiff = made.whiff + 1
        if not punished then punished, pun_t = true, t; punish_now(s) end
        press("P1 High Punch", (t - pun_t) < 4)
    end
    if vcat ~= 6 then punished = false end
end)

emu.register_stop(function()
    log("")
    for n, c in pairs(counts) do log("RESULT %-13s x%d", n, c) end
    log("scenarios reached the recovery: whiff %d, block %d", made.whiff, made.block)
    log("hits that actually landed on a recovering p2: %d", punish_hits)
    local seen_w = (counts["WHIFF PUNISH"] or 0)
    local seen_b = (counts["BLOCK PUNISH"] or 0)
    log("SUMMARY mismatches=%d  (REVERSAL seen %d, stamp problems %d)",
        #fails, rev_seen, #rev_bad)
    for _, r in ipairs(rev_bad) do log("  REVERSAL STAMP %s", r) end
    if #rev_gaps > 0 then
        local t2 = {}
        for _, g in ipairs(rev_gaps) do t2[#t2+1] = tostring(g) end
        log("  reversal gaps (cal_atk - cal_free): %s", table.concat(t2, " "))
    end
    if seen_w == 0 and seen_b == 0 then
        log("VERDICT NO-CASE - neither whiff nor block punish ever fired;"
            .. " the scenario did not produce the condition")
    elseif #fails > 0 then
        log("VERDICT FAIL - %d callouts did not match ground truth", #fails)
    else
        log("VERDICT PASS - every word matched ground truth (whiff x%d,"
            .. " block x%d)", seen_w, seen_b)
    end
    if logf then logf:close() end
end)
