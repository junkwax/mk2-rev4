-- kintaro_backhand_test.lua
--
-- Kintaro's BACKHAND (goro_backhand, MKBOSS.ASM) - the `BACKHAND` seqscr
-- authored in data/TIGER4.IMG, whose TIGERBACK1..6 art has sat in the video
-- ROM since the leak with no animation table and no go_anitab1 slot.
--
-- Trigger: drone_turnaround (MKDRONE.ASM).  The art is a rotation, so the move
-- IS a turn with a strike box on the way past - which means the rig has to
-- CROSS HIM UP.  It does that by teleporting P1 to his other side on a timer,
-- which is what makes am_i_facing_him fail and sends him to the turnaround.
--
-- Breadcrumbs (@debug4):
--
--   7120  the move started
--   7121  whiffed
--   7122  CONNECTED
--   7123  refused - too far to reach
--   7124  in range, ask_mr_diff said no
--
-- KBH_SHOTS=1 snapshots the whole lane a frame-triple at a time, which is how
-- the spin gets looked at rather than reasoned about.
--
-- Env: KBH_LOG, KBH_FRAMES, KBH_DIFF, KBH_SHOTS
-- Usage: tools\run_kintaro_backhand_test.ps1

local LOGP   = os.getenv("KBH_LOG") or "C:/Users/you/Workplace/mk2-main/tools/kintaro_backhand_test.log"
local FRAMES = tonumber(os.getenv("KBH_FRAMES") or "5400")
local DIFF   = tonumber(os.getenv("KBH_DIFF") or "9")
local SHOTS  = (os.getenv("KBH_SHOTS") or "") ~= ""

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[kbh] " .. string.format(fmt, ...)
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
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    debug4 = sym("debug4"), f_freeze_timer = sym("f_freeze_timer"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_GORO = 1, 12
local ARENA = 5

local BC = { [0x7120]="start", [0x7121]="whiffed", [0x7122]="connected",
             [0x7123]="too_far", [0x7124]="roll_declined" }

local frame, space = 0, nil
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local n = { start=0, whiffed=0, connected=0, too_far=0, roll_declined=0 }
local damage, hits = 0, 0
local last_bc, last_p1hp = 0, MAX_HP
local use_open, use_start = false, -999
local side = -1                 -- which side of Kintaro P1 is pinned on
local next_flip = -999
local shot_until, shot_next = -999, -999
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

local function finish(reason)
    if done then return end
    done = true
    local offers = n.start + n.too_far + n.roll_declined
    log("RESULT %s: gate_ran=%d started=%d connected=%d whiffed=%d too_far=%d roll_declined=%d damage=%d over %d hits",
        reason, offers, n.start, n.connected, n.whiffed, n.too_far, n.roll_declined, damage, hits)
    if offers == 0 then
        log("FAIL: goro_backhand_check never ran - he was never sent to drone_turnaround")
    elseif n.start == 0 then
        log("FAIL: the gate ran %d times and never took the move", offers)
    elseif n.connected + n.whiffed < n.start then
        log("FAIL: %d starts but only %d finished - the lane is not completing", n.start, n.connected + n.whiffed)
    elseif n.connected == 0 then
        log("PARTIAL: the backhand spun %d times and never connected", n.start)
    else
        log("PASS: backhand fired %d times, connected %d, %d damage", n.start, n.connected, damage)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true, ["UI Select"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
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
        log("---- kintaro backhand: debug4=%08x diff=%d frames=%d shots=%s ----",
            A.debug4, DIFF, FRAMES, tostring(SHOTS))
    end
    for nm, f in pairs(fields) do f:set_value(pressed(nm) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then log("frame=%d gstate %d -> %d", frame, last_gstate, gs); last_gstate = gs end
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG);    w16(A.p2_char, FT_GORO)
        w16(A.curback, ARENA); w16(A.map_position, 13); w16(A.battle_num, 14)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        next_flip = frame + 120
        log("fight_start frame=%d p1=%d p2=%d", frame, r16(A.p1_char), r16(A.p2_char))
        last_p1hp = MAX_HP
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish("no_fight") end
        return
    end
    if r16(A.p2_char) ~= FT_GORO then
        log("ERROR p2 is not Kintaro (%d)", r16(A.p2_char)); finish("wrong_opponent"); return
    end

    w16(A.diff, DIFF)
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    if use_open and frame - use_start > 60 then use_open = false end
    local hp = r16(A.p1_bar)
    if hp < last_p1hp and use_open then
        damage = damage + (last_p1hp - hp); hits = hits + 1
        log("DAMAGE %d to P1 (total %d over %d)", last_p1hp - hp, damage, hits)
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    last_p1hp = MAX_HP
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    -- THE CROSS-UP.  Teleporting P1 to his other side is what makes
    -- am_i_facing_him fail, which is the only road to drone_turnaround.
    -- Do not do it while the move is running or he gets yanked out of reach
    -- mid-spin and every use reads as a whiff.
    if frame >= next_flip and not use_open then
        side = -side
        next_flip = frame + 150
    end
    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then pin(A.p1_obj, x2 + side * 50) end

    local bc = r16(A.debug4)
    if bc ~= last_bc then
        local tag = BC[bc]
        if tag then
            n[tag] = n[tag] + 1
            local gap = math.abs((x2 or 0) - (x1 or 0))
            if tag == "start" then
                use_open, use_start = true, frame
                if SHOTS and n.start == 1 then shot_until, shot_next = frame + 30, frame end
                log("START #%d frame=%d gap=%d side=%d", n.start, frame, gap, side)
            else
                log("  %-13s frame=%d gap=%d (rel=%d)", tag, frame, gap, frame - use_start)
                if tag ~= "too_far" and tag ~= "roll_declined" then use_open = false end
            end
        end
        last_bc = bc
    end

    if SHOTS and frame <= shot_until and frame >= shot_next then
        manager.machine.video:snapshot()
        shot_next = frame + 3
    end

    if frame - fighting_frame > FRAMES then finish("window_elapsed") end
    if frame > 40000 then finish("global_timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
