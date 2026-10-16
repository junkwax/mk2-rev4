-- lk_dubknee_test.lua
--
-- LIU KANG'S DOUBLE KNEE (lk_knee / lk_double_knee, src/MKLKDK.ASM;
-- stk_lkdubknee, MKSTK.ASM; a_lkdubknee, MKLK.ASM) - the DUBLKNEESQ
-- sequence embedded in data/KANG3.IMG, authored in 1993 and never coded.
--
-- The ordinary close knee comes out.  If the SECOND High Kick is already in
-- by the time it lands, the knee stuns him standing (stk_lkknee_link) and
-- carries on into LKDUBLKNEE1-4: the second knee SPIKES him into the floor
-- (r_lk_spiked -> lk_spike, MKLKDK.ASM, off data/KANGDBLKNEE2.WAX) - his own
-- sweep fall, the ground rumbles, he bounces IN PLACE and
-- gets up.  Otherwise it is retail's knee: a knock-up (r_hhknee), no link.
--
-- Every trial parks the pair mid-screen, P1 40 px from Jax, and taps HK at
-- d=0..3 for the knee (it lands around d=9).  `link` = when the second HK is.
--
--   dubk   link at 5, before the knee lands: stunned (he does not rise),
--          then kicked down through his sweep fall - a bounce of >= 20 px
--          with no x drift, then upright facing Liu Kang for his get-up.
--          20 + 11 = 31 over 2 hits.
--   knee   no link: the knee LAUNCHES him (retail) - 20, no carry-on.
--   late   link at 14, after the knee landed: he is already launched, so
--          no carry-on - 20, launched.
--   cool   link at 5 but inside lk_dknee_cool (the rig stamps l_lkdknee):
--          the plain knee - 20, launched.
--
-- The negatives are the point: a build where every knee spiked, or where
-- the launch never came back, fails them.
--
--   LKDK_LOG   log file path
--   LKDK_SNAP  1 = snapshot the carry-on (lkdk_NNN.png)
--   LKDK_STAGE a curback id to force

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("LKDK_LOG") or (ROOT .. "/tools/lk_dubknee_test.log")
local SNAP = os.getenv("LKDK_SNAP") == "1"
local STAGE = tonumber(os.getenv("LKDK_STAGE") or "")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[lk-dk] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(os.getenv("LKDK_MAP") or (ROOT .. "/src/mk2.map"), "r")
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

local A = {
    gstate = sym("gstate"), diff = sym("diff"), tick = sym("tick"),
    p1_proc = sym("p1_proc"), p1_char = sym("p1_char"), p1_bar = sym("p1_bar"),
    p2_proc = sym("p2_proc"), p2_char = sym("p2_char"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), curback = sym("curback"),
    l_lkdknee = sym("l_lkdknee"),
}
local missing = false
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k); missing = true end end

local P_ACTION = 0x1f0
local OXPOS, OYPOS, OFLAGS = 0x90, 0xb0, 0xf0
local M_FLIPV = 0x20
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KANG, MAX_HP = 1, 0xa1
local FT_JAX = tonumber(os.getenv("LKDK_VICTIM") or "") or 11   -- the victim's ochar
-- act_knee 010fh, act_2nd_knee 011ch, act_knee_sd 0601h (MAINEQU.ASM)
local ACT_KNEE, ACT_2ND_KNEE, ACT_KNEE_SD = 0x10f, 0x11c, 0x601
local KNEE = 20            -- stk_lkknee's hit damage
local LINKED = 31          -- ...plus stk_lkdubknee's 14 at dmgscale 3/4 = 11
local PARK = 30            -- frames before `at` P1 is parked and held

