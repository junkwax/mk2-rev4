-- fatality_budget_wrap.lua - runtime pool peaks DURING a finisher.
--
-- Graphics audit row 10 (doc/graphics_opportunities/BUDGET_AUDIT.md): the pools
-- were measured in busy fights but never through a fatality, when objects peak.
-- This does not drive anything.  It installs a sampler, then hands over to an
-- existing rig that already knows how to perform one finisher (FB_TARGET):
-- Scorpion's toasty, Raiden's lift, Kung Lao's split, Kahn's hammer, the souls.
--
-- Every repo path the rig opens (io.open / dofile / loadfile) is redirected into
-- FB_ROOT, a frozen copy of src/ and tools/ taken with the ROM, so a rig that
-- hard-codes the repo root still reads the map that matches the ROM under test.
--
-- Phases: PRE until the finisher starts (f_death != 0, or winner_status 4 for
-- the soul escape), then FIN to the end of the run.  At the switch the ROM's
-- latched high-waters (peak_overload, deep_dmaq) are zeroed so they re-latch on
-- the finisher alone; the drop/overflow counters are reported as deltas.
--
-- Env: FB_TARGET (rig lua, path inside FB_ROOT), FB_ROOT, FB_LOG, FB_LABEL
local REPO = "C:/Users/you/Workplace/mk2-main"
local FROOT = assert(os.getenv("FB_ROOT"), "FB_ROOT"):gsub("\\", "/")
local LOGP = assert(os.getenv("FB_LOG"), "FB_LOG")
local LABEL = os.getenv("FB_LABEL") or "finisher"
local TARGET = assert(os.getenv("FB_TARGET"), "FB_TARGET"):gsub("\\", "/")
-- FB_SHADFAST=N forces @shad_fast to N every frame (0 = the stock row loop), for
-- tools/run_fatality_shadow_ab.py.  Whatever a stage writes is logged first.
local SHADFAST = tonumber(os.getenv("FB_SHADFAST") or "")
-- FB_TRACE="first-last": log the camera / floor-skew state every frame in that
-- frame range, for comparing two boots frame by frame.  Names not in the map are
-- skipped, so the list can be generous.
local TR0, TR1 = (os.getenv("FB_TRACE") or ""):match("^(%d+)%-(%d+)$")
TR0, TR1 = tonumber(TR0), tonumber(TR1)
local TRACE_NAMES = { "worldtlx", "worldtly", "worldtlx2", "worldtlx3", "worldtlx4", "worldtlx5", "worldtlx6",
                      "skew_oc", "skew_dx", "skew_y", "skew_sag", "skew_scroll", "scrollx", "scrollx6",
                      "tick", "overload", "f_death", "gstate",
                      "timer", "timetemp", "geo_count", "geo_full", "geo_dropped",
                      "dmaq_late", "dmaq_lost", "dmaq_over", "deep_dmaq", "peak_overload", "qdma_drops" }

