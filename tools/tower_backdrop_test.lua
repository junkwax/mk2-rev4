-- tower_backdrop_test.lua
-- THE TOWER's backdrop reflection, checked on the real machine.
--
-- What it proves, per camera stop:
--   * the three private lists exist and hold what tower_backdrop_reflections
--     and backdrop_follow built (wall ~73, sky = baklst8 + baklst7, monk =
--     baklst5);
--   * every reflected WALL object draws inside the marble band. Its drawn rows
--     are computed with the MEASURED rule - the DMA ceils a reduction, and
--     m_flipv makes clip6 add ysize-1 - so this is the hardware's placement,
--     not the generator's intent restated;
--   * every reflected cloud/monk piece tracks its source: same x, same sag,
--     and a y that matches the mirror formula the follower uses (a cloud that
--     clip_a_row has parked must have its reflection parked too);
--   * the frame still fits: peak_overload (2 = no overrun) and qdma_drops,
--     at the stops and through 1800 frames of released combat, where the
--     per-frame overload word is sampled the way tools/pool_stress.lua does.
-- Snapshots go to tools/screens/tower_backdrop/<tag>; the runner overlay is
-- judged from them by tools/tower_runner_overlay_check.py, from the camera
-- state this logs at each one.
--
-- EVERY SNAPSHOT IS TAKEN WITH THE CAMERA AT REST.  The first versions shot on
-- a fixed frame; when the drone jumped the camera was climbing, and the logged
-- worldtly was two rows away from the one in the picture - the runner check
-- then failed by exactly that, on an overlay that was correct.  Now each stop
-- parks for HOLD frames and then waits until worldtly and skew_oc have held
-- still for STABLE frames (up to SETTLE_MAX) before it checks and snaps.
--
-- Stops, in order:
--   mid    fighters either side of the arch, so it and the runner are clear
--   left   camera at the left limit; the runner near the RIGHT edge
--   right  camera at the right limit; the runner off the left edge
--   climb  P1 held in the air, so the camera climbs and settles: the runner
--          pass's ceiling_y - worldtly path, deliberately, at rest
--   ledge  a live sweep that stops the moment the runner straddles x=0 - the
--          only way to reach twr_runner_code's LEFT clip
--
-- env: MK2_BK_TAG (default "bk")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_BK_TAG") or "bk"
local COLBOX = tonumber(os.getenv("MK2_BK_COLBOX") or "0") or 0
local SHOTS = tonumber(os.getenv("MK2_BK_SHOTS") or "0") or 0
-- MK2_BK_FIGHT=1 skips every camera stop and goes straight to the combat
-- measurement.  The stops are what made the frame-cost figure meaningless:
-- the climb stop teleports P1 into the air with his state machine still
-- saying STANDING, so nothing pulls him down and he hangs there for the rest
-- of the run - measured, "a fighter above the barrier on 100% of frames" and
-- P2 never once leaving oypos 93.  What that number described was two inert
-- fighters, not a fight.
local FIGHTONLY = tonumber(os.getenv("MK2_BK_FIGHT") or "0") or 0
-- MK2_BK_NOSKIP=1 holds @skew_skip at 0, so floor_code draws the rows the
-- reflection covers again.  Same ROM, same run, so a frame-for-frame diff
-- against a normal run is a direct test of "the skip is invisible".
local NOSKIP = tonumber(os.getenv("MK2_BK_NOSKIP") or "0") or 0
-- MK2_BK_NOSHAD=1 clears f_shadows, so a frame-for-frame diff against a normal
-- run is EXACTLY the shadow's pixels.  The shadow and a fighter's boots are
-- both flat black; nothing else separates them.
local NOSHAD = tonumber(os.getenv("MK2_BK_NOSHAD") or "0") or 0
-- MK2_BK_SHADBIAS overrides @shad_bias at runtime, so both looks can be shot
-- from ONE rom.  Empty = leave whatever calla_tower set.
local SHADBIAS = os.getenv("MK2_BK_SHADBIAS")
-- MK2_BK_SHADFAST=0|1 overrides @shad_fast at runtime: the row-by-row stock
-- shadow against shadf's two blits a piece, from ONE rom, so a frame-for-frame
-- diff proves the pixels are the same and the timeline shows what it saves.
local SHADFAST = os.getenv("MK2_BK_SHADFAST")
-- MK2_BK_NOSKY=1 empties the sky backing's list every frame: 2 blits and
-- ~21,600 PIXELS gone, everything else untouched.  It is the cleanest way to
-- ask whether the dma is running out of time on per-blit setup or on pixels.
local NOSKY = tonumber(os.getenv("MK2_BK_NOSKY") or "0") or 0
-- MK2_BK_NOCLDREF=1 empties the REFLECTED clouds' list every frame.  They are
-- drawn behind the reflected wall, so wherever one sits it hides a hole in the
-- wall from view; with them gone every hole shows the sky backing's colour,
-- and the snapshots map where the backing is actually needed.
local NOCLDREF = tonumber(os.getenv("MK2_BK_NOCLDREF") or "0") or 0
-- MK2_BK_NOREFL=1 takes the whole BACKDROP reflection away at runtime - wall,
-- reflected clouds, monk and the sky backing - and lets floor_code draw the
-- marble under it again.  The guard and pillar reflections stay.  It exists to
-- shoot the bare floor for side-by-side mockups, no rebuild needed.
local NOREFL = tonumber(os.getenv("MK2_BK_NOREFL") or "0") or 0
-- MK2_BK_CENTRE=1 emulates a CENTRE-ONLY reflection at runtime: floor_code
-- draws the marble again, and every reflected wall block and sky tile that
-- does not touch the arch window (plane x 425..660) is unlinked once.  It
-- exists to MEASURE what that option costs the object queue, not to ship.
local CENTRE = tonumber(os.getenv("MK2_BK_CENTRE") or "0") or 0
local centre_done = false
local function keep_centre(head)
    local prev, o, dropped = head, r32(head), 0
    while o ~= 0 do
        local nx = r32(o + O.next)
        local x, w = s16(r16(o + O.oxpos)), r16(o + O.osize)
        if x + w <= 425 or x >= 661 then
            w32(prev, nx); dropped = dropped + 1          -- splice it out
        else
            prev = o + O.next
        end
        o = nx
    end
    return dropped
end
local LOG_PATH = ROOT .. "/tools/tower_backdrop_test_" .. TAG .. ".log"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) local v = symbols[n]; if not v then print("[bk] FATAL missing " .. n) end; return v end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtly = sym("worldtly"), worldtlx6 = sym("worldtlx6"), ofree = sym("ofree"),
    ground_y = sym("ground_y"), baklst3 = sym("baklst3"), baklst4 = sym("baklst4"),
    baklst6 = sym("baklst6"),
    p1_shadadj = symbols["p1_shadadj"], p2_shadadj = symbols["p2_shadadj"],
    baklst5 = sym("baklst5"), baklst7 = sym("baklst7"), baklst8 = sym("baklst8"),
    sky = sym("twr_bsky_lst"), wall = sym("twr_bwall_lst"), monk = sym("twr_bmonk_lst"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
    skew_oc = sym("skew_oc"), skew_dx = sym("skew_dx"), skew_y = sym("skew_y"),
    ceiling_y = sym("ceiling_y"),
    f_colbox = symbols["f_colbox"],
    skybg = symbols["twr_skybg_lst"],
    shad_bias = symbols["shad_bias"],
    skew_skip = symbols["skew_skip"],
    f_shadows = symbols["f_shadows"],
    deep_dmaq = symbols["deep_dmaq"], dmaq_over = symbols["dmaq_over"],
    dmaq_late = symbols["dmaq_late"], dmaq_lost = symbols["dmaq_lost"],
    last_dmaq = symbols["last_dmaq"],
    overload = symbols["overload"], p1_bar = symbols["p1_bar"], p2_bar = symbols["p2_bar"],
}
local O = { next = 0x000, oyvel = 0x060, oxval = 0x080, oxpos = 0x090, oyval = 0x0a0,
            oypos = 0x0b0, ofset = 0x0e0, oflags = 0x0f0, osag = 0x100, osize = 0x120,
            osizey = 0x130, opal = 0x140, oscale = 0x180 }
