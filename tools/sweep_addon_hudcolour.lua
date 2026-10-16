-- sweep_addon_hudcolour.lua - the HUD's new colours and spacing, measured.
--
-- Four claims to check, and none of them is settled by reading the source:
--
--   1  boonpal's two spare pens carry the new colours in CRAM - 9 is
--      #FFFFCE (7FF9h) and 10 is #420000 (2000h).  A .word edit in
--      IMGPAL6.ASM only matters if the palette reaches colour map 0.
--   2  the damage total is RED exactly while it is bigger than its resting
--      size: cot_fadered = 1 iff cmb_scl < COT_SCLMAX (4).
--   3  both sides' toasts get built, so the icon spacing can be LOOKED at.
--   4  the readout and a toast are on screen together at least once, for
--      one snapshot with every colour in it.
--
-- P1 jabs in bursts (two hits, then silence longer than hudcmb_hold) so the
-- readout appears AND fades; P2 jabs back in the gaps so his own toast is
-- built on the mirrored side.
--
-- Env: HCOL_LOG.  Driven by run_hudcolour_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("HCOL_LOG") or (ROOT .. "/tools/hudcolour.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local cmb_tick, cmb_scl, cmb_hits = sym.cmb_tick, sym.cmb_scl, sym.cmb_hits
local cal_word = sym.cal_word
local cot_fpal, cot_fpalr = sym.cot_fpal, sym.cot_fpalr
local cmb_xv = sym.cmb_xv          -- 0 = the readout has finished sliding in
local OBJLST = {sym.objlst, sym.objlst2, sym.objlst3}
local OLINK, OZVAL, OSIZEX, OPAL, OID = 0x000, 0x0c0, 0x120, 0x140, 0x1c0
local OYPOS = 0x0b0
local OSCALE = 0x180        -- DISPEQU: oscale is 180h, not 160h
local OCONST = 0x150        -- ... and oconst is 150h
local FRONT_Z = 0x50
local COT_ZTEXT, COT_ZSHAD = FRONT_Z + 2, FRONT_Z + 1
local OID_CALOUT, OID_CMBDMG, OID_CMBHIT = 0x806, 0x808, 0x80a
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local OXPOS, OXVAL = 0x090, 0x080
local GAP = 70                       -- jab range, outside grab range
local COT_SCLMAX = 4
local REST_SCALE = 0x01400140   -- cot_scltab[COT_SCLMAX], the only size drawn
                                -- while hudcmb_grow is shelved
local CRAM = 0x01800000              -- mk2.cmd; entry n is 16 bits in
local MAX_HP = 0xA1

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[hcol] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end
local function rgb(w)
    return string.format("#%02x%02x%02x", ((w >> 10) & 31) * 255 // 31,
                         ((w >> 5) & 31) * 255 // 31, (w & 31) * 255 // 31)
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Down","P1 High Punch","P1 Low Punch",
    "P2 Left","P2 Right","P2 Down","P2 High Punch","P2 Low Punch","P2 Block",
}) do ADDON_OWNS[n] = true end

local SIDE = tonumber(os.getenv("HCOL_SIDE") or "1")
local CHAIN = os.getenv("HCOL_CHAIN") == "1"
-- what the OBJECTS carry this frame, not what cmb_scl says: a snapshot taken
-- off the variable catches the frame before the redraw and shows the old
-- size and the old palette
local drawn_pal, drawn_oscale, home_at, fresh_at = nil, nil, nil, nil
local hits_col, ys_done = nil, nil
local pinned, last_hits_x, jumps = nil, nil, 0
local last_xy, still = nil, 0
local space, frame, fight0 = nil, 0, 0
local gap_done = {}

-- every live object carrying one oid, with the fields this rig compares
local function objs_with_oid(want)
    local out = {}
    for _, head in ipairs(OBJLST) do
        local p, guard = space:read_u32(head), 0
        while p ~= 0 and guard < 300 do
            if (space:read_u16(p + OID) & 0xffff) == want then
                out[#out + 1] = {
                    x   = s16(space:read_u16(p + OXPOS)),
                    w   = space:read_u16(p + OSIZEX) & 0xffff,
                    pal = space:read_u16(p + OPAL) & 0xffff,
                    z   = space:read_u32(p + OZVAL) & 0xffffffff,
                    scale = space:read_u32(p + OSCALE) & 0xffffffff,
                    const = space:read_u16(p + OCONST) & 0xffff,
                    y   = s16(space:read_u16(p + OYPOS)),
                }
            end
            p = space:read_u32(p + OLINK)
            guard = guard + 1
        end
    end
    return out
