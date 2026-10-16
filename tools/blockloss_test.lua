-- blockloss_test.lua - A HELD GUARD IS AN IDLE LOOP AND HAS TO POLL THE ROUND.
--
-- joy_block_loop (JOY.ASM) never called check_winner_status.  joy_stance_loop
-- (joye5), the duck loop (joyd5) and the duck-block loop (jdblk5) all do; the
-- STANDING block loop did not - Midway's own omission, still there in
-- mk2-readonly - so a player who was holding Block when the round was decided
-- stayed in his guard pose: no dizzy sway through FINISH HIM, and no collapse
-- while the other man celebrated.
--
-- WHAT IS MEASURED, and why it is not p_action alone.  collapse_on_ground
-- (MKCANNED.ASM) never writes p_action - it animates and parks in
-- local_wait_forever - so the loser's p_action reads act_blockhi both before
-- and after the fix on a round-1 loss and cannot tell them apart.  Two things
-- can:
--
--   round 1 loss (winner_status 1/2 -> collapse_on_ground)
--       the DRAWN SAG moves off the guard pose (the fall lane runs), AND
--       m_shadow is cleared in oflags2 - clear_shadow_bit is the LAST thing
--       collapse_on_ground does, so that bit is the proof the whole routine
--       ran and not merely that something ticked.
--
--   round 2 loss (P2 reaches 2 match wins -> winner_status 3, FINISH HIM)
--       p_action becomes act_stunned (0400h).  dizzy_dude is the branch the
--       loser takes, and it also calls set_no_block - so losing the guard is
--       the game's own intent.  THIS is the beat the player reported.
--
-- BL_HOLD=0 is the POSITIVE CONTROL, not a negative: Block is never pressed,
-- the loser is in his stance, and both outcomes must hold on BOTH ROMs.  That
-- is what proves the detector works, so a HELD run reporting neither outcome
-- is the ROM failing and not the rig.
--
-- Deciding the round by writing p1_bar = 0 is legitimate here and is NOT the
-- "writing a bar to 0 does not end a round" trap: that trap is about the KO
-- path, which needs damage applied.  MAIN.ASM's clock loop polls
-- `move @p1_bar,a0,w / jreq round_is_over` directly, so a zeroed bar ends the
-- round by the game's own test.  p1_bar is therefore NOT pinned; p2_bar is.
--
--   BL_LOG  log path   BL_MAP  the map belonging to the zip under test
--   BL_HOLD 1 = hold Block through the loss (default), 0 = control

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("BL_LOG") or (ROOT .. "/tools/blockloss_test.log")
local HOLD = (os.getenv("BL_HOLD") or "1") == "1"

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[blk] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local missing = false
local symbols = {}
do
    local mp = os.getenv("BL_MAP") or (ROOT .. "/src/mk2.map")
    local fh = assert(io.open(mp, "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
    log("map: %s", mp)
end

local A = {}
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar",
                     "p1_obj", "p2_obj", "p1_proc", "winner_status",
                     "p1_matchw", "p2_matchw", "round_num" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end

-- DISPEQU.ASM / MKSTRUCT.ASM, BIT offsets
local OIMG, OFLAGS2, OYPOS = 0x1a0, 0x160, 0xb0
local MP_SAG   = 0
local M_SHADOW = 0x10          -- DISPEQU.ASM m_shadow, in oflags2
local P_ACTION = 0x1f0
local ACT_BLOCKHI, ACT_STUNNED = 0x0700, 0x0400
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KANG, FT_JAX, MAX_HP = 1, 11, 0xa1

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function hold(n, on) held[n] = on and true or false end

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Block"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    -- "UI Select" is a MAME UI input, not an ioport field in every build, and it
    -- is only used to hurry past the title screen.  Its absence is a note; a
    -- missing GAME button is fatal, because the rig would then measure a fight
    -- it never drove.  Treating them alike aborted every run before frame 2.
    local optional = { ["UI Select"] = true }
    for n in pairs(want) do
        if not fields[n] then
            log("input %s: %s", optional[n] and "absent (optional)" or "MISSING", n)
            if not optional[n] then missing = true end
        end
    end
end

-- the SAG P1 is drawing right now, off his multipart RAM
local function p1_sag()
    local o = r32(A.p1_obj); if o == 0 then return 0 end
    local mp = r32(o + OIMG); if mp == 0 then return 0 end
    return r32(mp + MP_SAG)
end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local rounds = {}
local cur = nil

local function verdict()
    done = true
    log("---- results (BL_HOLD=%s) ----", HOLD and "1 (Block held)" or "0 (control, no Block)")
    local fails = 0
    for _, r in ipairs(rounds) do
        local ok, why
        if r.kind == "collapse" then
            ok = (r.sag_changed == true) and (r.shadow_cleared == true)
            why = string.format("sag %s (%08x->%08x)  shadow_cleared=%s",
                r.sag_changed and "MOVED" or "FROZEN", r.sag0 or 0, r.sagN or 0,
                tostring(r.shadow_cleared == true))
        else
            ok = (r.stunned == true) and (r.ws3 == true)
            why = string.format("p_action %04x -> %04x (want act_stunned 0400)%s",
                r.act0 or 0, r.actN or 0, r.ws3 and "" or "  [never saw winner_status 3]")
        end
        if not ok then fails = fails + 1 end
        log("%-9s round %d  %-4s  %s", r.kind, r.round, ok and "PASS" or "FAIL", why)
        log("           p_action %04x -> %04x  wsmax=%d  matchw %d/%d  window=%d ticks",
            r.act0 or 0, r.actN or 0, r.wsN or 0, r.mw1 or 0, r.mw2 or 0, r.window or 0)
        log("           first seen at (ticks after the decision): sag_move=%s shadow_clear=%s stunned=%s",
            tostring(r.t_sag or "never"), tostring(r.t_shadow or "never"),
            tostring(r.t_stun or "never"))
    end
    if #rounds < 2 then
        log("only %d of 2 beats were measured - NO VERDICT, not a pass", #rounds)
        fails = fails + 1
    end
    log(fails == 0 and "PASS - the loser left his guard in both beats"
                    or ("FAIL - " .. fails .. " beat(s)"))
    logfh:close()
    manager.machine:exit()
end

local function tick()
    if done then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        if missing then verdict(); return end
        log("booting: Liu Kang (P1, human) vs Jax (P2, human)")
    end
    if frame > 9000 then log("backstop: out of frames"); verdict(); return end

    local gs = r16(A.gstate)
    -- Heartbeat.  A frame notifier that throws is disabled by MAME without a
    -- line in the redirected stderr, so "the log stops after booting" has two
    -- completely different causes - the handler died, or the attract mode never
    -- let go - and nothing else in the log tells them apart.
    if frame % 600 == 0 then
        log("hb frame=%d gstate=%02x psel=%d confirm=%d fight=%d", frame, gs, psel, confirm, fight_at)
    end

    if psel == 0 and gs == GS_PSEL then
        psel = frame
        log("select screen at frame %d", frame)
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 4000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 4000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 4000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)
    elseif confirm == 0 then
        local rel = frame - psel
        if gs == GS_PSEL then
            w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX)
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and rel > 60 then
            confirm = frame
            for n in pairs(fields) do hold(n, false) end
        end
    else
        if gs == GS_POST then w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX) end
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d", frame)
        end
        if fight_at == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        local p1o, p1p = r32(A.p1_obj), r32(A.p1_proc)
        local ws = r16(A.winner_status)

        -- P2 never runs out of life; P1's bar is the instrument and is left alone.
        w16(A.p2_bar, MAX_HP)

        -- Hold Block from the first fighting frame and NEVER let go.  The bug
        -- only shows while the button is DOWN: releasing it exits the loop
        -- through do_unblock_hi -> joy_entry -> joye5, which polls and self-heals.
        --
        -- THIS CONDITION USED TO BE `gs == GS_FIGHTING` AND THAT RELEASED THE
        -- BUTTON FOR THE RIG.  gstate leaves GS_FIGHTING within a couple of
        -- ticks of a round-1 decision, so the rig let go exactly when the beat
        -- began, the guard came down on its own and the UNFIXED ROM scored that
        -- beat PASS (shadow clear at tick 40, p_action 0700 -> 0303).  A player
        -- holding the button does not release it because the round ended.
        hold("P1 Block", HOLD and fight_at ~= 0)

        if cur == nil and gs == GS_FIGHTING and p1o ~= 0 and p1p ~= 0 and ws == 0 then
            local rnd = r16(A.round_num)
            local already = false
            for _, r in ipairs(rounds) do if r.round == rnd then already = true end end
            if not already and r16(A.p1_bar) > 0 then
                cur = { round = rnd, t0 = frame, killed = false }
            end
        end

        if cur ~= nil then
            local rel = frame - cur.t0
            if not cur.killed and rel >= 70 then
                cur.act0  = r16(p1p + P_ACTION)
                cur.sag0  = p1_sag()
                cur.ypos0 = r16(p1o + OYPOS)
                if HOLD and cur.act0 ~= ACT_BLOCKHI then
                    -- He is not in the guard yet.  A rig that killed the round
                    -- here would be testing the stance loop, which was never
                    -- broken - so wait instead of measuring the wrong loop.
                    cur.t0 = frame - 60
                elseif cur.sag0 == 0 then
                    cur.t0 = frame - 60
                else
                    w16(A.p1_bar, 0)
                    cur.killed = true
                    cur.kt = frame
                    log("round %d: p1_bar=0 at frame %d (p_action=%04x sag=%08x)",
                        cur.round, frame, cur.act0, cur.sag0)
                end
            elseif cur.killed then
                local k = frame - cur.kt
                --
                -- EVERYTHING IS SAMPLED ONLY WHILE winner_status IS NON-ZERO,
                -- and that gate is the whole assertion.  round_init clears
                -- winner_status for the next round and setup_players rebuilds
                -- both fighters, so a window that runs past the teardown sees
                -- the SAG move and the shadow bit change for reasons that have
                -- nothing to do with the loser leaving his guard.  Measured: a
                -- 240-tick window scored the round-1 beat PASS on the UNFIXED
                -- ROM (p_action 0700 -> 0303, sag "MOVED") purely off the next
                -- round's rebuild.  The question is whether he leaves the guard
                -- BEFORE the round is torn down, so the window is the decision.
                --
                if ws ~= 0 then
                    cur.saw_ws = true
                    cur.wsN = math.max(cur.wsN or 0, ws)
                    if ws == 3 then cur.ws3 = true end
                    if p1p ~= 0 then
                        local a = r16(p1p + P_ACTION)
                        cur.actN = a
                        if a == ACT_STUNNED and not cur.stunned then
                            cur.stunned = true; cur.t_stun = k
                        end
                    end
                    if p1o ~= 0 then
                        local s = p1_sag()
                        if s ~= 0 then
                            cur.sagN = s
                            if s ~= cur.sag0 and not cur.sag_changed then
                                cur.sag_changed = true; cur.t_sag = k
                            end
                        end
                        cur.yposN = r16(p1o + OYPOS)
                        if (r32(p1o + OFLAGS2) & M_SHADOW) == 0 and not cur.shadow_cleared then
                            cur.shadow_cleared = true; cur.t_shadow = k
                        end
                    end
                    cur.mw1, cur.mw2 = r16(A.p1_matchw), r16(A.p2_matchw)
                end
                -- Close the beat when the round is torn down (winner_status back
                -- to 0 after we have seen it set), or at 240 ticks for the
                -- FINISH HIM beat, which holds winner_status 3 far longer.
                if (cur.saw_ws and ws == 0) or k >= 240 then
                    cur.kind = (cur.ws3 or (cur.mw2 or 0) >= 2) and "finishhim" or "collapse"
                    cur.window = k
                    rounds[#rounds + 1] = cur
                    log("round %d measured as %s over %d ticks of winner_status", cur.round, cur.kind, k)
                    cur = nil
                    if #rounds >= 2 then verdict(); return end
                end
            end
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
end

-- emu.register_frame_done, NOT emu.add_machine_frame_notifier: that one hands
-- back a subscription object, and a rig that does not keep a reference to it has
-- the notifier collected after its FIRST call - the handler stops, MAME prints
-- nothing, and the log simply ends after the boot line.  Same trap as a write
-- tap whose handle is not kept.  Every working rig in this tree uses
-- register_frame_done.
emu.register_frame_done(tick)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
log("blockloss rig armed")
