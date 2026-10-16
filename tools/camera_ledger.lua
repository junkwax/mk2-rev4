-- camera_ledger.lua
--
-- Accounts for every write to worldtly during ordinary combat.
--
-- Background: the camera complaint was first pinned on Sub-Zero's air freeze,
-- but it also shows on a plain grounded uppercut and on Liu Kang's low
-- fireball -- so it is not the freeze, and camera_scroll_probe.lua already
-- cleared the y-scroll controller's own arithmetic (a fighter parked anywhere
-- in or above the barrier band settles worldtly on a stable value).
--
-- Only three things ever move worldtly:
--     MKDISP display loop   worldtly += scrolly     <- the real scroll
--     BGND  scrl8           snap to ceiling_y       <- the clamp
--     MKFX  es_sub          screen shake, +/-N px every 3 ticks
--
-- Predicted delta each frame is LAST frame's scrolly.  Anything else is an
-- outside writer.  Group those into bursts (a shake is one burst) and report,
-- per burst: how big the biggest single-frame jump was, what the camera's net
-- displacement was when the burst ended, and whether the scroller was actively
-- moving the camera while the burst ran -- which is the case where a shake
-- that restores an absolute snapshot would throw away real scrolling.
--
-- No scripted inputs: P1 stands still and the AI drone does the hitting, so
-- there is no input-timing guesswork.  Every knockdown it lands is a sample.
--
-- Env: CAMLEDGER_LOG, CAMLEDGER_FRAMES
-- Usage: tools/run_camera_ledger.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("CAMLEDGER_LOG") or (ROOT .. "/tools/camera_ledger.log")
local RUN_FRAMES = tonumber(os.getenv("CAMLEDGER_FRAMES") or "") or 3000
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[ledger] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_obj", "p2_obj",
                     "p1_proc", "p2_proc", "p1_bar", "p2_bar", "p1_bar_view",
                     "p2_bar_view", "winner_status", "battle_num", "map_position",
                     "worldtly", "scrolly", "ceiling_y", "ground_y", "diff",
                     "p1_state", "p2_state" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s - results are worthless", n) end
end

local OYPOS = 0x0b0
local P_ACTION = 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_SUBZERO = 1, 8

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local ceiling_y, floor_y = 0, 0
local prev_w, prev_sc = nil, 0
local burst, bursts, done = nil, {}, false
local scroll_active_run = 0
local live_a1, live_a2, live_n1, live_n2 = -1, -1, 0, 0
local fields = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end
local function pact(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + P_ACTION) end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function wtly() return s32(r32(A.worldtly)) end
local function px(v) return v / 65536.0 end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["1 Player Start"] = true, ["P1 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input field %s", n) end end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and p1_confirm > 0 and name == "P1 High Punch" then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

-- A shake displaces the camera by its own amplitude every 3 ticks, and that is
-- deliberate -- a 6px shake is SUPPOSED to move the camera 6px.  The defect
-- signature is a single write BIGGER than that: the shake handing back an
-- absolute snapshot and taking the scroller's work with it.  So take the
-- burst's own repeated magnitude as the amplitude and only flag what exceeds
-- it.  (Judging against a flat 2px threshold just flags every screen shake.)
local function burst_amplitude(b)
    local tally, best, bestn = {}, 0, 0
    for _, m in ipairs(b.mags) do
        local k = math.floor(math.abs(m) / 32768 + 0.5)     -- half-pixel buckets
        tally[k] = (tally[k] or 0) + 1
        if tally[k] > bestn or (tally[k] == bestn and k > best) then best, bestn = k, tally[k] end
    end
    return best * 32768
end