local GS_PSEL, GS_FIGHTING = 4, 2
-- MK2_BK_STAGE forces a different backdrop, for comparing the object-queue
-- depth against a stock stage.  Every tower-specific check is skipped.
local TOWER = tonumber(os.getenv("MK2_BK_STAGE") or "3") or 3
local BASE = 167                      -- TWR_BKBASE, plane y of the floor's top row
local MARBLE_TOP, CARPET_TOP = 181, 235   -- at REST; the band moves with the camera

local HOLD, STABLE, SETTLE_MAX = 320, 10, 300
local FIGHT_FOR = 1800
local SWEEP = 520
local RUN_L0, RUN_R0 = 5, 581        -- TWR_RUNL0 and its r0 (src/TWRBKREF.ASM)
local CLIMB_UP = 90                  -- how far above his rest y P1 is held

-- MK2_BK_PAN=1 replaces the five checking stops with a PAN: the fighters are
-- walked across the whole scroll range in even steps and the camera is let
-- settle at each, so the snapshots are a filmstrip of one walk.  It is for
-- looking at how a plane parallaxes - the guards are only ever on screen near
-- one limit, so a single stop cannot show their motion at all.
local PAN = tonumber(os.getenv("MK2_BK_PAN") or "0") or 0
-- MK2_BK_GATE=<px> MOCKS the guard gate at runtime, before any of it is built
-- in asm: every frame each guard block on baklst3 is pushed INWARD by
--   px * min(1, |camera - centre| / range)
-- left group one way, right group the other, so the row closes as the camera
-- leaves the centre and opens back out at it.  Objects are moved by oxval
-- (oxpos is recomputed from it every frame), and each object's own base x is
-- remembered the first time it is seen, so the offset never accumulates.
local GATE = tonumber(os.getenv("MK2_BK_GATE") or "0") or 0
local GATE_RANGE = 300          -- camera px from centre at which the gate is fully shut
local gate_base = {}
local PAN_STEPS = tonumber(os.getenv("MK2_BK_PAN_STEPS") or "9") or 9

local STOPS = {
    {name = "mid",   p1 = 400,  p2 = 720},
    -- left/right keep the fighters FLANKING the runner, which sits near the far
    -- edge at either limit. Parked on top of it they hid it, and the first
    -- runner check took a fighter's red trousers for the carpet.
    {name = "left",  p1 = 40,   p2 = 330},
    {name = "right", p1 = 780,  p2 = 1090},
    {name = "climb", p1 = 400,  p2 = 720, climb = true},
}

