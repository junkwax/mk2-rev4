-- bike_ghost_test.lua - Liu Kang's bicycle kick trails afterimages
-- (MKPROP.ASM do_bicycle -> MKDISP.ASM ghost_arm / ghost_disarm / ghost_rec).
-- doc/graphics_opportunities/GHOSTS_PROTOTYPE.md.
--
-- 2-player game, P1 Liu Kang vs an idle P2 Jax, on BG_STAGE.  Three trials,
-- each placed by pinning both fighters, then P1 holds Low Kick past the 2 s
-- charge (lk_lk_open) and lets go:
--   whiff  380 px apart: the kick flies, misses and lands (disarm on landing)
--   hit    110 px apart: contact (disarm at contact, before the pummel)
--   block  110 px apart, P2 holding Block: blocked contact (same disarm)
--
-- BG_MODE=on  normal ROM behaviour.  BG_MODE=off writes gh_n = 0 every frame,
-- so ghost_rec draws nothing - the control the runner compares captures with.
--
-- Checks (mode on), per trial: the trail ARMED, held at least the trial's
-- minimum of ghosts at some frame, and DISARMED (gh_src 0, list empty) before
-- the trial ends.  Snapshots every 3 frames for the first 45 frames after
-- release, each logging the free object / process counts: the runner compares
-- those with the BG_MODE=off boot at the same frames (the kick itself moves
-- them, so only an on/off comparison says whether the ghosts took any).
--
-- env: BG_MODE (on|off), BG_STAGE (curback, default 0), BG_LOG, MK2_ROOT
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("BG_MODE") or "on"
local STAGE = tonumber(os.getenv("BG_STAGE") or "0")
local CHAR = tonumber(os.getenv("BG_CHAR") or "1")
local TRACE = os.getenv("BG_TRACE") == "1"
local LOG = os.getenv("BG_LOG") or (ROOT .. "/tools/bike_ghost_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[bg] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"), p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), worldtlx = sym("worldtlx"),
    gh_src = sym("gh_src"), gh_n = sym("gh_n"), gh_life = sym("gh_life"), ghost_lst = sym("ghost_lst"),
    gh_snaps = sym("gh_snaps"), ofree = symbols["ofree"], pfree = symbols["free"],
    switch = symbols["switch"], switch2 = symbols["switch2"],
}
local OXVAL, OXPOS, PROC_ACTION = 0x080, 0x090, 0x1f0
local ACT_BIKE = 0x0204
local GS_PSEL, GS_FIGHTING = 4, 2
local MAXBAR = 0xa1
local CRAM = 0x01800000
local PENS = { 0x0b, 0x05, 0x04, 0x0a }
-- move: which producer the trial fires.  "bike" is Liu Kang's bicycle kick
-- (hold Low Kick past the 2 s charge, then let go); "dive" is Raiden's
-- torpedo (Away, Away, Block in the air); "slide" is the shared slide
-- (Away + Low Kick while ducking).  BG_CHAR picks the fighter, so the runner
-- can put Raiden on P1 for the dive trials.
local TRIALS_BY_MOVE = {
    bike = {
        { name = "bike_whiff", gap = 380, block = false, min = 3 },
        { name = "bike_hit",   gap = 110, block = false, min = 1 },
        { name = "bike_block", gap = 110, block = true,  min = 1 },
    },
    dive = {
        { name = "dive_whiff", gap = 380, block = false, min = 3 },
        { name = "dive_hit",   gap = 150, block = false, min = 1 },
        { name = "dive_block", gap = 150, block = true,  min = 1 },
    },
    slide = {
        { name = "slide_whiff", gap = 330, block = false, min = 2 },
        { name = "slide_hit",   gap = 120, block = false, min = 1 },
        { name = "slide_block", gap = 120, block = true,  min = 1 },
    },
}
local MOVE = os.getenv("BG_MOVE") or "bike"
local TRIALS = assert(TRIALS_BY_MOVE[MOVE], "BG_MOVE must be bike, dive or slide")
local PLACE, CHARGE, WATCH = 60, 150, 160