local function close_burst()
    if not burst then return end
    burst.net = burst.w_end - burst.w_start
    burst.amp = burst_amplitude(burst)
    burst.yanks = 0
    for _, m in ipairs(burst.mags) do
        if math.abs(m) > burst.amp + 32768 then burst.yanks = burst.yanks + 1 end
    end
    bursts[#bursts + 1] = burst
    log("burst @f%-6d %2d writes over %3d frames | amplitude %.1fpx | biggest %+6.1fpx | "
        .. "%d oversized | net %+5.1fpx | worldtly %.1f -> %.1f | scroll active %d frames",
        burst.f0, burst.n, burst.f1 - burst.f0 + 1, px(burst.amp), px(burst.worst),
        burst.yanks, px(burst.net), px(burst.w_start), px(burst.w_end),
        burst.scroll_frames)
    burst = nil
end

local function finish()
    if done then return end
    done = true
    close_burst()
    log("")
    log("ceiling_y=%d  rest barrier=%d  scroll-up limit worldtly=%d",
        ceiling_y, ceiling_y + 40, ceiling_y - 0x10)
    log("")
    local bad, with_scroll, yanks, worst, worst_b = 0, 0, 0, 0, nil
    for _, b in ipairs(bursts) do
        if b.yanks > 0 then bad = bad + 1; yanks = yanks + b.yanks end
        if b.scroll_frames > 0 then with_scroll = with_scroll + 1 end
        if math.abs(b.worst) > math.abs(worst) then worst, worst_b = b.worst, b end
    end
    log("liveness: p1 changed action %d times, p2 changed action %d times",
        live_n1, live_n2)
    if #bursts == 0 and (live_n1 < 20 or live_n2 < 20) then
        log("INCONCLUSIVE: no shakes AND barely any combat - this run proves nothing")
    end
    log("%d bursts of outside writes over %d fight frames", #bursts, frame - fighting_frame)
    log("  %d overlapped an ACTIVE scroll (camera was moving on its own at the time)",
        with_scroll)
    log("  %d writes exceeded their own shake amplitude, across %d bursts", yanks, bad)
    if worst_b then
        log("  biggest single-frame camera move: %+.1fpx at frame %d (burst amplitude %.1fpx)",
            px(worst), worst_b.f0, px(worst_b.amp))
    end
    log("")
    if bad == 0 then
        log("PASS camera: every write is its shake's own amplitude - no shake threw "
            .. "away the scroller's work")
    else
        log("FAIL camera: %d writes over %d bursts moved the camera further than the "
            .. "shake itself, i.e. a snapshot restore is eating live scrolling", yanks, bad)
    end
    logfh:close(); manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- every write to worldtly during a drone brawl ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG); w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        ceiling_y = s16(r16(A.ceiling_y))
        floor_y = gety(A.p1_obj) or 0
        log("fight start frame=%d ceiling_y=%d worldtly=%.1f (P1 idle, P2 = AI drone)",
            frame, ceiling_y, px(wtly()))
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    -- never let the round end: the drone keeps hitting a punching bag
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    local w = wtly()
    local sc = s32(r32(A.scrolly))
    if sc ~= 0 then scroll_active_run = 12 elseif scroll_active_run > 0 then
        scroll_active_run = scroll_active_run - 1 end

    if prev_w then
        local unexplained = (w - prev_w) - prev_sc
        if math.abs(unexplained) > 0x2000 then          -- > 1/8 px: not rounding
            if burst and frame - burst.f1 > 12 then close_burst() end
            if not burst then
                burst = { f0 = frame, f1 = frame, n = 0, worst = 0, mags = {},
                          w_start = prev_w, w_end = w, scroll_frames = 0 }
            end
            burst.n = burst.n + 1
            burst.f1 = frame
            burst.w_end = w
            burst.mags[#burst.mags + 1] = unexplained
            if math.abs(unexplained) > math.abs(burst.worst) then burst.worst = unexplained end
            if scroll_active_run > 0 then burst.scroll_frames = burst.scroll_frames + 1 end
            if math.abs(unexplained) > 2 * 65536 then
                log("  POP f%-6d %+6.1fpx in one frame -> worldtly %.1f "
                    .. "(scrolly %+.2f, p1y=%s p2y=%s, barrier %.0f, p1act=%04x p2act=%04x)",
                    frame, px(unexplained), px(w), px(sc),
                    tostring(gety(A.p1_obj)), tostring(gety(A.p2_obj)),
                    px(w) + 40, pact(A.p1_proc), pact(A.p2_proc))
            end
        elseif burst and frame - burst.f1 > 12 then
            close_burst()
        end
    end
    prev_w, prev_sc = w, sc

    -- Liveness. A run with zero bursts is only good news if the fighters were
    -- actually fighting; "no shakes" and "no combat" look identical in the
    -- ledger, and a vacuous PASS is worse than a FAIL.
    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    if a1 ~= live_a1 then live_a1, live_n1 = a1, live_n1 + 1 end
    if a2 ~= live_a2 then live_a2, live_n2 = a2, live_n2 + 1 end
    if (frame - fighting_frame) % 600 == 0 then
        local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
        log("  liveness f%-6d gs=%d p1act=%04x p2act=%04x p1(%s,%s) p2(%s,%s) "
            .. "p1_state=%s p2_state=%s diff=%s | action changes: p1=%d p2=%d",
            frame, r16(A.gstate), a1, a2,
            o1 ~= 0 and tostring(r16(o1 + 0x090)) or "nil", tostring(gety(A.p1_obj)),
            o2 ~= 0 and tostring(r16(o2 + 0x090)) or "nil", tostring(gety(A.p2_obj)),
            A.p1_state ~= 0 and tostring(r16(A.p1_state)) or "?",
            A.p2_state ~= 0 and tostring(r16(A.p2_state)) or "?",
            A.diff ~= 0 and tostring(r16(A.diff)) or "?",
            live_n1, live_n2)
        manager.machine.video:snapshot()
    end

    if frame - fighting_frame > RUN_FRAMES then finish(); return end
    if frame > 40000 then log("ERROR backstop"); finish() end
end)
