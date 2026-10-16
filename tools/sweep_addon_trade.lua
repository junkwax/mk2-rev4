-- sweep_addon_trade.lua - is there a player-1 side advantage?
--
-- The question that matters is not whether the code mentions p1_obj (it does,
-- to pick which life bar to reduce) but what happens when both players' strike
-- checks land on the SAME TICK. MK2 dispatches processes from one list in one
-- order, and a fighter who is hit is transferred to a reaction routine - so if
-- P1's check runs first, P2 is already reacting when his own check would have
-- run, and P1 wins every trade. That is the classic side advantage and it is
-- measurable rather than arguable.
--
-- Both players are human, pinned at an exact symmetric distance, and both
-- press the SAME button on the SAME frame. The outcome of each trial is one
-- of: only P2 took damage (P1 won), only P1 took damage (P2 won), both took
-- damage (a true trade), or neither connected.
--
-- Every trial verifies BOTH actions fired. A trial where only one player's
-- move came out is not a trade and is discarded, not scored - otherwise a
-- dropped input reads as a side advantage, which is exactly the kind of
-- artefact this rig exists to avoid.
--
-- TRADE_MOVE=hikick|punch   which button both players press (default hikick)
-- TRADE_TAG=...             output file tag

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MOVE = (os.getenv("TRADE_MOVE") or "hikick"):lower()
local TAG = os.getenv("TRADE_TAG") or "run"
local OUT = ROOT .. "/tools/trade_" .. TAG .. ".txt"

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
local gstate = S("gstate")
local p1_obj, p2_obj = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
local worldtlx = S("worldtlx")
if not (gstate and p1_proc and worldtlx) then
    print("[trade] symbols missing - addon disabled"); return
end

-- p_hit, not the life bar.  The sweep harness pins p1_bar to full every frame
-- to keep its battles running, so P1 taking damage is INVISIBLE through HP and
-- the first run scored 0 for both sides.  p_hit is the engine's own count of
-- hits taken and nothing pins it.
local P = { action = 0x1f0, hit = 0x370, hitby = 0x360 }
local O = { oxval = 0x080, oxpos = 0x090 }
local MAX_HP = 0xa1

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
-- High Punch is not usable here: the sweep harness caches "P1 High Punch" for
-- character select and zeroes it every frame of the fight, so P1's punch never
-- comes out.  High Kick is not in its cache.
local WANT_ACT = (MOVE == "punch") and acts.act_hipunch or acts.act_hikick
local BTN1 = (MOVE == "punch") and "P1 High Punch" or "P1 High Kick"
local BTN2 = (MOVE == "punch") and "P2 High Punch" or "P2 High Kick"

-- distances stepped so the result is not one lucky spacing
-- TRADE_FLIP=1 puts P1 on the RIGHT instead of the left.  A mirror match rules
-- out the character; this rules out the remaining confound, which is whether
-- the winner is "player two" or "whoever stands on the right".
local FLIP = os.getenv("TRADE_FLIP") == "1"

-- THE BAND MATTERS MORE THAN THE COUNT.  The first version swept 56..96 and
-- scored ONE trial in eleven: knee_check turns a high kick into a KNEE at
-- close range, so most of that range never produced the move being measured
-- and every such trial was correctly discarded. A rig that discards 10 of 11
-- is not measuring a side advantage, it is measuring knee_check.
--
-- So sweep further out and finer, where both fighters keep the high kick and
-- it still reaches. Overridable, because the usable band moves with the
-- characters the battle happens to use.
local D_FROM = tonumber(os.getenv("TRADE_FROM") or "") or 78
local D_TO   = tonumber(os.getenv("TRADE_TO") or "") or 116
local D_STEP = tonumber(os.getenv("TRADE_STEP") or "") or 2
local TRIAL = 90

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[trade] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

-- CLAIM BOTH STICKS. The harness walks P1 through the fight to keep battles
-- moving, which is right for a stability sweep and fatal for a symmetry test:
-- a fighter who is walking picks a different move for the same button than one
-- who is standing. Neither player may be driven by anything but this rig.
local ADDON_OWNS = _G.ADDON_OWNS or {}
ADDON_OWNS["P1 Left"] = true
ADDON_OWNS["P1 Right"] = true
ADDON_OWNS["P1 High Punch"] = true
ADDON_OWNS["P2 High Punch"] = true

