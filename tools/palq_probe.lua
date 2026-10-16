-- palq_probe.lua - what does the palette transfer queue actually carry?
-- (graphics audit opportunity 11, "palette update coalescing").
--
-- palset (PALL.ASM) appends [src:32 | dest:16 | count:16] to a 32-cell ring
-- and transfer_palettes drains all of it in dirq.  The ring is never
-- cleared, so every enqueue can be recovered each frame by walking from the
-- previous paltrans_end to the current one - no write tap needed (a 32-bit
-- tap on this 16-bit bus fires twice with half the data).
--
-- For every enqueue: count, colours, whether the same destination+count was
-- already queued this frame (a wasted transfer), and how many of its colours
-- equal what the previous transfer to that colour-RAM entry wrote (a
-- redundant colour).  That last one is judged against a shadow model built
-- from every transfer since boot, NOT against colour RAM itself, because the
-- drain may already have run by the time this callback reads it.  Source
-- colours are read at callback time; a producer that rewrites its buffer
-- between enqueue and drain is the audit's pointer-lifetime hazard, and is
-- out of scope here.
--
-- Two players, forced stage, both bars and the clock pinned.  P1 walks in and
-- punches every 40 frames so hit effects fire.  Logs from boot (attract,
-- select, VS, intro) to fight rel 900.
--
-- PQ_COAL=1 sets f_palcoal (PALL.ASM's coalescer) from the first frame; the
-- A/B runner boots each stage both ways.  Every 8 frames an H line hashes
-- colour RAM for all 80 palettes, so the two boots can be proved to have put
-- the same colours on screen.
--
-- env: PQ_STAGE (curback), PQ_COAL, PQ_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local STAGE = tonumber(os.getenv("PQ_STAGE") or "2")
local LOG = os.getenv("PQ_LOG") or (ROOT .. "/tools/palq_probe.log")
local COAL = (os.getenv("PQ_COAL") or "0") == "1"

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[pq] " .. string.format(fmt, ...)
    logfh:write(line, "\n")
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    pqs = sym("paltrans_start"), pqe = sym("paltrans_end"),
    f_freeze_timer = symbols["f_freeze_timer"],
    f_palcoal = symbols["f_palcoal"], palq_drops = symbols["palq_drops"],
    palq_merged = symbols["palq_merged"], palq_voided = symbols["palq_voided"],
}
local CELL, CELLS = 64, 32
local QBASE = A.pqs - CELLS * CELL      -- PALL declares paltrans_queue right before paltrans_start
local QEND = A.pqs
local GS_PSEL, GS_FIGHTING = 4, 2
local FIGHT_FRAMES = 900

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local prev_end, badptr, resets = nil, 0, 0
local last_fn, cb_gaps, cb_maxgap, cb_n = nil, 0, 0, 0
local model = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
-- after r16: a local referenced before its own declaration is the (nil) global
local CRAM, NUMPAL = 0x01800000, 80
local function cram_hash()
    local h = 2166136261
    for i = 0, NUMPAL * 256 - 1 do
        h = ((h ~ r16(CRAM + i * 16)) * 16777619) & 0xffffffff
    end
    return h
end
local function opt16(a) return a and r16(a) or -1 end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true, ["P2 High Punch"] = true,
                   ["P1 Right"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if name == "P1 Right" then return rel >= 60 and rel < 200 end
        if name == "P1 High Punch" then return rel >= 120 and (rel % 40) < 3 end
        return false
    end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

local function in_ring(p) return p >= QBASE and p < QEND and (p - QBASE) % CELL == 0 end

local function sample(gs, rel)
    local s, e = r32(A.pqs), r32(A.pqe)
    if not (in_ring(s) and in_ring(e)) then
        badptr = badptr + 1
        if badptr < 4 then log("BADPTR frame=%d start=%08x end=%08x base=%08x", frame, s, e, QBASE) end
        return
    end
    if prev_end == nil then prev_end = e; return end
    -- init_paltrans_queue (state changes) puts BOTH pointers back on the base.
    -- Walking from the old end would wrap the ring and re-count up to 31 stale
    -- cells as new - which is exactly what the first profile did at the select
    -- screen.  A start sitting on the base with the end behind the old end is
    -- a reset: only base..end is new.
    local reset = 0
    if s == QBASE and e < prev_end then
        reset = 1
        prev_end = QBASE
        resets = resets + 1
    end
    local n, cols, dup, red, first, big = 0, 0, 0, 0, 0, 0
    local seen, parts = {}, {}
    local p = prev_end
    while p ~= e and n < CELLS do
        local src, dest, cnt = r32(p), r16(p + 32), r16(p + 48)
        n = n + 1
        cols = cols + cnt
        local key = dest * 512 + cnt
        if seen[key] then dup = dup + 1 end
        seen[key] = true
        if cnt > big then big = cnt end
        local base = (dest >> 8) * 256 + (dest & 0xff)
        for i = 0, math.min(cnt, 256) - 1 do
            local v = r16(src + i * 16)
            local idx = base + i
            local m = model[idx]
            if m == nil then first = first + 1 elseif m == v then red = red + 1 end
            model[idx] = v
        end
        if #parts < 32 then parts[#parts + 1] = string.format("%04x:%d", dest, cnt) end
        p = p + CELL
        if p >= QEND then p = QBASE end
    end
    prev_end = e
    local depth = ((e - s) % (CELLS * CELL)) // CELL
    if n > 0 or depth > 0 then
        log("F frame=%d gs=%d rel=%d n=%d cols=%d dup=%d red=%d first=%d big=%d depth=%d reset=%d %s",
            frame, gs, rel, n, cols, dup, red, first, big, depth, reset, table.concat(parts, ","))
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("stage=%d coal=%d qbase=%08x", STAGE, COAL and 1 or 0, QBASE)
    end
    if not space then return end
    -- Is this callback once per EMULATED frame?  The screen's own counter says.
    -- A gap means one Lua "frame" spans several emulated frames - and several
    -- dirq drains, so per-callback queue counts are windows, not frames.
    local fn = nil
    pcall(function() fn = manager.machine.screens[":screen"]:frame_number() end)
    if fn then
        if last_fn then
            local d = fn - last_fn
            cb_n = cb_n + 1
            if d ~= 1 then cb_gaps = cb_gaps + 1 end
            if d > cb_maxgap then cb_maxgap = d end
        end
        last_fn = fn
    end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("GSTATE frame=%d %d -> %d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, 1); w16(A.p2_char, 2)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, STAGE) end
    if frame > 9000 and fighting_frame == 0 then log("ERROR never reached the fight"); logfh:close(); manager.machine:exit(); return end

    local rel = fighting_frame > 0 and (frame - fighting_frame) or -1
    if fighting_frame > 0 then
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    end
    if COAL and A.f_palcoal then w16(A.f_palcoal, 1) end
    if frame >= 2 then sample(gs, rel) end
    if frame % 8 == 0 and frame > 64 then log("H frame=%d gs=%d hash=%08x drops=%d", frame, gs, cram_hash(), opt16(A.palq_drops)) end
    if rel == FIGHT_FRAMES then
        log("RESULT frames=%d badptr=%d resets=%d coal=%d drops=%d merged=%d voided=%d", frame, badptr, resets,
            COAL and 1 or 0, opt16(A.palq_drops), opt16(A.palq_merged), opt16(A.palq_voided))
        log("CALLBACKS n=%d not_one_frame=%d max_step=%d emulated_frames=%s", cb_n, cb_gaps, cb_maxgap, tostring(last_fn))
        logfh:close()
        manager.machine:exit()
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
