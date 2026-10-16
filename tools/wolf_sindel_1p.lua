-- wolf_sindel_1p.lua - a ONE-PLAYER game as UMK3 SINDEL (Wolf, ochar 21),
-- looking for a hang.  1P Start, the real joystick to Shang Tsung, a START
-- tap, confirm - then the ladder, the VS screen and the fight against the
-- CPU, P1 mashing a fixed pseudo-random pattern (specials included).
-- Every gstate change is logged.  FREEZE = the game's `tick` word not moving
-- for 240 frames (the display still refreshes off the interrupt when a
-- process spins), or illop_count moving (a reboot).  Runs S1_FRAMES frames
-- past the select screen (default 9000).
-- Env: WB_LOG, WS_MAP, S1_FRAMES, S1_SEED, S1_NOTAP=1 (play as Shang - control).
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc", "illop_count",
                    "tick", "p1_state", "p1_bar", "p2_bar", "curback", "winner_status", "round_num"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local NAMES = {"Coin 1", "1 Player Start", "P1 High Punch", "P1 Low Punch", "P1 Block", "P1 Down", "P1 Left",
               "P1 Right", "P1 Up", "P1 High Kick", "P1 Low Kick"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local FRAMES = tonumber(os.getenv("S1_FRAMES") or "9000")
local seed = tonumber(os.getenv("S1_SEED") or "12345")
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return (seed >> 8) % n end
local NOTAP = os.getenv("S1_NOTAP") == "1"
local function done(fmt, ...) log(fmt, ...); f:close(); manager.machine:exit() end
local frame, started, sel, ill0 = 0, false, nil, nil
local lastgs, lasttick, tickat = -1, -1, 0
local held, until_f = {}, 0
local MOVES = {
    {"P1 Right"}, {"P1 Left"}, {"P1 Down"}, {"P1 Up"}, {"P1 Up", "P1 Right"}, {"P1 Block"},
    {"P1 High Punch"}, {"P1 Low Punch"}, {"P1 High Kick"}, {"P1 Low Kick"}, {"P1 Down", "P1 High Punch"},
    {"P1 Left", "P1 High Kick"}, {"P1 Left", "P1 Low Kick"}, {},
}
-- special motions as scripted bursts: {frames, inputs}...
local R, L, D = "P1 Right", "P1 Left", "P1 Down"
local SCRIPTS = {
    { {4, {R}}, {3, {}}, {4, {R}}, {4, {"P1 Low Punch"}} },                               -- fireball
    { {4, {R}}, {3, {}}, {4, {R}}, {3, {}}, {4, {R}}, {4, {"P1 High Punch"}} },          -- scream
    { {6, {"P1 Up"}}, {16, {}}, {4, {D}}, {3, {D, R}}, {3, {R}}, {4, {"P1 Low Kick"}} },  -- air fireball
    { {4, {L}}, {3, {}}, {4, {L}}, {3, {}}, {4, {R}}, {4, {"P1 High Kick"}}, {60, {}}, {6, {"P1 Block"}} }, -- fly
}
local script, si, st = nil, 1, 0
-- S1_WIN=1: she cannot lose (bar pinned) and the CPU's bar is capped at 30,
-- so the run climbs the ladder; in FINISH HIM she tries her finishers in turn.
local WIN = os.getenv("S1_WIN") == "1"
local B = "P1 Block"
local FIN = {
    { {4, {L}}, {2, {}}, {4, {L}}, {2, {}}, {4, {R}}, {2, {}}, {6, {B}} },                -- scream rip
    { {4, {D}}, {2, {}}, {4, {D}}, {2, {}}, {4, {L}}, {2, {}}, {6, {B}} },                -- hair spin
    { {4, {D}}, {2, {}}, {4, {D}}, {2, {}}, {4, {D}}, {2, {}}, {6, {"P1 Low Kick"}} },    -- babality
    { {4, {D}}, {2, {}}, {4, {R}}, {2, {}}, {4, {R}}, {2, {}}, {6, {B}} },                -- stage
    { {4, {R}}, {2, {}}, {4, {R}}, {2, {}}, {4, {L}}, {2, {}}, {6, {B}} },                -- (mirrored rip)
    { {4, {D}}, {2, {}}, {4, {D}}, {2, {}}, {4, {R}}, {2, {}}, {6, {B}} },                -- (mirrored hair)
}
local fin_n, lastws = 0, 0
-- S1_WATCH=1: fast-forward MUTED through the whole ladder, then play the
-- cast roll and credits at real speed with the sound on (needs -Listen and
-- a MAME that loads u6-u9 - the music lives there), S1_WATCHLEN frames.
local WATCH = os.getenv("S1_WATCH") == "1"
local watch_end, yelled = nil, false
local WATCH_AT = tonumber(os.getenv("S1_WATCHAT") or "0")   -- real speed + sound from this frame
local function set_mute(on)                    -- this MAME has no settable attenuation
    pcall(function() manager.machine.sound.system_mute = on end)
end
local tap, prevb, shot = nil, nil, 0
local function on_sound(offset, data, mask)
    local v = data & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if c == 0x0713 then
        log("CREDITS MUSIC code 0713 at frame %d", frame); shot = 60
        if WATCH and not watch_end then         -- backstop; the MK yell ends it
            watch_end = frame + tonumber(os.getenv("S1_WATCHLEN") or "12000")
        end
    end
    -- the MK logo shout (mklogo_tada, MKAMODE.ASM) after the credits: let it ring, then stop
    if c == 0x0033 and watch_end and not yelled then
        yelled = true; log("MK YELL code 0033 at frame %d", frame); watch_end = frame + 300
    end
    return data
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
        if WATCH then set_mute(true) end
    end
    frame = frame + 1
    if os.getenv("S1_TAP") and not tap then tap = space:install_write_tap(0x01680000, 0x0168001f, "s1_snd", on_sound) end
    if os.getenv("S1_SNAPFROM") and frame >= tonumber(os.getenv("S1_SNAPFROM")) and frame <= tonumber(os.getenv("S1_SNAPTO"))
        and frame % tonumber(os.getenv("S1_SNAPEVERY") or "4") == 0 then manager.machine.video:snapshot() end
    if shot > 0 then shot = shot - 1; if frame % 150 == 0 then manager.machine.video:snapshot() end end
    if WATCH and WATCH_AT > 0 and frame == WATCH_AT then
        manager.machine.video.throttled = true; set_mute(false); log("WATCH real speed from %d", frame)
    end
    if watch_end and frame >= watch_end then done("WATCH done at frame %d", frame) return end
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs ~= lastgs then
        log("frame %d gstate %02X  p1_char %d p2_char %d curback %02X round %d", frame, gs, r16(A.p1_char),
            r16(A.p2_char), r16(A.curback), r16(A.round_num))
        lastgs = gs
    end
    local tk = r16(A.tick)
    if tk ~= lasttick then lasttick = tk; tickat = frame end
    if not sel then
        if gs == 4 and r16(A.p1_state) ~= 0 and r16(A.p1_char) < 12 then
            sel = frame; ill0 = r16(A.illop_count); log("select at %d", frame)
        elseif frame >= 1500 then
            local k = (frame - 1500) % 200
            F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
            F["1 Player Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
        end
        if frame > 9000 then done("no select screen - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then
        done("FREEZE/REBOOT: illop_count moved at frame %d gstate %02X illop_pc %08X", frame, gs,
             S.illop_pc and r32(S.illop_pc) or 0)
        return
    end
    local rel = frame - sel
    if frame - tickat > 240 and rel > 400 then
        local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
        done("FREEZE: tick stopped at frame %d (+%d) gstate %02X pc %08X  p1act %04X p2act %04X ws %d  p1 %d p2 %d",
             tickat, tickat - sel, gs, cpu.state["PC"].value, p1p ~= 0 and r16(p1p + 0x1f0) or 0,
             p2p ~= 0 and r16(p2p + 0x1f0) or 0, r16(A.winner_status), r16(A.p1_char), r16(A.p2_char))
        return
    end
    if rel >= FRAMES then done("PASS no freeze in %d frames (gstate %02X)", FRAMES, gs) return end
    -- the select screen: to Shang, the tap, confirm
    if rel < 400 then
        local function tap(n, at) if rel >= at and rel < at + 6 then F[n]:set_value(1) end end
        tap("P1 Down", 100); tap("P1 Right", 130)
        if not NOTAP then tap("1 Player Start", 180) end
        tap("P1 High Punch", 260)
        if rel == 250 then log("cursor %d", r16(A.p1_char)) end
        return
    end
    -- S1_VIC=1: in FINISH HIM she stands still, so the round times out into
    -- her VICTORY, filmed every 6 frames for 700 frames
    if os.getenv("S1_VIC") == "1" and (vic_t or (gs == 2 and r16(A.winner_status) == 3)) then
        vic_t = (vic_t or 0) + 1
        if vic_t % 6 == 0 then manager.machine.video:snapshot() end
        if vic_t % 30 == 0 then
            local o = r32(A.p1_obj)
            if o ~= 0 then log("  vic +%d oypos %d ws %d gs %02X", vic_t, r16(o + 0x0b0), r16(A.winner_status), gs) end
        end
        if vic_t >= 700 then done("FILMED her victory") end
        return
    end
    -- S1_OPP / S1_STAGE: force the CPU opponent and the stage (hex curback),
    -- and log the display budget's counters every 300 frames of the fight
    if os.getenv("S1_OPP") and rel >= 400 then
        if gs ~= 2 and gs ~= 5 then
            space:write_u16(A.p2_char, tonumber(os.getenv("S1_OPP")))
            if os.getenv("S1_STAGE") then space:write_u16(A.curback, tonumber(os.getenv("S1_STAGE"), 16)) end
        end
        if gs == 2 and os.getenv("S1_PIN") then space:write_u16(A.p1_bar, 0xa1); space:write_u16(A.p2_bar, 0xa1) end
        if gs == 2 then
            local l = r16(S.dmaq_late)
            if late0 and l ~= late0 then
                local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
                manager.machine.video:snapshot()
                log("  LATE +%d at %d  p1act %04X p2act %04X  debug4 %04X", l - late0, frame,
                    p1p ~= 0 and r16(p1p + 0x1f0) or 0, p2p ~= 0 and r16(p2p + 0x1f0) or 0,
                    S.debug4 and r16(S.debug4) or 0)
            end
            late0 = l
        end
        if gs == 2 and frame % 300 == 0 then
            log("  budget: late %d over %d lost %d qdrops %d peak %d skr_plain %d  p2 %d curback %02X",
                r16(S.dmaq_late), r16(S.dmaq_over), r16(S.dmaq_lost), r16(S.qdma_drops), r16(S.peak_overload),
                r16(S.skr_plain), r16(A.p2_char), r16(A.curback))
        end
    end
    if gs ~= 2 then
        if rel % 40 < 4 then F["P1 High Punch"]:set_value(1) end    -- through any screen that waits
        return
    end
    if WIN then
        space:write_u16(A.p1_bar, 0xa1)
        if r16(A.p2_bar) > 30 then space:write_u16(A.p2_bar, 30) end
        local ws = r16(A.winner_status)
        if ws ~= lastws then
            log("frame %d winner_status %d (p2_char %d curback %02X)", frame, ws, r16(A.p2_char), r16(A.curback))
            if ws == 3 then
                fin_n = fin_n + 1
                script = FIN[(fin_n - 1) % #FIN + 1]; si, st = 1, 0
                log("  finisher script %d", (fin_n - 1) % #FIN + 1)
            end
            lastws = ws
        end
        if ws == 3 and not script and rnd(40) == 0 then script = FIN[rnd(#FIN) + 1]; si, st = 1, 0 end
    end
    -- fighting: scripted specials one time in three, else a random held input
    if script then
        local s = script[si]
        for _, n in ipairs(s[2]) do F[n]:set_value(1) end
        st = st + 1
        if st >= s[1] then si = si + 1; st = 0 end
        if si > #script then script = nil end
        return
    end
    if frame >= until_f then
        if rnd(3) == 0 then script = SCRIPTS[rnd(#SCRIPTS) + 1]; si, st = 1, 0; return end
        held = MOVES[rnd(#MOVES) + 1]
        until_f = frame + 4 + rnd(14)
    end
    for _, n in ipairs(held) do F[n]:set_value(1) end
end)
