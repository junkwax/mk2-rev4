-- reptile_forceball_test.lua
--
-- Reptile's forceball: the squash-and-stretch throb, and the "throw another
-- one the instant this one is spent" gate.
--
-- What it watches, from outside the ROM:
--
--   oscale        - the packed [ystep:xstep] the display list hands the DMA.
--                   0x0100 is 1:1 and a BIGGER step draws SMALLER, so the
--                   flat pose is a big ystep beside a small xstep.  This is
--                   the throb; there is no art for it.
--   mp_anix/aniy  - the multipart piece deltas.  dclip scales the PIECE but
--                   not the offset, so if these do not move with oscale the
--                   ball drifts off its own flight path as it pulses.
--   procid        - pid_orb1/2 (0702h/0802h) while it may still block a new
--                   throw, pid_orbx1/2 (0704h/0804h) once it is spent.
--
-- MK2_FB_MODE=slow|fast    which forceball (default slow)
-- MK2_FB_LOG / MK2_FB_ROOT / MK2_FB_SNAP

local frame = 0
local ROOT = os.getenv("MK2_FB_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("MK2_FB_LOG") or (ROOT .. "/tools/reptile_forceball.log")
local MODE = (os.getenv("MK2_FB_MODE") or "slow"):lower()
local SNAP_ON = os.getenv("MK2_FB_SNAP") ~= "0"
-- MK2_FB_CHASE=1: re-enter the throw the instant the last ball is marked
-- spent, instead of on a fixed cycle.  This is the behavioural half of the
-- gate test: the procid re-tag says existp can no longer see the old ball,
-- and this says a new one actually comes out while the old one is still on
-- the active list playing its explosion.
local CHASE = os.getenv("MK2_FB_CHASE") == "1"

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n") logfh:flush() end
end

-- ---------------------------------------------------------------- symbols
local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local missing = {}
local function sym(name)
    local v = symbols[name]
    if not v then missing[#missing + 1] = name return 0 end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"),
    map_position = sym("map_position"), battle_num = sym("battle_num"),
    active = sym("active"), tick = sym("tick"),
    f_freeze_timer = sym("f_freeze_timer"),
}

-- DISPEQU.ASM / MAINEQU.ASM - the space MAME hands lua is bit-addressed,
-- so these are the raw equates, not equates/8.
local O = { next=0x000, oxvel=0x040, oxval=0x080, oxpos=0x090, oypos=0x0b0, oflags=0x0f0,
            osizex=0x120, osizey=0x130, oflags2=0x160, oscale=0x180,
            oimg=0x1a0, oid=0x1c0, ochar=0x1f0 }
local P = { link=0x000, procid=0x020, pa8=0x0c0, action=0x1f0 }
local MP = { sag=0, sizex=32, sizey=32+16, anix=32+32+16, aniy=32+32+16+16,
             length=32+32+16+32 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_REPTILE, FT_JAX = 9, 11
local PS_ACTIVE, PS_INACTIVE = 1, 0
local PID_ORB = { [0x0702]=1, [0x0802]=1 }
local PID_ORBX = { [0x0704]=1, [0x0804]=1 }

local space, fields = nil, {}
local charsel_frame, fighting_frame, did_select = 0, 0, false
local p1_confirm_start = 0
local done_frame, verdict = 0, nil
local pin_x = nil
local GAP_PX = tonumber(os.getenv("MK2_FB_GAP") or "200") or 200

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff if v >= 0x8000 then return v-0x10000 end return v end
local function s32(v) v = v & 0xffffffff if v >= 0x80000000 then return v-0x100000000 end return v end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end
local snaps = 0
local function snap()
    if not SNAP_ON or snaps >= 24 then return end
    local s = main_screen()
    if s then snaps = snaps + 1 pcall(function() s:snapshot() end) end
end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Punch"]=true,
                   ["P1 Right"]=true, ["P1 Left"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

-- Every orb process on the active list, spent or not.
-- Prefers a LIVE orb (still pid_orb*) over a spent one, so that once a
-- chase run has two in the air the trace follows the new ball rather than
-- staying latched on the one that is finishing its explosion.
local function find_orb()
    local p, n, spent_p, spent_o, spent_id = r32(A.active), 0, nil, nil, nil
    while p ~= 0 and n < 400 do
        local id = r16(p + P.procid)
        local obj = r32(p + P.pa8)
        if obj ~= 0 then
            if PID_ORB[id] then return p, obj, id end
            if PID_ORBX[id] and spent_p == nil then spent_p, spent_o, spent_id = p, obj, id end
        end
        p = r32(p + P.link)
        n = n + 1
    end
    if spent_p then return spent_p, spent_o, spent_id end
    return nil
end

local function mp_first(obj)
    local ram = r32(obj + O.oimg)
    if ram == 0 or r32(ram + MP.sag) == 0 then return nil end
    return s16(r16(ram + MP.anix)), s16(r16(ram + MP.aniy)),
           r16(ram + MP.sizex), r16(ram + MP.sizey)
end

local function force_ladder()
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, FT_REPTILE)
    w16(A.p2_char, FT_JAX)
    w16(A.map_position, 0)
    w16(A.battle_num, 1)
    if not did_select then
        did_select = true
        print(string.format("[fb] direct_select frame=%d p1=%d p2=%d",
            frame, r16(A.p1_char), r16(A.p2_char)))
    end
end

-- ------------------------------------------------------------- throw plan
-- scom_slow_proj is Back,Back + LP with HI PUNCH in the queue within 4 ticks,
-- so both punches go down together (same as the deflect rig).
-- scom_fast_proj is Forward,Forward + HP+LP.
-- Chase runs enter the combo as tightly as the window allows; a leisurely
-- sequence would take longer than the whole explosion and prove nothing.
local TAP, GAP = 4, 2
if CHASE then TAP, GAP = 2, 1 end
local DIRS = (MODE == "fast") and { "P1 Right", "P1 Right" }
                              or  { "P1 Left",  "P1 Left"  }
local throw_no = 0
local arm_frame = 0
local CYCLE = 110               -- one scripted throw attempt every ~2s
if CHASE then CYCLE = 40 end

local function throw_phase()
    if arm_frame == 0 then return "idle" end
    local t = frame - arm_frame
    if t < 0 then return "idle" end
    t = t % CYCLE
    for i = 1, #DIRS do
        local base = (i-1) * (TAP+GAP)
        if t < base + TAP then return "dir"..i end
        if t < base + TAP + GAP then return "gap" end
    end
    if t < #DIRS*(TAP+GAP) + 10 then return "punch" end
    return "idle"
end

local function pressed(name)
    if fighting_frame == 0 then
        if charsel_frame > 0 then
            if name == "P1 High Punch" and p1_confirm_start > 0 then
                return frame >= p1_confirm_start and frame < p1_confirm_start + 45
            end
            return false
        end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    local ph = throw_phase()
    for i = 1, #DIRS do
        if name == DIRS[i] and ph == ("dir"..i) then return true end
    end
    if (name == "P1 Low Punch" or name == "P1 High Punch") then return ph == "punch" end
    return false
end

-- ------------------------------------------------------------- the record
local cur = nil
local finished = {}
local rethrow_gap = nil
local last_spent_frame = 0
local max_live, overlap_frame = 0, 0
-- ticks from an orb appearing to it being marked spent.  Deterministic
-- for a given gap, so ball #1 teaches the rig when to start entering the
-- next combo: the punch has to land ON the spent frame, not 26 frames
-- after it, or the input path is what is being measured and not the gate.
local spent_dt = nil
-- The decisive gate reading: while a spent ball is still on the active
-- list, is anything left that an exact-match existp(pid_orb) would find?
local gate_window_frames, gate_blocked_frames = 0, 0

local function finish(msg, ok)
    if done_frame > 0 then return end
    done_frame = frame
    verdict = ok
    print("[fb] " .. msg)
    print("[fb] " .. (ok and "PASS" or "FAIL"))
    print("[fb] finished")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print("[fb] reptile_forceball_test - mode=" .. MODE)
        print("[fb] log=" .. LOG_PATH)
        if #missing > 0 then print("[fb] MISSING SYMBOLS: " .. table.concat(missing, ",")) end
    end
    if done_frame > 0 then
        if frame > done_frame + 60 then manager.machine:exit() end
        return
    end
    if frame > 6000 then finish("timed out", false) return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame print("[fb] charsel frame="..frame) end
        force_ladder()
        if p1_confirm_start == 0 then p1_confirm_start = frame + 20 end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        arm_frame = frame + 90
        print(string.format("[fb] fight_start frame=%d p1char=%d p2char=%d",
            frame, r16(A.p1_char), r16(A.p2_char)))
    end

    for name, f in pairs(fields) do
        f:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame == 0 then return end

    -- Nobody is allowed to die: this is about the ball, not the fight, and a
    -- round ending mid-flight deletes every projectile.
    -- Pinning the bars stops a KO but NOT a TIME OVER, and a round that
    -- ends tears the stage down mid-run.
    w16(A.f_freeze_timer, 1)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p2o ~= 0 then w16(A.p2_bar, 0x0a1) end
    if p1o ~= 0 then w16(A.p1_bar, 0x0a1) end

    -- Hold them GAP apart, P1 on the left.  Two reasons, both learned the
    -- hard way: a forceball explodes on x-proximity, so from point blank it
    -- detonates on its first tick and never throbs at all; and if the drone
    -- walks past P1 the sides swap, "Back,Back" becomes "Forward,Forward"
    -- and the rig silently throws the FAST ball in the slow run (seen as
    -- vx=-6.00 on a run asking for 3.00).  oxpos is the HIGH WORD of oxval
    -- and gets overwritten from it before the draw, so write both.
    if p1o ~= 0 and p2o ~= 0 and frame > fighting_frame + 30 then
        if pin_x == nil then
            pin_x = s16(r16(p2o + O.oxpos))
            print(string.format("[fb] pin p2_x=%d gap=%d", pin_x, GAP_PX))
        end
        w32(p2o + O.oxval, pin_x << 16)
        w16(p2o + O.oxpos, pin_x)
        local target = pin_x - GAP_PX
        w32(p1o + O.oxval, target << 16)
        w16(p1o + O.oxpos, target)
    end

    -- Heartbeat: without it a run with no throws says nothing about WHY.
    if frame % 60 == 0 then
        local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
        print(string.format("[hb] f=%d gs=%d p1x=%d p2x=%d p1act=%04x p2act=%04x ph=%s",
            frame, r16(A.gstate),
            p1o ~= 0 and s16(r16(p1o + O.oxpos)) or -1,
            p2o ~= 0 and s16(r16(p2o + O.oxpos)) or -1,
            p1p ~= 0 and r16(p1p + P.action) or 0xffff,
            p2p ~= 0 and r16(p2p + P.action) or 0xffff,
            throw_phase()))
    end

    -- How many orb-family processes are alive right now, and how many of
    -- them still carry a gate-blocking pid.  An overlap of 2 is the whole
    -- point of the chase run.
    do
        local p, n, live, blocking = r32(A.active), 0, 0, 0
        while p ~= 0 and n < 400 do
            local pid = r16(p + P.procid)
            if PID_ORB[pid] then live = live + 1 blocking = blocking + 1
            elseif PID_ORBX[pid] then live = live + 1 end
            p = r32(p + P.link) n = n + 1
        end
        if live > max_live then
            max_live = live
            print(string.format("[fb] live orb procs = %d (gate-blocking = %d) frame=%d",
                live, blocking, frame))
        end
        if live >= 2 and blocking >= 1 and overlap_frame == 0 then
            overlap_frame = frame
            print(string.format("[fb] OVERLAP frame=%d - a fresh forceball is out while a spent one is still exploding", frame))
        end
        -- A ball exists and it is spent: this is the window retail spends
        -- locked out.  blocking must be 0 through all of it.
        if cur and cur.spent_frame > 0 and live >= 1 then
            gate_window_frames = gate_window_frames + 1
            if blocking >= 1 and overlap_frame == 0 then
                gate_blocked_frames = gate_blocked_frames + 1
            end
        end
    end

    local proc, obj, id = find_orb()
    if proc then
        if cur == nil or cur.proc ~= proc then
            if cur then finished[#finished+1] = cur end
            throw_no = throw_no + 1
            cur = { proc=proc, id=id, first=frame, steps={}, rows={},
                    spent_frame=0, no=throw_no }
            if last_spent_frame > 0 and rethrow_gap == nil then
                rethrow_gap = frame - last_spent_frame
            end
            print(string.format("[fb] THROW #%d frame=%d proc=%08x id=%04x vx=%.2f",
                throw_no, frame, proc, id, s32(r32(obj + O.oxvel))/65536.0))
            -- Start entering the NEXT combo early enough that its punch lands
            -- on the frame this ball goes spent.
            if CHASE and spent_dt then
                arm_frame = frame + spent_dt - #DIRS*(TAP+GAP)
            end
        end
        local sc = r32(obj + O.oscale)
        local xs, ys = sc & 0xffff, (sc >> 16) & 0xffff
        local dx, dy, sx, sy = mp_first(obj)
        local last = cur.steps[#cur.steps]
        if last == nil or last.xs ~= xs or last.ys ~= ys then
            cur.steps[#cur.steps+1] = { f=frame, xs=xs, ys=ys, dx=dx, dy=dy }
        end
        cur.rows[#cur.rows+1] = string.format(
            "f=%d id=%04x x=%d xs=%03x ys=%03x dx=%s dy=%s w=%s h=%s",
            frame, r16(proc+P.procid), s16(r16(obj+O.oxpos)), xs, ys,
            tostring(dx), tostring(dy), tostring(sx), tostring(sy))
        if PID_ORBX[r16(proc+P.procid)] and cur.spent_frame == 0 then
            cur.spent_frame = frame
            last_spent_frame = frame
            print(string.format("[fb] SPENT #%d frame=%d procid=%04x (gate released)",
                cur.no, frame, r16(proc+P.procid)))
            if CHASE then
                if spent_dt == nil then spent_dt = frame - cur.first end
                arm_frame = frame + 1
            end
        end
        if cur.no == 1 and dx then
            if ys >= 0x148 and not cur.snap_flat then cur.snap_flat = true snap() end
            if ys <= 0x0c8 and not cur.snap_tall then cur.snap_tall = true snap() end
        end
    elseif cur then
        cur.last = frame
        finished[#finished+1] = cur
        print(string.format("[fb] GONE  #%d frame=%d lived=%d frames",
            cur.no, frame, frame - cur.first))
        cur = nil
    end

    if throw_no >= 3 and cur == nil then
        local ok = true
        local why = {}
        for _, t in ipairs(finished) do
            local seen = {}
            local flat, tall = false, false
            for _, s in ipairs(t.steps) do
                seen[string.format("%03x:%03x", s.ys, s.xs)] = true
                if s.ys > s.xs then flat = true end
                if s.xs > s.ys then tall = true end
            end
            local n = 0 for _ in pairs(seen) do n = n + 1 end
            print(string.format("[fb] throw #%d  poses=%d  flat=%s tall=%s  spent@%d  lived=%d",
                t.no, n, tostring(flat), tostring(tall), t.spent_frame,
                (t.last or frame) - t.first))
            for _, s in ipairs(t.steps) do
                print(string.format("[fb]    step f=%d  ystep=%03x xstep=%03x  dx=%s dy=%s",
                    s.f, s.ys, s.xs, tostring(s.dx), tostring(s.dy)))
            end
            if not (flat and tall) then ok = false why[#why+1] = "throw "..t.no.." never both squashed and stretched" end
            if n < 5 then ok = false why[#why+1] = "throw "..t.no.." only "..n.." distinct poses" end
        end
        local t1 = finished[1]
        if t1 and #t1.steps >= 3 then
            local gaps, sum = 0, 0
            for i = 2, #t1.steps do
                local d = t1.steps[i].f - t1.steps[i-1].f
                if d > 0 and d < 10 then gaps = gaps + 1 sum = sum + d end
            end
            if gaps > 0 then
                print(string.format("[fb] mean pose dwell = %.2f frames (%s ball)",
                    sum/gaps, MODE))
            end
        end
        if rethrow_gap then
            print(string.format("[fb] rethrow gap after a spent ball = %d frames", rethrow_gap))
        end
        print(string.format("[fb] most orb procs alive at once = %d  overlap_frame=%d",
            max_live, overlap_frame))
        print(string.format("[fb] spent-but-still-alive frames = %d, of which gate-blocking = %d",
            gate_window_frames, gate_blocked_frames))
        if gate_window_frames == 0 then
            ok = false why[#why+1] = "never observed a spent ball still on the list"
        elseif gate_blocked_frames > 0 then
            ok = false why[#why+1] = "a spent ball was still blocking a new throw for "..gate_blocked_frames.." frames"
        end
        if CHASE and overlap_frame == 0 then
            ok = false
            why[#why+1] = "chase run never got a second forceball out while the first was still exploding"
        end
        for _, w in ipairs(why) do print("[fb] why: " .. w) end
        if t1 then
            for _, r in ipairs(t1.rows) do print("[trace] " .. r) end
        end
        finish(string.format("%d forceballs observed", throw_no), ok)
    end
end)
