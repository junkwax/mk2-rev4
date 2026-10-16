-- jade_boom_arcs_test.lua
--
-- Runtime proof that Jade's four boomerang variants really are four
-- different flights, and that the numbers extracted from the UMK3 arcade ROM
-- (tools/umk3_jade_extract.py) are the numbers the blade actually flies with.
--
-- Throws all four in one fight and measures the LIVE projectile object:
--
--   B,F + LP        straight   dy over the flight stays ~0
--   B,F + HP        upward     dy goes strongly negative (screen y up)
--   B,F + LK        downward   dy goes positive
--   B,B,F + LP      returning  x reverses direction and the blade comes back
--
-- and on every throw:
--   x speed    ~9 px/tick   (UMK3 set_proj_vel 0090000h)
--   frame hold  2 ticks     (UMK3 set_proj_vel anirate 2)
--   loop        7 distinct BRANG frames (UMK3's REL4 + SPIN1..6)
--
-- The opponent is shoved out of reach for the measurement window on purpose.
-- The arc is applied by jbp_arc in the flight loop, and jbp_hit peels off
-- into jbp_fly_through which does NOT apply it - so a blade that connects
-- early stops arcing and the shape being measured here would be gone.
--
-- Jade selection trick (as jade_boomerang_test.lua): the select screen will
-- not take char 16, so pick Kitana during GS_PSEL and overwrite p1_char to
-- FT_JADE during GS_POST.
--
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_ARCS_LOG") or (ROOT .. "/tools/jade_boom_arcs_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[boom-arc] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n, d) return symbols[n] or d end

local A = {
    gstate  = sym("gstate", 0x0112a830),
    p1_obj  = sym("p1_obj", 0x0112a880),
    p1_proc = sym("p1_proc", 0x0112a8c0),
    p1_char = sym("p1_char", 0x0112a8e0),
    p2_obj  = sym("p2_obj", 0x0112b450),
    p2_char = sym("p2_char", 0x0112b4b0),
    diff    = sym("diff"),
    objlst  = sym("objlst"),
    worldtlx = sym("worldtlx"),
}
-- object block (bit offsets, DISPEQU.ASM)
local O = { link=0x000, xvel=0x040, yvel=0x060, xval=0x080, xpos=0x090,
            yval=0x0a0, ypos=0x0b0, zval=0x0c0, flags=0x0f0, sag=0x100,
            pal=0x140, flags2=0x160, img=0x1a0 }
local MP = { sag=0, yxsize=32, control=64, anix=80, aniy=96 }

local P_ACTION = 0x1f0
-- pdata=100h, p_store7=pdata+1f0h.  jade_zap3 stashes the variant's arc
-- constant here on the THROWER's process before spawning the blade, so it is
-- the one place that says which of the four actually fired - the action code
-- (act_jade_boom) is the same for all of them, and so is dy for med and ret.
local P_STORE7 = 0x2f0
local ARC_NAME = { [0]="med (straight)", [1]="ret (returning)",
                   [0x5000]="lo (downward)", [0xffff4000]="hi (upward)" }
local ARC_WANT = { med=0, hi=0xffff4000, lo=0x5000, ret=1 }
local ACT_JADE_BOOM = 0x112
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_REPTILE, FT_JADE = 4, 9, 16

-- The blade's SAG window is READ OUT OF src/JADERANG.TBL, never written down
-- here: every SAG in the sidecar shifts whenever data/JADERANG.LOD's pack
-- changes, and a stale window then matches NOTHING - so find_blade returns nil
-- and a perfectly good ROM is reported as "the blade never appeared".  That is
-- what the hardcoded 03c10000..03c32000 had been doing since the pack moved to
-- 03bd5f10.  Only the UB* records count: Jade's own throw poses (JDTHROWBLADE*)
-- live in the same sidecar and are pieces of her multipart object, which is in
-- objlst too.
local SAG_LO, SAG_HI
do
    local lo, hi, label
    local fh = io.open(ROOT .. "/src/JADERANG.TBL", "r")
    if fh then
        for line in fh:lines() do
            local l = line:match("^(UB[%w_]*):")
            if l then label = l end
            local sag = line:match("^%s*%.long%s+(%x+)[Hh]")
            if label and sag then
                local v = tonumber(sag, 16)
                if not lo or v < lo then lo = v end
                if not hi or v > hi then hi = v end
                label = nil
            end
        end
        fh:close()
    end
    assert(lo, "could not read blade SAGs from src/JADERANG.TBL")
    SAG_LO, SAG_HI = lo - 0x1000, hi + 0x10000
