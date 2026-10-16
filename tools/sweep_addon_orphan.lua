-- sweep_addon_orphan.lua - where do callout glyphs get orphaned?
--
-- Two reported symptoms, one mechanism. cot_setvel writes oxvel onto every
-- glyph object with the word's oid, so the glyphs SELF-PROPEL: the flight
-- process only nudges them once a tick. If that process dies without running
-- cfly_gone - which is what kills the objects and clears cal_word - the
-- glyphs are left on the display list with whatever they last held:
--
--   parked, oxvel 0   -> "FIRST HIT on the left still stays on"
--   still moving      -> "flies across the screen from left to right"
--
-- The hudcall rig reports 0 orphan frames, but it only ever looks while
-- gstate is gs_fighting. The report says attract mode especially, so this
-- watches the WHOLE run - attract, select, round intro, bonus, game over -
-- and says which state the orphan appears in.
--
-- An orphan is: an object carrying a callout oid while cal_word for that
-- player reads 0. cfly_gone clears cal_word as it kills the objects, so the
-- two can only disagree if the process never got there.
--
-- Env: ORPHAN_LOG.  Driven by run_orphan_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("ORPHAN_LOG") or (ROOT .. "/tools/orphan.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

local space
local logf = io.open(OUT, "w")
local function log(fmt, ...)
    local s = "[orphan] " .. string.format(fmt, ...)
    print(s)
    if logf then logf:write(s .. "\n"); logf:flush() end
end
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff
    if v >= 0x80000000 then return v - 0x100000000 end return v end

local OID, OXVEL, OXPOS = 0x1c0, 0x40, 0x90
local PROCID = 0x20             -- MAINEQU.ASM
local PID_CALOUT = 0x011a       -- MAINEQU.ASM

-- Is the flight process actually on the active list? "cal_tick frozen" cannot
-- tell a killed process from a stalled one, and the two want different fixes.
local function flight_alive(i)
    local pr, guard = space:read_u32(sym.active), 0
    while pr ~= 0 and guard < 300 do
        if (space:read_u16(pr + PROCID) & 0xffff) == (PID_CALOUT + i) then
            return true
        end
        pr = space:read_u32(pr); guard = guard + 1
    end
    return false
end
local OID_CALOUT, OID_CMBDMG, OID_CMBHIT = 0x806, 0x808, 0x80a
local GS = { [0x01]="amode", [0x02]="fighting", [0x03]="buyin", [0x04]="psel",
             [0x05]="bonus", [0x06]="pfsetup", [0x07]="round_intro",
             [0x09]="pitfall", [0x0a]="initials", [0x0b]="gameover",
             [0x0c]="octopus", [0x0d]="post_psel", [0x0e]="barge" }

local t, prev_gs = 0, -1
local reported, events = {}, 0
local last_arms, armed = {}, 0
local pending, noproc = {}, 0
local life = { [0] = 0, [1] = 0 }
local lo = { [0] = 9999, [1] = 9999 }
local hi = { [0] = -9999, [1] = -9999 }
local worst_life = { [0] = 0, [1] = 0 }
local worst_span = { [0] = 0, [1] = 0 }
local sym_bad = 0
local last_tick = { [0] = -1, [1] = -1 }
local still = { [0] = 0, [1] = 0 }
local dead_flights = 0
local worst_run = { [0] = 0, [1] = 0 }
local run = { [0] = 0, [1] = 0 }

-- Every object carrying one of the callout oids, with its velocity.
local function scan()
    local out = { [0] = {n=0, moving=0, x=0}, [1] = {n=0, moving=0, x=0} }
    local o, guard = space:read_u32(sym.objlst), 0
    while o ~= 0 and guard < 400 do
        local id = space:read_u16(o + OID) & 0xffff
        local i = nil
        if id == OID_CALOUT or id == OID_CALOUT + 1 then i = id - OID_CALOUT end
        if i then
            local r = out[i]
            r.n = r.n + 1
            r.x = s16(space:read_u16(o + OXPOS))
            if s32(space:read_u32(o + OXVEL)) ~= 0 then r.moving = r.moving + 1 end
        end
        o = space:read_u32(o); guard = guard + 1
    end
    return out
end

emu.register_frame(function()
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        log("=== orphan hunt === callout glyphs with no flight behind them")
    end
    t = t + 1
    if t % 3 ~= 0 then return end          -- every third frame is plenty

    local gs = space:read_u16(sym.gstate) & 0xffff
    if gs ~= prev_gs then
        log("  [gstate -> %#04x %s at %d]", gs, GS[gs] or "?", t)
        prev_gs = gs
    end

    local o = scan()
    -- Activity, not just orphans: without this a silent run cannot be told
    -- apart from a clean one. The attract demo fights inside gs_amode, so
    -- "still in amode" does not mean nothing happened.
    for i = 0, 1 do
        local a = space:read_u16(sym.cal_arms + i * 16) & 0xffff
        if a ~= (last_arms[i] or 0) then
            last_arms[i] = a
            armed = armed + 1
            -- Watch for the arming that gets NO flight process. cfly_clk sets
            -- cal_phase on the flight's first instruction, so a phase still 0
            -- a few frames later means create_and_kill returned nothing - and
            -- the glyphs already carry the entry velocity, with nothing left
            -- to damp them. That is a word that flies straight across.
            pending[i] = { at = t, n = a }
        end
    end
    if t % 3000 == 0 then
        log("  t=%d %s  glyphs p1=%d p2=%d  cal_word=%08x/%08x  armings=%d",
            t, GS[gs] or gs, o[0].n, o[1].n,
            space:read_u32(sym.cal_word) & 0xffffffff,
            space:read_u32(sym.cal_word + 32) & 0xffffffff, armed)
    end
    -- Measure the SYMPTOM, not a theory of it. Two things were reported: a
    -- word crossing the screen, and a word that stays up. So track how far
    -- each player's glyphs actually travel and how long they are present,
    -- and flag either directly. p1 parks at x=22 and p2's right edge at 377.
    for i = 0, 1 do
        if o[i].n > 0 then
            life[i] = life[i] + 3
            -- Is the flight still RUNNING? cfly_dec takes one off cal_tick
            -- every tick, so a frozen cal_tick with glyphs still up means the
            -- process is gone. cal_word stays SET in that case, which is why
            -- an orphan test keyed on cal_word == 0 saw nothing.
            local tk = space:read_u16(sym.cal_tick + i * 16) & 0xffff
            if tk == last_tick[i] then
                still[i] = still[i] + 3
                if still[i] == 30 then
                    dead_flights = dead_flights + 1
                    log("DEAD FLIGHT p%d in %s at %d: cal_tick stuck at %d for"
                        .. " 30 frames, proc_on_list=%s, %d glyph(s) up,"
                        .. " %d moving, cal_word=%08x cal_phase=%d",
                        i + 1, GS[gs] or gs, t, tk, tostring(flight_alive(i)),
                        o[i].n, o[i].moving,
                        space:read_u32(sym.cal_word + i * 32) & 0xffffffff,
                        space:read_u16(sym.cal_phase + i * 16) & 0xffff)
                end
            else
                still[i], last_tick[i] = 0, tk
            end
            if o[i].x < lo[i] then lo[i] = o[i].x end
            if o[i].x > hi[i] then hi[i] = o[i].x end
        elseif life[i] > 0 then
            local span = hi[i] - lo[i]
            if life[i] > 190 or span > 240 then
                sym_bad = sym_bad + 1
                log("SYMPTOM p%d in %s: on screen %d frames (life is ~105),"
                    .. " x ran %d..%d (span %d)", i + 1, GS[gs] or gs,
                    life[i], lo[i], hi[i], span)
            end
            if life[i] > worst_life[i] then worst_life[i] = life[i] end
            if span > worst_span[i] then worst_span[i] = span end
            life[i], lo[i], hi[i] = 0, 9999, -9999
            still[i] = 0
        end
    end

    for i = 0, 1 do
        local pd = pending[i]
        if pd and t - pd.at >= 9 then
            local ph = space:read_u16(sym.cal_phase + i * 16) & 0xffff
            if ph == 0 then
                noproc = noproc + 1
                log("NO FLIGHT p%d arming #%d at %d: cal_phase still 0 after"
                    .. " %d frames, %d glyph(s) up, %d moving, x=%d",
                    i + 1, pd.n, t, t - pd.at, o[i].n, o[i].moving, o[i].x)
            end
            pending[i] = nil
        end
        local w = space:read_u32(sym.cal_word + i * 32) & 0xffffffff
        if o[i].n > 0 and w == 0 then
            run[i] = run[i] + 1
            if run[i] > worst_run[i] then worst_run[i] = run[i] end
            local key = string.format("%s-p%d", GS[gs] or gs, i)
            if not reported[key] then
                reported[key] = true
                events = events + 1
                log("ORPHAN p%d in %s at frame %d: %d glyph(s), %d still"
                    .. " moving, x=%d, cal_word=0", i + 1, GS[gs] or gs, t,
                    o[i].n, o[i].moving, o[i].x)
            end
        else
            run[i] = 0
        end
    end
end)

emu.register_stop(function()
    log("")
    log("=== %d arming(s) observed, %d distinct orphan situation(s)", armed, events)
    log("armings that got NO flight process: %d", noproc)
    log("longest a word stayed up: p1 %d frames, p2 %d  (the flight is 105)",
        worst_life[0], worst_life[1])
    log("widest a word travelled: p1 %d px, p2 %d  (the slide is 76)",
        worst_span[0], worst_span[1])
    log("flights that overran either: %d", sym_bad)
    log("flights found DEAD with glyphs still on screen: %d", dead_flights)
    log("longest orphan run: p1 %d samples, p2 %d (one sample = 3 frames)",
        worst_run[0], worst_run[1])
    if events == 0 then
        log("VERDICT CLEAN - no callout glyph outlived its flight")
    else
        log("VERDICT ORPHANS - glyphs survive their flight; see the states above")
    end
    if logf then logf:close() end
end)
