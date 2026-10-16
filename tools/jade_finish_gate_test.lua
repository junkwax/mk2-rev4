--- jade_finish_gate_test.lua - the FINISH HIM gate, asked from both sides.
---
--- finish_him_sequence (MAIN.ASM) used to refuse the window whenever ft_jade
--- was on the screen at all, and boss_minumum_diff forced GORO'S LAIR and
--- difficulty 8 on the same test.  Both were right for the hidden encounter
--- and wrong for a human who unlocked her at the select screen (Mileena +
--- Low Kick x5), so she was the one fighter in the cast who could never earn
--- a FINISH HIM and who dragged the whole ladder to Goro's Lair.
---
--- secret_is_cpu (MAIN.ASM) now asks WHO IS PLAYING her.  This rig exercises
--- both answers against the same build:
---
---   JFG_MODE=human  P1 unlocks Jade and fights a drone.  Requires the
---                   FINISH HIM window (winner_status == 3) and a stage that
---                   is not Goro's Lair (curback ~= 9), at ordinary difficulty.
---   JFG_MODE=rounds identical to human, but the match is allowed to run on
---                   past round 1.  boss_minumum_diff now FALLS THROUGH to the
---                   ordinary boss tests for a human Jade, and that fall-
---                   through runs once per round with p1_char/p2_char live in
---                   a0/a1 - so every round's stage and difficulty is read
---                   back to prove the helper left those registers alone.
---   JFG_MODE=cpu    identical, except @p2_char is forced to ft_jade on the
---                   DRONE side just before the KO.  That is exactly the
---                   input the secret encounter hands the gate, and it must
---                   still refuse: winner_status must never reach 3.
---                   Only the global is written, not the object's ochar, so
---                   the drone keeps animating as the fighter it spawned as.
---
--- Reaching the KO: P2's bar is dropped to 1 once the fight is live, P1 is
--- snapped inside jab range, and P1 mashes High Punch.  @p1_matchw is pre-set
--- to 1 so the single round win takes the match - play3 (MAIN.ASM) only calls
--- finish_him_sequence once somebody holds two.
---
---   JFG_LOG   log path      JFG_SNAP  1 = screenshot at the verdict

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("JFG_MODE") or "human"
local LOG  = os.getenv("JFG_LOG") or (ROOT .. "/tools/jade_finish_gate_" .. MODE .. ".log")
local SNAP = (os.getenv("JFG_SNAP") or "") ~= ""

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[jfg/" .. MODE .. "] " ..
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

local WANT = { "gstate", "p1_char", "p2_char", "p1_state", "p2_state",
               "p1_bar", "p2_bar", "p1_matchw", "winner_status", "curback",
               "diff", "p1_obj", "p2_obj",
               "c_jade_cheat1", "f_jade_cheat1", "f_jade_lk_held1" }
local A = {}
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end

-- TMS34010 bit offsets (DISPEQU.ASM).  MAME's program space is bit-addressed,
-- so mk2.map values and these offsets both go in raw.
local O_OXVAL, O_OXPOS = 0x080, 0x090
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_JADE, JADE_BASE = 16, 5      -- Jade, and Mileena's square on the grid

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local frame, psel, p0, confirm, fight_at = 0, 0, 0, 0, 0
local phase, done = "boot", false
local armed_at, ws_seen, saw_finish = 0, {}, false
local back_curback, back_diff, back_p2char = -1, -1, -1
local ko_at, punches = 0, 0
local last_ws = -1
local rounds = {}          -- one {curback, diff} per round that went live