if PAN ~= 0 then
    STOPS = {}
    -- p1 40..780 is the range the left/right stops use; p2 trails by 320 so
    -- the pair stays together and the camera tracks the midpoint.
    for i = 0, PAN_STEPS - 1 do
        local x = 40 + math.floor((780 - 40) * i / (PAN_STEPS - 1))
        STOPS[#STOPS + 1] = {name = string.format("pan%02d", i), p1 = x, p2 = x + 320}
    end
end

local fields, cpu, space = {}, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local done_frame = 0
local fails = 0

-- sequencer
local phase, si, pt = "stops", 1, 0     -- phase, stop index, frames in this stop
local stable, last_wy, last_oc = 0, nil, nil
local p1_rest_y = nil
local ledge_p1, ledge_p2, ledge_k = 780, 1090, 0
local ctime = 0
local ovhist, ovpk = {}, 0
local billhist, billsum, billpk, billworst = {}, 0, 0, nil
local drophist, last_late = {}, 0
local offstage, offhist, offdrop = 0, {}, {}
local cloudx = {}
-- How much the camera actually moves in a real fight, which is the whole
-- question behind "the pillars move when I jump".  climbed = ceiling_y -
-- worldtly, so 0 is at rest and climb_limit is the cap.
local clhist, clpk, clframes = {}, 0, 0
-- ...and WHY. scrl6 scrolls up while either fighter's oypos is at or above
-- worldtly+16+40, and otherwise walks back down to ceiling_y. If the camera
-- is stuck high, one of those two is not doing what it looks like.
local abov, minoy = 0, 9999
local min1, min2, late1, late2 = 9999, 9999, 9999, 9999

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end

-- Park x, and PIN y as well. The drone jumps, the camera chases it vertically
-- and worldtly never holds still - "camera never came to rest" at two stops,
-- which is exactly the state that put the logged worldtly two rows from the
-- picture. Both fighters are held at the y they rest at, so the only thing
-- that moves the camera vertically is the climb stop, deliberately.
local rest_y = {}
local function park_both(x1, x2, pin_y)
    local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
    if o1 ~= 0 then
        w32(o1 + O.oxval, (x1 & 0xffff) << 16)
        if pin_y ~= false then
            if not rest_y[1] then rest_y[1] = r32(o1 + O.oyval) end
            w32(o1 + O.oyval, rest_y[1]); w32(o1 + O.oyvel, 0)
        end
    end
    if o2 ~= 0 then
        w32(o2 + O.oxval, (x2 & 0xffff) << 16)
        if not rest_y[2] then rest_y[2] = r32(o2 + O.oyval) end
        w32(o2 + O.oyval, rest_y[2]); w32(o2 + O.oyvel, 0)
    end
end
local function runner_first_x()
    -- floor division, NOT >>: Lua's >> is a logical shift and the skew is
    -- negative whenever the camera is right of centre
    local oc, dx = s32(r32(A.skew_oc)), s32(r32(A.skew_dx))
    return RUN_R0 - 400 + ((oc + RUN_L0 * dx) // 65536)
end
-- Consecutive frames with the camera still, in both axes - judged on the
-- INTEGER parts. worldtly and skew_oc are 16.16 and the scroller converges
-- asymptotically, so the low bits keep twitching long after the picture has
-- stopped moving; comparing the whole word meant "never at rest" forever, and
-- a snapshot taken anyway sat ~2px from its own logged state.
local drift_wy, drift_oc = 0, 0
local function track_stable()
    local wy, oc = s32(r32(A.worldtly)) // 65536, s32(r32(A.skew_oc)) // 65536
    if wy == last_wy and oc == last_oc then
        stable = stable + 1
    else
        if last_wy then drift_wy, drift_oc = wy - last_wy, oc - last_oc end
        stable = 0
    end
    last_wy, last_oc = wy, oc
end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 High Punch"]=true, ["P2 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end
local function screen1()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap(label)
    local s = screen1(); if s then pcall(function() s:snapshot() end) end
    print("[bk] SNAP " .. label)
end
local function list(head)
    local out, p = {}, r32(head)
    while p ~= 0 and #out < 200 do out[#out + 1] = p; p = r32(p + O.next) end
    return out
end
local function ceil_div(a, b) return (a + b - 1) // b end
-- the follower's depth mapping, read from the generated data so the rig can
-- never disagree with it (src/TWRBKREF.ASM: TWR_BKR, TWR_BKDMAX, TWR_BKSTEP)
local MROWS, DMAX, SKYSTEP = 54, 200, 949
do
    local fh = io.open(ROOT .. "/src/TWRBKREF.ASM", "r")
    if fh then
        local t = fh:read("a"); fh:close()
        MROWS = tonumber(t:match("TWR_BKR%s+%.set%s+(%d+)")) or MROWS
        DMAX = tonumber(t:match("TWR_BKDMAX%s+%.set%s+(%d+)")) or DMAX
        local s = t:match("TWR_BKSTEP%s+%.set%s+0*(%x%x%x%x)0100h")
        if s then SKYSTEP = tonumber(s, 16) end
    end
end
local function dmap(d) if d > 319 then d = 319 end return (d * MROWS) // DMAX end
local function drawn_sky(h)
    if h > 319 then h = 319 end
    return (h * 256 + SKYSTEP - 1) // SKYSTEP
end

-- CHARGED dma time, the way the emulators bill it (FBNeo midtunit_dma.h,
-- ported from MAME): 41 ns a pixel of the PROGRAMMED blit - an unscaled
-- blit pays its whole w*h, transparent pixels and off-screen overhang
-- included; a scaled one pays only its drawn size, (w<<8/xstep)*(h<<8/ystep).
-- One 54.7 Hz frame is 18.28 ms, so ~445,800 charged pixels is the ceiling.
-- Cells run down from objq_1 (dma_q + 500 cells); the consumer copies each
-- one top-down into the DMA register block, so a cell reads, ascending:
-- ctrl:offset, sag, dest, size, const:pal, scale.  The queue is not cleared
-- after it drains, so the last frame's cells are still there to read.
-- breakdown=false skips the per-list attribution (the display-list walk is
-- the expensive part) and returns just the total.
-- How long each list the tower draws from is, and whether it still ends.  A
-- list that grows over a fight, or runs into another list, bills the dma for
-- the same art over and over; the walk stops at 2000 and says so.
function list_census()
    local L = {{"baklst1", symbols["baklst1"]}, {"baklst2", symbols["baklst2"]},
        {"baklst3", A.baklst3}, {"baklst4", A.baklst4}, {"baklst5", A.baklst5},
        {"baklst6", A.baklst6}, {"baklst7", A.baklst7}, {"baklst8", A.baklst8},
        {"twr_bsky", A.sky}, {"twr_bwall", A.wall}, {"twr_bmonk", A.monk},
        {"twr_prefl", symbols["twr_prefl_lst"]}}
    local parts, owner = {}, {}
    for _, l in ipairs(L) do
        if l[2] then
            local o, n, seen, note = r32(l[2]), 0, {}, ""
            while o ~= 0 do
                if seen[o] then note = "CYCLE"; break end
                if owner[o] and owner[o] ~= l[1] then note = "->" .. owner[o]; break end
                seen[o] = true; owner[o] = l[1]
                n = n + 1
                if n >= 2000 then note = "2000+"; break end
                o = r32(o + O.next)
            end
            parts[#parts + 1] = l[1] .. "=" .. n .. (note ~= "" and ("[" .. note .. "]") or "")
        end
    end
    return table.concat(parts, " ")
end

function dma_bill(cells, breakdown)
    local top = symbols["dma_q"] + 500 * 192
    local sagmap = {}
    if breakdown then
        -- which display list queued each blit: every object's osag is what the
        -- display pass hands the queue, so match on it
        local lists = {{"baklst2 high clouds", symbols["baklst2"]}, {"baklst8 clouds", A.baklst8},
            {"baklst7 clouds", A.baklst7}, {"baklst6 wall", A.baklst6},
            {"refl: clouds", A.sky}, {"refl: wall", A.wall}, {"refl: monk", A.monk},
            {"refl: pillars", symbols["twr_prefl_lst"]}, {"baklst5 monk", A.baklst5},
            {"baklst4 pillars", A.baklst4}, {"baklst1 guard refl+torch", symbols["baklst1"]},
            {"baklst3 guards", A.baklst3}}
        for _, L in ipairs(lists) do
            if L[2] then
                local o, n = r32(L[2]), 0
                while o ~= 0 and n < 400 do
                    sagmap[r32(o + O.osag)] = L[1]; o = r32(o + O.next); n = n + 1
                end
            end
        end
    end
    local cat, order, tot, bad = {}, {}, 0, 0
    for i = 0, cells - 1 do
        local base = top - (i + 1) * 192
        local size = r32(base + 96)
        local scale = r32(base + 160)
        local w, h = size & 0xffff, (size >> 16) & 0xffff
        local xs, ys = scale & 0xffff, (scale >> 16) & 0xffff
        local a
        if xs == 0x100 and ys == 0x100 then a = w * h
        elseif xs > 0 and ys > 0 then a = ((w << 8) // xs) * ((h << 8) // ys)
        else a = 0 end
        tot = tot + a
        if breakdown then
            local ctrl = (r32(base) >> 16) & 0xffff
            local sag = r32(base + 32)
            if ctrl & 0x8000 == 0 then bad = bad + 1 end
            local k
            if sagmap[sag] then
                -- a reflection reuses its original's art, so the SAG alone
                -- cannot tell them apart; the scale can - reflections are squashed
                local base_name = sagmap[sag]:gsub("^refl: ", "")
                k = base_name .. ((xs == 0x100 and ys == 0x100) and " (original)" or " (reflection)")
            elseif sag >= 0x05cb0000 and sag < 0x05cb0000 + 388800 then k = "joints pass"
            elseif ctrl == 0xE00C then k = "sky backing"
            elseif sag >= 0x0506cfc0 and sag < 0x0506cfc0 + 540000 then k = "floor rows"
            elseif sag == 0x02000000 then k = "hud bars"
            elseif not (xs == 0x100 and ys == 0x100) then k = "other scaled"
            else k = "fighters/fx/hud/other" end
            if not cat[k] then cat[k] = {0, 0}; order[#order + 1] = k end
            cat[k][1] = cat[k][1] + 1; cat[k][2] = cat[k][2] + a
        end
    end
    table.sort(order, function(x, y) return cat[x][2] > cat[y][2] end)
    return tot, cat, order, bad
end

function print_bill(cells, tot, cat, order, bad)
    print(string.format("[bk]   dma CHARGED: %d cells, %d px = %.2f ms of 18.28 (%.0f%% of the frame)%s",
        cells, tot, tot * 41e-6, 100 * tot * 41e-6 / 18.28,
        bad > 0 and string.format(" (%d cells without dmago - layout suspect)", bad) or ""))
    for _, k in ipairs(order) do
        print(string.format("[bk]      %-26s %4d blits %7d px  %5.2f ms", k,
            cat[k][1], cat[k][2], cat[k][2] * 41e-6))
    end
end

local function check(label)
    local wtly = s16(r32(A.worldtly) >> 16)
    local wx6 = s16(r32(A.worldtlx6) >> 16)
    local climb = s16(r16(A.ceiling_y)) - wtly     -- rows the camera has climbed
    local sky, wall, monk = list(A.sky), list(A.wall), list(A.monk)
    local s8, s7, s5 = list(A.baklst8), list(A.baklst7), list(A.baklst5)
    print(string.format("[bk] === %s  worldtlx6=%d worldtly=%d (camera climbed %d, still %d frames) ===",
        label, wx6, wtly, climb, stable))
    -- everything tools/tower_runner_overlay_check.py needs to put the runner
    -- exactly where floor_code put it on this frame
    print(string.format("[bk] skew oc=%d dx=%d skew_y=%d ceiling_y=%d worldtly=%d",
        s32(r32(A.skew_oc)), s32(r32(A.skew_dx)), s16(r16(A.skew_y)),
        s16(r16(A.ceiling_y)), wtly))
    print(string.format("[bk] lists: wall=%d sky=%d (sources %d+%d) monk=%d (source %d)",
        #wall, #sky, #s8, #s7, #monk, #s5))
    if #sky ~= #s8 + #s7 then print("[bk] FAIL sky list does not pair with its sources"); fails = fails + 1 end
    if #monk ~= #s5 then print("[bk] FAIL monk list does not pair with its source"); fails = fails + 1 end

    -- wall: drawn rows with the MEASURED rule, on screen only. The marble band
    -- moves down with a climbing camera, exactly as the floor does.
    local mtop, ctop = MARBLE_TOP + climb, CARPET_TOP + climb
    local onscreen, off, lo, hi = 0, 0, 999, -999
    for _, o in ipairs(wall) do
        local x = s16(r16(o + O.oxpos)) - wx6
        local w = r32(o + O.osize) & 0xffff
        if x + w > 0 and x < 400 then
            onscreen = onscreen + 1
            local h = r16(o + O.osizey)
            local step = r32(o + O.oscale) >> 16
            local drawn = ceil_div(h * 256, step)
            local y = s16(r16(o + O.oypos))
            local top = y + h - drawn - wtly          -- screen
            local bot = y + h - 1 - wtly
            if top < lo then lo = top end
            if bot > hi then hi = bot end
            if top < mtop or bot >= ctop then off = off + 1 end
        end
    end
    print(string.format("[bk] wall: %d on screen, drawn rows %d..%d (marble %d..%d), %d outside it",
        onscreen, lo, hi, mtop, ctop - 1, off))
    if off > 0 then fails = fails + 1 end

    -- sky + monk: each reflection against its source
    local function pair(srcs, dsts, first, name)
        local bad = 0
        for i, s in ipairs(srcs) do
            local d = dsts[first + i - 1]
            if not d then bad = bad + 1 else
                local h = r16(s + O.osizey)
                local y0 = s16(r16(s + O.oypos))
                local parked = y0 >= 0x1000         -- clip_a_row cld7: y + 4000h
                local dlo = BASE - y0 - h
                if dlo < 0 then dlo = 0 end
                local want = parked and y0 or (BASE + dmap(dlo) - h + drawn_sky(h))
                local gy = s16(r16(d + O.oypos))
                local ok = r16(d + O.oxpos) == r16(s + O.oxpos)
                          and r32(d + O.osag) == r32(s + O.osag)
                          and gy == want
                if not ok then
                    bad = bad + 1
                    print(string.format("[bk]   %s[%d] src x=%d y=%d h=%d sag=%08x | refl x=%d y=%d (want %d) sag=%08x",
                        name, i, s16(r16(s + O.oxpos)), y0, h, r32(s + O.osag),
                        s16(r16(d + O.oxpos)), gy, want, r32(d + O.osag)))
                end
                if parked then
                    print(string.format("[bk]   %s[%d] PARKED by clip_a_row (y=%04x): reflection parked too: %s",
                        name, i, y0, gy == y0 and "yes" or "NO - it is on screen"))
                end
            end
        end
        return bad
    end
    local bad = pair(s8, sky, 1, "row8") + pair(s7, sky, #s8 + 1, "row7") + pair(s5, monk, 1, "monk")
    print(string.format("[bk] sky/monk tracking: %d mismatched", bad))
    if bad > 0 then fails = fails + 1 end

    -- WHAT ACTUALLY MOVES WITH THE CAMERA. Frame differencing said the guard
    -- group is vertically locked while the wall and floor shift with worldtly;
    -- these are the positions themselves, per plane, so there is no doubt which
    -- list is which. screen y = oypos - worldtly for a background object.
    local function first(head, name)
        local o = r32(head)
        if o == 0 then print("[bk]   " .. name .. ": empty"); return end
        local y = s16(r16(o + O.oypos))
        print(string.format("[bk]   %-22s oypos=%4d -> screen y %4d", name, y, y - wtly))
    end
    if A.skybg then
        local o = r32(A.skybg)
        if o == 0 then
            print("[bk]   sky backing: NOT ON ITS LIST")
        else
            print(string.format("[bk]   sky backing (head tile): obj=%08x xy=(%d,%d) size=%dx%d "
                .. "flags=%04x const=%04x pal=%04x sag=%08x",
                o, s16(r16(o + O.oxpos)), s16(r16(o + O.oypos)),
                r16(o + O.osize), r16(o + O.osizey), r16(o + O.oflags),
                r16(o + 0x150), r16(o + O.opal), r32(o + O.osag)))
        end
    end
    first(A.baklst3, "baklst3 guards")
    first(A.baklst4, "baklst4 pillars")
    first(A.baklst6, "baklst6 wall")
    first(A.wall,    "reflected wall")
    for i, h in ipairs({A.p1_obj, A.p2_obj}) do
        local o = r32(h)
        if o ~= 0 then
            local y = s16(r16(o + O.oypos))
            print(string.format("[bk]   fighter %d          oypos=%4d -> screen y %4d  (h=%d)",
                i, y, y - wtly, r16(o + O.osizey)))
        end
    end
    -- shad0 draws a shadow at screen ground_y PLUS a per-character adjust
    -- (stuff_shad_adj, setup_players), not at the fighter's feet - so these two
    -- numbers are what "lines up with its shadow" actually means here.
    local gy = s16(r16(A.ground_y))
    local a1 = A.p1_shadadj and s16(r16(A.p1_shadadj)) or 0
    local a2 = A.p2_shadadj and s16(r16(A.p2_shadadj)) or 0
    -- Where the frame's DMA work goes, read straight out of the queue.  Cells
    -- run down from objq_1 (dma_q + 500 cells); the consumer copies each one
    -- top-down into the DMA register block, so a cell reads, ascending:
    -- ctrl:offset, sag, dest, size, const:pal, scale.  Area is the QUEUED
    -- w*h - hardware clipping happens after this, so an object hanging off the
    -- screen edge is counted whole.
    -- CHARGED dma time, the way the emulators bill it (FBNeo midtunit_dma.h,
    -- ported from MAME): 41 ns a pixel of the PROGRAMMED blit - an unscaled
    -- blit pays its whole w*h, transparent pixels and off-screen overhang
    -- included; a scaled one pays only its drawn size, (w<<8/xstep)*(h<<8/ystep).
    -- One 54.7 Hz frame is 18.28 ms, so ~445,800 charged pixels is the ceiling.
    if A.deep_dmaq and symbols["dma_q"] then
        local tot, cat, order, bad = dma_bill(r16(A.deep_dmaq) // 6, true)
        print_bill(r16(A.deep_dmaq) // 6, tot, cat, order, bad)
    end
    if A.deep_dmaq then
        print(string.format("[bk]   dma queue since the last stop: peak %d cells, "
            .. "%d frame(s) left blits undrawn (worst %d)",
            r16(A.deep_dmaq) // 6, r16(A.dmaq_late), r16(A.dmaq_lost)))
        w16(A.deep_dmaq, 0); w16(A.dmaq_late, 0); w16(A.dmaq_lost, 0)
    end
    print(string.format("[bk]   ground_y=%d -> screen %d   floor top row=%d", gy,
        gy - wtly, s16(r16(A.skew_y)) + (s16(r16(A.ceiling_y)) - wtly)))
    -- shad0 anchors each shadow at ground_y + shadow_adjustments[char] +
    -- @shad_bias, the stage's own nudge.  Print the bias too, or this line
    -- reports the stock row on a stage that has moved its shadows.
    local sb = A.shad_bias and s16(r16(A.shad_bias)) or 0
    print(string.format(
        "[bk]   shadow row: P1 %d  P2 %d  (adj %+d/%+d, stage bias %+d)",
        gy - wtly + a1 + sb, gy - wtly + a2 + sb, a1, a2, sb))

    local n, p = 0, r32(A.ofree)
    while p ~= 0 and n < 400 do n = n + 1; p = r32(p + O.next) end
    print(string.format("[bk] free objects: %d / 358", n))
    if A.peak_overload then
        print(string.format("[bk] peak_overload=%d qdma_drops=%d",
            r16(A.peak_overload), r16(A.qdma_drops)))
    end
end

local function hold_p1_up()
    local o = r32(A.p1_obj)
    if o == 0 then return end
    if not p1_rest_y then p1_rest_y = s32(r32(o + O.oyval)) end
    w32(o + O.oyval, p1_rest_y - (CLIMB_UP << 16))
    w32(o + O.oyvel, 0)                               -- no fall
end

-- The climb stop leaves P1 hanging at rest_y - CLIMB_UP with oyvel 0, and his
-- state machine still thinks he is STANDING - so nothing pulls him down and he
-- floats there for the rest of the run. The camera then chases him forever:
-- the first combat measurement read "a fighter above the barrier on 100% of
-- frames", which was this rig, not the game. Put him back before releasing.
-- THE DMA TIMELINE, measured rather than modelled.  display runs from the
-- display interrupt straight after @tick is bumped, and init_dma_regs throws
-- away whatever the dma has not reached by the NEXT one - so a frame's blits
-- must all START inside one @tick-to-@tick period.  Two write taps: @tick
-- (the frame boundary) and dmactrl with bit 15 set (a blit starting - the
-- interrupt handler writes the cell top-down, so the control word is its
-- last write, and shadow_p1p2's direct blits land here too).  The last start
-- in a frame, as a fraction of the frame, is the real headroom: it includes
-- the shadows, the per-blit interrupt, and any time the dma sat idle waiting
-- for the CPU to queue more - none of which the pixel bill can see.
-- The handles MUST stay referenced (see hidden_select_victory_test.lua).
local DMACTRL = 0x01a80010
local tl_taps, tl_t0, tl_last, tl_gos, tl_onstage = {}, nil, nil, 0, false
local tl_hist, tl_n, tl_pk, tl_pkgos, tl_sum, tl_per = {}, 0, 0, 0, 0, {}
-- ...and when the CPU finished QUEUING (display writes last_dmaq at dsa9,
-- after the HUD).  If the last blit starts right on its heels the dma was
-- waiting on the CPU; if long after, the dma itself is the bottleneck.
local tl_q, tl_qsum, tl_qpk, tl_gapsum, tl_gossum = nil, 0, 0, 0, 0
-- PER-BLIT OVERHEAD: the gap from one blit's start to the next, less the
-- first one's own pixel time (read back from the size/scale registers the
-- handler has already written when the control word lands).  Whatever is
-- left is the interrupt, the cell copy, and the shadow pass's polling.
local tl_pgo, tl_ppx, tl_ovh, tl_ovn, tl_ovsum, tl_pxsum = nil, 0, {}, 0, 0, 0
local function tl_now()
    local ok, v = pcall(function() return manager.machine.time:as_double() end)
    return ok and v or nil
end
local function tl_close(now)
    if tl_t0 and tl_last and tl_onstage then
        local per = now - tl_t0
        local used = (tl_last - tl_t0) / per
        local k = math.floor(used * 20)          -- 5% buckets
        tl_hist[k] = (tl_hist[k] or 0) + 1
        tl_n = tl_n + 1
        tl_sum = tl_sum + used
        tl_per[#tl_per + 1] = per
        if used > tl_pk then tl_pk, tl_pkgos = used, tl_gos end
        if tl_q then
            local q = (tl_q - tl_t0) / per
            tl_qsum = tl_qsum + q
            if q > tl_qpk then tl_qpk = q end
            tl_gapsum = tl_gapsum + (tl_last - tl_q)
        end
        tl_gossum = tl_gossum + tl_gos
    end
    tl_t0, tl_last, tl_gos, tl_q, tl_pgo = now, nil, 0, nil, nil
end
local function tl_install()
    if #tl_taps > 0 then return end
    local ok, err = pcall(function()
        tl_taps[1] = space:install_write_tap(symbols["tick"], symbols["tick"] + 15, "bktick",
            function(offset, data, mask)
                local now = tl_now(); if now then tl_close(now) end
                return data
            end)
        tl_taps[3] = space:install_write_tap(symbols["last_dmaq"], symbols["last_dmaq"] + 15, "bkq",
            function(offset, data, mask) tl_q = tl_now(); return data end)
        tl_taps[2] = space:install_write_tap(DMACTRL, DMACTRL + 15, "bkdma",
            function(offset, data, mask)
                if data & 0x8000 ~= 0 then
                    local now = tl_now()
                    tl_last = now; tl_gos = tl_gos + 1
                    local size = space:read_u32(0x01a80060)
                    local scale = space:read_u32(0x01a800a0)
                    local w, h = size & 0xffff, (size >> 16) & 0xffff
                    local xs, ys = scale & 0xffff, (scale >> 16) & 0xffff
                    local px
                    if xs == 0x100 and ys == 0x100 then px = w * h
                    elseif xs > 0 and ys > 0 then px = ((w << 8) // xs) * ((h << 8) // ys)
                    else px = 0 end
                    if tl_onstage and now and tl_pgo then
                        local ov = (now - tl_pgo) - tl_ppx * 41e-9
                        local k = math.floor(ov * 1e6 / 2)      -- 2 us buckets
                        if k < 0 then k = -1 end
                        if k > 40 then k = 40 end
                        tl_ovh[k] = (tl_ovh[k] or 0) + 1
                        tl_ovn = tl_ovn + 1; tl_ovsum = tl_ovsum + ov; tl_pxsum = tl_pxsum + tl_ppx
                    end
                    tl_pgo, tl_ppx = now, px
                end
                return data
            end)
    end)
    print("[bk] dma timeline taps: " .. (ok and "installed" or ("unavailable - " .. tostring(err))))
end
local function tl_report()
    if tl_n == 0 then print("[bk] dma timeline: no frames measured"); return end
    local ks = {}
    for k in pairs(tl_hist) do ks[#ks + 1] = k end
    table.sort(ks)
    table.sort(tl_per)
    print(string.format("[bk] dma timeline, fighting on THE TOWER: %d frames, the last blit "
        .. "started at %.0f%% of the frame on average, %.0f%% at worst (%d blits that frame); "
        .. "frame period %.2f-%.2f ms", tl_n, 100 * tl_sum / tl_n, 100 * tl_pk, tl_pkgos,
        1000 * tl_per[1], 1000 * tl_per[#tl_per]))
    print(string.format("[bk]    the CPU finished queuing at %.0f%% on average, %.0f%% at worst; "
        .. "the last blit started %.2f ms after that on average; %.0f blits started a frame",
        100 * tl_qsum / tl_n, 100 * tl_qpk, 1000 * tl_gapsum / tl_n, tl_gossum / tl_n))
    if tl_ovn > 0 then
        print(string.format("[bk]    per-blit overhead: %.1f us on average over %d blit gaps "
            .. "(= %.0f px of 41 ns); the pixels themselves averaged %.0f px a blit",
            1e6 * tl_ovsum / tl_ovn, tl_ovn, tl_ovsum / tl_ovn / 41e-9, tl_pxsum / tl_ovn))
        local ok = {}
        for k in pairs(tl_ovh) do ok[#ok + 1] = k end
        table.sort(ok)
        local parts = {}
        for _, k in ipairs(ok) do
            parts[#parts + 1] = string.format("%s%d:%d", k == 40 and ">=" or "", 2 * k, tl_ovh[k])
        end
        print("[bk]    overhead histogram (us:count): " .. table.concat(parts, " "))
    end
    for _, k in ipairs(ks) do
        print(string.format("[bk]    last blit at %3d-%3d%%: %5d frames", 5 * k, 5 * k + 5, tl_hist[k]))
    end
end

-- Does the stock shadow loop's CPU row walk find the same rows the DMA's own
-- walk does?  shad7 hard-codes 6 bits a pixel and does not clamp a row whose
-- lead+trail zeros exceed its width; the DMA (FBNeo midtunit_dma.h, the
-- scaled skip path) uses the piece's own bpp and skips nothing for such a
-- row.  shadf hands the walk to the DMA, so anywhere these differ, the two
-- shadows differ - and the DMA's is the one that matches the sprite.
local swc = {pieces = 0, bpp = {}, bad = 0, why = {}, seen = {}}
local function gbits(bitaddr, n)
    local a = 0x02000000 + bitaddr
    local base = a & ~15
    local v = space:read_u32(base) | (space:read_u16(base + 32) << 32)
    return (v >> (a - base)) & ((1 << n) - 1)
end
local function shadow_walk_check()
    for _, po in ipairs({A.p1_obj, A.p2_obj}) do
        local o = r32(po)
        if o ~= 0 then
            local mp, k = r32(o + 0x1a0), 0
            while k < 11 do
                local sag = r32(mp)
                if sag == 0 then break end
                local sx, sy, ctl = r16(mp + 32), r16(mp + 48), r16(mp + 64)
                local bpp = (ctl >> 12) & 7; if bpp == 0 then bpp = 8 end
                local pre, post = (ctl >> 8) & 3, (ctl >> 10) & 3
                swc.pieces = swc.pieces + 1
                swc.bpp[bpp] = (swc.bpp[bpp] or 0) + 1
                if ctl & 0x80 == 0 then swc.unc = (swc.unc or 0) + 1 end
                local n = sy // 4
                if n > 0 and not swc.seen[sag] then
                    swc.seen[sag] = true
                    local c, d = sag, sag     -- CPU row start, DMA row start
                    for r = 0, 4 * (n - 1) - 1 do
                        local hc, hd = gbits(c, 8), gbits(d, 8)
                        c = c + 8 + (sx - ((hc & 15) << pre) - ((hc >> 4) << post)) * 6
                        local w = sx - ((hd & 15) << pre) - ((hd >> 4) << post)
                        -- bit 7 clear = NOT zero-compressed: the DMA reads no
                        -- header at all, every row is sx*bpp bits
                        if ctl & 0x80 == 0 then d = d + sx * bpp
                        else d = d + 8 + (w > 0 and w * bpp or 0) end
                        if c ~= d then
                            local why = (ctl & 0x80 == 0) and "uncompressed piece - shad7 reads a header it does not have"
                                        or (bpp ~= 6) and ("bpp " .. bpp)
                                        or (w < 0 and "lead+trail > width" or "?")
                            swc.bad = swc.bad + 1
                            swc.why[why] = (swc.why[why] or 0) + 1
                            if swc.bad <= 8 then
                                print(string.format("[bk] shadow walk: piece sag %08x %dx%d ctl %04x "
                                    .. "- CPU and DMA part at source row %d (%s)", sag, sx, sy, ctl, r + 1, why))
                            end
                            break
                        end
                    end
                end
                mp = mp + 112; k = k + 1
            end
        end
    end
end

-- What the machine is drawing once the fight is over: the display table
-- dlists points at, each list in it and its length, and the per-tick hook.
-- On THE TOWER the continue screen dropped 780 frames; on Dead Pool, none.
local symname = nil
local function sname(a)
    if not symname then
        symname = {}
        for k, v in pairs(symbols) do
            if not symname[v] or #k < #symname[v] then symname[v] = k end
        end
    end
    return symname[a] or string.format("%08x", a)
end
local function after_fight_dump(tag)
    local dl = r32(symbols["dlists"])
    local parts, e = {}, dl
    for i = 1, 20 do
        if dl == 0 then break end
        local l = r32(e)
        if l == 0 then break end
        if l >= 0x80000000 then
            parts[#parts + 1] = (l == 0xffffffff) and "[-1 " .. sname(r32(e + 32)) .. "]" or string.format("[%08x]", l)
        else
            local o, n = r32(l), 0
            while o ~= 0 and n < 999 do n = n + 1; o = r32(o) end
            parts[#parts + 1] = sname(l) .. "=" .. n
        end
        e = e + 64
    end
    print(string.format("[bk] %s: gstate %d dlists=%s  %s  call_every_tick=%s f_auto_erase=%d cells=%d",
        tag, r16(A.gstate), sname(dl), table.concat(parts, " "),
        sname(r32(symbols["call_every_tick"])), r16(symbols["f_auto_erase"]),
        r16(A.last_dmaq) // 6))
end

local function release_p1()
    local o = r32(A.p1_obj)
    if o ~= 0 and p1_rest_y then
        w32(o + O.oyval, p1_rest_y)
        w32(o + O.oyvel, 0)
    end
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

local function finish()
    local keys = {}
    for k in pairs(ovhist) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format("ov%d=%.1f%%", k, 100 * ovhist[k] / FIGHT_FOR)
    end
    local pk = A.peak_overload and r16(A.peak_overload) or -1
    local dr = A.qdma_drops and r16(A.qdma_drops) or -1
    do
        local rows, tot = {}, 0
        for k, v in pairs(clhist) do rows[#rows + 1] = k; tot = tot + v end
        table.sort(rows)
        local parts = {}
        for _, k in ipairs(rows) do
            parts[#parts + 1] = string.format("%d:%.1f%%", k, 100 * clhist[k] / tot)
        end
        print(string.format("[bk] camera climb: peak %d, moved on %.1f%% of frames  [%s]",
            clpk, 100 * clframes / tot, table.concat(parts, " ")))
        print(string.format("[bk] climb cause: a fighter was above the barrier on "
            .. "%.1f%% of frames; highest oypos seen %d", 100 * abov / tot, minoy))
        print(string.format("[bk] highest each fighter got: P1 %d P2 %d  "
            .. "(after frame 600: P1 %d P2 %d; standing is about 95, "
            .. "the barrier is worldtly+40)", min1, min2, late1, late2))
    end
    print(string.format("[bk] combat: %s  sampled peak=%d  peak_overload=%d qdma_drops=%d",
        table.concat(parts, " "), ovpk, pk, dr))
    if dr ~= 0 then print("[bk] FAIL sprites dropped in combat"); fails = fails + 1 end
    if A.deep_dmaq then
        local w, ov = r16(A.deep_dmaq), r16(A.dmaq_over)
        print(string.format("[bk] object dma queue: deepest %d of 500 cells (%d%%), "
            .. "ran off the end on %d frame(s)", w // 6, (w // 6) * 100 // 500, ov))
        if A.dmaq_late then
            local la, lo = r16(A.dmaq_late), r16(A.dmaq_lost)
            print(string.format("[bk] blits that never drained: %d frame(s), worst %d "
                .. "entries abandoned  <-- the HUD is queued last", la, lo))
            -- ...split by where: the rig's idle P1 loses, and the CONTINUE
            -- screen drops frames of its own that are nothing to do with this stage
            local on, off = 0, 0
            for _, v in pairs(drophist) do on = on + v end
            for _, v in pairs(offdrop) do off = off + v end
            print(string.format("[bk]   of those, %d while fighting on THE TOWER and %d after the "
                .. "fight was over (continue screen etc.)", on, off))
            if on > 0 then
                print("[bk] FAIL the HUD dropped out while fighting on THE TOWER"); fails = fails + 1
            end
        end
        if ov ~= 0 then
            print("[bk] FAIL the object dma queue overran - it has no bound check")
            fails = fails + 1
        end
    end
    if next(billhist) then
        local ks = {}
        for k in pairs(billhist) do ks[#ks + 1] = k end
        table.sort(ks)
        print(string.format("[bk] combat frames not fighting on THE TOWER: %d", offstage))
        print(string.format("[bk] combat dma bill ON THE TOWER: mean %.2f ms, worst %.2f ms of 18.28",
            billsum / math.max(1, FIGHT_FOR - offstage), billpk * 41e-6))
        for _, k in ipairs(ks) do
            print(string.format("[bk]    %2d-%2d ms: %5d frames  %5d dropped", k, k + 1,
                billhist[k], drophist[k] or 0))
        end
        if offstage > 0 then
            ks = {}
            for k in pairs(offhist) do ks[#ks + 1] = k end
            table.sort(ks)
            print("[bk]  ...and the frames OFF the tower (another stage - not this work's bill):")
            for _, k in ipairs(ks) do
                print(string.format("[bk]    %2d-%2d ms: %5d frames  %5d dropped", k, k + 1,
                    offhist[k], offdrop[k] or 0))
            end
        end
        if billworst then
            print(string.format("[bk] the worst combat frame (c%d):", billworst[6]))
            print_bill(billworst[1], billworst[2], billworst[3], billworst[4], billworst[5])
            print("[bk]   lists then: " .. (billworst[7] or "?"))
        end
    end
    tl_report()
    do
        local bp, why = {}, {}
        for k, v in pairs(swc.bpp) do bp[#bp + 1] = k .. "bpp:" .. v end
        for k, v in pairs(swc.why) do why[#why + 1] = k .. ":" .. v end
        local nseen = 0
        for _ in pairs(swc.seen) do nseen = nseen + 1 end
        print(string.format("[bk] shadow walk check: %d distinct pieces (%s; %d piece-frames "
            .. "uncompressed); CPU and DMA walks differ on %d  %s", nseen, table.concat(bp, " "),
            swc.unc or 0, swc.bad, table.concat(why, " ")))
    end
    if pk > 4 then print("[bk] FAIL overrun beyond the stock stages' worst (4)"); fails = fails + 1 end
    done_frame = frame
    print(string.format("[bk] RESULT %s (%d failing check group(s))",
        fails == 0 and "PASS" or "FAIL", fails))
    print("[bk] finished")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[bk] loaded, THE TOWER, tag=" .. TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            if A.peak_overload then w16(A.peak_overload, 0); w16(A.qdma_drops, 0) end
        end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, 1); w16(A.p2_char, 2); w16(A.curback, TOWER)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, TOWER) end
    if NOSKIP ~= 0 and A.skew_skip then w16(A.skew_skip, 0) end
    if NOSHAD ~= 0 and A.f_shadows then w16(A.f_shadows, 0) end
    if SHADBIAS and A.shad_bias then w16(A.shad_bias, tonumber(SHADBIAS)) end
    if SHADFAST and symbols["shad_fast"] then w16(symbols["shad_fast"], tonumber(SHADFAST)) end
    if GATE ~= 0 and A.baklst3 then
        local cam = s16(r32(A.worldtlx) >> 16) - 361
        local g = GATE * math.min(1, math.abs(cam) / GATE_RANGE)
        local o, n = r32(A.baklst3), 0
        while o ~= 0 and n < 200 do
            local base = gate_base[o]
            if not base then base = s32(r32(o + O.oxval)); gate_base[o] = base end
            -- plane x 561 is the stage centre the module is built around
            local inward = ((base >> 16) < 561) and g or -g
            w32(o + O.oxval, base + math.floor(inward) * 65536)
            o = r32(o + O.next); n = n + 1
        end
    end
    if NOSKY ~= 0 and A.skybg then w32(A.skybg, 0) end
    if NOCLDREF ~= 0 and A.sky then w32(A.sky, 0) end
    if CENTRE ~= 0 and fighting_frame > 0 then
        if A.skew_skip then w16(A.skew_skip, 0) end
        if not centre_done and A.wall and r32(A.wall) ~= 0 then
            print(string.format("[bk] centre-only: dropped %d wall blocks, %d sky tiles",
                keep_centre(A.wall), keep_centre(A.skybg)))
            centre_done = true
        end
    end
    if NOREFL ~= 0 then
        for _, h in ipairs({A.wall, A.sky, A.monk, A.skybg}) do if h then w32(h, 0) end end
        if A.skew_skip then w16(A.skew_skip, 0) end
    end

    -- MK2_BK_COLBOX=8 turns on cb_anchor (anipoint crosses + the ground_y
    -- line) so a snapshot SHOWS where the fighting line is, instead of us
    -- inferring it from where a shoe looks like it stops. Off by default:
    -- the overlay draws with the CPU and would fail the runner check.
    if COLBOX ~= 0 and A.f_colbox and r16(A.f_colbox) ~= COLBOX then
        w16(A.f_colbox, COLBOX)
    end

    if fighting_frame > 0 and done_frame == 0 then
        -- keep one live round: nobody dies while this runs
        if A.p1_bar then w16(A.p1_bar, 0xA1) end
        if A.deep_dmaq and fighting_frame == frame then
            w16(A.deep_dmaq, 0); w16(A.dmaq_over, 0)
            if A.dmaq_late then w16(A.dmaq_late, 0); w16(A.dmaq_lost, 0) end
        end
        if A.p2_bar then w16(A.p2_bar, 0xA1) end
        if FIGHTONLY ~= 0 and phase == "stops" then
            phase, ctime = "combat", 0
            tl_install()
            print(string.format("[bk] === combat only: %d frames, nothing parked ===",
                FIGHT_FOR))
        end
        track_stable()

        if phase == "stops" then
            local st = STOPS[si]
            park_both(st.p1, st.p2, not st.climb)   -- the climb stop owns P1's y
            if st.climb then hold_p1_up() end
            pt = pt + 1
            if pt >= HOLD and (stable >= STABLE or pt >= HOLD + SETTLE_MAX) then
                if stable < STABLE then
                    print(string.format("[bk] WARNING %s: camera never came to rest "
                        .. "(last step: worldtly %+d, skew %+d px) - checked anyway",
                        st.name, drift_wy, drift_oc))
                end
                check(st.name)
                snap(st.name)
                si, pt = si + 1, 0
                if si > #STOPS then
                    phase = "sweep"
                    p1_rest_y, rest_y[1] = nil, nil   -- he is put back by the sweep
                end
            end

        elseif phase == "sweep" then
            -- after the climb stop the camera is at centre: go to the right
            -- limit first, then sweep left until the runner straddles x=0
            ledge_k = ledge_k + 1
            if ledge_k <= HOLD then
                park_both(780, 1090)
            else
                local k = ledge_k - HOLD
                if k > SWEEP then
                    print("[bk] ledge: the runner never straddled x=0 - left clip NOT exercised")
                    fails = fails + 1
                    release_p1()
                    phase, ctime = "combat", 0
                    tl_install()
                else
                    local d = k * 260 // SWEEP
                    ledge_p1, ledge_p2 = 780 - d, 1090 - d
                    park_both(ledge_p1, ledge_p2)
                    local xf = runner_first_x()
                    if xf >= -22 and xf <= -4 then
                        print(string.format("[bk] ledge: runner first line reached x=%d at p1=%d p2=%d, holding",
                            xf, ledge_p1, ledge_p2))
                        phase, pt = "settle", 0
                    end
                end
            end

        elseif phase == "settle" then
            park_both(ledge_p1, ledge_p2)
            pt = pt + 1
            if pt >= 60 and (stable >= STABLE or pt >= 60 + SETTLE_MAX) then
                print(string.format("[bk] ledge: settled, runner first line at x=%d", runner_first_x()))
                check("ledge")
                snap("ledge")
                release_p1()
                phase, ctime = "combat", 0
                tl_install()
                if A.peak_overload then w16(A.peak_overload, 0); w16(A.qdma_drops, 0) end
                print(string.format("[bk] === combat: %d frames, fighters released ===", FIGHT_FOR))
            end

        elseif phase == "combat" then
            -- COMBAT: nothing parked, the drone fights; sample the per-frame
            -- overload word the way tools/pool_stress.lua does
            ctime = ctime + 1
            -- MK2_BK_SHOTS=n snapshots every n frames of the fight, so the HUD
            -- can be scanned for the artifacting a still frame never catches.
            if SHOTS > 0 and ctime % SHOTS == 0 then snap("c" .. ctime) end
            local wy16 = s16(r32(A.worldtly) >> 16)
            local bar = wy16 + 40
            local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
            local y1 = o1 ~= 0 and s16(r16(o1 + O.oypos)) or 9999
            local y2 = o2 ~= 0 and s16(r16(o2 + O.oypos)) or 9999
            if y1 < minoy then minoy = y1 end
            if y2 < minoy then minoy = y2 end
            if y1 < min1 then min1 = y1 end
            if y2 < min2 then min2 = y2 end
            -- the first 600 frames still carry the climb stop's leftovers, so
            -- the honest figure is the tail
            if ctime > 600 then
                if y1 < late1 then late1 = y1 end
                if y2 < late2 then late2 = y2 end
            end
            if y1 <= bar or y2 <= bar then abov = abov + 1 end
            local cl = s16(r16(A.ceiling_y)) - wy16
            clhist[cl] = (clhist[cl] or 0) + 1
            if cl > clpk then clpk = cl end
            if cl ~= 0 then clframes = clframes + 1 end
            if A.overload then
                local ov = r16(A.overload)
                ovhist[ov] = (ovhist[ov] or 0) + 1
                if ov > ovpk then ovpk = ov end
            end
            -- this frame's bill; last_dmaq is written by the display walk every
            -- frame, so it and the cells under it are the frame just queued
            if A.last_dmaq and symbols["dma_q"] then
                local cells = r16(A.last_dmaq) // 6
                local tot = dma_bill(cells, false)
                local ms = tot * 41e-6
                local b = math.floor(ms)
                -- the rig does not stop the ladder: a round that ends inside the
                -- 1800 frames moves on, possibly to ANOTHER stage, and its bill
                -- lands in the same histogram unless it is split out here
                -- curback alone is not enough: it stays 3 through the CONTINUE
                -- screen, which bakclr's the stage and switches dlists to
                -- dlists_buyin.  The rig's idle P1 loses the match at about
                -- c850, and every dropped frame of the first combat figures
                -- was that screen, not this stage.
                local stg = r16(A.curback)
                local onstage = stg == TOWER and r16(A.gstate) == GS_FIGHTING
                if not onstage then offstage = offstage + 1 end
                if not onstage and offstage == 1 then
                    print(string.format("[bk] combat c%d: the fight on THE TOWER is over (curback %d, "
                        .. "gstate %d) - frames from here are not this stage's", ctime, stg, r16(A.gstate)))
                end
                tl_onstage = onstage
                if ctime % 100 == 1 then
                    print(string.format("[bk] c%d %d cells %.1f ms  %s", ctime, cells, ms, list_census()))
                end
                local H, D = billhist, drophist
                if not onstage then H, D = offhist, offdrop end
                H[b] = (H[b] or 0) + 1
                if onstage then billsum = billsum + ms end
                if onstage and tot > billpk then
                    billpk = tot
                    local _, cat, order, bad = dma_bill(cells, true)
                    billworst = {cells, tot, cat, order, bad, ctime}
                    billworst[7] = list_census()
                end
                -- which frames dropped: dmaq_late counts one per frame that
                -- left blits behind, so a step in it lands on the bill's bucket
                if A.dmaq_late then
                    local la = r16(A.dmaq_late)
                    if la ~= last_late then
                        D[b] = (D[b] or 0) + 1
                        last_late = la
                        if not onstage then
                            offdrops_logged = (offdrops_logged or 0) + 1
                            if offdrops_logged <= 40 then
                                print(string.format("[bk]   dropped c%d: gstate %d dlists=%s cells %d lost %d "
                                    .. "f_skew %d displayon %d f_auto_erase %d", ctime, r16(A.gstate),
                                    sname(r32(symbols["dlists"])), cells, r16(A.dmaq_lost),
                                    r16(symbols["f_skew"]), r16(symbols["displayon"]), r16(symbols["f_auto_erase"])))
                            end
                        end
                    end
                end
            end
            shadow_walk_check()
            -- cloud drift, measured: every object on each cloud list at c100
            -- and c110; the MEDIAN per-tick delta, because clip_a_row
            -- repositions the clouds at the window edges (wraps and clips)
            if ctime == 100 or ctime == 110 then
                for _, L in ipairs({{"baklst7 row", A.baklst7}, {"baklst8 row", A.baklst8},
                                    {"high clouds", symbols["baklst2"]}}) do
                    local o, n = L[2] and r32(L[2]) or 0, 0
                    cloudx[L[1]] = cloudx[L[1]] or {}
                    while o ~= 0 and n < 40 do
                        local x = s32(r32(o + O.oxval)) / 65536
                        local e = cloudx[L[1]][o]
                        if ctime == 100 then cloudx[L[1]][o] = {x} elseif e then e[2] = x end
                        o = r32(o + O.next); n = n + 1
                    end
                end
                if ctime == 110 then
                    for k, objs in pairs(cloudx) do
                        local d = {}
                        for _, e in pairs(objs) do
                            if e[2] then d[#d + 1] = (e[2] - e[1]) / 10 end
                        end
                        table.sort(d)
                        if #d > 0 then
                            print(string.format("[bk] cloud drift %-12s median %.3f px/tick over %d clouds (all: %s)",
                                k, d[(#d + 1) // 2], #d, table.concat((function()
                                    local s = {} for _, v in ipairs(d) do s[#s + 1] = string.format("%.2f", v) end return s end)(), " ")))
                        end
                    end
                end
            end
            if ctime >= FIGHT_FOR then finish() end
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 7000 then print("[bk] TIMEOUT"); manager.machine:exit(); return end
    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)
