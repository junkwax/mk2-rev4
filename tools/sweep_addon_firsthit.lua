-- sweep_addon_firsthit.lua - does FIRST HIT actually mark the first hit?
--
-- The hudcall rig cannot answer this, for two reasons, and between them they
-- are why it reported 0 mismatches on a word that visibly misbehaves:
--
--   1. It gives FIRST HIT a free pass. Its classifier models the VICTIM's
--      action, and "first hit of the round" is not a property of the victim's
--      action at all, so the check degenerates to
--          or (name == "FIRST HIT" and counts["FIRST HIT"] >= 1)
--      which is true of every FIRST HIT it will ever see.
--
--   2. Rounds never end there. The harness's HP pin refills p1_bar AND forces
--      winner_status back to 0, so one round runs forever. FIRST HIT is armed
--      once per round and cleared by round_init_words, so the rig saw exactly
--      one - and one sample is not a test of a once-per-round flag.
--
-- What this checks, per round:
--
--   * exactly one FIRST HIT - not zero, not two
--   * armed by the player who took the round's first chunk out of the other
--     bar, which is what landing the first hit means
--   * armed at that moment, not seconds later
--
-- The life bar is the ground truth deliberately. It is downstream of every
-- path a hit can take - normal strike, projectile, throw - so it cannot agree
-- with a mistake in the ladder the way a state model can.
--
-- Keeping a fight on screen long enough to see several rounds takes some
-- care. Left alone the drones kill each other, the match ends, and gstate
-- goes to gameover and then attract - where the DEMO fight still moves bars
-- and still arms callouts, so a rig that is not watching gstate happily
-- scores the attract loop as rounds. That is what the first version of this
-- did. So: pin p1_bar AFTER reading it (p1 cannot lose the match, but a hit
-- ON p1 is still seen as damage and still credited to p2), and drain p2 once
-- the round has been measured, which ends it honestly and starts the next.
--
-- Env: FIRSTHIT_LOG.  Driven by run_firsthit_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("FIRSTHIT_LOG") or (ROOT .. "/tools/firsthit.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
    "P2 High Punch","P2 Low Punch","P2 High Kick","P2 Low Kick","P2 Block",
}) do ADDON_OWNS[n] = true end

local space, fields = nil, {}
local logf = io.open(OUT, "w")
local function log(fmt, ...)
    local s = "[firsthit] " .. string.format(fmt, ...)
    print(s)
    if logf then logf:write(s .. "\n"); logf:flush() end
end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

local MAXHP = 0xa1
local GS_FIGHTING, GS_ROUND_INTRO = 0x02, 0x07
local OXVAL = 0x80
local WORDS = {
    [sym.hc_kounter_s] = "KOUNTER",      [sym.hc_punish]   = "PUNISH",
    [sym.hc_reversal]  = "REVERSAL",     [sym.hc_firsthit] = "FIRST HIT",
    [sym.hc_blockpun]  = "BLOCK PUNISH", [sym.hc_whiffpun] = "WHIFF PUNISH",
    [sym.hc_antiair]   = "ANTI-AIR",
    [sym.hc_flawblk]   = "FLAWLESS BLOCK",
}

local t, prev_gs = 0, 0
local fought = true      -- the first intro counts
local prev_bar  = { [0] = MAXHP, [1] = MAXHP }
local prev_arms = { [0] = nil, [1] = nil }
local round_n, in_round, live_t = 0, false, 0
local first_dmg_t, first_dmg_by
local fh_count, fh_t, fh_by = 0, nil, nil
local drained = false
local rounds = {}
local cut, fh_live = {}, nil
local LIFE = 0x15 + 2 + 0x48 + 10   -- MK3's message life, as cal_fly runs it

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local function close_round()
    if not in_round then return end
    in_round = false
    if not first_dmg_t and fh_count == 0 then return end
    rounds[#rounds + 1] = { n = round_n, dmg_t = first_dmg_t,
        dmg_by = first_dmg_by, fh = fh_count, fh_t = fh_t, fh_by = fh_by }
end

