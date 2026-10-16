-- strip_cost_watch.lua - what a strip_layer producer costs during real flow.
--
-- Rides along with any driver rig (SW_TARGET inside SW_ROOT; repo paths it
-- opens are redirected there, as tools/hitlight_watch.lua does) and, for every
-- frame spent on the stage SW_STAGE (curback), records:
--   drawn     frames on that stage
--   banded    frames whose sky strip_layer actually ran (strip_ran advanced)
--   skipped   frames on that stage with the arm live but no banded draw - a
--             display pass that did not happen, i.e. a dropped frame
--   stall     strip_v1 - strip_v0 per banded draw, scanlines (avg / max)
--   overload  process-pass overload, max
--   late      dmaq_late delta over those frames (blits unfinished at flip)
-- A line every 300 frames, a RESULT at stop.
--
-- env: SW_TARGET, SW_ROOT, SW_LOG, SW_STAGE (default 8, KAHN'S ARENA)
local REPO = "C:/Users/you/Workplace/mk2-main"
local FROOT = assert(os.getenv("SW_ROOT"), "SW_ROOT"):gsub("\\", "/")
local TARGET = assert(os.getenv("SW_TARGET"), "SW_TARGET"):gsub("\\", "/")
local LOGP = assert(os.getenv("SW_LOG"), "SW_LOG")
local STAGE = tonumber(os.getenv("SW_STAGE") or "8")
local OFF = os.getenv("SW_OFF") == "1"   -- the A/B: name a list nobody draws, so the sky draws plain

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
for _, n in ipairs({ "curback", "gstate", "f_strip", "strip_ran", "strip_v0", "strip_v1", "strip_list",
    "overload", "dmaq_late" }) do A[n] = assert(S[n], "missing " .. n) end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local st = { drawn = 0, banded = 0, skipped = 0, sum = 0, max = 0, over = 0, late = 0 }
local prev_ran, prev_late, frame = nil, nil, 0

local function report(tag)
    log("%s frame=%d stage_frames=%d banded=%d skipped=%d stall_avg=%.1f stall_max=%d overload_max=%d late=+%d",
        tag, frame, st.drawn, st.banded, st.skipped, st.banded > 0 and st.sum / st.banded or 0,
        st.max, st.over, st.late)
end

emu.register_frame_done(function()
    frame = frame + 1
    if OFF then space:write_u32(A.strip_list, 1) end
    local ran, late = space:read_u16(A.strip_ran), space:read_u16(A.dmaq_late)
    if prev_ran and space:read_u16(A.curback) == STAGE then
        st.drawn = st.drawn + 1
        if ran ~= prev_ran then
            st.banded = st.banded + 1
            local d = space:read_u16(A.strip_v1) - space:read_u16(A.strip_v0)
            if d < 0 then d = d + 288 end
            st.sum = st.sum + d
            if d > st.max then st.max = d end
        elseif space:read_u16(A.f_strip) ~= 0 and not OFF then
            st.skipped = st.skipped + 1
        end
        local ov = space:read_u16(A.overload)
        if ov > st.over then st.over = ov end
        st.late = st.late + ((late - prev_late) & 0xffff)
    end
    prev_ran, prev_late = ran, late
    if frame % 300 == 0 then report("PROGRESS") end
end)
emu.register_stop(function() report("RESULT") end)

dofile(FROOT .. "/" .. TARGET)
