-- sweep_addon_dko.lua - what happens on a DOUBLE KO?
--
-- deferhit makes a genuine simultaneous exchange TRADE, and a trade at low
-- health kills BOTH fighters on the same tick. That state was essentially
-- unreachable before: only one fighter could ever land the killing blow, so
-- "both bars at zero, mid-round" is new territory that this ROM has never
-- entered.
--
-- It matters because of what the round-end code does with it. round_is_over
-- (MAIN.ASM) compares p1_bar against p2_bar and treats EQUAL as a tie, and
-- its_a_tie is a bare `retp`: no winner_status is set and neither player's
-- round count moves. Ties themselves are not novel - a timeout with equal
-- health reaches the same path - but a tie at ZERO, with two death
-- animations to play and no winner recorded, has never happened.
--
-- Unresolved rounds are this codebase's known hang class, so the question is
-- narrow and worth answering directly: after a double KO, does the round end?
--
-- METHOD. Both players human, mirror-matched, pinned at a symmetric distance,
-- both pressing High Kick on the same frame - the trade rig's setup, because
-- it is the one that reliably produces a simultaneous exchange. The only
-- change is that both bars are set LOW first, so the trade is lethal to both.
--
-- Then the rig STOPS TOUCHING ANYTHING and watches. No position writes, no
-- HP writes, no button presses - because the question is whether the GAME
-- resolves the state, and a rig still driving the fighters would answer a
-- different question.
--
-- Env:
--   DKO_HP=n     health both fighters start the lethal trial on (default 8;
--                a high kick does 32, so one hit is lethal either way)
--   DKO_DIST=n   the symmetric distance to trade at (default 82)
--   DKO_WATCH=n  frames to observe after the KO (default 900, ~16s)
--   DKO_TAG=...  output file tag

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("DKO_TAG") or "run"
local OUT = ROOT .. "/tools/dko_" .. TAG .. ".txt"

