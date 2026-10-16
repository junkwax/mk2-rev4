--
-- deadpool_rotation_probe.lua - WHO IS HANGING OVER THE ACID, match by match.
--
-- THE DEAD POOL hangs THREE of its nine bodies now (hp_pick_lineup, MKHANG.ASM)
-- and picks a new three when a match starts.  This forces a 2-player idle
-- match onto the stage and reads hp_live_now every time the pick runs, so the
-- three things worth proving are read off the machine and not off the source:
--
--   COUNT   exactly three bodies hang
--   SPREAD  one of them in each zone - left corner, opening view, right corner
--   ROTATE  the next three are not the three before them
--
-- DP_MODE=drops runs the other half instead: a real match, rounds played out,
-- watching what falls.  The three are the SAME all match and a body that went
-- in STAYS in, so the round-by-round question is only how many MORE fall -
-- hp_round_cap, one or two (see "How many fall in a round", MKHANG.ASM).
--
-- HOW IT GETS MORE THAN ONE PICK.  create_hangers picks only when round_num is
-- 1, which is what makes rounds 2 and 3 keep the bodies the match started
-- with.  So the probe holds round_num AT 1 and ends each round by emptying a
-- bar: every round then rebuilds the stage down the same path a new match
-- takes, and one run sees as many picks as it has rounds.  Nothing else is
-- written - the pick itself is never touched.
--
local ROOT = os.getenv("DP_ROOT") or "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = os.getenv("DP_TEST_LOG")
local READY = os.getenv("DP_READY")
local WANT = tonumber(os.getenv("DP_PICKS") or "6")
local MODE = os.getenv("DP_MODE") or "rotate"

local logfh = LOG_PATH and io.open(LOG_PATH, "w") or nil
local function log(fmt, ...)
    local s = "[dprot] " .. string.format(fmt, ...)
    print(s)
    if logfh then logfh:write(s .. "\n"); logfh:flush() end
end

--------------------------------------------------------------------------
-- the layout and the zone rule, both read out of MKHANG.ASM
--------------------------------------------------------------------------
local function equ(name)
    local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
    if not fh then return nil end
    local v
    for line in fh:lines() do
        local n = line:match("^" .. name .. "%s+%.equ%s+(%-?%d+)")
        if n then v = tonumber(n); break end
    end
    fh:close()
    return v
end
local MID_LO = equ("hz_mid_lo") or 373
local MID_HI = equ("hz_mid_hi") or 772
local NZONES = equ("NZONES") or 3
local NH = equ("NHANGERS") or 9
local ROTATE = equ("hanger_rotate") or 0
local CAP_MIN = equ("drops_per_round_min") or 1
local CAP_MAX = equ("drops_per_round_max") or 2
local FIRST_DROP = equ("first_drop_ticks") or 821

local NAME, XPOS = {}, {}
do
    local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
    local armed, n = false, 0
    for line in fh:lines() do
        if line:match("^hanger_initab") then armed = true
        elseif armed then
            local x, who = line:match("%.word%s+(%d+)%s*,%s*%d+%s*;%s*(%S+)")
            if x then
                XPOS[n] = tonumber(x); NAME[n] = who; n = n + 1
                if n >= NH then break end
            end
        end
    end
    fh:close()
end
local function zone_of(x)
    if x < MID_LO then return 0 elseif x > MID_HI then return 2 else return 1 end
end
local ZONE_NAME = { [0] = "left", [1] = "view", [2] = "right" }