local space, frame, fight0, vx0 = nil, 0, 0, nil
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local dist, t0, cur = D_FROM, nil, nil
local drops = {}
local waited, forced = 0, 0
local tally = { p1win = 0, p2win = 0, trade = 0, neither = 0, dropped = 0 }
local rows = {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if fd.name == BTN1 or fd.name == BTN2 then
                    fields[fd.name] = fd
                end
            end
        end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== trade test, %s, both human, %d..%d px, P1 on the %s ===",
            MOVE, D_FROM, D_TO, FLIP and "RIGHT" or "left")
    end
    local rel = frame - fight0
    if rel < 60 then return end
    if dist > D_TO then return end

    if vx0 == nil then vx0 = s16(space:read_u16(worldtlx + 16)) + 250 end
    -- right-hand fighter at vx0, left-hand fighter dist to his left
    local rightobj = FLIP and o1 or o2
    local leftobj  = FLIP and o2 or o1
    local vx = vx0
    space:write_u32(rightobj + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(rightobj + O.oxpos, vx)
    local ax = vx - dist
    space:write_u32(leftobj + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(leftobj + O.oxpos, ax)

    -- BOTH FIGHTERS MUST START THE TRIAL NEUTRAL.
    --
    -- Trials ran back to back, so at close range P2's move connected, P1 was
    -- still in a reaction when the next trial's press window opened, and he
    -- never acted at all - which then repeated, because he was hit again.
    -- That is self-reinforcing and reads exactly like a side advantage: the
    -- first run showed P1 producing NO attack at 56..84 and P2 producing one
    -- at every distance. It was scoring who got hit first in the PREVIOUS
    -- trial.
    --
    -- So wait for both to be back in stance. Bounded, because a fighter stuck
    -- forever must not hang the sweep - a trial that has to be forced is
    -- counted separately rather than scored, since it is not a clean start.
    local ACT_STANCE = 0x0303
    if t0 == nil then
        local n1 = space:read_u16(r1 + P.action)
        local n2 = space:read_u16(r2 + P.action)
        if n1 ~= ACT_STANCE or n2 ~= ACT_STANCE then
            waited = waited + 1
            if waited < 240 then return end
            forced = forced + 1
        end
        waited = 0
        t0 = frame
        cur = { f1 = false, f2 = false, h1 = false, h2 = false,
                a1 = 0, a2 = 0 }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
        -- ...and clear the hit counters, or a count left over from the last
        -- trial is read as a hit in this one before anybody has moved.
        space:write_u16(r1 + P.hit, 0)
        space:write_u16(r2 + P.hit, 0)
    end
    local t = frame - t0

    -- SAME frame, both players, same button
    -- knee_check converts a high kick to a KNEE at close range, so a trial
    -- that comes back act_knee is a discarded trial, not a lost exchange
    local press = (t >= 8 and t < 11)
    for n, fd in pairs(fields) do fd:set_value(press and 1 or 0) end

    local act1, act2 = space:read_u16(r1 + P.action), space:read_u16(r2 + P.action)
    if act1 == WANT_ACT then cur.f1 = true end
    if act2 == WANT_ACT then cur.f2 = true end
    -- remember the first ATTACK either of them actually produced, so a
    -- discarded trial can say what came out instead of the move we wanted
    if cur.a1 == 0 and act1 ~= 0 and (act1 & 0xff00) == 0x0100 then cur.a1 = act1 end
    if cur.a2 == 0 and act2 ~= 0 and (act2 & 0xff00) == 0x0100 then cur.a2 = act2 end
    if space:read_u16(r1 + P.hit) > 0 then cur.h1 = true end
    if space:read_u16(r2 + P.hit) > 0 then cur.h2 = true end

    if t >= TRIAL then
        local outcome
        if not (cur.f1 and cur.f2) then
            outcome = "dropped"
            tally.dropped = tally.dropped + 1
            drops[#drops + 1] = string.format("%d:p1=%04xh p2=%04xh",
                                              dist, cur.a1, cur.a2)
        elseif cur.h1 and cur.h2 then
            outcome = "trade"; tally.trade = tally.trade + 1
        elseif cur.h2 then
            outcome = "p1win"; tally.p1win = tally.p1win + 1
        elseif cur.h1 then
            outcome = "p2win"; tally.p2win = tally.p2win + 1
        else
            outcome = "neither"; tally.neither = tally.neither + 1
        end
        rows[#rows + 1] = string.format("%3d:%s", dist, outcome:sub(1, 2))
        dist = dist + D_STEP
        t0 = nil
    end
end)

emu.register_stop(function()
    if #rows == 0 then log("no trials ran"); return end
    log("%s", table.concat(rows, "  "))
    local scored = tally.p1win + tally.p2win + tally.trade + tally.neither
    log("P1 won %d   P2 won %d   both hit %d   neither %d   discarded %d",
        tally.p1win, tally.p2win, tally.trade, tally.neither, tally.dropped)
    if forced > 0 then
        log("  %d trial(s) STARTED DIRTY - a fighter never returned to stance",
            forced)
    end
    if #drops > 0 then
        -- what came out instead. 0000h means no attack at all; anything else
        -- is a different move, usually the knee, and says the band is wrong
        -- rather than the input being lost.
        log("  discarded: %s", table.concat(drops, "  "))
    end
    if scored == 0 then
        log("VERDICT: no trial produced both moves - nothing measured")
    elseif tally.p1win > 0 and tally.p2win == 0 and tally.trade == 0 then
        log("VERDICT: P1 won every scored exchange - a real side advantage")
    elseif tally.p2win > 0 and tally.p1win == 0 and tally.trade == 0 then
        log("VERDICT: P2 won every scored exchange - a real side advantage")
    elseif tally.trade == scored then
        log("VERDICT: every exchange traded - neither side is favoured")
    else
        log("VERDICT: mixed - P1 %d%%, P2 %d%%, trades %d%% of %d scored",
            math.floor(100 * tally.p1win / scored),
            math.floor(100 * tally.p2win / scored),
            math.floor(100 * tally.trade / scored), scored)
    end
end)
