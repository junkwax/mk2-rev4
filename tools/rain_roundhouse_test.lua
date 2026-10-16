-- rain_roundhouse_test.lua
--
-- RAIN (ft_rain = 19) in a real fight, and his one special: the SUPER
-- ROUNDHOUSE (rain_roundhouse / rain_super_knee, MOVES.ASM; r_rain_roundh,
-- MKREACT.ASM; rain_rh_scan, MKPROP.ASM).  Since 2026-09-22 his ORDINARY
-- roundhouse IS the super - Back + HK, every time, the way MK Trilogy's
-- stat_do_roundhouse ft_rain branch does it - and the knee link carries a
-- landed knee into the same lane.
--
-- Reached like every hidden-fighter rig: pick his BASE character (Scorpion)
-- at the select screen and overwrite p1_char at GS_POST - forcing the id at
-- GS_PSEL never confirms.  The unlock itself is covered by
-- run_hidden_cheat_test.ps1 -Name rain.
--
-- The SUPER ROUNDHOUSE is a KNEE LINK (rain_knee, MOVES.ASM): the knee
-- (HK, close), then Back + HK in UMK3's combo window (ticks 4-9 after the
-- knee lands; an earlier press is remembered and fires on tick 4) carries
-- it on along RAINSUPROUND.WAX into the super.  Every knee test parks P1
-- 40 px from Jax and taps HK at d=0..3 for the knee (it lands ~d=9);
-- `link` = when the linking press comes (HK at d=link..link+3, Back held
-- link-3..link+8).
--
--   super   link at 8 (before the knee lands): remembered, the knee still
--           strikes on NJKNEE3, then the super: 16 + 11 (14 at dmgscale's
--           3/4 for a string's second hit) = 27, and he wraps
--   knee    no link: the stock knee, 16, no roundhouse
--   nobk    HK at 8 WITHOUT Back: still the stock knee
--   late    link at 22, after the window: still the stock knee
--   hold    link at 14, inside the window: the super, 27
--   cool    link at 8, but the rig stamps l_roundh first: inside
--           rain_rh_cool it must be the stock knee
--
-- The negatives are what prove the link has teeth; a rig that only checked
-- "a roundhouse came out" would pass on a build where every knee was one.
--
--   RAIN_RH_LOG   log file path
--   RAIN_RH_SNAP  1 = snapshot the super's flight (rain_rh_NNN.png)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("RAIN_RH_LOG") or (ROOT .. "/tools/rain_roundhouse_test.log")
local SNAP = os.getenv("RAIN_RH_SNAP") == "1"
-- RAIN_RH_STAGE = a curback id to force (3 = THE TOWER); unset = the game's pick
local STAGE = tonumber(os.getenv("RAIN_RH_STAGE") or "")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[rain-rh] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    -- RAIN_RH_MAP: the map that belongs to -rompath's zip, when that is not the
    -- live tree's (a frozen pair such as C:/tmp/flybrain/romNN)
    local fh = io.open(os.getenv("RAIN_RH_MAP") or (ROOT .. "/src/mk2.map"), "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end
local addr2sym = {}
for n, a in pairs(symbols) do if not addr2sym[a] or #n < #addr2sym[a] then addr2sym[a] = n end end
local PALDUMP = os.getenv("RAIN_RH_PALDUMP") == "1"
-- RAIN_RH_NOSHADOW=1: clear the victim's m_shadow every tick of the bolt
-- window, to tell his SHADOW apart from anything else drawn near him
local NOSHADOW = os.getenv("RAIN_RH_NOSHADOW") == "1"

local A = {
    gstate = sym("gstate"), diff = sym("diff"),
    p1_proc = sym("p1_proc"), p1_char = sym("p1_char"), p1_bar = sym("p1_bar"),
    p2_char = sym("p2_char"), p2_bar = sym("p2_bar"), p2_proc = sym("p2_proc"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), l_roundh = sym("l_roundh"), tick = sym("tick"),
    curback = sym("curback"), dmaq_late = sym("dmaq_late"), dmaq_lost = sym("dmaq_lost"),
    geo_dropped = sym("geo_dropped"),
    worldtly = sym("worldtly"), palram = sym("palram"), skew_constpal = sym("skew_constpal"), ceiling_y = sym("ceiling_y"), climb_limit = sym("climb_limit"),
}
local missing = false
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k); missing = true end end

local P_ACTION = 0x1f0
local OXPOS = 0x90
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_JAX, FT_RAIN, MAX_HP = 10, 11, 19, 0xa1
local ACT_RHOUSE, ACT_KNEE = 0x105, 0x10f

-- at = frames after the fight starts; gap = how far from Jax P1 is parked
-- (px, on whichever side keeps him on screen); want = expected damage;
-- wrap = must the victim wrap?  nil = don't care (the whiff).
local TESTS = {
    -- knee link (kind = "knee"): see the header.  super = must the super
    -- come out (act_rhouse seen)?
    { at = 120, label = "super", gap = 40, want = 27, wrap = true,  win = 100, kind = "knee", link = 8,  back = true, super = true },
    { at = 330, label = "knee",  gap = 40, want = 16, wrap = false, win = 70,  kind = "knee",                        super = false },
    { at = 420, label = "nobk",  gap = 40, want = 16, wrap = false, win = 70,  kind = "knee", link = 8,  back = false, super = false },
    { at = 510, label = "late",  gap = 40, want = 16, wrap = false, win = 80,  kind = "knee", link = 22, back = true, super = false },
    { at = 610, label = "hold",  gap = 40, want = 27, wrap = true,  win = 100, kind = "knee", link = 14, back = true, super = true },
    { at = 725, label = "cool",  gap = 40, want = 16, wrap = false, win = 40,  kind = "knee", link = 8,  back = true, super = false, stamp = true },
    -- LIGHTNING BOLT, Back,Back + HP (do_rain_bolt).  kind = "bolt".
    --   bolt   lands: act_rain_bolt, 9 damage, and he goes straight UP
    --   cool   inside rain_bolt_cool (112 ticks) of it: must NOT cast
    --   dodge  cast (d=14), then Jax is moved 110 px from d=20, during the
    --          windup and the forks - the bolt
    --          falls where he STOOD, so it must miss
    { at = 800, label = "bolt",  gap = 120, want = 9, kind = "bolt", cast = true,  rise = true,  win = 90 },
    { at = 890, label = "bcool", gap = 120, want = 0, kind = "bolt", cast = false, rise = false, win = 60 },
    { at = 1020, label = "dodge", gap = 120, want = 0, kind = "bolt", cast = true,  rise = false, win = 90, dodge = 20 },
    -- Back + HK from roundhouse range (80 px: outside knee_check's 64, so no
    -- knee).  kind = "brh".  His roundhouse IS the super now, so:
    --   bhk    Back + HK alone: the SUPER - stk_rain_roundh, 14 as a fresh
    --          hit, and he wraps
    --   brh    Back + HK + LK: two kicks on one tick reach ONE handler, and
    --          which is not ours to choose - the super (14) if the high kick
    --          won the scan, the sweep (20) if the low one did.  Both are
    --          stock behaviour; the trial only fails on something else.
    { at = 1130, label = "brh",   gap = 80,  want = 14, alt = 20, kind = "brh", lk = true,  win = 100, anyact = true },
    { at = 1240, label = "bhk",   gap = 80,  want = 14, kind = "brh", lk = false, wrap = true,  win = 80,  super = true },
}

--
-- THE KNEE -> SUPER LINK IS A BUILD SWITCH, so the expectation has to be read
-- from the build rather than written down here.  `rainknee .set 0` (MOVES.ASM,
-- 2026-09-28, the user's call) leaves rain_knee assembled but unreachable: the
-- knee stays the stock ninja knee and Back+HK on its own still throws the
-- super roundhouse.  The "super" and "hold" trials went on asserting the LINKED
-- damage (27) and reported FAIL on a perfectly good ROM from that day on - two
-- permanent false failures, which is worse than no trial at all, because a rig
-- that fails whatever the code does cannot tell anyone anything.
--
-- With the link off those two trials become the assertion that it IS off: the
-- same stock knee the "knee" and "nobk" trials expect, no super, no wrap.  So
-- they still discriminate - turning rainknee back on without re-enabling the
-- link would fail them.
--
local function read_rainknee()
    local fh = io.open(ROOT .. "/src/MOVES.ASM", "r")
    if not fh then return nil end
    local v
    for line in fh:lines() do
        local m = line:match("^rainknee%s+%.set%s+(%d+)")
        if m then v = tonumber(m) break end
    end
    fh:close()
    return v
end

local RAINKNEE = read_rainknee()
if RAINKNEE == nil then
    log("[rain-rh] WARNING: could not read `rainknee` from src/MOVES.ASM - "
        .. "leaving the linked expectations in place")
elseif RAINKNEE == 0 then
    log("[rain-rh] rainknee=0: the knee->super link is compiled out, so "
        .. "'super' and 'hold' expect the STOCK knee (16, no super, no wrap)")
    for _, t in ipairs(TESTS) do
        if t.label == "super" or t.label == "hold" then
            t.want, t.wrap, t.super = 16, false, false
        end
    end
else
    log("[rain-rh] rainknee=%d: the knee->super link is live", RAINKNEE)
end
-- how far off the ground the bolt must throw him.  Trilogy's own lob
-- (rain_bolt_trilogy 1): ~230 px, ~80 ticks in the air.
local BOLT_LIFT = 60
local ACT_RAIN_BOLT = 0x018
local OYPOS = 0xb0
local PARK = 30          -- frames before `at` P1 is moved and held
-- win = frames after `at` to measure; the whiff's must close before the
-- plain test parks P1 (at 350), or it counts the plain kick's damage.
local RUN_END = 1330

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local failures = 0
local st = {}            -- per test: facing, bar0, maxjump, act, park_x
local results = {}
local last_act
local stance_last, stance_since, scwalk_seen

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function obj_x(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function set_x(p, x) local o = r32(p); if o ~= 0 then w16(o + OXPOS, x) end end
local function wtlx() return s16(r16(A.worldtlx + 16)) end
local function p1_action()
    local proc = r32(A.p1_proc)
    if proc == 0 then return 0xffff end
    return r16(proc + P_ACTION)
end

local function shot(label)
    if not SNAP then return end
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot(label .. ".png") end) end
end

local base
local function finish(ok, reason)
    if finished then return end
    finished = true
    log("walk check: %d frame(s) of Scorpion's SCWALK while walking (want 0)", scwalk_seen or 0)
    if base and space then
        log("frame budget over the fight: dma late +%d  lost +%d  geo segments dropped +%d",
            r16(A.dmaq_late) - base.late, r16(A.dmaq_lost) - base.lost, r16(A.geo_dropped) - base.geo)
    end
    log("---- results ----")
    for _, t in ipairs(TESTS) do log("%-7s %s", t.label, results[t.label] or "NOT REACHED") end
    log("%s reason=%s failures=%d", ok and "PASS" or "FAIL", reason, failures)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Right"] = true, ["P1 Left"] = true, ["P1 High Punch"] = true,
        ["P1 High Kick"] = true, ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do if not fields[name] then log("input %-16s MISSING", name) end end
end

-- Back + High Kick (+ Low Kick for the super): Back held 0..10, the
-- Back-held version of the high kick).
local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end
    local r = frame - fighting_frame
    -- walk him forward, then back, before the first test parks him, so the
    -- walk lanes show up in the stance/frame log below
    if name == "P1 Right" and r >= 25 and r < 50 then return true end
    if name == "P1 Left" and r >= 55 and r < 80 then return true end
    for _, t in ipairs(TESTS) do
        local d = r - t.at
        local s = st[t.label]
        if s and s.facing ~= nil then
            local back = s.facing and "P1 Left" or "P1 Right"
            if t.kind == "brh" then
                -- Back held, then High Kick (+ Low Kick) together
                if name == back and d >= 0 and d < 12 then return true end
                if name == "P1 High Kick" and d >= 3 and d < 7 then return true end
                if t.lk and name == "P1 Low Kick" and d >= 3 and d < 7 then return true end
            elseif t.kind == "bolt" then
                -- Back (tap), release, Back, then High Punch
                if name == back and ((d >= 0 and d < 4) or (d >= 7 and d < 11)) then return true end
                if name == "P1 High Punch" and d >= 12 and d < 18 then return true end
            else
                -- the knee: HK tapped close, stick neutral
                if name == "P1 High Kick" and d >= 0 and d < 4 then return true end
                local L = t.link
                if L then
                    if t.back and name == back and d >= L - 3 and d < L + 8 then return true end
                    if name == "P1 High Kick" and d >= L and d < L + 4 then return true end
                end
            end
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("harness loaded")
        if missing then finish(false, "missing_symbols"); return end
    end
    if not space or finished then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_SCORPION)
        w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d (hovering Scorpion)", frame)
        end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_RAIN)
        w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
        if r16(A.p1_char) ~= FT_RAIN then finish(false, "p1_char_overwrite_failed"); return end
        shot("rain_rh_stance")
        base = { late = r16(A.dmaq_late), lost = r16(A.dmaq_lost), geo = r16(A.geo_dropped) }
        log("stage curback=%d  dma late=%d lost=%d geo_dropped=%d at the bell",
            r16(A.curback), base.late, base.lost, base.geo)
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end
        w16(A.p1_bar, MAX_HP)

        -- STANCE: before the first test parks him (r < 85), which frame is he
        -- showing and for how many ticks.  oshape (object +1d0h) is the
        -- current piece list; the map names it.
        if r < 85 then
            local o1 = r32(A.p1_obj)
            local sh = o1 ~= 0 and r32(o1 + 0x1d0) or 0
            if sh ~= stance_last then
                if stance_last and stance_since then
                    local nm = addr2sym[stance_last] or string.format("%08x", stance_last)
                    log("  frame %-14s held %d ticks  (act %04x)", nm, r - stance_since, p1_action())
                    if nm:match("^SCWALK") then scwalk_seen = (scwalk_seen or 0) + 1 end
                end
                stance_last, stance_since = sh, r
            end
        end
        local act = p1_action()
        if act ~= last_act then
            log("  r=%4d p1act 0x%04x -> 0x%04x  x: p1=%s p2=%s wtlx=%d",
                r, last_act or 0, act, tostring(obj_x(A.p1_obj)), tostring(obj_x(A.p2_obj)), wtlx())
            last_act = act
        end

        local measuring = false
        for _, t in ipairs(TESTS) do
            local d = r - t.at
            if d >= -PARK and d < 0 then
                -- park P1 beside Jax, on the side with room, and refill Jax
                measuring = true
                local p2 = obj_x(A.p2_obj)
                if p2 then
                    local left = p2 - t.gap
                    local x = (left > wtlx() + 60) and left or (p2 + t.gap)
                    set_x(A.p1_obj, x)
                end
                w16(A.p2_bar, MAX_HP)
            elseif d == 0 then
                measuring = true
                local p1, p2 = obj_x(A.p1_obj), obj_x(A.p2_obj)
                local o2 = r32(A.p2_obj)
                if t.stamp then
                    -- the super was "just" thrown: l_roundh (P1's word) = now
                    w16(A.l_roundh, r16(A.tick))
                end
                st[t.label] = { facing = (p1 <= p2), bar0 = r16(A.p2_bar), maxjump = 0,
                                lastx = p2, tsl = r16(A.l_roundh),
                                y0 = o2 ~= 0 and s16(r16(o2 + OYPOS)) or 0, rise = 0,
                                minbar = r16(A.p2_bar) }
                log("%-7s start: p1=%d p2=%d (%s)  p2_bar=%d", t.label, p1, p2,
                    (p1 <= p2) and "facing right" or "facing left", r16(A.p2_bar))
            elseif d > 0 and d <= t.win then
                measuring = true
                local s = st[t.label]
                local x = obj_x(A.p2_obj)
                if x and s.lastx then
                    local j = math.abs(x - s.lastx)
                    if j > s.maxjump then s.maxjump = j; s.jumpat = d end
                end
                s.lastx = x
                -- LOWEST bar seen, not the bar at the end of the window: the
                -- next test parks (and refills Jax) before a long window closes
                local b = r16(A.p2_bar)
                if b < s.minbar then s.minbar = b end
                if act == ACT_RHOUSE and t.kind ~= "bolt" then s.sawact = true end
                if act == ACT_KNEE then s.sawknee = true end
                if act == ACT_RAIN_BOLT then s.sawbolt = true end
                local o2 = r32(A.p2_obj)
                if o2 ~= 0 then
                    local up = s.y0 - s16(r16(o2 + OYPOS))
                    if up > s.rise then s.rise = up end
                end
                if t.dodge and d >= t.dodge and d < t.dodge + 20 then
                    -- walk him out from under it: away from Rain
                    local px = obj_x(A.p1_obj)
                    -- away from Rain unless that is past the screen edge (the
                    -- knee tests leave Jax in the right corner): then the
                    -- other way - the bolt falls where he STOOD either way
                    if d == t.dodge then
                        local away = (x > px) and (x + 110) or (x - 110)
                        if away > wtlx() + 330 or away < wtlx() + 20 then
                            away = (x > px) and (x - 110) or (x + 110)
                        end
                        s.dodgex = away
                    end
                    set_x(A.p2_obj, s.dodgex)
                end
                if PALDUMP and t.kind == "bolt" and t.label == "bolt" and A.palram then
                    -- 80 slots x 64 bits: +0 palette id (its address), +32 count
                    s.pal = s.pal or {}
                    for i = 0, 79 do
                        local a = A.palram + i * 64
                        local id, cnt = r32(a), r16(a + 32)
                        local old = s.pal[i]
                        if old and (old[1] ~= id or old[2] ~= cnt) then
                            log("  pal slot %2d  +%3d  %s x%d -> %s x%d", i, d,
                                addr2sym[old[1]] or string.format("%08x", old[1]), old[2],
                                addr2sym[id] or string.format("%08x", id), cnt)
                        end
                        s.pal[i] = { id, cnt }
                    end
                    if d == 1 then
                        local cp = r32(A.skew_constpal)
                        log("  floor const:pal %08x (map %d)", cp, cp & 0xff)
                        for i = 0, 79 do
                            local id = s.pal[i][1]
                            if addr2sym[id] and addr2sym[id]:match("GROUND") then
                                log("  floor palette %s is in slot %d, count %d", addr2sym[id], i, s.pal[i][2])
                            end
                        end
                    end
                end
                if NOSHADOW and t.kind == "bolt" and t.label == "bolt" then
                    local o2 = r32(A.p2_obj)
                    if o2 ~= 0 then w16(o2 + 0x160, r16(o2 + 0x160) & ~0x10) end
                end
                if t.kind == "bolt" and t.label == "bolt" then
                    local wy = s16(r16(A.worldtly + 16))
                    if not s.wymin or wy < s.wymin then s.wymin = wy; s.wyat = d end
                    if SNAP and d % 3 == 0 and d <= 90 then
                        shot(string.format("rain_bolt_%03d", d))
                    end
                    if d == t.win then
                        log("camera: top y %d at +%d, ceiling_y %d, climb_limit %d -> %d px ABOVE the ceiling",
                            s.wymin, s.wyat, s16(r16(A.ceiling_y)), r16(A.climb_limit),
                            s16(r16(A.ceiling_y)) - s.wymin)
                    end
                end
                if t.label == "super" and d <= 40 then
                    local pp = r32(A.p2_proc)
                    local o2 = r32(A.p2_obj)
                    log("  super +%2d  p1act %04x  p2 x=%s act=%04x oxvel=%08x", d, act, tostring(obj_x(A.p2_obj)),
                        pp ~= 0 and r16(pp + P_ACTION) or 0xffff, o2 ~= 0 and r32(o2 + 0x40) or 0)
                end
                if t.label == "super" and d % 2 == 0 and d <= 70 then
                    shot(string.format("rain_rh_%03d", d))
                end
                if d == t.win and t.kind == "bolt" then
                    local dmg = s.bar0 - s.minbar
                    -- the bolt is a JUGGLE launch now, not Trilogy's 230 px
                    -- lob: rain_bolt_yvel/-grav (MAINEQU) put him ~45 px up
                    -- for ~28 ticks, inside a ground normal's reach
                    local rose = s.rise > BOLT_LIFT
                    local ok = ((s.sawbolt or false) == t.cast) and dmg == t.want and rose == t.rise
                    local line = string.format("%s cast=%s (want %s) dmg=%d (want %d) rose=%dpx (want %s) maxjump=%d",
                        ok and "OK  " or "FAIL", tostring(s.sawbolt == true), tostring(t.cast), dmg, t.want,
                        s.rise, t.rise and (">" .. BOLT_LIFT) or ("<=" .. BOLT_LIFT), s.maxjump)
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-7s %s", t.label, line)
                elseif d == t.win and t.kind == "brh" then
                    local dmg = s.bar0 - s.minbar
                    local wrapped = s.maxjump > 150
                    -- two kicks on one tick reach ONE handler, so an lk
                    -- trial comes out as a roundhouse or a sweep; `alt` is the
                    -- other one, `anyact` waives the act_rhouse requirement
                    local hit_ok = (dmg == t.want) or (t.alt ~= nil and dmg == t.alt)
                    local act_ok = t.anyact and true or (s.sawact or false)
                    local ok = act_ok and not s.sawknee and hit_ok
                    if t.wrap ~= nil then ok = ok and (wrapped == t.wrap) end
                    local line = string.format("%s roundhouse=%s knee=%s dmg=%d (want %s) maxjump=%d wrap=%s (want %s)",
                        ok and "OK  " or "FAIL", tostring(s.sawact == true), tostring(s.sawknee == true), dmg,
                        t.alt and (t.want .. " or " .. t.alt) or tostring(t.want),
                        s.maxjump, tostring(wrapped), t.wrap == nil and "any" or tostring(t.wrap))
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-7s %s", t.label, line)
                elseif d == t.win then
                    local dmg = s.bar0 - s.minbar
                    local wrapped = s.maxjump > 150
                    local ok = s.sawknee and ((s.sawact or false) == t.super) and dmg == t.want
                    if t.wrap ~= nil then ok = ok and (wrapped == t.wrap) end
                    local line = string.format("%s knee=%s super=%s (want %s) dmg=%d (want %d) maxjump=%d%s wrap=%s (want %s)",
                        ok and "OK  " or "FAIL", tostring(s.sawknee == true), tostring(s.sawact == true), tostring(t.super), dmg, t.want,
                        s.maxjump, s.jumpat and ("@+" .. s.jumpat) or "", tostring(wrapped),
                        t.wrap == nil and "any" or tostring(t.wrap))
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-7s %s", t.label, line)
                end
            end
        end
        if not measuring then w16(A.p2_bar, MAX_HP) end

        if r > RUN_END then
            finish(failures == 0, failures == 0 and "knee_links_super_negatives_hold" or "mismatch")
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 6000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
