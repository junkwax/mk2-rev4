-- kahn_sonic_block_test.lua
--
-- Measures the knockback a BLOCKING victim takes from one of Shao Kahn's
-- moves.  Built for the sonic clap's new blocked reaction (b_kahn_sonic,
-- block_xfers slot 0x28) - "does the shockwave actually shove the guard
-- back, and how far".
--
-- Rig: P1 = Liu Kang (human, but the only input we ever press is BLOCK,
-- held from before the move until well after it lands).  P2 = Shao Kahn
-- drone, pinned in place so P1's x delta IS the slide.  The move is
-- requested through the debug3 hook in MKBOSS.ASM's kahn_debug_test.
--
--   MK2_BLOCK_MOVE=sonic|punch   which move to block (default sonic)
--   MK2_BLOCK_GAP=<px>           starting gap, default 110
--   MK2_BLOCK_LOG / MK2_BLOCK_ROOT
--
-- debug4 breadcrumbs from MKZAP.ASM: 0x5005 = wave hit, 0x5006 = wave
-- BLOCKED (the case under test).

local frame = 0
local ROOT = os.getenv("MK2_BLOCK_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("MK2_BLOCK_LOG") or (ROOT .. "/tools/kahn_sonic_block_test.log")
local MOVE_NAME = (os.getenv("MK2_BLOCK_MOVE") or "sonic"):lower()
local START_GAP = tonumber(os.getenv("MK2_BLOCK_GAP") or "110") or 110
-- MK2_BLOCK_GUARD=0: don't hold block.  Control run - the victim should take
-- the HIT reaction (debug4 0x5005) and lose health, proving the hit path is
-- untouched by whatever the blocked path does.
local GUARD = os.getenv("MK2_BLOCK_GUARD") ~= "0"
-- MK2_BLOCK_SNAP=0: no screenshots.  Required for any run whose audio will be
-- listened to or measured - the snapshot flood starves the host sound device
-- and drops blanks into everything, which reads as the ROM being broken.
local SNAP_ON = os.getenv("MK2_BLOCK_SNAP") ~= "0"

-- portal = 4: the Portal Punch.  It has no blocked breadcrumb of its own, so
-- the contact detector below falls through to "P1 started moving", same as
-- punch/kick/charge.  Note the hand takes ~25 ticks to fall before it can
-- connect, so CONTACT lands much later in the run than a clap's does.
local MOVE_CODES = { sonic = 3, punch = 8, kick = 9, charge = 11, portal = 4 }
local MOVE_CODE = MOVE_CODES[MOVE_NAME]

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n") logfh:flush() end
end

-- ---------------------------------------------------------------- symbols
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

local missing = {}
local function sym(name)
    local v = symbols[name]
    if not v then missing[#missing + 1] = name return 0 end
    return v
end

local A = {
    gstate        = sym("gstate"),
    curback       = sym("curback"),
    p1_state      = sym("p1_state"),  p2_state    = sym("p2_state"),
    p1_obj        = sym("p1_obj"),    p2_obj      = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),   p2_proc     = sym("p2_proc"),
    p1_char       = sym("p1_char"),   p2_char     = sym("p2_char"),
    p1_bar        = sym("p1_bar"),    p2_bar      = sym("p2_bar"),
    p1_bar_view   = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    p1_xvel       = sym("p1_xvel"),
    f_norepell    = sym("f_norepell"),
    winner_status = sym("winner_status"),
    map_position  = sym("map_position"),
    battle_num    = sym("battle_num"),
    debug2        = sym("debug2"),
    debug3        = sym("debug3"),    debug4      = sym("debug4"),
    debug5        = sym("debug5"),
    objlst        = sym("objlst"),
    active        = sym("active"),
}

-- kahn_stalk's puppet gate (MKBOSS.ASM).  Without it Kahn sits inside
-- kahn_stalk_a11 walking toward a target he can never reach (we pin him),
-- so he never returns to the top of the brain loop and never polls debug3 -
-- the move request is simply never seen.  Puppet mode parks him in
-- kahn_puppet_hold, which polls debug3 every tick and attacks only on
-- command, which also keeps stray AI attacks out of the measurement.
local PUPPET_MAGIC = 0x50ad
local STALK_POLL = 0x6200       -- breadcrumb written at the brain-loop top

-- object / process field offsets (DISPEQU.ASM, MKSTRUCT.ASM)
local O = { next = 0x000, oxvel = 0x040, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0 }
local P = { action = 0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_KAHN, KAHN_ARENA = 1, 13, 8
local PS_ACTIVE, PS_INACTIVE = 1, 0
local MAX_HP = 0x0a1

local space, input_sys
local fields, blk_field = {}, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm_start, did_select = 0, false
local armed_frame, request_frame, contact_frame, done_frame = 0, 0, 0, 0
local brain_seen, last_request = false, 0
local kahn_pin_x = nil
local base_xval, base_gap = nil, nil
local peak_vel, last_debug4, shot_count = 0, -1, 0
local peak_y, ground_y = 9999, nil
local last_debug5, claps = -1, 0
local burst_total, result_done, pending_dgp, singles = 1, false, 0, 0
local watch_x, watch_d4, watch_since = nil, nil, 0
-- MK2_BLOCK_SHOTS=n: fire the move n times in one round, reporting the clap
-- count each time.  Needed because @rand is reseeded identically at every
-- round start, so a one-shot rig replays the same 1-or-3 roll forever - only
-- repeated shots inside a single round let the RNG advance and show both.
local SHOTS = tonumber(os.getenv("MK2_BLOCK_SHOTS") or "1") or 1
local shot = 0
local trace_rows = {}
local verdict = nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function s16(v) v = v & 0xffff if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff if v >= 0x80000000 then return v - 0x100000000 end return v end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    if not SNAP_ON then return end
    local s = main_screen()
    if not s then return end
    pcall(function() s:snapshot() end)
end

local function cache_fields()
    local wanted = { ["UI Select"] = true, ["Coin 1"] = true,
                     ["1 Player Start"] = true, ["P1 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
            -- P1 block: name it exactly, or fall back to player 0 + "Block"
            if not blk_field then
                if field.name == "P1 Block"
                   or (field.player == 0 and field.name:find("Block", 1, true)) then
                    blk_field = field
                end
            end
        end
    end
    for name in pairs(wanted) do
        print(string.format("[blk] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
    print(string.format("[blk] input P1 Block        %s",
        blk_field and ("ok (" .. blk_field.name .. ")") or "MISSING"))
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if charsel_frame > 0 and (name == "UI Select" or name == "Coin 1" or name == "1 Player Start") then
        return false
    end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    return false
end

-- Pool pressure: a wedged cooperative scheduler and an exhausted object pool
-- look identical from outside (everything stops), so count both.
local function count_list(head, nextoff, limit)
    local p, n, seen = r32(head), 0, {}
    while p ~= 0 and n < (limit or 400) do
        if seen[p] then return -n end          -- negative = cycle detected
        seen[p] = true
        n = n + 1
        p = r32(p + nextoff)
    end
    return n
end

local function pools()
    return count_list(A.objlst, 0x000), count_list(A.active, 0x000)
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return nil end
    return {
        p1o = p1o, p2o = p2o,
        p1x = s16(r16(p1o + O.oxpos)),  p2x = s16(r16(p2o + O.oxpos)),
        p1y = s16(r16(p1o + O.oypos)),
        p1xval = s32(r32(p1o + O.oxval)),
        p1xvel = s32(r32(p1o + O.oxvel)),
        req    = s32(r32(A.p1_xvel)),
        act    = p1_action(),
    }
end

local function force_ladder()
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_KAHN)
    w16(A.curback, KAHN_ARENA)
    w16(A.map_position, 14)
    w16(A.battle_num, 15)
    -- puppet flag must be up BEFORE the round intro: Kahn's brain enters
    -- kahn_stalk during the intro and would otherwise get a free attack in
    w16(A.debug2, PUPPET_MAGIC)
    if not did_select then
        did_select = true
        print(string.format("[blk] direct_select frame=%d p1=%d p2=%d curback=%d",
            frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback)))
    end
end

local function keep_alive()
    w16(A.p1_bar, MAX_HP) w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP) w16(A.p2_bar_view, MAX_HP)
end

local function finish(msg, ok)
    if done_frame > 0 then return end
    done_frame = frame
    verdict = ok
    print("[blk] " .. msg)
    print("[blk] " .. (ok and "PASS" or "FAIL"))
    print("[blk] finished")
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        input_sys = manager.machine.input
        cache_fields()
        print("[blk] kahn_sonic_block_test - blocked-knockback probe")
        print("[blk] log=" .. LOG_PATH)
        print(string.format("[blk] move=%s code=%s start_gap=%d",
            MOVE_NAME, tostring(MOVE_CODE), START_GAP))
        if #missing > 0 then
            print("[blk] ERROR unresolved map symbols: " .. table.concat(missing, ","))
            manager.machine:exit() return
        end
        if not MOVE_CODE then
            print("[blk] ERROR unknown MK2_BLOCK_MOVE=" .. MOVE_NAME)
            manager.machine:exit() return
        end
        if not blk_field then
            print("[blk] ERROR no P1 Block input field")
            manager.machine:exit() return
        end
    end

    if not space then return end

    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then
        print(string.format("[blk] ERROR bad_gstate frame=%d gs=0x%04x", frame, gs))
        snap("bad_gstate")
        manager.machine:exit() return
    end

    if gs ~= last_gstate then
        print(string.format("[blk] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            w16(A.debug4, 0)
            print("[blk] fight_start frame=" .. frame)
        end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then force_ladder() end
    if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0
       and frame - charsel_frame > 90 then
        p1_confirm_start = frame
    end

    -- ------------------------------------------------------------- fight
    if fighting_frame > 0 and gs == GS_FIGHTING and done_frame == 0 then
        keep_alive()
        w16(A.debug2, PUPPET_MAGIC)     -- hold across round intros too
        local st = state()

        if st then
            if not brain_seen and r16(A.debug4) == STALK_POLL then
                brain_seen = true
                print(string.format("[blk] brain_poll_seen frame=%d (puppet hold is live)", frame))
            end
            -- Kahn is pinned from the moment the fight starts, so every pixel
            -- P1 moves during the reaction is the knockback and nothing else.
            if kahn_pin_x == nil and frame - fighting_frame > 30 then
                kahn_pin_x = st.p2x
                print(string.format("[blk] pin_kahn x=%d", kahn_pin_x))
            end
            -- Pin Kahn ONLY up to the first contact: that is all the
            -- measurement needs (the baseline is taken at contact), and
            -- holding him there afterwards is a state the game can never
            -- reach on its own.  A triple clap shoves the victim ~300px, and
            -- with Kahn nailed down the pair end up ~580px apart against a
            -- 304px screen_distance limit the engine then cannot resolve -
            -- which looked exactly like the burst hanging the game.
            if kahn_pin_x and contact_frame == 0 then
                w32(st.p2o + O.oxval, kahn_pin_x << 16)
                w16(st.p2o + O.oxpos, kahn_pin_x)
            end

            -- hold BLOCK from the arm frame onwards, and place P1 once
            if armed_frame == 0 and kahn_pin_x and frame - fighting_frame > 60 then
                armed_frame = frame
                ground_y = st.p1y
                local target = kahn_pin_x - START_GAP
                w32(st.p1o + O.oxval, target << 16)
                w16(st.p1o + O.oxpos, target)
                print(string.format("[blk] armed frame=%d p1_x=%d kahn_x=%d gap=%d",
                    frame, target, kahn_pin_x, START_GAP))
            end
            if armed_frame > 0 and GUARD then blk_field:set_value(1) end

            -- Fire once block has had time to establish.  Do NOT gate this on
            -- seeing the 0x6200 stalk breadcrumb: kahn_puppet_hold writes it
            -- once on the way in and then loops forever without touching
            -- debug4, so if he parked before we zeroed debug4 the flag never
            -- comes back and the rig waits for something that cannot happen.
            -- debug3 reading back 0 is the real proof his brain is polling.
            if armed_frame > 0 and request_frame == 0
               and frame - armed_frame > 40 then
                request_frame = frame
                last_request = frame
                shot = shot + 1
                base_xval = st.p1xval
                base_gap  = kahn_pin_x - st.p1x
                w16(A.debug4, 0)
                w32(A.debug5, 0)
                last_debug4 = -1
                w16(A.debug3, MOVE_CODE)
                print(string.format("[blk] request move=%s code=%d frame=%d p1_x=%d gap=%d act=0x%04x",
                    MOVE_NAME, MOVE_CODE, frame, st.p1x, base_gap, st.act))
                snap("request")
            end

            -- re-post an unconsumed command rather than sitting on a silent
            -- miss: debug3 reading back non-zero means nobody picked it up
            if request_frame > 0 and contact_frame == 0 and r16(A.debug3) ~= 0
               and frame - last_request > 60 then
                last_request = frame
                w16(A.debug3, MOVE_CODE)
                print(string.format("[blk] re-request frame=%d (debug3 was unconsumed)", frame))
            end

            if request_frame > 0 then
                local rel = frame - request_frame
                local d4 = r16(A.debug4)
                if d4 ~= last_debug4 then
                    print(string.format("[blk] debug4 rel=%d 0x%04x p1_x=%d gap=%d act=0x%04x",
                        rel, d4, st.p1x, kahn_pin_x - st.p1x, st.act))
                    last_debug4 = d4
                end

                -- 05100h + claps-remaining, written once per clap of a burst
                -- Consume the breadcrumb by zeroing it: two claps in a row can
                -- write the SAME value (a lone clap always writes 0x5101), so
                -- change-detection alone silently misses every repeat.
                local d5 = r32(A.debug5)
                if (d5 & 0xffffff00) == 0x5100 then
                    claps = claps + 1
                    if claps == 1 then burst_total = d5 & 0xff end
                    print(string.format("[blk] CLAP #%d/%d rel=%d (debug5=0x%04x)",
                        claps, burst_total, rel, d5))
                    w32(A.debug5, 0)
                end

                if math.abs(st.p1xvel) > math.abs(peak_vel) then peak_vel = st.p1xvel end

                -- Dump the WAVE object's render parameters every tick.  The
                -- art is byte-exact in ROM, so a mid-animation garble has to
                -- be the object being handed a bad sag/size/flags for the
                -- frame it is on.  Anything that is not a player object.
                --
                -- x/y/sx/sy are also the ALIGNMENT readout: the wave is a
                -- single-part object, so its oxpos/oypos ARE the drawn art's
                -- top-left corner (MKDISP.ASM's no_multi path takes the
                -- coordinate straight to the dma - only multipart objects
                -- subtract an anipoint).  art_r therefore is the wave's real
                -- leading edge, and lead = how far it still is from P1's
                -- anchor.  A hit reported while lead is large is a strike box
                -- sitting out in front of the art.
                local p = r32(A.objlst)
                local n = 0
                while p ~= 0 and n < 12 do
                    if p ~= st.p1o and p ~= st.p2o then
                        local ox, oy = s16(r16(p + O.oxpos)), s16(r16(p + O.oypos))
                        local sx = r16(p + 0x120)
                        print(string.format(
                            "[obj] rel=%3d obj=%08x sag=%08x sx=%3d sy=%3d flags=%04x pal=%04x img=%08x x=%d y=%d art_r=%d p1_x=%d lead=%d",
                            rel, p, r32(p + 0x100), sx, r16(p + 0x130),
                            r16(p + 0x0f0), r16(p + 0x140), r32(p + 0x1a0),
                            ox, oy, ox + sx, st.p1x, st.p1x - (ox + sx)))
                    end
                    p = r32(p + 0x000)
                    n = n + 1
                end

                -- Stall watchdog.  P1's x stops moving AND debug4 stops
                -- changing = either a process is spinning without a sleep or
                -- the object pool ran dry (ermac hangs the CPU outright).
                if st.p1x ~= watch_x or d4 ~= watch_d4 then
                    watch_x, watch_d4, watch_since = st.p1x, d4, frame
                elseif (frame - watch_since) % 150 == 0 and frame > watch_since then
                    local objs, procs = pools()
                    local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
                    print(string.format(
                        "[blk] STALL %d frames: debug4=0x%04x p1_x=%d p2_x=%d act=0x%04x oxvel=%.2f req=%.2f objs=%d procs=%d",
                        frame - watch_since, d4, st.p1x, st.p2x, st.act,
                        st.p1xvel / 65536.0, st.req / 65536.0, objs, procs))
                    -- Where is each process parked?  wake is the resume
                    -- address - run it through sym_resolve.py to name it.
                    print(string.format(
                        "[blk]   P1 proc=0x%08x wake=0x%08x t=%d sp=0x%08x | P2 proc=0x%08x wake=0x%08x t=%d",
                        p1p, r32(p1p + 0x0e0), r16(p1p + 0x030), r32(p1p + 0x040),
                        p2p, r32(p2p + 0x0e0), r16(p2p + 0x030)))
                end

                -- keep tracing past the measurement window so a runaway slide
                -- after a LATER clap is visible, not just the first skid
                if contact_frame > 0 and result_done
                   and ((frame - contact_frame) % 10) == 0 then
                    print(string.format("[late] t=%3d x=%4d p2x=%4d oxvel=%7.2f req=%7.2f act=0x%04x",
                        frame - contact_frame, st.p1x, st.p2x,
                        st.p1xvel / 65536.0, st.req / 65536.0, st.act))
                end

                -- Dense capture: EVERY tick from the wave being in flight
                -- through the skid.  Sampling every 3rd tick makes the shove
                -- hard to see, and the camera scrolls with the fighters so a
                -- sparse strip reads as "nobody moved" even when they did.
                if shot_count < 80
                   and ((contact_frame == 0 and rel >= 6)
                        or (contact_frame > 0 and frame - contact_frame <= 60)) then
                    shot_count = shot_count + 1
                    snap(string.format("t%03d", shot_count))
                end

                -- 0x5006 = kson_blocked; for a plain punch there is no
                -- breadcrumb, so fall back to "P1 started moving".
                if contact_frame == 0 then
                    local want = GUARD and 0x5006 or 0x5005
                    local other = GUARD and 0x5005 or 0x5006
                    if d4 == want
                       or (MOVE_NAME ~= "sonic" and st.p1xvel ~= 0) then
                        contact_frame = frame
                        base_xval = st.p1xval
                        base_gap  = kahn_pin_x - st.p1x
                        print(string.format("[blk] CONTACT(%s) rel=%d p1_x=%d y=%d gap=%d act=0x%04x",
                            GUARD and "blocked" or "clean hit",
                            rel, st.p1x, st.p1y, base_gap, st.act))
                        snap("contact")
                    elseif d4 == other then
                        finish(string.format("wrong outcome: debug4=0x%04x with guard %s (act=0x%04x)",
                            d4, GUARD and "ON" or "OFF", st.act), false)
                        snap("wrong_outcome")
                    end
                end

                if contact_frame > 0 then
                    local crel = frame - contact_frame
                    -- y matters for the unguarded case: a clean hit is meant to
                    -- put him in the AIR (r_kahn_punch -> flight), so a knockback
                    -- number without height does not describe the reaction.
                    if st.p1y < peak_y then peak_y = st.p1y end
                    trace_rows[#trace_rows + 1] = string.format(
                        "[trace] t=%2d x=%4d y=%4d gap=%4d dx=%6.2f oxvel=%8.3f act=0x%04x",
                        crel, st.p1x, st.p1y, st.p2x - st.p1x,
                        (st.p1xval - base_xval) / 65536.0,
                        st.p1xvel / 65536.0, st.act)

                    -- Measure at 35, not 75: in a TRIPLE the second wave
                    -- connects around crel 54, and a 75-tick window folded its
                    -- knockback into the first one's (a bogus 330px reading).
                    -- The skid itself is over by tick 17, so 35 is settled and
                    -- still clear of the next clap.
                    if crel >= 35 and not result_done then
                        result_done = true
                        local dx  = (st.p1xval - base_xval) / 65536.0
                        local dgp = (st.p2x - st.p1x) - base_gap
                        for _, row in ipairs(trace_rows) do print(row) end
                        print(string.format(
                            "[blk] RESULT move=%s guard=%s knockback=%.2fpx gap_change=%+dpx peak_oxvel=%.2fpx/tick airborne_peak_y=%d (ground=%d)",
                            MOVE_NAME, GUARD and "ON" or "OFF", dx, dgp,
                            peak_vel / 65536.0, peak_y, ground_y or -1))
                        -- Emulation speed belongs in any log whose audio will
                        -- be judged: a host that fell behind explains dropouts
                        -- that have nothing to do with the ROM.
                        local ok, spd = pcall(function()
                            return manager.machine.video.speed_percent end)
                        print(string.format("[blk] host_speed=%s",
                            ok and string.format("%.1f%%", spd * 100) or "na"))
                        snap("settled")
                        pending_dgp = dgp
                    end

                    -- Wait for the WHOLE burst before moving on: re-arming
                    -- between claps leaves a wave in flight that lands during
                    -- the next shot's measurement.
                    if result_done and claps >= burst_total then
                        local dgp = pending_dgp
                        print(string.format("[blk] SHOT %d/%d fired %d clap(s)", shot, SHOTS, claps))
                        if shot < SHOTS then
                            -- next shot: re-arm in place and let the RNG move on
                            local target = kahn_pin_x - START_GAP
                            w32(st.p1o + O.oxval, target << 16)
                            w16(st.p1o + O.oxpos, target)
                            request_frame, contact_frame = 0, 0
                            armed_frame = frame - 20
                            trace_rows, claps, peak_vel = {}, 0, 0
                            burst_total, result_done = 1, false
                            singles = singles + (claps == 1 and 1 or 0)
                            print(string.format("[blk] --- re-arming for shot %d/%d ---", shot + 1, SHOTS))
                        elseif dgp >= 12 then
                            finish(string.format("victim driven %+dpx AWAY from Kahn", dgp), true)
                        elseif dgp <= -12 then
                            finish(string.format("victim pulled %+dpx TOWARD Kahn - wrong direction", dgp), false)
                        else
                            finish(string.format("victim barely moved (%+dpx)", dgp), false)
                        end
                    end
                end

                if (rel % 120) == 0 and contact_frame == 0 then
                    print(string.format("[blk] waiting rel=%d debug3=%d debug4=0x%04x p1_x=%d kahn_x=%d act=0x%04x",
                        rel, r16(A.debug3), r16(A.debug4), st.p1x, kahn_pin_x, st.act))
                end

                if rel > 400 and contact_frame == 0 then
                    if r16(A.debug3) ~= 0 then
                        finish("Kahn never consumed the debug3 command (brain not polling)", false)
                    else
                        finish("move ran but never connected on the block", false)
                    end
                    snap("no_contact")
                end
            end
        end
    else
        if blk_field then blk_field:clear_value() end
    end

    if done_frame > 0 and frame - done_frame > 40 then manager.machine:exit() end
    if frame > 4500 then
        print("[blk] ERROR timeout")
        snap("timeout")
        manager.machine:exit()
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end
end)

emu.register_stop(function()
    print(string.format("[blk] stopped frame=%d verdict=%s", frame, tostring(verdict)))
    if logfh then logfh:flush() logfh:close() logfh = nil end
end)
