-- raiden_shocker_ai_test.lua
--
-- Raiden's electrocute grab (hold HP, release close) never came out against
-- the CPU. Not a bug in the move -- retail refuses it outright:
--
--   rd_hp_open (MOVES.ASM)
--       calla   is_he_joy
--       jrnc    death           ; no zap on drones
--
-- so do_raiden_shocker was unreachable in single player. `rdshockai 1`
-- (MAINEQU.ASM) compiles that test out.
--
-- Two phases, identical inputs, only the opponent's nature changes:
--   DRONE - P2 is AI (p2_state = PS_INACTIVE). Retail scores ZERO here.
--   HUMAN - P2 is a second player: p2_state AND the pb_joy flag that
--           is_he_joy actually reads. The control: the move is reachable
--           here in BOTH switch states, so a zero in this column means the
--           rig is not producing the input and the drone column proves
--           nothing.
--
-- The human column may land as grabs or as whiffs depending on the stance
-- P2 was left in when the phase flipped (a held block makes the move's own
-- is_he_blocking test take useless_shock). Either counts: both mean
-- do_raiden_shocker was REACHED, which is all the control has to show.
--
-- What counts. P1's p_action is watched for the whole family, because a
-- REFUSAL and a WHIFF look nothing alike and only one of them is a failure:
--   act_shocker    0403h - the grab resolved. What we are here for.
--   act_shocker_sd 0615h - the grab came out and was refused by
--                          do_raiden_shocker itself (blocking / airborne /
--                          out of range) -> useless_shock. Still proves the
--                          joy gate is gone, because retail never reaches
--                          the routine at all.
-- Either one is a pass for the GATE; only the first is a landed grab, so
-- both are reported separately. The victim side (act_shock_sd 0613h on P2)
-- is logged too - that is the drone taking over cleanly after being shocked,
-- which is the half most likely to hang if it were mis-wired.
--
-- Env: RSK_LOG
-- Usage: tools\run_raiden_shocker_ai_test.ps1

