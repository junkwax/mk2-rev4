-- WOLF ATTRACT: the four story screens + a character profile before each demo
-- fight (MKAMODE.ASM the_story / show_next_bio, src/WSTORY.ASM).
--
-- Env (all addresses are RAW map (bit) addresses, as Lua space reads take):
--   WS_LOG       log file
--   WS_GSTATE, WS_BIO (c_amode_bio), WS_P1 (p1_char), WS_P2, WS_CURBACK
--   WS_MODS      wstory_mods, WS_MODS_END its end (tap range)
--   WS_FRAMES    frames to run
-- Verdict lines:
--   STORY  n  - one_story_screen took a Wolf module (index 0E-11 story, 14 bio)
--   DEMO  bio=N p1=N - the demo fight's player 1 against the profile shown
local function env(n, d) local v = os.getenv(n); if v == nil or v == "" then return d end; return v end
local function hx(n) return tonumber(env(n, "0"), 16) end
local LOG = env("WS_LOG", "wolf_attract_story.log")
local A = { gs = hx("WS_GSTATE"), bio = hx("WS_BIO"), p1 = hx("WS_P1"), p2 = hx("WS_P2"),
            cb = hx("WS_CURBACK"), mods = hx("WS_MODS"), mods_end = hx("WS_MODS_END") }
local FRAMES = tonumber(env("WS_FRAMES", "12000"))
-- WS_SNAPS: comma list of frames to snapshot (timed look at the screens)
-- WS_POKE_BIO=N@F: write c_amode_bio = N on frame F (show_next_bio then shows N+1)
local POKE_BIO, POKE_AT = string.match(env("WS_POKE_BIO", ""), "(%d+)@(%d+)")
POKE_BIO, POKE_AT = tonumber(POKE_BIO), tonumber(POKE_AT)
-- WS_PEEKS=name=hexaddr,...: 16-bit words logged on every snapshot and on change from WS_PEEK_FROM..WS_PEEK_TO
local PEEKS = {}
for n, a in string.gmatch(env("WS_PEEKS", ""), "([%w_]+)=(%x+)") do PEEKS[#PEEKS + 1] = {n, tonumber(a, 16)} end
local PK_FROM, PK_TO = tonumber(env("WS_PEEK_FROM", "0")), tonumber(env("WS_PEEK_TO", "0"))
local pk_last = ""
-- WS_LISTS=name=hexaddr,...: list heads whose length (link at +0) is logged with the PEEK line
local LISTS = {}
for n, a in string.gmatch(env("WS_LISTS", ""), "([%w_]+)=(%x+)") do LISTS[#LISTS + 1] = {n, tonumber(a, 16)} end
local sp_ref = nil
local function list_len(head)
    local sp = sp_ref
    local n, p = 0, sp:read_u32(head)
    while p ~= 0 and n < 2000 do n = n + 1; p = sp:read_u32(p) end
    return n
end
local TIMED = {}
for n in string.gmatch(env("WS_SNAPS", ""), "%d+") do TIMED[tonumber(n)] = true end

local f = io.open(LOG, "w")
local function log(s) f:write(s .. "\n"); f:flush() end
log("wolf_attract_story_check start")

local cpu = manager.machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
sp_ref = sp
local frame = 0
local stories = {}
local snap_at = {}
local last = {}

-- one_story_screen walks wstory_mods row by row (.word index, .long module);
-- a row read that matches is followed by its module read.  Every read of the
-- index words is logged with the index it read, deduped per frame.
local seen_frame = {}
local tap = sp:install_read_tap(A.mods, A.mods_end, "wstory", function(offset, data, mask)
    if seen_frame[frame] then return end
    seen_frame[frame] = true
    local idx_hit = sp:read_u16(A.mods)  -- not used; the verdict is the STORY log below
end)

local prev_bio, prev_gs = -1, -1
local demo_logged_for = -1
emu.register_frame_done(function()
    frame = frame + 1
    if POKE_AT and frame == POKE_AT then sp:write_u16(A.bio, POKE_BIO); log(string.format("POKE c_amode_bio=%d frame=%d", POKE_BIO, frame)) end
    local gs  = sp:read_u16(A.gs)
    local bio = sp:read_u16(A.bio)
    local p1  = sp:read_u16(A.p1)
    local p2  = sp:read_u16(A.p2)
    local cb  = sp:read_u16(A.cb)
    if seen_frame[frame] then
        stories[#stories + 1] = frame
        log(string.format("STORY %d frame=%d gs=%d bio=%d", #stories, frame, gs, bio))
        snap_at[frame + 90] = string.format("story%02d", #stories)
    end
    local key = string.format("%d/%d/%d/%d/%d", gs, bio, p1, p2, cb)
    if key ~= last.key then
        log(string.format("f=%6d gs=%2d bio=%2d p1=%2d p2=%2d curback=%2d", frame, gs, bio, p1, p2, cb))
        last.key = key
    end
    -- a demo fight: p1_char is written to the profile fighter by amode_demo_game;
    -- log once per bio value, a second after p1 changes to it
    if bio ~= demo_logged_for and p1 == bio and prev_bio == bio then
        demo_logged_for = bio
        log(string.format("DEMO bio=%d p1=%d p2=%d curback=%d frame=%d", bio, p1, p2, cb, frame))
        snap_at[frame + 200] = string.format("demo_bio%02d", bio)
    end
    prev_bio = bio
    if #PEEKS > 0 then
        local s = {}
        for _, p in ipairs(PEEKS) do s[#s + 1] = p[1] .. "=" .. sp:read_u16(p[2]) end
        for _, l in ipairs(LISTS) do s[#s + 1] = l[1] .. "#" .. list_len(l[2]) end
        s = table.concat(s, " ")
        if (frame >= PK_FROM and frame <= PK_TO and s ~= pk_last) or snap_at[frame] or TIMED[frame] then
            log(string.format("PEEK f=%d %s", frame, s)); pk_last = s
        end
    end
    if TIMED[frame] and not snap_at[frame] then snap_at[frame] = string.format("t%05d", frame) end
    if snap_at[frame] then
        manager.machine.video:snapshot()
        log(string.format("SNAP %s frame=%d", snap_at[frame], frame))
    end
    if frame >= FRAMES then
        log(string.format("END frames=%d stories=%d", frame, #stories))
        f:close()
        manager.machine:exit()
    end
end)