local TESTS = {
    { at = 120, label = "dubk", gap = 40, want = LINKED, dub = true,  win = 130, link = 5,  hits = 2, spike = true },
    { at = 300, label = "knee", gap = 40, want = KNEE,   dub = false, win = 80,             hits = 1 },
    { at = 420, label = "late", gap = 40, want = KNEE,   dub = false, win = 80,  link = 14, hits = 1 },
    { at = 540, label = "cool", gap = 40, want = KNEE,   dub = false, win = 80,  link = 5,  hits = 1, stamp = true },
    -- the bounce is juggleable: a CROUCHING HIGH KICK (Down + HK) thrown into
    -- it lands as a THIRD hit and knocks him on instead of the sweep get-up.
    -- (Measured: an uppercut does not reach the ~74 px he lies at, and a
    -- standing high kick passes over a man lying flat even at the apex.)
    { at = 660, label = "jugl", gap = 40, want = nil,    dub = true,  win = 130, link = 5,  hits = 3, upper = 41 },
}
local RUN_END = 800

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local failures = 0
local st, results = {}, {}
local last_act

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function obj_x(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function obj_y(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function obj_fl(p) local o = r32(p); if o == 0 then return 0 end return r16(o + OFLAGS) end
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

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- results ----")
    for _, t in ipairs(TESTS) do log("%-5s %s", t.label, results[t.label] or "NOT REACHED") end
    log("%s reason=%s failures=%d", ok and "PASS" or "FAIL", reason, failures)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Right"] = true, ["P1 Left"] = true, ["P1 High Punch"] = true,
        ["P1 High Kick"] = true, ["P1 Down"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do if not fields[name] then log("input %-16s MISSING", name) end end
end

local function pressed(name)
    -- boot: the attract sequence has to run before a coin registers, so these
    -- are the Rain rig's own frame numbers, not guesses
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end
    local r = frame - fighting_frame
    for _, t in ipairs(TESTS) do
        local d = r - t.at
        if st[t.label] then
            -- the knee: HK tapped close, STICK NEUTRAL.  is_stick_away turns
            -- joy_hi_kick into a roundhouse, so no direction is ever held.
            if name == "P1 High Kick" and d >= 0 and d < 4 then return true end
            local L = t.link
            if L and name == "P1 High Kick" and d >= L and d < L + 4 then return true end
            local U = t.upper
            if U and name == "P1 Down" and d >= U and d < U + 12 then return true end
            if U and name == "P1 High Kick" and d >= U + 3 and d < U + 7 then return true end
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
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d (hovering Liu Kang)", frame)
        end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d curback=%d", r16(A.p1_char), r16(A.p2_char), r16(A.curback))
        if r16(A.p1_char) ~= FT_KANG then finish(false, "p1_char_overwrite_failed"); return end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end
        w16(A.p1_bar, MAX_HP)

        local act = p1_action()
        if act ~= last_act then
            log("  r=%4d p1act 0x%04x -> 0x%04x  x: p1=%s p2=%s", r, last_act or 0, act,
                tostring(obj_x(A.p1_obj)), tostring(obj_x(A.p2_obj)))
            last_act = act
        end

        local measuring = false
        for _, t in ipairs(TESTS) do
            local d = r - t.at
            if d >= -PARK and d < 0 then
                -- Park the PAIR mid-screen, not just P1 beside wherever Jax
                -- ended up.  Parking only P1 lets each trial inherit the
                -- previous one's drift, and after a few knockdowns Jax is in
                -- a corner - where the edge clamp stops him sliding away and
                -- the carry-on connects on a victim it would MISS in open
                -- space.  That difference passed `nohp` and failed `dubk` on
                -- identical inputs until the pair was pinned here.
                measuring = true
                local base = wtlx() + 200
                set_x(A.p2_obj, base)
                set_x(A.p1_obj, base - t.gap)
                w16(A.p2_bar, MAX_HP)
            elseif d == 0 then
                measuring = true
                local p1, p2 = obj_x(A.p1_obj), obj_x(A.p2_obj)
                if t.stamp then
                    -- the carry-on was "just" used: l_lkdknee (P1's word) = now
                    w16(A.l_lkdknee, r16(A.tick))
                end
                st[t.label] = { bar0 = r16(A.p2_bar), minbar = r16(A.p2_bar), fl0 = obj_fl(A.p2_obj),
                                y0 = obj_y(A.p2_obj) or 0, rise = 0, maxaway = 0,
                                x0 = p2, sawknee = false, sawdub = false }
                log("%-5s start: p1=%d p2=%d gap=%d  p2_bar=%d  l_lkdknee=%d tick=%d",
                    t.label, p1, p2, math.abs((p1 or 0) - (p2 or 0)), r16(A.p2_bar),
                    r16(A.l_lkdknee), r16(A.tick))
            elseif d > 0 and d <= t.win then
                measuring = true
                local s = st[t.label]
                if act == ACT_KNEE or act == ACT_KNEE_SD then s.sawknee = true end
                if act == ACT_2ND_KNEE then
                    if not s.sawdub then s.dubat = d end
                    s.sawdub = true
                end
                local b = r16(A.p2_bar)
                if b < s.minbar then
                    s.nhits = (s.nhits or 0) + 1
                    if not s.hit1 then s.hit1 = d end
                    s.hit2 = d
                    s.minbar = b
                end
                local x, y = obj_x(A.p2_obj), obj_y(A.p2_obj)
                if x and s.x0 then
                    local away = math.abs(x - s.x0)
                    if away > s.maxaway then s.maxaway = away end
                end
                local fl = obj_fl(A.p2_obj)
                local down = (fl & M_FLIPV) ~= 0
                if down then s.flipped = true end
                if y then
                    local up = s.y0 - y
                    -- before the second knee: did the FIRST one launch him?
                    if not s.sawdub and up > s.rise then s.rise = up end
                    -- after the second knee lands (2nd bar drop): kicked down
                    -- through his sweep fall onto the floor, then the bounce -
                    -- measured from the lowest anchor he reaches as he lands
                    -- after the second knee lands: the bounce.  Clearly in the air
                    -- (> 8 px up, past the sweep-fall poses' own few px) until he
                    -- is back on his floor; x must not move meanwhile.
                    if (s.nhits or 0) >= 2 and not s.landed then
                        if up > (s.bounce or 0) then s.bounce = up end
                        if up > 8 then
                            s.aloft = true
                            if not s.bx then s.bx, s.bdrift = x, 0 end
                            if x and s.bx then
                                local dx = math.abs(x - s.bx)
                                if dx > (s.bdrift or 0) then s.bdrift = dx end
                            end
                        elseif s.aloft and up <= 0 then
                            s.landed = true
                        end
                    end
                end
                s.lastfl = fl
                s.lastdown = down
                -- after a THIRD hit (the juggle trial): how far that hit's own
                -- reaction carries him - the get-up never moves him sideways
                do
                    local p1x = obj_x(A.p1_obj)
                    if x and p1x and (s.nhits or 0) >= 3 then
                        local dd = math.abs(x - p1x)
                        if not s.d3 then s.d3 = dd end
                        if dd - s.d3 > (s.carried or 0) then s.carried = dd - s.d3 end
                    end
                end
                -- the geometry the box has to cover, logged through the window
                if d <= 70 then
                    local p1x = obj_x(A.p1_obj)
                    log("  %-5s +%2d  p1act %04x  dist=%s  p2 up=%s  flipv=%s  bar=%d",
                        t.label, d, act,
                        (x and p1x) and tostring(math.abs(x - p1x)) or "?",
                        y and tostring(s.y0 - y) or "?", down and 1 or 0, b)
                end
                if SNAP and t.dub and d <= 80 then
                    shot(string.format("lkdk_%s_%03d", t.label, d))
                end
                if d == t.win then
                    local dmg = s.bar0 - s.minbar
                    local ok = s.sawknee and (s.sawdub == t.dub) and (t.want == nil or dmg == t.want)
                    ok = ok and (s.nhits or 0) == t.hits
                    local why = ""
                    if t.upper then
                        -- the third hit landed while he bounced, and its OWN
                        -- reaction took him over - carried him off sideways,
                        -- which the sweep get-up never does
                        local good = (s.carried or 0) >= 15
                        why = " carried=" .. tostring(s.carried)
                        if not good then why = why .. " FOLLOW-UP-NOT-A-JUGGLE" end
                        ok = ok and good
                    elseif t.spike then
                        -- stunned standing, kicked down, bounced in place, facing him at the end
                        -- ...and he ends upright, turned to face Liu Kang
                        -- (the facing he had at the start, when he faced him)
                        local facing = ((s.lastfl or 0) & 0x10) == (s.fl0 & 0x10)
                        local good = s.rise <= 8 and not s.flipped and (s.bounce or 0) >= 20
                                     and (s.bdrift or 99) <= 3 and facing
                        if not facing then why = " NOT-FACING-HIM" end
                        if not good and why == "" then why = " SPIKE-SHAPE-WRONG" end
                        ok = ok and good
                    else
                        -- retail's knee: launched, never spiked
                        local good = s.rise >= 30 and not s.flipped
                        if not good then why = " NOT-A-LAUNCH" end
                        ok = ok and good
                    end
                    local line = string.format(
                        "%s knee=%s dub=%s(want %s)%s dmg=%d(want %s) hits=%d(want %d) rose=%d flipv=%s%s bounce=%s drift=%s%s",
                        ok and "OK  " or "FAIL", tostring(s.sawknee), tostring(s.sawdub),
                        tostring(t.dub), s.dubat and ("@+" .. s.dubat) or "",
                        dmg, tostring(t.want or "any"), s.nhits or 0, t.hits, s.rise, tostring(s.flipped == true),
                        "",
                        tostring(s.bounce), tostring(s.bdrift), why)
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-5s %s", t.label, line)
                end
            end
        end
        if not measuring then w16(A.p2_bar, MAX_HP) end

        if r > RUN_END then
            finish(failures == 0,
                   failures == 0 and "knee_links_double_knee_negatives_hold" or "mismatch")
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 6000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
