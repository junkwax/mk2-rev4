-- combo_count_test.lua
--
-- WHAT COUNTS AS A COMBO HIT (cmbrules, MAINEQU.ASM; doc/COMBO_COUNTING_RULES.md).
--
-- UMK3's r_hi_punch / r_lo_punch bump p_block and then hand their p_hit
-- straight back (dec_my_p_hit), so an ordinary jab is not a combo hit: it does
-- not show in the KOMBO KOUNTER and it is not taxed by dmgscale.  MK2 counted
-- everything.  This measures that the port took, and - the part that matters -
-- that the counter STILL WORKS for everything else.
--
-- Jax is P1 throughout.  His three relevant strike records (MKSTK.ASM) are
-- what make this measurable without a second ROM:
--
--   stk_jxhipunch   hit reaction 02h = r_hipunched   11 damage
--   stk_jxlopunch   hit reaction 03h = r_lopunched    8 damage
--   stk_jxhikick    hit reaction 00h = r_hikicked    32 damage
--
-- THREE INDEPENDENT SIGNALS PER TRIAL, so no single one can carry a false pass:
--
--   phit_peak   the VICTIM's p_hit, sampled every frame.  A jab's inc and its
--               dec both happen before animate_a9's first sleep, i.e. inside
--               ONE tick, so a jab can never be caught at 1 - it reads 0 for
--               the whole reaction.  A kick reads 1 until back_to_normal.
--   pblk_peak   the VICTIM's p_pblock (pdata+288h), the new cheap-hit counter.
--   dmg per hit 11 for every jab of a LINKED string.  This is the strongest
--               signal and needs no A/B ROM: before cmbrules the second jab
--               of a string was dmgscale's 3/4 = 8, because p_hit had climbed
--               to 1.  11 twice means dmgscale never saw it.
--
-- `kick` IS THE CONTROL and it is not optional.  Jab trials alone cannot tell
-- "jabs are excluded" from "the counter is broken" - both read zero.  The kick
-- must come back phit_peak=1 / pblk_peak=0, the exact inverse, on the same
-- harness in the same fight.  It also CALIBRATES the cmb_hits detector: if a
-- kick does not move cmb_hits then the KOMBO KOUNTER is off in this CMOS and
-- the "no readout on a jab string" check is vacuous, so it is reported
-- NO VERDICT rather than passed.
--
--   CMBC_LOG  log file path      CMBC_MAP  the mk2.map that matches the zip
--   CMBC_STAGE  a curback id to force

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("CMBC_LOG") or (ROOT .. "/tools/combo_count_test.log")
local STAGE = tonumber(os.getenv("CMBC_STAGE") or "")
local GAP = tonumber(os.getenv("CMBC_GAP") or "") or 70
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[cmbc] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(os.getenv("CMBC_MAP") or (ROOT .. "/src/mk2.map"), "r")
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
    p2_proc = sym("p2_proc"), p2_char = sym("p2_char"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), curback = sym("curback"),
    cmb_hits = sym("cmb_hits"), f_kmbcnt = sym("f_kmbcnt"),
}
local missing = false
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k); missing = true end end

-- pdata = 100h (MAINEQU.ASM), so these are process-block BIT offsets.
local P_HIT       = 0x100 + 0x270   -- (8) hit count         -> 0x370
local P_SCALEBIAS = 0x100 + 0x280   -- (8) dmgscale credit   -> 0x380
local P_PBLOCK    = 0x100 + 0x288   -- (8) cheap-hit count   -> 0x388
local OXPOS = 0x90
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KANG, FT_JAX, MAX_HP = 1, 11, 0xa1
-- hudcmb_min (MAINEQU.ASM): hits before the KOMBO KOUNTER draws at all.  ONE
-- hit is not a combo, so cmb_hits sitting at 1 is not a readout - the check
-- below is that a jab string never REACHES this, not that it never moves.
local HUDCMB_MIN = 2
local D_HP, D_LP, D_HK = 11, 8, 32  -- stk_jxhipunch / jxlopunch / jxhikick hit damage

