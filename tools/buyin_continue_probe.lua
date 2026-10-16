-- buyin_continue_probe.lua
--
-- Second half of the continue-screen test: the countdown expiring is one
-- path, PRESSING START to actually kontinue is the other, and it runs
-- completely different code (start_pstate_jumps -> buyin_check -> cr_contp ->
-- p_cont -> start_a_game).  Neither had run since April.
--
-- Drives a 1P match to a loss, waits for gs_buyin, taps START, and reports
-- where the game lands.  PASS = back into a fight (gstate 2/6/7) with p1
-- active again.  FAIL = stuck in gs_buyin, dropped to game over (11) /
-- attract (1), or parked in a trap handler.
--
-- Env: BUYIN_LOG, BUYIN_MODE ("continue" default, "initials" forces a win
-- streak first so check_enter_initials runs).

local LOGP = os.getenv("BUYIN_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/buyin_continue_probe.log"
local MODE = os.getenv("BUYIN_MODE") or "continue"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[cont] " .. string.format(fmt, ...)
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

local A = {
    gstate = sym("gstate"), active = sym("active"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_wiar = sym("p1_wiar"), p2_wiar = sym("p2_wiar"),
    curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), winner_status = sym("winner_status"),
    p1_matchw = sym("p1_matchw"), p2_matchw = sym("p2_matchw"),
    system_lockup = sym("system_lockup"), tvbp = sym("TVBP"),
}

local P_PROCID, P_PTIME, P_WAKE = 0x20, 0x30, 0xe0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING, GS_BUYIN = 4, 2, 3
local P1_CHAR, P2_CHAR, STAGE = 1, 11, 0

local frame, space, cpu = 0, nil, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local buyin_frame, start_frame, done, did_select = 0, 0, false, false
local fields, last_gstate = {}, -1
local resumed_frame = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end

local function finish(why)
    if done then return end
    done = true
    log("RESULT: %s", why)
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    -- START tap while the buy-in countdown is up
    if name == "1 Player Start" and start_frame > 0 then
        return frame >= start_frame and frame < start_frame + 12
    end
    if fighting_frame > 0 then return false end
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

local function procs()
    local out, p, n = {}, r32(A.active), 0
    while p ~= 0 and n < 48 do
        n = n + 1
        out[#out+1] = string.format("pid%d@0x%08x(t=%d)",
            r16(p + P_PROCID), r32(p + P_WAKE), r16(p + P_PTIME))
        p = r32(p)
    end
    return table.concat(out, " ")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cpu = manager.machine.devices[":maincpu"]
        cache_fields()
        log("---- continue probe (mode=%s) ----", MODE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, P1_CHAR)
        w16(A.p2_char, P2_CHAR)
        w16(A.curback, STAGE)
        if A.map_position ~= 0 then w16(A.map_position, STAGE) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if not did_select then did_select = true; log("forced kang vs jax on stage %d", STAGE) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d", frame)
        -- initials mode: fake a long win streak so does_a0_cut_it passes and
        -- check_enter_initials actually runs on the way to the buy-in screen.
        if MODE == "initials" then
            w16(A.p1_wiar, 10)
            log("forced p1_wiar=10 to exercise check_enter_initials")
        end
    end

    -- twoplayer mode: the drone still does the killing (nothing else can drive
    -- a real fight to a conclusion here), but p2 is flipped to ps_active once
    -- the match is decided so play9 takes the 2-player branch: loser -> buyin,
    -- winner -> "PREPARE FOR YOUR NEXT CHALLENGE" on the other half.
    -- Only once the MATCH is decided (2 rounds), otherwise p2 stops being a
    -- drone mid-match and the fight stalls with nobody throwing a punch.
    if MODE == "twoplayer" and gs == 5 and buyin_frame == 0
       and (r16(A.p1_matchw) >= 2 or r16(A.p2_matchw) >= 2) then
        if r16(A.p2_state) ~= PS_ACTIVE then
            w16(A.p2_state, PS_ACTIVE)
            log("match decided (p1_matchw=%d p2_matchw=%d) - flipped p2_state -> ps_active",
                r16(A.p1_matchw), r16(A.p2_matchw))
        end
    end
    if fighting_frame == 0 then
        if frame > 6000 then finish("FAIL never reached fight") end
        return
    end

    if gs ~= last_gstate then
        log("gstate %d -> %d at frame %d (p1_state=%d p2_state=%d)",
            last_gstate, gs, frame, r16(A.p1_state), r16(A.p2_state))
        last_gstate = gs
    end

    local pc
    do
        local ok, item = pcall(function() return cpu.state["PC"] end)
        if ok and item then pc = item.value end
    end
    if pc and A.system_lockup ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
        log("procs: %s", procs())
        finish(string.format("FAIL trap handler at pc=0x%08x", pc))
        return
    end

    if gs == GS_BUYIN and buyin_frame == 0 then
        buyin_frame = frame
        log("*** entered gs_buyin at frame %d (p1_state=%d p2_state=%d) ***",
            frame, r16(A.p1_state), r16(A.p2_state))
        start_frame = frame + 240      -- let the slide + a few digits run first
        log("will tap START at frame %d", start_frame)
    end

    -- snapshot the screen so the text/doors/countdown can actually be looked at
    if buyin_frame > 0 and resumed_frame == 0 then
        local rel = frame - buyin_frame
        if rel == 60 or rel == 150 or rel == 230 then
            manager.machine.video:snapshot()
            log("snapshot at %d ticks into gs_buyin", rel)
        end
    end

    if buyin_frame > 0 and start_frame > 0 and frame == start_frame + 20 then
        log("START tapped; gstate=%d p1_state=%d procs: %s",
            gs, r16(A.p1_state), procs())
    end

    if buyin_frame > 0 and gs ~= GS_BUYIN and resumed_frame == 0 then
        resumed_frame = frame
        log("left gs_buyin -> gstate %d after %d ticks (p1_state=%d)",
            gs, frame - buyin_frame, r16(A.p1_state))
    end

    if resumed_frame > 0 then
        if gs == GS_FIGHTING and frame > resumed_frame + 30 then
            finish(string.format("PASS back in a fight %d ticks after START (p1_hp=%d p2_hp=%d)",
                frame - start_frame, r16(A.p1_bar), r16(A.p2_bar)))
            return
        end
        if frame - resumed_frame > 2400 then
            finish(string.format("FAIL never got back to a fight; gstate=%d procs: %s",
                gs, procs()))
            return
        end
    end

    if buyin_frame > 0 and frame - buyin_frame > 3000 then
        finish("FAIL stuck in gs_buyin")
    end
    if frame - fighting_frame > 14000 then finish("FAIL match never ended") end
    if frame > 26000 then finish("FAIL global timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
