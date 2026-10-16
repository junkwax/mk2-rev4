-- deadpool_boon_drop_test.lua
--
-- THE ACID DROP: Ed Boon lets go of his hook and goes into THE DEAD POOL.
--
-- Hanger 0 (`hanger_initab[0]`, world x 269, `ed_start_y`) is Ed.  He is the
-- only hanger on a clock trigger rather than a Finish Him / autodrop trigger:
-- `hp_hang` (src/MKHANG.ASM) fires `hp_drop_begin` the first tick the round
-- clock reads `ed_drop_at_clock` or lower.  From there the sequence is one
-- long process with no instrumentation of its own, so this rig measures it
-- from the OUTSIDE - `hp_body_ptr[0]` plus the object lists - and segments it
-- into the beats the ROM actually walks:
--
--   HANG      body parked at ed_start_y on the hook, chain above it
--   TRIGGER   hp_drop_busy 0->1, hp_dropped[0] latches 1
--   FALL      oypos += ed_drop_step every drop_ticks; strips cut at the
--             crossline (acid_lower_mask_y) as they breach the surface
--   SUBMERGE  fall loop exits at acid_body_hide_y; multipart body blanked
--   SPLASH    acidsplash1a + hanger_splash_proc, 050h ticks
--   SIMMER    simmer_fx_proc, acid_simmer_wait ticks
--   PRERISE   three bubbles (only when hanger_fx_enable is 1)
--   RISE      DEDHANG skeleton from acid_rise_start up to ed_start_y at
--             rise_step every rise_ticks
--   DONE      hp_drop_busy 1->0, skeleton parked, hp_hold_acid
--
-- Every expected number is READ OUT OF src/MKHANG.ASM, never inherited, so
-- retuning an equate retunes the rig instead of breaking it.
--
-- Nothing here writes to the drop sequence.  The rig only forces the stage
-- and the character select, then watches.
--
-- Env knobs:
--   DP_TEST_LOG=path    log file (default tools/deadpool_boon_drop_test.log)
--   DP_CLOCK_JUMP=1     slam the round clock to ed_drop_at_clock+2 as soon as
--                       the fight starts, instead of waiting ~4s for it
--   DP_TRACE=1          per-tick trace lines (big log; default beat-only)
--   DP_SNAPS=1          snapshot every beat transition (default 1)
--   DP_SNAP_EVERY=N     ALSO snapshot every N frames from trigger to done, so
--                       the whole sink/rise can be assembled into a filmstrip
--   DP_WATCH=f          run FLAT OUT through boot and throttle to f x speed for
--                       the sequence only - boot is ~15s of menus nobody wants
--                       to watch at quarter speed
--   DP_READY=path       touched once frames really run, so the launcher can
--                       tell "parked on the CRC warning screen" from "running"
--   DP_TOLERANCE=N      percent slack on the timing budgets (default 30)
--   DP_HANGER=N         which hanger to watch (default: 2, Tony - the newest
--                       body on the schedule).  Every
--                       expectation comes from hanger_initab row N and from
--                       that body's own piece records, so the rig follows
--                       whichever developer is being brought up.
--   DP_NEXT_ROUND=1     after the drop, run the round out and check round 2:
--                       every body that went in must come back as its
--                       SKELETON on the hook, not whole again (the drops are
--                       once per match - create_hangers resets on round 1 only)
--   DP_PIN_CAM=0        do not pull the two idle fighters over to the hanger.
--                       They are what the camera follows, and the bodies are
--                       spread across the whole pool now, so most of them are
--                       off screen at the resting camera (world 373..773).

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("DP_TEST_LOG") or (ROOT .. "/tools/deadpool_boon_drop_test.log")
local READY_PATH = os.getenv("DP_READY")
local CLOCK_JUMP = getenv_int("DP_CLOCK_JUMP", 0) ~= 0
local TRACE = getenv_int("DP_TRACE", 0) ~= 0
local SNAPS = getenv_int("DP_SNAPS", 1) ~= 0
local SNAP_EVERY = getenv_int("DP_SNAP_EVERY", 0)
local WATCH = tonumber(os.getenv("DP_WATCH") or "0") or 0
local TOLERANCE = getenv_int("DP_TOLERANCE", 30) / 100.0

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    print("[dpboon] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

--------------------------------------------------------------------------
-- build truth: every constant comes out of the source it was built from
--------------------------------------------------------------------------

local K = {
    -- MKHANG.ASM equates, with the current values as the fallback
    ed_start_y = 20, ed_crossline_y = 76, ed_drop_step = 3, drop_ticks = 4,
    ed_body_rows = 112, ed_acid_under_y = 188,
    acid_pull_line_y = 76, acid_lower_mask_y = 188, acid_body_hide_y = 188,
    acid_rise_start = 0xc0, acid_rise_stop = 0x90,
    rise_step = 5, rise_ticks = 4, strip_step = 5,
    acid_simmer_wait = 0x12c, ed_drop_at_clock = 95,
    hbody_chain_ofs = -211,
    acid_ripple_y = 0xb8, acid_drip_yofs = 0, acid_lower_fx_z = -1,
    pre_rise_bubble_gap = 0x18, pre_rise_bubble_ticks = 0x20,
    hanger_fx_enable = 0, hanger_rise_ripple_enable = 0,
    hanger_rise_bubble_enable = 0, hanger_debug_static = 0,
    hanger_match_autodrop = 0, acid_bubble_preview_only = 0,
    deadpool_hanger_runtime_enable = 1,
    NHANGERS = 9, acid_drop_hanger = 4,  -- the rig's default body (the newest), not an equate
    -- the chain stack, for the per-hanger joint expectations
    wax_hook_yofs = -8, wax_tinchain_yofs = -77, wax_chain_yofs = -286,
    wax_tinchain_from_hook = -69, wax_chain_from_hook = -278,
    tony_conn_from_hook = -63, tony_chain_from_hook = -272,
    drop_pause_ticks = 821, hanger_drop_view_left = 0, hanger_drop_view_right = 350,
    tinchain4_rows = 70, longchain_rows = 211,
}
local SPLASH_HOLD = 0x50 -- sloop 050h at hp_splash_wake; not an equate

-- The pool, out of BGND.ASM, so "is he actually over liquid" is measured and
-- not assumed - the same equates tools/deadpool_acid_band.py checks.
local ACID_L, ACID_R, ACID_MARGIN = 195, 947, 30
do
    local fh = io.open((os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main")
        :gsub("\\", "/") .. "/src/BGND.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n = line:match("^dp_acid_raw_lft%s+%.equ%s+(%d+)")
            if n then ACID_L = tonumber(n) end
            n = line:match("^dp_acid_raw_rgt%s+%.equ%s+(%d+)")
            if n then ACID_R = tonumber(n) end
            n = line:match("^dp_acid_margin%s+%.equ%s+(%d+)")
            if n then ACID_MARGIN = tonumber(n) end
        end
        fh:close()
    end
end

-- `name .equ value` / `name .set value`, decimal or 0xxh, possibly negative,
-- possibly defined in terms of a constant we already read.
local function resolve_equates(path)
    local fh = io.open(path, "r")
    if not fh then log("WARN cannot read %s", path); return 0 end
    local n = 0
    for line in fh:lines() do
        line = line:gsub(";.*$", "")
        local name, rhs = line:match("^([%w_]+)%s+%.[es][qe][ut]%s+(.+)$")
        if name and K[name] ~= nil then
            rhs = rhs:gsub("%s+$", "")
            local v
            local hex = rhs:match("^0(%x+)[hH]$")
            if hex then v = tonumber(hex, 16) end
            if not v then v = tonumber(rhs) end
            if not v then
                -- one level of "othername" or "othername-21" or "a*b"
                local base, op, num = rhs:match("^([%w_]+)%s*([%+%-%*])%s*([%w_]+)$")
                if base and K[base] ~= nil then
                    -- the right side may be a literal OR another equate we have
                    local m = tonumber(num) or K[num]
                    if m then
                        local b = K[base]
                        if op == "+" then v = b + m
                        elseif op == "-" then v = b - m
                        else v = b * m end
                    end
                elseif K[rhs] ~= nil then
                    v = K[rhs]
                end
            end
            if v then K[name] = v; n = n + 1 end
        end
    end
    fh:close()
    return n
end
log("equates resolved from MKHANG.ASM: %d", resolve_equates(ROOT .. "/src/MKHANG.ASM"))

-- WHICH BODY.  The hangers are spread across the whole pool against the order
-- photo, and both scheduled bodies drop in one match; the rig watches ONE -
-- Tony (2) by default, DP_HANGER overrides it.  Everything
-- below - his column, his hang height, how tall he is and therefore where his
-- feet meet the acid - is read out of the source he was built from.
local HANG = getenv_int("DP_HANGER", -1)
if HANG < 0 then HANG = K.acid_drop_hanger end

-- ONE table, not three locals: Lua allows 200 locals in a function and this
-- file sits near that ceiling (MAME reports "too many local variables" and
-- loads nothing at all).
local HT = { x = {}, y = {}, chunk = {} }
do
    local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
    if fh then
        local armed, n, chunk = false, 0, nil
        for line in fh:lines() do
            if line:match("^hanger_initab") then armed = true
            elseif armed then
                local lab = line:match("%.long%s+([%w_]+)")
                if lab then chunk = lab end
                local x, y = line:match("%.word%s+(%d+)%s*,%s*([%w_]+)")
                if x then
                    HT.x[n] = tonumber(x)
                    HT.y[n] = tonumber(y) or K[y] or K.ed_start_y
                    HT.chunk[n] = chunk
                    n = n + 1
                    if n >= K.NHANGERS then break end
                end
            end
        end
        fh:close()
    end
end
-- Any `name .equ <number>` in MKHANG.ASM.  K only knows the equates it has a
-- default for, and each new body brings its own (john_conn_from_hook...);
-- without this a table row naming one fell back to Ed's number.
function HT.equ(name)
    local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
    if not fh then return nil end
    local v
    for line in fh:lines() do
        local n = line:match("^" .. name .. "%s+%.equ%s+(%-?%d+)%s*")
        if n then v = tonumber(n); break end
    end
    fh:close()
    return v
end

-- hanger_acid_live: who is scheduled.  Hanger order is the drop order.
HT.live = {}
do
    local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
    if fh then
        local armed, n = false, 0
        for line in fh:lines() do
            if line:match("^hanger_acid_live") then armed = true
            elseif armed then
                local v = line:match("^%s+%.word%s+(%d+)")
                if v then HT.live[n] = tonumber(v); n = n + 1
                elseif line:match("^%S") then break end
            end
        end
        fh:close()
    end
end
local ED_X = HT.x[HANG] or 269
local ED_Y = HT.y[HANG] or K.ed_start_y

-- How tall he is, and therefore where his feet meet the acid.  Both are
-- measured off his own piece records, which load further down - these two
-- fallbacks are Ed's and are right for nobody else.
local BODY_ROWS = K.ed_body_rows
local CROSSLINE = K.acid_body_hide_y - BODY_ROWS

-- The per-hanger BSS slots: 32-bit pointers, 16-bit flags.  Fields, not
-- locals - see HT above.
HT.slot32, HT.slot16 = HANG * 32, HANG * 16

-- THE JOINTS THIS BODY'S WAX AUTHORS.  Each hanger's chain stack comes out of
-- its own WAX, and they do not all meet the same way: Ed's connector ends one
-- row into the hook, Tony's seven.  Row HANG of hanger_conn_from_hook /
-- hanger_chain_from_hook (symbols resolved through the equates) gives both:
--   hook joint  = hook top - connector bottom = -(conn_from_hook + 70)
--   chain joint = connector top - chain bottom = conn - (chain + 211)
-- Measured joints have to sit within 2 of THESE, not of Ed's.
do
    function HT.table_row(name)
        local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
        if not fh then return nil end
        local armed, n, v = false, 0, nil
        for line in fh:lines() do
            if line:match("^" .. name .. "%s*$") then armed = true
            elseif armed then
                local tok = line:match("^%s+%.word%s+([%w_%-]+)")
                if tok then
                    if n == HANG then v = tonumber(tok) or K[tok] or HT.equ(tok); break end
                    n = n + 1
                elseif line:match("^%S") then break end
            end
        end
        fh:close()
        return v
    end
    local cfh = HT.table_row("hanger_conn_from_hook") or -69
    local chfh = HT.table_row("hanger_chain_from_hook") or -278
    HT.fx = HT.table_row("hanger_fx_xofs") or 24
    HT.want_hook = -(cfh + (K.tinchain4_rows or 70))
    HT.want_chain = cfh - (chfh + (K.longchain_rows or 211))
    HT.j = { hook = {}, chain = {} }
    log("hanger %d chain stack: connector %d / chain %d off the hook -> joints "
        .. "hook %d, chain %d", HANG, cfh, chfh, HT.want_hook, HT.want_chain)
end

-- Timing budgets, in ticks, derived from the equates above.
local B = {}
B.fall = math.ceil((K.acid_body_hide_y - ED_Y) / math.max(1, K.ed_drop_step)) * K.drop_ticks
B.splash = SPLASH_HOLD
B.simmer = K.acid_simmer_wait
B.prerise = (K.hanger_fx_enable ~= 0)
    and (2 * K.pre_rise_bubble_gap + K.pre_rise_bubble_ticks) or 0
-- the fall stops on the first step at/after the hide line, and the rise now
-- starts from exactly there rather than from acid_rise_start
local SINK_Y = ED_Y + math.ceil((K.acid_body_hide_y - ED_Y) / math.max(1, K.ed_drop_step)) * K.ed_drop_step
B.rise = math.ceil((SINK_Y - ED_Y) / math.max(1, K.rise_step)) * K.rise_ticks
B.total = B.fall + B.splash + B.simmer + B.prerise + B.rise

--------------------------------------------------------------------------
-- symbols
--------------------------------------------------------------------------

local symbols, missing = {}, {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        log("WARN no linker map at src/mk2.map")
    end
end
-- Required: the rig cannot run without these.
local function sym(name)
    local v = symbols[name]
    if v == nil then missing[#missing + 1] = name; return 0 end
    return v
end
-- Optional: .bss that is not .global yet.  Reported, never fatal.
local optional_absent = {}
local function sym_opt(name)
    local v = symbols[name]
    if v == nil then optional_absent[#optional_absent + 1] = name; return nil end
    return v
end

local A = {
    active = sym("active"), free = sym("free"), worldtly = sym("worldtly"),
    gstate = sym("gstate"), curback = sym("curback"),
    winner_status = sym("winner_status"), round_num = sym("round_num"),
    clk_tens = sym("clk_tens"), clk_ones = sym("clk_ones"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym_opt("p1_obj"), p2_obj = sym_opt("p2_obj"),
    p2_bar = sym_opt("p2_bar"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    worldtlx = sym("worldtlx"),
    hanger_coords = sym("hanger_coords"),
    hp_body_ptr = sym("hp_body_ptr"),
    hp_dropped = sym("hp_dropped"),
    hp_drop_busy = sym("hp_drop_busy"),
    hp_next_drop_ticks = sym_opt("hp_next_drop_ticks"),
    -- Only THREE of the nine hang in a match now (hp_pick_lineup).  The rig
    -- watches one named body, so it pins him: a non-zero mask here IS the
    -- lineup, and the rotation's own state is left alone.
    hp_lineup_force = sym_opt("hp_lineup_force"),
    hp_live_now = sym_opt("hp_live_now"),
    palram = sym_opt("palram"),
    f_freeze_timer = sym_opt("f_freeze_timer"),
    hp_dbg_beat = sym("hp_dbg_beat"),
    hp_dbg_where = sym("hp_dbg_where"),
    -- not .global yet; add `.global hp_lower_strips,hp_skel_visible,hp_splash_x`
    -- to MKHANG.ASM and these columns light up.
    hp_lower_strips = sym_opt("hp_lower_strips"),
    hp_skel_visible = sym_opt("hp_skel_visible"),
    hp_splash_x = sym_opt("hp_splash_x"),
    -- MPROC's temporary kilwho probe: who reclaimed the hanger process
    kilwho_hit = sym_opt("kilwho_hit"),
    kilwho_a0 = sym_opt("kilwho_a0"),
    kilwho_a1 = sym_opt("kilwho_a1"),
    kilwho_n = sym_opt("kilwho_n"),
    sucwho_pc = sym_opt("sucwho_pc"),
    sucwho_n = sym_opt("sucwho_n"),
    sucwho_a12 = sym_opt("sucwho_a12"),
    sucwho_a13 = sym_opt("sucwho_a13"),
    dropwho_why = sym_opt("dropwho_why"),
    dropwho_n = sym_opt("dropwho_n"),
}

local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, ozpos = 0x0d0,
            oflags = 0x0f0, osag = 0x100, osize = 0x120, oimg = 0x1a0, oid = 0x1c0 }
-- DISPEQU.ASM: one multipart piece is sag(32) sizex(16) sizey(16) ctrl(16)
-- anixy(32) = mp_length 112 bits.  The LAST piece's sizey is the row the acid
-- has eaten down to, so it is the direct read-out of the row-exact clip.
local MP = { sag = 0, sizex = 32, sizey = 48, length = 112 }
-- osize is [h:w]; the h half sits 16 bits up, same as a piece's mp_sizey.
local O_SIZEY = 0x120 + 16
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0 }
local PID_BANI, PID_SPLASH = 6, 0x1b
local PID_EDPOOL_FX = 0x111   -- MAINEQU.ASM: the EDACID boil lanes stamp this as their OID

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
-- DP_P1_CHAR / DP_P2_CHAR pick the fighters (ft_ ids, MAINEQU.ASM) - so a run
-- also puts that pair through the VS screen, snapped as "vs"
local FT_KANG, FT_JAX = getenv_int("DP_P1_CHAR", 1), getenv_int("DP_P2_CHAR", 11)
local STAGE_DEADPOOL = 0
local M_INVISO = 0x0020

--------------------------------------------------------------------------
-- SAG -> label, so the rig can name what is actually on screen
--------------------------------------------------------------------------

local art = {}       -- [sag] = { label=, w=, h= }
local art_masked = {}
local art_by_label = {}  -- [label] = the same record, for the piece lists
local function load_art(path)
    local fh = io.open(path, "r")
    if not fh then return 0 end
    local n, label, w, h, ay, ax = 0, nil, nil, nil, 0, 0
    for line in fh:lines() do
        local lab = line:match("^([%w_]+):")
        if lab then
            label, w, h = lab, nil, nil
        elseif label then
            if not w then
                local a, b = line:match("%.word%s+(-?%d+)%s*,%s*(-?%d+)")
                if a then
                    w, h = tonumber(a), tonumber(b)
                    -- the 4th word is the anipoint y: oypos = anchor - aniy
                    ay = tonumber(line:match(
                        "%.word%s+%-?%d+%s*,%s*%-?%d+%s*,%s*%-?%d+%s*,%s*(%-?%d+)") or 0)
                    ax = tonumber(line:match(
                        "%.word%s+%-?%d+%s*,%s*%-?%d+%s*,%s*(%-?%d+)") or 0)
                end
            else
                local raw = line:match("%.long%s+0?(%x+)[hH]")
                if raw then
                    local sag = tonumber(raw, 16)
                    local rec = { label = label, w = w, h = h, ay = ay, ax = ax }
                    art[sag] = rec
                    art_masked[sag & 0x00ffffff] = rec
                    art_by_label[label] = rec
                    n = n + 1
                    label = nil
                end
            end
        end
    end
    fh:close()
    return n
end
local art_n = load_art(ROOT .. "/src/MKHANGN.TBL")
    + load_art(ROOT .. "/src/ACIDHANG.TBL")
    + load_art(ROOT .. "/src/HANGTONY.TBL")
    + load_art(ROOT .. "/src/HANGTNYD.TBL")
    + load_art(ROOT .. "/src/HANGJOHN.TBL")
    + load_art(ROOT .. "/src/HANGJOHD.TBL")
    + load_art(ROOT .. "/src/HANGGEO.TBL")
    + load_art(ROOT .. "/src/HANGGEOD.TBL")
    + load_art(ROOT .. "/src/HANGMARK.TBL") + load_art(ROOT .. "/src/HANGJEFF.TBL")
    + load_art(ROOT .. "/src/HANGSTEV.TBL") + load_art(ROOT .. "/src/HANGSAL.TBL")
    + load_art(ROOT .. "/src/HANGERIC.TBL")
    + load_art(ROOT .. "/src/MKBGANI.TBL")
log("art records loaded: %d", art_n)

-- How tall this body is, from its OWN piece records: each piece is drawn at
-- oypos - aniy, so the body ends at max(-aniy + h).  Ed is six 20px bands
-- (112 rows) and Tony three 40px ones (120), which is exactly why
-- hp_cut_shape_to_surface stopped dividing by strip_step.
do
    local pieces = {}
    local want = HT.chunk[HANG]
    if want then
        local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
        if fh then
            local armed = false
            for line in fh:lines() do
                if line:match("^" .. want .. "%s*$") then armed = true
                elseif armed then
                    local body = line:match("%.long%s+(.*)$")
                    if body then
                        for lab in body:gmatch("[%w_]+") do
                            if lab ~= "0" then pieces[#pieces + 1] = lab end
                        end
                        if body:match("0%s*$") then break end
                    elseif not line:match("^%s*%*") and line:match("%S") then break end
                end
            end
            fh:close()
        end
    end
    local rows = 0
    for _, lab in ipairs(pieces) do
        local rec = art_by_label[lab]
        if rec then
            local bottom = -(rec.ay or 0) + (rec.h or 0)
            if bottom > rows then rows = bottom end
            local right = -(rec.ax or 0) + (rec.w or 0)       -- drawn at x - anix
            if right > (HT.body_w or 0) then HT.body_w = right end
        end
    end
    if rows > 0 then BODY_ROWS = rows end
    log("hanger %d: %s = %d piece(s), %d rows tall", HANG,
        tostring(want), #pieces, BODY_ROWS)
end
-- His crossline: where HIS feet meet the surface.  ed_crossline_y is Ed's.
CROSSLINE = K.acid_body_hide_y - BODY_ROWS
log("hanger %d at world x=%d y=%d, crossline %d (Ed's is %d)",
    HANG, ED_X, ED_Y, CROSSLINE, K.ed_crossline_y)


local function art_of(sag)
    return art[sag] or art[sag & 0xffffffff] or art_masked[sag & 0x00ffffff]
end

-- What KIND of thing is this label?  Beat detection keys off these.
local function classify(label)
    if not label then return nil end
    -- A developer's hanging body is <NAME>HANG1x and his skeleton is the same
    -- name with a D in front: EDHANG1A/DEDHANG1A, TONYHANG1A/DTONYHANG1A.
    -- The skeleton test goes FIRST - DEDHANG matches both patterns.
    if label:match("^D%u+HANG") or label:match("^D%u+HG")
        or label:match("^DEDBODY") or label:match("^DEDLEG")
        or label:match("^DEDHEAD") then return "skel" end
    if label:match("^%u+HANG") or label:match("^%u+HG")
        or label:match("^EDBODY") or label:match("^EDLEG")
        or label:match("^EDHEAD") then return "body" end
    if label == "longchain" then return "chain" end
    if label == "TINCHAIN4" then return "connector" end
    if label == "TINHOOK" then return "hook" end
    if label:match("^acidsplash") then return "splash" end
    if label:match("^BUBL") then return "bubble" end
    if label:match("^greendrip") or label:match("^aciddrip") then return "drip" end
    if label:match("^pooldrip") then return "ripple" end
    if label:match("^ACIDSMOKE") then return "smoke" end
    return nil
end

--------------------------------------------------------------------------
-- machine access
--------------------------------------------------------------------------

local cpu, space, fields = nil, nil, {}
local function r16(a) if a == 0 then return 0 end return space:read_u16(a) end
local function r32(a) if a == 0 then return 0 end return space:read_u32(a) end
local function w16(a, v) if a ~= 0 then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if a ~= 0 then space:write_u32(a, v & 0xffffffff) end end

-- THE CAMERA FOLLOWS THE FIGHTERS, and the bodies hang across the whole pool.
-- Two idle fighters park the camera at worldtlx 373, showing world 373..773,
-- so a body at 892 is never drawn and every check that needs to SEE him
-- reports nothing.  Pull the pair over to his column instead of writing
-- worldtlx, which BGND recomputes from them anyway.
HT.pin_cam = getenv_int("DP_PIN_CAM", 1) ~= 0
HT.next_round = getenv_int("DP_NEXT_ROUND", 0) ~= 0
local function pin_fighters_at(x)
    if not (HT.pin_cam and A.p1_obj and A.p2_obj) then return end
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return end
    -- BESIDE him, not on him: pinned either side of his column they stood
    -- in front of the whole drop.  Both to his LEFT was worse - the camera
    -- centres between them, so it stopped at worldtlx 498 and he was just off
    -- the right edge.  Both to his RIGHT pushes the camera as far as the stage
    -- lets it go and leaves him clear, left of them.
    local ax, bx = x + 55, x + 100
    w16(a + O.oxpos, ax & 0xffff); w32(a + O.oxval, (ax << 16) & 0xffffffff)
    w16(b + O.oxpos, bx & 0xffff); w32(b + O.oxval, (bx << 16) & 0xffffffff)
end

local function body_ptr() return r32(A.hp_body_ptr + HT.slot32) end

-- Walk hanger 0's multipart list: how many pieces are live, and how tall the
-- bottom one is drawing right now.
local function mpart_tail()
    local obj = body_ptr()
    if obj == 0 then return 0, nil end
    local mp = r32(obj + O.oimg)
    if mp == 0 then return 0, nil end
    -- The piece that reaches LOWEST down him is the one the surface is
    -- cutting: every piece it crosses ends exactly on the waterline.  That is
    -- the last band when bands are stacked (Ed, Tony), but not when pieces
    -- sit side by side - Mark's second piece is his arm, rows 30..69, and
    -- reading the LAST piece held its 39 rows for 76 frames while his body
    -- was being eaten.  Bottom = -aniy + sizey (aniy at +96, DISPEQU mp_aniy).
    local n, best, best_bottom = 0, nil, nil
    while n < 16 do
        if r32(mp + MP.sag) == 0 then break end
        local h = r16(mp + MP.sizey)
        local bottom = -s16(r16(mp + 96)) + h
        if best_bottom == nil or bottom > best_bottom then best, best_bottom = h, bottom end
        n = n + 1
        mp = mp + MP.length
    end
    return n, best
end
local function dropped0() return r16(A.hp_dropped + HT.slot16) end
local function drop_busy() return r16(A.hp_drop_busy) end
-- the drop schedule is a CHAIN now (MKHANG.ASM): hp_next_drop_ticks counts
-- down to the next body, whoever that is
function HT.next_ticks()
    return A.hp_next_drop_ticks and s16(r16(A.hp_next_drop_ticks)) or nil
end
local function strips0()
    return A.hp_lower_strips and r16(A.hp_lower_strips + HT.slot16) or nil
end
local function skel_vis0()
    return A.hp_skel_visible and r16(A.hp_skel_visible + HT.slot16) or nil
end
local function round_clock() return r16(A.clk_tens) * 10 + r16(A.clk_ones) end
local SCRW = 400
local function camera_left() return s16(r16(A.worldtlx + 16)) end
local function dbg_where() return r16(A.hp_dbg_where) end
local function dbg_beat() return r16(A.hp_dbg_beat) end

-- hp_dbg_where is MKHANG's own breadcrumb through the hang loop's gate chain.
-- When the drop does not fire, the last value it reached says which gate said
-- no.  1/2/3 are the hang-loop checkpoints; 10/11 are setup; 100+n is "the
-- index resolved to n".
local WHERE = {
    [1] = "hang_loop_top", [2] = "past_eligibility", [3] = "at_clock_compare",
    [10] = "setup_body_built", [11] = "setup_fx_done",
}
local function where_name(v)
    if WHERE[v] then return string.format("%d(%s)", v, WHERE[v]) end
    if v >= 100 and v < 100 + K.NHANGERS then
        return string.format("%d(index_%d)", v, v - 100)
    end
    return tostring(v)
end

local function walk_objects(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj, guard, seen = r32(list), 0, {}
        while obj ~= 0 and guard < 400 do
            if seen[obj] then return "cycle" end
            seen[obj] = true
            fn(obj)
            obj = r32(obj + O.next)
            guard = guard + 1
        end
        if guard >= 400 then return "overflow" end
    end
    return nil
end

-- Census of everything the rig knows how to name, this tick.
-- TWO BODIES HANG NOW, and they share their art.  Ed's chain, connector and
-- hook are the same three labels as the inspected hanger's - `longchain`,
-- `TINCHAIN4`, `TINHOOK` - so a census that took whichever came first in the
-- object list measured Ed's chain against Tony's body: "chain bottom minus
-- body top -216..-61" and "biggest one-frame y move 158 px" were both that,
-- not a chain that jumps.  The two are 125 px apart on the sheet and the whole
-- assembly sits within +20 of its body's x, so a column window tells them
-- apart.  FX are windowed too (see mine): two bodies drop in one match now.
local HANGER_KINDS = { body = true, skel = true,
                       chain = true, connector = true, hook = true }
local function mine(kind, x)
    local d = x - ED_X
    -- NINE bodies now, ~74px apart (the illustration), so the windows are the
    -- ones the art itself allows, not "somewhere near him":
    if kind == "body" or kind == "skel" then
        return d >= -2 and d <= 2          -- anchored exactly at his x
    end
    if HANGER_KINDS[kind] then
        return d >= 0 and d <= 45          -- chain/connector/hook: x+13..+36
    end
    -- FX: his boil, drips, splash and steam sit within ~30px of his FX centre
    -- (hanger_fx_xofs); a neighbour's cloud starts ~40px further on
    local f = d - (HT.fx or 24)
    if kind == "splash" then return f >= -90 and f <= 34 end  -- wide, placed by
                                        -- its anipoint: the left edge is far out
    return f >= -34 and f <= 34
end

local function census()
    -- zs collects EVERY object's layer per kind, not just the first one the
    -- walk happens to reach: the ambient boil and the cut-hiding bubbles are
    -- the same art on different layers, and "first" only ever saw the ambient.
    -- spots does the same for positions - several drips are alive at once and
    -- "first" kept reporting whichever sat earliest in the object list.
    local out = { count = {}, first = {}, zs = {}, spots = {}, unknown = {} }
    walk_objects(function(obj)
        local rec = art_of(r32(obj + O.osag))
        local kind = rec and classify(rec.label)
        if kind and not mine(kind, r16(obj + O.oxpos)) then return end
        -- Anything on screen the rig cannot NAME.  A check that counts art it
        -- never matched reads as "the feature is missing" when the feature is
        -- there and only the lookup failed.
        if not kind then
            out.unknown[#out.unknown + 1] = {
                sag = r32(obj + O.osag), oid = r16(obj + O.oid),
                x = r16(obj + O.oxpos), y = s16(r16(obj + O.oypos)),
                named = rec and rec.label or nil,
            }
        end
        if kind then
            out.count[kind] = (out.count[kind] or 0) + 1
            local z = s16(r16(obj + O.ozpos))
            out.zs[kind] = out.zs[kind] or {}
            out.zs[kind][z] = (out.zs[kind][z] or 0) + 1
            out.spots[kind] = out.spots[kind] or {}
            table.insert(out.spots[kind],
                { x = r16(obj + O.oxpos), y = s16(r16(obj + O.oypos)), obj = obj,
                  sag = r32(obj + O.osag), w = rec.w, z = s16(r16(obj + O.ozpos)),
                  oid = r16(obj + O.oid),
                  -- the ANCHOR, which is what hp_place_single_fx places
                  ay = s16(r16(obj + O.oypos)) + (rec.ay or 0) })
            if not out.first[kind] then
                out.first[kind] = {
                    label = rec.label, w = rec.w, h = rec.h, obj = obj,
                    x = r16(obj + O.oxpos), y = s16(r16(obj + O.oypos)),
                    z = s16(r16(obj + O.ozpos)),
                    inviso = (r16(obj + O.oflags) & M_INVISO) ~= 0,
                }
            end
        end
    end)
    return out
end

-- Is hanger_proc still ALIVE?  hp_dbg_beat standing still says the hang loop
-- is not running; this says whether that is because the process is gone.
local function proc_count(pid)
    local n, obj, guard, seen = 0, r32(A.active), 0, {}
    while obj ~= 0 and guard < 400 do
        if seen[obj] then return n, "cycle" end
        seen[obj] = true
        if r16(obj + P.id) == pid then n = n + 1 end
        obj = r32(obj + P.next)
        guard = guard + 1
    end
    return n, (guard >= 400) and "overflow" or nil
end

-- Every live pid, once, so a zero count can be told apart from a broken walk.
-- Find one process record's fate.  A record that has left `active` either
-- went back on the `free` list (something reclaimed it: kilall / sucide) or is
-- still on `active` under a DIFFERENT procid (something xferprc'd it).  Those
-- are completely different bugs, so the rig says which.
local function proc_fate(ptr)
    local on_active, on_free = false, false
    local obj, guard, seen = r32(A.active), 0, {}
    while obj ~= 0 and guard < 400 do
        if seen[obj] then break end
        seen[obj] = true
        if obj == ptr then on_active = true end
        obj = r32(obj + P.next); guard = guard + 1
    end
    obj, guard, seen = A.free ~= 0 and r32(A.free) or 0, 0, {}
    while obj ~= 0 and guard < 400 do
        if seen[obj] then break end
        seen[obj] = true
        if obj == ptr then on_free = true end
        obj = r32(obj + P.next); guard = guard + 1
    end
    return string.format("ptr=0x%08x procid_now=0x%04x on_active=%s on_free=%s",
        ptr, r16(ptr + P.id), tostring(on_active), tostring(on_free))
end

local function proc_ptr(pid)
    local obj, guard, seen = r32(A.active), 0, {}
    while obj ~= 0 and guard < 400 do
        if seen[obj] then break end
        seen[obj] = true
        if r16(obj + P.id) == pid then return obj end
        obj = r32(obj + P.next); guard = guard + 1
    end
    return 0
end

local function proc_histogram()
    local hist, total, obj, guard, seen = {}, 0, r32(A.active), 0, {}
    while obj ~= 0 and guard < 400 do
        if seen[obj] then break end
        seen[obj] = true
        local id = r16(obj + P.id)
        hist[id] = (hist[id] or 0) + 1
        total = total + 1
        obj = r32(obj + P.next)
        guard = guard + 1
    end
    local t = {}
    for id, n in pairs(hist) do t[#t + 1] = string.format("0x%x=%d", id, n) end
    table.sort(t)
    return string.format("total=%d head=0x%08x %s", total, r32(A.active), table.concat(t, " "))
end

-- Throttle only around the part worth looking at.  MAME's -speed is static and
-- would drag the boot schedule out with it; this leaves the rig unthrottled for
-- the ~800 frames of coin/select/intro and slows down for the drop alone.
local watch_state = nil
local function set_watch(on)
    if WATCH <= 0 or watch_state == on then return end
    local ok = pcall(function()
        local v = manager.machine.video
        v.throttled = on
        if on then v.throttle_rate = WATCH end
    end)
    if ok then
        watch_state = on
        log("watch: throttle %s", on and string.format("ON at %.2fx", WATCH) or "OFF")
    elseif watch_state == nil then
        watch_state = on
        log("WARN watch: this MAME will not take video.throttled/throttle_rate; "
            .. "use -Speed for a static slowdown instead")
    end
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local snap_index = 0
local strip_shots = 0
local function shutter()
    local sc = main_screen()
    if sc then pcall(function() sc:snapshot() end) end
end
local function snap(label)
    if SNAPS then
        local s = main_screen()
        if s then pcall(function() s:snapshot() end) end
    end
    log("SNAP idx=%04d frame=%d label=%s", snap_index, frame, label)
    snap_index = snap_index + 1
end

--------------------------------------------------------------------------
-- observation state
--------------------------------------------------------------------------

local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm_start = 0, 0, 0
local clock_jumped = false
local finished = false
local last_status = 0

-- beat timestamps (frame numbers, 0 = not seen)
local T = { hang = 0, trigger = 0, submerge = 0, splash = 0, skel = 0,
            rise_start = 0, rise_done = 0, done = 0 }
local trigger_clock = nil

-- fall / rise traces
local fall_y_min, fall_y_max, fall_x_min, fall_x_max = nil, nil, nil, nil
local fall_regress, rise_regress = 0, 0
local sink_y = nil
local rise_y_start, rise_y_end = nil, nil
local strips_start, strips_min = nil, nil
local hang_y, hang_x = nil, nil
local park_y, park_x = nil, nil
local seen_kind = {}
local peak_bubbles, peak_drips, peak_ripples = 0, 0, 0
local base_bubbles, base_drips, base_ripples = nil, nil, nil
local chain_notes = {}
local last_body_y, prev_ptr = nil, nil
local stall_note = nil

local cam_lo, cam_hi = nil, nil
local chain_gap_min, chain_gap_max = nil, nil
-- The JOINTS, not just the chain against the body: longchain's art bottom
-- against TINCHAIN4's top, and TINCHAIN4's bottom against TINHOOK's top,
-- whenever the pieces are actually drawn.  Two placement paths disagreeing
-- shows up here as a spread - the parked skeleton once had a 26px gap the
-- body check could not see.
local joint_min, joint_max = nil, nil
-- hook z minus body (or bones) z while the hook is drawn: must stay > 0
local hook_dz_min, hook_dz_max = nil, nil
-- The chain must never JUMP.  Sideways it should not move at all during the
-- drop; vertically no frame may move it further than one drop/rise step.  A
-- branch change (human body -> acid state -> skeleton) that disagrees with the
-- one before it shows up here as a one-frame hop.
local chainx_lo, chainx_hi, chain_prev_y, chain_dy_max, chain_dy_at = nil, nil, nil, 0, nil
local drip_cols = {}
local chain_overhang_max = nil
local drip_spots, drip_y_lo, drip_y_hi = {}, nil, nil
-- Where each drip LANDS: its lowest anchor before its object goes away.  Every
-- one has to end on the ripple line (+-2) - it falls INTO the pool.
local drip_live, drip_lands = {}, {}
local drip_spawns = {}   -- "f<ticks into the rise>:x<off his anchor>,y<top>" per lift drip
local drip_spawn_min_y = nil   -- highest (smallest y) any lift drip started at
-- Bubbles in LOCKSTEP: on every tick where bubbles change frame, how many
-- changed together.  Six lanes on one hold change six at a time; out of step
-- they change one or two at a time.
local bub_prev, bub_change_ticks, bub_changes, bub_group_max = {}, 0, 0, 0
local bub_x_sum, bub_x_n = 0, 0
-- How fast each bubble animates: ticks between its frame changes, per object
-- life.  A 4-frame bubble at 3-5 ticks a frame is a flicker, not a bubble.
local bub_live, bub_rates = {}, {}
-- ACIDSMOKE (EDSMOKEACID.WAX): steam off the bones, and ONLY while they are
-- being pulled out.  Its x rides with him; its y is the pool's own rows, so
-- the plume stays on the acid instead of climbing into the air with him.
local smoke_before, smoke_during = 0, 0
local smoke_frames, smoke_xofs = {}, {}
local smoke_top_lo, smoke_top_hi = nil, nil
local rise_bubble_frames = 0     -- frames of the pull-out with a bubble on screen
-- DP_TAP=1: a write tap on the body's multipart piece RAM.  The only legal
-- writers are ani2 (restoring the shape) and hp_cut_shape_to_surface (a band
-- height of 1..20); anything else, or any height outside 1..20, is logged
-- with the CPU's PC so the culprit resolves with sym_resolve.py.
local TAP = os.getenv("DP_TAP") == "1"
local tap_handle, tap_lo, tap_hi = nil, nil, nil
local tap_pcs, tap_bad = {}, {}
-- The pool must be QUIET before he touches it and QUIET again once the bones
-- are out.  peak_fx alone could not see this: the EDACID lanes ran the whole
-- round, so every phase looked equally busy.
local fx_before, fx_during, fx_after = 0, 0, 0
local body_z_seen, fx_z_seen = nil, {}
local cut_heights, cut_pieces_min = {}, nil
local rise_heights, rise_pieces_max = {}, nil
local bani_min, bani_max = nil, nil
-- hanger_proc's whole life, watched from BEFORE the fight starts: it is
-- created in create_hangers (BGND.ASM, scene build), so if something sweeps
-- it during the round intro the fight never has a hang loop at all.
local bani_born, bani_died, bani_peak = 0, 0, 0
local bani_ptr, bani_fate = 0, nil
local where_seen = {}
local beat_first, beat_last = nil, nil
local checks = {}
local function check(name, ok, detail, skipped)
    checks[#checks + 1] = { name = name, ok = ok, detail = detail, skipped = skipped }
end

local function near(actual, expect, slack)
    if expect <= 0 then return actual <= 4 end
    local lo = math.floor(expect * (1 - (slack or TOLERANCE)))
    local hi = math.ceil(expect * (1 + (slack or TOLERANCE))) + 4
    return actual >= lo and actual <= hi
end

local function beat_line(tag, c)
    local b = c.first["body"] or c.first["skel"]
    return string.format(
        "%s frame=%d clk=%d busy=%d dropped=%d where=%s beat=%d bani=%d strips=%s skelvis=%s art=%s y=%s x=%s wtlx=%d bz=%s fx=b%d/d%d/r%d/s%d chain=%s",
        tag, frame, round_clock(), drop_busy(), dropped0(),
        where_name(dbg_where()), dbg_beat(), (proc_count(PID_BANI)),
        tostring(strips0()), tostring(skel_vis0()),
        b and b.label or "none", b and tostring(b.y) or "na", b and tostring(b.x) or "na",
        camera_left(),
        (function()
            local o = body_ptr()
            return o ~= 0 and tostring(s16(r16(o + O.ozpos))) or "na"
        end)(),
        c.count["bubble"] or 0, c.count["drip"] or 0, c.count["ripple"] or 0,
        c.count["splash"] or 0,
        c.first["chain"] and string.format("%s@%d/%d%s", c.first["chain"].label,
            c.first["chain"].x, c.first["chain"].y,
            c.first["chain"].inviso and "(hid)" or "") or "none")
end

--------------------------------------------------------------------------
-- verdict
--------------------------------------------------------------------------

local function finish(reason)
    if finished then return end
    finished = true
    snap("final")

    -- 1. the stage actually built the hangers
    check("hangers_spawned", hang_y ~= nil,
        string.format("body_ptr=%s hang_y=%s hang_x=%s want y=%d x=%d",
            tostring(body_ptr()), tostring(hang_y), tostring(hang_x), ED_Y, ED_X))
    if hang_y ~= nil then
        -- x within the IDLE swing (hp_idle_sway_a0, +-1 every 6..17s)
        check("hang_position", hang_y == ED_Y and math.abs(hang_x - ED_X) <= 2,
            string.format("y=%d/%d x=%d/%d (swing +-2)", hang_y, ED_Y, hang_x, ED_X))
    end

    check("hang_loop_running",
        beat_first ~= nil and beat_last ~= nil and beat_last ~= beat_first,
        string.format("hp_dbg_beat %s->%s; last checkpoint %s; pid_bani in-fight %s..%s",
            tostring(beat_first), tostring(beat_last), where_name(dbg_where()),
            tostring(bani_min), tostring(bani_max)))
    -- in DP_NEXT_ROUND mode the round-1 procs are torn down with the round
    -- once the drop is done, and round 2 spawns its own - not a death
    check("hanger_proc_survives", bani_peak > 0
            and (bani_died == 0 or (HT.next_round and T.done ~= 0 and bani_died > T.done)),
        bani_born == 0 and "pid_bani never appeared at all - create_hangers did not create it"
            or (bani_died ~= 0
                and string.format("born frame %d, GONE at frame %d (%d ticks later)",
                    bani_born, bani_died, bani_died - bani_born)
                or string.format("born frame %d, still alive", bani_born)))

    -- A drop nobody can see is not a drop.  Ed hung 104px off the left edge
    -- for this rig's whole life before anyone measured the camera.
    if cam_lo ~= nil then
        -- his WHOLE body, at some camera position: the left edge alone passed
        -- with him 6px from the right border and nothing of him visible
        check("body_on_screen",
            ED_X >= cam_lo and ED_X + 40 <= cam_hi + SCRW,
            string.format("ed_x=%d, camera showed world x %d..%d (centre %d..%d)",
                ED_X, cam_lo, cam_hi + SCRW, cam_lo + SCRW // 2, cam_hi + SCRW // 2))
    end
    do
        local bz = body_z_seen
        local front = false
        for z in pairs(fx_z_seen["bubble"] or {}) do
            if bz and z > bz then front = true end
        end
        check("bubbles_in_front_of_body", front,
            string.format("body_z=%s, bubbles seen on z %s - one has to be IN FRONT "
                .. "or it cannot hide the cut edge", tostring(bz),
                (function()
                    local l = {}
                    for z in pairs(fx_z_seen["bubble"] or {}) do l[#l + 1] = z end
                    table.sort(l); return table.concat(l, "/")
                end)()))
    end
    check("chain_follows_him",
        chain_gap_min ~= nil and (chain_gap_max - chain_gap_min) <= 2,
        string.format("chain bottom minus body top stayed within %s..%s across the "
            .. "whole drop - it goes in and comes back out with him",
            tostring(chain_gap_min), tostring(chain_gap_max)))
    do
        local n, lo, hi = 0, nil, nil
        for x in pairs(drip_cols) do
            n = n + 1
            if lo == nil or x < lo then lo = x end
            if hi == nil or x > hi then hi = x end
        end
        local spots = 0
        for _ in pairs(drip_spots) do spots = spots + 1 end
        check("lift_drips_are_spread", n >= 4,
            string.format("drips came off %d columns (x %s..%s), %d distinct x,y "
                .. "spots - one column reads as a leak, not a body sheeting",
                n, tostring(lo), tostring(hi), spots))
    end
    do
        -- x varies, y does NOT: every drip ends in the pool on the ripple line,
        -- jittered 1-2px so the splashes do not stack into a single row
        local want = K.acid_ripple_y + K.acid_drip_yofs
        local lo, hi, ys = nil, nil, {}
        for _, y in ipairs(drip_lands) do
            if lo == nil or y < lo then lo = y end
            if hi == nil or y > hi then hi = y end
            ys[y] = (ys[y] or 0) + 1
        end
        local l = {}
        for y, k in pairs(ys) do l[#l + 1] = string.format("%dx%d", y, k) end
        table.sort(l)
        check("drips_land_in_the_pool",
            #drip_lands >= 4 and lo >= want - 2 and hi <= want + 2 and hi > lo,
            string.format("%d drips landed on y %s..%s (%s), want %d +-2 with some "
                .. "jitter - a drip that ends off the ripple line never reaches the "
                .. "pool", #drip_lands, tostring(lo), tostring(hi),
                table.concat(l, " "), want))
    end
    do
        local mean = bub_change_ticks > 0 and bub_changes / bub_change_ticks or 0
        check("bubbles_out_of_step",
            bub_change_ticks >= 10 and mean <= 2.0,
            string.format("%d bubble frame changes over %d ticks: %.2f per tick "
                .. "on average, at most %d at once - lockstep lanes change all "
                .. "together, each on its own hold changes one or two at a time",
                bub_changes, bub_change_ticks, mean, bub_group_max))
        if TAP then
            local l = {}
            for pc, n in pairs(tap_pcs) do l[#l + 1] = pc .. "x" .. n end
            table.sort(l)
            log("MEASURE tap writers %s", #l > 0 and table.concat(l, " ") or "none")
            for _, b in ipairs(tap_bad) do log("MEASURE tap BAD %s", b) end
        end
        log("MEASURE lift_drip_spawns %s", table.concat(drip_spawns, " "))
        -- Nearly home, a fresh drip starts up by his shoulders (world ~47) and
        -- falls the whole screen - it read as coming off him from nowhere.
        -- lift_drip_stop_band keeps the last 8px of the pull drip-free.
        -- relative to HIS top: the bodies hang at different heights now (60
        -- was Ed's 46 + 14)
        check("no_late_drip_up_by_the_hook", drip_spawn_min_y ~= nil and drip_spawn_min_y >= ED_Y + 14,
            string.format("the highest lift drip started at world y %s - one that starts "
                .. "up by the hook (was 47, the last drip of the rise) falls the whole "
                .. "screen and looks detached", tostring(drip_spawn_min_y)))
        log("MEASURE bubble_centre_x mean=%.1f over %d bubble-frames",
            bub_x_n > 0 and bub_x_sum / bub_x_n or 0, bub_x_n)
    end
    do
        local all = {}
        for _, r in ipairs(bub_rates) do all[#all + 1] = r end
        for _, r in pairs(bub_live) do if r.n >= 2 then all[#all + 1] = r end end
        table.sort(all, function(a, b) return a.sum / a.n < b.sum / b.n end)
        -- The SINKING bubbles (acid_lower_fx_z, in front of him) are the ones
        -- spawned per step and the one that read as "animating in place, way
        -- too fast".  The EDACID lanes are listed for reference: their pops
        -- run at the authored 12 fps, and a lane that steps off BUBL art is
        -- banked as a short life of pops only, so their numbers read low.
        local sink, lanes = {}, {}
        for _, r in ipairs(all) do
            if r.z == K.acid_lower_fx_z then sink[#sink + 1] = r else lanes[#lanes + 1] = r end
        end
        local function top(list)
            local l = {}
            for i = 1, math.min(6, #list) do
                l[#l + 1] = string.format("x%d:%.1f", list[i].x, list[i].sum / list[i].n)
            end
            return table.concat(l, " ")
        end
        log("MEASURE bubble_rates sinking %s (of %d) | lanes %s (of %d) - ticks/frame, fastest first",
            top(sink), #sink, top(lanes), #lanes)
        local worst = sink[1] and sink[1].sum / sink[1].n or nil
        check("sinking_bubbles_not_too_fast", #sink >= 4 and worst >= 6.0,
            string.format("%d sinking bubbles timed; the fastest averaged %.1f ticks a "
                .. "frame (at x %s) - they were 3-5, a four-frame pop in ~16 ticks, "
                .. "which read as one bubble flickering in place",
                #sink, worst or 0, sink[1] and tostring(sink[1].x) or "-"))
    end
    do
        -- ACIDSMOKE, placed by data/EDSMOKEACID.WAX: five frames, x riding with
        -- the bones (its art lands 73..95 left of his anchor) and y pinned to
        -- the pool (art tops world 156..192).  Anchored to HIS top instead it
        -- would start ~50px below the pool, on the walkway.
        local nf, nx, lo, hi = 0, 0, nil, nil
        for _ in pairs(smoke_frames) do nf = nf + 1 end
        for x in pairs(smoke_xofs) do
            nx = nx + 1
            if lo == nil or x < lo then lo = x end
            if hi == nil or x > hi then hi = x end
        end
        check("smoke_only_on_the_rise", smoke_before == 0 and smoke_during > 0,
            string.format("ACIDSMOKE drawn on %d frames before the bones existed and "
                .. "%d from there to the park - it is the steam off the acid as he "
                .. "comes out, not part of the hang", smoke_before, smoke_during))
        check("smoke_runs_its_lane", nf >= 4,
            string.format("%d of the 5 ACIDSMOKE frames were seen - a lane stuck on "
                .. "one frame is a still, not steam", nf))
        check("smoke_sits_on_the_pool",
            smoke_top_lo ~= nil and smoke_top_lo >= 140 and smoke_top_hi <= 200,
            string.format("its art top stayed in world y %s..%s; the WAX puts it at "
                .. "156..192 and acid_smoke_rise lifts it 10 to 146..182; the acid "
                .. "surface is %d - a plume that climbs with him leaves the pool behind",
                tostring(smoke_top_lo),
                tostring(smoke_top_hi), K.ed_acid_under_y))
        check("smoke_keeps_his_column", nx >= 3 and lo ~= nil and lo >= -25 and hi <= 25,
            string.format("%d distinct x offsets from his anchor, spanning %s..%s - "
                .. "each frame is CENTRED on his 50px column (art left -11..+8); the "
                .. "WAX's own offsets stood it 73..95px off to his left",
                nx, tostring(lo), tostring(hi)))
        -- ONE gout of steam as he breaks the surface, not a smoking pool: five
        -- frames at smoke_frame_ticks is ~20 ticks, and it used to loop the
        -- whole ~188-tick rise.
        check("smoke_plays_once", smoke_during >= 20 and smoke_during <= 45,
            string.format("ACIDSMOKE was on screen for %d frames; one pass of 5 "
                .. "frames at 6 ticks is ~30, looping the rise was ~196",
                smoke_during))
        -- the boil keeps working on him while he is pulled out
        check("bubbles_during_the_rise", rise_bubble_frames > 0,
            string.format("bubbles were on screen for %d frames of the pull-out - the "
                .. "acid is still boiling as he comes up through it",
                rise_bubble_frames))
    end
    -- x may move by the SWING (hp_sway_a0, +-3) - the chain hangs off him
    check("chain_never_jumps",
        chainx_lo ~= nil and chainx_hi - chainx_lo <= 6
            and chain_dy_max <= math.max(K.ed_drop_step, K.rise_step),
        string.format("chain x %s..%s, biggest one-frame y move %d px at frame %s "
            .. "(a step is %d) - it has to stop and start from the same place",
            tostring(chainx_lo), tostring(chainx_hi), chain_dy_max,
            tostring(chain_dy_at), math.max(K.ed_drop_step, K.rise_step)))
    do
        local jh, jc = HT.j.hook, HT.j.chain
        local ok = jh.lo ~= nil and jc.lo ~= nil
            and jh.lo >= HT.want_hook - 2 and jh.hi <= HT.want_hook + 2
            and jc.lo >= HT.want_chain - 2 and jc.hi <= HT.want_chain + 2
        check("hook_meets_chain", ok,
            string.format("TINCHAIN4->TINHOOK ran %s..%s (this body's WAX: %d), "
                .. "longchain->TINCHAIN4 ran %s..%s (%d) whenever drawn - more "
                .. "than 2 off the authored joint is a visible gap or overlap",
                tostring(jh.lo), tostring(jh.hi), HT.want_hook,
                tostring(jc.lo), tostring(jc.hi), HT.want_chain))
    end
    check("hook_behind_him",
        hook_dz_max ~= nil and hook_dz_max < 0,
        string.format("hook z minus body/bones z ran %s..%s while the hook was drawn - "
            .. "it has to stay < 0 all the way down and all the way back up: the hook "
            .. "is what he hangs FROM, and in front it sits on him",
            tostring(hook_dz_min), tostring(hook_dz_max)))
    check("chain_stops_at_the_surface",
        chain_overhang_max ~= nil and chain_overhang_max <= 0,
        string.format("chain's drawn bottom reached %s px past the acid surface "
            .. "(y %d) - anything over 0 is chain painted on top of the pool",
            tostring(chain_overhang_max), K.ed_acid_under_y))
    check("pool_is_quiet_until_he_touches_it", fx_during > fx_before,
        string.format("peak acid FX: %d before the trigger, %d while he goes in, "
            .. "%d once the bones are rising - it has to RISE when he arrives or "
            .. "there is nothing to see", fx_before, fx_during, fx_after))
    -- ALL of him over the acid, edge to edge (his width from his own pieces).
    -- This was a 30px margin on his left edge - the stage fatality's aim band,
    -- not a hanger's - and the six bodies outside the opening view now hang
    -- closer to the pool's ends than that.
    local bw = HT.body_w or 50
    check("body_over_the_acid",
        ED_X >= ACID_L and ED_X + bw <= ACID_R,
        string.format("x %d..%d (%dpx wide), acid %d..%d", ED_X, ED_X + bw, bw,
            ACID_L, ACID_R))

    -- 2. the schedule
    check("trigger_fired", T.trigger ~= 0,
        string.format("clk_at_trigger=%s frames_after_fight=%s",
            tostring(trigger_clock),
            T.trigger ~= 0 and (T.trigger - fighting_frame) or "never"))
    if T.trigger ~= 0 then
        -- he only lets go where he can be SEEN: all of him inside the camera
        -- (hanger_drop_view_left/right, MKHANG.ASM - 0..350 for a 50px body)
        local vl = K.hanger_drop_view_left or 0
        local vr = K.hanger_drop_view_right or 350
        -- a body on a hook is never quite still: hp_idle_sway_a0 leans him 1px,
        -- slowly (~4.7s) every 10..25s - so it needs 30s of hang to judge.  Needs a long enough hang to see one -
        -- the first body of a match drops ~2.3s in.
        check("idle_swing",
            (HT.idle_ticks or 0) >= 1650
                and (HT.idle_hi - HT.idle_lo >= 1 and HT.idle_hi - HT.idle_lo <= 4),
            string.format("hanging x ran %s..%s over %s ticks on the hook (want a "
                .. "lean of 1..4)", tostring(HT.idle_lo), tostring(HT.idle_hi),
                tostring(HT.idle_ticks)),
            (HT.idle_ticks or 0) < 1650)
        do
            local n, l = 0, {}
            for dx in pairs(HT.rest_dx or {}) do n = n + 1; l[#l + 1] = dx end
            local swayed = HT.rest_lo and HT.rest_hi and HT.rest_hi > HT.rest_lo
            check("chain_rides_the_sway", n == 1,
                string.format("back on his hook his bones ran x %s..%s and the chain sat "
                    .. "at %s px from them - one offset means it swings with him",
                    tostring(HT.rest_lo), tostring(HT.rest_hi), table.concat(l, "/")),
                n == 0 or not swayed)
        end
        check("starts_on_screen",
            HT.trig_screen_x and HT.trig_screen_x >= vl and HT.trig_screen_x <= vr,
            string.format("he let go at screen x %s, want %d..%d - nobody goes into "
                .. "the acid off screen", tostring(HT.trig_screen_x), vl, vr))
        -- at least 15s after the previous drop ended.  Only measurable with
        -- the waits running for real: -ClockJump cuts them to 2 ticks.
        local need = K.drop_pause_ticks or 821
        if not CLOCK_JUMP then
            check("next_drop_waits",
                HT.next_start == nil or (HT.next_start - T.done) >= (K.drop_pause_ticks or 821),
                HT.next_start == nil and "no other body went in within the pause + 400 ticks"
                    or string.format("the next body let go %d ticks after he was back on "
                        .. "his hook, want >= %d (15s)", HT.next_start - T.done,
                        K.drop_pause_ticks or 821),
                HT.next_start == nil)
        end
        check("pause_before_drop",
            HT.trig_since_done == nil or HT.trig_since_done >= need,
            HT.trig_since_done == nil and "no drop finished before his - nothing to pause after"
                or string.format("%d ticks after the previous body was back on his hook, "
                    .. "want >= %d (15s)", HT.trig_since_done, need),
            CLOCK_JUMP or HT.trig_since_done == nil)
    end
    check("dropped_latched", dropped0() == 1,
        string.format("hp_dropped[%d]=%d", HANG, dropped0()))

    -- 3. the fall
    if T.trigger ~= 0 then
        local fall_len = (T.submerge ~= 0 and T.submerge or frame) - T.trigger
        check("fall_reached_crossline", T.submerge ~= 0,
            string.format("y span %s..%s want %d..%d", tostring(fall_y_min),
                tostring(fall_y_max), ED_Y, K.acid_body_hide_y))
        check("fall_rate", near(fall_len, B.fall),
            string.format("%d ticks, budget %d (%dpx / %dpx per %d ticks)",
                fall_len, B.fall, K.acid_body_hide_y - ED_Y, K.ed_drop_step, K.drop_ticks))
        check("fall_monotonic", fall_regress == 0,
            string.format("%d frames went back up", fall_regress))
        -- he SWINGS on the way down (hp_sway_a0, +-3 dry, half in the acid) -
        -- so his x has to move, stay within the swing, and he goes under on
        -- his own column (the splash, bubbles and bones are all built on it)
        local lo, hi = fall_x_min or ED_X, fall_x_max or ED_X
        check("fall_swings", hi - lo >= 2 and lo >= ED_X - 3 and hi <= ED_X + 3
                and (HT.sub_x == nil or HT.sub_x == ED_X),
            string.format("x ran %s..%s on the way down (his column %d, swing +-3); "
                .. "under at x %s", tostring(fall_x_min), tostring(fall_x_max), ED_X,
                tostring(HT.sub_x)))
        -- Row-exact clip: the bottom band's height should take MANY distinct
        -- values as the acid eats it, not just its full height.  Band-at-a-time
        -- cutting shows exactly one.
        do
            local distinct, lo, hi = 0, nil, nil
            for h in pairs(cut_heights) do
                distinct = distinct + 1
                if lo == nil or h < lo then lo = h end
                if hi == nil or h > hi then hi = h end
            end
            check("cut_is_row_exact", distinct >= 8,
                string.format("bottom band drew %d distinct heights (%s..%s rows); "
                    .. "band-at-a-time would be 1", distinct, tostring(lo), tostring(hi)))
            -- ...and never STALLS on one.  Distinct-count passed while band F
            -- (the shoes) sat at its full 12 rows for 56 frames, 12px under the
            -- surface: his feet went through the acid uncut, then popped.
            local most, at = 0, nil
            for h, n in pairs(cut_heights) do if n > most then most, at = n, h end end
            check("cut_never_stalls", most <= 20,
                string.format("no cut height held longer than %d frames (the %s-row "
                    .. "one); one step of the sink holds a height ~8", most, tostring(at)))
        end
        -- The bones come OUT of the acid the same way the body went in: the
        -- reveal used to walk a six-shape table and arrive in lumps.
        do
            local distinct, lo, hi = 0, nil, nil
            for h in pairs(rise_heights) do
                distinct = distinct + 1
                if lo == nil or h < lo then lo = h end
                if hi == nil or h > hi then hi = h end
            end
            check("rise_is_row_exact", distinct >= 8,
                string.format("top band drew %d distinct heights (%s..%s rows), "
                    .. "max %s bands out; table-driven would be 1",
                    distinct, tostring(lo), tostring(hi), tostring(rise_pieces_max)))
            local most, at = 0, nil
            for h, n in pairs(rise_heights) do if n > most then most, at = n, h end end
            check("rise_never_stalls", most <= 20,
                string.format("no reveal height held longer than %d frames (the %s-row "
                    .. "one) - a band held at full height is a band that pops", most,
                    tostring(at)))
        end
        if strips_start then
            check("strips_cut_progressively", strips_min ~= nil and strips_min < strips_start,
                string.format("hp_lower_strips %d -> %s", strips_start, tostring(strips_min)))
        else
            check("strips_cut_progressively", false,
                "hp_lower_strips is not .global - add it to MKHANG's .global list", true)
        end
    end

    -- 4. splash / simmer handoff
    check("splash_played", T.splash ~= 0,
        T.splash ~= 0 and string.format("%d ticks after submerge", T.splash - T.submerge)
            or "no acidsplash object ever appeared")
    if K.hanger_fx_enable ~= 0 then
        check("prerise_bubbles", peak_bubbles > (base_bubbles or 0),
            string.format("peak bubbles=%d over stage ambient %s",
                peak_bubbles, tostring(base_bubbles)))
    else
        check("prerise_bubbles", true,
            string.format("hanger_fx_enable=0 in this build; peak %d vs stage ambient %s",
                peak_bubbles, tostring(base_bubbles)), true)
    end

    -- 5. the skeleton
    check("skeleton_spawned", T.skel ~= 0,
        T.skel ~= 0 and string.format("hp_skel_visible=1 (bones inserted) at frame %d", T.skel)
            or string.format("bones never inserted; hp_skel_visible=%s", tostring(skel_vis0())))
    if T.rise_start ~= 0 then
        local rise_len = (T.rise_done ~= 0 and T.rise_done or frame) - T.rise_start
        check("rise_reached_hook", T.rise_done ~= 0,
            string.format("y %s -> %s want %d -> %d", tostring(rise_y_start),
                tostring(rise_y_end), K.acid_rise_start, ED_Y))
        check("rise_rate", near(rise_len, B.rise),
            string.format("%d ticks, budget %d (%dpx / %dpx per %d ticks)",
                rise_len, B.rise, K.acid_rise_start - ED_Y, K.rise_step, K.rise_ticks))
        check("rise_monotonic", rise_regress == 0,
            string.format("%d frames went back down", rise_regress))
    else
        check("rise_reached_hook", false, "rise never started", false)
    end

    -- 6. the sequence handed control back
    check("busy_cleared", T.done ~= 0,
        T.done ~= 0 and string.format("hp_drop_busy cleared at frame %d", T.done)
            or string.format("hp_drop_busy still %d", drop_busy()))
    if park_y ~= nil and park_x ~= nil then
        check("skeleton_parked", park_y == ED_Y and math.abs(park_x - ED_X) <= 8,
            string.format("y=%d/%d x=%d/%d (+-8)", park_y, ED_Y, park_x, ED_X))
    end
    check("no_stall", stall_note == nil, stall_note or
        string.format("total %s ticks, budget %d",
            T.done ~= 0 and (T.done - T.trigger) or "n/a", B.total))

    local pass, fail, skip = 0, 0, 0
    for _, c in ipairs(checks) do
        local tag = c.skipped and "SKIP" or (c.ok and "PASS" or "FAIL")
        if c.skipped then skip = skip + 1 elseif c.ok then pass = pass + 1 else fail = fail + 1 end
        log("CHECK %-4s %-26s %s", tag, c.name, c.detail or "")
    end

    log("BEATS hang=%d trigger=%d submerge=%d splash=%d skel=%d rise=%d rise_done=%d done=%d",
        T.hang, T.trigger, T.submerge, T.splash, T.skel, T.rise_start, T.rise_done, T.done)
    log("BUDGET fall=%d splash=%d simmer=%d prerise=%d rise=%d total=%d",
        B.fall, B.splash, B.simmer, B.prerise, B.rise, B.total)
    for _, note in ipairs(chain_notes) do log("MEASURE %s", note) end
    log("MEASURE peak_fx bubbles=%d drips=%d ripples=%d (stage ambient baseline b%s/d%s/r%s)",
        peak_bubbles, peak_drips, peak_ripples,
        tostring(base_bubbles), tostring(base_drips), tostring(base_ripples))
    if SNAP_EVERY > 0 then
        log("MEASURE filmstrip %d frames, one every %d ticks", strip_shots, SNAP_EVERY)
    end
    log("MEASURE camera worldtlx %s..%s -> screen centre world x %s..%s "
        .. "(ed_x=%d, %s); acid band 195..947",
        tostring(cam_lo), tostring(cam_hi),
        cam_lo and (cam_lo + SCRW // 2) or "?", cam_hi and (cam_hi + SCRW // 2) or "?",
        ED_X,
        (cam_lo and cam_hi)
            and ((ED_X >= cam_lo and ED_X <= cam_hi + SCRW)
                 and "on screen at some camera position" or "NEVER on screen")
            or "?")
    log("MEASURE layers body_z=%s  %s", tostring(body_z_seen),
        (function()
            local t = {}
            for k, zs in pairs(fx_z_seen) do
                local l = {}
                for z in pairs(zs) do l[#l + 1] = z end
                table.sort(l)
                t[#t + 1] = k .. "_z=" .. table.concat(l, "/")
            end
            table.sort(t); return table.concat(t, " ")
        end)())
    log("MEASURE row_clip_rise %s", (function()
        local t = {}
        for h, n in pairs(rise_heights) do t[#t + 1] = { h, n } end
        table.sort(t, function(a, b) return a[1] < b[1] end)
        local parts = {}
        for _, e in ipairs(t) do parts[#parts + 1] = e[1] .. "x" .. e[2] end
        return "top-band heights " .. table.concat(parts, " ")
            .. "  max_pieces=" .. tostring(rise_pieces_max)
    end)())
    log("MEASURE row_clip %s", (function()
        local t = {}
        for h, n in pairs(cut_heights) do t[#t + 1] = { h, n } end
        table.sort(t, function(a, b) return a[1] < b[1] end)
        local parts = {}
        for _, e in ipairs(t) do parts[#parts + 1] = e[1] .. "x" .. e[2] end
        return "bottom-band heights " .. table.concat(parts, " ")
            .. "  min_pieces=" .. tostring(cut_pieces_min)
    end)())
    log("MEASURE procs pid_bani %s..%s pid_green_splash=%d",
        tostring(bani_min), tostring(bani_max), (proc_count(PID_SPLASH)))
    log("MEASURE hang_loop hp_dbg_beat %s->%s (%s ticks of loop), checkpoints: %s",
        tostring(beat_first), tostring(beat_last),
        (beat_first and beat_last) and tostring((beat_last - beat_first) & 0xffff) or "n/a",
        (function()
            local t = {}
            for v, n in pairs(where_seen) do t[#t + 1] = where_name(v) .. "x" .. n end
            table.sort(t); return table.concat(t, " ")
        end)())
    log("MEASURE art_seen %s", (function()
        local t = {}
        for k, v in pairs(seen_kind) do t[#t + 1] = k .. "=" .. v end
        table.sort(t); return table.concat(t, " ")
    end)())
    if #optional_absent > 0 then
        log("NOTE not .global (columns skipped): %s", table.concat(optional_absent, " "))
    end

    log("RESULT %s reason=%s pass=%d fail=%d skip=%d hanger=%d x=%d y=%d "
        .. "rows=%d crossline=%d clk_gate=%d",
        fail == 0 and "PASS" or "FAIL", reason, pass, fail, skip,
        HANG, ED_X, ED_Y, BODY_ROWS, CROSSLINE, K.ed_drop_at_clock)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

--------------------------------------------------------------------------
-- boot: force THE DEAD POOL and a 2-player idle match
--------------------------------------------------------------------------

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-18s MISSING", name); ok = false end
    end
    return ok
end

local function force_select()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_DEADPOOL)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    return false
end

--------------------------------------------------------------------------
-- the watch
--------------------------------------------------------------------------

local function observe()
    local w = dbg_where()
    where_seen[w] = (where_seen[w] or 0) + 1
    local bt = dbg_beat()
    if beat_first == nil then beat_first = bt end
    beat_last = bt
    local nb = proc_count(PID_BANI)
    if bani_min == nil or nb < bani_min then bani_min = nb end
    if bani_max == nil or nb > bani_max then bani_max = nb end
    local cl = camera_left()
    if cam_lo == nil or cl < cam_lo then cam_lo = cl end
    if cam_hi == nil or cl > cam_hi then cam_hi = cl end

    local c = census()
    do
        -- The chain has to travel WITH him: its bottom is his top, wherever he
        -- is.  Pinned at the waterline this gap ran away as he sank.
        if T.rise_start ~= 0 then
            local now = {}
            for _, d in ipairs(c.spots["drip"] or {}) do
              -- the boil's own EDACID drip lanes (oid pid_edpool_fx) keep their
              -- authored rows and run through the rise now; only the lift
              -- drips off the bones are held to the landing line
              if d.oid ~= PID_EDPOOL_FX then
                drip_cols[d.x] = (drip_cols[d.x] or 0) + 1
                drip_spots[d.x .. "," .. d.y] = true
                if drip_y_lo == nil or d.y < drip_y_lo then drip_y_lo = d.y end
                if drip_y_hi == nil or d.y > drip_y_hi then drip_y_hi = d.y end
                now[d.obj] = true
                if drip_live[d.obj] == nil and (drip_spawn_min_y == nil or d.y < drip_spawn_min_y) then
                    drip_spawn_min_y = d.y
                end
                if drip_live[d.obj] == nil and #drip_spawns < 60 then
                    local bo = body_ptr()
                    drip_spawns[#drip_spawns + 1] = string.format("f%d:x%+d,y%d",
                        frame - (T.rise_start or 0),
                        d.x - (bo ~= 0 and r16(bo + O.oxpos) or 0), d.y)
                end
                local lv = drip_live[d.obj]
                if lv and d.ay < lv then            -- a new drip in a reused block
                    drip_lands[#drip_lands + 1] = lv
                    lv = nil
                end
                drip_live[d.obj] = math.max(lv or d.ay, d.ay)
              end
            end
            for o, ay in pairs(drip_live) do       -- gone: that was its landing
                if not now[o] then
                    drip_lands[#drip_lands + 1] = ay
                    drip_live[o] = nil
                end
            end
        end
        if T.trigger ~= 0 and T.done == 0 then
            if T.rise_start ~= 0 and frame == T.rise_start + 20 then
                local l = {}
                for _, u in ipairs(c.unknown) do
                    l[#l + 1] = string.format("sag=%08x oid=%03x at %d,%d%s",
                        u.sag, u.oid, u.x, u.y, u.named and (" ("..u.named..")") or "")
                end
                log("MEASURE unnamed_on_the_rise %s", #l > 0 and table.concat(l, " | ") or "none")
            end
            -- ACIDSMOKE: only while the bones are on their way out, x riding
            -- with him, y held on the pool's rows
            if T.rise_start ~= 0 and T.rise_done == 0 and (c.count["bubble"] or 0) > 0 then
                rise_bubble_frames = rise_bubble_frames + 1
            end
            local ob0 = body_ptr()
            for _, sm in ipairs(c.spots["smoke"] or {}) do
                -- Boundary is hp_skel_visible, not a beat: the parent sets it
                -- (2 = bones built, not yet inserted) and creates the smoke in
                -- the same breath, while T.skel marks when the bones became
                -- VISIBLE - a tick or four later.
                if (skel_vis0() or 0) == 0 then
                    smoke_before = smoke_before + 1
                else
                    smoke_during = smoke_during + 1
                    smoke_frames[sm.sag] = (smoke_frames[sm.sag] or 0) + 1
                    if ob0 ~= 0 then
                        smoke_xofs[sm.x - r16(ob0 + O.oxpos)] = true
                    end
                    if smoke_top_lo == nil or sm.y < smoke_top_lo then smoke_top_lo = sm.y end
                    if smoke_top_hi == nil or sm.y > smoke_top_hi then smoke_top_hi = sm.y end
                end
            end
            local now, changed = {}, 0
            for _, b in ipairs(c.spots["bubble"] or {}) do
                now[b.obj] = b.sag
                if not bub_live[b.obj] then bub_live[b.obj] = { n = 0, sum = 0, x = b.x, z = b.z } end
                if bub_prev[b.obj] and bub_prev[b.obj] ~= b.sag then
                    changed = changed + 1
                    local r = bub_live[b.obj]
                    if r.last then r.n = r.n + 1; r.sum = r.sum + (frame - r.last) end
                    r.last = frame
                end
                bub_x_sum = bub_x_sum + b.x + (b.w or 0) // 2
                bub_x_n = bub_x_n + 1
            end
            bub_prev = now
            for o, r in pairs(bub_live) do          -- gone: bank its rate
                if not now[o] then
                    if r.n >= 2 then bub_rates[#bub_rates + 1] = r end
                    bub_live[o] = nil
                end
            end
            if changed > 0 then
                bub_change_ticks = bub_change_ticks + 1
                bub_changes = bub_changes + changed
                if changed > bub_group_max then bub_group_max = changed end
            end
        end
        local chj = c.first["chain"]
        if chj and T.trigger ~= 0 and T.done == 0 then
            if chainx_lo == nil or chj.x < chainx_lo then chainx_lo = chj.x end
            if chainx_hi == nil or chj.x > chainx_hi then chainx_hi = chj.x end
            if chain_prev_y then
                local dy = math.abs(chj.y - chain_prev_y)
                if dy > chain_dy_max then chain_dy_max = dy; chain_dy_at = frame end
            end
            chain_prev_y = chj.y
        end
        local hk = c.first["hook"]
        local cn0 = c.first["connector"]
        local ch0 = c.first["chain"]
        -- both joints of the WAX stack: longchain -> TINCHAIN4 -> TINHOOK
        if ch0 and cn0 and hk and hk.y > -200 and not hk.inviso and not cn0.inviso then
            for name, joint in pairs({ hook = hk.y - (cn0.y + (cn0.h or 0)),
                                       chain = cn0.y - (ch0.y + (ch0.h or 0)) }) do
                if joint_min == nil or joint < joint_min then joint_min = joint end
                if joint_max == nil or joint > joint_max then joint_max = joint end
                local j = HT.j[name]
                if j.lo == nil or joint < j.lo then j.lo = joint end
                if j.hi == nil or joint > j.hi then j.hi = joint end
            end
        end
        -- TINHOOK is IN FRONT of him (WAX slot order 1 over EDHANG1's 0), on
        -- the bones as well as the body.  Behind, its curl vanished into his
        -- collar and only a 1px shank showed - a chain stopping short of him.
        local ob = body_ptr()
        if hk and ob ~= 0 and hk.y > -200 and not hk.inviso and T.trigger ~= 0 then
            local dz = s16(r16(hk.obj + O.ozpos)) - s16(r16(ob + O.ozpos))
            if hook_dz_min == nil or dz < hook_dz_min then hook_dz_min = dz end
            if hook_dz_max == nil or dz > hook_dz_max then hook_dz_max = dz end
            if dz >= 0 and not HT.dz_logged then
                HT.dz_logged = true
                log("HOOK IN FRONT frame=%d dz=%d hook x=%d y=%d z=%d  body x=%d y=%d z=%d  busy=%d skelvis=%s",
                    frame, dz, hk.x, hk.y, s16(r16(hk.obj + O.ozpos)), r16(ob + O.oxpos),
                    s16(r16(ob + O.oypos)), s16(r16(ob + O.ozpos)), drop_busy(), tostring(skel_vis0()))
            end
        end
        local ch, o = c.first["chain"], body_ptr()
        if ch and T.trigger ~= 0 then
            -- how far the chain's DRAWN bottom reaches past the acid surface
            local drawn = r16(ch.obj + O_SIZEY)
            local over = (ch.y + drawn) - K.ed_acid_under_y
            if chain_overhang_max == nil or over > chain_overhang_max then
                chain_overhang_max = over
            end
        end
        if ch and o ~= 0 and T.trigger ~= 0 then
            local gap = (ch.y + (ch.h or 0)) - s16(r16(o + O.oypos))
            if chain_gap_min == nil or gap < chain_gap_min then chain_gap_min = gap end
            if chain_gap_max == nil or gap > chain_gap_max then chain_gap_max = gap end
        end
    end
    do
        local o = body_ptr()
        if o ~= 0 and body_z_seen == nil then body_z_seen = s16(r16(o + O.ozpos)) end
        -- every z a kind is seen on, not just the first: the ambient boil and
        -- the lowering bubbles are the same art on different layers.
        for kind, zs in pairs(c.zs) do
            fx_z_seen[kind] = fx_z_seen[kind] or {}
            for z, n in pairs(zs) do
                fx_z_seen[kind][z] = (fx_z_seen[kind][z] or 0) + n
            end
        end
    end
    for kind, n in pairs(c.count) do
        if n > (seen_kind[kind] or 0) then seen_kind[kind] = n end
    end
    do
        local busy = (c.count["bubble"] or 0) + (c.count["drip"] or 0)
            + (c.count["ripple"] or 0)
        -- "before" is HIS column at rest, not a NEIGHBOUR's drop: the
        -- bodies hang as close as 37px apart (the user's layout), so another
        -- body's boil lands in his window while it goes in ahead of him
        if T.trigger == 0 then
            if drop_busy() == 0 and busy > fx_before then fx_before = busy end
        elseif T.rise_start == 0 then
            if busy > fx_during then fx_during = busy end
        else
            if busy > fx_after then fx_after = busy end
        end
    end
    peak_bubbles = math.max(peak_bubbles, c.count["bubble"] or 0)
    peak_drips = math.max(peak_drips, c.count["drip"] or 0)
    peak_ripples = math.max(peak_ripples, c.count["ripple"] or 0)

    local ptr = body_ptr()
    local body = ptr ~= 0 and { y = s16(r16(ptr + O.oypos)), x = r16(ptr + O.oxpos) } or nil
    local busy = drop_busy()

    -- HANG: the first tick hanger 0 exists and is still on its hook
    if T.hang == 0 and body and busy == 0 and dropped0() == 0 then
        T.hang = frame
        hang_y, hang_x = body.y, body.x
        -- THE DEAD POOL boils on its own; the drop's FX only count above this.
        base_bubbles = c.count["bubble"] or 0
        base_drips = c.count["drip"] or 0
        base_ripples = c.count["ripple"] or 0
        log("%s", beat_line("BEAT hang", c))
        log("MEASURE procs_at_hang %s", proc_histogram())
        -- palette slots: 80 exist (numpal).  An object whose palette cannot be
        -- allocated falls back to colour map 0 - wrong colours AND immune to
        -- the fatality fade, because map 0's palette is excluded from it.
        if A.palram then
            local used, ids = 0, {}
            for i = 0, 79 do
                local rec = A.palram + i * 0x40
                if r16(rec + 0x20) ~= 0 then
                    used = used + 1
                    ids[#ids + 1] = string.format("%08x", r32(rec))
                end
            end
            local o = body_ptr()
            log("MEASURE palettes used=%d/80 body_opal=%s", used,
                o ~= 0 and string.format("%04x", r16(o + 0x140)) or "-")
        end
        snap("hang")
    end

    -- Slow down from the hang beat (the trigger is ~2s later on the natural
    -- clock, which is itself worth seeing) and speed back up once it is parked.
    if T.hang ~= 0 and T.done == 0 then set_watch(true) else set_watch(false) end

    -- TRIGGER: hp_drop_busy 0 -> 1 WITH hp_dropped[HANG] latched.  Two bodies
    -- are scheduled now, and busy alone fired on Ed's drop while the rig was
    -- watching Tony.
    if T.trigger == 0 and busy ~= 0 and dropped0() == 1 then
        T.trigger = frame
        if TAP and not tap_handle then
            local bo = body_ptr()
            local mp = bo ~= 0 and r32(bo + O.oimg) or 0
            if mp ~= 0 then
                tap_lo, tap_hi = mp, mp + 6 * MP.length - 1
                local ok, err = pcall(function()
                    tap_handle = space:install_write_tap(tap_lo, tap_hi, "hang_mpart",
                        function(offset, data, mask)
                            local pc = cpu.state["PC"].value
                            local key = string.format("%08x", pc)
                            tap_pcs[key] = (tap_pcs[key] or 0) + 1
                            local rel = offset - tap_lo
                            if rel % MP.length == MP.sizey and (data == 0 or data > 20)
                                and #tap_bad < 40 then
                                tap_bad[#tap_bad + 1] = string.format(
                                    "f%d pc=%08x piece%d sizey=%d", frame, pc,
                                    rel // MP.length, data)
                            end
                            return data
                        end)
                end)
                log("MEASURE tap install %s over %08x..%08x %s", ok and "ok" or "FAILED",
                    tap_lo, tap_hi, ok and "" or tostring(err))
            end
        end
        trigger_clock = round_clock()
        -- where the camera had him when he let go, and how long since the
        -- previous body (anybody's) was back up on his hook
        HT.trig_screen_x = ED_X - camera_left()
        HT.trig_since_done = HT.last_done and (frame - HT.last_done) or nil
        -- hp_drop_begin sets the full band count as it enters the fall; before
        -- that hp_lower_strips is still 0, so the baseline belongs HERE.
        strips_start = strips0()
        fall_y_min = body and body.y or nil
        fall_y_max = fall_y_min
        fall_x_min = body and body.x or nil
        fall_x_max = fall_x_min
        last_body_y = fall_y_min
        log("%s", beat_line("BEAT trigger", c))
        snap("trigger")
    end

    -- FALL: watch oypos walk down to acid_body_hide_y
    if T.trigger ~= 0 and T.submerge == 0 and body then
        if fall_y_min == nil or body.y < fall_y_min then fall_y_min = body.y end
        if fall_y_max == nil or body.y > fall_y_max then fall_y_max = body.y end
        if fall_x_min == nil or body.x < fall_x_min then fall_x_min = body.x end
        if fall_x_max == nil or body.x > fall_x_max then fall_x_max = body.x end
        if last_body_y and body.y < last_body_y then fall_regress = fall_regress + 1 end
        last_body_y = body.y
        local s = strips0()
        if s and (strips_min == nil or s < strips_min) then strips_min = s end
        local np, h = mpart_tail()
        -- only once his feet are below the surface: above it every band is
        -- legitimately full height, and that is 40 frames of a "held" height
        if h ~= nil and np > 0 and body.y > CROSSLINE then
            cut_heights[h] = (cut_heights[h] or 0) + 1
            if cut_pieces_min == nil or np < cut_pieces_min then cut_pieces_min = np end
        end
        if body.y >= K.acid_body_hide_y then
            T.submerge = frame
            sink_y = body.y          -- the skeleton starts from exactly here
            HT.sub_x = body.x         -- back on his column when he goes under
            last_body_y = nil
            log("%s", beat_line("BEAT submerge", c))
            snap("submerge")
        end
    end

    -- SPLASH: acidsplash art in the lists
    -- after HIS submerge: another body's drop earlier in the chain splashes too
    if T.splash == 0 and T.submerge ~= 0 and (c.count["splash"] or 0) > 0 then
        T.splash = frame
        log("%s", beat_line("BEAT splash", c))
        snap("splash")
    end

    -- SKELETON: hp_skel_visible[0] goes 2 (built, held out of the lists) -> 1
    -- (inserted).  A multipart object has no frame SAG in osag, so the census
    -- cannot see the bones; this flag is the only honest signal.
    if T.skel == 0 and (skel_vis0() == 1 or (c.count["skel"] or 0) > 0) then
        T.skel = frame
        rise_y_start = c.first["skel"] and c.first["skel"].y or (body and body.y)
        log("%s", beat_line("BEAT skeleton", c))
        snap("skeleton")
    end

    -- RISE: hp_body_ptr[0] is repointed at the skeleton the moment
    -- get_multi_obj builds it, which is well before hp_maybe_show_skel inserts
    -- it into the object lists (hp_skel_visible=2 holds it out until the bones
    -- clear acid_rise_stop).  So the rise is measured off the pointer, and
    -- T.skel stays a separate measurement of when the art became VISIBLE.
    if T.submerge ~= 0 and T.rise_done == 0 and body then
        if T.rise_start == 0 then
            -- Rising means moving UP from where he stopped.  Keying this off
            -- acid_rise_start fired during the simmer once the skeleton began
            -- at the body's real stop (190) instead of a fixed 192.
            if sink_y and body.y < sink_y and body.y > ED_Y then
                T.rise_start = frame
                rise_y_start = body.y
                last_body_y = body.y
                log("%s", beat_line("BEAT rise", c))
                snap("rise")
            end
        else
            if last_body_y and body.y > last_body_y then rise_regress = rise_regress + 1 end
            last_body_y = body.y
            rise_y_end = body.y
            local np, h = mpart_tail()
            -- only while the bones are still partly under (see the cut above)
            if h ~= nil and np > 0 and body.y > CROSSLINE then
                rise_heights[h] = (rise_heights[h] or 0) + 1
                if rise_pieces_max == nil or np > rise_pieces_max then
                    rise_pieces_max = np
                end
            end
            if body.y <= ED_Y then
                T.rise_done = frame
                log("%s", beat_line("BEAT rise_done", c))
                snap("rise_done")
            end
        end
    end

    -- the IDLE swing: his x while he is still on his hook
    if T.hang ~= 0 and T.trigger == 0 and body then
        if HT.idle_lo == nil or body.x < HT.idle_lo then HT.idle_lo = body.x end
        if HT.idle_hi == nil or body.x > HT.idle_hi then HT.idle_hi = body.x end
        HT.idle_ticks = (HT.idle_ticks or 0) + 1
    end

    -- AT REST AFTER HIS DROP: his bones sway on the hook, and the chain has to
    -- go with them - it used to be pinned to the drop point, so the bones
    -- swayed beside a chain that stood still
    if T.done ~= 0 and body and r16(A.gstate) == GS_FIGHTING then
        local ch = c.first["chain"]
        if ch then
            local dx = ch.x - body.x
            HT.rest_dx = HT.rest_dx or {}
            HT.rest_dx[dx] = true
            if HT.rest_lo == nil or body.x < HT.rest_lo then HT.rest_lo = body.x end
            if HT.rest_hi == nil or body.x > HT.rest_hi then HT.rest_hi = body.x end
        end
    end

    -- ANY body's drop finishing (for pause_before_drop), and the next one
    -- STARTING after his is done (for next_drop_waits)
    if HT.prev_busy and HT.prev_busy ~= 0 and busy == 0 then HT.last_done = frame end
    if HT.prev_busy == 0 and busy ~= 0 and T.done ~= 0 and not HT.next_start then
        HT.next_start = frame
        log("NEXT drop started %d ticks after his ended", frame - T.done)
    end
    HT.prev_busy = busy

    -- DONE: hp_drop_busy back to 0 after having been 1
    if T.trigger ~= 0 and T.done == 0 and busy == 0 then
        T.done = frame
        park_y = body and body.y or nil
        park_x = body and body.x or nil
        log("%s", beat_line("BEAT done", c))
        snap("done")
    end

    -- Chain geometry, sampled at the beats that matter.  This is the open
    -- visual question in doc/DEADPOOL_HANGER_HANDOFF.md: does the chain stay
    -- connected to the body/skeleton through the pull-up?
    local function chain_gap(tag)
        local ch, cn, hk = c.first["chain"], c.first["connector"], c.first["hook"]
        local b = c.first["body"] or c.first["skel"]
        local wtly = s16(r16(A.worldtly + 16))
        local bo = body_ptr()
        local parts = { tag, string.format("wtly=%d body_y=%s", wtly,
            bo ~= 0 and tostring(s16(r16(bo + O.oypos))) or "na") }
        -- DRAWN extent, on screen, using the runtime height the clip wrote -
        -- the art height from the TBL is not what the DMA was told to blit.
        for _, e in ipairs({ { "chain", ch }, { "connector", cn }, { "hook", hk } }) do
            local name, o = e[1], e[2]
            if o then
                local drawn = r16(o.obj + O_SIZEY)
                parts[#parts + 1] = string.format(
                    "%s y=%d rows=%d screen=%d..%d%s", name, o.y, drawn,
                    o.y - wtly, o.y - wtly + drawn, o.inviso and "(hid)" or "")
            else
                parts[#parts + 1] = name .. "=absent"
            end
        end
        if ch and b then
            parts[#parts + 1] = string.format("chain_bottom=%d body_top=%d gap=%d",
                ch.y + (ch.h or 0), b.y, b.y - (ch.y + (ch.h or 0)))
        end
        chain_notes[#chain_notes + 1] = table.concat(parts, " ")
    end
    if T.hang == frame then chain_gap("chain_at_hang") end
    if T.submerge == frame then chain_gap("chain_at_submerge") end
    if T.rise_start == frame then chain_gap("chain_at_rise") end
    if T.done == frame then chain_gap("chain_at_done") end

    -- filmstrip: every SNAP_EVERY frames for the whole sequence
    if SNAP_EVERY > 0 and T.trigger ~= 0 and T.done == 0
        and (frame - T.trigger) % SNAP_EVERY == 0 then
        shutter()
        strip_shots = strip_shots + 1
    end

    if TRACE or (T.trigger ~= 0 and T.done == 0 and frame % 8 == 0) then
        log("%s", beat_line("trace", c))
    end

    -- stall detection: each beat gets its budget plus slack before we give up
    if T.trigger ~= 0 and T.done == 0 then
        local elapsed = frame - T.trigger
        local cap = math.ceil(B.total * 2) + 240
        if elapsed > cap then
            stall_note = string.format(
                "stalled %d ticks after trigger (cap %d); last beat reached: %s",
                elapsed, cap,
                T.rise_start ~= 0 and "rise" or T.skel ~= 0 and "skeleton"
                    or T.splash ~= 0 and "splash" or T.submerge ~= 0 and "submerge" or "fall")
            log("STALL %s", stall_note)
            finish("stalled")
            return
        end
    end

    -- one full sequence is the trial
    if T.done ~= 0 and frame > T.done + 60 then
        -- natural timing: stay on long enough to see the NEXT body wait out
        -- the pause (a body on screen goes as soon as it is up)
        if not CLOCK_JUMP and not HT.next_round and not HT.next_start
            and frame < T.done + (K.drop_pause_ticks or 821) + 400 then
            -- keep watching
        elseif not HT.next_round then
            finish("sequence_complete")
        elseif not HT.nr_wait then
            -- run the round out: unfreeze the timer and let it time out.  P2 is
            -- knocked down to half first - a timeout on EQUAL health is not a
            -- round loss for one side, it is game over for both (gstate 11,
            -- then attract), and there is no round 2 to look at.
            HT.nr_wait = true
            if A.f_freeze_timer then w16(A.f_freeze_timer, 0) end  -- let it run out
            if A.p2_bar then w16(A.p2_bar, 0x50) end
            log("NEXT_ROUND: drop done at frame %d, running round %d out",
                T.done, r16(A.round_num))
        end
    end

    -- ROUND 2: every body that went in is its skeleton, on its hook
    if HT.nr_wait and not HT.nr_at and r16(A.gstate) == GS_FIGHTING
        and r16(A.round_num) >= 2 then
        HT.nr_at = frame + 60
        log("NEXT_ROUND: round %d fighting at frame %d", r16(A.round_num), frame)
    end
    if HT.nr_at and frame >= HT.nr_at then
        local ok, notes = true, {}
        for i = 0, K.NHANGERS - 1 do
            local dropped = r16(A.hp_dropped + i * 16)
            local obj = r32(A.hp_body_ptr + i * 32)
            if obj ~= 0 and HT.x[i] then
                -- a multipart body names its art in its piece list, not osag
                local mp = r32(obj + O.oimg)
                local rec = mp ~= 0 and art_of(r32(mp + MP.sag)) or nil
                local kind = rec and classify(rec.label) or "?"
                local y = s16(r16(obj + O.oypos))
                notes[#notes + 1] = string.format("hanger %d dropped=%d %s(%s) y=%d",
                    i, dropped, kind, rec and rec.label or "?", y)
                -- dropped=1 latches when he lets go, so a body GOING IN right
                -- now (a round timed out in the pause and he went at once in
                -- this one) is a body below his hook, not a skeleton on it
                local going = dropped == 1 and kind == "body" and drop_busy() ~= 0
                    and y ~= HT.y[i]
                if going then notes[#notes] = notes[#notes] .. " (going in now)" end
                if dropped == 1 and not going and not (kind == "skel" and y == HT.y[i]) then ok = false end
                if i == HANG and dropped ~= 1 then ok = false end
            end
        end
        check("stays_in_the_acid", ok and #notes > 0,
            "round " .. r16(A.round_num) .. ": " .. table.concat(notes, "; ")
            .. " - a body that went in comes back as its skeleton on the hook, "
            .. "never whole again, for the rest of the match")
        finish("next_round_checked")
        return
    end
end

local ready_written = false
local function write_ready()
    if ready_written or not READY_PATH then return end
    local fh = io.open(READY_PATH, "w")
    if fh then fh:write(tostring(frame)); fh:close(); ready_written = true end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 30 then write_ready() end
    -- Every frame, because create_hangers reads it the tick the stage is
    -- built and that can be any round of any match.
    if space and A.hp_lineup_force then
        space:write_u16(A.hp_lineup_force, 1 << HANG)
    end
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if #missing > 0 then
            log("FATAL missing required symbols: %s", table.concat(missing, " "))
            finish("symbols_missing"); return
        end
        if not cache_fields() then finish("input_missing"); return end
        log("ed_hook x=%d y=%d  crossline=%d hide=%d rise_start=%d clk_gate=%d",
            ED_X, ED_Y, K.ed_crossline_y, K.acid_body_hide_y, K.acid_rise_start,
            K.ed_drop_at_clock)
        log("build gates: runtime=%d preview_only=%d fx=%d rise_ripple=%d rise_bubble=%d static=%d autodrop=%d",
            K.deadpool_hanger_runtime_enable, K.acid_bubble_preview_only,
            K.hanger_fx_enable, K.hanger_rise_ripple_enable,
            K.hanger_rise_bubble_enable, K.hanger_debug_static, K.hanger_match_autodrop)
        log("budgets: fall=%d splash=%d simmer=%d prerise=%d rise=%d total=%d ticks",
            B.fall, B.splash, B.simmer, B.prerise, B.rise, B.total)
        if K.deadpool_hanger_runtime_enable == 0 then
            log("WARN deadpool_hanger_runtime_enable=0 - this ROM has no hangers")
        end
        if K.acid_bubble_preview_only ~= 0 then
            log("WARN acid_bubble_preview_only=1 - the A/B bubble test runs, not the clock drop")
        end
        if K.hanger_debug_static ~= 0 then
            log("WARN hanger_debug_static=1 - bodies never drop in this ROM")
        end
    end
    if not space or finished then return end

    -- hanger_proc liveness is watched in EVERY game state, not just the
    -- fight, so "it was never created" and "it was created then swept" are
    -- different answers instead of one silent zero.
    do
        local nb = proc_count(PID_BANI)
        if nb > bani_peak then bani_peak = nb end
        if nb > 0 and bani_ptr == 0 then bani_ptr = proc_ptr(PID_BANI) end
        if nb > 0 and bani_born == 0 then
            bani_born = frame
            log("hanger_proc alive frame=%d count=%d gs=%d where=%s",
                frame, nb, r16(A.gstate), where_name(dbg_where()))
        end
        -- A tick-by-tick census across the death: a broad sweep and a single
        -- targeted kill look completely different here.
        if bani_born ~= 0 and frame >= bani_born - 2 and frame <= bani_born + 5 then
            log("MEASURE census f=%d gs=%d %s", frame, r16(A.gstate), proc_histogram())
        end
        if nb == 0 and bani_born ~= 0 and bani_died == 0 then
            bani_died = frame
            if bani_ptr ~= 0 then
                bani_fate = proc_fate(bani_ptr)
                log("MEASURE hanger_proc_fate %s", bani_fate)
            end
            if A.kilwho_hit then
                log("MEASURE kilwho ra=0x%08x match=0x%04x mask=0x%04x hits=%d"
                    .. "   (resolve: python sym_resolve.py %x)",
                    r32(A.kilwho_hit), r16(A.kilwho_a0), r16(A.kilwho_a1),
                    r16(A.kilwho_n), r32(A.kilwho_hit))
            end
            if A.sucwho_pc then
                local a12 = A.sucwho_a12 and r32(A.sucwho_a12) or 0
                local a13 = A.sucwho_a13 and r32(A.sucwho_a13) or 0
                local why = A.dropwho_why and r16(A.dropwho_why) or 0
                local WHY = { [1] = "resume PC not in ROM",
                              [2] = "a12 BELOW the proc block",
                              [3] = "a12 ABOVE the proc block" }
                log("MEASURE sucwho a7=0x%08x hits=%d a12=0x%08x a13=0x%08x "
                    .. "(a12-a13=0x%x, block 0..0x6f0) prcd2_guard=%d(%s) drops=%d",
                    r32(A.sucwho_pc), r16(A.sucwho_n), a12, a13,
                    (a12 - a13) & 0xffffffff, why, WHY[why] or "none",
                    A.dropwho_n and r16(A.dropwho_n) or 0)
            end
            log("WARN hanger_proc GONE frame=%d (alive %d ticks) gs=%d where=%s beat=%d",
                frame, frame - bani_born, r16(A.gstate),
                where_name(dbg_where()), dbg_beat())
        end
    end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d curback=%d round=%d",
                frame, r16(A.curback), r16(A.round_num))
        end
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == 13 and not HT.vs_at then HT.vs_at = frame + 90 end  -- the VS screen
        last_gstate = gs
    end

    if fighting_frame == 0 then
        force_select()
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_KANG and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    else
        -- Once the round is over the hang loop can no longer fire the clock
        -- trigger, so that is the honest end of the trial - and curback is
        -- repicked on the way out, which is not itself a failure.
        if T.hang ~= 0 and gs ~= GS_FIGHTING and T.done == 0 and not HT.nr_wait then
            finish(T.trigger == 0 and "round_ended_before_trigger"
                or "round_ended_mid_sequence")
            return
        end
        if T.hang == 0 and r16(A.curback) ~= STAGE_DEADPOOL then
            finish("not_on_deadpool_curback_" .. r16(A.curback)); return
        end
        -- -ClockJump now means SKIP THE WAITS.  The bodies go in one after
        -- another, 20-40s apart (MKHANG.ASM's chain), so watching John means
        -- Ed's and Tony's drops play first.  Every wait between drops is cut
        -- to 2 ticks, and the round clock is held at 99 until HIS drop is done
        -- so the round cannot time out in the middle of the queue.  The drops
        -- themselves run at their real speed - those are what is measured.
        if CLOCK_JUMP and T.done == 0 and frame > fighting_frame + 60 then
            if not clock_jumped then
                clock_jumped = true
                log("waits skipped (DP_CLOCK_JUMP): round timer frozen (f_freeze_timer), "
                    .. "hp_next_drop_ticks cut to 2 between drops")
            end
            -- the round clock lives in the master process's REGISTERS (a10/a11,
            -- MAIN.ASM play_1_round); clk_tens/clk_ones are only its display
            -- copy, so writing them held nothing and the round timed out -
            -- game over, on equal health - behind the queue of earlier drops.
            -- f_freeze_timer is the training-mode switch that stops it.
            if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
            local t = HT.next_ticks()
            if t and t > 2 and drop_busy() == 0 then w16(A.hp_next_drop_ticks, 2) end
        end
        pin_fighters_at(ED_X)
        observe()
    end

    if frame - last_status >= 240 then
        last_status = frame
        log("status frame=%d gs=%d curback=%d clk=%d busy=%d dropped=%d where=%s beat=%d ptr=0x%08x",
            frame, gs, r16(A.curback), round_clock(), drop_busy(), dropped0(),
            where_name(dbg_where()), dbg_beat(), (proc_count(PID_BANI)), body_ptr())
    end

    if HT.vs_at and frame == HT.vs_at then snap("vs") end
    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 9000 then finish("never_reached_fight")
    elseif frame > 24000 then finish("global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)

log("Dead Pool Boon acid-drop rig loaded")
