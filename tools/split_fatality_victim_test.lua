-- split_fatality_victim_test.lua
--
-- A fatality performed ON a chosen victim, to prove the VICTIM-indexed tables
-- resolve for that fighter.  Two attackers, two different failures:
--
--   SFV_ATTACKER=kunglao  SPLIT IN 2.  r_split_in_2 picks the half-body lane
--                         out of split_in_2_tab with the victim's ochar, and
--                         rows 14-16 were retail PADS - Noob (15) inherited
--                         a_fn_split (female art) and Jade (16) inherited
--                         a_nj_split (male ninja).  A picture, not a crash.
--   SFV_ATTACKER=reptile  TONGUE head rip.  do_tongue reads head_lineups with
--                         the victim's ochar, and words 3-4 of that row are an
--                         ANIMATION index and a frame offset.  The table had
--                         16 rows, so Jade (16) built an animation pointer out
--                         of do_rip's opcodes: a wild jump, i.e. the hang.
--
--   SFV_VICTIM=jade     P2 unlocks Jade at the select screen (Mileena + LK x5)
--   SFV_VICTIM=kitana   P2 stays Kitana   - the reference female split
--   SFV_VICTIM=subzero  P2 stays Sub-Zero - the reference ninja split
--
-- The rig coins a 2-PLAYER game so the victim is a human who stands still: a
-- drone would wander out of the distance window the fatality handler checks
-- before it will hand off to do_fatality_1.
--
-- The verdict is a live one - the fatality has to START (f_death goes
-- non-zero) and the game has to still be running afterwards.  WHICH art it
-- used is a picture, so snapshots are taken across the split and the peel.
--
--   SFV_LOG   log path

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("SFV_VICTIM") or "jade"):lower()
local ATK    = (os.getenv("SFV_ATTACKER") or "kunglao"):lower()
local LOG    = os.getenv("SFV_LOG") or (ROOT .. "/tools/split_fatality_" .. ATK .. "_" .. VICTIM .. ".log")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[sfv/" .. ATK .. "-" .. VICTIM .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    raw(line); logfh:write(line, "\n"); logfh:flush()
end

-- ------------------------------------------------------------------ symbols
local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "curback", "p1_obj", "p2_obj",
               "f_death", "c_jade_cheat2", "f_jade_cheat2" }
local A = {}
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end

-- DISPEQU.ASM object offsets, in bits - MAME's program space is bit-addressed.
local O_OXVAL, O_OXPOS = 0x080, 0x090
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_HATHEAD, FT_FN1, FT_FN2, FT_SUBZERO, FT_JADE = 0, 4, 5, 8, 16
local FT_REPTILE = 9

-- Each attacker: who P1 must be, how far apart the fatality wants them, and
-- the input, as {field, first frame, last frame} inside one attempt.  Both
-- sequences finish inside the combo window the handler checks (034h ticks for
-- Kung Lao, 028h for Reptile).
local ATTACKERS = {
    kunglao = { char = FT_HATHEAD, dist = 0x70,
                seq = { { "P1 Right", 0, 5 }, { "P1 Right", 12, 17 },
                        { "P1 Right", 24, 29 }, { "P1 Low Kick", 38, 43 } } },
    -- combo_look_lr ANCHORS the newest queue entry on the pattern's last
    -- direction (the joyskip block in MOVES.ASM): it may not be skipped over.
    -- Spread the taps out and something else lands in the queue first and the
    -- press arrives as a plain standing jab - watched happening in this rig's
    -- own c=45 snapshot.  These are the tap widths every other combo rig in
    -- tools/ uses: 4 on, 2 off, button 2 ticks behind the last release.
    reptile = { char = FT_REPTILE, dist = 0xc0, sweep = true,
                keys = { "P1 Left", "P1 Left", "P1 Down" }, button = "P1 Low Punch" },
}

local ATTACK = ATTACKERS[ATK]
if not ATTACK then log("FATAL: unknown SFV_ATTACKER '%s'", ATK); ATTACK = ATTACKERS.kunglao end

