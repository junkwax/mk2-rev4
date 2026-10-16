-- sweep_addon_antiair.lua - what the narrowed ANTI-AIR rung actually says yes
--                           to, measured on the hits themselves.
--
-- Ask: "anti air toast should be narrowed ... there is an attack from the
-- opponent, the other player is still on the ground and is able to knock the
-- opponent out of the air ... timing is pretty critical, like a high kick out
-- of an incoming flip kick, where if the high kick didn't land or wasn't done
-- they would be hit".  And NOT: "an air freeze done at the wrong timing that
-- then automatically sets the player up for an attack".
--
-- So the interesting event is not "a word armed" - it is EVERY HIT ON AN
-- AIRBORNE MAN, with what he was doing at the time, and then whether the word
-- came up.  Arming alone cannot show what was correctly refused.
--
-- The hit is detected on the VICTIM's action edge: airborne-and-doing-
-- something -> a reaction (0503 / 0606 / 0609 / 060d).  The action and
-- p_store1 from the frame BEFORE that edge are what the classifier read.
--
--   act 0200/0201  the jump-in kick / punch ("flip kick")
--   act 010e/0118  the straight-up jump kick / punch
--   act 030b/0308  a NEUTRAL jump - no attack, no read, must NOT be a word
--   window         p_store1: strike checks air_strike has left.  0 = his kick
--                  is spent and he is only falling
--
-- P2 jumps at P1 over and over, and the phase is picked per JUMP: empty,
-- kick late (live on arrival), kick early (window spent on arrival).  P1
-- crouches and uppercuts whatever arrives, so all three get hit by the same
-- move at the same range and only the victim's state differs.
--
-- Env: AA_LOG.  Driven by run_antiair_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("AA_LOG") or (ROOT .. "/tools/antiair.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate  = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_obj,  p2_obj  = sym.p1_obj,  sym.p2_obj
local p1_bar,  p2_bar  = sym.p1_bar,  sym.p2_bar
local cal_word, cal_arms, cal_first = sym.cal_word, sym.cal_arms, sym.cal_first

local WORDS = {}
for _, n in ipairs({"hc_kounter_s","hc_punish","hc_reversal","hc_blockpun",
                    "hc_whiffpun","hc_antiair","hc_firsthit","hc_flawblk"}) do
    if sym[n] then WORDS[sym[n]] = n:gsub("^hc_", ""):gsub("_s$", ""):upper() end
end

local P_ACTION, P_STORE1, P_GANIY = 0x1f0, 0x230, 0x200
local OYPOS, OXPOS = 0x0b0, 0x090
local MAX_HP = 0xA1

-- the four air_strike callers - the only actions the narrowed rung accepts
local AIRATK  = { [0x0200]=1, [0x0201]=1, [0x010e]=1, [0x0118]=1 }
local NEUTRAL = { [0x030b]=1, [0x0308]=1 }
-- The reaction edges that mean "he just got hit".
--
-- act_fk_sd (060d) is NOT one of them, and having it here was a real error in
-- the first run: MOVES.ASM sets it on the flip kick's OWN wham path, so P2's
-- kick LANDING on P1 looked like P2 being hit and scored four phantom
-- "AIRATK-LIVE -> (no word)" that never happened.
local REACT   = { [0x0503]=1, [0x0606]=1, [0x0609]=1 }

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[aa] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
    "P2 Left","P2 Right","P2 Up","P2 Down",
    "P2 High Punch","P2 Low Punch","P2 High Kick","P2 Low Kick","P2 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

local prev = { act = 0, win = 0, air = false }
local jump = { t = -999, n = -1, kick_at = nil, up_until = -999 }
local prev_arms = 0
local pending = nil          -- an air hit waiting to see if a word arms
local recent  = nil          -- a word waiting to see if an air hit follows
local hits, words = {}, {}
local function bump(t, k) t[k] = (t[k] or 0) + 1 end
local function signed16(v) if v >= 0x8000 then return v - 0x10000 end return v end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== anti-air === P2 jumps in; every third jump is empty, every")
        log("                 third kicks late, every third kicks early.  P1")
        log("                 crouches and uppercuts whatever arrives")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)
    -- FIRST HIT sits above every rung below it and would eat the first
    -- reading of the round.  Spend it, the way run_airfreeze_test does.
    space:write_u16(cal_first, 1)

    local pr1, pr2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if pr1 == 0 or pr2 == 0 or o1 == 0 or o2 == 0 then return end

    local a2 = space:read_u16(pr2 + P_ACTION) & 0xffff
    local w2 = space:read_u16(pr2 + P_STORE1) & 0xffff
    local y2 = signed16(space:read_u16(o2 + OYPOS))
    local g2 = signed16(space:read_u16(pr2 + P_GANIY))
    local air2 = (y2 < g2 - 6)
    local x1 = signed16(space:read_u16(o1 + OXPOS))
    local x2 = signed16(space:read_u16(o2 + OXPOS))
    local dx = x2 - x1

    -- ---- the hit edge, on P2 --------------------------------------------
    if REACT[a2] and not REACT[prev.act] and prev.air then
        local kind = AIRATK[prev.act]
                     and (prev.win ~= 0 and "AIRATK-LIVE" or "AIRATK-SPENT")
                     or (NEUTRAL[prev.act] and "NEUTRAL-JUMP" or "OTHER")
        pending = { t = t, act = prev.act, win = prev.win, kind = kind,
                    deadline = frame + 4 }
        bump(hits, kind)
    end
    if os.getenv("AA_TRACE") and a2 ~= prev.act and t < 900 then
        log("    trace t=%-5d c=%-3d p2 act %04x window %-3d dx=%-4d %s",
            t, t % 100, a2, w2, dx, air2 and "air" or "ground")
    end
    prev.act, prev.win, prev.air = a2, w2, air2

    -- ---- did a word arm for P1 (the attacker) ? -------------------------
    --
    -- The word arms INSIDE the strike, one tick before the victim's action
    -- becomes the reaction - so the match has to look BACKWARDS as well as
    -- forwards.  Matching only forwards printed every anti-air as a "ground
    -- hit" and every real one as "(no word)": both halves wrong, from one
    -- frame of skew.
    local n = space:read_u16(cal_arms) & 0xffff          -- p1's slot
    if n ~= prev_arms then
        prev_arms = n
        local ww = space:read_u32(cal_word)
        local name = WORDS[ww] or string.format("?%08x", ww)
        if pending then
            log("  hit t=%-5d victim act %04x window %-3d %-12s -> %s",
                pending.t, pending.act, pending.win, pending.kind, name)
            bump(words, pending.kind .. " -> " .. name)
            pending = nil
        else
            recent = { name = name, frame = frame, t = t }
        end
    end
    if pending and recent and frame - recent.frame <= 3 then
        log("  hit t=%-5d victim act %04x window %-3d %-12s -> %s",
            pending.t, pending.act, pending.win, pending.kind, recent.name)
        bump(words, pending.kind .. " -> " .. recent.name)
        pending, recent = nil, nil
    end
    if recent and frame - recent.frame > 3 then
        log("  word t=%-5d grounded victim                        -> %s",
            recent.t, recent.name)
        bump(words, "grounded -> " .. recent.name)
        recent = nil
    end
    if pending and frame > pending.deadline then
        log("  hit t=%-5d victim act %04x window %-3d %-12s -> (no word)",
            pending.t, pending.act, pending.win, pending.kind)
        bump(words, pending.kind .. " -> (no word)")
        pending = nil
    end

    -- ---- the choreography -----------------------------------------------
    --
    -- NOT on a fixed cycle.  The first version drove the jump off t % 100 and
    -- every jump landed on the same parity: a knockdown plus the getup is
    -- about 200 ticks, so the "attack this time" cycles were always the ones
    -- P2 spent on the floor, and 15 runs produced 15 empty jumps and no jump
    -- attack at all.  The phase is picked when the JUMP starts instead.
    --
    --   jump 0 mod 3   empty jump          - the control, must stay silent
    --   jump 1 mod 3   kick LATE           - window still live on arrival
    --   jump 2 mod 3   kick IMMEDIATELY    - 16 checks spent by arrival, so
    --                                        he is only falling when he is hit
    for _, k in ipairs({"P2 Up","P2 Left","P2 Right","P2 High Kick",
                        "P1 Down","P1 High Punch"}) do press(k, false) end

    local toward2 = (dx > 0) and "P2 Left" or "P2 Right"
    local away2   = (dx > 0) and "P2 Right" or "P2 Left"
    local adx     = math.abs(dx)

    if t <= jump.up_until then
        press("P2 Up", true)
        press(toward2, true)
    elseif air2 then
        if jump.kick_at and t >= jump.kick_at and t <= jump.kick_at + 1 then
            press("P2 High Kick", true)
        end
    elseif a2 == 0 or a2 == 0x0303 or a2 == 0x0305 or a2 == 0x0307 then
        -- on his feet and free: walk to jump-in range, then jump
        if adx > 150 then
            press(toward2, true)
        elseif adx < 110 then
            press(away2, true)
        elseif t > jump.t + 30 then
            press("P2 Up", true)
            press(toward2, true)
            jump.t = t
            jump.up_until = t + 2
            jump.n = jump.n + 1
            local phase = jump.n % 3
            jump.kick_at = (phase == 1 and t + 16)
                        or (phase == 2 and t + 3) or nil
        end
    end

    -- P1 crouches the whole time and uppercuts when P2 is airborne and close.
    -- Crouching is the uppercut's own requirement, so it is not a cheat: it
    -- is what a player holds while waiting for a jump-in.
    press("P1 Down", true)
    if air2 and adx < 78 and (t % 6) < 2 then
        press("P1 High Punch", true)
    end
end)

emu.register_stop(function()
    log("--- air hits, by what the victim was doing ---")
    for k, v in pairs(hits) do log("HITS   %-14s x%d", k, v) end
    log("--- what the classifier said ---")
    for k, v in pairs(words) do log("RESULT %-34s x%d", k, v) end
    --
    -- The verdict, spelled out rather than left to be read off the table:
    -- a live jump attack MUST get the word, and nothing else may.
    local bad, live = 0, 0
    for k, v in pairs(words) do
        local kind, word = k:match("^(.-) %-> (.+)$")
        if kind == "AIRATK-LIVE" then
            if word == "ANTIAIR" then live = live + v else bad = bad + v end
        elseif word == "ANTIAIR" then
            bad = bad + v
        end
    end
    log("VERDICT %s  (%d live jump attacks stuffed, %d wrong)",
        (bad == 0 and live > 0) and "PASS" or "FAIL", live, bad)
end)