-- The frozen tree usually lives INSIDE the repo (tmp/...), so a path already
-- under FROOT must be left alone or it is redirected a second time.
local function redirect(p)
    if type(p) ~= "string" then return p end
    local q = p:gsub("\\", "/")
    local low = q:lower()
    if low:sub(1, #FROOT) == FROOT:lower() then return q end
    -- only what the frozen tree holds: a log path elsewhere in the repo (the
    -- run directory under tmp/) must stay where the runner asked for it
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
    logfh:write("[fb] " .. string.format(fmt, ...) .. "\n"); logfh:flush()
end

local S = {}
for line in assert(orig_open(FROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
for _, n in ipairs({ "free", "ofree", "blood_count", "fpalram", "bpalram", "f_death", "winner_status",
                     "gstate", "peak_overload", "qdma_drops" }) do
    if not S[n] then log("MISSING %s", n) end
end

local NPROC, NOBJ, NMFPAL, NMBPAL = 168, 358, 35, 45
local PALRSIZ, PALCNT = 0x40, 0x20
local space
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function rom(n) return S[n] and r16(S[n]) or nil end

local function free_len(head, cap)
    local p, n = r32(head), 0
    while p ~= 0 and n <= cap do p = r32(p); n = n + 1 end
    if n > cap then return nil end
    return n
end
local function pals(base, n)
    local c = 0
    for i = 0, n - 1 do if r16(base + i * PALRSIZ + PALCNT) ~= 0 then c = c + 1 end end
    return c
end

local frame, fin_at = 0, nil
local last_sf = nil
local ph = { PRE = {}, FIN = {} }
local at_fin = {}
local function bump(t, k, v, f)
    if v and (t[k] == nil or v > t[k]) then t[k] = v; t[k .. "_at"] = f end
end

local function sample()
    local fp, fo = free_len(S.free, NPROC + 8), free_len(S.ofree, NOBJ + 8)
    local t = fin_at and ph.FIN or ph.PRE
    local rel = fin_at and (frame - fin_at) or frame
    bump(t, "proc", fp and (NPROC - fp), rel)
    bump(t, "obj", fo and (NOBJ - fo), rel)
    bump(t, "blood", r16(S.blood_count), rel)
    bump(t, "fg", pals(S.fpalram, NMFPAL), rel)
    bump(t, "bg", pals(S.bpalram, NMBPAL), rel)
    if not fp or not fo then t.walk_fail = (t.walk_fail or 0) + 1 end
end

local function line(name, t)
    return string.format("%s %s obj=%s/%d(@%s) proc=%s/%d(@%s) blood=%s/64 fg=%s/%d bg=%s/%d walk_fail=%d",
        name, LABEL, tostring(t.obj), NOBJ, tostring(t.obj_at), tostring(t.proc), NPROC, tostring(t.proc_at),
        tostring(t.blood), tostring(t.fg), NMFPAL, tostring(t.bg), NMBPAL, t.walk_fail or 0)
end

local COUNTERS = { "qdma_drops", "dmaq_over", "dmaq_late", "dmaq_lost", "palq_drops" }
local function report()
    log("%s", line("PRE", ph.PRE))
    if not fin_at then log("NO_FINISHER %s frames=%d", LABEL, frame); return end
    log("%s", line("FIN", ph.FIN))
    local d = {}
    for _, n in ipairs(COUNTERS) do
        local v = rom(n)
        d[#d + 1] = string.format("%s=+%s", n, (v and at_fin[n]) and tostring((v - at_fin[n]) & 0xffff) or "na")
    end
    log("FINROM %s start=%d frames=%d peak_overload=%s deep_dmaq_cells=%s %s", LABEL, fin_at, frame - fin_at,
        tostring(rom("peak_overload")), S.deep_dmaq and tostring((r16(S.deep_dmaq) + 5) // 6) or "na",
        table.concat(d, " "))
end

emu.register_frame_done(function()
    frame = frame + 1
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        log("START %s target=%s", LABEL, TARGET)
    end
    local gs = r16(S.gstate)
    if S.shad_fast then
        local v = r16(S.shad_fast)
        if v ~= (SHADFAST or -1) and v ~= last_sf then
            log("SHADFAST_SET %s value=%d frame=%d curback=%d", LABEL, v, frame, S.curback and r16(S.curback) or -1)
            last_sf = v
        end
        if SHADFAST then space:write_u16(S.shad_fast, SHADFAST) end
    end
    if not fin_at and (r16(S.f_death) ~= 0 or r16(S.winner_status) == 4) then
        fin_at = frame
        for _, n in ipairs(COUNTERS) do at_fin[n] = rom(n) end
        local fp, fo = free_len(S.free, NPROC + 8), free_len(S.ofree, NOBJ + 8)
        log("FINISHER_START %s frame=%d f_death=%04x winner_status=%d gstate=%d in_use obj=%s proc=%s shad_fast=%s curback=%s",
            LABEL, frame, r16(S.f_death), r16(S.winner_status), gs, fo and tostring(NOBJ - fo) or "na",
            fp and tostring(NPROC - fp) or "na", S.shad_fast and tostring(r16(S.shad_fast)) or "na",
            S.curback and tostring(r16(S.curback)) or "na")
        if S.peak_overload then space:write_u16(S.peak_overload, 0) end
        if S.deep_dmaq then space:write_u16(S.deep_dmaq, 0) end
    end
    if TR0 and frame >= TR0 and frame <= TR1 then
        local parts = {}
        for _, n in ipairs(TRACE_NAMES) do
            if S[n] then parts[#parts + 1] = string.format("%s=%08x", n, r32(S[n])) end
        end
        local fp = free_len(S.free, NPROC + 8)
        log("TR frame=%d proc=%s %s", frame, fp and tostring(NPROC - fp) or "na", table.concat(parts, " "))
        -- every live process: id (procid, 20h) and where it resumes (pwake, 0e0h),
        -- so a process present in one boot and not the other can be named
        if S.active then
            local ids, p, n = {}, r32(S.active), 0
            while p ~= 0 and n < NPROC + 8 do
                ids[#ids + 1] = string.format("%04x@%08x", r16(p + 0x20), r32(p + 0xe0))
                p = r32(p); n = n + 1
            end
            log("TRP frame=%d %s", frame, table.concat(ids, " "))
        end
    end
    -- Before the pools are built at power-up the free lists are empty and
    -- "pool - free" would read the whole pool, so PRE only counts live fighting.
    if fin_at or gs == 2 then sample() end
    if frame % 300 == 0 then log("%s", line(fin_at and "FIN_SO_FAR" or "PRE_SO_FAR", fin_at and ph.FIN or ph.PRE)) end
end)
emu.register_stop(function() report(); logfh:close() end)

dofile(FROOT .. "/" .. TARGET)