end
local fields = {}
local pens_done, shots = false, 0
local bad, pairs_seen = 0, {}
local last = nil
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end
local function snap(why)
    shots = shots + 1
    log("SNAP %d %s", shots, why)
    pcall(function() manager.machine.video:snapshot() end)
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
        log("=== hud colour === pens, red-while-big, both toasts")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    -- 1: the pens, once the fight's palettes are loaded
    if not pens_done and t == 60 then
        pens_done = true
        for _, i in ipairs({9, 10, 13, 14, 15}) do
            local w = space:read_u16(CRAM + i * 16) & 0x7fff
            log("  boonpal[%2d] = %04Xh  %s", i, w, rgb(w))
        end
    end

    -- 2: the colour must follow the size.
    --
    -- NOT off cot_fadered: that is a scratch flag hud_combo_draw sets and
    -- clears inside one call, so from out here it reads 0 on every frame no
    -- matter what got drawn.  What reaches the screen is the PALETTE on the
    -- damage total's objects, so read that.
    local scl  = space:read_u16(cmb_scl) & 0xffff
    local tick = space:read_u16(cmb_tick) & 0xffff
    local hits = space:read_u16(cmb_hits) & 0xffff
    local fpal  = space:read_u16(cot_fpal) & 0xffff
    local fpalr = space:read_u16(cot_fpalr) & 0xffff
    if tick ~= 0 and fpal ~= 0 then
        local pal, drawn_scale = nil, nil
        for _, o in ipairs(objs_with_oid(OID_CMBDMG)) do
            if o.z == COT_ZTEXT then pal, drawn_scale = o.pal, o.scale end
        end
        drawn_pal, drawn_oscale = pal, drawn_scale
        if home_at == nil and tick > 4 and pal == fpal then
            home_at = frame
        end
        if fresh_at == nil and shots >= 1 and pal == fpalr then
            fresh_at = frame
        end
        if pal then
            local isred = (pal == fpalr) and 1 or 0
            local key = scl .. ":" .. isred .. ":" .. tostring(drawn_scale)
            if not pairs_seen[key] then
                pairs_seen[key] = true
                -- hudcmb_red is shelved too: MK2FDE_P on EVERY step now,
                -- and MK2RDf_P should never be allocated, let alone drawn
                local want = 0
                if isred ~= want then bad = bad + 1 end
                -- hudcmb_grow is shelved: the size must NOT move any more,
                -- whatever cmb_scl is doing
                if drawn_scale ~= REST_SCALE then
                    bad = bad + 1
                    log("  scl=%d drew oscale %08x, want %08x - the size is " ..
                        "supposed to be shelved", scl, drawn_scale, REST_SCALE)
                end
                -- the DRAWN oscale too: cmb_scl moving in RAM proves
                -- nothing about the objects on screen
                log("  scl=%d palette=%-8s oscale=%08x  want %s%s", scl,
                    isred == 1 and "MK2RDf_P" or "MK2FDE_P", drawn_scale,
                    want == 1 and "MK2RDf_P" or "MK2FDE_P",
                    isred ~= want and "   <-- WRONG" or "")
            end
        end
    end

    -- DOES IT STAY PUT while the string is being extended?
    --
    -- "Parked" is decided by WATCHING, not by reading cmb_xv: that reads
    -- non-zero here even after the flight zeroes it, and gating on it meant
    -- this check silently never ran.  Ten frames at the same x is parked.
    if tick ~= 0 then
        local dx, hx = nil, nil
        for _, o in ipairs(objs_with_oid(OID_CMBDMG)) do
            if o.z == COT_ZTEXT then dx = math.min(dx or 9999, o.x) end
        end
        for _, o in ipairs(objs_with_oid(OID_CMBHIT)) do
            if o.z == COT_ZTEXT then hx = math.min(hx or 9999, o.x) end
        end
        if dx and hx then
            if hits < (last_hits_x or 0) then pinned = nil end   -- new string
            last_hits_x = hits
            if last_xy and last_xy[1] == dx and last_xy[2] == hx then
                still = still + 1
            else
                if pinned and still >= 10 then
                    jumps = jumps + 1
                    if jumps <= 8 then
                        log("  JUMP at hits=%d: %% x=%d (was %d), hits x=%d (was %d)",
                            hits, dx, pinned[1], hx, pinned[2])
                    end
                    pinned = nil
                end
                still = 0
            end
            if pinned == nil and still >= 10 then
                pinned = {dx, hx}
                log("  parked at hits=%d: %% x=%d, hits x=%d", hits, dx, hx)
            end
            last_xy = {dx, hx}
        end
    end

    -- where the % line sits against the rule/hits line under it: the ask
    -- was one pixel DOWN, and the two lines below it must not have moved
    if tick ~= 0 and not ys_done then
        local dy, hy = nil, nil
        for _, o in ipairs(objs_with_oid(OID_CMBDMG)) do
            if o.z == COT_ZTEXT then dy = o.y end
        end
        for _, o in ipairs(objs_with_oid(OID_CMBHIT)) do
            if o.z == COT_ZTEXT then hy = math.min(hy or 9999, o.y) end
        end
        if dy and hy then
            ys_done = true
            log("  %% line y=%d, rule/hits top y=%d, gap=%d", dy, hy, hy - dy)
        end
    end

    -- the hit count and the rule share oid_cmbhit and should now be the
    -- toast colour too - they are masks, so oconst IS the colour
    if tick ~= 0 and not hits_col then
        for _, o in ipairs(objs_with_oid(OID_CMBHIT)) do
            if o.z == COT_ZTEXT then
                hits_col = o.const
                log("  hits line / rule oconst=%04Xh (want 0909h #FFFFCE)",
                    o.const)
                break
            end
        end
    end

    -- 3: the icon gap, in pixels, off the objects themselves
    for i = 0, 1 do
        if not gap_done[i] then
            local o = objs_with_oid(OID_CALOUT + i)
            local text = {}
            for _, v in ipairs(o) do
                if v.z == COT_ZTEXT then text[#text + 1] = v end
            end
            if #text >= 3 then
                -- the icon is the piece at the OUTER end: leftmost for p1,
                -- rightmost for p2 (it goes on that player's own screen edge)
                table.sort(text, function(a, b) return a.x < b.x end)
                local icon, gap
                if i == 0 then
                    icon = text[1]
                    gap = text[2].x - (icon.x + icon.w)
                else
                    icon = text[#text]
                    local right = 0
                    for k = 1, #text - 1 do
                        right = math.max(right, text[k].x + text[k].w)
                    end
                    gap = icon.x - right
                end
                gap_done[i] = gap
                log("  p%d toast: icon %dx at x=%d, gap to the word = %d px",
                    i + 1, icon.w, icon.x, gap)
                -- the pens the glyphs are actually blitted in.  A mask is
                -- drawn in oconst, so this is the colour, not a guess
                local word, shadow = nil, nil
                for _, v in ipairs(o) do
                    if v.z == COT_ZTEXT and v.w < 14 then word = v.const end
                    if v.z == COT_ZSHAD then shadow = v.const end
                end
                log("  p%d toast: word oconst=%04Xh (want 0909h #FFFFCE), " ..
                    "shadow oconst=%04Xh (want 0A0Ah #420000)",
                    i + 1, word or 0, shadow or 0)
            end
        end
    end

    -- 4: one shot of each state, both taken FIVE FRAMES LATE.
    --
    -- video:snapshot() hands back the buffer rendered before this frame's
    -- logic ran, so snapping on the frame the state changes captures the
    -- state before it - the "home" shot came out big and red that way.
    --
    -- Home first, then fresh: the readout SLIDES IN, so the first hit of a
    -- string is drawn while it is still off the left edge and a shot taken
    -- there has no readout in it at all.
    if shots == 0 and home_at ~= nil and frame >= home_at + 5 then
        snap("home: small, MK2FDE_P, window still running")
    elseif shots == 1 and fresh_at ~= nil and frame >= fresh_at + 5 then
        snap("live: MK2RDf_P, at the shelved resting size")
    end
    local w2 = space:read_u32(cal_word + 32)
    if w2 ~= 0 and shots == 2 then snap("p2 toast (icon on the right)") end

    -- pin them at jab range
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 ~= 0 and o2 ~= 0 then
        local x1 = s16(space:read_u16(o1 + OXPOS))
        local x2 = s16(space:read_u16(o2 + OXPOS))
        local tx = (x1 < x2) and (x1 + GAP) or (x1 - GAP)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end

    -- P1: two jabs then silence.  P2: one jab late in the same period, so
    -- his toast is built while P1's readout is still fading.
    -- FIRST HIT arms once a round, for whoever lands it - so which side's
    -- toast exists at all is decided by who opens.  HCOL_SIDE picks that:
    -- side 1 gives p1 the readout AND the toast, side 2 hands the toast to
    -- p2 so the mirrored icon spacing can be measured against p1's.
    -- CHAIN mode: keep jabbing, so the string runs long and the numbers gain
    -- digits.  That is the case the report is about - "continuing the combo
    -- makes the hit/percentage jump back a few pixels".
    if CHAIN then
        local k = t % 10
        press("P1 High Punch", k == 4 or k == 5)
        return
    end

    local c = t % 220
    if SIDE == 2 then
        press("P2 High Punch", c == 4 or c == 5 or c == 16 or c == 17)
        press("P1 High Punch", c == 120 or c == 121)
    else
        press("P1 High Punch", c == 4 or c == 5 or c == 16 or c == 17)
        press("P2 High Punch", c == 120 or c == 121)
    end
end)

emu.register_stop(function()
    log("DRIFT %d jumps of the parked readout (0 = it stays in place)", jumps)
    log("GAPS p1=%s p2=%s (they must match)",
        tostring(gap_done[0]), tostring(gap_done[1]))
    log("SUMMARY mismatches=%d  distinct (scl,fadered) pairs seen=%d  shots=%d",
        bad, (function() local n = 0 for _ in pairs(pairs_seen) do n = n + 1 end
              return n end)(), shots)
    if bad == 0 then
        log("VERDICT PASS - MK2FDE_P at every step, size pinned at the rest")
    else
        log("VERDICT FAIL - %d frames drew the wrong size or palette", bad)
    end
end)
