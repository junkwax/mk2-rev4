-- Runtime proof for THE OVERLOOK (peak_mod, curback 018h).
--
-- Three things have to be true and only one of them is visible in a single
-- screenshot, so this drives the camera to both scroll limits and reads the
-- plane registers at each stop:
--
--   floor      seven `battlepit` tiles must cover the whole playable span.
--              A tile short at either end shows sky under the fighters' feet,
--              and that only appears at a scroll limit.
--   backdrop   worldtlx6 (mount2, the sky) must NOT move.  peak_scroll gives
--              plane 6 a rate of zero; if the value drifts the sky is riding
--              some other plane's velocity.
--   mountain   worldtlx3 (mount1) MUST move, at a quarter of the floor's
--              rate.  Equal to the floor = no parallax; equal to the sky =
--              no motion at all.
--
-- Boot schedule, addressing and the warning-screen dismissal are lifted from
-- tools/noob_divekick_test.lua.  All offsets are TMS34010 BIT units.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("PEAK_LOG") or (ROOT .. "/tools/peak_stage_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[peak] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "p1_obj", "p2_obj", "p1_bar", "p2_bar", "p1_bar_view",
                     "p2_bar_view", "winner_status", "battle_num", "map_position",
                     "worldtlx", "worldtlx3", "worldtlx6", "worldtly",
                     "ground_y", "ceiling_y", "left_edge", "right_edge",
                     "baklst1", "baklst2", "baklst3", "baklst4", "baklst5",
                     "baklst6", "baklst7", "rand",
                     "worldtlx2", "worldtlx4", "worldtlx5", "worldtlx7",
                     "ofree", "f_nosound" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local OXVAL, OXPOS, OYPOS, ONEXT, OSIZEX, OSIZEY = 0x080, 0x090, 0x0b0, 0x00, 0x120, 0x130
-- m_noscroll lives in OFLAGS2, not OFLAGS: set_noscroll (MKUTIL.ASM) writes
-- oflags2, and dclipl tests b_noscroll in a7, which it loads from oflags2.
local OFLAGS2, M_NOSCROLL = 0x160, 0x0001
local OPAL = 0x140   -- the allocated colour map, [#,#] form from getfpal
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_KANG = 8, 1
local PEAK = 0x18
-- Three lanes: far railing (baklst5), stone deck (baklst4), near railing
-- (baklst1).  The railings are subframe STRIPS now, so the counts are the
-- sum of each composite's strip count over the 1,2,3,4,5,4,3,2,1,2 run:
-- 5+4+4+3+3+3+4+4+5+4 = 39.  The deck is three slices drawn twice.
local STONE_N, RAIL_N = 6, 39
local STONE_W, RAIL_W = 1200, 1254

-- The warning-screen dismisser watches for a READY file, and it must not be
-- this script's log: that is opened at script LOAD, which happens before a
-- single frame runs, so the poker would see it instantly, exit, and leave MAME
-- parked on the red screen forever at ~0 CPU.  This flag is written from the
-- frame callback once emulation is demonstrably going.
local READY_PATH = (os.getenv("PEAK_READY") or (ROOT .. "/tools/peak_stage_ready.flag"))
local ready_written = false

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local R, stops = {}, {}
local bolts, bolt_live, bolt_x, bolt_snap_at = 0, 0, {}, nil

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
-- worldtl* are 32-bit fixed point; the integer part is the top word.
local function world(a) return s16(r32(a) >> 16) end

local function setx(p, x)
    local o = r32(p)
    if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- field report ----")
    for _, k in ipairs({ "curback", "ground_y", "worldtly", "left_edge", "right_edge",
                         "feet_screen_y",
                         "stone_pieces", "stone_span", "stone_width", "stone_gap",
                         "near_pieces", "near_span", "near_width", "near_gap",
                         "far_pieces", "far_span", "far_width", "far_gap",
                         "far_lift", "bolt_tracks_sky", "near_opal", "far_opal", "deck_opal",
                         "uncovered_deck", "uncovered_near", "uncovered_far",
                         "near_drift", "far_drift",
                         "sky_fixed", "mountain_moved", "mountain_ratio_x4",
                         "reached_left", "reached_right",
                         "sky_objs", "mtn_objs", "mtn_top_screen", "bolts_seen", "bolt_screen_y",
                         "bolt_distinct_x", "bolt_noscroll", "bolt_max_w", "bolt_offscreen",
                         "sound_tap", "f_nosound", "snd_writes", "snd_strike",
                         "snd_rumble", "snd_doorslam", "strike_times",
                         "objs_free_min" }) do
        log("  %-20s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
                   ["1 Player Start"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

-- Sound is a write-only strobe at 0x1d01030, and this probe runs with
-- -sound none, so the only way to prove a cue fired is to watch the port.
-- The address is the RAW SYSEQU value, not a /8 byte conversion: every other
-- address in this script comes straight out of mk2.map and MAME's Lua space
-- accepts them as-is, so the port has to be addressed the same way.  Passing
-- the byte address made install_write_tap fail silently (the pcall reported
-- "unavailable" while the method was in fact present).  send_code_a3 writes the code as two bytes, each OR'd with
-- 0ff00h|soundbit (0100h): high byte first, then low.  Reassemble them.
-- Wrapped in pcall because install_write_tap is not in every MAME build - a
-- missing API must not take the rest of the run down with it.
local SOUND_PORT = 0x1d01030
local snd_hi, snd_codes, snd_writes, snd_raw = nil, {}, 0, {}
local strike_open = false
local function install_sound_tap()
    local ok = pcall(function()
        local prog = manager.machine.devices[":maincpu"].spaces["program"]
        prog:install_write_tap(SOUND_PORT, SOUND_PORT + 0x0f, "sndtap", function(offset, data, mask)
            snd_writes = snd_writes + 1
            if snd_writes <= 12 then
                snd_raw[#snd_raw + 1] = string.format("%x@%x", data & 0xffff, offset)
            end
            local b = data & 0xff
            if snd_hi == nil then snd_hi = b
            else snd_codes[#snd_codes + 1] = (snd_hi << 8) | b; snd_hi = nil end
            return data
        end)
    end)
    R.sound_tap = ok and "installed" or "unavailable"
    -- Record what the build actually offers, so the next person does not have
    -- to burn a run finding out.
    local prog = manager.machine.devices[":maincpu"].spaces["program"]
    R.tap_api = tostring(rawget(getmetatable(prog) or {}, "__index") and
                         type(prog.install_write_tap)) .. "/" .. (emu.app_version and emu.app_version() or "?")
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

-- Walk one background list; return count and the min/max world x its objects span.
local function list_span(head)
    local obj, n, lo, hi, guard = r32(head), 0, nil, nil, 0
    while obj ~= 0 and guard < 300 do
        local x = s16(r16(obj + OXPOS))
        local w = r16(obj + OSIZEX)
        n = n + 1
        if not lo or x < lo then lo = x end
        if not hi or x + w > hi then hi = x + w end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return n, lo, hi
end

-- How much of the 358-block object pool is still free.  This stage hand-inserts
-- every floor piece into baklst1/baklst4 and they are NEVER culled - stock
-- stages get their tiles from a BMOD plane, where disp_mod only inserts blocks
-- that are actually on screen.  So the floor's object count is a permanent tax
-- on the pool, and object_setup calls ermac 5 when getobj comes back empty.
local function objs_free()
    if not A.ofree then return -1 end
    local o, n = r32(A.ofree), 0
    while o ~= 0 and n < 400 do o = r32(o); n = n + 1 end
    return n
end

-- Walk a list and return (count, leftmost, rightmost, gap) in world x.  `gap`
-- is the first hole or overlap found once the pieces are sorted, which is what
-- catches a re-cut: the soulteeth x positions in BGND.ASM are running sums of
-- widths that live in CASTLE.IMG, and nothing else would notice them drifting.
local function strip_walk(head)
    local obj, pieces, guard = r32(head), {}, 0
    while obj ~= 0 and guard < 300 do
        pieces[#pieces + 1] = { x = s16(r16(obj + OXPOS)), w = r16(obj + OSIZEX) }
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    if #pieces == 0 then return 0, nil, nil, "empty" end
    table.sort(pieces, function(a, b) return a.x < b.x end)
    local gap = nil
    for i = 1, #pieces - 1 do
        local endx = pieces[i].x + pieces[i].w
        if endx ~= pieces[i + 1].x and not gap then
            gap = string.format("%d..%d", endx, pieces[i + 1].x)
        end
    end
    return #pieces, pieces[1].x, pieces[#pieces].x + pieces[#pieces].w, gap
end

-- Topmost screen row any object in a list actually reaches.  The life bars run
-- to row 39 and the panel behind them a little past that, so a mountain summit
-- above ~45 is behind the HUD and nobody ever sees the peak.
local function list_top_screen(head)
    local obj, top, guard = r32(head), nil, 0
    while obj ~= 0 and guard < 300 do
        local y = s16(r16(obj + OYPOS))
        if not top or y < top then top = y end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    if not top then return nil end
    return top - world(A.worldtly)
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        install_sound_tap()
        log("---- THE OVERLOOK (curback %02xh) ----", PEAK)
    end

    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end          -- warning screen
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, PEAK)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space then return end

    -- The VS panel is where print_background_name draws "KOMBAT ZONE: <name>".
    -- Snapshot it once on the way through so a renamed stage can be checked for
    -- spelling and for fit - the field is centred and there is no clipping.
    if confirm_frame > 0 and fighting_frame == 0 then
        local since = frame - confirm_frame
        if since > 120 and since % 40 == 0 then snap("vs panel " .. since) end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        R.curback   = r16(A.curback)
        R.ground_y  = s16(r16(A.ground_y))
        R.worldtly  = world(A.worldtly)
        R.left_edge = s16(r16(A.left_edge))
        R.right_edge = s16(r16(A.right_edge))
        R.feet_screen_y = R.ground_y - R.worldtly
        local nn, nlo, nhi, ngap = strip_walk(A.baklst7)   -- near railing
        local sn, slo, shi, sgap = strip_walk(A.baklst4)   -- stone deck
        local fn, flo, fhi, fgap = strip_walk(A.baklst5)   -- far railing
        R.near_pieces, R.near_span = nn, string.format("%s..%s", tostring(nlo), tostring(nhi))
        R.near_gap = ngap or "none"
        R.near_width = (nhi and nlo) and (nhi - nlo) or 0
        R.stone_pieces, R.stone_span = sn, string.format("%s..%s", tostring(slo), tostring(shi))
        R.stone_gap = sgap or "none"
        R.stone_width = (shi and slo) and (shi - slo) or 0
        R.far_pieces, R.far_span = fn, string.format("%s..%s", tostring(flo), tostring(fhi))
        R.far_gap = fgap or "none"
        R.far_width = (fhi and flo) and (fhi - flo) or 0
        -- the far railing must be the near one MIRRORED: same span, and it
        -- has to sit higher, which is the whole point of teethflip1's aniy
        R.far_lift = (nlo and flo) and (list_top_screen(A.baklst7) - list_top_screen(A.baklst5)) or 0
        -- The railings are the SAME art; only the colour map separates them.
        -- Every packed strip binds TEEFBAC_p, the far row keeps it, and the
        -- near runs swpal to DEATHZN_p.  Reading opal is the only honest way
        -- to prove that landed - the two palettes are close enough in shape
        -- that a screenshot does not settle it.
        R.near_opal = string.format("%04x", r16(r32(A.baklst7) + OPAL))
        R.far_opal  = string.format("%04x", r16(r32(A.baklst5) + OPAL))
        R.deck_opal = string.format("%04x", r16(r32(A.baklst4) + OPAL))
        R.spans = { deck = { slo, shi }, near = { nlo, nhi }, far = { flo, fhi } }
        R.sky_objs = (select(1, list_span(A.baklst6)))
        R.mtn_objs = (select(1, list_span(A.baklst3)))
        R.mtn_top_screen = list_top_screen(A.baklst3)
        R.f_nosound = A.f_nosound and r16(A.f_nosound) or "?"
        R.snd_writes = snd_writes
        R.snd_raw = table.concat(snd_raw, " ")
        log("fight start f=%d curback=%d ground_y=%d worldtly=%d edges=%d..%d",
            frame, R.curback, R.ground_y, R.worldtly, R.left_edge, R.right_edge)
        log("deck  %2d pieces %s (w=%d, gap %s)", sn, R.stone_span, R.stone_width, R.stone_gap)
        log("near  %2d pieces %s (w=%d, gap %s)", nn, R.near_span, R.near_width, R.near_gap)
        log("far   %2d pieces %s (w=%d, gap %s) lift=%d",
            fn, R.far_span, R.far_width, R.far_gap, R.far_lift)
        log("baklst3=%d  baklst6=%d", R.mtn_objs, R.sky_objs)
        if R.curback ~= PEAK then finish(false, "curback is not the peak stage") end
    end
    if fighting_frame == 0 then
        if frame > 4000 then finish(false, "never reached a fight") end
        return
    end

    -- Lightning: one_bang inserts a bolt into baklst2 and deletes it when the
    -- animation ends, so the lane is empty most of the time.  Count the rising
    -- edges rather than sampling, and grab a screenshot on the first one.
    do
        local n, lo = list_span(A.baklst2)
        if n > 0 and bolt_live == 0 then
            bolts = bolts + 1
            local obj = r32(A.baklst2)
            R.bolts_seen = bolts
            R.bolt_screen_y = s16(r16(obj + OYPOS))
            local seen = {}
            for k = 1, #bolt_x do seen[bolt_x[k]] = true end
            bolt_x[#bolt_x + 1] = s16(r16(obj + OXPOS))
            local distinct = 0
            for _ in pairs(seen) do distinct = distinct + 1 end
            R.bolt_distinct_x = distinct + (seen[bolt_x[#bolt_x]] and 0 or 1)
            R.bolt_noscroll = (r16(obj + OFLAGS2) & M_NOSCROLL) ~= 0
            -- (width is sampled below, every frame the bolt is live - NOT here.
            -- Every a_thunder table starts on its SMALLEST frame, so the width
            -- on the appearance frame says nothing about which slot rolled:
            -- a_thunder4 opens on thunder4e at 23px and only reaches 47 mid
            -- strike, which read as "thunder4 never fired" for two runs.)
            -- The world coords above prove nothing on their own: they are the
            -- object's, and a bolt placed 400px out would still report five
            -- tidy distinct positions while rendering off the side of the
            -- screen.  Convert to where it actually DRAWS - dclipl subtracts
            -- the plane's own worldtl for a scrolling object - and range-check
            -- that instead.
            local sx = bolt_x[#bolt_x] - world(A.worldtlx2)
            local sy = R.bolt_screen_y - world(A.worldtly)
            -- Left/top only.  thunder4 is authored at the sky panel's right
            -- edge and clips there on purpose - it does on the map screen too -
            -- so a right-edge overhang is not a fault.
            if sx < 0 or sx > 399 or sy < 45 or sy > 253 then
                R.bolt_offscreen = string.format("bolt %d drew at %d,%d", bolts, sx, sy)
            end
            log("bolt %2d  world=%3d,%-3d screen=%3d,%-3d w=%2d noscroll=%s",
                bolts, bolt_x[#bolt_x], R.bolt_screen_y, sx, sy,
                r16(obj + OSIZEX), tostring(R.bolt_noscroll))

        end
        -- thunder4 is 47x74 at full extent and nothing else in lightning_table
        -- gets past 40 wide, so the widest width seen ACROSS a strike is a
        -- clean proxy for "slot 5 came up".
        if n > 0 then
            local w = r16(r32(A.baklst2) + OSIZEX)
            if not R.bolt_max_w or w > R.bolt_max_w then R.bolt_max_w = w end
            -- Log WHEN thunder4 is on screen, in emulated seconds, so the
            -- captured wav can be checked at those offsets.  It has to be here
            -- and not on the rising edge: every a_thunder table opens on its
            -- smallest frame, so a bolt is only identifiable as thunder4 once
            -- it has grown to its 47px extent.
            -- Trigger on HEIGHT, not width.  thunder4a is 47 wide too but it
            -- is only the cloud glow; the frames that carry the long
            -- descending bolt are the 74-row ones (4b/4c).  Snapping on width
            -- caught the flash a frame early, every time.
            local h = r16(r32(A.baklst2) + OSIZEY)
            if h >= 74 and not strike_open then
                strike_open = true
                -- +3 frames: screen:snapshot() captures the last COMPLETED
                -- frame, so snapping the instant the 74-row frame is detected
                -- returns the glow that preceded it.  a_thunder4 holds b/c for
                -- 6 ticks each and runs b,c,b,c, so three frames is safely
                -- inside the bolt.
                bolt_snap_at = frame + 3
                R.strike_times = (R.strike_times and (R.strike_times .. " ") or "")
                                 .. string.format("%.2f", frame / 60.0)
            end
        else
            strike_open = false
        end
        -- 0239h is triple_sndtab2 entry 4, the lightning strike, and only the
        -- thunder4 slot asks for it.  0233h/0236h are the two distance
        -- thunders; 01f7h would be the "doors slam" the map screen plays by
        -- mistake and must never appear here.
        for i = 1, #snd_codes do
            local c = snd_codes[i]
            if c == 0x239 then R.snd_strike = (R.snd_strike or 0) + 1 end
            if c == 0x233 or c == 0x236 then R.snd_rumble = (R.snd_rumble or 0) + 1 end
            if c == 0x1f7 or c == 0x1f4 then R.snd_doorslam = (R.snd_doorslam or 0) + 1 end
            snd_codes[i] = nil
        end
        snd_codes = {}
        bolt_live = n
        if bolt_snap_at and frame >= bolt_snap_at then
            bolt_snap_at = nil
            snap("thunder4 bolt frame")
        end
    end

    -- keep the round alive and the drone quiet
    -- @rand is reseeded identically at every round start, so a scripted rig
    -- replays ONE fixed sequence of slot draws however long it runs - which is
    -- why 13 strikes never once rolled lightning_table's sixth entry.  Stir it
    -- so the sample actually covers the table.
    if (frame - fighting_frame) % 137 == 0 and A.rand then
        space:write_u32(A.rand, (frame * 2654435761) & 0xffffffff)
    end
    do
        local f = objs_free()
        if not R.objs_free_min or f < R.objs_free_min then R.objs_free_min = f end
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status then w16(A.winner_status, 0) end
    w16(A.p2_state, 1)

    -- Pin the pair over a LONG window and let the scroller settle on them.
    -- One or two frames of writes is not enough: the round-start pan owns the
    -- camera for a while, and the scroller only closes on a target at 010000h
    -- a frame, so the edges take ~200 frames to reach from the middle.  The
    -- first cut of this probe wrote x for 40 frames and never left the centre,
    -- which is exactly the reading that would have hidden a short floor.
    local r = frame - fighting_frame
    -- 700 and no more: the round clock is live, and past ~40s of fight the
    -- round ends, the stage tears down and every reading after that is
    -- another state's.  A 60s pass produced a 192px wide "bolt" on baklst2.
    local HOLD = 700
    local plan = {
        { x = R.left_edge - 40,          tag = "left"   },   -- past the limit
        { x = (R.left_edge + R.right_edge) // 2 + 200, tag = "centre" },
        { x = R.right_edge + 399 + 40,   tag = "right"  },   -- past the limit
    }
    local idx = math.floor(r / HOLD) + 1
    local p = plan[idx]
    if p then
        setx(A.p1_obj, p.x); setx(A.p2_obj, p.x + 70)
        local into = r % HOLD
        if into == HOLD - 1 then
            local wx, w3, w6 = world(A.worldtlx), world(A.worldtlx3), world(A.worldtlx6)
            local w4, w5, w7 = world(A.worldtlx4), world(A.worldtlx5), world(A.worldtlx7)
            stops[#stops + 1] = { tag = p.tag, wx = wx, w3 = w3, w6 = w6,
                                  w4 = w4, w5 = w5, w7 = w7,
                                  w2 = world(A.worldtlx2) }
            -- Each course rides its OWN plane now, so coverage has to be tested
            -- against that plane's worldtlx.  Comparing a span to left_edge is
            -- only meaningful for a course locked to the camera.
            for name, wtl in pairs({ deck = w4, near = w7, far = w5 }) do
                local lo, hi = R.spans[name][1], R.spans[name][2]
                if not (lo <= wtl and hi >= wtl + 399) then
                    R["uncovered_" .. name] = string.format("%s at worldtl %d", p.tag, wtl)
                end
            end
            log("stop %-6s cam=%4d deck=%4d near=%4d far=%4d  mtn=%4d sky=%4d",
                p.tag, wx, w4, w7, w5, w3, w6)
            snap(p.tag)
        end
    end

    if r > HOLD * 3 + 10 and not finished then
        local L, C, Rt = stops[1], stops[2], stops[3]
        if not (L and C and Rt) then finish(false, "did not reach all three stops") end

        R.sky_fixed = (L.w6 == C.w6) and (C.w6 == Rt.w6)

        R.reached_left  = L.wx <= R.left_edge + 2
        R.reached_right = Rt.wx >= R.right_edge - 2
        local floor_travel = Rt.wx - L.wx
        local mtn_travel   = Rt.w3 - L.w3
        R.mountain_moved = mtn_travel ~= 0
        R.mountain_ratio_x4 = floor_travel ~= 0
            and string.format("%.2f", (mtn_travel * 4.0) / floor_travel) or "n/a"
        log("travel: floor=%d mountain=%d sky=%d", floor_travel, mtn_travel, Rt.w6 - L.w6)

        local bad = {}
        if R.stone_pieces ~= STONE_N then bad[#bad+1] = "deck piece count" end
        if R.near_pieces ~= RAIL_N then bad[#bad+1] = "near railing piece count" end
        if R.far_pieces ~= RAIL_N then bad[#bad+1] = "far railing piece count" end
        if R.stone_gap ~= "none" then bad[#bad+1] = "deck has a gap/overlap" end
        if R.near_gap ~= "none" then bad[#bad+1] = "near railing has a gap/overlap" end
        if R.far_gap ~= "none" then bad[#bad+1] = "far railing has a gap/overlap" end
        if R.stone_width ~= STONE_W then bad[#bad+1] = "deck is not 1200 wide" end
        if R.near_width ~= RAIL_W then bad[#bad+1] = "near railing is not 1254 wide" end
        if R.far_width ~= RAIL_W then bad[#bad+1] = "far railing is not 1254 wide" end
        if R.near_span ~= R.far_span then bad[#bad+1] = "railings are not mirrored onto the same span" end
        -- 36 = soulteeth aniy (-113) - teethflip1 aniy (-77), read out of
        -- CASTLE.IMG.  Asserted as an exact number, not just "above": the
        -- reference sprite gets re-anipointed, and a silent drift here is a
        -- railing at the wrong depth that still passes a >0 test.
        if R.far_lift ~= 36 then
            bad[#bad+1] = "far railing lift is " .. tostring(R.far_lift) .. ", expected 36"
        end
        if R.near_opal == R.far_opal or R.near_opal == R.deck_opal
           or R.far_opal == R.deck_opal then
            bad[#bad+1] = "the three floor lanes are not on three colour maps"
        end
        -- the railings must actually parallax against the deck, and in the
        -- right directions: the near one leads it, the far one hangs back
        -- The bolts are mount2 features, so plane 2 must track the SKY on
        -- plane 6 - not the mountain.  Both were tried: welding them to the
        -- mountain is the wrong relationship and it shows as the strike
        -- drifting off the cloud it is drawn hanging from.
        R.bolt_tracks_sky = (L.w2 == L.w6) and (C.w2 == C.w6) and (Rt.w2 == Rt.w6)
        R.near_drift = (Rt.w7 - L.w7) - (Rt.w4 - L.w4)
        R.far_drift  = (Rt.w5 - L.w5) - (Rt.w4 - L.w4)
        if R.near_drift <= 0 then bad[#bad+1] = "near railing does not lead the deck" end
        if R.far_drift  >= 0 then bad[#bad+1] = "far railing does not hang back" end
        for _, n in ipairs({ "deck", "near", "far" }) do
            if R["uncovered_" .. n] then bad[#bad+1] = n .. " ran off its plane" end
        end
        if not R.sky_fixed then bad[#bad+1] = "sky moved" end
        if not R.mountain_moved then bad[#bad+1] = "mountain static" end
        if floor_travel ~= 0 and math.abs(mtn_travel * 4 - floor_travel) > 8 then
            bad[#bad+1] = "mountain rate not 1/4"
        end
        if not R.reached_left or not R.reached_right then
            bad[#bad+1] = "camera never reached both limits (coverage unproven)"
        end
        if bolts == 0 then bad[#bad+1] = "no lightning in ~36s" end
        R.snd_writes = snd_writes
        R.snd_raw = table.concat(snd_raw, " ")
        -- NOT asserted.  The tap installs and fires, but over a whole round it
        -- only ever catches ~10 writes, all of them the power-up handshake
        -- (0x55/0xAA and friends) - the in-game sound codes never reach it.
        -- Reported as a diagnostic so the numbers are visible, but the sound
        -- cue itself is proven from captured audio instead: run with -Sound and
        -- check tools/peak_stage_audio.wav against the strike times logged
        -- below.
        if (R.bolt_max_w or 0) < 47 then
            bad[#bad+1] = "thunder4 (slot 5) never rolled - widest bolt was "
                          .. tostring(R.bolt_max_w)
        end
        -- INVERTED on purpose.  The bolts used to be m_noscroll, which pins
        -- them to screen coordinates - and that is a bug here, not a feature:
        -- the scroller pans up to 16px up when a fighter jumps, the sky and
        -- mountain slide down with it, and a screen-pinned bolt detaches from
        -- the sky it lives in.  peak_bang builds them scrolling, on world
        -- coordinates, so Y follows worldtly.  X is still fixed because plane
        -- 2's rate is 0.
        if R.bolt_offscreen then bad[#bad+1] = R.bolt_offscreen end
        if R.bolt_tracks_sky == false then
            bad[#bad+1] = "bolts do not track the sky (planes 2 and 6 differ)"
        end
        if bolts > 0 and R.bolt_noscroll then
            bad[#bad+1] = "bolts are m_noscroll again - they will detach from "
                          .. "the sky when the camera pans on a jump"
        end
        if R.sky_objs == 0 then bad[#bad+1] = "no sky art" end
        if R.mtn_objs == 0 then bad[#bad+1] = "no mountain art" end
        if R.mtn_top_screen and R.mtn_top_screen < 45 then
            bad[#bad+1] = "mountain summit is behind the HUD"
        end
        finish(#bad == 0, #bad == 0 and "all checks green" or table.concat(bad, ", "))
    end

    if frame > 20000 then finish(false, "backstop") end
end)
