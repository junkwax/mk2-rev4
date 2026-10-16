-- WOLF ATTRACT PROFILES around data/UPPROF.IMG (show_next_bio -> upprof_screen,
-- MKAMODE.ASM; tools/make_upprof.py).  Runs the attract loop and, every time
-- c_amode_bio changes (a new profile starting), snapshots the finished screen
-- and logs the DMA queue's late/overflow counters, so a pass that overran the
-- frame is a number and not a guess.
--
-- Env (RAW map / bit addresses, as Lua space reads take):
--   UP_LOG, UP_FRAMES, UP_BIO (c_amode_bio), UP_GS (gstate)
--   UP_LATE (dmaq_late), UP_OVER (dmaq_over) - optional, 0 = not logged
--   UP_SNAP  frames after the change to snapshot (default 60: all four passes done)
-- Lines:  BIO n frame=F   SNAP bioNN frame=F late=L over=O   END
local function env(n, d) local v = os.getenv(n); if v == nil or v == "" then return d end; return v end
local function hx(n) return tonumber(env(n, "0"), 16) end
local LOG = env("UP_LOG", "wolf_upprof.log")
local FRAMES = tonumber(env("UP_FRAMES", "40000"))
local SNAP = tonumber(env("UP_SNAP", "60"))
local A = { bio = hx("UP_BIO"), gs = hx("UP_GS"), late = hx("UP_LATE"), over = hx("UP_OVER") }

local f = io.open(LOG, "w")
local function log(s) f:write(s .. "\n"); f:flush() end
log("wolf_upprof_check start")

local sp = manager.machine.devices[":maincpu"].spaces["program"]
local frame, prev, seq, pending = 0, nil, {}, {}
local function ctr(a) if a == 0 then return -1 end; return sp:read_u16(a) end

emu.register_frame_done(function()
    frame = frame + 1
    local bio = sp:read_u16(A.bio)
    if prev ~= nil and bio ~= prev then
        seq[#seq + 1] = bio
        log(string.format("BIO %d frame=%d gs=%d late=%d over=%d", bio, frame, sp:read_u16(A.gs), ctr(A.late), ctr(A.over)))
        pending[frame + SNAP] = bio
    end
    prev = bio
    if pending[frame] then
        manager.machine.video:snapshot()
        log(string.format("SNAP bio%02d frame=%d late=%d over=%d", pending[frame], frame, ctr(A.late), ctr(A.over)))
        pending[frame] = nil
    end
    if frame >= FRAMES then
        log("END frames=" .. frame .. " order=" .. table.concat(seq, ","))
        f:close()
        manager.machine:exit()
    end
end)
