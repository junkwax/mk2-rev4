-- stelbow_chain_test.lua
--
-- SHANG TSUNG'S ELBOW CHAIN, judged on the FRAMES it draws (st_elbow /
-- st_elbow_2, src/MKSTEL.ASM; a_stelbow, src/MKST.ASM).
--
-- STELBO1-5 in data/TSUNG2.IMG are TWO elbows, which is what the ELBO
-- sequence embedded beside them plays: STELBO1 is the wind-up and STELBO2
-- the contact of the FIRST, STELBO3,4,5 the turn, the cock and the contact
-- of the SECOND.  Retail opened a_stelbow on STELBO3, so the elbow MK2
-- ships is the second of the pair and the first was drawn by nothing - and
-- STELBO1 was not even packed whole (data/MK3MIL.LOD names STELBO1A twice
-- and STELBO1B never; src/MKST.ASM matched the typo with a one-piece list).
--
-- SO DAMAGE IS NOT THE THING TO MEASURE HERE.  The chain already did the
-- right damage while drawing the wrong frames - both elbows were STELBO3,4,5
-- and it read as the same swing twice.  This reads the SAG and size of every
-- piece the DMA was handed, every tick, and asserts the ORDER.
--
--   elbo  close HP, no link: STELBO1 then STELBO2, retract on STELBO1.
--         STELBO3/4/5 must NEVER appear - that is the regression that put
--         retail's second elbow in the first elbow's place.
--   dual  close HP, HP again inside the window: 1, 2, then 3, 4, 5.
--         STELBO1 must not come back between 2 and 3: st_elbow_2 BURNS part
--         2 (the retract) with no sleep between the calls, and a burn that
--         slept would show the wind-up again in the middle of the chain.
--   cool  the same presses inside st_chain_cool: the plain elbow.  Without a
--         negative, "the frames are 1,2,3,4,5" passes on a build where every
--         elbow is the whole lane.
--
-- AND IT COUNTS THE PIECES.  STELBO1 is a two-piece frame; with STELBO1B
-- still unpacked the object carries ONE node and Shang draws as a man sliced
-- down the middle - which a frame-order check alone cannot see, because the
-- first piece is STELBO1A either way.
--
--   STEL_LOG    log file path
--   STEL_SNAP   1 = snapshot the chain (stel_NNN.png)
--   STEL_STAGE  a curback id to force
--   STEL_MAP    an mk2.map that belongs to the zip under test

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("STEL_LOG") or (ROOT .. "/tools/stelbow_chain_test.log")
local SNAP = os.getenv("STEL_SNAP") == "1"
-- STEL_NEG crosses the expectation: the unlinked elbow is told to expect the
-- chain and the linked one the plain elbow.  Every trial must then FAIL.  A
-- detector that cannot be made to fail is not measuring anything.
local NEG = os.getenv("STEL_NEG") == "1"
local STAGE = tonumber(os.getenv("STEL_STAGE") or "")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[stel] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(os.getenv("STEL_MAP") or (ROOT .. "/src/mk2.map"), "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), diff = sym("diff"), tick = sym("tick"),
    p1_proc = sym("p1_proc"), p1_char = sym("p1_char"), p1_bar = sym("p1_bar"),
    p2_char = sym("p2_char"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), curback = sym("curback"),
    l_stchain = sym("l_stchain"),
}
local missing = false
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k); missing = true end end

-- DISPEQU.ASM object offsets, in bits - MAME's program space is bit-addressed.
local O_OXPOS, O_OSIZEX, O_OIMG = 0x090, 0x120, 0x1a0
-- multipart node: mp_sag 0, mp_sizex 32, mp_sizey 48, mp_length 112 (DISPEQU)
local MP_SAG, MP_SIZEX, MP_SIZEY, MP_LENGTH = 0x00, 0x20, 0x30, 0x70
local MP_MAX = 32
local P_ACTION = 0x1f0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_ST, FT_JAX, MAX_HP = 6, 11, 0xa1

