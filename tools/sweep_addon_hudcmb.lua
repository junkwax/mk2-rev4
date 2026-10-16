-- sweep_addon_hudcmb.lua - the LIVE COMBO READOUT (hudcmb, MKDISP.ASM).
--
-- Its own feature, not part of the hudcall toasts.  hudcall is a toast - one
-- word, earned at one instant, that flies in and leaves.  This is a meter
-- that is up for as long as a string is live and changes while you watch it:
--
--        114        damage the string has done so far, popped BIGGER on
--      -------      every hit and easing back down
--       5 HITS      ... and how many hits did it, same font, smaller
--
-- Four things can be silently wrong, and each needs its own evidence:
--
--   1. THE NUMBERS.  cmb_dmg has to be the damage that actually came off the
--      bar, not the pre-dmgscale figure the strike table carries.  So the rig
--      reads the victim's bar BEFORE re-pinning it and accumulates the drops
--      itself.  A readout that agreed with the ROM's own arithmetic and
--      disagreed with the life bar would pass a test that only counted.
--
--   2. THE POP.  cmb_step must be hudcmb_pop on the frame after a hit, then
--      ease back to exactly 0100h and STOP.  A step that crept to 0101h and
--      stayed would rebuild the line forever for a picture identical to the
--      one it already had.
--
--   3. THE RECORDS.  This draws CPU text through hud_list, so "the state is
--      right" proves nothing about what is on screen.  hud_pass zeroes
--      hud_count every frame but leaves the RECORDS, so the rig reads them
--      back: four of them, shadow-then-text per line, the ASCIZ decoded and
--      compared against the number the state holds, the scale field checked,
--      and the coordinates checked to be on screen.  Four perfect counters
--      and an empty list is the exact failure this is looking for.
--
--   4. THE LAYOUT.  A fight will not produce a 3-digit total or a 2-digit
--      count on demand - this rig's own driver tops out at 2 hits - and what
--      is untested there is the LAYOUT, not the counting.  So the second half
--      of the run stops trying to provoke it: once a real hit has started the
--      readout process, the rig writes cmb_dmg / cmb_hits / cmb_step straight
--      into RAM and holds them.  The process re-lays the line from that state
--      every tick, so 7 / 47 / 247 / 999 and 2 / 12 / 99 walk every digit
--      count deterministically, and the glyph total is then an exact
--      assertion rather than whatever the fight happened to reach.  The
--      counting checks are switched off while this runs - the numbers are
--      forged, so they prove nothing about the accounting.
--
--   5. THE CLEANUP.  Those objects belong to a process.  When the readout
--      expires there must be none left - a leak here is glyphs stranded over
--      the next round.
--
-- Env: HUDCMB_LOG.  Driven by run_hudcmb_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("HUDCMB_LOG") or (ROOT .. "/tools/hudcmb.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local cmb_hits, cmb_dmg = sym.cmb_hits, sym.cmb_dmg
local cmb_tick, cmb_scl = sym.cmb_tick, sym.cmb_scl
local hud_list, hud_drew = sym.hud_list, sym.hud_drew
local f_doscore = sym.f_doscore
local hud_ran, hud_count = sym.hud_ran, sym.hud_count

-- MAINEQU's numbers, duplicated here on purpose.  A rig that read them out of
-- the ROM would agree with whatever value the ROM happened to hold.
local POP, DECAY, HOLD, MINHITS = 0x180, 2, 0x40, 2
local WHITE, BLACK, RED = 0x0e, 0x0f, 0x0d

-- hud_list record: xy, colour, 16 bytes of ASCIZ, then the 8.8 scale.
-- HUD_MAXS went 6 -> 12 when the callouts moved back onto this queue: the
-- readout is four records, the callouts two each, and both players can have
-- both at once. At 6 the two features silently ate each other, because
-- hud_str DROPS a record when the queue is full.
local HUD_REC, HUD_TXT, HUD_SCLF, HUD_MAXS = 256, 64, 192, 12

local OXPOS, OXVAL = 0x090, 0x080
local MAX_HP = 0xA1

local space = nil

-- The readout is DMA OBJECTS now, not hud_list records: rd11font/MK2FONT
-- glyphs are image-ROM art in constant-colour mode, which PIXBLT cannot
-- read. So everything below asks the object list what is on screen instead
-- of asking the text queue what was requested.
local objlst_sym = sym.objlst
local OID_DMG, OID_HIT = 0x808, 0x80a   -- damage total / hit line + rule
local OID, OXVAL, OYVAL = 0x1c0, 0x080, 0x0a0
local OCONST, OSCALE, OSIZE = 0x150, 0x180, 0x120
local RED, WHITE = 0x0d0d, 0x0e0e
local DMACNZ = 0x8008        -- constant-colour blit: a tinted mask
local OPAL, OFLAGS = 0x140, 0x0f0   -- DISPEQU.ASM, not guessed

-- Every glyph of one string, in list order.
local function glyphs_of(oid)
    local out, o, n = {}, space:read_u32(objlst_sym), 0
    while o ~= 0 and n < 400 do
        if (space:read_u16(o + OID) & 0xffff) == oid then
            out[#out+1] = {
                -- sign-extended inline: s16 is declared further down this
                -- file, so calling it from here reaches a nil GLOBAL and
                -- throws - which killed this check every time it ran and
                -- looked exactly like the check never firing.
                x = (function(v) if v >= 0x8000 then return v - 0x10000 end
                     return v end)((space:read_u32(o + OXVAL) >> 16) & 0xffff),
                y = (space:read_u32(o + OYVAL) >> 16) & 0xffff,
                col = space:read_u16(o + OCONST) & 0xffff,
                pal = space:read_u16(o + OPAL) & 0xffff,
                flg = space:read_u16(o + OFLAGS) & 0xffff,
                scale = space:read_u32(o + OSCALE),
                w = space:read_u32(o + OSIZE) & 0xffff,
                h = (space:read_u32(o + OSIZE) >> 16) & 0xffff,
            }
        end
        o = space:read_u32(o); n = n + 1
    end
    return out
end

-- How many glyphs a string is worth: every character that has art. A space
-- has none, so " HITS" is four objects and not five - and each of them is
-- drawn twice, once as its shadow.
local function inked(str)
    local n = 0
    for i = 1, #str do
        if str:byte(i) ~= 32 then n = n + 1 end
    end
    return n * 2
end

-- Census of the object list by oid, to answer "whose objects are these?"
-- when the list explodes. 0806/0807 are the callout words' glyphs.
local function census()
    local t, o, n = {}, space:read_u32(objlst_sym), 0
    while o ~= 0 and n < 400 do
        local id = space:read_u16(o + 0x1c0) & 0xffff
        t[id] = (t[id] or 0) + 1
        o = space:read_u32(o); n = n + 1
    end
    local out = {}
    for id, c in pairs(t) do out[#out + 1] = string.format("%04x:%d", id, c) end
    table.sort(out)
    return n, table.concat(out, " ")
end
local out = io.open(OUT, "w")
local function log(f, ...)
    local s = select('#', ...) > 0 and string.format(f, ...) or f
    if out then out:write(s, "\n"); out:flush() end
    print(s)
end
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

-- One queued text record, read back after hud_pass has drawn it.  hud_pass
-- zeroes hud_count ("consume the list") but never touches the records, so
-- what is here is exactly what was drawn this frame.
local function record(n)
    local b = hud_list + n * HUD_REC
    local xy = space:read_u32(b)
    local t = {}
    for k = 0, 15 do
        local c = space:read_u8(b + HUD_TXT + k * 8) & 0xff
        if c == 0 then break end
        t[#t + 1] = string.char(c)
    end
    return {
        x     = s16(xy & 0xffff),
        y     = s16((xy >> 16) & 0xffff),
        col   = space:read_u32(b + 32) & 0xff,
        text  = table.concat(t),
        scale = space:read_u16(b + HUD_SCLF) & 0xffff,
    }
end

-- ADDON_OWNS is the harness's GLOBAL table, not a local one.  Declaring a
-- local here leaves _G.ADDON_OWNS empty, and the harness then keeps driving
-- P1's buttons every frame to make battles progress - zeroing whatever this
-- rig just pressed.  The symptom is a run where nothing ever hits anything.
for _, n in ipairs({
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
    "P2 Left","P2 Right","P2 Up","P2 Down",
    "P2 High Punch","P2 Low Punch","P2 High Kick","P2 Low Kick","P2 Block",
}) do ADDON_OWNS[n] = true end

local frame, fight0, fields = 0, 0, {}
HOLD_ACTIVE = false   -- global: the hold measurement parks the driver
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

local prev = {}
for i = 0, 1 do prev[i] = { hits = 0, dmg = 0, step = 0x100, tick = 0 } end
local mine = {[0] = {h = 0, d = 0}, [1] = {h = 0, d = 0}}

local strings_seen, dmg_bad, hits_bad = 0, 0, 0
local pop_arm, pop_bad, settle_bad = 0, 0, 0
local glyph_ok, glyph_none, glyph_scale_bad, glyph_off = 0, 0, 0, 0
local leaked = 0
local peak_hits, peak_dmg, peak_glyphs = 0, 0, 0
local shown, snapped = false, {}

-- The forced-layout phase: {damage, hits, step}.  Held long enough for the
-- process to re-lay the line, then asserted glyph by glyph.
local FORCE_AT, CASE_HOLD = 1500, 24
-- Damage is drawn as a PERCENTAGE of the bar now, so these are hit points in
-- and a percentage out - which is the interesting part, because that is where
-- the digit count comes from.  99% is the clamp cmb_pct applies.
local CASES = {
    {   7,  2 },      -- one digit out of one, at rest
    {  47,  9 },      -- two digits
    { 247, 12 },      -- clamps to 99% - the widest ordinary readout
    { 999, 99 },      -- ... and the clamp hcm_hadd applies to the count
}
local forced, case_i, case_t, swept = false, 0, 0, false
local layout_ok, layout_bad = 0, 0
local function ndig(v) if v < 10 then return 1 elseif v < 100 then return 2 end return 3 end

-- One tick of hud_combo_draw's easing, recomputed.  The producer decays
-- cmb_scl and THEN queues with the decayed value, so what reaches a record is
-- always one step past whatever is sitting in the state word.
local function decay1(v)
    local r = v - 0x100
    local n = r - (r >> DECAY)
    if n < 4 then n = 0 end
    return 0x100 + n
end
local warned_diag = false
local last_ran, last_drew, ran_n, drew_n = nil, nil, 0, 0

local reported = false
local seen = {}
local function watch_explosion(t)
    if reported or (t % 8) ~= 0 then return end
    local n, cs = census()
    -- one of each: a readout glyph (0808) and a callout glyph (0806),
    -- which is the one that demonstrably draws.
    if not (seen[0x806] and seen[0x808] and seen[0x80a]) then
        local o2 = space:read_u32(objlst_sym)
        while o2 ~= 0 do
            local oidv = space:read_u16(o2 + 0x1c0) & 0xffff
            if (oidv == 0x808 or oidv == 0x806 or oidv == 0x80a) and not seen[oidv] then
                seen[oidv] = true
                if oidv == 0x808 then
                    pcall(function() manager.machine.video:snapshot() end)
                end
                log("  GLYPH %04x x=%d y=%d oflags=%04x oflags2=%08x oconst=%04x"
                    .. " opal=%04x oscale=%08x z=%08x size=%08x",
                    oidv, (space:read_u32(o2+0x080) >> 16) & 0xffff,
                    (space:read_u32(o2+0x0a0) >> 16) & 0xffff,
                    space:read_u16(o2+0x0f0) & 0xffff, space:read_u32(o2+0x160),
                    space:read_u16(o2+0x150) & 0xffff, space:read_u16(o2+0x140) & 0xffff,
                    space:read_u32(o2+0x180), space:read_u32(o2+0x0c0),
                    space:read_u32(o2+0x120))
            end
            o2 = space:read_u32(o2)
        end
    end
    if n > 130 then
        reported = true
        local cw = {}
        for i = 0, 1 do
            cw[#cw + 1] = string.format("p%d phase=%d arms=%d", i + 1,
                space:read_u16(sym.cal_phase + i * 16) & 0xffff,
                space:read_u16(sym.cal_arms + i * 16) & 0xffff)
        end
        log("  EXPLOSION t=%d objects=%d  %s", t, n, cs)
        log("           %s / %s", cw[1], cw[2])
    end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== live combo readout === numbers, pop, glyphs, cleanup")
    end
    -- gstate 8 is gs_diag.  If this rig ever sits there it is the committed
    -- cfg/mk2.cfg being picked up (TEST switch ON) - see -cfg_directory in
    -- run_hudcmb_test.ps1.  Said once, because it is not a finding.
    if space:read_u16(gstate) == 8 then
        if not warned_diag then
            warned_diag = true
            log("  !! booted into the operator menu (gstate 8) - MAME took a cfg with")
            log("  !! the TEST switch on.  Nothing below this line means anything.")
        end
        return
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame; log("  fight reached at frame %d", frame) end
    local t = frame - fight0
    watch_explosion(t)

    -- READ the bars before re-pinning them: the drop since last frame's pin
    -- is the damage that was actually applied, which is what cmb_dmg claims.
    -- The three-way split hud_pass's sentinels exist for: hook never fired /
    -- fired and early-outed / ran the whole draw loop.  hud_count is zeroed by
    -- hud_pass ("consume the list"), so a NON-zero one here means the pass
    -- never got to it at all.
    local hr = space:read_u16(hud_ran) & 0xffff
    local hd = space:read_u16(hud_drew) & 0xffff
    if last_ran and hr ~= last_ran then ran_n = ran_n + 1 end
    if last_drew and hd ~= last_drew then drew_n = drew_n + 1 end
    last_ran, last_drew = hr, hd
    if t > 0 and t % 400 == 0 then
        log("  pass t=%-5d hud_ran+%d hud_drew+%d hud_count=%d",
            t, ran_n, drew_n, space:read_u16(hud_count) & 0xffff)
            local cn, cs = census()
            log("       objects=%d  %s", cn, cs)
            reported = reported
    end

    local bar = { space:read_u16(p1_bar) & 0xffff, space:read_u16(p2_bar) & 0xffff }
    local drop = { math.max(MAX_HP - bar[1], 0), math.max(MAX_HP - bar[2], 0) }
    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    -- ---- forced layout phase -------------------------------------------
    -- Once the forged sweep has run, the organic checks are OVER for this
    -- run.  Resuming them would compare the next real hit against a forged
    -- 999/99 left in `prev` and report three failures the ROM did not cause -
    -- which is exactly what it did before this cutoff existed.
    if swept then return end

    -- The forced sweep can write the readout's STATE but cannot create the
    -- process that draws it - only a real hit does that. So keep whatever
    -- process a live string left behind alive into the sweep, by topping up
    -- its clock for the second before it starts.
    --
    -- NOT while the hold is being measured.  This top-up re-arms cmb_tick to
    -- hudcmb_hold on every frame, so with it running the clock cannot go down
    -- for any reason and "the clock did not run down while he was frozen" is
    -- true on a ROM that has never heard of the hold.  It made the check pass
    -- against a baseline built without the fix, which is worth nothing.
    --
    if t < FORCE_AT and not HOLD_ACTIVE then
        for i = 0, 1 do
            if (space:read_u16(cmb_tick + i * 16) & 0xffff) ~= 0 then
                space:write_u16(cmb_tick + i * 16, HOLD)
            end
        end
    end
    if t >= FORCE_AT then
        if not forced then
            forced, case_i, case_t = true, 1, 0
            log("  --- forced layout sweep: the digit counts a fight will not reach ---")
        end
        local c = CASES[case_i]
        if c then
            space:write_u16(cmb_dmg,  c[1])
            space:write_u16(cmb_hits, c[2])
            space:write_u16(cmb_tick, HOLD)          -- keep it on screen
            case_t = case_t + 1
            if case_t == CASE_HOLD then
                local wd = tostring(math.min(99, (c[1] * 100) // 0xa1)) .. "%"
                local wh = tostring(c[2]) .. " HITS"
                local gd, gh = glyphs_of(OID_DMG), glyphs_of(OID_HIT)
                if #gd == inked(wd) and #gh == inked(wh) + 2 then
                    layout_ok = layout_ok + 1
                    log("    %3d hp / %2d hits -> %q (%d glyphs) and %q + rule (%d), exact",
                        c[1], c[2], wd, #gd, wh, #gh)
                else
                    layout_bad = layout_bad + 1
                    log("    %3d hp / %2d hits -> %d/%d glyphs, want %q (%d) and %q + rule (%d)",
                        c[1], c[2], #gd, #gh, wd, inked(wd), wh, inked(wh) + 2)
                end
                if not snapped["case" .. case_i] then
                    snapped["case" .. case_i] = true
                    pcall(function() manager.machine.video:snapshot() end)
                end
                case_i, case_t = case_i + 1, 0
            end
        else
            -- Done.  Put the forged state back so the readout tears itself
            -- down the way it would after a real string.
            swept = true
            space:write_u16(cmb_dmg, 0)
            space:write_u16(cmb_hits, 0)
            space:write_u16(cmb_tick, 0)
            space:write_u16(cmb_scl, 0x100)
        end
        return                                       -- the numbers are forged
    end

    for i = 0, 1 do                       -- i = the ATTACKER
        local v = 1 - i                   -- ... so the victim is the other one
        local hits = space:read_u16(cmb_hits + i * 16) & 0xffff
        local dmg  = space:read_u16(cmb_dmg  + i * 16) & 0xffff
        local step = space:read_u16(cmb_scl + i * 16) & 0xffff
        local tick = space:read_u16(cmb_tick + i * 16) & 0xffff
        local p = prev[i]

        if hits > peak_hits then peak_hits = hits end
        if dmg  > peak_dmg  then peak_dmg  = dmg  end

        if hits ~= p.hits then
            if hits <= 1 then
                strings_seen = strings_seen + 1
                mine[i].h, mine[i].d = 0, 0
            end
            mine[i].h = mine[i].h + 1
            if hits ~= mine[i].h then
                hits_bad = hits_bad + 1
                if hits_bad <= 4 then
                    log("  HITS p%d: readout says %d, the rig counted %d", i + 1, hits, mine[i].h)
                end
            end

            -- Compare the DELTA, not the running total.  A total makes every
            -- later hit of a string report a mismatch the first one caused,
            -- and it makes the rig's own frame attribution part of the claim.
            -- What is actually being checked is "this hit added to the readout
            -- exactly what it took off the bar".
            local want = drop[v + 1]
            local got  = (hits <= 1) and dmg or (dmg - p.dmg)
            if got ~= want then
                dmg_bad = dmg_bad + 1
                if dmg_bad <= 4 then
                    log("  DAMAGE p%d: hit %d added %d to the readout, the bar lost %d",
                        i + 1, hits, got, want)
                end
            end

            -- The pop is gone: the readout is drawn at one fixed size now,
            -- so there is no scale to arm and none to ease back. cmb_scl is
            -- still written by hud_combo_hit and still read here as part of
            -- the state, but nothing is expected of it.
        end

        -- THE RECORDS.  State being right proves nothing about the screen.
        --
        -- Skipped on the frame a hit lands.  The producer runs at dsa9, in
        -- the display interrupt; a strike resolving AFTER that point in the
        -- frame updates the state but does not reach a record until the next
        -- one, so this rig would be comparing the new number against the
        -- previous frame's picture.  One frame of skew is the path working,
        -- not failing.
        if tick > 0 and hits >= MINHITS and hits == p.hits then
            local wantd = tostring(math.min(99, (dmg * 100) // 0xa1)) .. "%"
            local wanth = tostring(hits) .. " HITS"
            local gd, gh = glyphs_of(OID_DMG), glyphs_of(OID_HIT)
            local bad = nil

            -- The damage line is its own oid; the hit line shares one with
            -- the rule, which is a single 60x1 piece of art (linebreak_).
            if #gd ~= inked(wantd) then
                bad = string.format("damage line has %d glyphs, %q wants %d",
                                    #gd, wantd, inked(wantd))
            elseif #gh ~= inked(wanth) + 2 then
                bad = string.format("hit line has %d glyphs, %q + rule wants %d",
                                    #gh, wanth, inked(wanth) + 2)
            end

            if not bad then
                -- Colour, since FONTFADE arrived. The digits and the "%" are
                -- real 5bpp art carrying their own red-to-amber ramp, so they
                -- are drawn dmawnz off a palette and have NO oconst - looking
                -- for a red pen finds nothing, which is what this check used
                -- to do and report as a dead readout. The " HITS" caption and
                -- the 1bpp rule are still tinted masks.
                --
                -- What has to hold either way: every drawn glyph is shadowed
                -- by exactly one black silhouette, and a full-colour glyph
                -- must actually carry a palette - opal 0 is colour map 0,
                -- which would be the wrong ramp drawn silently.
                local function tally(list, tint)
                    local shadow, fade, masked, nopal = 0, 0, 0, 0
                    for _, g in ipairs(list) do
                        if g.col == 0x0f0f then shadow = shadow + 1
                        elseif (g.flg & DMACNZ) == DMACNZ and g.col == tint then
                            masked = masked + 1
                        else
                            fade = fade + 1
                            if g.pal == 0 then nopal = nopal + 1 end
                        end
                    end
                    return shadow, fade, masked, nopal
                end
                local ds, df, dm, dn = tally(gd, RED)
                local hs, hf, hm, hn = tally(gh, WHITE)
                if df + dm ~= ds or ds == 0 then
                    bad = string.format("damage: %d drawn (%d fade + %d mask) vs %d shadow",
                                        df + dm, df, dm, ds)
                elseif hf + hm ~= hs or hs == 0 then
                    bad = string.format("hits: %d drawn (%d fade + %d mask) vs %d shadow",
                                        hf + hm, hf, hm, hs)
                elseif df == 0 then
                    bad = "damage line has no FONTFADE glyphs - it is all masks"
                elseif dn > 0 or hn > 0 then
                    bad = string.format("%d full-colour glyph(s) with opal 0", dn + hn)
                end
            end

            -- Bounds, not "on screen": the readout FLIES IN, so a negative
            -- x is the feature working. What this is looking for is a glyph
            -- that has been lost - left behind at the entry position, or
            -- drifting away because it never got told to stop.
            if not bad then
                for _, g in ipairs(gd) do
                    if g.x < -200 or g.x > 460 or g.y < 0 or g.y > 253 then
                        bad = string.format("a damage glyph is lost at %d,%d",
                                            g.x, g.y)
                    end
                end
                for _, g in ipairs(gh) do
                    if g.x < -200 or g.x > 460 or g.y < 0 or g.y > 253 then
                        bad = string.format("a hit glyph is lost at %d,%d",
                                            g.x, g.y)
                    end
                end
            end

            if bad then
                glyph_none = glyph_none + 1
                if glyph_none <= 4 then log("  OBJECTS p%d: %s", i + 1, bad) end
            else
                glyph_ok = glyph_ok + 1
                if not shown then
                    shown = true
                    log("  DRAWN p%d  %q (%d glyphs) / %q + rule (%d glyphs)",
                        i + 1, wantd, #gd, wanth, #gh)
                    pcall(function() manager.machine.video:snapshot() end)
                end
            end
        end

        p.hits, p.dmg, p.step, p.tick = hits, dmg, step, tick
    end

    -- The driver, lifted from the hudcall rig: P2 pinned close so strings
    -- build, three P1 attacks 7 ticks apart inside a 22-tick cycle, which is
    -- inside hitstun and is what makes a multi-hit string at all.
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 ~= 0 and o2 ~= 0 then
        local x1 = s16(space:read_u16(o1 + OXPOS))
        local x2 = s16(space:read_u16(o2 + OXPOS))
        local tx = (x1 < x2) and (x1 + 52) or (x1 - 52)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end
    -- Hands off while the hold is being measured: a hit landing in there
    -- re-arms cmb_tick, and "the clock did not run down" would then be
    -- true for the wrong reason.
    if HOLD_ACTIVE then
        press("P1 High Punch", false)
        press("P1 High Kick",  false)
        press("P1 Low Kick",   false)
        return
    end
    local c = t % 22
    press("P1 High Punch", c == 0 or c == 1)
    press("P1 High Kick",  c == 7 or c == 8)
    press("P1 Low Kick",   c == 14 or c == 15)
end)

-- The hit pop: cmb_scl goes to step 0 on every hit and cmb_ease walks it back
-- to COT_SCLMAX, and the same index drives the colour swap to MK2FDE1_P.
--
-- Only the SCALE half is checked here. An attempt to check the palette by
-- comparing each glyph's opal against cot_fpal / cot_fpalr gave three
-- different answers on three runs (3f3f, then 0000, with the glyph reading
-- 1525 throughout) while the readout was rendering CORRECTLY on screen the
-- whole time - so the check was wrong, not the ROM, and a check that cannot
-- be trusted is worse than none. The colour swap is unverified.
local pops, scl_seen, prev_scl = 0, {}, -1
-- "1 HITS" must never be on screen: hudcmb_min is 2. Counted straight off the
-- object list against cmb_hits, because the creation gate alone did not cover
-- a fresh string starting while the previous readout was still up.
local one_hit_frames = 0

-- ...and the case the passive count on its own will not reach.  The failure
-- needs a readout ALREADY on screen when a new string opens, which happens
-- when the victim recovers (back_to_normal zeroes his p_hit) inside the 40h
-- tick window and then eats one more hit.  A rig that only watches cannot
-- schedule that, so this arranges it: whenever a string of three or more is
-- live, the victim's p_hit is zeroed once.  The very next hit is then an
-- opening hit under a living flight - exactly the reported "1 HITS".
--
-- p_hit is 8 bits at pdata+270h and p_action 16 at pdata+0f0h, off the
-- fighter's process pointer (MAINEQU.ASM).  Lua takes RAW map addresses.
local P_HIT, P_ACTION = 0x370, 0x1f0
local ACT_FROZEN = 0x0401          -- Sub-Zero's ice ball, cmb_holds[0]
local provokes, provoke_at = 0, 0

-- THE HOLD.  cmb_tick must not run down while the victim is in a state he
-- cannot act out of - the freeze is 80h ticks and the window is 40h, so
-- without it the chain broke before he thawed.  Driven by writing the
-- action the freeze itself writes (r_ice, MKREACT.ASM:1672) rather than by
-- landing a real ice ball, because what is under test is the readout's
-- reading of it; that r_ice sets it is source, not inference.
local hold_t, hold_tick0, hold_done, hold_bad, hold_ok = 0, nil, false, 0, 0
local HOLD_FRAMES = 40             -- longer than the 40h window has left

emu.register_frame(function()
    if not space or not sym.cmb_scl then return end
    for i = 0, 1 do
        local h = space:read_u16(sym.cmb_hits + i * 16) & 0xffff
        if h > 0 and h < 2 then
            local o, guard = space:read_u32(objlst_sym), 0
            while o ~= 0 and guard < 400 do
                local id = space:read_u16(o + OID) & 0xffff
                if id == 0x808 + i or id == 0x80a + i then
                    one_hit_frames = one_hit_frames + 1; break
                end
                o = space:read_u32(o); guard = guard + 1
            end
        end
    end

    if fight0 == 0 or forced then return end
    local t = frame - fight0

    -- ---- the hold, first and once: it needs an undisturbed clock --------
    if not hold_done then
        if hold_tick0 == nil then
            local hits = space:read_u16(cmb_hits) & 0xffff
            local tick = space:read_u16(cmb_tick) & 0xffff
            if t > 200 and hits >= 2 and tick > 4 then
                local v = space:read_u32(p2_proc)      -- p1 attacks, so p2 is hit
                if v ~= 0 then
                    hold_tick0, hold_t, HOLD_ACTIVE = tick, 0, true
                    space:write_u16(v + P_ACTION, ACT_FROZEN)
                    log("  HOLD  freezing p2 at cmb_tick=%d for %d frames", tick, HOLD_FRAMES)
                end
            end
        else
            local v = space:read_u32(p2_proc)
            hold_t = hold_t + 1
            if v ~= 0 and hold_t <= HOLD_FRAMES then
                space:write_u16(v + P_ACTION, ACT_FROZEN)   -- hold him there
                local tick = space:read_u16(cmb_tick) & 0xffff
                -- NOT "unchanged": a hit re-arms the clock to hudcmb_hold,
                -- which is a jump UP and is the feature working.  What must
                -- not happen is the window closing under a held man.
                if tick < hold_tick0 then
                    hold_bad = hold_bad + 1
                    if hold_bad == 1 then
                        log("  HOLD  cmb_tick ran down %d -> %d while the victim was frozen",
                            hold_tick0, tick)
                    end
                else
                    hold_ok = hold_ok + 1
                end
                hold_tick0 = tick
            else
                hold_done, HOLD_ACTIVE = true, false
                log("  HOLD  released after %d frames held, tick=%d",
                    hold_ok, space:read_u16(cmb_tick) & 0xffff)
            end
        end
        return                      -- do not provoke through the hold window
    end

    -- ---- and then the reset-under-a-live-readout case -------------------
    if t > provoke_at and provokes < 6 then
        local hits = space:read_u16(cmb_hits) & 0xffff
        local tick = space:read_u16(cmb_tick) & 0xffff
        if hits >= 2 and tick > 8 then
            local v = space:read_u32(p2_proc)
            if v ~= 0 then
                space:write_u8(v + P_HIT, 0)
                provokes = provokes + 1
                provoke_at = t + 90
                log("  PROVOKE p2 p_hit zeroed at %d hits, tick=%d - the next hit"
                    .. " opens a new string under a live readout", hits, tick)
            end
        end
    end

    local scl = space:read_u16(sym.cmb_scl) & 0xffff
    scl_seen[scl] = (scl_seen[scl] or 0) + 1
    if scl == 0 and prev_scl ~= 0 then pops = pops + 1 end
    prev_scl = scl
end)

emu.register_stop(function()
    local steps = {}
    for k = 0, 4 do steps[#steps+1] = string.format("%d:%d", k, scl_seen[k] or 0) end
    log("POP  cmb_scl reached step 0 %d time(s); frames at each step %s",
        pops, table.concat(steps, " "))
    log("ONEHIT readout on screen while the count was 1: %d frame(s)%s",
        one_hit_frames, one_hit_frames == 0 and "  OK" or "  <-- FAIL")
    log("ONEHIT the case was actually provoked %d time(s)%s", provokes,
        provokes > 0 and "" or "  <-- NOT TESTED")
    log("HOLD  cmb_tick frozen for %d frame(s), moved on %d%s", hold_ok, hold_bad,
        (hold_ok > 0 and hold_bad == 0) and "  OK"
            or (hold_ok == 0 and "  <-- NOT TESTED" or "  <-- FAIL"))
end)

emu.register_stop(function()
    log("SUMMARY strings=%d  peak_hits=%d  peak_damage=%d",
        strings_seen, peak_hits, peak_dmg)
    log("SUMMARY hits_mismatch=%d  damage_mismatch=%d", hits_bad, dmg_bad)
    log("SUMMARY frames_ok=%d  frames_wrong=%d  (objects, not records)",
        glyph_ok, glyph_none)
    log("SUMMARY hud_pass entered %d frames, completed the draw loop %d", ran_n, drew_n)
    log("SUMMARY layout_exact=%d/%d", layout_ok, layout_ok + layout_bad)
    -- The pop is gone from the feature, so it is gone from here: there is
    -- one fixed size now and nothing to ease back to.
    local ok = peak_hits >= MINHITS and hits_bad == 0 and dmg_bad == 0
           and glyph_ok > 0 and glyph_none == 0
           and layout_ok == #CASES and layout_bad == 0
    log("VERDICT %s", ok and "PASS" or "FAIL")
    if out then out:close() end
end)