local function cache_inputs()
    local want = { ["Coin 1"] = 1, ["1 Player Start"] = 1, ["UI Select"] = 1,
                   ["P1 Low Kick"] = 1, ["P1 Low Punch"] = 1, ["P1 High Punch"] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, fld in pairs(p.fields) do
            if want[fld.name] then fields[fld.name] = fld end
        end
    end
    for n in pairs(want) do log("input %-18s %s", n, fields[n] and "ok" or "MISSING") end
end

-- Put P1 a jab's length from P2.  oxpos alone is overwritten before the draw,
-- so oxval (the 16.16 master) has to move with it.
local function snap_close()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local x = r16(p2o + O_OXPOS) - 60
    w16(p1o + O_OXPOS, x)
    w32(p1o + O_OXVAL, (x << 16) & 0xffffffff)
end

local function verdict()
    local ok, why = true, {}
    local seen = {}
    for v in pairs(ws_seen) do seen[#seen + 1] = v end
    table.sort(seen)
    log("winner_status values seen after the KO: %s", table.concat(seen, ","))
    log("stage at fight start: curback=%d  diff=%d  p1_char=%d  p2_char=%d",
        back_curback, back_diff, r16(A.p1_char), back_p2char)

    if r16(A.p1_char) ~= FT_JADE then
        ok = false; why[#why + 1] = string.format("p1_char=%d, wanted %d", r16(A.p1_char), FT_JADE)
    end
    if ko_at == 0 and MODE ~= "rounds" then
        ok = false; why[#why + 1] = "P2 was never knocked out - the gate was never asked"
    end
    if MODE == "rounds" then
        for i, r in ipairs(rounds) do
            log("round %d: curback=%d diff=%d", i, r.cb, r.df)
        end
        if #rounds < 2 then
            ok = false; why[#why + 1] = string.format("only %d round(s) went live", #rounds)
        end
        for i, r in ipairs(rounds) do
            if r.cb == 9 then
                ok = false; why[#why + 1] = string.format("round %d forced to GORO'S LAIR", i)
            elseif r.cb == 8 then
                ok = false; why[#why + 1] = string.format("round %d forced to the BOSS arena", i)
            end
            if r.df >= 7 then
                ok = false; why[#why + 1] = string.format("round %d difficulty %d (boss scaling)", i, r.df)
            end
        end
    elseif MODE == "human" then
        if not saw_finish then
            ok = false; why[#why + 1] = "no FINISH HIM window (winner_status never 3)"
        end
        if back_curback == 9 then
            ok = false; why[#why + 1] = "stage forced to GORO'S LAIR (curback=9)"
        end
        if back_diff == 8 then
            ok = false; why[#why + 1] = "difficulty forced to 8 (secret-fight scaling)"
        end
    else
        if saw_finish then
            ok = false; why[#why + 1] = "FINISH HIM ran against a DRONE Jade - the gate leaked"
        end
    end
    log("%s %s%s", ok and "PASS" or "FAIL", MODE,
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
        for _, n in ipairs({ "Coin 1", "1 Player Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        -- Coin + start, pulsed: a stuck Start is itself a confirm and would
        -- swallow every cheat press further down.
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("1 Player Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)

    elseif confirm == 0 then
        local rel = frame - psel
        if rel == 60 then p0 = frame; phase = "pulsing"; log("pulsing P1 Low Kick x5 on Mileena") end
        if phase == "pulsing" then
            -- Park on Mileena only until the pending flag rises: cmove9
            -- commits @p1_char on the fifth press, and stamping the base id
            -- back even once undoes the unlock.
            if r16(A.f_jade_cheat1) == 0 and r16(A.p1_char) ~= FT_JADE then
                w16(A.p1_char, JADE_BASE)
            end
            local p = frame - p0
            if (p // 10) < 5 then
                hold("P1 Low Kick", (p % 10) < 5)
            else
                hold("P1 Low Kick", false)
                if phase ~= "post" then
                    phase = "post"
                    log("pulses done c=%d f=%d held=%d",
                        r16(A.c_jade_cheat1), r16(A.f_jade_cheat1), r16(A.f_jade_lk_held1))
                end
            end
        end
        if phase == "post" and (frame - p0) > 70 then
            hold("P1 Low Punch", (frame % 20) < 8)
        end
        if phase ~= "boot" and r16(A.p1_char) == FT_JADE then
            confirm = frame
            log("Jade confirmed at frame %d", frame)
            for n in pairs(fields) do hold(n, false) end
        end

    else
        if gs == GS_FIGHTING then
            if fight_at == 0 then
                fight_at = frame
                local cb, df = r16(A.curback), r16(A.diff)
                rounds[#rounds + 1] = { cb = cb, df = df }
                if #rounds == 1 then
                    back_curback, back_diff, back_p2char = cb, df, r16(A.p2_char)
                end
                log("fight live at frame %d (round %d): curback=%d diff=%d p1_char=%d p2_char=%d",
                    frame, #rounds, cb, df, r16(A.p1_char), r16(A.p2_char))
            end

            if frame - fight_at == 60 then
                armed_at = frame
                if MODE ~= "rounds" then
                    w16(A.p1_matchw, 1)      -- this round takes the match
                end
                w16(A.p2_bar, 1)             -- one clean jab ends it
                if MODE == "cpu" then
                    w16(A.p2_char, FT_JADE)  -- what the secret encounter hands the gate
                    log("forced @p2_char = ft_jade on the DRONE side")
                end
                log("armed: p1_matchw=1 p2_bar=1 (p1_bar=%d)", r16(A.p1_bar))
            end

            if armed_at > 0 then
                if MODE == "cpu" then w16(A.p2_char, FT_JADE) end
                if ko_at == 0 then
                    snap_close()
                    hold("P1 High Punch", (frame % 12) < 5)
                    if (frame % 12) == 0 then punches = punches + 1 end
                    if r16(A.p2_bar) == 0 then
                        ko_at = frame
                        log("KO at frame %d (%d jab attempts)", frame, punches)
                        for n in pairs(fields) do hold(n, false) end
                    end
                end
            end
        end

        if MODE == "rounds" and ko_at > 0 and gs ~= GS_FIGHTING and (frame - ko_at) > 240 then
            if #rounds < 3 then
                fight_at, armed_at, ko_at, last_ws = 0, 0, 0, -1
                log("round %d over - waiting for the next one", #rounds)
            else
                done = true; verdict(); manager.machine:exit()
            end
        end

        if ko_at > 0 then
            local ws = r16(A.winner_status)
            ws_seen[ws] = true
            if ws ~= last_ws then
                log("  +%3d winner_status=%d gstate=%d", frame - ko_at, ws, gs)
                last_ws = ws
            end
            if ws == 3 then saw_finish = true end
            -- FINISH HIM holds winner_status at 3 for the whole window, so
            -- give it well past the 8-second (01e0h tick) fatality timer
            -- before deciding it never came.
            if frame - ko_at > 900 then
                if SNAP then manager.machine.video:snapshot() end
                done = true; verdict(); manager.machine:exit()
            end
        end

        if fight_at > 0 and ko_at == 0 and (frame - fight_at) > 2400 and gs == GS_FIGHTING then
            done = true; log("never landed a KO"); verdict(); manager.machine:exit()
        end
    end

    for n, fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end

    if frame > 9000 and not done then
        done = true
        log("timeout phase=%s psel=%d confirm=%d fight=%d ko=%d", phase, psel, confirm, fight_at, ko_at)
        verdict(); manager.machine:exit()
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