local HP    = tonumber(os.getenv("DKO_HP") or "") or 8
local DIST  = tonumber(os.getenv("DKO_DIST") or "") or 82
local WATCH = tonumber(os.getenv("DKO_WATCH") or "") or 900

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                sym[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate   = S("gstate")
local p1_obj, p2_obj   = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar   = S("p1_bar"), S("p2_bar")
local p1_rwon, p2_rwon = S("p1_rwon"), S("p2_rwon")
local winner_status    = S("winner_status")
local worldtlx = S("worldtlx")
if not (gstate and p1_proc and worldtlx and winner_status and p1_rwon) then
    print("[dko] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0, hit = 0x370 }
local O = { oxval = 0x080, oxpos = 0x090 }

local acts = {}
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+(%x+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end
local WANT_ACT = acts.act_hikick
-- High Punch is unusable here for the same reason as the trade rig: the
-- harness caches it for character select and zeroes it every fight frame.
local BTN1, BTN2 = "P1 High Kick", "P2 High Kick"

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[dko] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

-- Claim both sticks; the harness otherwise walks P1 to keep battles moving,
-- and a walking fighter picks a different move for the same button.
local ADDON_OWNS = _G.ADDON_OWNS or {}
for _, n in ipairs({ "P1 Left", "P1 Right", "P1 High Punch", "P2 High Punch" }) do
    ADDON_OWNS[n] = true
end

local space, frame, fight0, vx0 = nil, 0, 0, nil
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local ACT_STANCE = 0x0303
local t0, waited = nil, 0
local phase = "arm"          -- arm -> watch -> done
local ko_frame, watched = nil, 0
local pre = {}
local seen_gstate, gs_last = {}, nil
local hit1, hit2 = false, false
local f1, f2 = false, false
local lo1, lo2, dead_t, first_dead = nil, nil, nil, nil
local trace = {}

emu.register_frame(function()
    frame = frame + 1
    if phase == "done" then return end
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if fd.name == BTN1 or fd.name == BTN2 then fields[fd.name] = fd end
            end
        end
    end

    local gs = space:read_u16(gstate)

    -- Record every gstate the machine visits after the KO. A round that
    -- resolves leaves 2; one that does not, never does.
    if phase == "watch" and gs ~= gs_last then
        seen_gstate[#seen_gstate + 1] = string.format("%d@+%d", gs, watched)
        gs_last = gs
    end

    if phase == "watch" then
        watched = watched + 1
        -- HANDS OFF. Whether the GAME resolves this is the whole question.
        if watched >= WATCH then
            local ws = space:read_u16(winner_status)
            local b1, b2 = space:read_u16(p1_bar), space:read_u16(p2_bar)
            local w1, w2 = space:read_u16(p1_rwon), space:read_u16(p2_rwon)
            log("--- %d frames after the double KO ---", watched)
            log("  bars      p1=%d p2=%d", s16(b1), s16(b2))
            log("  rounds won  p1 %d -> %d   p2 %d -> %d",
                pre.w1, w1, pre.w2, w2)
            log("  winner_status %d -> %d", pre.ws, ws)
            log("  gstate visited: %s",
                #seen_gstate > 0 and table.concat(seen_gstate, " ") or "(never changed)")
            -- WHAT COUNTS AS PROGRESS, corrected. The first version looked
            -- for a gstate change or a round win, and a DRAW produces
            -- neither by design: its_a_tie awards nothing, and a round
            -- change inside a match never leaves gstate 2. The real
            -- evidence a tie replayed is the bars coming back to full.
            local refilled = (s16(b1) >= 0xa1) and (s16(b2) >= 0xa1)
            local progressed = refilled or (#seen_gstate > 0)
                               or (w1 > pre.w1) or (w2 > pre.w2)
            if refilled and w1 == pre.w1 and w2 == pre.w2 then
                log("  bars refilled with NO round awarded - a DRAW that replayed")
            end
            if progressed then
                log("VERDICT: the round RESOLVED - double KO is handled")
            else
                log("VERDICT: NOTHING MOVED - the round never ended after a")
                log("         double KO. gstate stayed %d, no round awarded,", gs)
                log("         winner_status unchanged. This is the hang.")
            end
            phase = "done"
        end
        return
    end

    if gs ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== double KO test: both at %d HP, trading High Kick at %d px ===",
            HP, DIST)
    end
    if frame - fight0 < 60 then return end

    if vx0 == nil then vx0 = s16(space:read_u16(worldtlx + 16)) + 250 end
    local vx = vx0
    space:write_u32(o2 + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx)
    local ax = vx - DIST
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    if t0 == nil then
        local n1 = space:read_u16(r1 + P.action)
        local n2 = space:read_u16(r2 + P.action)
        if n1 ~= ACT_STANCE or n2 ~= ACT_STANCE then
            waited = waited + 1
            if waited < 240 then return end
            log("  (starting dirty - a fighter never returned to stance)")
        end
        waited = 0
        t0 = frame
        -- LOW, so the trade is lethal to both. A high kick does 32.
        space:write_u16(p1_bar, HP)
        space:write_u16(p2_bar, HP)
        space:write_u16(r1 + P.hit, 0)
        space:write_u16(r2 + P.hit, 0)
        pre.ws = space:read_u16(winner_status)
        pre.w1 = space:read_u16(p1_rwon)
        pre.w2 = space:read_u16(p2_rwon)
    end
    local t = frame - t0

    -- HOLD the low health right up to the press. Writing it once at t0 was
    -- not enough - the bars read back at FULL, so something (round init, or
    -- the harness pin) puts them back. Stop at the press so the damage the
    -- exchange does is the game's, not ours.
    if t < 8 then
        space:write_u16(p1_bar, HP)
        space:write_u16(p2_bar, HP)
    end
    if t == 8 then
        log("  at the press: bars p1=%d p2=%d",
            s16(space:read_u16(p1_bar)), s16(space:read_u16(p2_bar)))
    end

    local press = (t >= 8 and t < 11)
    for _, fd in pairs(fields) do fd:set_value(press and 1 or 0) end

    local a1 = space:read_u16(r1 + P.action)
    local a2 = space:read_u16(r2 + P.action)
    if a1 == WANT_ACT then f1 = true end
    if a2 == WANT_ACT then f2 = true end
    if space:read_u16(r1 + P.hit) > 0 then hit1 = true end
    if space:read_u16(r2 + P.hit) > 0 then hit2 = true end

    -- SAMPLE EVERY FRAME, not at the end. The first version read the bars 90
    -- frames after the press and found them at 161 with p_hit zero, which
    -- looked like "nobody connected" and was the opposite: the round had
    -- already ended and reset both. A KO erases its own evidence, so catch
    -- the transition instead of the aftermath.
    local b1n, b2n = s16(space:read_u16(p1_bar)), s16(space:read_u16(p2_bar))
    if lo1 == nil or b1n < lo1 then lo1 = b1n end
    if lo2 == nil or b2n < lo2 then lo2 = b2n end
    if t >= 8 and t <= 46 then
        trace[#trace + 1] = string.format("%d:%d/%d", t, b1n, b2n)
    end
    if b1n <= 0 and b2n <= 0 and dead_t == nil then
        dead_t = t
    end
    if (b1n <= 0 or b2n <= 0) and first_dead == nil then
        first_dead = string.format("t=%d p1=%d p2=%d", t, b1n, b2n)
    end

    if t >= 90 then
        local b1, b2 = s16(space:read_u16(p1_bar)), s16(space:read_u16(p2_bar))
        log("  both moves came out: p1=%s p2=%s | p_hit p1=%d p2=%d",
            tostring(f1), tostring(f2),
            space:read_u16(r1 + P.hit), space:read_u16(r2 + P.hit))
        log("  bars after the exchange: p1=%d p2=%d", b1, b2)
        log("  bar trace t:p1/p2  %s", table.concat(trace, " "))
        log("  lowest bars seen: p1=%d p2=%d | first zero: %s",
            lo1 or -999, lo2 or -999, first_dead or "never")
        if dead_t then
            log("  BOTH bars reached zero at t=%d", dead_t)
        end
        -- ORDER MATTERS. p_hit is cleared by the round reset, so by the time
        -- this runs a real double KO reads p_hit 0/0 and the old ordering
        -- called it "nobody connected". Both bars reaching zero on one tick
        -- is the reliable evidence; test it FIRST.
        if dead_t then
            ko_frame = frame
            gs_last = space:read_u16(gstate)
            log("  DOUBLE KO at t=%d. Watching %d frames, hands off.",
                dead_t, WATCH)
            for _, fd in pairs(fields) do fd:set_value(0) end
            phase = "watch"
            return
        end
        if not (hit1 and hit2) then
            log("  NOT A DOUBLE KO - only one side connected, nothing to test.")
            log("VERDICT: inconclusive (no simultaneous lethal exchange)")
            phase = "done"
            return
        end
        if not dead_t then
            log("  both never hit zero together - not a double KO")
            log("VERDICT: inconclusive (trade was not lethal to both)")
            phase = "done"
            return
        end
        ko_frame = frame
        gs_last = space:read_u16(gstate)
        log("  DOUBLE KO reached. Watching %d frames, hands off.", WATCH)
        -- release both buttons and stop driving
        for _, fd in pairs(fields) do fd:set_value(0) end
        phase = "watch"
    end
end)

emu.register_stop(function()
    if phase == "arm" then log("no trial ran - the fight never started") end
end)
