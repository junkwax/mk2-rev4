-- jade_boom_contact_return_test.lua
--
-- Runtime proof for the returning boomerang's CONTACT behaviour
-- (MKZAP.ASM jbp_hit / jbp_turn_for_home).
--
-- Back,Back,Forward + LP is Jade's returning throw.  It used to come back
-- only when it MISSED - a hit peeled off into jbp_fly_through and the blade
-- carried on across the screen.  It now turns around off contact as well,
-- blocked or clean, while the hi/med/lo throws still fly through a hit.
--
-- Three throws, all aimed AT a standing P2 (the arcs rig parks him out of
-- the lane on purpose; this one wants the collision):
--
--   1  ret,  P2 standing   -> clean hit (-20).  The blade must pass THROUGH
--                               him and keep its heading, then turn at the
--                               screen edge - the same place a miss turns -
--                               and come home.  A turn at the victim fails.
--                               It must then hit him a SECOND time on the way
--                               home, and that hit has to drag him TOWARD
--                               Jade where the first one shoved him away.
--   2  ret,  P2 blocking   -> block (-3).  The arcade bounce reverses it on
--                               the spot, so this one DOES turn at contact.
--   3  med,  P2 standing   -> clean hit (-20) and the blade must never turn.
--
-- A reversal has to move the ART as well as the velocity, or the blade
-- moonwalks home: b_fliph (oflags bit 4) must toggle with oxvel, and must NOT
-- toggle on the throw that flies through.  jbp_reverse_x is the single place
-- all three turns go through, so this is checked on every one of them.
--
-- Throw 3 is the control: without it "the blade came back" proves nothing,
-- because the blocked bounce reverses every variant and a rig that only
-- looked at blocks would pass on stock code too.
--
-- Reversal is read two ways and both must agree: oxvel changing sign, and
-- the blade actually travelling back toward Jade afterwards.  oxvel alone
-- would pass on a blade that flipped and was deleted in the same tick (the
-- exact hazard jbp_return_arm's comment describes).
--
-- P2 has to be HUMAN to hold Block on cue, so this is a 2-player start.
-- Jade is not selectable, so P1 hovers Kitana through GS_PSEL and p1_char is
-- overwritten with FT_JADE during GS_POST - same trick as
-- jade_boom_arcs_test.lua.
--
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_RET_LOG") or (ROOT .. "/tools/jade_boom_contact_return_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[boom-ret] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                if symbols[name] == nil then symbols[name] = tonumber(addr, 16) end
            end
        end
        fh:close()
    end
end
local function sym(n, d)
    local v = symbols[n]
    if v == nil then log("WARN symbol %s not in mk2.map", n) end
    return v or d
end

local A = {
    gstate  = sym("gstate"),
    p1_obj  = sym("p1_obj"),
    p1_proc = sym("p1_proc"),
    p1_char = sym("p1_char"),
    p2_obj  = sym("p2_obj"),
    p2_char = sym("p2_char"),
    p2_bar  = sym("p2_bar"),
    objlst  = sym("objlst"),
    worldtlx = sym("worldtlx"),
}

-- object block (bit offsets, DISPEQU.ASM)
local O = { link=0x000, xvel=0x040, yvel=0x060, xval=0x080, xpos=0x090,
            yval=0x0a0, ypos=0x0b0, zval=0x0c0, flags=0x0f0,
            flags2=0x160, img=0x1a0 }
local M_FLIPH = 0x10             -- DISPEQU.ASM m_fliph, oflags bit 4
local MP_SAG = 0

local P_ACTION  = 0x1f0          -- pdata+0f0h
local P_STORE7  = 0x2f0          -- pdata+1f0h - jade_zap3's arc stash (thrower)
local ACT_JADE_BOOM = 0x112
local ARC_WANT  = { ret = 1, med = 0 }
local ARC_NAME  = { [0]="med (straight)", [1]="ret (returning)",
                    [0x5000]="lo (downward)", [0xffff4000]="hi (upward)" }

local GS_PSEL, GS_FIGHTING, GS_POST = 4, 2, 0x0d
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

-- JADE_RET_TRACE=1 dumps the blade's pointer/position/velocity for the 24
-- ticks after each collision.  That trace is what settled the first run's
-- apparent failure (see the note at the contact test below), so it stays.
local TRACE = (os.getenv("JADE_RET_TRACE") or "") ~= ""

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local last_gs, last_pc, same_pc = -1, nil, 0
local errors, notes = {}, {}

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) v = v & 0xffff; return (v >= 0x8000) and (v - 0x10000) or v end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local function fail(msg) errors[#errors+1] = msg; log("FAIL %s", msg) end

local function finish()
    if finished then return end
    finished = true
    for _, n in ipairs(notes) do log("note %s", n) end
    if #errors == 0 then log("PASS reason=returning_throw_comes_back_off_contact")
    else log("ERROR reason=%s (%d failures)", errors[1], #errors) end
    logfh:close()
    manager.machine:exit()
end

-- Throw schedule ------------------------------------------------------------
-- Same input timings as jade_boom_arcs_test.lua: two DISTINCT back taps for
-- the returning throw, inside scom_jade_boom_ret's 024h window.
-- `turn` is where the reversal is expected: "edge" = out at the screen edge,
-- well after contact; "contact" = the blocked bounce, on the contact tick
-- itself; "never" = it must not happen at all.
local THROWS = {
    { label="ret_hit", variant="ret", block=false, turn="edge", hits=2,
      seq={ {"P1 Left",0,4}, {"P1 Left",8,12}, {"P1 Right",16,20},
            {"P1 Low Punch",22,28} }, window=200 },
    { label="ret_block", variant="ret", block=true, turn="contact",
      seq={ {"P1 Left",0,4}, {"P1 Left",8,12}, {"P1 Right",16,20},
            {"P1 Low Punch",22,28} }, window=140 },
    { label="med_hit", variant="med", block=false, turn="never",
      seq={ {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Punch",12,18} },
      window=110 },
}
local THROW_AT  = { 90, 420, 700 }
local THROW_END = 1000
local cur, pending, armed_rel = 0, 1, nil
local samples = {}

local function want_block(rel)
    -- P2 guards across the whole of the blocked throw's flight, nowhere else.
    for i, t in ipairs(THROWS) do
        if t.block then
            local d = rel - THROW_AT[i]
            if d >= -10 and d <= t.window then return true end
        end
    end
    return false
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 200 and frame < 3000 and (frame % 80) < 20 end
    if name == "Coin 2" then return frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40 end
    if name == "2 Players Start" then return frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70 end
    if fighting_frame == 0 then
        -- both players confirm their (forced) hover once the screen settles
        if (name == "P1 Low Punch" or name == "P2 Low Punch") and confirm_frame > 0 then
            return frame >= confirm_frame and frame < confirm_frame + 120 and (frame % 20) < 8
        end
        return false
    end
    local rel = frame - fighting_frame
    if name == "P2 Block" or name == "P2 Block 2" then return want_block(rel) end
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
    -- Scan the WHOLE list, not the first 40: the trail keeps spawning through
    -- the fly-out and each puff goes in at the head, so a short cap can walk
    -- past the blade and report it deleted while it is still flying.
    local p, n = r32(A.objlst), 0
    while p ~= 0 and n < 200 do
        if p ~= p1o and p ~= p2o then
            local f2 = r16(p + O.flags2)
            local img = r32(p + O.img)
            if (f2 & 2) ~= 0 and img ~= 0 then
                local sag = r32(img + MP_SAG)
                if sag >= SAG_LO and sag < SAG_HI then return p, sag end
            end
        end
        p = r32(p + O.link); n = n + 1
    end
    return nil
end

-- Assess one finished throw -------------------------------------------------
local function assess(i)
    local t, s = THROWS[i], samples[i]
    if not s or (s.n or 0) < 10 then
        fail(string.format("%s: blade only tracked for %d tick(s)", t.label, s and (s.n or 0) or 0))
        return
    end
    if not s.hit then
        fail(string.format("%s: the blade never touched P2 - nothing to prove"
                           .. " (x %d..%d, %d ticks)", t.label, s.minx, s.maxx, s.n))
        return
    end

    local dmg = (s.hits[1] and s.hits[1].dmg) or (s.bar_before - s.bar_after)
    local kind = (dmg >= 15) and "clean hit" or ((dmg > 0) and "blocked" or "no damage")
    log("%s: contact at tick %d, p2_bar %d->%d (-%d = %s), oxvel %08x -> %08x",
        t.label, s.hit, s.bar_before, s.bar_after, dmg, kind,
        s.xvel_before or 0, s.xvel_last or 0)

    -- How many times it connected, and which way each one threw him.
    local want_hits = t.hits or 1
    if #s.hits ~= want_hits then
        fail(string.format("%s: connected %d time(s), wanted %d"
                           .. " - the return leg has to be live too",
                           t.label, #s.hits, want_hits))
    else
        for i, h in ipairs(s.hits) do
            local d = h.p2x_after - h.p2x
            local carried = d * h.away          -- >0 away from Jade, <0 toward
            local wanted = (i == 1) and "away from" or "toward"
            local got = (carried > 0) and "away from" or "toward"
            log("%s: hit #%d threw P2 %d px %s Jade", t.label, i,
                math.abs(d), got)
            if h.dmg < 15 then
                -- A GUARDED hit does not move him, and must not: b_standard
                -- holds him in the block. There is no direction to check.
                notes[#notes+1] = string.format("%s: hit #%d was blocked (-%d)"
                                                .. " and moved him %d px, as a"
                                                .. " guarded hit should",
                                                t.label, i, h.dmg, math.abs(d))
            elseif math.abs(d) < 8 then
                fail(string.format("%s: hit #%d barely moved him (%d px) -"
                                   .. " cannot tell which way he went",
                                   t.label, i, d))
            elseif got ~= wanted then
                fail(string.format("%s: hit #%d threw him %s Jade, wanted %s"
                                   .. " - the %s leg has the wrong reaction",
                                   t.label, i, got, wanted,
                                   (i == 1) and "outbound" or "homeward"))
            else
                notes[#notes+1] = string.format("%s: hit #%d (tick %d, -%d) carried"
                                                .. " him %d px %s Jade",
                                                t.label, i, h.tick, h.dmg,
                                                math.abs(d), got)
            end
        end
    end

    if t.block then
        if dmg == 0 or dmg >= 15 then
            fail(string.format("%s: wanted a BLOCK (3 chip) but p2_bar dropped %d"
                               .. " - P2 was not guarding", t.label, dmg))
        end
    else
        if dmg < 15 then
            fail(string.format("%s: wanted a CLEAN hit (20) but p2_bar dropped %d"
                               .. " - P2 blocked it", t.label, dmg))
        end
    end

    -- "back" is how far the blade travelled toward Jade after it turned,
    -- measured from the furthest downrange point it reached AFTER contact.
    local back = s.back or 0
    local through = s.past_hit or 0     -- how far past the victim it carried on

    if t.turn == "never" then
        if s.flipped then
            fail(string.format("%s: this throw turned around at tick %d -"
                               .. " only the returning variant may do that",
                               t.label, s.flipped))
        elseif s.mirrored then
            fail(string.format("%s: this throw mirrored at tick %d without"
                               .. " reversing - nothing should flip it",
                               t.label, s.mirrored))
        else
            notes[#notes+1] = string.format("%s: %s and flew on through unmirrored,"
                                            .. " as it should (x %d..%d)",
                                            t.label, kind, s.minx, s.maxx)
        end
        return
    end

    if not s.flipped then
        fail(string.format("%s: the blade never turned around (x %d..%d) -"
                           .. " it flew off and died", t.label, s.minx, s.maxx))
        return
    end
    if not s.mirrored then
        fail(string.format("%s: turned around at tick %d but b_fliph never"
                           .. " toggled - it is flying home backwards",
                           t.label, s.flipped))
        return
    end
    if back < 30 then
        fail(string.format("%s: turned at tick %d but only came back %d px -"
                           .. " deleted before it could return?",
                           t.label, s.flipped, back))
        return
    end

    if t.turn == "contact" then
        -- The blocked bounce is immediate: it happens on the contact tick.
        if s.flipped > s.hit + 2 then
            fail(string.format("%s: the BLOCKED bounce should reverse on the"
                               .. " contact tick, but it waited %d ticks",
                               t.label, s.flipped - s.hit))
            return
        end
        notes[#notes+1] = string.format("%s: %s, bounced back on the contact tick,"
                                        .. " mirrored with it, came back %d px",
                                        t.label, kind, back)
    else
        -- turn == "edge": the hit must NOT be the turn.  The blade has to
        -- carry on past the man it hit and reverse well downrange, which is
        -- the whole point of the change - a hit and a miss fly one path.
        if s.flipped <= s.hit + 2 then
            fail(string.format("%s: the blade turned around ON the victim"
                               .. " (contact tick %d, turn tick %d) - a hit must"
                               .. " carry through to the edge",
                               t.label, s.hit, s.flipped))
            return
        end
        if through < 40 then
            fail(string.format("%s: only carried %d px past the victim before"
                               .. " turning - that is not the edge",
                               t.label, through))
            return
        end
        notes[#notes+1] = string.format("%s: %s, carried %d px PAST him, turned at"
                                        .. " tick %d (%d after contact), mirrored"
                                        .. " with it, came back %d px",
                                        t.label, kind, through, s.flipped,
                                        s.flipped - s.hit, back)
    end
end

-- The body is a NAMED function called through a pcall below.  A MAME frame
-- callback that throws just stops being called - no message, no exit code -
-- and the run then looks exactly like a locked-up ROM: the log goes quiet
-- mid-fight and MAME sits there until -seconds_to_run expires.  Three runs
-- were mis-read that way before this wrapper went in.
-- Sound-call tap (decoder from fly_wins_test.lua).  Observation only: logs
-- every ST_JADE_ZAP ($0564, sound/stlaugh_patch.txt note (37)) so each one
-- lands in the log beside the HIT # line it belongs to - including the
-- homeward hit, which reaches r_jade_boom_back rather than r_jade_boom.
local SND_PORT, snd_hi, snd_tap = 0x01d01030, nil, nil
local function on_sound_write(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    local code = (snd_hi << 8) | (w & 0xff)
    snd_hi = nil
    if code == 0x0564 then log("  SOUND $0564 ST_JADE_ZAP at frame %d", frame) end
    return data
end

local function tick()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local ok, tap = pcall(function()
            return space:install_write_tap(0x01d00000, 0x01d01fff, "boomsnd", on_sound_write)
        end)
        snd_tap = ok and tap or nil
        local wanted = {
            ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
            ["2 Players Start"]=true,
            ["P1 Right"]=true, ["P1 Left"]=true, ["P1 Low Punch"]=true,
            ["P2 Low Punch"]=true, ["P2 Block"]=true, ["P2 Block 2"]=true,
        }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if wanted[f.name] then fields[f.name] = f end end
        end
        local missing = {}
        for _, n in ipairs({"P1 Left","P1 Right","P1 Low Punch","P2 Low Punch",
                            "2 Players Start","Coin 1","Coin 2"}) do
            if not fields[n] then missing[#missing+1] = n end
        end
        if not fields["P2 Block"] and not fields["P2 Block 2"] then
            missing[#missing+1] = "P2 Block"
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

    -- gstate transitions + a lockup watch.  Both exist because a run went
    -- silent mid-fight with no Lua error and no MAME error: the rig only
    -- looks at the world inside `gs == GS_FIGHTING`, so anything that leaves
    -- that state - a real round end, or the CPU pinning on MACROS.HDR's
    -- `ermac` (a bare `jauc $`) - reads as "the rig stopped" rather than as
    -- what actually happened.
    local gs = r16(A.gstate)
    if gs ~= last_gs then
        log("gstate %d -> %d at frame %d%s", last_gs, gs, frame,
            fighting_frame > 0 and string.format(" (fight+%d)", frame - fighting_frame) or "")
        last_gs = gs
    end
    do
        local ok, pc = pcall(function() return cpu.state["PC"].value end)
        if ok then
            if pc == last_pc then
                same_pc = same_pc + 1
                if same_pc == 45 then
                    log("LOCKUP: PC pinned at %08x for 45 frames (gstate=%d%s)",
                        pc, gs,
                        fighting_frame > 0 and string.format(", fight+%d", frame - fighting_frame) or "")
                    fail(string.format("CPU locked at %08x", pc))
                    finish(); return
                end
            else
                last_pc, same_pc = pc, 0
            end
        end
    end
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame; log("select reached frame=%d", frame) end
        w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_REPTILE)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_JADE); w16(A.p2_char, FT_REPTILE)
    elseif gs == GS_FIGHTING then
        if fighting_frame == 0 then
            fighting_frame = frame
            log("fight started (p1=%d p2=%d)", r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= FT_JADE then
                fail(string.format("P1 is char %d, not Jade (%d) - the select cheat"
                                   .. " did not stick", r16(A.p1_char), FT_JADE))
                finish(); return
            end
        end
        local rel = frame - fighting_frame

        local proc = r32(A.p1_proc)
        local act = proc ~= 0 and r16(proc + P_ACTION) or 0

        if cur == 0 and pending <= #THROWS and act == ACT_JADE_BOOM
           and rel >= THROW_AT[pending] then
            cur = pending
            armed_rel = rel
            local arc = r32(proc + P_STORE7)
            samples[cur] = { minx = 0x7fff, maxx = -0x7fff, n = 0,
                             bar_before = r16(A.p2_bar),
                             bar_now = r16(A.p2_bar), hits = {} }
            log("throw %d (%s) confirmed at rel=%d  arc=%08x = %s  p2_bar=%d",
                cur, THROWS[cur].label, rel, arc, ARC_NAME[arc] or "UNKNOWN",
                samples[cur].bar_before)
            local want = ARC_WANT[THROWS[cur].variant]
            if arc ~= want then
                fail(string.format("%s: input fired the WRONG variant - arc=%08x (%s),"
                                   .. " want %08x", THROWS[cur].label, arc,
                                   ARC_NAME[arc] or "?", want))
            end
        end

        if cur > 0 then
            local s = samples[cur]

            -- EVERY LANDED HIT, and which way it threw him.
            --
            -- Read off p2_bar rather than the blade, so it counts hits on
            -- both legs without caring where the blade is.  bar_reducer
            -- writes p2_bar on the hit tick itself (the bar on screen then
            -- slides down to it), so a drop IS the hit.  P2's x is sampled
            -- at that instant and again for the next 15 ticks; the sign of
            -- the difference against the side he is standing on says whether
            -- the stumble carried him away from Jade or toward her.
            local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
            if p1o ~= 0 and p2o ~= 0 then
                local p1x, p2x = s16(r16(p1o + O.xpos)), s16(r16(p2o + O.xpos))
                local bar = r16(A.p2_bar)
                local t = rel - armed_rel
                if bar < s.bar_now then
                    s.hits[#s.hits+1] = { tick = t, dmg = s.bar_now - bar,
                                          p2x = p2x, p2x_after = p2x,
                                          away = (p2x >= p1x) and 1 or -1 }
                    log("%s: HIT #%d at tick %d for %d (P1 x=%d, P2 x=%d)",
                        THROWS[cur].label, #s.hits, t, s.bar_now - bar, p1x, p2x)
                end
                s.bar_now = bar
                local h = s.hits[#s.hits]
                if h and t - h.tick <= 15 then h.p2x_after = p2x end
            end

            local blade = find_blade()
            if blade then
                local x  = s16(r16(blade + O.xpos))
                local xv = r32(blade + O.xvel)
                local neg = (xv & 0x80000000) ~= 0
                local fliph = (r16(blade + O.flags) & M_FLIPH) ~= 0
                if x < s.minx then s.minx = x end
                if x > s.maxx then s.maxx = x end
                s.last_x = x
                s.xvel_last = xv
                s.n = s.n + 1

                -- jbp_hit stamps front_z into ozpos on contact: the top half
                -- of ozval going non-zero IS the collision.
                --
                -- THE OUTBOUND DIRECTION MUST COME FROM THE TICK BEFORE.
                -- jbp_hit stamps the z AND turns the blade around inside the
                -- same game tick, so the oxvel readable on the tick the
                -- collision first shows is ALREADY the reversed one - taking
                -- it as the baseline made a working reversal read as "never
                -- reversed" (the first run of this rig failed all three
                -- throws that way, including the stock blocked bounce).
                if (r32(blade + O.zval) >> 16) ~= 0 and not s.hit then
                    s.hit = rel - armed_rel
                    s.hit_x = x
                    s.peak_after = s.prev_x or x
                    s.xvel_before = s.prev_xv or xv
                    s.sign_before = (s.prev_sign == nil) and neg or s.prev_sign
                    s.fliph_before = (s.prev_fliph == nil) and fliph or s.prev_fliph
                    snap(THROWS[cur].label .. "_contact")
                end

                -- Per-tick trace around contact: the first run of this rig
                -- read a reversal that was not there, and the only way to
                -- tell "the blade flew on" from "I am sampling a different
                -- object" is to watch the POINTER across the collision.
                if TRACE and s.hit and (rel - armed_rel) <= s.hit + 24 then
                    log("  %s t=%d ptr=%08x f2=%04x x=%d y=%d xv=%08x yv=%08x z=%08x",
                        THROWS[cur].label, rel - armed_rel, blade,
                        r16(blade + O.flags2), x, s16(r16(blade + O.ypos)),
                        xv, r32(blade + O.yvel), r32(blade + O.zval))
                end

                if s.hit then
                    -- Furthest DOWNRANGE after contact, in the outbound
                    -- direction, so "came back" is measured from the turn and
                    -- not from the throw.
                    if s.sign_before then          -- was travelling left
                        if x < s.peak_after then s.peak_after = x end
                        s.back = x - s.peak_after
                        s.past_hit = s.hit_x - s.peak_after
                    else                           -- was travelling right
                        if x > s.peak_after then s.peak_after = x end
                        s.back = s.peak_after - x
                        s.past_hit = s.peak_after - s.hit_x
                    end
                    if neg ~= s.sign_before and not s.flipped then
                        s.flipped = rel - armed_rel
                        log("%s: oxvel flipped sign %d tick(s) after contact (xvel=%08x, x=%d)",
                            THROWS[cur].label, s.flipped - s.hit, xv, x)
                    end
                    if fliph ~= s.fliph_before and not s.mirrored then
                        s.mirrored = rel - armed_rel
                        log("%s: b_fliph toggled %d tick(s) after contact (oflags=%04x)",
                            THROWS[cur].label, s.mirrored - s.hit,
                            r16(blade + O.flags))
                    end
                end

                s.prev_x, s.prev_xv, s.prev_sign, s.prev_fliph = x, xv, neg, fliph
            elseif s.n > 0 and not s.gone then
                s.gone = rel - armed_rel
                local wl = A.worldtlx and s16(r16(A.worldtlx + 16)) or -1
                log("%s: blade gone at tick %d (last x=%d, back=%d, world %d..%d)",
                    THROWS[cur].label, s.gone, s.last_x or 0, s.back or 0,
                    wl, wl + 400)
            end

            if rel - armed_rel >= THROWS[cur].window then
                -- Read the bar AFTER the window: a block's 3 points and a
                -- hit's 20 both land through update_bar's slide.
                s.bar_after = r16(A.p2_bar)
                assess(cur)
                pending = cur + 1
                cur = 0
            end
        end

        if rel > THROW_END then
            for i = 1, #THROWS do
                if samples[i] == nil then
                    fail(string.format("%s never fired", THROWS[i].label))
                end
            end
            finish()
        end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
end

emu.register_frame(function()
    if finished then return end
    local ok, err = pcall(tick)
    if not ok then
        log("LUA ERROR at frame %d: %s", frame, tostring(err))
        fail("rig crashed: " .. tostring(err))
        finish()
    end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:close() end) end end)
