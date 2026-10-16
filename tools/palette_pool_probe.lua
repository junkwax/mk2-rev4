-- palette_pool_probe.lua
--
-- How much of the colour-map pool does a stage actually use, and how much
-- headroom is left?
--
-- Why: "dead pool sub freeze then snowball breaks the map screen". The
-- allocator (PALL.ASM) hands out fixed pools -- nmfpal foreground, nmbpal
-- background -- and `getfpal` returns Z when nothing is free. `swpal`
-- (MKUTIL.ASM:2796) reacts to that by SILENTLY keeping the old palette:
--
--     swpal   getfpal(new)      ; allocate the new one FIRST
--             jrne allm5
--             pull a0 / rets    ; no map free -> silently keep the old
--     allm5   delpal(old)       ; release old only once new succeeded
--
-- So exhaustion produces wrong colours rather than a crash, and because the
-- new palette is claimed BEFORE the old is released, every swap needs one
-- spare slot to work at all.
--
-- Both pools were already RAISED above the pristine source (nmfpal 25->35,
-- nmbpal 35->45), which suggests headroom was being bought rather than a
-- leak being found. This probe measures where it actually goes.
--
-- Counts entries whose palcnt != 0, sampled through a fight, and reports
-- baseline / peak / final per stage. A stage whose peak sits near the cap is
-- one bad fatality away from the failure above.
--
-- Also walks the PROCESS and OBJECT free lists (@free / @ofree, first long of
-- each block is the next pointer). Those are the other two shared pools an
-- effect-heavy fatality can drain -- `super_freeze_bang` fires `explode`, which
-- spawns a piece per chunk -- and blood already had a documented exhaustion bug
-- of exactly that shape (getprc denying allocations once a counter leaked).
--
-- Env: PAL_STAGE (stage id), PAL_P1, PAL_P2, PAL_LABEL, PAL_LOG
-- Usage: tools\run_palette_pool_probe.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP  = os.getenv("PAL_LOG")   or (ROOT .. "/tools/palette_pool_probe.log")
local LABEL = os.getenv("PAL_LABEL") or "stage"
local STAGE = tonumber(os.getenv("PAL_STAGE") or "0")
local P1CH  = tonumber(os.getenv("PAL_P1") or "8")   -- Sub-Zero
local P2CH  = tonumber(os.getenv("PAL_P2") or "9")   -- Reptile

local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[pal] " .. string.format(fmt, ...)
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
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate=sym("gstate"), curback=sym("curback"),
    p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
    p1_bar_view=sym("p1_bar_view"), p2_bar_view=sym("p2_bar_view"),
    winner_status=sym("winner_status"), battle_num=sym("battle_num"),
    map_position=sym("map_position"), f_freeze_timer=sym("f_freeze_timer"),
    fpalram=sym("fpalram"), bpalram=sym("bpalram"),
    free=sym("free"), ofree=sym("ofree"), blood_count=sym("blood_count"),
    worldtly=sym("worldtly"),
}

-- MAINEQU: palrsiz 040h per entry, palcnt at +020h (16 bits)
local PALRSIZ, PALCNT = 0x40, 0x20
local NMFPAL, NMBPAL = 35, 45
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local RUN_FRAMES = 1800
-- HOVER mode: park P2 high, the way a victim frozen in MID-AIR by Sub-Zero's
-- air freeze does. scrl6 reads *a8(oypos) directly, so pinning oypos is a
-- faithful stimulus for the y-scroll logic specifically (this is NOT the
-- oyval-pinning mistake - we are not asking the game to treat him as airborne,
-- only to see him up there). Measures whether the camera settles.
local HOVER = (os.getenv("PAL_HOVER") or "0") ~= "0"
local OYPOS = 0x0b0

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields, done = {}, false
local base_f, base_b = nil, nil
local peak_f, peak_b = 0, 0
local last_f, last_b = -1, -1
local base_p, base_o = nil, nil
local min_p, min_o = 9999, 9999   -- fewest FREE procs/objects seen = peak pressure
local peak_blood = 0
-- Camera drift. es_sub shakes by writing worldtly+16 and only lands home on an
-- EVEN iteration count; ordinary hit reactions already pass odd ones
-- (MKREACT 00050005 / 00070007), so a plain fight exercises this. On a stage
-- with no floor parallaxing nothing re-clamps it, so any drift is permanent.
local base_y, min_y, max_y, end_y = nil, nil, nil, nil
local prev_y, dir, flips = nil, 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end

local function used(base, n)
    if base == 0 then return -1 end
    local c = 0
    for i = 0, n-1 do
        if r16(base + i*PALRSIZ + PALCNT) ~= 0 then c = c + 1 end
    end
    return c
end

-- Walk a free list. Returns nil if it does not terminate within `cap`, rather
-- than returning the cap -- an earlier version returned 800 for the object
-- list on every stage, which read like a measurement and was just the limit.
-- nobj is 358, so anything past that means the walk is not following real
-- links and the number must not be reported as data.
local function free_len(headaddr, cap)
    if headaddr == 0 then return nil end
    local p, n = r32(headaddr), 0
    while p ~= 0 and n <= cap do
        p = r32(p)
        n = n + 1
    end
    if n > cap then return nil end
    return n
end
local function fmt(v) if v == nil then return "unmeasured" end return tostring(v) end

