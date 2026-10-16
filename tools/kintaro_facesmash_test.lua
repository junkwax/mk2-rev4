-- kintaro_facesmash_test.lua
--
-- Kintaro's FACE SMASH (goro_facesmash, MKBOSS.ASM) - the `FACE SMASH` seqscr
-- authored in data/TIGER4.IMG, whose TIGERFACE1..8 art has sat in the video
-- ROM since the leak with no animation table and no go_anitab1 slot.
--
-- Trigger: goro4 in goro_stalk (MKBOSS.ASM) - his close-range decision, on the
-- ground only.  The rig pins P1 next to him and jabs so he keeps closing.
--
-- (The first wiring put it on stop_abusive_attackers instead.  That branch
-- needs boss_wait_nonattack to TIME OUT, which a jab never causes, so the move
-- never ran once in a 5400-frame trial - the same unreachable-trigger trap the
-- get-up kick documents for rt_goro_close.  The offer is still there as well,
-- it is just not the one that fires.)
--
-- It is a GRAB AND PUNCH in do_noogy's shape: TIGERFACE3 is the catch, then
-- the victim is HELD (takeover_him, Jax's gotcha-grab victim pose) and punched
-- in the face twice.  Branches off @debug4:
--
--   7110  reaching out
--   7111  CAUGHT him - he is held from here
--   7112  first punch landed
--   7113  the grab closed on nothing
--   7114  second punch landed
--   7115  the catch was blocked
--
-- A catch MUST be followed by both punches: 7111 without 7112 and 7114 means
-- the hold broke, which is the failure this shape exists to avoid.
--
-- Env: KFS_LOG, KFS_FRAMES, KFS_DIFF, KFS_DODGE
-- Usage: tools\run_kintaro_facesmash_test.ps1

local LOGP   = os.getenv("KFS_LOG") or "C:/Users/you/Workplace/mk2-main/tools/kintaro_facesmash_test.log"
local FRAMES = tonumber(os.getenv("KFS_FRAMES") or "5400")
local DIFF   = tonumber(os.getenv("KFS_DIFF") or "9")
-- DODGE (kept as the -Shots switch): snapshot the whole grab every 4 ticks,
-- because whether the victim actually hangs in his hands at the right height
-- is not a thing any counter can answer.
local DODGE  = (os.getenv("KFS_DODGE") or "") ~= ""


local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[kfs] " .. string.format(fmt, ...)
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

local OXVAL, OXPOS, OXVEL = 0x080, 0x090, 0x040
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_GORO = 1, 12
local ARENA = 5

local BC = { [0x7110]="start", [0x7111]="caught", [0x7112]="punch1",
             [0x7113]="whiffed", [0x7114]="punch2", [0x7115]="blocked" }

local frame, space = 0, nil
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local n = { start=0, caught=0, punch1=0, whiffed=0, punch2=0, blocked=0 }
local damage, hits = 0, 0
local last_bc, last_p1hp = 0, MAX_HP
local use_open, use_hits = false, 0     -- guards the mutual-exclusion claim
local use_start = -999
local overlap = 0
local stand_until, snap_at = -999, -999
local shot_until, shot_next = -999, -999
-- The second punch is supposed to throw him, the way the gotcha grab's last
-- hit does (r_last_noogy -> r_roundh).  Sample his x velocity after it: a
-- release that merely lets go reads 0 here.
local kb_until, kb_peak, kb_n = -999, 0, 0
local dodge_from, dodge_to = -999, -999
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
    log("RESULT %s: started=%d caught=%d punch1=%d punch2=%d whiffed=%d blocked=%d " ..
        "p1_damage=%d over %d hits",
        reason, n.start, n.caught, n.punch1, n.punch2, n.whiffed, n.blocked, damage, hits)
    if n.start == 0 then
        log("FAIL: goro_facesmash never ran - goro4 never chose it")
    elseif n.caught == 0 then
        log("PARTIAL: it reached out %d times and never caught anyone", n.start)
    elseif n.punch1 < n.caught or n.punch2 < n.caught then
        log("FAIL: caught %d but only %d/%d punches landed - the hold is breaking",
            n.caught, n.punch1, n.punch2)
    elseif hits ~= n.punch1 + n.punch2 then
        log("FAIL: %d punches but %d damage events - damage_to_him is not matching",
            n.punch1 + n.punch2, hits)
    elseif kb_n < n.punch2 then
        log("FAIL: %d second punches but only %d threw him - the release is not r_last_noogy",
            n.punch2, kb_n)
    else
        log("PASS: grabbed %d times, %d + %d punches, %d damage (%d per punch), thrown %d",
            n.caught, n.punch1, n.punch2, damage,
            (n.punch1 + n.punch2) > 0 and damage // (n.punch1 + n.punch2) or 0, kb_n)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["UI Select"]=true }
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
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    -- Stop attacking once the move starts, so P1 stands there and the smash
    -- has something to hit.  Attacking through it measures the trade instead.
    if frame < stand_until then return false end
    if name == "P1 High Punch" then return ((frame - fighting_frame) % 26) < 6 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- kintaro face smash: debug4=%08x diff=%d frames=%d ----", A.debug4, DIFF, FRAMES)
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

    -- A use that gets interrupted writes no terminal crumb, and the NEXT use
    -- writes 7110 again - which is not a change, so the rig cannot see it.
    -- Expire the window on time as well, or the next uppercut's 40 gets
    -- counted as face-smash damage (it did: three 40s inside one "use").
    -- Damage is attributed from the CATCH, not from the start.  A start that
    -- does not catch writes 7110 again next time, which a change-poller cannot
    -- see, so "start" can be 700 frames stale - and Kintaro's uppercut (40)
    -- then lands inside the window and is scored as face-smash damage.  It
    -- did, six times, before this.
    if use_open and frame - use_start > 40 then use_open = false end

    local hp = r16(A.p1_bar)
    if hp < last_p1hp and use_open then
        damage = damage + (last_p1hp - hp); hits = hits + 1
        log("DAMAGE %d to P1 (total %d over %d)", last_p1hp - hp, damage, hits)
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    last_p1hp = MAX_HP
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    -- Positions FIRST: the breadcrumb block logs them and the pin below uses
    -- them, and the pin must not run on the frame the catch lands or it yanks
    -- the victim straight back out of the hold.
    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    local gap = math.abs((x2 or 0) - (x1 or 0))

    local bc = r16(A.debug4)
    if bc ~= last_bc then
        local tag = BC[bc]
        if tag then
            n[tag] = n[tag] + 1
            if tag == "start" then
                stand_until = frame + 90
                log("START #%d frame=%d gap=%d", n.start, frame, gap)
            elseif tag == "caught" then
                -- The damage window opens HERE, not at the start.  A start that
                -- does not catch rewrites 7110, which a change-poller cannot
                -- see, so "start" can be hundreds of frames stale - and his
                -- uppercut (40) then lands inside the window and gets scored as
                -- grab damage.  It did, six times.
                use_open, use_start = true, frame
                stand_until = frame + 90
                if n.caught <= 2 then shot_until, shot_next = frame + 44, frame end
                log("  %-13s frame=%d gap=%d", tag, frame, gap)
            else
                log("  %-13s frame=%d gap=%d", tag, frame, gap)
                if tag == "whiffed" or tag == "blocked" then use_open = false end
                if tag == "punch2" then
                    kb_until, kb_peak = frame + 26, 0
                    use_start = frame - 14         -- keep the pin off for the throw
                end
            end
        end
        last_bc = bc
    end

    if frame <= kb_until then
        local o = r32(A.p1_obj)
        if o ~= 0 then
            local v = space:read_u32(o + OXVEL)
            if v >= 0x80000000 then v = v - 0x100000000 end
            if math.abs(v) > math.abs(kb_peak) then kb_peak = v end
        end
        if frame == kb_until then
            kb_n = kb_n + (math.abs(kb_peak) >= 0x20000 and 1 or 0)
            log("  knockback     peak xvel=%s (%s)", string.format("%d", kb_peak),
                math.abs(kb_peak) >= 0x20000 and "THROWN" or "no throw")
        end
    end

    -- DO NOT PIN DURING THE HOLD.  gfs_lineup puts the victim in Kintaro's
    -- hands with adjust_him_a0; a pin fighting that rips him straight back out
    -- and the rig then measures its own interference.
    if not use_open and x1 and x2 and gap > 60 then
        if x2 > x1 then pin(A.p1_obj, x2 - 52) else pin(A.p1_obj, x2 + 52) end
    end

    -- Shoot the whole grab so the hold can be LOOKED at: whether the victim
    -- is in his hands at the right height is not something a counter answers.
    if frame <= shot_until and frame >= shot_next then
        manager.machine.video:snapshot()
        shot_next = frame + 4
    end

    if frame - fighting_frame > FRAMES then finish("window_elapsed") end
    if frame > 40000 then finish("global_timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