-- Reptile's Back,Back,Down + LP would not fire at any one hand-picked rhythm,
-- so each retry inside the FINISH HIM window plays it at a different one: the
-- gap between taps walks 4-10 ticks and the button lands 2-6 ticks behind the
-- last release.  The widest of these is 38 ticks end to end, still inside the
-- 028h window scom_rp_db1 allows.
local function sweep_seq(n)
    local g = 4 + 2 * ((n - 1) % 4)
    local b = 2 + 2 * (((n - 1) // 4) % 3)
    local seq = {}
    for i, k in ipairs(ATTACK.keys) do
        local t = (i - 1) * (4 + g)
        seq[#seq + 1] = { k, t, t + 4 }
    end
    local last = (#ATTACK.keys - 1) * (4 + g) + 4
    seq[#seq + 1] = { ATTACK.button, last + b, last + b + 6 }
    return seq
end

-- who P2 hovers at the select screen, and what he must end up as
local VICTIMS = {
    jade    = { hover = FT_FN2,     want = FT_JADE,    cheat = "lk" },
    kitana  = { hover = FT_FN1,     want = FT_FN1,     cheat = nil  },
    subzero = { hover = FT_SUBZERO, want = FT_SUBZERO, cheat = nil  },
}
local V = VICTIMS[VICTIM]
if not V then log("FATAL: unknown SFV_VICTIM '%s'", VICTIM); V = VICTIMS.jade end

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, combo_at, death_at = 0, 0, 0, 0
local done, phase, pulse0 = false, "boot", 0
local last_ws, snaps, tries = -1, 0, 0
local probe = {}

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1, ["P1 Low Kick"]=1,
                   ["P1 Right"]=1, ["P1 Left"]=1, ["P1 Down"]=1,
                   ["P2 Low Punch"]=1, ["P2 Low Kick"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

-- Park P1 a given pixel distance to the LEFT of P2.  oxpos alone is rewritten
-- before the draw, so the 16.16 master oxval has to move with it.
local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

-- Reptile's tongue wants 0a0h-0e0h between them.  Pulling P1 back that far
-- from a corner KO just walks him into the edge limit and the gap collapses,
-- so the pair is spread around its own midpoint instead of anchoring on P2.
local function snap_to(dist)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local x1, x2 = r16(p1o + O_OXPOS), r16(p2o + O_OXPOS)
    local mid = (x1 + x2) // 2
    place(p1o, mid - dist // 2)
    place(p2o, mid + dist - dist // 2)
end

local function gap()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return -1 end
    local d = r16(p2o + O_OXPOS) - r16(p1o + O_OXPOS)
    return d
end

local function snap()
    snaps = snaps + 1
    manager.machine.video:snapshot()
end

local function verdict()
    local ok, why = true, {}
    local p1c, p2c = r16(A.p1_char), r16(A.p2_char)
    log("p1_char=%d (want %d)  p2_char=%d (want %d)", p1c, ATTACK.char, p2c, V.want)
    if p1c ~= ATTACK.char then ok = false; why[#why+1] = "P1 is not the requested attacker" end
    if p2c ~= V.want then ok = false; why[#why+1] = "P2 is not the requested victim" end
    if finish_at == 0 then ok = false; why[#why+1] = "no FINISH HIM window" end
    if death_at == 0 then
        ok = false; why[#why+1] = "the fatality never started (f_death stayed 0)"
    else
        log("fatality started at frame %d (+%d after FINISH HIM), %d input attempt(s)",
            death_at, death_at - finish_at, tries)
        log("post-fatality gstate probe: %s", table.concat(probe, ","))
        if #probe > 0 and probe[#probe] == 0 then
            ok = false; why[#why+1] = "gstate went to 0 - the game reset"
        end
    end
    log("%d snapshot(s) written", snaps)
    log("%s %s on %s%s", ok and "PASS" or "FAIL", ATK, VICTIM,
        ok and "" or ("  -- " .. table.concat(why, "; ")))
end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
    end
    frame = frame + 1
    local gs = r16(A.gstate)

    if psel == 0 and gs == GS_PSEL then
        psel = frame
        log("select screen at frame %d", frame)
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)

    elseif confirm == 0 then
        local rel = frame - psel
        -- P1 parks on Kung Lao for the whole select; P2 parks on the victim's
        -- base square until the unlock commits (stamping the base id back even
        -- once undoes it - see jade_finish_gate_test.lua).
        if gs == GS_PSEL then
            w16(A.p1_char, ATTACK.char)
            if r16(A.f_jade_cheat2) == 0 and r16(A.p2_char) ~= V.want then
                w16(A.p2_char, V.hover)
            end
        end

        if V.cheat == "lk" then
            if rel == 60 then pulse0 = frame; phase = "pulsing"; log("pulsing P2 Low Kick x5") end
            if phase == "pulsing" then
                local p = frame - pulse0
                if (p // 10) < 5 then
                    hold("P2 Low Kick", (p % 10) < 5)
                else
                    hold("P2 Low Kick", false)
                    if phase ~= "post" then
                        phase = "post"
                        log("pulses done c=%d f=%d", r16(A.c_jade_cheat2), r16(A.f_jade_cheat2))
                    end
                end
            end
        elseif rel == 60 and phase == "boot" then
            phase = "post"
            log("no cheat needed - confirming both players")
        end

        if phase == "post" and rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and phase == "post" then
            confirm = frame
            log("select done at frame %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            for n in pairs(fields) do hold(n, false) end
        end

    else
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: curback=%d p1_char=%d p2_char=%d",
                frame, r16(A.curback), r16(A.p1_char), r16(A.p2_char))
        end

        if fight_at > 0 and armed_at == 0 and frame - fight_at == 60 then
            armed_at = frame
            w16(A.p1_matchw, 1)   -- this round takes the match, so FINISH HIM runs
            w16(A.p2_bar, 1)      -- one clean jab ends it
            log("armed: p1_matchw=1 p2_bar=1")
        end

        -- knock the victim out with jabs from jab range
        if armed_at > 0 and ko_at == 0 then
            snap_to(60)
            hold("P1 High Punch", (frame % 12) < 5)
            if r16(A.p2_bar) == 0 then
                ko_at = frame
                hold("P1 High Punch", false)
                log("KO at frame %d", frame)
            end
        end

        if ko_at > 0 then
            local ws = r16(A.winner_status)
            if ws ~= last_ws then log("  +%3d winner_status=%d gstate=%d", frame - ko_at, ws, gs); last_ws = ws end
            if ws == 3 and finish_at == 0 then
                finish_at = frame
                log("FINISH HIM at frame %d", frame)
            end
        end

        -- Park them at the distance this fatality wants, then play the input.
        -- Snapping every frame also cancels the walk the direction taps would
        -- otherwise cause, so the range holds across the whole attempt.
        if finish_at > 0 and death_at == 0 then
            local rel = frame - finish_at
            if rel < 400 then snap_to(ATTACK.dist) end
            if rel == 60 then combo_at = frame; tries = 1; log("driving the %s fatality input", ATK) end
            if combo_at > 0 then
                local c = frame - combo_at
                local seq = ATTACK.sweep and sweep_seq(tries) or ATTACK.seq
                -- A sequence taps the SAME key more than once (Back,Back,Down),
                -- so the windows have to be OR-ed: setting each step in turn
                -- lets a later window's "not now" overwrite an earlier window's
                -- press and the motion collapses to its last tap.
                local want = {}
                for _, step in ipairs(seq) do
                    if c >= step[2] and c < step[3] then want[step[1]] = true end
                end
                for _, step in ipairs(seq) do hold(step[1], want[step[1]] == true) end
                if c == 45 and tries <= 2 then
                    log("  attempt %d: gap=%d (want %d)", tries, gap(), ATTACK.dist)
                    snap()
                end
                if c == 0 and ATTACK.sweep then
                    local q = sweep_seq(tries)
                    log("  attempt %d rhythm: %s", tries,
                        string.format("%s@%d %s@%d %s@%d %s@%d",
                            q[1][1], q[1][2], q[2][1], q[2][2],
                            q[3][1], q[3][2], q[4][1], q[4][2]))
                end
                if c >= 60 then
                    for _, step in ipairs(seq) do hold(step[1], false) end
                    if c >= 75 then
                        combo_at = frame
                        tries = tries + 1
                        log("no fatality yet - retrying the input (attempt %d)", tries)
                    end
                end
            end
            if r16(A.f_death) ~= 0 then
                death_at = frame
                for n in pairs(fields) do hold(n, false) end
                log("f_death=%d at frame %d (+%d)", r16(A.f_death), frame, frame - finish_at)
                snap()
            end
        end

        if death_at > 0 then
            local rel = frame - death_at
            -- the slice, the split, the peel, and the rest afterwards
            if rel == 60 or rel == 110 or rel == 150 or rel == 200 or rel == 260
               or rel == 330 or rel == 420 then snap() end
            if rel > 0 and rel % 60 == 0 and #probe < 12 then probe[#probe + 1] = gs end
            if rel > 720 then done = true; verdict(); manager.machine:exit() end
        end

        if finish_at > 0 and death_at == 0 and frame - finish_at > 1200 then
            snap()
            done = true; log("fatality window closed without a fatality"); verdict(); manager.machine:exit()
        end
        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then
            done = true; log("never landed a KO"); verdict(); manager.machine:exit()
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end

    if frame > 12000 and not done then
        done = true
        log("timeout phase=%s psel=%d confirm=%d fight=%d ko=%d finish=%d death=%d",
            phase, psel, confirm, fight_at, ko_at, finish_at, death_at)
        verdict(); manager.machine:exit()
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