local function finish()
    if done then return end
    done = true
    log("")
    log("RESULT %-12s fg peak %2d/%d (baseline %s)   bg peak %2d/%d (baseline %s)",
        LABEL, peak_f, NMFPAL, tostring(base_f), peak_b, NMBPAL, tostring(base_b))
    local fg_head, bg_head = NMFPAL - peak_f, NMBPAL - peak_b
    log("       headroom at peak: fg %d slot(s), bg %d slot(s)", fg_head, bg_head)
    log("       free procs %s -> low %s   free objects %s -> low %s   peak blood %d",
        fmt(base_p), fmt(min_p), fmt(base_o), fmt(min_o), peak_blood)
    if base_y then
        local drift = (end_y or base_y) - base_y
        log("       camera worldtly+16 base=%d final=%d DRIFT=%d (range %d..%d) "
            .. "direction-flips=%d%s",
            base_y, end_y or base_y, drift, min_y, max_y, flips,
            HOVER and "  [HOVER]" or "")
        if HOVER then
            if flips > 20 then
                log("FAIL  %s: camera never settles - %d direction changes with a "
                    .. "fighter parked above the barrier", LABEL, flips)
            else
                log("ok    %s: camera settled (%d direction changes)", LABEL, flips)
            end
        end
        if drift ~= 0 then
            log("FAIL  %s: camera did not return home - drifted %d after shakes",
                LABEL, drift)
        else
            log("ok    %s: camera returned home (0 drift) despite shake range %d",
                LABEL, max_y - min_y)
        end
    end
    if min_o == nil then
        log("       NOTE object free-list walk did not terminate within %d (nobj=358) -"
            .. " object pressure is UNMEASURED here, not healthy", 400)
    end
    if min_p and min_p <= 4 then
        log("FAIL  %s: process pool nearly drained (low %d free) - getprc starts "
            .. "denying allocations here", LABEL, min_p)
    end
    if min_o and min_o <= 4 then
        log("FAIL  %s: object pool nearly drained (low %d free) - getobj returns 0",
            LABEL, min_o)
    end
    -- swpal claims the new palette BEFORE releasing the old, so a swap needs a
    -- free slot; at 0 spare, palette swaps silently no-op.
    if fg_head <= 0 then
        log("FAIL  %s: foreground pool FULL at peak - swpal cannot swap, colours "
            .. "will silently come out wrong", LABEL)
    elseif fg_head <= 2 then
        log("WARN  %s: only %d foreground slot(s) spare at peak - one extra effect "
            .. "(a fatality's palettes) exhausts it", LABEL, fg_head)
    else
        log("ok    %s: %d foreground slots spare at peak", LABEL, fg_head)
    end
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- %s: stage=%d p1=%d p2=%d ----", LABEL, STAGE, P1CH, P2CH)
        if A.fpalram == 0 or A.bpalram == 0 then
            log("ERROR fpalram/bpalram missing from MK2.MAP - results worthless")
        end
    end
    for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state,1); w16(A.p2_state,0)
        w16(A.p1_char,P1CH); w16(A.p2_char,P2CH); w16(A.curback,STAGE)
        if A.map_position ~= 0 then w16(A.map_position,0) end
        if A.battle_num ~= 0 then w16(A.battle_num,1) end
        if p1_confirm == 0 and frame-charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        base_f, base_b = used(A.fpalram, NMFPAL), used(A.bpalram, NMBPAL)
        peak_f, peak_b = base_f, base_b
        base_p, base_o = free_len(A.free, 200), free_len(A.ofree, 400)
        min_p, min_o = base_p, base_o
        if A.worldtly ~= 0 then
            base_y = r32(A.worldtly + 16); min_y, max_y = base_y, base_y
        end
        log("fight start frame=%d  baseline fg=%d/%d bg=%d/%d  free procs=%s objs=%s",
            frame, base_f, NMFPAL, base_b, NMBPAL, fmt(base_p), fmt(base_o))
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar,MAX_HP); w16(A.p1_bar_view,MAX_HP)
    w16(A.p2_bar,MAX_HP); w16(A.p2_bar_view,MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status,0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer,1) end

    local f, b = used(A.fpalram, NMFPAL), used(A.bpalram, NMBPAL)
    if f > peak_f then peak_f = f end
    if b > peak_b then peak_b = b end
    if f ~= last_f or b ~= last_b then
        log("  rel=%4d fg=%2d/%d bg=%2d/%d", frame - fighting_frame, f, NMFPAL, b, NMBPAL)
        last_f, last_b = f, b
    end

    if HOVER then
        local o = r32(A.p2_obj)
        if o ~= 0 then space:write_u16(o + OYPOS, 40) end   -- well above the barrier
    end

    if A.worldtly ~= 0 and base_y then
        local y = r32(A.worldtly + 16)
        if prev_y and y ~= prev_y then
            local d = (y > prev_y) and 1 or -1
            if dir ~= 0 and d ~= dir then flips = flips + 1 end
            dir = d
        end
        prev_y = y
        end_y = y
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end
    end

    if (frame % 15) == 0 then
        local fp, fo = free_len(A.free, 200), free_len(A.ofree, 400)
        if fp and (min_p == nil or fp < min_p) then min_p = fp end
        if fo and (min_o == nil or fo < min_o) then min_o = fo end
        if A.blood_count ~= 0 then
            local bc = r16(A.blood_count)
            if bc > peak_blood then peak_blood = bc end
        end
    end

    if frame - fighting_frame > RUN_FRAMES then finish(); return end
    if frame > 30000 then log("ERROR backstop"); finish() end
end)