local LOGP = os.getenv("RSK_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/raiden_shocker_ai_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[rsk] " .. string.format(fmt, ...)
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
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0        -- p_action = pdata+0f0h, pdata = 100h
-- is_he_joy reads pb_joy (bit 0) out of p_flags = pdata+110h. p2_state
-- alone does NOT move it: the flag is stamped when the player is built,
-- so flipping p2_state mid-fight left P2 a drone in BOTH phases and the
-- 'human' column was not a control at all. Drive the flag itself.
local PROC_FLAGS  = 0x210
local PB_JOY      = 0x0001
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_RAIDEN, FT_KANG = 7, 1

local ACT_SHOCKER    = 0x0403   -- the grab resolved
local ACT_SHOCKER_SD = 0x0615   -- came out, useless_shock took it
local ACT_SHOCK_SD   = 0x0613   -- the VICTIM, post-shock

-- get_tsl wants 050h ticks since HP went down, and one tick is one frame.
-- Hold well past it, then release -- rd_hp_open runs on the RELEASE.
local HOLD, PERIOD = 100, 150
local PHASE_FRAMES = 2400
local SETTLE = 40

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase_idx, phase_start = 1, 0
local phases = { "drone", "human" }
local hits = {
    drone = {grab=0, whiff=0, victim=0, rel=0},
    human = {grab=0, whiff=0, victim=0, rel=0},
}
local last_act, last_vact = -1, -1
local fields = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function finish()
    if done then return end
    done = true
    for _, ph in ipairs(phases) do
        log("RESULT %-5s releases=%d  grab(0403)=%d  whiff(0615)=%d  victim(0613)=%d",
            ph, hits[ph].rel, hits[ph].grab, hits[ph].whiff, hits[ph].victim)
    end
    local d, h = hits.drone, hits.human
    local fails = {}
    if h.grab + h.whiff == 0 then
        fails[#fails+1] = "HUMAN control never reached the shocker at all - " ..
            "the rig is not producing the input, so the drone column proves nothing"
    end
    if d.grab + d.whiff == 0 then
        fails[#fails+1] = "the CPU opponent never reached the shocker - " ..
            "rd_hp_open is still taking the is_he_joy branch"
    end
    if #fails == 0 then
        if d.grab > 0 then
            log("PASS rdshockai: the shocker LANDED on a CPU opponent %d time(s) " ..
                "(%d whiffed on block/range), against %d landed on a human",
                d.grab, d.whiff, h.grab)
        else
            log("PASS rdshockai: the gate is gone - the move reached " ..
                "do_raiden_shocker %d time(s) vs the CPU - but every one was " ..
                "refused by the move's own block/range checks, so a landed " ..
                "grab is still unproven", d.whiff)
        end
    else
        log("FAIL rdshockai: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["2 Players Start"]=true,
                   ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local hp_down = false

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    if name == "P1 High Punch" then
        local rel = frame - phase_start
        if rel < SETTLE then return false end
        return (rel % PERIOD) < HOLD
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- raiden shocker vs CPU: hold HP %d frames, release, every %d ----",
            HOLD, PERIOD)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)     -- phase 1 opponent is the CPU
        w16(A.p1_char, FT_RAIDEN)
        w16(A.p2_char, FT_KANG)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase_start = frame
        log("fight start frame=%d phase=%s", frame, phases[1])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    -- P2's nature is the whole experiment, so it is re-asserted every frame --
    -- both halves of it: the state word AND the pb_joy flag that is_he_joy
    -- actually reads.
    local want_human = (phases[phase_idx] == "human")
    w16(A.p2_state, want_human and PS_ACTIVE or PS_INACTIVE)
    do
        local vp2 = (A.p2_proc ~= 0) and r32(A.p2_proc) or 0
        if vp2 ~= 0 then
            local fl = r16(vp2 + PROC_FLAGS)
            local nf = want_human and (fl | PB_JOY) or (fl & ~PB_JOY & 0xffff)
            if nf ~= fl then w16(vp2 + PROC_FLAGS, nf) end
        end
    end
    if A.diff ~= 0 then w16(A.diff, 5) end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    -- Hold the pair inside the move's own 060h range test, so a miss is the
    -- gate rather than the spacing.
    local x1 = objx(A.p1_obj)
    if x1 then pin(A.p2_obj, x1 + 0x40) end

    local ph = phases[phase_idx]
    local settling = (frame - phase_start) < SETTLE

    -- count HP releases, so "the move never came out" can be told apart from
    -- "the rig never asked for it"
    local now_down = pressed("P1 High Punch")
    if hp_down and not now_down and not settling then
        hits[ph].rel = hits[ph].rel + 1
    end
    hp_down = now_down

    local p = r32(A.p1_proc)
    local act = (p ~= 0) and r16(p + PROC_ACTION) or 0xffff
    if act ~= last_act then
        if settling then
            if act == ACT_SHOCKER or act == ACT_SHOCKER_SD then
                log("%s: (settle) carry-over act=0x%04x ignored", ph, act)
            end
        elseif act == ACT_SHOCKER then
            hits[ph].grab = hits[ph].grab + 1
            log("%s: SHOCKER GRAB act=0x%04x (#%d)", ph, act, hits[ph].grab)
        elseif act == ACT_SHOCKER_SD then
            hits[ph].whiff = hits[ph].whiff + 1
            log("%s: shocker whiffed (useless_shock) act=0x%04x (#%d)",
                ph, act, hits[ph].whiff)
        end
        last_act = act
    end

    local vp = (A.p2_proc ~= 0) and r32(A.p2_proc) or 0
    local vact = (vp ~= 0) and r16(vp + PROC_ACTION) or 0xffff
    if vact ~= last_vact then
        if vact == ACT_SHOCK_SD and not settling then
            hits[ph].victim = hits[ph].victim + 1
            log("%s: victim in act_shock_sd (#%d)", ph, hits[ph].victim)
        end
        last_vact = vact
    end

    if frame - phase_start > PHASE_FRAMES then
        phase_idx = phase_idx + 1
        if phase_idx > #phases then finish(); return end
        phase_start = frame
        hp_down = false
        log("---- phase -> %s ----", phases[phase_idx])
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