-- GAP 70 IS THE WHOLE REASON THIS RIG WORKS, and the first cut got it wrong.
-- MK2 swaps in CLOSE variants: elbow_check and knee_check (JOY.ASM) both bail
-- only when x_dist > 040h, so at 46 px a High Punch is Jax's ELBOW
-- (stk_jxelbow, 24 dmg, reaction 0Fh) and a High Kick is his KNEE
-- (stk_jxknee, 16, reaction 0Eh).  Reactions 02h/03h - the ones cmbrules
-- touches - never fired at all, and the rig reported FAIL on a correct ROM.
-- 70 is past that gate (>64) and still inside every box being tested:
-- stk_jxhipunch reaches 88, stk_jxlopunch 90, stk_jxhikick 118.  It is also
-- out of throw range, so a Low Punch here is a body punch, not MK2's throw.

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local failures, noverdict = 0, 0
local st, results = {}, {}
local kick_moved_cmb = nil

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

-- read_u16 aligns DOWN to a 16-bit boundary, so it CANNOT be used for
-- p_pblock: 0x388 would align to 0x380 and hand back p_scalebias in the low
-- byte.  read_u8 first; the fallback takes the HIGH byte of that pair.
local function rd8(addr)
    if not space then return 0 end
    local ok, v = pcall(function() return space:read_u8(addr) end)
    if ok and v then return v & 0xff end
    local word = space:read_u16(addr - (addr % 16))
    if (addr % 16) ~= 0 then return (word >> 8) & 0xff end
    return word & 0xff
end
local function victim(field)
    local proc = r32(A.p2_proc)
    if proc == 0 then return 0 end
    return rd8(proc + field)
