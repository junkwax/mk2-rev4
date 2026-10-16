-- rain_zap_test.lua
--
-- RAIN's WATER MOVE - the storm cloud, Down, Forward + HP (do_rain_zap /
-- rain_zap_proc / rain_hold, MKZAP.ASM; r_rain_zap, MKREACT.ASM), MK Trilogy's
-- do_proj_rain_zap on the N64.  Reached like rain_roundhouse_test.lua: pick
-- Scorpion, overwrite p1_char with ft_rain at GS_POST.  P2 is Jax at diff 0.
--
--   far    thrown from 150 px: the cloud FLIES and catches him.  Must: cast
--          (act_rain_zap), 20 damage, he goes into act_rain_storm, Rain into
--          act_rain_hold; the rig holds UP then RIGHT through the hold and he
--          must RISE and MOVE RIGHT; afterwards both are out of it and he is
--          back on the floor
--   close  thrown from 70 px: caught while the cloud FORMS (stk_rain_zp1-3).
--          20 damage, act_rain_storm seen
--   still  far again, stick left alone: he is held but must NOT be moved -
--          proves the rise in `far` is the steering, not the reaction
--   nomo   HP with no motion: a plain high punch, no cast
--   kill   far, with Jax on 5: the cloud empties his bar, so there must be NO
--          hold (r_rain_zap skips it) and the round must end - winner_status
--          set - instead of wedging with nobody in the cloud
--
--   RAIN_ZAP_LOG   log file path
--   RAIN_ZAP_SNAP  1 = snapshot `far` every 2nd frame (rain_zap_NNN.png)
--   RAIN_ZAP_MAP   the mk2.map belonging to -rompath's zip, if not the tree's

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("RAIN_ZAP_LOG") or (ROOT .. "/tools/rain_zap_test.log")
local SNAP = os.getenv("RAIN_ZAP_SNAP") == "1"
-- RAIN_ZAP_BUB=1: log the HELD victim's oscale every tick.  rainbub's
-- wobble (MAINEQU.ASM) writes it from rain_hold, so a flat trace means the
-- layer is not running - which a snapshot cannot tell from a small roll.
local BUB = os.getenv("RAIN_ZAP_BUB") == "1"
local STAGE = tonumber(os.getenv("RAIN_ZAP_STAGE") or "")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[rain-zap] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(os.getenv("RAIN_ZAP_MAP") or (ROOT .. "/src/mk2.map"), "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), diff = sym("diff"),
    p1_proc = sym("p1_proc"), p1_char = sym("p1_char"), p1_bar = sym("p1_bar"),
    p2_char = sym("p2_char"), p2_bar = sym("p2_bar"), p2_proc = sym("p2_proc"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), worldtly = sym("worldtly"), curback = sym("curback"),
    winner_status = sym("winner_status"),
    dmaq_late = sym("dmaq_late"), dmaq_lost = sym("dmaq_lost"),
}
local OPT = {
    sp_spans = sym("sp_spans"), peak_overload = sym("peak_overload"),
    fpal_fail = sym("fpal_fail"),
    rbub_obj = sym("rbub_obj"),
    objlst = sym("objlst"),
}
local missing = false
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k); missing = true end end

local P_ACTION = 0x1f0
local OXPOS, OYPOS = 0x90, 0xb0
local OSCALE = 0x180
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_JAX, FT_RAIN, MAX_HP = 10, 11, 19, 0xa1
local ACT_RAIN_ZAP, ACT_RAIN_HOLD, ACT_RAIN_STORM = 0x019, 0x30c, 0x50e

