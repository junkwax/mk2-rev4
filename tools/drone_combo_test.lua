-- drone_combo_test.lua
--
-- Does the drone actually PERFORM the scripted combos?
--
-- The stability sweep only proves nothing crashed, and "it builds" proves
-- less than that. Both of these chains were shipped on exactly that evidence,
-- which is no evidence at all that a single link ever fires.
--
-- Watches the DRONE's p_action and looks for the chain in order, each link
-- inside a window measured from a player's own lab recording:
--
--   mileena   act_kano (roll) -> act_flykick -> act_air_tsai (sai)
--   scorpion  act_flykick -> act_decoy (teleport) -> act_spear
--
-- Reports LINK BY LINK, because "it did not work" is useless and "link 2
-- fired 9 times, link 3 never" names the bug. The parked juggle engine's
-- known failure was exactly that shape -- links 3 and 4 never chained --
-- and a pass/fail number would have hidden it.
--
-- Action ids come from MAINEQU.ASM. Never hardcode them: they are .set
-- equates, absent from MK2.MAP, so a typo cannot be caught by sym() and
-- turns a working feature into a confident zero.
--
-- Env: COMBO_LOG, COMBO_CHAR, COMBO_DIFF
-- Usage: tools\run_drone_combo_test.ps1

local LOGP = os.getenv("COMBO_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_combo_test.log"
local CHAR = (os.getenv("COMBO_CHAR") or "mileena"):lower()
local DIFF = tonumber(os.getenv("COMBO_DIFF") or "9")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[combo] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local acts = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+([0-9a-fA-F]+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end
local fatal = false
local function act(n)
    local v = acts[n]
    if not v then log("FATAL: %s missing from MAINEQU.ASM", n); fatal = true end
    return v or -1
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"), rand = sym("rand"),
    debug2 = sym("debug2"), debug3 = sym("debug3"),
}

local PDATA, PROC_ACTION = 0x100, 0x100 + 0x0f0
-- p_juggle_step = pdata+2b0h (MAINEQU.ASM). These offsets stay in BITS: this
-- space is the TMS34010's own, which is bit addressed -- PROC_ACTION above is
-- 0x1f0 bits (not 0x3e bytes) and reads p_action correctly. Do not "fix" it
-- by dividing by 8; that is the rule for saver/loadr and w@, not for this.
local PROC_JSTEP = 0x100 + 0x2b0

local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG = 1

-- windows are generous: the recording showed +10 and +33..43, so 90 ticks
-- per link cannot miss a real chain while still refusing an unrelated move
-- half a second later.
local LINK_WINDOW = 90

local COMBOS = {
    mileena  = { id = 5,  name = "Mileena  roll -> flip kick -> air sai",
                 links = {"act_kano", "act_flykick", "act_air_tsai"} },
    scorpion = { id = 10, name = "Scorpion flip kick -> teleport -> spear",
                 links = {"act_flykick", "act_decoy", "act_spear"} },
    kunglao  = { id = 0,  name = "Kung Lao HP,HP -> flip kick -> D+HK",
                 links = {"act_hipunch", "act_flykick", "act_duck_kickh"} },
}
-- No silent fallback. This used to be `COMBOS[CHAR] or COMBOS.mileena`, and a
-- runner bug that passed "scorpion,mileena" as ONE name quietly ran Mileena
-- and reported her PASS under Scorpion's name -- a green result for a
-- character that never booted. An unknown name is a harness bug: say so.
local C = COMBOS[CHAR]
if not C then
    local known = {}
    for k in pairs(COMBOS) do known[#known+1] = k end
    log("FATAL: unknown COMBO_CHAR %q (known: %s)", CHAR, table.concat(known, ", "))
    log("FAIL combo: harness misconfigured, nothing was tested")
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
    return
end

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start, fields, done = 0, {}, false
local RUN_FRAMES = 9000

local want, reached, stage, stage_frame = {}, {}, 0, 0
local was_act = -1
-- ARM counter. Scorpion's link 1 counts every flip kick, but only the ones
-- launched from drone_ajump_call arm the follow-up and can ever chain, so
-- "2 of 10 kicks" was never the conversion rate -- it had the wrong
-- denominator. Count arms to get the number that actually means something.
-- Counted PER ID. A single lumped counter read 12 arms against 10 flip kicks
-- -- more arms than openers -- because it also counted dln_press, which this
-- chain never uses. A denominator that includes unrelated events is just a
-- different wrong number than the one it replaced.
-- Does link 1 actually CONNECT? The gates now require his bar to drop, so a
-- chain that never converts may mean the launcher is whiffing rather than the
-- gate being wrong -- and those need opposite fixes. Track damage overall and
-- damage landed in the window right after each link-1, which separates them.
local dmg_total, link1_hits, link1_n, last_hp = 0, 0, 0, -1
local watch_until = 0
local DLN = { [0x10] = "dln_zap", [0x11] = "dln_press", [0x12] = "dln_spear" }
local armed = { [0x10] = 0, [0x11] = 0, [0x12] = 0 }
local was_arm = -1

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function proc_act(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
end

local function finish()
    if done then return end
    done = true
    log("RESULT %s diff=%d", C.name, DIFF)
    for i, n in ipairs(C.links) do
        log("   link %d  %-14s (0x%04x)  fired %d time(s)", i, n, want[i], reached[i])
    end
    log("   drone dealt %d damage total; %d of %d link-1 openers landed a hit",
        dmg_total, link1_hits, link1_n)
    if link1_n > 0 and link1_hits == 0 then
        log("   link 1 NEVER connects -- the gate is doing its job and the")
        log("   opener itself is the problem (spacing), not the combo wiring")
    end
    for _, id in ipairs({0x10, 0x11, 0x12}) do
        log("   armed %-10s (0x%02x)  %d time(s)", DLN[id], id, armed[id])
    end
    -- Only dln_zap gates this chain: it is what dlf_zap runs from, and only a
    -- dlf_zap that passes is_he_reacting AND the diff roll reaches link 2.
    -- Kung Lao breadcrumbs (lao_debug in MKDRONE.ASM). Names which of the
    -- three gates in dlf_try_lao is eating link 3 instead of leaving me to
    -- pick one and rebuild on a guess.
    if CHAR == "kunglao" and A.debug2 ~= 0 then
        local arrive = r16(A.debug2)
        local far = (A.debug3 ~= 0) and r16(A.debug3) or 0
        local how = ({[0]="never passed the diff roll", [1]="rolled ok, then the duck failed",
                      [2]="ducked, but does_stk_reach said out of range",
                      [3]="reached -- do_duck_kickh was actually called"})[far] or "?"
        log("   dlf_try_lao reached %d time(s); furthest stage %d = %s", arrive, far, how)
    end
    local gate = armed[0x10]
    if gate > 0 then
        log("   link 2 conversion = %d/%d = %d%% of dln_zap arms",
            reached[2], gate, math.floor(reached[2] * 100 / gate))
    else
        log("   dln_zap never armed -- the chain had no opening at all, so the")
        log("   arm site is the bug, not the probability table")
    end
    local fails = {}
    if fatal then fails[#fails+1] = "an act_* id was missing - the ids are wrong, not the drone" end
    if reached[1] == 0 then
        fails[#fails+1] = string.format("link 1 (%s) never fired - the drone never even opened", C.links[1])
    else
        for i = 2, #C.links do
            if reached[i] == 0 then
                fails[#fails+1] = string.format(
                    "chain breaks at link %d (%s): link %d fired %d times, link %d never followed",
                    i, C.links[i], i - 1, reached[i - 1], i)
                break
            end
        end
    end
    if #fails == 0 then
        log("PASS combo: full chain completed %d time(s)", reached[#C.links])
    else
        log("FAIL combo: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want_f = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want_f[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        for i, n in ipairs(C.links) do want[i] = act(n); reached[i] = 0 end
        log("---- %s ----", C.name)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)      -- P2 = the drone under test
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, C.id)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; run_start = frame
        log("fight start frame=%d (P1 idle so every hit is the drone's)", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= DIFF then w16(A.diff, DIFF) end
    -- keep both alive so the run is one long sample, and stir the RNG or a
    -- single probability roll decides the whole run (see doc/AI_DRONE.md)
    -- REFILL WHEN LOW, never pin every frame. The combo gates now ask whether
    -- his LIFE BAR dropped ("did it connect"), so rewriting the bar to full on
    -- the very next frame erases the only evidence they read and every chain
    -- measures as broken -- a harness that silently disproves the feature it
    -- is testing. A floor keeps the round alive for a long sample while each
    -- individual hit still visibly registers.
    if r16(A.p1_bar) < 0x40 then w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP) end
    if r16(A.p2_bar) < 0x40 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    if A.rand ~= 0 then
        w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345) & 0xffffffff)
    end

    do  -- count each new arm exactly once (drone_land_next consumes it)
        local q = r32(A.p2_proc)
        local jst = (q ~= 0) and r16(q + PROC_JSTEP) or 0
        if jst ~= was_arm then
            if DLN[jst] then armed[jst] = armed[jst] + 1 end
            was_arm = jst
        end
    end

    do  -- damage bookkeeping (P1 is the idle victim, so every drop is the drone's)
        local hp = r16(A.p1_bar)
        if last_hp >= 0 and hp < last_hp and (last_hp - hp) < 0x60 then
            local d = last_hp - hp
            dmg_total = dmg_total + d
            -- at most ONE per opener: this counted every damage event in the
            -- window, so a multi-hit window reported more openers landing than
            -- openers thrown ("4 of 3"), which is not a ratio at all
            if frame <= watch_until then
                link1_hits = link1_hits + 1
                watch_until = 0
            end
        end
        last_hp = hp
    end

    local a2 = proc_act(A.p2_proc)
    if a2 ~= was_act then
        local rel = frame - run_start
        if a2 == want[1] then
            reached[1] = reached[1] + 1; stage = 1; stage_frame = frame
            link1_n = link1_n + 1; watch_until = frame + 40
            log("  link 1 %s at rel=%d", C.links[1], rel)
        elseif stage >= 1 and a2 == want[stage + 1] and (frame - stage_frame) <= LINK_WINDOW then
            stage = stage + 1
            reached[stage] = reached[stage] + 1
            log("  link %d %s at rel=%d  (+%d from previous link)",
                stage, C.links[stage], rel, frame - stage_frame)
            stage_frame = frame
            if stage == #C.links then
                log("  *** FULL CHAIN ***")
                stage = 0
            end
        elseif stage >= 1 and (frame - stage_frame) > LINK_WINDOW then
            stage = 0     -- window closed, start looking for an opener again
        end
        was_act = a2
    end

    if (frame % 1800) == 0 then
        local s = {}
        for i = 1, #C.links do s[#s+1] = string.format("L%d=%d", i, reached[i]) end
        log("  .. rel=%d  %s", frame - run_start, table.concat(s, " "))
    end

    if frame - run_start > RUN_FRAMES then finish(); return end
    if frame > 40000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