emu.register_frame(function()
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== FIRST HIT === once a round, to whoever landed it?")
    end
    t = t + 1

    local gs = space:read_u16(sym.gstate) & 0xffff
    -- A round only starts if the game actually FOUGHT since the last intro.
    -- gstate re-enters gs_round_intro more than once per round (it passes
    -- through on the way back out too), and counting each one split single
    -- rounds in half: the half with the arming looked like "FIRST HIT before
    -- any damage" and the other half like a round where nothing happened.
    if gs == GS_ROUND_INTRO and prev_gs ~= GS_ROUND_INTRO and fought then
        close_round()
        round_n = round_n + 1
        in_round, live_t, drained, fought = true, 0, false, false
        fh_live = nil
        first_dmg_t, first_dmg_by = nil, nil
        fh_count, fh_t, fh_by = 0, nil, nil
        log("--- round %d: intro at frame %d", round_n, t)
    elseif gs ~= prev_gs and (gs == 0x0b or gs == 0x01) then
        log("    [gstate -> %#04x at %d: match over; nothing after this is a"
            .. " round]", gs, t)
        close_round()
    end
    prev_gs = gs
    if gs ~= GS_FIGHTING then return end
    fought = true
    live_t = live_t + 1

    -- Bars read BEFORE p1 is pinned, so a hit on p1 still registers as this
    -- round's first damage and is still credited to p2.
    local b = { [0] = space:read_u16(sym.p1_bar) & 0xffff,
                [1] = space:read_u16(sym.p2_bar) & 0xffff }

    -- Seed on the round's first live frame, then compare from the second.
    -- A grace window was wrong here: skipping the comparison while still
    -- advancing prev_bar SWALLOWS a hit landing in those frames, and the
    -- FIRST HIT the ROM correctly armed for it then reads as "armed before
    -- any damage". Both of this rig's failures were that, not the ROM's.
    if live_t == 1 then
        prev_bar[0], prev_bar[1] = b[0], b[1]
        log("    round %d live at %d, bars %d / %d", round_n, t, b[0], b[1])
    end
    if in_round and not first_dmg_t and live_t > 1 then
        for i = 0, 1 do
            if b[i] < prev_bar[i] then
                first_dmg_t, first_dmg_by = t, 1 - i
                log("    first damage at %d (+%d into the round): p%d %d -> %d,"
                    .. " so p%d landed it", t, live_t, i + 1, prev_bar[i], b[i],
                    (1 - i) + 1)
                break
            end
        end
    end

    for i = 0, 1 do
        local arms = space:read_u16(sym.cal_arms + i * 16) & 0xffff
        if prev_arms[i] and arms ~= prev_arms[i] and in_round then
            local w = space:read_u32(sym.cal_word + i * 32) & 0xffffffff
            local name = WORDS[w] or string.format("?%08x", w)
            if name == "FIRST HIT" then
                fh_count = fh_count + 1
                if not fh_t then fh_t, fh_by = t, i end
                fh_live = { by = i, at = t }
            elseif fh_live and fh_live.by == i and (t - fh_live.at) < LIFE then
                -- Same player armed something else while his FIRST HIT was
                -- still flying. cal_arm_word opens with cot_kill, so the new
                -- word REPLACES it - "there can be only 1". On screen that is
                -- FIRST HIT appearing and being wiped part way through.
                cut[#cut+1] = { at = t, after = t - fh_live.at, by = i, w = name }
                log("    FIRST HIT p%d REPLACED by %s after %d of %d ticks",
                    i + 1, name, t - fh_live.at, LIFE)
                fh_live = nil
                log("    FIRST HIT armed by p%d at frame %d%s", i + 1, t,
                    first_dmg_t
                    and string.format(" (%+d from the first damage)", t - first_dmg_t)
                    or  "  <-- BEFORE any damage this round")
            end
        end
        prev_arms[i] = arms
    end
    prev_bar[0], prev_bar[1] = b[0], b[1]

    -- p1 cannot lose: a game over ends the match and drops into attract, and
    -- the demo fight there would go on arming callouts that are not rounds.
    space:write_u16(sym.p1_bar, MAXHP)

    -- Once this round has been measured, end it so the next one starts.
    if in_round and not drained and first_dmg_t and (t - first_dmg_t) > 90 then
        space:write_u16(sym.p2_bar, 0)
        drained = true
    end

    -- Drive a fight: p2 snapped in and out of range so moves both connect and
    -- whiff, p1 attacking on a short cycle so a first hit happens early.
    local o1 = space:read_u32(sym.p1_obj) & 0xffffffff
    local o2 = space:read_u32(sym.p2_obj) & 0xffffffff
    if o1 ~= 0 and o2 ~= 0 then
        local x1 = s16((space:read_u32(o1 + OXVAL) >> 16) & 0xffff)
        local x2 = s16((space:read_u32(o2 + OXVAL) >> 16) & 0xffff)
        local gap = ((t % 140) >= 70) and 132 or 50
        local tx = (x1 < x2) and (x1 + gap) or (x1 - gap)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end
    local c = t % 22
    press("P1 High Punch", c == 0 or c == 1)
    press("P1 High Kick",  c == 7 or c == 8)
    press("P1 Low Kick",   c == 14 or c == 15)
    local d = t % 31
    press("P2 High Kick",  d == 18 or d == 19)
    press("P2 High Punch", d == 26 or d == 27)
end)

emu.register_stop(function()
    close_round()
    log("")
    log("=== %d round(s) observed", #rounds)
    local bad, judged = 0, 0
    for _, r in ipairs(rounds) do
        if not r.dmg_t then
            log("round %d: no damage landed - not judged (FIRST HIT x%d)", r.n, r.fh)
        else
            judged = judged + 1
            local why = {}
            if r.fh == 0 then why[#why+1] = "never armed"
            elseif r.fh > 1 then why[#why+1] = string.format("armed %d times", r.fh) end
            if r.fh > 0 and r.fh_by ~= r.dmg_by then
                why[#why+1] = string.format("armed by p%d, p%d landed the hit",
                                            r.fh_by + 1, r.dmg_by + 1) end
            if r.fh > 0 and r.fh_t and math.abs(r.fh_t - r.dmg_t) > 4 then
                why[#why+1] = string.format("%+d frames off the hit",
                                            r.fh_t - r.dmg_t) end
            if #why == 0 then
                log("round %d: OK - one FIRST HIT, p%d, on the hit", r.n, r.dmg_by + 1)
            else
                bad = bad + 1
                log("round %d: BAD - %s", r.n, table.concat(why, "; "))
            end
        end
    end
    log("")
    log("=== FIRST HIT cut short in %d of %d rounds", #cut, judged)
    for _, c in ipairs(cut) do
        log("    p%d: replaced by %s after %d ticks (%.1f%% of its life)",
            c.by + 1, c.w, c.after, c.after * 100 / LIFE)
    end
    if judged == 0 then log("VERDICT NO-CASE - no round got far enough to judge")
    elseif bad == 0 then log("VERDICT PASS - FIRST HIT correct in all %d rounds", judged)
    else log("VERDICT FAIL - wrong in %d of %d rounds", bad, judged) end
    if logf then logf:close() end
end)