-- steer = { {from, to, "Up"|"Down"|"Left"|"Right"}, ... } in frames after
-- the victim first shows act_rain_storm
local TESTS = {
    { at = 120, label = "far",   gap = 150, win = 150, cast = true,  want = 20,
      steer = { {4, 40, "Up"}, {40, 70, "Right"} }, rise = true, moved = true },
    { at = 300, label = "close", gap = 70,  win = 130, cast = true,  want = 20 },
    { at = 460, label = "still", gap = 150, win = 150, cast = true,  want = 20, rise = false, moved = false },
    { at = 640, label = "nomo",  gap = 40,  win = 60,  cast = false, plain = true },
    { at = 760, label = "kill",  gap = 150, win = 200, cast = true,  want = 5, kill = true },
}
local PARK = 30
local RUN_END = 970

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local failures = 0
local st, results = {}, {}
local last_act, last_act2

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function obj_x(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function obj_y(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function set_x(p, x) local o = r32(p); if o ~= 0 then w16(o + OXPOS, x) end end
local function wtlx() return s16(r16(A.worldtlx + 16)) end
local function act_of(pp) local proc = r32(pp); if proc == 0 then return 0xffff end return r16(proc + P_ACTION) end

local function shot(label)
    if not SNAP then return end
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot(label .. ".png") end) end
end

local base
local function finish(ok, reason)
    if finished then return end
    finished = true
    if base and space then
        log("frame budget: dma late +%d  lost +%d", r16(A.dmaq_late) - base.late, r16(A.dmaq_lost) - base.lost)
    end
    log("---- results ----")
    for _, t in ipairs(TESTS) do log("%-6s %s", t.label, results[t.label] or "NOT REACHED") end
    log("%s reason=%s failures=%d", ok and "PASS" or "FAIL", reason, failures)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Right"] = true, ["P1 Left"] = true, ["P1 Up"] = true, ["P1 Down"] = true,
        ["P1 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do if not fields[name] then log("input %-16s MISSING", name) end end
end

local function pressed(name)
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
        local s = st[t.label]
        if s and s.facing ~= nil and d >= 0 and d <= t.win then
            local fwd = s.facing and "P1 Right" or "P1 Left"
            if not t.plain then
                -- Down, release, Forward, then High Punch
                if name == "P1 Down" and d >= 0 and d < 4 then return true end
                if name == fwd and d >= 6 and d < 10 then return true end
            end
            if name == "P1 High Punch" and d >= 11 and d < 16 then return true end
            -- the steer, keyed to when the hold began
            if t.steer and s.storm_at then
                local k = r - s.storm_at
                for _, sv in ipairs(t.steer) do
                    if k >= sv[1] and k < sv[2] and name == "P1 " .. sv[3] then return true end
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
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_RAIN)
        w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d stage=%d", r16(A.p1_char), r16(A.p2_char), r16(A.curback))
        if r16(A.p1_char) ~= FT_RAIN then finish(false, "p1_char_overwrite_failed"); return end
        base = { late = r16(A.dmaq_late), lost = r16(A.dmaq_lost) }
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end
        w16(A.p1_bar, MAX_HP)
        local act, act2 = act_of(A.p1_proc), act_of(A.p2_proc)
        if act ~= last_act or act2 ~= last_act2 then
            log("  r=%4d p1act %04x p2act %04x  p1 x=%s  p2 x=%s y=%s  wtlx=%d", r, act, act2,
                tostring(obj_x(A.p1_obj)), tostring(obj_x(A.p2_obj)), tostring(obj_y(A.p2_obj)), wtlx())
            last_act, last_act2 = act, act2
        end

        local measuring = false
        for _, t in ipairs(TESTS) do
            local d = r - t.at
            if d >= -PARK and d < 0 then
                measuring = true
                local p2 = obj_x(A.p2_obj)
                if p2 then
                    local left = p2 - t.gap
                    set_x(A.p1_obj, (left > wtlx() + 40) and left or (p2 + t.gap))
                end
                w16(A.p2_bar, t.kill and 5 or MAX_HP)
            elseif d == 0 then
                measuring = true
                local p1, p2 = obj_x(A.p1_obj), obj_x(A.p2_obj)
                st[t.label] = { facing = (p1 <= p2), bar0 = r16(A.p2_bar), minbar = r16(A.p2_bar),
                                y0 = obj_y(A.p2_obj), x0 = p2 }
                log("%-6s start: p1=%d p2=%d (%s)", t.label, p1, p2, (p1 <= p2) and "facing right" or "facing left")
            elseif d > 0 and d <= t.win then
                measuring = true
                local s = st[t.label]
                local b = r16(A.p2_bar)
                if b < s.minbar then s.minbar = b end
                if act == ACT_RAIN_ZAP then s.cast = true end
                if act == ACT_RAIN_HOLD then s.hold = (s.hold or 0) + 1 end
                if act2 == ACT_RAIN_STORM then
                    s.storm = (s.storm or 0) + 1
                    if not s.storm_at then
                        s.storm_at = r
                        s.sy0, s.sx0 = obj_y(A.p2_obj), obj_x(A.p2_obj)
                        log("  %s: held at +%d (x=%d y=%d)", t.label, d, s.sx0, s.sy0)
                    end
                    local y, x = obj_y(A.p2_obj), obj_x(A.p2_obj)
                    if (r - s.storm_at) % 8 == 0 then
                        log("    %s +%2d  victim x=%d y=%d  camera top=%d", t.label, r - s.storm_at, x, y, s16(r16(A.worldtly + 16)))
                    end
                    if BUB then
                        local o = r32(A.p2_obj)
                        if o ~= 0 then
                            local sc = r32(o + OSCALE)
                            local extra = ""
                            if OPT.sp_spans then extra = extra .. string.format("  spans=%d", r16(OPT.sp_spans)) end
                            if OPT.peak_overload then extra = extra .. string.format("  peak_overload=%d", r16(OPT.peak_overload)) end
                            if OPT.rbub_obj then
                                local bo = r32(OPT.rbub_obj)
                                extra = extra .. string.format("  bub=%08x", bo)
                                if bo ~= 0 then extra = extra .. string.format(
                                    " @%d,%d pal=%04x sz=%08x flags=%04x sag=%08x z=%08x",
                                    s16(r16(bo + OXPOS)), s16(r16(bo + OYPOS)), r16(bo + 0x140),
                                    r32(bo + 0x120), r16(bo + 0xf0), r32(bo + 0x100), r32(bo + 0xc0)) end
                                if bo ~= 0 and OPT.objlst then
                                    -- walk objlst looking for our pointer: an object
                                    -- with perfect fields that is not IN the list is a
                                    -- completely different bug from one that is.
                                    local o, k, found = r32(OPT.objlst), 0, false
                                    while o ~= 0 and k < 400 do
                                        if o == bo then found = true end
                                        o = r32(o); k = k + 1
                                    end
                                    extra = extra .. string.format("  inlist=%s depth=%d", tostring(found), k)
                                end
                            end
                            log("    bub %s +%2d  oscale=%08x  ystep=%d xstep=%d%s", t.label, r - s.storm_at, sc, (sc >> 16) & 0xffff, sc & 0xffff, extra)
                        end
                    end
                    -- the reaction's own shake is +-6; more than that is steering
                    if s.sy0 - y > (s.rise or 0) then s.rise = s.sy0 - y end
                    if math.abs(x - s.sx0) > (s.dx or 0) then s.dx = math.abs(x - s.sx0) end
                elseif s.storm_at and not s.out_at then
                    s.out_at = r
                    log("  %s: released after %d ticks", t.label, r - s.storm_at)
                end
                if (t.label == "far" or t.label == "still") and d % 2 == 0 then
                    shot(string.format("rain_zap_%s_%03d", t.label, d))
                end
                if t.kill and r16(A.winner_status) ~= 0 and not s.won then
                    s.won = d
                    log("  kill: winner_status %d at +%d", r16(A.winner_status), d)
                end
                if d == t.win and t.kill then
                    local dmg = s.bar0 - s.minbar
                    local ok = s.cast and dmg == t.want and (s.storm or 0) == 0 and (s.hold or 0) == 0 and s.won ~= nil
                    local line = string.format("%s cast=%s dmg=%d (want %d) storm=%d hold=%d round_over=%s",
                        ok and "OK  " or "FAIL", tostring(s.cast == true), dmg, t.want, s.storm or 0, s.hold or 0,
                        s.won and ("+" .. s.won) or "never")
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-6s %s", t.label, line)
                elseif d == t.win then
                    local dmg = s.bar0 - s.minbar
                    local ok = ((s.cast or false) == t.cast)
                    local extra = ""
                    if t.cast then
                        ok = ok and dmg == t.want and (s.storm or 0) > 0
                        extra = string.format(" storm=%d hold=%d rise=%d dx=%d", s.storm or 0, s.hold or 0, s.rise or 0, s.dx or 0)
                        if t.rise ~= nil then
                            ok = ok and ((s.hold or 0) > 0) and (((s.rise or 0) > 20) == t.rise) and (((s.dx or 0) > 20) == t.moved)
                        end
                        -- afterwards: out of it, and on his feet again
                        local grounded = math.abs((obj_y(A.p2_obj) or 0) - (st[t.label].y0 or 0)) <= 2
                        ok = ok and s.out_at ~= nil and grounded and act ~= ACT_RAIN_HOLD
                        extra = extra .. string.format(" released=%s grounded=%s", tostring(s.out_at ~= nil), tostring(grounded))
                    else
                        ok = ok and (s.storm or 0) == 0
                    end
                    local line = string.format("%s cast=%s (want %s) dmg=%d%s%s", ok and "OK  " or "FAIL",
                        tostring(s.cast == true), tostring(t.cast), dmg, t.want and (" (want " .. t.want .. ")") or "", extra)
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-6s %s", t.label, line)
                end
            end
        end
        if not measuring and r < 700 then w16(A.p2_bar, MAX_HP) end
        if r > RUN_END then
            finish(failures == 0, failures == 0 and "cloud_holds_steers_releases" or "mismatch")
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 5000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
