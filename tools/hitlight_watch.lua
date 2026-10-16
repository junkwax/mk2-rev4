-- hitlight_watch.lua - does the hit light always let go, whatever the game does?
--
-- The hit light (MKFX.ASM hitlight_start / hitlight_proc, on by default since
-- 2026-09-15) swaps the struck fighter onto a private copy of his palette for
-- five refreshes and hands it back.  tools/hitlight_test.lua proves that in a
-- controlled punch loop.  This proves it across REAL game flow - round and
-- match ends, the continue / buy-in screen, character select, other palette
-- effects - by riding along with an existing rig that drives that flow.
--
-- It drives nothing.  It installs a per-frame watchdog, then hands over to the
-- rig named by HLW_TARGET (path inside HLW_ROOT).  Every repo path the rig
-- opens is redirected into HLW_ROOT, a frozen copy of src/ + tools/ taken with
-- the ROM, so a rig that hard-codes the repo root reads the matching map.
--
-- Every frame:
--   lit      a fighter's colour map was allocated for hl_pal1 / hl_pal2
--   procs    hitlight_proc processes alive (procid 011eh / 011fh)
--   held     colour-map slots whose palette id is hl_pal1 / hl_pal2
-- Violations:
--   STUCK_LIT   a fighter lit for more than MAX_LIT refreshes in a row
--   LEAK        a slot held for, or a fighter wearing, a private buffer while
--               no hitlight_proc is alive (for more than GRACE refreshes)
--   STRAY_PROC  a hitlight_proc alive for more than GRACE refreshes outside
--               gs_fighting (2)
-- Verdict: PASS only if lights were seen to start and nothing was violated.
--
-- Env: HLW_TARGET, HLW_ROOT, HLW_LOG, HLW_LABEL
local REPO = "C:/Users/you/Workplace/mk2-main"
local FROOT = assert(os.getenv("HLW_ROOT"), "HLW_ROOT"):gsub("\\", "/")
local LOGP = assert(os.getenv("HLW_LOG"), "HLW_LOG")
local LABEL = os.getenv("HLW_LABEL") or "hitlight_watch"
local TARGET = assert(os.getenv("HLW_TARGET"), "HLW_TARGET"):gsub("\\", "/")