-- EXPECTATIONS REGENERATED FROM THE BUILD EVERY RUN.  A rebuild moves every
-- SAG, so a hard-coded one passes against a stale ROM; the geometry is read
-- out of the shipped tables the way promote_tbls wrote them.  STELBO1B is in
-- its OWN table (data/STELBO1.LOD's sidecar), which is the record this rig
-- exists to prove reached the ROM at all - a missing STELBO1.TBL is a named
-- refusal here, not a quiet pass.
local PIECE = {}          -- "WxH" -> label (first piece of a frame; unique)
local BYSAG = {}          -- SAG -> label (STELBO2B and STELBO3B are both
                          --   28x130, so size alone MISLABELS the log)
local GEOM = {}           -- label -> {w, h, sag}
do
    local function scan(path)
        local fh = io.open(path, "r")
        if not fh then return false end
        local pending
        for line in fh:lines() do
            local n = line:match("^(STELBO%d[AB]):")
            if n then
                pending = n
            elseif pending then
                local w, h = line:match("^%s+%.word%s+(%-?%d+),(%-?%d+),")
                if w then
                    GEOM[pending] = { w = tonumber(w), h = tonumber(h) }
                    if not PIECE[w .. "x" .. h] then PIECE[w .. "x" .. h] = pending end
                else
                    local sag = line:match("^%s+%.long%s+0(%x+)[Hh]")
                    if sag then
                        GEOM[pending].sag = tonumber(sag, 16)
                        BYSAG[tonumber(sag, 16)] = pending
                        pending = nil
                    end
                end
            end
        end
        fh:close()
        return true
    end
    if not scan(ROOT .. "/src/MKST.TBL") then log("FATAL: no src/MKST.TBL"); missing = true end
    if not scan(ROOT .. "/src/STELBO1.TBL") then log("FATAL: no src/STELBO1.TBL"); missing = true end
    for i = 1, 5 do
        for _, s in ipairs({ "A", "B" }) do
            local n = "STELBO" .. i .. s
            if not GEOM[n] then log("FATAL: %s has no record in the build", n); missing = true end
        end
    end
end

local ELBOW, CHAIN = 24, 42      -- stk_stelbow's 24, plus 24*3/4 = 18

local TESTS = {
    -- link = ticks after the first HP at which the SECOND HP is tapped.  The
    -- window is stel_win_skip+1..stel_win AFTER CONTACT, and contact is a few
    -- ticks after the press, so 10 lands inside it wherever the press does.
    { at = 140, label = "elbo", gap = 50, want = ELBOW, chain = false, win = 90 },
    { at = 320, label = "dual", gap = 50, want = CHAIN, chain = true,  win = 90, link = 10 },
    { at = 500, label = "cool", gap = 50, want = ELBOW, chain = false, win = 90, link = 10, stamp = true },
    -- spam: the MASHER.  HP, then HP again and again after the link window
    -- has shut - a fresh elbow each time, no chain.  The first stuns him in
    -- place; the second lands while he is still reeling from it and must be
    -- retail's elbow and THROW HIM CLEAR (st_elbow_spam, MKSTEL.ASM), or the
    -- elbow loops.  Inside st_chain_cool so a press cannot link instead.
    { at = 680, label = "spam", gap = 50, want = CHAIN, chain = false, win = 90,
      mash = { 16, 22, 28 }, stamp = true, spam = true },
}
-- THE INPUTS ARE NOT TOUCHED.  Flipping t.link as well would run a different
-- trial and then expect the flipped answer, which passes trivially - measured,
-- the first cut of this control "failed" only the one trial whose inputs it
-- happened not to change.  Cross the EXPECTATION against the SAME press.
if NEG then
    for _, t in ipairs(TESTS) do
        t.chain = not t.chain
        t.want = t.chain and CHAIN or ELBOW
    end
end

local RUN_END = 820

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local failures = 0
local st, results = {}, {}

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function obj_x(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + O_OXPOS)) end
local function set_x(p, x) local o = r32(p); if o ~= 0 then w16(o + O_OXPOS, x) end end
local function wtlx() return s16(r16(A.worldtlx + 16)) end
local function p1_action()
    local proc = r32(A.p1_proc)
    if proc == 0 then return 0xffff end
    return r16(proc + P_ACTION)
end

-- Every piece the DMA was handed this tick.  A FIGHTER IS MULTIPART: its own
-- osize fields are 0 and the pieces are 112-bit nodes in the process's shape
-- RAM at *obj(oimg).  The walk ends on a zero node, capped at mp_max.
local function pieces(objp)
    local obj = r32(objp)
    if obj == 0 then return nil end
    if r16(obj + O_OSIZEX) ~= 0 then return nil end   -- single-part: not one of ours
    local mp = r32(obj + O_OIMG)
    if mp == 0 then return nil end
    local out = {}
    for i = 0, MP_MAX - 1 do
        local node = mp + i * MP_LENGTH
        local sag = r32(node + MP_SAG)
        if sag == 0 then break end
        local w, h = r16(node + MP_SIZEX), r16(node + MP_SIZEY)
        out[#out + 1] = { sag = sag, w = w, h = h, key = w .. "x" .. h,
                          label = BYSAG[sag] or PIECE[w .. "x" .. h] }
    end
    if #out == 0 then return nil end
    return out