local frame, space, fields = 0, nil, {}
local charsel_frame, fighting_frame, confirm = 0, 0, 0
local trial_i, phase, phase_at = 0, "idle", 0
local T = {}
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true, ["P1 Low Kick"] = true, ["P2 Block"] = true,
                   ["P1 Up"] = true, ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Down"] = true,
                   ["P1 Block"] = true, ["P1 Low Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input %s", n) end end
end

local function free_len(head, cap)
    if not head then return nil end
    local n, p = 0, r32(head)
    while p ~= 0 and n < cap do n = n + 1; p = r32(p) end
    return n
end
local function list_len()
    local n, p = 0, r32(A.ghost_lst)
    while p ~= 0 and n < 16 do n = n + 1; p = r32(p) end
    return n
end
local function objx(ptr) local o = r32(ptr); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function pin(ptr, x) local o = r32(ptr); if o == 0 then return end
    w32(o + OXVAL, (x & 0xffff) << 16); w16(o + OXPOS, x) end
local function p1_action() local p = r32(A.p1_proc); return p ~= 0 and r16(p + PROC_ACTION) or 0xffff end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return (name == "P1 High Punch" or name == "P2 High Punch") and confirm > 0 and frame >= confirm and frame < confirm + 40
    end
    local t = TRIALS[trial_i]
    if not t then return false end
    local rel = frame - phase_at
    if name == "P2 Block" then return t.block and (phase == "charge" or phase == "watch") end
    if phase ~= "charge" then return false end
    if MOVE == "bike" then
        -- hold Low Kick past the 2 s charge; lk_lk_open fires on release
        return name == "P1 Low Kick"
    elseif MOVE == "dive" then
        -- scom_rd_dive: Back, Back, Forward within 32 ticks, IN THE AIR,
        -- with Low Kick as the button that runs the detector (rd_left_right
        -- sits in the lo-kick dispatch).  P2 is to the right, so Back = Left.
        if name == "P1 Up" then return rel >= 20 and rel < 25 end
        if name == "P1 Left" then return (rel >= 40 and rel < 45) or (rel >= 50 and rel < 55) end
        if name == "P1 Right" then return rel >= 60 and rel < 66 end
        if name == "P1 Low Kick" then return rel >= 62 and rel < 68 end
        return false
    else
        -- slide_check: stick AWAY plus p1b2 and p1b1|p1b4 held together, i.e.
        -- Block + Low Punch + Low Kick (b0 HP, b1 LP, b2 BL, b3 HK, b4 LK).
        if name == "P1 Left" then return rel >= 20 end
        if name == "P1 Block" or name == "P1 Low Punch" or name == "P1 Low Kick" then
            return rel >= 40 and rel < 48
        end
        return false
    end
end