local function redirect(p)
    if type(p) ~= "string" then return p end
    local q = p:gsub("\\", "/")
    local low = q:lower()
    if low:sub(1, #FROOT) == FROOT:lower() then return q end
    local rest = q:sub(#REPO + 1)
    if low:sub(1, #REPO) == REPO:lower() and (rest:lower():sub(1, 5) == "/src/" or rest:lower():sub(1, 7) == "/tools/") then
        return FROOT .. rest
    end
    return q
end
local orig_open, orig_dofile, orig_loadfile = io.open, dofile, loadfile
io.open = function(p, m) return orig_open(redirect(p), m) end
dofile = function(p) return orig_dofile(redirect(p)) end
loadfile = function(p, ...) return orig_loadfile(redirect(p), ...) end

local logfh = assert(orig_open(LOGP, "w"))
local function log(fmt, ...)
    logfh:write("[hlw] " .. string.format(fmt, ...) .. "\n"); logfh:flush()
end

local S = {}
do
    local fh = orig_open(FROOT .. "/src/mk2.map", "r") or orig_open(FROOT .. "/src/MK2.MAP", "r")
    assert(fh, "no mk2.map under HLW_ROOT/src")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
    end
    fh:close()
end
for _, n in ipairs({ "gstate", "p1_obj", "p2_obj", "palram", "active", "hl_pal1", "hl_pal2", "f_hitlight" }) do
    assert(S[n], "missing map symbol " .. n)
end

local OPAL, PROCID = 0x140, 0x20
local PALRSIZ, PALCNT, NUMPAL, NPROC = 0x40, 0x20, 80, 168
local PID1, PID2 = 0x011e, 0x011f
local GS_FIGHTING = 2
local MAX_LIT, GRACE = 12, 3

local space
local frame = 0
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end

local lit_run = { 0, 0 }
local starts = { 0, 0 }
local leak_run, stray_run = 0, 0
local violations, first_bad = 0, {}
local last_gs, gstates, gs_order = -1, {}, {}
local flag_seen = nil

local function bad(kind, fmt, ...)
    violations = violations + 1
    if not first_bad[kind] then
        first_bad[kind] = frame
        log("VIOLATION %s frame=%d " .. fmt, kind, frame, ...)
    end
end

local function fighter_lit(objptr)
    local o = r32(objptr)
    if o == 0 then return false end
    local slot = r16(o + OPAL) & 0xff
    if slot >= NUMPAL then return false end
    local id = r32(S.palram + slot * PALRSIZ)
    return id == S.hl_pal1 or id == S.hl_pal2
end

local function held_slots()
    local n = 0
    for slot = 0, NUMPAL - 1 do
        local base = S.palram + slot * PALRSIZ
        local id = r32(base)
        if (id == S.hl_pal1 or id == S.hl_pal2) and r16(base + PALCNT) ~= 0 then n = n + 1 end
    end
    return n
end

local function live_procs()
    local n, p, guard = 0, r32(S.active), 0
    while p ~= 0 and guard < NPROC + 8 do
        local id = r16(p + PROCID)
        if id == PID1 or id == PID2 then n = n + 1 end
        p = r32(p); guard = guard + 1
    end
    return n
end

emu.register_frame_done(function()
    frame = frame + 1
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        log("START %s target=%s", LABEL, TARGET)
    end
    local gs = r16(S.gstate)
    local procs, held = live_procs(), held_slots()
    local lit = { fighter_lit(S.p1_obj), fighter_lit(S.p2_obj) }
    if gs ~= last_gs then
        if not gstates[gs] then gstates[gs] = true; gs_order[#gs_order + 1] = gs end
        log("GSTATE frame=%d %d -> %d procs=%d held=%d lit=%s/%s f_hitlight=%d", frame, last_gs, gs, procs, held,
            tostring(lit[1]), tostring(lit[2]), r16(S.f_hitlight))
        last_gs = gs
    end
    if flag_seen == nil and gs == GS_FIGHTING then
        flag_seen = r16(S.f_hitlight)
        log("F_HITLIGHT at first fight frame=%d value=%d", frame, flag_seen)
    end
    for side = 1, 2 do
        if lit[side] then
            if lit_run[side] == 0 then
                starts[side] = starts[side] + 1
                if starts[side] <= 3 then log("LIGHT_START side=%d frame=%d gstate=%d", side, frame, gs) end
            end
            lit_run[side] = lit_run[side] + 1
            if lit_run[side] > MAX_LIT then bad("STUCK_LIT", "side=%d run=%d gstate=%d", side, lit_run[side], gs) end
        else
            lit_run[side] = 0
        end
    end
    if procs == 0 and (held > 0 or lit[1] or lit[2]) then
        leak_run = leak_run + 1
        if leak_run > GRACE then bad("LEAK", "held=%d lit=%s/%s gstate=%d", held, tostring(lit[1]), tostring(lit[2]), gs) end
    else
        leak_run = 0
    end
    if procs > 0 and gs ~= GS_FIGHTING then
        stray_run = stray_run + 1
        if stray_run > GRACE then bad("STRAY_PROC", "procs=%d gstate=%d", procs, gs) end
    else
        stray_run = 0
    end
end)

emu.register_stop(function()
    local seq = {}
    for _, g in ipairs(gs_order) do seq[#seq + 1] = tostring(g) end
    local verdict = (violations == 0 and (starts[1] + starts[2]) > 0) and "PASS" or "FAIL"
    log("RESULT %s %s frames=%d starts=%d/%d violations=%d gstates=%s f_hitlight_first_fight=%s",
        verdict, LABEL, frame, starts[1], starts[2], violations, table.concat(seq, ","), tostring(flag_seen))
    logfh:close()
end)

dofile(FROOT .. "/" .. TARGET)
