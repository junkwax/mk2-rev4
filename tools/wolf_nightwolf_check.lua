-- wolf_nightwolf_check.lua - MK3 NIGHTWOLF on the Wolf build (ochar 23).
--
-- 2-player game.  P1's cursor starts on Liu Kang; P1 taps START three times -
-- on, off, on - and after each tap the pending flag (f_nwolf_cheat1) and the
-- box wipe frame (nwolf_pos: 0 = LKBOX, 8 = NWBOX9) must read 1/8, 0/0, 1/8.
-- Both confirm; P1 must reach the fight as ochar 23.  Then P1 throws each of
-- his specials at an idle P2 (both bars pinned high) and the rig logs the
-- action his process took and what P2's bar lost:
--   ARROW  Down, Back + LP      act 0008  (act_throw_fans)
--   AXEUP  Down, Forward + HP   act 0107  (act_uppercut)
--   REFL   Back, Back, Back + HK act 0604 (act_proj_sd)
--   CHARGE Forward, Forward + LK act 0207 (act_square)
-- PASS = right ochar, taps right, every special's action seen, no reboot.
-- NW_NOTAP=1 is the control: no taps, P1 must fight as Liu Kang (1).
-- NW_SND=<abs path to the Wolf WOLFSND.ASM> adds the SOUND half: the rig taps
-- the sound latch (the resolved DCS TRACK, bytes paired rolling) and each
-- trial must send his MK3 sounds (make_wolf_audio.py's nw_* rows): the
-- reflector, the arrow drawn / loosed / hit-or-blocked, axe up + axe hit, the
-- shoulder charge, Shao Kahn's "Night Wolf" at the select screen, and a plain
-- HIGH KICK must voice MK3's Dan Forden attack (rsnd_ochar -> rsnd_mk3df).
-- Stock MAME cannot PLAY the u6-u9 streams; this proves what the ROM sends.
-- Env: WB_LOG, WS_MAP.  Snapshots every 10 frames while a special runs.
local LOG = os.getenv("WB_LOG")
local NOTAP = os.getenv("NW_NOTAP") == "1"
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p1_proc", "p1_bar", "p2_bar", "illop_count", "debug4", "p2_proc",
                    "f_nwolf_cheat1", "nwolf_pos", "p1_state", "p2_state"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local SND = {}            -- base track -> nw_* key, from WOLFSND.ASM
if os.getenv("NW_SND") then
    for line in io.lines(os.getenv("NW_SND")) do
        local trk, key = line:match("%.word%s+%x+h|%d+,0(%x+)h%s*;%s*%x+%s+(nw_[%w_]+)")
        if trk then SND[tonumber(trk, 16)] = key end
    end
    local n = 0
    for _ in pairs(SND) do n = n + 1 end
    if n < 20 then error("NW_SND: found only " .. n .. " nw_* rows") end
end
local function key_of(t)
    for b, k in pairs(SND) do if t >= b and t <= b + 2 then return k end end
end
local heard, prevb = {}, nil
local raw = {}            -- every track word seen: {frame, track}
local hframe = 0
if os.getenv("NW_SND") then
    _G.NW_SNDTAP = space:install_write_tap(0x01680000, 0x0168001f, "nwsnd", function(o, d, m)
        local v = d & 0xff
        if prevb then
            local t = (prevb << 8) | v
            if t ~= 0 and (#raw == 0 or raw[#raw][2] ~= t) then raw[#raw + 1] = {hframe, t} end
            local k = key_of(t)
            if k and (#heard == 0 or heard[#heard][2] ~= k or hframe - heard[#heard][1] > 4) then
                heard[#heard + 1] = {hframe, k}
            end
        end
        prevb = v
        return d
    end)
end
-- was any of "a|b|c" sent in frames [lo, hi) ?
local function sent(alts, lo, hi)
    for _, h in ipairs(heard) do
        if h[1] >= lo and h[1] < hi then
            for a in alts:gmatch("[^|]+") do if h[2] == a then return true end end
        end
    end
    return false
end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "1 Player Start", "2 Players Start", "P1 High Punch", "P2 High Punch",
               "P1 Low Punch", "P1 High Kick", "P1 Low Kick", "P1 Down", "P1 Left", "P1 Right",
               "P2 Left"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local function done(fmt, ...) log(fmt, ...); f:close(); manager.machine:exit() end

-- select screen script: rel frame -> presses
local steps, t = {}, 100
local function press(n, at, len) steps[#steps + 1] = {at, at + (len or 6), n} end
local checks = {}
local bad = 0
checks[t] = function()
    local c = r16(A.p1_char)
    log("cursor on %d", c)
    if c ~= 1 then done("FAIL cursor on %d, not Liu Kang (1)", c) end
end
if not NOTAP then
    for i, want in ipairs({{1, 8}, {0, 0}, {1, 8}}) do
        press("1 Player Start", t + 10)
        checks[t + 70] = function()
            local fl, pos = r16(A.f_nwolf_cheat1), r16(A.nwolf_pos)
            log("tap %d: flag %d pos %d (want %d/%d)", i, fl, pos, want[1], want[2])
            if fl ~= want[1] or pos ~= want[2] then bad = bad + 1 end
            manager.machine.video:snapshot()
        end
        t = t + 80
    end
end
press("P1 High Punch", t + 10); press("P2 High Punch", t + 80)

-- fight script: each special is a list of {frame offset, input} - stick
-- entries held 4 frames, 6 frames apart, the button on the last
-- walk = frames P1 walks in first; p2 = P2's own move, thrown at the start
-- (the REFLECTOR test: Reptile's spit, Forward, Forward + HP, then the
-- reflector p1at frames later - kahn_deflect_proj leaves debug4 = 5020h)
local SPECIALS = {
    {"REFL",   0x0604, {"P1 Left", "P1 Left", "P1 Left"}, "P1 High Kick",
     p2 = {{"P2 Left", "P2 Left"}, "P2 High Punch"}, p1at = tonumber(os.getenv("NW_P1AT") or "6"),
     snd = {"nw_reflector"}},
    {"ARROW",  0x0008, {"P1 Down", "P1 Left"}, "P1 Low Punch",
     snd = {"nw_arrow_appear", "nw_arrow_fire", "nw_arrow_hit|nw_arrow_blocked"}},
    {"AXEUP",  0x0107, {"P1 Down", "P1 Right"}, "P1 High Punch", walk = 140,
     snd = {"nw_axe_up", "nw_axe_hit"}},
    {"CHARGE", 0x0207, {"P1 Right", "P1 Right"}, "P1 Low Kick", walk = 140,
     snd = {"nw_shoulder"}},
    -- a plain high kick: no action asserted (sp[2] nil), only MK3's voice
    -- (p1at 6: with no stick motion seq() puts the button at start-4, before
    -- the window the sound is looked for in)
    {"KICK",   nil,    {}, "P1 High Kick", p1at = 6, snd = {"nw_attack_0|nw_attack_1"}},
}
-- NW_ONLY=NAME runs just that special; NW_NOWALK=1 drops the walk-in
if os.getenv("NW_ONLY") then
    local keep = {}
    for _, sp in ipairs(SPECIALS) do if sp[1] == os.getenv("NW_ONLY") then keep[#keep + 1] = sp end end
    SPECIALS = keep
end
if os.getenv("NW_NOWALK") == "1" then for _, sp in ipairs(SPECIALS) do sp.walk = nil end end
local fsteps, seen = {}, {}
local function seq(at, sticks, button)
    for k, d in ipairs(sticks) do fsteps[#fsteps + 1] = {at + (k - 1) * 6, at + (k - 1) * 6 + 4, d} end
    local b = at + (#sticks - 1) * 6 + 2
    fsteps[#fsteps + 1] = {b, b + 4, button}
end
do
    local at = 200
    for i, sp in ipairs(SPECIALS) do
        if sp.walk then fsteps[#fsteps + 1] = {at, at + sp.walk, "P1 Right"}; at = at + sp.walk + 20 end
        sp.start = at
        if sp.p2 and os.getenv("NW_NOSPIT") ~= "1" then seq(at, sp.p2[1], sp.p2[2]) end
        seq(at + (sp.p1at or 0), sp[3], sp[4])
        sp.stop = at + 260
        at = at + 300
    end
end

local frame, started, sel, fight, ill0 = 0, false, nil, nil, nil
-- NW_TRACE: every HK press bj_hi_kick dispatches stamps l_hk (p1 word)
local hktap
if os.getenv("NW_TRACE") and S.l_hk then
    _G.NW_HKTAP = space:install_write_tap(S.l_hk, S.l_hk + 15, "nwhk", function(off, data, mask)
        if fight then
            log("  l_hk written (HK dispatched) at fight+%d, tick %04x", frame - fight, r16(S.tick))
            local q = S.p1_jcq; local nxt = r32(q)
            local s = {}
            for k = 1, 8 do
                local e = nxt - 32 * k
                if e <= q then e = e + 32 * 20 end
                local v = r32(e)
                s[#s + 1] = string.format("%04x@%04x", (v >> 16) & 0xffff, v & 0xffff)
            end
            log("  p1_jcq newest first: %s", table.concat(s, " "))
        end
    end)
end
local p2bar0
sndbad = 0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    hframe = frame
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel and r16(A.p1_state) ~= 0 and r16(A.p2_state) ~= 0
       and r16(A.p1_char) < 12 and r16(A.p2_char) < 12 then
        sel = frame; ill0 = r16(A.illop_count); log("select at %d", frame)
    end
    if not sel then
        if frame >= 1500 and gs == 4 and r16(A.p2_state) == 0 then
            F["2 Players Start"]:set_value((frame % 60) < 6 and 1 or 0)
        elseif frame >= 1500 and gs ~= 4 then
            local k = (frame - 1500) % 200
            F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
            F["1 Player Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
            F["2 Players Start"]:set_value((k >= 120 and k < 126) and 1 or 0)
        end
        if frame > 9000 then done("no select screen - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done("FAIL illop_count moved (a reboot) at frame %d", frame) return end
    if not fight then
        local rel = frame - sel
        for _, s in ipairs(steps) do
            if rel >= s[1] and rel < s[2] then F[s[3]]:set_value(1) end
        end
        if checks[rel] then checks[rel]() end
        if gs == 2 then
            fight = frame; log("fight at %d", frame)
            if os.getenv("NW_SND") and not NOTAP then
                log("select screen: %s", sent("nw_name", 0, frame) and "Kahn said \"Night Wolf\"" or "NO NAME CALL")
                if not sent("nw_name", 0, frame) then sndbad = (sndbad or 0) + 1 end
            end
        end
        if rel > 4000 then done("no fight - NO VERDICT") end
        return
    end
    local rel = frame - fight
    -- both bars stay up so the round never ends under the specials
    if r16(A.p1_bar) < 0x80 then w16(A.p1_bar, 0xa1) end
    if rel == 150 then
        manager.machine.video:snapshot()
        local p1o = r32(A.p1_obj)
        local och = p1o ~= 0 and r16(p1o + 0x1f0) or -1
        local want = NOTAP and 1 or 23
        log("P1 ochar %d (want %d), %d bad taps", och, want, bad)
        if och ~= want or bad ~= 0 then done("FAIL P1 ochar %d (want %d), %d bad taps", och, want, bad) end
        if NOTAP then done("PASS control: no tap, P1 fights as Liu Kang") end
    end
    if rel < 150 then return end
    for _, s in ipairs(fsteps) do
        if rel >= s[1] and rel < s[2] then F[s[3]]:set_value(1) end
    end
    local proc = r32(A.p1_proc)
    local act = proc ~= 0 and r16(proc + 0x1f0) or 0
    for _, sp in ipairs(SPECIALS) do
        if rel == sp.start then
            p2bar0 = r16(A.p2_bar); w16(A.debug4, 0)
            if S.dmaq_late then sp.late0, sp.lost0 = r16(S.dmaq_late), r16(S.dmaq_lost) end
        end
        if rel >= sp.start and rel < sp.stop and os.getenv("NW_TRACE") then
            local p2 = r32(A.p2_proc); local a2 = p2 ~= 0 and r16(p2 + 0x1f0) or 0
            if act ~= (sp.la1 or -1) or a2 ~= (sp.la2 or -1) then
                log("  %s +%d P1 act %04x P2 act %04x P1 bar %d P1 flags %04x", sp[1], rel - sp.start, act, a2,
                    r16(A.p1_bar), r16(r32(A.p1_proc) + 0x210)); sp.la1, sp.la2 = act, a2
            end
        end
        if rel >= sp.start and rel < sp.stop then
            if sp[2] == nil and not seen[sp[1]] then seen[sp[1]] = 0 end
            if act == sp[2] and not seen[sp[1]] then seen[sp[1]] = rel - sp.start; log("%s: action %04x at +%d", sp[1], act, rel - sp.start) end
            if (rel - sp.start) % 10 == 0 or (os.getenv("NW_SNAPALL") == sp[1] and rel - sp.start < 80) then
                manager.machine.video:snapshot()
            end
        end
        if rel == sp.stop then
            if S.dmaq_late then log("%s: during it dmaq_late +%d dmaq_lost +%d", sp[1],
                r16(S.dmaq_late) - sp.late0, r16(S.dmaq_lost) - sp.lost0) end
            log("%s: P2 bar %d -> %d (%s)%s", sp[1], p2bar0, r16(A.p2_bar), seen[sp[1]] and "fired" or "NOT SEEN",
                sp.p2 and string.format(", debug4 %04x%s", r16(A.debug4), r16(A.debug4) == 0x5020 and " = REFLECTED" or " - nothing reflected") or "")
            if r16(A.p2_bar) < 0x40 then w16(A.p2_bar, 0xa1) end
            if os.getenv("NW_SND") and sp.snd then
                local miss = {}
                for _, alts in ipairs(sp.snd) do
                    if not sent(alts, fight + sp.start, fight + sp.stop) then miss[#miss + 1] = alts end
                end
                local got = {}
                for _, h in ipairs(heard) do
                    if h[1] >= fight + sp.start and h[1] < fight + sp.stop then
                        got[#got + 1] = string.format("%s@+%d", h[2], h[1] - fight - sp.start)
                    end
                end
                log("%s: sent %s%s", sp[1], #got > 0 and table.concat(got, " ") or "(none of his)",
                    #miss > 0 and ("  MISSING " .. table.concat(miss, ",")) or "")
                if #miss > 0 then
                    sndbad = (sndbad or 0) + 1
                    local r = {}
                    for _, h in ipairs(raw) do
                        if h[1] >= fight + sp.start and h[1] < fight + sp.stop then
                            r[#r + 1] = string.format("%04x@+%d", h[2], h[1] - fight - sp.start)
                        end
                    end
                    log("%s: every latch word in the window: %s", sp[1], table.concat(r, " "))
                end
            end
        end
    end
    if rel == SPECIALS[#SPECIALS].stop + 10 then
        local miss = {}
        for _, sp in ipairs(SPECIALS) do if not seen[sp[1]] then miss[#miss + 1] = sp[1] end end
        if #miss > 0 then done("FAIL specials not seen: %s", table.concat(miss, ","))
        elseif (sndbad or 0) > 0 then done("FAIL %d sound check(s) failed - see above", sndbad)
        else done("PASS Nightwolf picked by the START tap; all four specials fired, no reboot%s",
                  os.getenv("NW_SND") and "; every MK3 sound sent" or "") end
    end
end)
