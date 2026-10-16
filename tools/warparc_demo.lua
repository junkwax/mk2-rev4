-- warparc_demo.lua - Outer Haven's portal crackle
--
-- Phase 1 (FXDEMO_MODE=observe): watch the STOCK warplite sprite.  Where does
-- it draw, when is it up, and is it visible at all?  It is inserted on
-- baklst7, which dlists_port draws FIRST - behind every other plane - so
-- "there is a spark there" is a claim to check, not to assume.
--
-- Phase 2 (FXDEMO_MODE=arc): the same watch against the geometry version, plus
-- geo_pass's own sentinels.
--
-- Phase 3 (FXDEMO_MODE=portal): the PORTAL stage, which keeps the sprite -
-- Outer Haven is the only one that took the geometry.  There the spark now
-- rolls m_flipv per burst (UNUSED_HARDWARE_EFFECTS #1, zero uses in retail),
-- so this reads the bit off the object and photographs both ways up.
--
-- Env: MK2_ROOT, WARP_LOG, WARP_READY, FXDEMO_MODE

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("WARP_LOG") or (ROOT .. "/tools/warparc_demo.log")
local MODE = (os.getenv("FXDEMO_MODE") or "observe"):lower()
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[warp] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
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
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view", "winner_status",
                     "battle_num", "map_position", "pageaddr", "worldtlx", "worldtlx3",
                     "worldtly", "f_freeze_timer", "p1_obj", "p2_obj",
                     "baklst7", "baklst3", "geo_count", "geo_ran", "geo_drew",
                     "geo_dropped", "geo_lastxy", "rand" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_SUBZERO = 1, 8
local OUTER_HAVEN, PORTAL = 22, 7   -- the Portal keeps the stock spark
local ONEXT, OXPOS, OYPOS, OSIZEX, OSIZEY, OXVAL = 0x00, 0x090, 0x0b0, 0x120, 0x130, 0x080

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local snap_index, snap_queue = 0, {}
local READY_PATH = os.getenv("WARP_READY") or (ROOT .. "/tools/warparc_ready.flag")
local ready_written = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap_now(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP %04d %s (ok=%s)", snap_index, label, tostring(ok))
    snap_index = snap_index + 1
end
local function snap(label, delay)
    local at = frame + (delay or 1)
    snap_queue[at] = snap_queue[at] or {}
    table.insert(snap_queue[at], label)
end
local function snap_pump()
    local due = snap_queue[frame]
    if not due then return end
    snap_queue[frame] = nil
    for _, l in ipairs(due) do snap_now(l) end
end

-- walk a plane's object chain, reporting every entry's screen box
local function plane_objs(head)
    local out, o, guard = {}, r32(head), 0
    while o ~= 0 and guard < 64 do
        out[#out + 1] = {
            obj = o,
            x = s16(r16(o + OXPOS)), y = s16(r16(o + OYPOS)),
            w = s16(r16(o + OSIZEX)), h = s16(r16(o + OSIZEY)),
        }
        o = r32(o + ONEXT); guard = guard + 1
    end
    return out
end

local seen, up_runs, was_up, run_start = {}, 0, false, 0
local flipped_bursts = 0
local last_drew = nil
local PAGE_X = 0
local fails, notes = {}, {}
local track_hits, track_checks, blocked_frames, burst_frames = 0, 0, 0, 0
local queue_frames, queue_bad = 0, 0
local function fail(f) fails[#fails + 1] = f; log("FAIL %s", f) end

-- OH_ARC_SX in BGND.ASM.  The archway is ohspiral4BMOD on baklst6 and
-- port_scroll gives plane 6 a rate of ZERO, so the hole does not move on
-- screen at all - measured at eight camera stops by tools/hole_locate.lua.
-- Anything here that recomputes it from a worldtlx is reintroducing the bug.
local ARC_SX, ARC_RX = 203, 9
local function hole_x() return ARC_SX end

-- The void, measured: screen x 193-213, y 130-147.  Every pixel of the bolt
-- has to be inside it, because geo_pass draws in front of everything and the
-- rim is stonework and the top step.  Reaching the CORNERS of this box put 16
-- pixels of bolt on the step - the hole is an oval - so the box is the outer
-- bound and the assertion is on the bolt's own bbox.
local VOID_L, VOID_R, VOID_T, VOID_B = 193, 213, 129, 148
local PAGE0, PAGE1
local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end
-- the bolt is drawn out of boonpal: white 0eh core, blue 0bh glow
local function arc_bbox()
    if not PAGE0 then return nil end
    local best = nil
    for _, page in ipairs({ PAGE0, PAGE1 }) do
        local l, r, t, b, n = 999, -1, 999, -1, 0
        for y = 110, 175 do
            for x = 160, 250 do
                local v = pxv(page, x, y)
                if v == 0x0e or v == 0x0b then
                    n = n + 1
                    if x < l then l = x end
                    if x > r then r = x end
                    if y < t then t = y end
                    if y > b then b = y end
                end
            end
        end
        if n > 8 and (best == nil or n > best.n) then
            best = { l = l, r = r, t = t, b = b, n = n }
        end
    end
    return best
end

local function setx(pobj, x)
    local o = r32(pobj)
    if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                       ["2 Players Start"] = true, ["P1 High Punch"] = true,
                       ["P2 High Punch"] = true, ["UI Select"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("---- Outer Haven portal crackle: %s ----", MODE)
    end
    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = space and r16(A.gstate) or 0
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, MODE == "portal" and PORTAL or OUTER_HAVEN)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space or finished then return end
    snap_pump()

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        PAGE_X = r32(A.pageaddr) & 0xffff
        do
            local pa = r32(A.pageaddr)
            local px, py = pa & 0xffff, (pa >> 16) & 0xffff
            PAGE0 = (py * 512 + px) * 8
            PAGE1 = (((py + 256) % 512) * 512 + px) * 8
        end
        log("fight at frame %d, curback=%d worldtlx=%d worldtlx3=%d worldtly=%d page_x=%d",
            frame, r16(A.curback), s16(r32(A.worldtlx) >> 16),
            s16(r32(A.worldtlx3) >> 16), s16(r32(A.worldtly) >> 16), PAGE_X)
    end
    if fighting_frame == 0 then
        if frame > 9000 then log("never reached a fight"); manager.machine:exit() end
        return
    end

    -- endless round, and keep the fighters out of the middle so the portal is
    -- unobstructed for the first look
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status then w16(A.winner_status, 0) end
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end

    local rel = frame - fighting_frame

    -- what is on the plane the spark lives on
    if rel == 30 then
        for i, o in ipairs(plane_objs(A.baklst7)) do
            log("baklst7[%d] obj=%08x xy=(%d,%d) size=%dx%d", i, o.obj, o.x, o.y, o.w, o.h)
        end
        log("geo sentinels ran=%d drew=%d dropped=%d",
            r16(A.geo_ran), r16(A.geo_drew), r16(A.geo_dropped))
    end

    -- the spark parks itself at 0fffh while it is waiting; anything else is
    -- "up".  Catch the transitions and photograph the up frames.
    local objs = MODE == "arc" and {} or plane_objs(A.baklst7)
    local up, sx, sy, sw, sh = false, 0, 0, 0, 0
    for _, o in ipairs(objs) do
        if o.w <= 40 and o.h <= 40 then          -- the warplite frames are 13-26px
            if o.x ~= 0xfff and o.x ~= -1 then up = true; sx, sy, sw, sh = o.x, o.y, o.w, o.h end
        end
    end
    if MODE ~= "arc" and up and not was_up then
        up_runs = up_runs + 1
        run_start = rel
        -- on the Portal the spark now rolls m_flipv per burst; read it off the
        -- object rather than trusting the picture
        local so = r32(A.baklst7)
        local sfl = so ~= 0 and r16(so + 0x0f0) or 0
        if (sfl & 0x20) ~= 0 then flipped_bursts = flipped_bursts + 1 end
        log("rel=%4d spark UP  at (%d,%d) %dx%d oflags=%04x %s",
            rel, sx, sy, sw, sh, sfl, (sfl & 0x20) ~= 0 and "FLIPPED" or "authored")
        if MODE == "portal" and up_runs <= 6 then
            snap(string.format("spark %d %s", up_runs,
                (sfl & 0x20) ~= 0 and "flipped" or "authored"), 3)
        end
        if up_runs <= 3 then
            snap("spark up " .. up_runs, 2)
            snap("spark up " .. up_runs .. " +6", 8)
            snap("spark up " .. up_runs .. " +12", 14)
        end
    elseif MODE ~= "arc" and was_up and not up then
        log("rel=%4d spark DOWN after %d frames", rel, rel - run_start)
    end
    if MODE ~= "arc" then was_up = up end

    if MODE == "arc" then
        if rel % 120 == 0 then
            log("rel=%4d geo ran=%d drew=%d dropped=%d count=%d",
                rel, r16(A.geo_ran), r16(A.geo_drew), r16(A.geo_dropped), r16(A.geo_count))
        end
        -- a burst is 36 consecutive ticks that emit; catch its start the way
        -- the sprite watch catches the spark going up
        local drew = r16(A.geo_drew)
        local emitting = drew ~= (last_drew or drew) or false
        if emitting and not was_up then
            up_runs = up_runs + 1
            run_start = rel
            log("rel=%4d arc UP  (geo_drew=%d, hole at screen x=%d, worldtlx=%d)",
                rel, drew, hole_x(), s16(r32(A.worldtlx) >> 16))
            if up_runs == 2 then
                for k = 1, 6 do snap(string.format("burst 2 frame %d", k), k + 1) end
            elseif up_runs <= 8 then
                snap(string.format("arc burst %d (worldtlx %d)", up_runs,
                    s16(r32(A.worldtlx) >> 16)), 3)
            end
        elseif was_up and not emitting then
            log("rel=%4d arc DOWN after %d frames", rel, rel - run_start)
        end
        -- Does the bolt actually TRACK the hole?  geo_lastxy is the last
        -- destination geo_pass handed the plot loop, in page coordinates, so
        -- the page's own x comes back off it.  The bolt's far end is the
        -- hole's centre plus/minus its reach.
        local hx = hole_x()
        local on_screen = hx > 12 and hx < 388
        -- CONTAINMENT IS NOT CHECKED HERE.  The obvious test - scan the frame
        -- buffer for the bolt's pen numbers and require the bbox inside the
        -- void - does not work: the frame buffer holds INDICES, every object
        -- draws out of its own map, and the stage art is full of 0eh and 0bh.
        -- It matched 271 background pixels a frame and "failed" a bolt that
        -- was provably inside the hole.  Containment is measured off the
        -- SNAPSHOTS, after the palette is resolved, where boonpal white is
        -- (231,231,231) and nothing else on this stage is.
        --
        -- What IS sound here is how many segments were queued: the producer
        -- emits exactly 8 a frame, so anything else means either a frame
        -- geo_pass did not consume or a second producer on the list.
        if emitting then
            local qc = r16(A.geo_count)
            if qc > 0 then
                queue_frames = queue_frames + 1
                if qc ~= 8 then
                    queue_bad = queue_bad + 1
                    if queue_bad <= 4 then log("rel=%4d geo_count is %d, not 8", rel, qc) end
                end
            end
        end

        if emitting and on_screen then
            burst_frames = burst_frames + 1
            track_checks = track_checks + 1
            local lx = (r32(A.geo_lastxy) & 0xffff) - PAGE_X
            if lx >= 0x8000 then lx = lx - 0x10000 end
            if math.abs(lx - hx) <= ARC_RX + 4 then
                track_hits = track_hits + 1
            elseif track_checks < 200 then
                log("rel=%4d bolt ends at x=%d, hole is at %d", rel, lx, hx)
            end
        elseif emitting and not on_screen then
            fail(string.format("emitted with the hole off screen at x=%d", hx))
        end

        was_up = emitting
        last_drew = drew
    end

    -- ---- pan the camera, then stand a fighter in the doorway ----
    if rel == 700 then
        log("panning left: the hole is on a rate-zero plane, so it must NOT move")
        setx(A.p1_obj, 60); setx(A.p2_obj, 120)
    elseif rel == 900 then
        log("rel=%4d worldtlx3=%d -> hole at screen x=%d",
            rel, s16(r32(A.worldtlx3) >> 16), hole_x())
        snap("panned left", 2)
    elseif rel == 1000 then
        setx(A.p1_obj, 740); setx(A.p2_obj, 700)
    elseif rel == 1200 then
        log("rel=%4d worldtlx3=%d -> hole at screen x=%d",
            rel, s16(r32(A.worldtlx3) >> 16), hole_x())
        snap("panned right", 2)
    elseif rel == 1300 then
        -- back to the middle, then stand P1 in front of the hole
        setx(A.p1_obj, 400); setx(A.p2_obj, 300)
    elseif rel == 1380 then
        -- OH_ARC_CLEAR is 28.  Park him at 34 - outside the stand-down, but
        -- his sprite is ~50px wide, so he is still standing across the hole.
        local wx = s16(r32(A.worldtlx) >> 16)
        log("rel=%4d parking P1 just outside the stand-down (screen %d)", rel, ARC_SX + 34)
        setx(A.p1_obj, ARC_SX + 34 + wx); setx(A.p2_obj, ARC_SX + 120 + wx)
        for k = 1, 40 do snap("edge of the stand-down " .. k, 40 + k * 4) end
    elseif rel == 1500 then
        local hx = hole_x()
        local wx = s16(r32(A.worldtlx) >> 16)
        log("rel=%4d standing P1 in the doorway (screen %d = world %d)", rel, hx, hx + wx)
        setx(A.p1_obj, hx + wx)
        blocked_frames, burst_frames = 0, 0
    end
    if rel > 1560 and rel < 1900 and MODE == "arc" then
        -- P1 is in front of the hole for this window; the arc must stand down
        if r16(A.geo_count) > 0 then blocked_frames = blocked_frames + 1 end
    end
    if rel == 1900 then
        notes[#notes + 1] = string.format(
            "with P1 in the doorway: %d frames of arc in 340 (want 0)", blocked_frames)
        if blocked_frames > 0 then fail("the arc drew over a fighter standing in the hole") end
        snap("fighter in the doorway", 2)
    end

    if rel > 60 * 36 then
        log("bursts seen: %d", up_runs)
        if MODE == "portal" then
            log("bursts drawn with m_flipv: %d of %d", flipped_bursts, up_runs)
            if up_runs >= 8 and (flipped_bursts == 0 or flipped_bursts == up_runs) then
                fail("m_flipv is not being rolled per burst")
            end
        end
        for _, n in ipairs(notes) do log("%s", n) end
        if MODE == "arc" then
            log("bolt tracked the hole on %d/%d emitting frames", track_hits, track_checks)
            log("frames where the queue held exactly 8 segments: %d of %d",
                queue_frames - queue_bad, queue_frames)
            if queue_bad > 0 then
                fail(string.format("%d frames queued something other than one bolt", queue_bad))
            end
            if up_runs == 0 then fail("no arc at all") end
            if r16(A.geo_dropped) > 0 then
                fail(string.format("%d segments refused by the page guard", r16(A.geo_dropped)))
            end
            if track_checks > 0 and track_hits < track_checks * 0.95 then
                fail("the bolt does not stay in the hole when the camera moves")
            end
        end
        if #fails == 0 then log("PASS") else log("FAILED: %s", table.concat(fails, "; ")) end
        finished = true
        manager.machine:exit()
    end
end)