end
-- ...and the frame NAMES from the same read, for the log line.  The table
-- that used to be here was the same stale pack.
local BRANG_SAGS = {}
do
    local label
    local fh = io.open(ROOT .. "/src/JADERANG.TBL", "r")
    if fh then
        for line in fh:lines() do
            local l = line:match("^(UB[%w_]*):")
            if l then label = l end
            local sag = line:match("^%s*%.long%s+(%x+)[Hh]")
            if label and sag then BRANG_SAGS[tonumber(sag, 16)] = label; label = nil end
        end
        fh:close()
    end
end

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local errors, notes = {}, {}

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end
local function s16(v) return (v >= 0x8000) and (v - 0x10000) or v end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local function fail(msg) errors[#errors+1] = msg; log("FAIL %s", msg) end

local function finish()
    if finished then return end
    finished = true
    for _, n in ipairs(notes) do log("note %s", n) end
    if #errors == 0 then log("PASS reason=all_four_arcs_confirmed")
    else log("ERROR reason=%s (%d failures)", errors[1], #errors) end
    logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 Right"]=true, ["P1 Left"]=true, ["P1 High Punch"]=true,
        ["P1 Low Punch"]=true, ["P1 Low Kick"]=true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
end

-- Throw schedule ------------------------------------------------------------
-- `window` is how many ticks after the throw is seen we keep measuring.
local THROWS = {
    { label="med", arc="straight",
      seq={ {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Punch",12,18} },
      window=40 },
    { label="hi", arc="upward",
      seq={ {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Punch",12,18} },
      window=40 },
    { label="lo", arc="downward",
      seq={ {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Kick",12,18} },
      window=40 },
    -- Back,Back,Forward: two DISTINCT back taps with a real release between
    -- them, so the queue records two separate left transitions rather than
    -- one long hold.  Spans 22 ticks, inside scom_jade_boom_ret's 024h.
    { label="ret", arc="returning",
      seq={ {"P1 Left",0,4}, {"P1 Left",8,12}, {"P1 Right",16,20},
            {"P1 Low Punch",22,28} },
      window=150 },
}
local THROW_AT = { 90, 300, 510, 720 }
local THROW_END = 1000
local cur = 0                 -- index into THROWS while a throw is being measured
local pending = 1             -- next throw to arm
local samples = {}            -- per throw: list of {rel,x,y,sag}
local armed_rel = nil

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end
    local rel = frame - fighting_frame
    for i, t in ipairs(THROWS) do
        local d = rel - THROW_AT[i]
        for _, s in ipairs(t.seq) do
            if name == s[1] and d >= s[2] and d < s[3] then return true end
        end
    end
    return false
end

-- Find the live blade in objlst: multipart, with a JADERANG sag.
local function find_blade()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p, n = r32(A.objlst), 0
    while p ~= 0 and n < 40 do
        if p ~= p1o and p ~= p2o then
            local f2 = r16(p + O.flags2)
            local img = r32(p + O.img)
            if (f2 & 2) ~= 0 and img ~= 0 then
                local sag = r32(img + MP.sag)
                if sag >= SAG_LO and sag < SAG_HI then return p, sag end
            end
        end
        p = r32(p + O.link); n = n + 1
    end
    return nil
end

local function median(t)
    if #t == 0 then return 0 end
    local c = {}
    for _, v in ipairs(t) do c[#c+1] = v end
    table.sort(c)
    return c[(#c // 2) + 1]
end

-- Assess one finished throw -------------------------------------------------
local function assess(i)
    local t, raw = THROWS[i], samples[i]
    if not raw or #raw < 12 then
        fail(string.format("%s: blade only tracked for %d tick(s)", t.label, raw and #raw or 0))
        return
    end
    -- The tracked run opens with the 14-tick RELEASE, where the blade is still
    -- riding Jade's hand on BRANG1-3's authored anipoints; jade_boomerang_proc
    -- then slides the anchor onto the art with one adjust_xy_a5 of +94,+31.
    -- That single-tick jump looks nothing like flight (94px against 9px), so
    -- it is what separates the two phases.  Measure the FLIGHT only - the +31
    -- of the handoff otherwise reads as a downward drift on every variant,
    -- including the straight one.
    -- Flight starts on the first tick the blade actually travels at flight
    -- speed.  This used to look for a big single-tick jump, because the old
    -- art's release handoff moved the anchor 94px; the arcade frames anchor
    -- consistently so that handoff is now 2px and there is no jump to find.
    local first = 1
    for k = 2, #raw do
        if math.abs(raw[k].x - raw[k-1].x) >= 8 then first = k break end
    end
    local jump, at = 0, first
    local s = {}
    for k = first, #raw do s[#s+1] = raw[k] end
    log("%s: flight starts at sample %d; measuring %d flight ticks",
        t.label, first, #s)
    if #s < 8 then
        fail(string.format("%s: only %d flight tick(s) after the release", t.label, #s))
        return
    end
    local dy = s[#s].y - s[1].y
    local dxs, holds, frames = {}, {}, {}
    local run, lastsag = 0, nil
    local minx, maxx = s[1].x, s[1].x
    local reversed = false
    local peak = s[1].x
    for k = 1, #s do
        local v = s[k]
        if k > 1 then
            local dx = v.x - s[k-1].x
            if dx ~= 0 then dxs[#dxs+1] = math.abs(dx) end
            -- a real direction change, not jitter
            if v.x > peak then peak = v.x
            elseif peak - v.x > 20 then reversed = true end
        end
        if v.x < minx then minx = v.x end
        if v.x > maxx then maxx = v.x end
        frames[BRANG_SAGS[v.sag] or string.format("%08x", v.sag)] = true
        if v.sag == lastsag then run = run + 1
        else
            if run > 0 then holds[#holds+1] = run end
            run = 1; lastsag = v.sag
        end
    end
    if run > 0 then holds[#holds+1] = run end
    local nframes = 0
    for _ in pairs(frames) do nframes = nframes + 1 end
    local spd, hold = median(dxs), median(holds)
    log("%s: ticks=%d  dy=%+d  |dx|/tick=%d  frame hold=%d ticks  distinct frames=%d",
        t.label, #s, dy, spd, hold, nframes)

    -- speed and animation rate are the same for every variant
    if spd < 8 or spd > 10 then
        fail(string.format("%s: x speed %d px/tick, want 9 (UMK3 0090000h)", t.label, spd))
    end
    if hold ~= 2 then
        fail(string.format("%s: frame hold %d ticks, want 2 (UMK3 anirate 2)", t.label, hold))
    end

    if t.label == "med" then
        if math.abs(dy) > 8 then
            fail(string.format("med: dy=%+d, a straight throw should stay level", dy))
        else
            notes[#notes+1] = string.format("straight throw stayed level (dy=%+d)", dy)
        end
    elseif t.label == "hi" then
        if dy > -30 then
            fail(string.format("hi: dy=%+d, an upward throw should climb (want <= -30)", dy))
        else
            notes[#notes+1] = string.format("upward throw climbed %d px", -dy)
        end
    elseif t.label == "lo" then
        if dy < 20 then
            fail(string.format("lo: dy=%+d, a downward throw should dip (want >= +20)", dy))
        else
            notes[#notes+1] = string.format("downward throw dipped %d px", dy)
        end
    elseif t.label == "ret" then
        if not reversed and not raw.flipped then
            fail(string.format("ret: blade never turned around (x %d..%d, %d flight ticks)",
                               minx, maxx, #s))
        elseif raw.flipped and not reversed then
            fail(string.format("ret: oxvel flipped at tick %d but the blade never travelled back"
                               .. " (x %d..%d) - deleted before it could return?",
                               raw.flipped, minx, maxx))
        else
            notes[#notes+1] = string.format("returning throw reversed at tick %s and came back %d px",
                                            tostring(raw.flipped), peak - s[#s].x)
        end
    end
    if nframes < 6 then
        fail(string.format("%s: only %d distinct blade frames in flight, want the 7-frame loop",
                           t.label, nframes))
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        local missing = {}
        for _, n in ipairs({"P1 Low Punch", "P1 Low Kick", "P1 High Punch"}) do
            if not fields[n] then missing[#missing+1] = n end
        end
        log("harness loaded  objlst=%s%s",
            A.objlst and string.format("%08x", A.objlst) or "MISSING",
            #missing > 0 and ("  MISSING INPUTS: " .. table.concat(missing, ",")) or "")
        if #missing > 0 then fail("input fields missing: " .. table.concat(missing, ",")) end
    end
    if not space or finished then
        for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_REPTILE)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_JADE); w16(A.p2_char, FT_REPTILE)
    elseif gs == GS_FIGHTING then
        if fighting_frame == 0 then
            fighting_frame = frame
            if A.diff then w16(A.diff, 0) end
            log("fight started (p1=%d p2=%d)", r16(A.p1_char), r16(A.p2_char))
        end
        local rel = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end

        -- Keep the opponent out of the blade's way for the whole run.  A hit
        -- sends the flight down jbp_fly_through, which applies no arc and
        -- never runs the return check - so a blade that connects stops being
        -- the thing this test is trying to measure.
        --
        -- Parked ABOVE the lane rather than far downrange: shoving him 300px
        -- away dragged the camera with him, which widened the world window
        -- enough that the returning throw could not reach an edge to turn
        -- around at, and he was still close enough to be hit at tick ~26.
        -- 200px across and 170px up keeps the camera where a real fight would
        -- have it and takes him out of the blade's path completely.
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o ~= 0 and p2o ~= 0 then
            local p1x = s16(r16(p1o + O.xpos))
            local p1y = s16(r16(p1o + O.ypos))
            w32(p2o + O.xval, ((p1x + 200) << 16) & 0xffffffff)
            w32(p2o + O.yval, ((p1y - 220) << 16) & 0xffffffff)
            -- Zero his velocities too, or gravity walks him straight back
            -- down into the blade's lane between our writes.
            w32(p2o + O.xvel, 0)
            w32(p2o + O.yvel, 0)
        end

        local proc = r32(A.p1_proc)
        local act = proc ~= 0 and r16(proc + P_ACTION) or 0

        if cur == 0 and pending <= #THROWS and act == ACT_JADE_BOOM
           and rel >= THROW_AT[pending] then
            cur = pending
            armed_rel = rel
            samples[cur] = {}
            local arc = r32(proc + P_STORE7)
            log("throw %d (%s / %s) confirmed at rel=%d  arc=%08x = %s",
                cur, THROWS[cur].label, THROWS[cur].arc, rel, arc,
                ARC_NAME[arc] or "UNKNOWN")
            local want = ARC_WANT[THROWS[cur].label]
            if arc ~= want then
                fail(string.format("%s: input fired the WRONG variant - arc=%08x (%s), want %08x",
                                   THROWS[cur].label, arc, ARC_NAME[arc] or "?", want))
            end
        end

        if cur > 0 then
            local blade, sag = find_blade()
            if blade then
                local s = samples[cur]
                local xv = r32(blade + O.xvel)
                -- jbp_hit stamps front_z into the blade's ozpos on contact,
                -- so the top half of ozval going non-zero is the hit - and a
                -- hit means the flight left jbp_loop for jbp_fly_through,
                -- where no arc and no return check run any more.
                if (r32(blade + O.zval) >> 16) ~= 0 and not samples[cur].hit then
                    samples[cur].hit = rel - armed_rel
                    local p2 = r32(A.p2_obj)
                    log("%s: CONTACT at tick %d - blade (%d,%d) vs P2 (%d,%d)"
                        .. " - arc/return stop here",
                        THROWS[cur].label, samples[cur].hit,
                        s16(r16(blade + O.xpos)), s16(r16(blade + O.ypos)),
                        p2 ~= 0 and s16(r16(p2 + O.xpos)) or -1,
                        p2 ~= 0 and s16(r16(p2 + O.ypos)) or -1)
                end
                s[#s+1] = { rel = rel,
                            x = s16(r16(blade + O.xpos)),
                            y = s16(r16(blade + O.ypos)),
                            xvel = xv,
                            sag = sag }
                -- 12 is still the release; 30 is well into clean flight,
                -- which is where the trail is actually readable.
                if #s == 12 or #s == 30 then snap(THROWS[cur].label) end
                -- oxvel flipping sign is the reversal itself, independent of
                -- whether the blade has had time to travel back yet.
                if THROWS[cur].label == "ret" then
                    local neg = (xv & 0x80000000) ~= 0
                    if samples[cur].sign == nil then samples[cur].sign = neg
                    elseif samples[cur].sign ~= neg and not samples[cur].flipped then
                        samples[cur].flipped = rel - armed_rel
                        log("ret: oxvel flipped sign at flight tick %d (xvel=%08x)",
                            samples[cur].flipped, xv)
                    end
                end
            end
            if blade == nil and #samples[cur] > 0 and not samples[cur].gone then
                samples[cur].gone = rel - armed_rel
                local wl = A.worldtlx and s16(r16(A.worldtlx + 16)) or -1
                local last = samples[cur][#samples[cur]]
                log("%s: blade gone at flight tick %d (last x=%d, world left=%d,"
                    .. " right=%d, hit=%s)",
                    THROWS[cur].label, samples[cur].gone, last.x, wl, wl + 400,
                    tostring(samples[cur].hit))
            end
            if rel - armed_rel >= THROWS[cur].window then
                assess(cur)
                pending = cur + 1
                cur = 0
            end
        end

        if rel > THROW_END then
            for i = 1, #THROWS do
                if samples[i] == nil then
                    fail(string.format("%s throw never fired", THROWS[i].label))
                end
            end
            finish()
        end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
end)