--------------------------------------------------------------------------
-- symbols
--------------------------------------------------------------------------
local symbols, missing = {}, {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
local function sym(n)
    local v = symbols[n]
    if v == nil then missing[#missing + 1] = n; return 0 end
    return v
end
local A = {
    gstate = sym("gstate"), curback = sym("curback"), round_num = sym("round_num"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"),
    hp_drop_busy = sym("hp_drop_busy"),
    hp_live_now = sym("hp_live_now"),
    hp_zone_bag = sym("hp_zone_bag"), hp_zone_last = sym("hp_zone_last"),
    hp_dropped = sym("hp_dropped"),
    hp_round_cap = sym("hp_round_cap"), hp_round_drops = sym("hp_round_drops"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    hanger_coords = sym("hanger_coords"),
}
local O = { oxpos = 0x090, oxval = 0x080 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KANG, FT_JAX = 1, 11
local STAGE_DEADPOOL = 0

local cpu, space, frame = nil, nil, 0
local fields = {}
local charsel_frame, p1_confirm_start, fighting_frame = 0, 0, 0
local picks, last_pick = {}, nil
local done = false
local snap_at = 0        -- frame to photograph the opening view on

local function r16(a) if a == 0 then return 0 end return space:read_u16(a) end
local function w16(a, v) if a ~= 0 then space:write_u16(a, v & 0xffff) end end

local function r32(a) if a == 0 then return 0 end return space:read_u32(a) end
local function w32(a, v) if a ~= 0 then space:write_u32(a, v & 0xffffffff) end end

local function body_x(i) return r16(A.hanger_coords + i * 32) end
local function dropped(i) return r16(A.hp_dropped + i * 16) end

-- THE CAMERA FOLLOWS THE FIGHTERS and the three hang the width of the pool,
-- so a body only gets its on-screen gate open when the pair is near him.
-- Park them beside one body at a time, in turn - the same trick the drop rig
-- uses, and the reason it has -NoPinCam.
local function park_pair_at(x)
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return end
    local ax, bx = x + 55, x + 100
    w16(a + O.oxpos, ax); w32(a + O.oxval, ax << 16)
    w16(b + O.oxpos, bx); w32(b + O.oxval, bx << 16)
end

local function read_lineup()
    local up = {}
    for i = 0, NH - 1 do
        if r16(A.hp_live_now + i * 16) ~= 0 then up[#up + 1] = i end
    end
    return up
end

local function lineup_key(up)
    local t = {}
    for _, i in ipairs(up) do t[#t + 1] = tostring(i) end
    return table.concat(t, ",")
end

local function describe(up)
    local t = {}
    for _, i in ipairs(up) do
        t[#t + 1] = string.format("%s(%d,x=%d,%s)", NAME[i] or "?", i, XPOS[i] or -1,
                                  ZONE_NAME[zone_of(XPOS[i] or 0)])
    end
    return table.concat(t, " ")
end

local function finish(v)
    if done then return end
    done = true
    log("RESULT %s", v)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function judge()
    local fails = {}
    if #picks < 2 then fails[#fails + 1] = "only_" .. #picks .. "_picks" end
    local seen, distinct = {}, 0
    for n, p in ipairs(picks) do
        if #p.up ~= NZONES then
            fails[#fails + 1] = string.format("pick%d_has_%d_bodies", n, #p.up)
        end
        local z = {}
        for _, i in ipairs(p.up) do
            local zz = zone_of(XPOS[i] or 0)
            if z[zz] then fails[#fails + 1] = string.format("pick%d_two_in_%s", n, ZONE_NAME[zz]) end
            z[zz] = true
        end
        for zz = 0, NZONES - 1 do
            if not z[zz] then fails[#fails + 1] = string.format("pick%d_no_%s", n, ZONE_NAME[zz]) end
        end
        if n > 1 then
            for _, i in ipairs(p.up) do
                for _, j in ipairs(picks[n - 1].up) do
                    if i == j then
                        fails[#fails + 1] = string.format("pick%d_repeats_%s", n, NAME[i] or i)
                    end
                end
            end
        end
        local k = lineup_key(p.up)
        if not seen[k] then seen[k] = true; distinct = distinct + 1 end
    end
    log("CHECK picks=%d distinct_lineups=%d", #picks, distinct)
    for n, p in ipairs(picks) do log("PICK %d: %s", n, describe(p.up)) end
    if #fails > 0 then
        log("FAIL %s", table.concat(fails, " "))
        finish("FAIL_" .. fails[1])
    else
        finish(string.format("PASS %d picks, %d bodies each, one per zone, none repeated",
                             #picks, NZONES))
    end
end

--------------------------------------------------------------------------
-- DP_MODE=drops: play the rounds out and watch what falls
--------------------------------------------------------------------------
local matches = {}          -- [n] = { lineup, rounds = { [r] = {cap, fell, had} } }
local cur = nil             -- the match being watched
local cur_round = 0
local park_i, park_until = 1, 0

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function names_of(t)
    local out = {}
    for i in pairs(t) do out[#out + 1] = NAME[i] or tostring(i) end
    table.sort(out)
    return #out > 0 and table.concat(out, ",") or "nobody"
end

local function judge_drops()
    local fails = {}
    local played = 0
    for m, M in ipairs(matches) do
        local order = {}
        for r in pairs(M.rounds) do order[#order + 1] = r end
        table.sort(order)
        if #order < 2 then goto next_match end      -- a match we only half saw
        played = played + 1
        log("MATCH %d hangs %s", m, describe(M.lineup))
        local carried, total = {}, 0
        for _, r in ipairs(order) do
            local R = M.rounds[r]
            if lineup_key(R.lineup) ~= lineup_key(M.lineup) then
                fails[#fails + 1] = string.format("m%d_round%d_lineup_changed", m, r)
            end
            if R.cap < CAP_MIN or R.cap > CAP_MAX then
                fails[#fails + 1] = string.format("m%d_round%d_cap_%d_outside_%d..%d",
                                                  m, r, R.cap, CAP_MIN, CAP_MAX)
            end
            local n = count(R.fell)
            total = total + n
            if n > R.cap then
                fails[#fails + 1] = string.format("m%d_round%d_%d_fell_over_cap_%d",
                                                  m, r, n, R.cap)
            end
            -- ONCE IN, STAYS IN: whoever had gone in before this round has to
            -- still be in the acid when it opens.
            for i in pairs(carried) do
                if not R.had[i] then
                    fails[#fails + 1] = string.format("m%d_round%d_%s_came_back_out",
                                                      m, r, NAME[i] or i)
                end
            end
            for i in pairs(R.fell) do carried[i] = true end
            for i in pairs(R.had) do carried[i] = true end
            -- THE FIRST BODY OF A MATCH WAITS first_drop_ticks.  Only round 1
            -- proves it: the countdown carries across rounds, so a later
            -- round can legitimately open with one going straight in.
            local waited = R.first_fall ~= 0 and (R.first_fall - R.fight_from) or nil
            -- FIRST_DROP - 1: hp_drop_count spends the last tick on the frame
            -- the drop begins, the same 821-counts-820 accounting the pause
            -- between drops has.
            if r == 1 and waited and waited < FIRST_DROP - 1 then
                fails[#fails + 1] = string.format("m%d_first_drop_after_%d_ticks_want_%d",
                                                  m, waited, FIRST_DROP)
            end
            log("  round %d: cap %d | already in the acid: %s | fell: %s (%d)%s",
                r, R.cap, names_of(R.had), names_of(R.fell), n,
                waited and string.format(" | first at +%d ticks", waited) or "")
        end
        if total == 0 then
            fails[#fails + 1] = string.format("m%d_nothing_fell", m)
        end
        ::next_match::
    end
    if played < 1 then fails[#fails + 1] = "no_complete_match" end

    log("CHECK matches=%d cap range %d..%d first_drop_ticks=%d (%.1fs)",
        played, CAP_MIN, CAP_MAX, FIRST_DROP, FIRST_DROP / 54.7068)
    if #fails > 0 then
        log("FAIL %s", table.concat(fails, " "))
        finish("FAIL_" .. fails[1])
    else
        finish(string.format(
            "PASS %d match(es): nobody goes in for the first %d ticks, the same three all match, never more than the round cap, and once in they stay in",
            played, FIRST_DROP))
    end
end

-- EVERY hp_dropped flip, whatever the game state, with the state it happened
-- in.  The per-round bookkeeping below only looks while a fight is live, so a
-- body whose flag moves anywhere else would otherwise show up as "already in"
-- with nothing to explain it.
local flip_seen = {}
local function trace_flips(gs)
    for i = 0, NH - 1 do
        local d = dropped(i) ~= 0
        if d ~= (flip_seen[i] or false) then
            flip_seen[i] = d
            log("FLIP %s -> %s  frame=%d gs=%d round=%d ws=%d busy=%d live=%d",
                NAME[i] or i, d and "in" or "out", frame, gs,
                r16(A.round_num), r16(A.winner_status), r16(A.hp_drop_busy),
                r16(A.hp_live_now + i * 16))
        end
    end
end

-- OPEN THE ROUND IN THE ROUND INTRO, not on the first frame of the fight.
-- hp_next_drop_ticks carries across rounds, so a body whose pause ran out
-- while the last round was capped goes in on the round's very FIRST fighting
-- frame - the same frame this rig used to notice the round had changed, which
-- read him as "already in the acid" and lost the fall.  The stage is built
-- (and the lineup picked and the cap rolled) before the intro, so opening the
-- round here is both earlier than any drop and later than create_hangers.
local pin_bar = 0

local function drops_frame(gs)
    trace_flips(gs)
    local r = r16(A.round_num)
    if r >= 1 and r ~= cur_round and r16(A.curback) == STAGE_DEADPOOL then
        local up = read_lineup()
        if #up > 0 then
            -- A NEW MATCH is round 1 after a later round, or a different three.
            if cur == nil or (r <= 1 and cur_round > 1)
               or lineup_key(up) ~= lineup_key(cur.lineup) then
                cur = { lineup = up, rounds = {} }
                matches[#matches + 1] = cur
                log("MATCH %d: %s", #matches, describe(up))
            end
            cur_round = r
            -- Only the three on the hooks mean anything: ch_reset_lp marks the
            -- other six hp_dropped=1 so no body of theirs can appear, and they
            -- are not spawned at all - reading them as "in the acid" counts six
            -- bodies that do not exist.
            local R = { lineup = up, cap = r16(A.hp_round_cap), fell = {}, had = {},
                        fight_from = 0, first_fall = 0 }
            for _, i in ipairs(up) do if dropped(i) ~= 0 then R.had[i] = true end end
            cur.rounds[r] = R
            log("round %d opens: frame=%d cap=%d already_in=%s",
                r, frame, R.cap, names_of(R.had))
            -- Idle fighters would tie, and a tie is GAME OVER (or sudden
            -- death).  Alternate the winner so the match runs its rounds out -
            -- but write the bar once the fight is live, or round_init's own
            -- reset lands on top of it.
            pin_bar = r
            park_i, park_until = 1, frame + 240
        end
    end

    if gs ~= GS_FIGHTING then
        w16(A.curback, STAGE_DEADPOOL)
        return
    end
    -- Idle fighters take no damage, so holding one bar down every frame is
    -- free and makes the timeout DECIDED.  Written once, round_init's own
    -- reset could land on top of it, the round tied, and a tie is sudden
    -- death or GAME OVER - short rounds in which nothing has time to fall.
    if pin_bar ~= 0 and r16(A.winner_status) == 0 then
        if pin_bar % 2 == 1 then w16(A.p2_bar, 0x50) else w16(A.p1_bar, 0x50) end
    end

    local R = cur and cur.rounds[cur_round]
    if not R then return end
    -- The countdown is only spent while a round is LIVE, so the 15 seconds
    -- before the first body goes in are measured from here, not from the
    -- round opening - the intro and the banners do not count.
    if R.fight_from == 0 then R.fight_from = frame end
    for _, i in ipairs(R.lineup) do
        if dropped(i) ~= 0 and not R.had[i] and not R.fell[i] then
            R.fell[i] = true
            if R.first_fall == 0 then R.first_fall = frame end
            log("FELL match %d round %d: %s (frame %d, %d ticks into the fight)",
                #matches, cur_round, NAME[i] or i, frame, frame - R.fight_from)
        end
    end
    -- park the pair beside each hanging body in turn, so each one's on-screen
    -- gate gets a chance to open
    if frame >= park_until and #R.lineup > 0 then
        park_i = park_i % #R.lineup + 1
        park_until = frame + 240
    end
    if #R.lineup > 0 then park_pair_at(body_x(R.lineup[park_i])) end
end

--------------------------------------------------------------------------
-- boot: coin up, 2 players, force the stage
--------------------------------------------------------------------------
local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-18s MISSING", name); ok = false end
    end
    return ok
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
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if #missing > 0 then
            log("FATAL missing symbols: %s", table.concat(missing, " "))
            finish("symbols_missing"); return
        end
        if not cache_fields() then finish("input_missing"); return end
        log("hanger_rotate=%d NZONES=%d zones: left <%d, view %d..%d, right >%d",
            ROTATE, NZONES, MID_LO, MID_LO, MID_HI, MID_HI)
        local by = {}
        for i = 0, NH - 1 do
            local z = zone_of(XPOS[i] or 0)
            by[z] = (by[z] and (by[z] .. " ") or "") ..
                    string.format("%s@%d", NAME[i] or i, XPOS[i] or -1)
        end
        for z = 0, NZONES - 1 do log("zone %-5s: %s", ZONE_NAME[z], by[z] or "(empty)") end
        if ROTATE == 0 then log("WARN hanger_rotate=0 - this ROM hangs everybody") end
    end
    if frame == 30 and READY then
        local fh = io.open(READY, "w"); if fh then fh:write("1"); fh:close() end
    end
    if done or frame < 2 then return end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        if p1_confirm_start == 0 then p1_confirm_start = frame + 60 end
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_JAX)
        w16(A.curback, STAGE_DEADPOOL)
        if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
        if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    end
    if MODE == "drops" then
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d curback=%d", frame, r16(A.curback))
        end
        drops_frame(gs)
        return
    end

    if gs ~= GS_FIGHTING then
        -- MAKE EVERY ROUND A NEW MATCH.  round_init increments round_num and
        -- create_hangers picks when it reads 1, so holding it at 0 between
        -- rounds means the next round builds the stage down exactly the path
        -- a new match takes.  Nothing about the pick itself is touched.
        w16(A.round_num, 0)
        w16(A.curback, STAGE_DEADPOOL)   -- ...and always on the Dead Pool
        fighting_frame = 0
        return
    end
    if fighting_frame == 0 then
        fighting_frame = frame
        log("fight_start frame=%d curback=%d round=%d",
            frame, r16(A.curback), r16(A.round_num))
    end
    if r16(A.curback) ~= STAGE_DEADPOOL then return end

    -- A pick has run when the lineup is not the one we last read.
    local up = read_lineup()
    local key = lineup_key(up)
    if #up > 0 and key ~= last_pick then
        last_pick = key
        picks[#picks + 1] = { up = up, frame = frame }
        local bags, lasts = {}, {}
        for z = 0, NZONES - 1 do
            bags[#bags + 1] = string.format("%03x", r16(A.hp_zone_bag + z * 16))
            lasts[#lasts + 1] = string.format("%03x", r16(A.hp_zone_last + z * 16))
        end
        log("PICKED %d frame=%d  %s   bag=[%s] last=[%s]",
            #picks, frame, describe(up), table.concat(bags, " "), table.concat(lasts, " "))
        -- The round opens on world 373..772, so the shot shows the MIDDLE
        -- body; the two corner ones are off the sides of the screen, which is
        -- the point of spreading them.
        snap_at = frame + 90
        if #picks >= WANT then judge(); return end
    end
    if snap_at ~= 0 and frame >= snap_at then
        snap_at = 0
        manager.machine.video:snapshot()
    end

    -- End the round: empty P2's bar once the fight is really under way.
    if r16(A.winner_status) == 0 and (frame % 8) == 0 then
        if frame > fighting_frame + 150 then w16(A.p2_bar, 0) end
    end
end)

emu.register_stop(function()
    if not done then
        if MODE == "drops" then
            if #matches > 0 then judge_drops()
            else log("RESULT no_verdict matches=0") end
        elseif #picks >= 2 then judge()
        else log("RESULT no_verdict picks=%d", #picks) end
    end
    if logfh then logfh:close() end
end)
