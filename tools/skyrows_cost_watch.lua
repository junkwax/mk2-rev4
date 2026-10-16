-- skyrows_cost_watch.lua - what KAHN'S ARENA's per-line sky costs in real flow.
--
-- Rides along with any driver rig (SW_TARGET inside SW_ROOT; repo paths it opens
-- are redirected there, as tools/hitlight_watch.lua does) and, for every frame
-- on SW_STAGE (curback, default 8), records frames drawn as lines, frames that
-- FELL BACK to the plain blocks and how often it flipped between the two (that
-- would read as flicker), lines per frame, process-pass overload, dmaq_late /
-- dmaq_over / dmaq_lost and the queue high-water deep_dmaq.  SW_OFF=1 holds
-- f_skyrows_off = 1 for the A/B.
--
-- env: SW_TARGET, SW_ROOT, SW_LOG, SW_STAGE, SW_OFF
local REPO = "C:/Users/you/Workplace/mk2-main"
local FROOT = assert(os.getenv("SW_ROOT"), "SW_ROOT"):gsub("\\", "/")
local TARGET = assert(os.getenv("SW_TARGET"), "SW_TARGET"):gsub("\\", "/")
local LOGP = assert(os.getenv("SW_LOG"), "SW_LOG")
local STAGE = tonumber(os.getenv("SW_STAGE") or "8")
local OFF = os.getenv("SW_OFF") == "1"

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
local function log(fmt, ...) logfh:write("[sw] " .. string.format(fmt, ...) .. "\n"); logfh:flush() end

local S = {}
for line in assert(orig_open(FROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local A = {}
for _, n in ipairs({ "curback", "gstate", "winner_status", "f_skyrows_off", "skr_ran", "skr_plain", "skr_lines", "overload",
    "dmaq_late", "dmaq_over", "dmaq_lost", "deep_dmaq" }) do A[n] = assert(S[n], "missing " .. n) end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local st = { drawn = 0, rows = 0, plain = 0, flips = 0, lmin = 1e9, lmax = 0, over = 0, late = 0,
             qover = 0, lost = 0 }
local prev, last, frame = nil, nil, 0

local function report(tag)
    log("%s frame=%d stage_frames=%d rows=%d fallback=%d flips=%d lines=%d..%d overload_max=%d "
        .. "late=+%d over=+%d lost_max=%d deep_dmaq=%d cells",
        tag, frame, st.drawn, st.rows, st.plain, st.flips, st.lmin == 1e9 and 0 or st.lmin, st.lmax,
        st.over, st.late, st.qover, st.lost, space:read_u16(A.deep_dmaq) // 6)
end

emu.register_frame_done(function()
    frame = frame + 1
    if OFF then space:write_u16(A.f_skyrows_off, 1) end
    local cur = { ran = space:read_u16(A.skr_ran), plain = space:read_u16(A.skr_plain),
                  late = space:read_u16(A.dmaq_late), qover = space:read_u16(A.dmaq_over) }
    if prev and space:read_u16(A.curback) == STAGE then
        st.drawn = st.drawn + 1
        if cur.ran ~= prev.ran then
            st.rows = st.rows + 1
            local n = space:read_u16(A.skr_lines)
            if n < st.lmin then st.lmin = n end
            if n > st.lmax then st.lmax = n end
            if last == "plain" then st.flips = st.flips + 1 end
            last = "rows"
        elseif cur.plain ~= prev.plain then
            st.plain = st.plain + 1
            log("FALLBACK frame=%d gstate=%d winner_status=%d", frame,
                space:read_u16(A.gstate), space:read_u16(A.winner_status))
            if last == "rows" then st.flips = st.flips + 1 end
            last = "plain"
        end
        local ov = space:read_u16(A.overload); if ov > st.over then st.over = ov end
        local lo = space:read_u16(A.dmaq_lost); if lo > st.lost then st.lost = lo end
        st.late = st.late + ((cur.late - prev.late) & 0xffff)
        st.qover = st.qover + ((cur.qover - prev.qover) & 0xffff)
    end
    prev = cur
    if frame % 300 == 0 then report("PROGRESS") end
end)
emu.register_stop(function() report("RESULT") end)

dofile(FROOT .. "/" .. TARGET)