end
local function obj_x(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function set_x(p, x) local o = r32(p); if o ~= 0 then w16(o + OXPOS, x) end end
local function wtlx() return s16(r16(A.worldtlx + 16)) end

-- Trials.  `taps` = {button, tick-after-start}.  A press lands about 10 ticks
-- later and r_hipunched holds the victim about 12, so jabs are tapped every 10
-- to link without the rig having to guess one exact frame.  Whether they DID
-- link is measured, not assumed: p_pblock's peak says so, and a trial that
-- never linked is reported NO VERDICT.
local TESTS = {
    { at = 120, label = "jab1",  gap = GAP, win = 120,
      taps = { {"P1 High Punch", 0} },
      want = { hits = 1, phit = 0, pblk = 1, dmg = {D_HP} } },
    { at = 300, label = "jabs",  gap = GAP, win = 120,
      taps = { {"P1 High Punch", 0}, {"P1 High Punch", 10}, {"P1 High Punch", 20},
               {"P1 High Punch", 30}, {"P1 High Punch", 40}, {"P1 High Punch", 50},
               {"P1 High Punch", 60} },
      -- Seven taps, to drive p_pblock past ccp3's stick-HELD threshold of 6
      -- (punch_stumble_check's a5 for a high punch).  The stick is never
      -- touched, so 6 is the one in force, not the pull-away 4.
      want = { phit = 0, pblk_min = 2, all_dmg = D_HP, watch_sep = 6 } },
    { at = 480, label = "kick",  gap = GAP, win = 120,
      taps = { {"P1 High Kick", 0} },
      want = { hits = 1, phit = 1, pblk = 0, dmg = {D_HK} }, control = true },
    { at = 660, label = "mixed", gap = GAP, win = 120,
      taps = { {"P1 High Punch", 0}, {"P1 High Punch", 10}, {"P1 High Kick", 20} },
      want = { phit = 1, pblk_min = 1 } },
    { at = 840, label = "lopun", gap = GAP, win = 120,
      taps = { {"P1 Low Punch", 0} },
      want = { hits = 1, phit = 0, pblk = 1, dmg = {D_LP} } },
}
local RUN_END = 1000
local PARK = 30

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- results ----")
    for _, t in ipairs(TESTS) do log("%-6s %s", t.label, results[t.label] or "NOT REACHED") end
    log("kounter detector: %s", kick_moved_cmb == nil and "untested"
        or (kick_moved_cmb and "LIVE (a kick moved cmb_hits)" or "OFF - cmb check is NO VERDICT"))
    log("%s reason=%s failures=%d noverdict=%d", ok and "PASS" or "FAIL", reason, failures, noverdict)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 High Punch"] = true, ["P1 Low Punch"] = true, ["P1 High Kick"] = true,
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
        if st[t.label] then
            local d = r - t.at
            for _, tap in ipairs(t.taps) do
                if tap[1] == name and d >= tap[2] and d < tap[2] + 3 then return true end
            end
        end
    end
    return false
end

local function judge(t, s)
    local w, msgs, ok = t.want, {}, true
    local n = #s.hits
    local dmgs = {}
    for _, h in ipairs(s.hits) do table.insert(dmgs, h.dmg) end

    if n == 0 then
        results[t.label] = string.format("NOT REACHED (no hit landed in %d ticks)", t.win)
        if t.advisory then noverdict = noverdict + 1 else failures = failures + 1 end
        log("%-6s %s", t.label, results[t.label])
        return
    end

    -- A string that never linked proves nothing either way: NO VERDICT, not a pass.
    if w.pblk_min and s.pblk < w.pblk_min then
        results[t.label] = string.format(
            "NO VERDICT p_pblock peak=%d (<%d) - the string did not link; hits=%d dmg=%s",
            s.pblk, w.pblk_min, n, table.concat(dmgs, "+"))
        noverdict = noverdict + 1
        log("%-6s %s", t.label, results[t.label])
        return
    end

    if w.hits and n ~= w.hits then
        ok = false; table.insert(msgs, string.format("hits=%d want %d", n, w.hits))
    end
    if w.phit ~= nil and s.phit ~= w.phit then
        ok = false; table.insert(msgs, string.format("p_hit peak=%d want %d", s.phit, w.phit))
    end
    if w.pblk ~= nil and s.pblk ~= w.pblk then
        ok = false; table.insert(msgs, string.format("p_pblock peak=%d want %d", s.pblk, w.pblk))
    end
    if w.dmg then
        for i, want in ipairs(w.dmg) do
            if dmgs[i] ~= want then
                ok = false
                table.insert(msgs, string.format("dmg[%d]=%s want %d", i, tostring(dmgs[i]), want))
            end
        end
    end
    if w.all_dmg then
        for i, got in ipairs(dmgs) do
            if got ~= w.all_dmg then
                ok = false
                table.insert(msgs, string.format(
                    "dmg[%d]=%d want %d (dmgscale taxed a jab)", i, got, w.all_dmg))
            end
        end
    end
    if t.control then kick_moved_cmb = (s.cmbmax or 0) > 0 end

    local sep = ""
    if w.watch_sep then
        -- Whether the threshold is REACHED is reported, not asserted.  Reaching ccp3's threshold needs the victim to
        -- stay linked that long, which depends on spacing the rig does not own;
        -- what matters is that the number the check reads is p_pblock, and that
        -- is already pinned above.
        sep = string.format("  sep_thresh=%d reached=%s maxdist=%d p_hit_after_sep=%d",
                            w.watch_sep, tostring(s.pblk >= w.watch_sep), s.maxdist or 0,
                            s.phit_after or 0)
    end
    results[t.label] = string.format(
        "%s hits=%d dmg=%s p_hit_peak=%d p_pblock_peak=%d cmb=%d%s%s",
        ok and "OK  " or "FAIL", n, table.concat(dmgs, "+"), s.phit, s.pblk,
        s.cmbmax or 0, sep, #msgs > 0 and ("  [" .. table.concat(msgs, "; ") .. "]") or "")
    if not ok then failures = failures + 1 end
    log("%-6s %s", t.label, results[t.label])
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
        w16(A.p1_char, FT_JAX); w16(A.p2_char, FT_KANG)
        if STAGE then w16(A.curback, STAGE) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d", frame)
        end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_JAX); w16(A.p2_char, FT_KANG)
        if STAGE then w16(A.curback, STAGE) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d curback=%d f_kmbcnt=%d",
            r16(A.p1_char), r16(A.p2_char), r16(A.curback), r16(A.f_kmbcnt))
        if r16(A.p1_char) ~= FT_JAX then finish(false, "p1_char_overwrite_failed"); return end
    end

    if fighting_frame == 0 then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        if frame > 6000 then finish(false, "never_reached_fight") end
        return
    end

    local r = frame - fighting_frame
    if A.diff then w16(A.diff, 0) end
    w16(A.p1_bar, MAX_HP)

    local measuring = false
    for _, t in ipairs(TESTS) do
        local d = r - t.at
        if d >= -PARK and d < 0 then
            -- Park the PAIR, not just P1: parking one lets a trial inherit the
            -- previous one's drift into a corner, where the edge clamp stops
            -- the victim sliding and a string connects that would miss in open
            -- space.  That trap cost the LK chain rig a whole cycle.
            measuring = true
            local base = wtlx() + 200
            set_x(A.p2_obj, base)
            set_x(A.p1_obj, base - t.gap)
            w16(A.p2_bar, MAX_HP)
            w16(A.cmb_hits, 0)
        elseif d == 0 then
            measuring = true
            st[t.label] = { bar = r16(A.p2_bar), phit = 0, pblk = 0, bias = 0,
                            hits = {}, cmbmax = 0, lastph = 0, lastpb = 0 }
            log("%-6s start gap=%d p2_bar=%d cmb_hits=%d", t.label,
                math.abs((obj_x(A.p1_obj) or 0) - (obj_x(A.p2_obj) or 0)),
                r16(A.p2_bar), r16(A.cmb_hits))
        elseif d > 0 and d <= t.win then
            measuring = true
            local s = st[t.label]
            local ph, pb, bi = victim(P_HIT), victim(P_PBLOCK), victim(P_SCALEBIAS)
            if pb > s.pblk then s.pblk = pb end
            -- THE JAB THAT TRIPS THE SEPARATION KEEPS ITS HIT, in this build and
            -- in UMK3 both, so p_hit is only sampled below that threshold.
            --
            -- pblk_stumble_check does `pull a0 / jruc separate_us` - no return -
            -- so the `callr dec_my_p_hit` on the next line never runs for that
            -- one jab.  UMK3 is identical by construction: ccp3 is
            -- reaction_start's ccroutine, so it runs BEFORE r_hi_punch's own
            -- dec_my_p_hit, and its stumble_back_vel -> reaction_exit never
            -- comes back either.  The stranded p_hit=1 lives only for that
            -- reaction - reaction_exit's back_to_normal clears it.
            --
            -- Asserting p_hit==0 across the whole window instead reported FAIL
            -- on a correct ROM: measured 0 for jabs 1-5 and 1 on jab 6, the one
            -- that separated the players (dist 70 -> 150).
            local thresh = t.want.watch_sep
            if thresh and pb >= thresh then s.sepd = true end
            if s.sepd then
                if ph > (s.phit_after or 0) then s.phit_after = ph end
            elseif ph > s.phit then
                s.phit = ph
            end
            if bi > s.bias then s.bias = bi end
            if ph ~= s.lastph or pb ~= s.lastpb then
                log("  %-6s +%2d  p_hit %s->%d  p_pblock %s->%d",
                    t.label, d, tostring(s.lastph), ph, tostring(s.lastpb), pb)
                s.lastph, s.lastpb = ph, pb
            end
            local dist = math.abs((obj_x(A.p1_obj) or 0) - (obj_x(A.p2_obj) or 0))
            if dist > (s.maxdist or 0) then s.maxdist = dist end
            local bar = r16(A.p2_bar)
            if bar < s.bar then
                table.insert(s.hits, { d = d, dmg = s.bar - bar, phit = ph, pblk = pb })
                log("  %-6s +%2d HIT -%d  p_hit=%d p_pblock=%d bias=%d cmb=%d dist=%d",
                    t.label, d, s.bar - bar, ph, pb, bi, r16(A.cmb_hits), dist)
                s.bar = bar
            end
            local c = r16(A.cmb_hits)
            if c > s.cmbmax then s.cmbmax = c end
            if d == t.win then judge(t, s) end
        end
    end
    if not measuring then w16(A.p2_bar, MAX_HP) end

    if r > RUN_END then
        -- The jab trials' "no readout" claim only means something if the
        -- producer is alive, which the kick control is what proves.
        local jabs = st["jabs"]
        if kick_moved_cmb == false then
            log("NOTE: cmb_hits never moved even on the kick control - the KOMBO")
            log("      KOUNTER is off in this CMOS, so 'no readout on a jab")
            log("      string' is NO VERDICT, not a pass.")
            noverdict = noverdict + 1
        elseif kick_moved_cmb and jabs and jabs.cmbmax >= HUDCMB_MIN then
            log("FAIL: a jab string reached cmb_hits=%d, the readout threshold", jabs.cmbmax)
            failures = failures + 1
        elseif jabs then
            log("kounter: a %d-jab string held cmb_hits at %d - below hudcmb_min %d,",
                #jabs.hits, jabs.cmbmax, HUDCMB_MIN)
            log("         so no readout appears.  Each jab opens a NEW string,")
            log("         because hud_combo_hit reads the victim's p_hit and a")
            log("         jab always leaves it zero.")
        end
        finish(failures == 0, failures == 0 and "jabs_excluded_counter_still_live" or "mismatch")
        return
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 9000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
