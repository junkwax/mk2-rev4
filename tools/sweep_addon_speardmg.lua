-- sweep_addon_speardmg.lua - does a stun's free hit still land for full?
--
-- dmgscale (MAINEQU.ASM) makes the 2nd hit of a string worth 3/4, the 3rd 1/2
-- and the 4th onwards a quarter.  Three moves are exempt, because each leaves
-- the victim HELD and unable to block, so the hit that follows is the back
-- half of one move rather than a second hit that beat him again:
--
--   MOVE=spear   Scorpion, Back,Back + LP     -> the drag, then act_speared_sd
--   MOVE=freeze  Sub-Zero, Down,Fwd  + LP     -> act_frozen for 080h ticks
--   MOVE=puddle  Sub-Zero, Down,Back + LK     -> act_slipping for 050h ticks
--
-- Each was worth less than it should have been, for its own reason.  The
-- spear is the extreme: r_spear (MKREACT.ASM) loops back onto
-- reaction_start_chores every 2 ticks for the whole drag, so the victim
-- arrives dizzy with p_hit around 15 and the free hit landed for a QUARTER.
-- The puddle is the plainest: stk_floor_ice does 00000h damage and still
-- charged him a hit, taxing the next real one 25% for nothing.
--
-- HOW THE EXPECTED NUMBER IS OBTAINED.  Not from a table, and not from the
-- attacker's p_stk - the thrower never writes p_stk for a projectile, and it
-- reads 0.  The rig lands the SAME button at the SAME range TWICE:
--
--   baseline  P2 pinned at jab range, HP, p_hit = 0
--             -> D0, the unscaled damage of whatever normal comes out there
--   free hit  after the spear drag, HP again at that same pinned range
--             -> D1, and PASS iff D1 == D0
--   3rd hit   the next jab of the same string -> must be D0 - D0>>2 (3/4)
--
-- Both hits are checked to be the same move (the victim's p_hitby is the
-- attacker's p_action at the moment of the hit); if they differ the run is
-- NO-CASE rather than a failure, because then D0 is not D1's baseline.
--
-- P2 is a passive HUMAN, not the drone: nothing else hits him, nothing blocks,
-- and his bar is the instrument, so it is never pinned.
--
-- Env: MOVE (spear|freeze|puddle), SPEAR_LOG.  Driven by
-- run_spear_dmgscale_test.ps1, which also forces the matching P1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("SPEAR_LOG") or (ROOT .. "/tools/spear_dmgscale.txt")
local WHICH = (os.getenv("MOVE") or "spear"):lower()
-- SPEAR_SEED=N: the setup lands as the (N+1)th hit of a string.  The victim's
-- p_hit is held at N until the setup takes its damage, and then left alone -
-- the drag's own count has to pile up on top of it.  A stun's free hit keeps
-- the string's depth: it scales exactly as the setup itself did, and the hit
-- after it one step further.  N=0 is the old test (opener: full, then 3/4).
-- Flip kick, teleport, spear, uppercut is N=2, and before 2026-10-06 the
-- uppercut landed whole because the bias swallowed the two real hits too.
local SEED = tonumber(os.getenv("SPEAR_SEED") or "0") or 0
local function scaled(d, idx)
    if d == 0 or idx <= 0 then return d end
    local v = (idx == 1) and (d - (d >> 2)) or (idx == 2) and (d >> 1) or (d >> 2)
    if v == 0 then v = 1 end
    return v
end

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p2_bar = sym.p2_bar

-- nj_strikes hit damage - the high byte of each record's damage word
-- (MKSTK.ASM).  Scorpion, Sub-Zero, Reptile, Smoke and Noob share this table,
-- and it is what a hit is worth UNSCALED.  The rig prefers it to its own
-- measured opener, because a build can apply something other than the byte it
-- was handed - and when the two disagree the rig says so rather than quietly
-- believing the fight over the ROM.
local NJ_DMG = {
    [0x00] = 32, [0x01] = 26, [0x02] = 11, [0x03] = 8,
    [0x04] = 20, [0x05] = 6,  [0x06] = 12, [0x07] = 6,
    [0x08] = 40, [0x09] = 16, [0x0a] = 32, [0x0b] = 26,
    [0x0c] = 16, [0x0d] = 30, [0x0e] = 16, [0x0f] = 24,
    [0x11] = 8,  [0x12] = 22, [0x13] = 10, [0x14] = 1,
    [0x15] = 0,  [0x16] = 20,
}

local P_ACTION, P_HITBY, P_HIT, P_SCALEBIAS = 0x1f0, 0x360, 0x370, 0x380
local P_STK = 0x350
local OXPOS, OXVAL = 0x090, 0x080
local ACT_SPEAR, ACT_ROPE_PULL, ACT_SPEARED_SD = 0x0011, 0x0405, 0x0605
local ACT_FROZEN, ACT_SLIPPING = 0x0401, 0x060e

-- Per move: the stick roll that throws it, the button, the range it is thrown
-- from, and how the rig knows it landed.  `held` is the victim action that
-- means he is in the stun; `busy` is an attacker action the rig must wait out
-- before it may take the free hit (only the spear has one - the drag).
local MOVES = {
    spear = {
        name = "Scorpion's spear (Back,Back + LP)",
        stick = {{"back",0,5},{"back",10,21}}, btn = "P1 Low Punch", bt = {15,21},
        ranges = {190},
        -- the DRAG is the connect; act_spear is only him throwing it
        held = function(a1, a2) return a2 == ACT_SPEARED_SD or a1 == ACT_ROPE_PULL end,
        busy = function(a1) return a1 == ACT_ROPE_PULL or a1 == ACT_SPEAR end,
    },
    freeze = {
        name = "Sub-Zero's ice ball (Down,Fwd + LP)",
        stick = {{"down",0,5},{"fwd",6,17}}, btn = "P1 Low Punch", bt = {11,17},
        ranges = {190},
        held = function(a1, a2) return a2 == ACT_FROZEN end,
        busy = function(a1) return false end,
    },
    puddle = {
        name = "Sub-Zero's floor ice (Down,Back + LK)",
        stick = {{"down",0,5},{"back",6,17}}, btn = "P1 Low Kick", bt = {11,17},
        -- The puddle does not travel: floor_ice_proc parks an object at his
        -- feet and strike-checks 015h against it every tick.  stk_floor_ice's
        -- box sits 0a8h out with a 072h spread, so the victim has to be stood
        -- in that band - each retry tries the next range along.
        ranges = {190, 230, 150, 120},
        held = function(a1, a2) return a2 == ACT_SLIPPING end,
        busy = function(a1) return false end,
    },
}
local M = MOVES[WHICH]
local DRAG_RANGE = 0x40      -- where do_rope_pull's papa4 loop lets go
-- Ranges tried for the measured hits, widest first, and the victim is held at
-- whichever one first connects for BOTH of them.  Not simply the drag's own
-- 0x40: at that range High Punch comes out as the elbow, which knocks him away
-- and ends the string after one hit, so the "does scaling resume" half could
-- never be measured.  A standing jab leaves him on his feet in front of you and
-- the pin puts him back for the next one - but which range gives which normal
-- is not worth predicting, so the rig walks in until something lands.
local HIT_RANGES = {0x60, 0x58, 0x50, 0x48, 0x40}
local MAX_HP = 0xa1

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[spear] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local phase, phase_at = "settle", 0
local attempts, attempt_at = 0, 0
local free_at, pin_x, pin_gap = 0, true, HIT_RANGES[1]
local range_i, try_at = 1, 0
local events, prev = {}, nil
local baseline = nil
local verdict_done = false

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end
local function rbyte(a)
    local ok, v = pcall(function() return space:read_u8(a) end)
    if ok then return v & 0xff end
    return space:read_u16(a) & 0xff
end
local function pact(procptr)
    local p = space:read_u32(procptr)
    if p == 0 then return 0xffff end
    return space:read_u16(p + P_ACTION) & 0xffff
end
local function objx(objptr)
    local o = space:read_u32(objptr)
    if o == 0 then return nil end
    return s16(space:read_u16(o + OXPOS))
end

local function verdict(pass, why)
    if verdict_done then return end
    verdict_done = true
    log("---- damage events (victim = P2) ----")
    for i, e in ipairs(events) do
        log("#%d %-8s frame=%d dmg=%d  p_hit(before)=%d p_scalebias(before)=%d"
            .. "  effective=%d  hitby=0x%04x",
            i, e.tag, e.frame, e.dmg, e.hit, e.bias,
            math.max(0, e.hit - e.bias), e.hitby)
    end
    log(why)
    log(pass and "VERDICT PASS" or "VERDICT FAIL")
end

local function judge()
    local base, setup, freehit, third
    for _, e in ipairs(events) do
        if e.tag == "baseline" and not base then base = e
        elseif e.tag == "setup" and not setup then setup = e
        elseif e.tag == "free" and not freehit then freehit = e
        elseif e.tag == "free" and freehit and not third then third = e end
    end

    if not base then verdict(false, "the baseline hit never landed"); return end
    if base.hit ~= 0 then
        verdict(false, string.format("baseline was not an opener (p_hit=%d) - rerun", base.hit)); return
    end
    -- the puddle takes nothing off the bar (stk_floor_ice damage = 0), so a
    -- missing setup event is only a failure for the two that do damage
    if setup and setup.hit ~= SEED then
        verdict(false, string.format("NO-CASE: setup landed at p_hit=%d, wanted the seed %d - rerun",
            setup.hit, SEED)); return
    end
    if not setup and WHICH ~= "puddle" then
        verdict(false, "the " .. WHICH .. " never took any damage off"); return
    end
    if not freehit then verdict(false, "no follow-up hit landed during the dizzy"); return end
    if freehit.hitby ~= base.hitby then
        verdict(false, string.format(
            "NO-CASE: baseline was move 0x%04x, free hit was 0x%04x - different moves, "
            .. "so %d is not the free hit's baseline",
            base.hitby, freehit.hitby, base.dmg)); return
    end
    if freehit.hit - freehit.bias ~= SEED then
        verdict(false, string.format(
            "free hit saw p_hit=%d p_scalebias=%d (effective %d) - wanted the string's own "
            .. "depth %d: the stun's count discounted, the %d real hit(s) before it kept",
            freehit.hit, freehit.bias, freehit.hit - freehit.bias, SEED, SEED)); return
    end
    -- WHAT THE HIT IS WORTH UNSCALED.  The record, when the attacker's p_stk
    -- names one (it does for a normal; a projectile's thrower never writes
    -- it), and the measured opener otherwise.  The two are cross-checked and
    -- a disagreement is REPORTED rather than smoothed over: it means the game
    -- applied something other than the damage byte it was handed, which is a
    -- finding about the build, not about this exemption.
    local full = NJ_DMG[freehit.stk] or base.dmg
    local source = NJ_DMG[freehit.stk] and ("record 0x" .. string.format("%02x", freehit.stk))
                                        or "measured opener"
    if NJ_DMG[freehit.stk] and base.dmg ~= NJ_DMG[freehit.stk]
       and base.stk == freehit.stk then
        log("WARNING: the opener took %d off the bar where strike row 0x%02x "
            .. "carries %d - the BUILD is applying the wrong damage, and it is "
            .. "not this exemption doing it",
            base.dmg, base.stk, NJ_DMG[freehit.stk])
    end

    if freehit.dmg ~= scaled(full, SEED) then
        verdict(false, string.format(
            "free hit did %d, wanted %d at depth %d (move worth %d unscaled, %s; "
            .. "3/4 = %d, 1/2 = %d, 1/4 = %d)",
            freehit.dmg, scaled(full, SEED), SEED, full, source, full - (full >> 2),
            full >> 1, full >> 2)); return
    end

    local msg = string.format(
        "%s seed %d: setup %s, free hit %d (unscaled %d, %s) "
        .. "with p_hit at %d bias %d = depth %d",
        WHICH, SEED, setup and (setup.dmg .. " at p_hit=" .. setup.hit) or "0 damage (as designed)",
        freehit.dmg, full, source, freehit.hit, freehit.bias, freehit.hit - freehit.bias)
    if third then
        -- Scaled by the depth IT saw.  Not SEED+1: under cmbrules an ordinary
        -- High/Low Punch hands its hit back (dec_my_p_hit), so a jab after
        -- the free hit sits at the same depth and only a real link moves on.
        local want = scaled(full, third.hit - third.bias)
        if third.dmg ~= want then
            verdict(false, string.format(
                "%s, but the next hit did %d, wanted %d (of %d) - scaling did not resume",
                msg, third.dmg, want, full)); return
        end
        msg = msg .. string.format(", and the hit after it %d (of %d)", third.dmg, full)
    else
        msg = msg .. " (nothing landed after it - the resume half is unproven)"
    end
    verdict(true, msg)
end

emu.register_frame(function()
    frame = frame + 1
    if not M then return end
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== free-hit scaling: %s ===", M.name)
    end
    if verdict_done then return end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then
        fight0, phase_at = frame, frame
        local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
        log("fight start: p1 ochar=%d p2 ochar=%d",
            o1 ~= 0 and space:read_u16(o1 + 0x1f0) or -1,
            o2 ~= 0 and space:read_u16(o2 + 0x1f0) or -1)
    end

    -- ---- damage bookkeeping ------------------------------------------------
    -- inc_p_hit runs in the same tick as bar_reducer but after it, so the
    -- counter that DECIDED the scaling is the one sampled last frame.
    local pr1, pr2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if pr1 ~= 0 and pr2 ~= 0 then
        local now = {
            hp    = space:read_u16(p2_bar) & 0xffff,
            hit   = rbyte(pr2 + P_HIT),
            bias  = rbyte(pr2 + P_SCALEBIAS),
        }
        if prev and now.hp ~= prev.hp then
            log("  bar %d -> %d (frame %d, phase %s) p_hit %d -> %d, p1 stk=0x%02x act=0x%04x",
                prev.hp, now.hp, frame, phase, prev.hit, now.hit,
                space:read_u16(pr1 + 0x350) & 0xffff,
                space:read_u16(pr1 + P_ACTION) & 0xffff)
        end
        if prev and now.hp < prev.hp and now.hp > 0 then
            local tag = (phase == "baseline" and "baseline")
                     or ((phase == "throw" or phase == "hold") and "setup")
                     or ((phase == "free") and "free") or phase
            events[#events + 1] = {
                tag = tag, frame = frame, dmg = prev.hp - now.hp,
                hit = prev.hit, bias = prev.bias,
                hitby = space:read_u16(pr2 + P_HITBY) & 0xffff,
                stk = space:read_u16(pr1 + P_STK) & 0xffff,
            }
            local e = events[#events]
            log("hit %-8s frame=%d dmg=%d p_hit=%d bias=%d hitby=0x%04x",
                e.tag, e.frame, e.dmg, e.hit, e.bias, e.hitby)
        end
        prev = now
        -- the seed: held until the setup has taken its damage, then let go
        if SEED > 0 and phase == "throw" then
            local landed = false
            for _, e in ipairs(events) do if e.tag == "setup" then landed = true end end
            if not landed and not M.held(pact(p1_proc), pact(p2_proc)) then
                space:write_u8(pr2 + P_HIT, SEED)
                space:write_u8(pr2 + P_SCALEBIAS, 0)
                prev.hit, prev.bias = SEED, 0
            end
        end
    end

    -- ---- stick -------------------------------------------------------------
    local x1, x2 = objx(p1_obj), objx(p2_obj)
    if pin_x and x1 and x2 then
        local o2 = space:read_u32(p2_obj)
        local tx = x1 + pin_gap
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
        space:write_u16(o2 + OXPOS, tx)
        x2 = tx
    end
    local back = (x1 and x2 and x1 < x2) and "P1 Left" or "P1 Right"
    for _, n in ipairs({"P1 Left","P1 Right","P1 Down",
                        "P1 High Punch","P1 Low Punch","P1 Low Kick"}) do
        press(n, false)
    end

    local a1, a2 = pact(p1_proc), pact(p2_proc)

    if phase == "settle" then
        if frame - phase_at > 90 then
            phase, phase_at, try_at = "baseline", frame, frame
            range_i = 1
            pin_gap, pin_x = HIT_RANGES[range_i], true
            log("baseline: hunting for a clean hit, from range 0x%02x", pin_gap)
        end

    elseif phase == "baseline" then
        for _, e in ipairs(events) do
            if e.tag == "baseline" then baseline = e break end
        end
        if baseline then
            -- got it: let him recover so p_hit is back to 0 for the spear,
            -- and put his bar back - the spear must not finish the round
            if frame - baseline.frame > 90 then
                space:write_u16(p2_bar, MAX_HP)
                phase, attempts, attempt_at = "throw", 1, frame + 2
                pin_gap = M.ranges[1]
                log("baseline %d damage at range 0x%02x (hitby 0x%04x) - now the %s",
                    baseline.dmg, HIT_RANGES[range_i], baseline.hitby, WHICH)
            end
        else
            local r = frame - try_at
            press("P1 High Punch", (r % 20) < 8)
            if r > 80 then
                range_i = range_i + 1
                if not HIT_RANGES[range_i] then
                    verdict(false, "no range in HIT_RANGES ever landed a clean hit"); return
                end
                pin_gap, try_at = HIT_RANGES[range_i], frame
                log("nothing landed - closing to range 0x%02x", pin_gap)
            end
        end

    elseif phase == "throw" then
        local r = frame - attempt_at
        -- rolled like a stick: the last direction stays held under the button
        if r >= 0 then
            local fwd = (back == "P1 Left") and "P1 Right" or "P1 Left"
            for _, seg in ipairs(M.stick) do
                if r >= seg[2] and r <= seg[3] then
                    if seg[1] == "back" then press(back, true)
                    elseif seg[1] == "fwd" then press(fwd, true)
                    else press("P1 Down", true) end
                end
            end
            press(M.btn, r >= M.bt[1] and r <= M.bt[2])
        end
        -- the stun has to be able to move him (the spear's drag, the slip)
        if r > 24 then pin_x = false end
        if M.held(a1, a2) then
            phase, phase_at, pin_x = "hold", frame, false
            log("%s connected frame=%d p1act=0x%04x p2act=0x%04x",
                WHICH, frame, a1, a2)
        elseif r > 170 then
            attempts = attempts + 1
            if attempts > 8 then
                verdict(false, WHICH .. " never connected in 8 tries"); return
            end
            attempt_at, pin_x = frame + 2, true
            pin_gap = M.ranges[((attempts - 1) % #M.ranges) + 1]
            log("no connect, attempt %d - range %d", attempts, pin_gap)
        end

    elseif phase == "hold" then
        -- wait out anything the ATTACKER still owes (only the spear's drag),
        -- then put the victim back at the baseline's range and take the hit
        if not M.busy(a1) and frame - phase_at > 10 then
            phase, free_at = "free", frame
            pin_gap, pin_x = HIT_RANGES[range_i], true   -- the baseline's range
            log("setup done frame=%d p2act=0x%04x - taking the free hit", frame, a2)
        elseif frame - phase_at > 400 then
            verdict(false, "the setup never ended"); return
        end

    elseif phase == "free" then
        local r = frame - free_at
        press("P1 High Punch", (r % 12) < 6)   -- autofire at the dizzy man
        -- baseline + spear + three of the string is the whole question; more
        -- jabs into a pinned dummy prove nothing and can outrun the backstop
        if #events >= 5 or r > 150 then judge() end
    end
end)

emu.register_stop(function()
    if not verdict_done then judge() end
end)