end

-- The elbow frame on screen: 1..5, or nil for anything that is not one.
local function elbow_frame(ps)
    if not ps then return nil end
    local l = ps[1].label
    if not l then return nil end
    local n = l:match("^STELBO(%d)A$")
    return n and tonumber(n) or nil
end

local function names(ps)
    local z = {}
    for _, p in ipairs(ps) do z[#z + 1] = p.label or p.key end
    return table.concat(z, ",")
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
        if st[t.label] and name == "P1 High Punch" then
            -- the elbow: HP tapped close with the STICK NEUTRAL.  is_stick_away
            -- turns joy_hi_punch into the power punch before elbow_check is
            -- ever reached, so no direction is held in any trial.
            if d >= 0 and d < 3 then return true end
            local L = t.link
            if L and d >= L and d < L + 3 then return true end
            for _, M in ipairs(t.mash or {}) do
                if d >= M and d < M + 3 then return true end
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
        for i = 1, 5 do
            local a, b = GEOM["STELBO" .. i .. "A"], GEOM["STELBO" .. i .. "B"]
            if a and b then
                log("  STELBO%dA %dx%d   STELBO%dB %dx%d", i, a.w, a.h, i, b.w, b.h)
            end
        end
        if missing then finish(false, "missing_symbols_or_records"); return end
    end
    if not space or finished then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_ST); w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d (hovering Shang Tsung)", frame)
        end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_ST); w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d curback=%d", r16(A.p1_char), r16(A.p2_char), r16(A.curback))
        if r16(A.p1_char) ~= FT_ST then finish(false, "p1_char_overwrite_failed"); return end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end
        w16(A.p1_bar, MAX_HP)

        local measuring = false
        for _, t in ipairs(TESTS) do
            local d = r - t.at
            if d >= -30 and d < 0 then
                -- Park the PAIR, not just P1.  A trial that inherits the last
                -- one's drift can open in a corner, where the edge clamp stops
                -- the victim sliding and the second elbow connects on a man it
                -- would miss in open space.
                measuring = true
                local base = wtlx() + 200
                set_x(A.p2_obj, base)
                set_x(A.p1_obj, base - t.gap)
                w16(A.p2_bar, MAX_HP)
            elseif d == 0 then
                measuring = true
                -- "just chained": st_chain_cool is measured off l_stchain, so
                -- stamp it rather than race the previous trial's own chain.
                if t.stamp then w16(A.l_stchain, r16(A.tick)) end
                st[t.label] = { bar0 = r16(A.p2_bar), minbar = r16(A.p2_bar),
                                seq = {}, last = nil, nhits = 0 }
                -- THE OPENING GAP, so the pushback below is measured as a
                -- CHANGE rather than against a constant the rig's own parking
                -- happens to produce.
                st[t.label].dist0 = math.abs((obj_x(A.p1_obj) or 0)
                                             - (obj_x(A.p2_obj) or 0))
                st[t.label].maxdist = st[t.label].dist0
                log("%-5s start: gap=%d l_stchain=%d tick=%d", t.label,
                    st[t.label].dist0, r16(A.l_stchain), r16(A.tick))
            elseif d > 0 and d <= t.win then
                measuring = true
                local s = st[t.label]
                local ps = pieces(A.p1_obj)
                local f = elbow_frame(ps)
                if f and f ~= s.last then
                    s.seq[#s.seq + 1] = f
                    log("  %-5s +%2d  STELBO%d  pieces=%d (%s)  p1act %04x  dist=%s",
                        t.label, d, f, #ps, names(ps), p1_action(),
                        tostring(math.abs((obj_x(A.p2_obj) or 0) - (obj_x(A.p1_obj) or 0))))
                    if f == 1 then
                        s.pieces1 = #ps
                        s.p1b = ps[2] and (ps[2].label or ps[2].key) or "-"
                    end
                end
                if f then s.last = f end
                -- Every tick, not only on a frame change: the push happens
                -- after the last frame the lane draws.
                local gap = math.abs((obj_x(A.p2_obj) or 0) - (obj_x(A.p1_obj) or 0))
                if gap > s.maxdist then s.maxdist = gap end
                local b = r16(A.p2_bar)
                if b < s.minbar then s.nhits = s.nhits + 1; s.minbar = b end
                if SNAP and t.chain and d % 2 == 0 and d <= 40 then
                    shot(string.format("stel_%s_%03d", t.label, d))
                end
                if d == t.win then
                    local dmg = s.bar0 - s.minbar
                    local seq = table.concat(s.seq, ",")
                    -- THE ORDER, as a string.  The first elbow is 1,2 and the
                    -- second 3,4,5 (part 4's recovery repeats 4, so a linked
                    -- chain reads 1,2,3,4,5,4).  An unlinked elbow retracts on
                    -- the wind-up and must reach neither 3 nor 4 nor 5.
                    local want = t.chain and "1,2,3,4,5[,4]" or "1,2[,1]"
                    local order_ok
                    if t.spam then
                        -- two whole elbows; dmg 24 + 24*3/4 proves the second
                        -- landed on a man still in the first one's string.
                        want = "1,2,1,2[,1]"
                        order_ok = (seq == "1,2,1,2" or seq == "1,2,1,2,1")
                    elseif t.chain then
                        order_ok = seq:match("^1,2,3,4,5") ~= nil
                    else
                        order_ok = (seq == "1,2" or seq == "1,2,1")
                    end
                    local saw_second = seq:find("3") ~= nil
                    -- st_elbow_2 burns part 2 with no sleep between the calls,
                    -- so the wind-up must not reappear once the chain is under
                    -- way.  A burn that slept would read 1,2,1,3,4,5.
                    local no_rewind = (not t.chain) or (seq:match("^1,2,1") == nil)
                    -- STELBO1B is the record data/STELBO1.LOD exists for: with
                    -- it unpacked the frame is one piece and the order check
                    -- still passes, because the first piece is STELBO1A either
                    -- way.
                    local two_pieces = (s.pieces1 == 2) and (s.p1b == "STELBO1B")
                    -- EVERY TRIAL ENDS WITH HIM THROWN CLEAR: an unlinked elbow
                    -- is retail's r_saelbow again (it was the stun on every
                    -- elbow that let a mashed HP loop), and a chain ends on
                    -- stk_stelbow_end.  The stun is proved by dmg == CHAIN -
                    -- a pushed first elbow leaves the second nothing to hit.
                    -- (History: THE SECOND ELBOW THROWS HIM AWAY AND THE FIRST DOES NOT.)
                    -- stk_stelbow gives up retail's pushback so the second
                    -- swing can reach a man the first one hit; stk_stelbow_end
                    -- puts r_saelbow back, because nothing has to reach after
                    -- the hit that ENDS the chain.  So a linked chain must
                    -- leave him clear and an unlinked elbow must not - which
                    -- is also the control for the stun: if BOTH pushed, the
                    -- chain would be reaching a man who had been thrown 118px.
                    -- Measured 78px against 0; the threshold sits between.
                    local push = s.maxdist - s.dist0
                    local pushed = push >= 40
                    local ok = order_ok and two_pieces and dmg == t.want
                               and (saw_second == t.chain) and no_rewind
                               and (pushed == (t.chain or t.spam or false))
                    local line = string.format(
                        "%s frames=[%s] (want %s)  STELBO1 pieces=%s 2nd=%s  second_elbow=%s(want %s)  rewind=%s  push=%d/%s(want %s)  dmg=%d(want %d) hits=%d",
                        ok and "OK  " or "FAIL", seq, want,
                        tostring(s.pieces1), tostring(s.p1b),
                        tostring(saw_second), tostring(t.chain),
                        tostring(not no_rewind),
                        push, tostring(pushed), tostring(t.chain or t.spam or false),
                        dmg, t.want, s.nhits)
                    results[t.label] = line
                    if not ok then failures = failures + 1 end
                    log("%-5s %s", t.label, line)
                end
            end
        end
        if not measuring then w16(A.p2_bar, MAX_HP) end

        if r > RUN_END then
            if NEG then
                -- crossed: every trial must have failed
                finish(failures == #TESTS,
                       failures == #TESTS and "crossed_expectation_fails_every_trial"
                                          or "crossed_expectation_still_passed")
            else
                finish(failures == 0,
                       failures == 0 and "frames_are_the_authored_pair" or "mismatch")
            end
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 6000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