local function finish()
    if finished then return end
    finished = true
    local ok = true
    for i, t in ipairs(TRIALS) do
        local r = T[i] or {}
        -- The pool is judged by the runner, on vs off at the same frames: the kick
        -- itself moves the free counts, so a before/after here proves nothing.
        local pass = MODE ~= "on" or (r.armed and (r.max_len or 0) >= t.min and r.disarmed and r.bike)
        ok = ok and pass
        log("TRIAL %s mode=%s armed=%s bike=%s max_len=%s disarm_rel=%s disarm_action=%04x pool_ok=%s snaps=%s %s",
            t.name, MODE, tostring(r.armed), tostring(r.bike), tostring(r.max_len), tostring(r.disarm_rel),
            r.disarm_action or 0, tostring(r.pool_ok), tostring(r.snaps), pass and "PASS" or "FAIL")
    end
    local end_src = space and r32(A.gh_src) or -1
    ok = ok and end_src == 0
    log("RESULT %s mode=%s move=%s stage=%d gh_src_at_end=%08x", ok and "PASS" or "FAIL", MODE, MOVE, STAGE, end_src)
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("start mode=%s stage=%d move=%s char=%d", MODE, STAGE, MOVE, CHAR)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space or finished then return end
    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, CHAR); w16(A.p2_char, 11)
        w16(A.curback, STAGE); w16(A.map_position, 0); w16(A.battle_num, 1)
        if confirm == 0 and frame - charsel_frame > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("PREARM frame=%d p1x=%s p2x=%s cam=%d curback=%d", frame, tostring(objx(A.p1_obj)), tostring(objx(A.p2_obj)),
            s16(r32(A.worldtlx) >> 16), r16(A.curback))
        local pens = {}
        for _, i in ipairs(PENS) do pens[#pens + 1] = string.format("%02x=%04x", i, r16(CRAM + i * 16)) end
        log("PENS %s", table.concat(pens, " "))
        trial_i, phase, phase_at = 1, "place", frame
    end
    if fighting_frame == 0 then
        if frame > 7000 then log("ERROR never reached fight"); finish() end
        return
    end
    w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR); w16(A.p1_bar_view, MAXBAR); w16(A.p2_bar_view, MAXBAR)
    w16(A.winner_status, 0)
    if MODE == "off" then w16(A.gh_n, 0) end

    local t = TRIALS[trial_i]
    if not t then finish(); return end
    if TRACE and phase ~= "idle" then
        local o = r32(A.p1_obj)
        log("TR %s %s rel=%d act=%04x y=%s sw=%08x sw2=%08x src=%08x", t.name, phase, frame - phase_at,
            p1_action(), o ~= 0 and tostring(s16(r16(o + 0x0b0))) or "na",
            A.switch and r32(A.switch) or 0, A.switch2 and r32(A.switch2) or 0, r32(A.gh_src))
    end
    T[trial_i] = T[trial_i] or {}
    local r = T[trial_i]
    local rel = frame - phase_at
    -- Trail tracking runs in every phase.  The bicycle kick fires when Low Kick
    -- is RELEASED (end of charge), but the dive and slide fire the moment their
    -- gesture completes, i.e. inside the charge phase - watching only the watch
    -- phase saw a perfectly good trail arm and clear before the rig looked.
    do
        local src, n = r32(A.gh_src), list_len()
        if MOVE == "bike" then
            if p1_action() == ACT_BIKE then r.bike = true end
        elseif src ~= 0 then
            r.bike = true
        end
        if src ~= 0 and not r.armed then
            r.armed = frame
            r.free_obj0, r.free_proc0 = free_len(A.ofree, 400), free_len(A.pfree, 200)
            log("ARM %s phase=%s rel=%d life=%d", t.name, phase, rel, r16(A.gh_life))
        end
        if n > (r.max_len or 0) then r.max_len = n end
        if r.armed and src == 0 and n == 0 and not r.disarmed then
            r.disarmed = true
            r.disarm_rel = frame - r.armed
            r.disarm_action = p1_action()
            log("DISARM %s rel_after_arm=%d action=%04x snaps=%d", t.name, r.disarm_rel, r.disarm_action, r16(A.gh_snaps))
        end
        -- snapshots hang off the ARM, not a fixed frame
        if r.armed and (r.snaps or 0) < 15 and (frame - r.armed) % 3 == 0 then
            manager.machine.video:snapshot()
            r.snaps = (r.snaps or 0) + 1
            log("SNAP %s rel=%d list=%d src=%08x free_obj=%s free_proc=%s", t.name, frame - r.armed, n, src,
                tostring(free_len(A.ofree, 400)), tostring(free_len(A.pfree, 200)))
        end
    end

    if phase == "place" or phase == "charge" then
        if not r.mid then
            -- set on the trial's first placing frame, whenever that is: a trial
            -- that starts from the previous one's watch phase arrives at rel 1
            local x1, x2 = objx(A.p1_obj) or 600, objx(A.p2_obj) or 700
            r.mid = (x1 + x2) // 2
        end
        pin(A.p1_obj, r.mid - t.gap // 2); pin(A.p2_obj, r.mid + t.gap // 2)
        if phase == "place" and rel >= PLACE then phase, phase_at = "charge", frame end
        if phase == "charge" and rel >= CHARGE then
            phase, phase_at = "watch", frame
            r.free_obj0, r.free_proc0 = free_len(A.ofree, 400), free_len(A.pfree, 200)
        end
        return
    end
    -- watch phase: just let the trial run out; tracking above does the work
    if rel >= WATCH then
        trial_i, phase, phase_at = trial_i + 1, "place", frame
    end
end)

emu.register_stop(function() if logfh then logfh:close() end end)
