-- wolf_rsmoke_check.lua - MK3 ROBOT SMOKE on the Wolf build (ochar 24).
--
-- 2-player game.  P2's cursor starts on Reptile; P2 taps START three times -
-- on, off, on - and after each tap the pending flag (f_rsmoke_cheat2) and the
-- box wipe frame (rsmoke_pos: 0 = RPBOX, 8 = RSBOX9) must read 1/8, 0/0, 1/8.
-- Both confirm; P2 must reach the fight as ochar 24 (P1 is Liu Kang).  Then
-- P2 throws his specials at an idle P1 - "P2 FWD" / "P2 BACK" are resolved
-- every frame from the two positions (the teleport puts him on the other side)
-- (both bars pinned high) and the rig logs what each did:
--   INVIS  hold Block, Up, Up + HP   m_inviso set in his oflags2
--   VISIB  the same again            m_inviso clear
--   SPEAR  Back, Back + LP           act 0011 (act_spear), P1's bar drops
--   TELE   Forward, Forward + LK     act 020a (act_decoy) then 0107, P1's bar drops
--   RUN    back off, then Run + Forward: ~7 px a tick, turbo spent (rs_turbo)
--          and NOT drawn (score entries 21/22 both 0 wide), refilled to 48
--   ELBOWC walk in, HP (the elbow), then HP, LK, HK, LP: 5 hits (MK3 combo)
--   KNEEC  walk in, HK (the knee), then HK, LP: 3 hits
--          (each next button is pressed only after the last hit lands)
--   THROW  walk in, close LP         act 0507 (act_bodyslam), P1's bar drops
--          (his own MK3 throw, RBAIRSLAM - Sektor's needed an arm object)
--   AIRTH  both jump, P2 Block       act 0507 (act_bodyslam), P1's bar drops
-- Every phase also fails if ani2_clip moves (a frame list ran away and he
-- was not drawn - the landing did this when row 6 had no part 2).
-- PASS = right ochar, taps right, every check met, no reboot.
-- RS_NOTAP=1 is the control: no taps, P2 must fight as Reptile (9) - and
-- the run and combos must be HIS: the same RUN and ELBOWC phases are played
-- by Reptile and must both FAIL (he walks, Run is his extra Block; no 5-hit
-- chain), with no turbo bar drawn for either player.
-- Env: WB_LOG, WS_MAP.  Snapshots every 6 frames while a special runs.
-- RS_TRACE=1 logs his frame (oimg, first piece, inviso, ani2_clip) every tick;
-- RS_SNAPALL=1 snaps every tick; RS_ONLY=SPEAR,ELBOWC plays only those phases.
local LOG = os.getenv("WB_LOG")
local NOTAP = os.getenv("RS_NOTAP") == "1"
local TRACE = os.getenv("RS_TRACE") == "1"      -- per-tick frame log
local SNAPALL = os.getenv("RS_SNAPALL") == "1"  -- snapshot every tick, not every 6th
local ONLY = os.getenv("RS_ONLY")               -- comma list of phases to play
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p2_proc", "p1_bar", "p2_bar",
                    "illop_count", "f_rsmoke_cheat2", "rsmoke_pos", "p1_state", "p2_state",
                    "score_ram_end"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "1 Player Start", "2 Players Start", "P1 High Punch", "P2 High Punch",
               "P1 Up", "P2 Up", "P2 Left", "P2 Right", "P2 Low Punch", "P2 Low Kick", "P2 Block",
               "P2 Run", "P2 High Kick"}
local SNS = 32 * 6                         -- one score-area DMA entry, bits
local function entry(n) return A.score_ram_end - SNS * n end
local OXPOS, OYPOS = 0x090, 0x0b0
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then
        local all = {}
        for _, q in pairs(manager.machine.ioport.ports) do for k in pairs(q.fields) do all[#all + 1] = k end end
        log("fields: %s", table.concat(all, " | "))
        error("no input " .. n)
    end
end
local function done(fmt, ...) log(fmt, ...); f:close(); manager.machine:exit() end
local OFLAGS2, OCHAR, PACT, M_INVISO = 0x160, 0x1f0, 0x1f0, 0x20

-- select screen script: rel frame -> presses
local steps, t = {}, 100
local function press(n, at, len) steps[#steps + 1] = {at, at + (len or 6), n} end
local checks = {}
local bad = 0
checks[t] = function()
    local c = r16(A.p2_char)
    log("P2 cursor on %d", c)
    if c ~= 9 then done("FAIL P2 cursor on %d, not Reptile (9)", c) end
end
if not NOTAP then
    for i, want in ipairs({{1, 8}, {0, 0}, {1, 8}}) do
        press("2 Players Start", t + 10)
        checks[t + 70] = function()
            local fl, pos = r16(A.f_rsmoke_cheat2), r16(A.rsmoke_pos)
            log("tap %d: flag %d pos %d (want %d/%d)", i, fl, pos, want[1], want[2])
            if fl ~= want[1] or pos ~= want[2] then bad = bad + 1 end
            manager.machine.video:snapshot()
        end
        t = t + 80
    end
end
press("P1 High Punch", t + 10); press("P2 High Punch", t + 80)

-- fight script: {from, to, input} relative to the special's start
local SPECIALS = {
    {"INVIS", {{0, 34, "P2 Block"}, {6, 10, "P2 Up"}, {14, 18, "P2 Up"}, {22, 26, "P2 High Punch"}}},
    {"VISIB", {{0, 34, "P2 Block"}, {6, 10, "P2 Up"}, {14, 18, "P2 Up"}, {22, 26, "P2 High Punch"}}},
    {"SPEAR", {{0, 4, "P2 BACK"}, {6, 10, "P2 BACK"}, {8, 12, "P2 Low Punch"}}},
    {"TELE",  {{0, 4, "P2 FWD"}, {6, 10, "P2 FWD"}, {8, 12, "P2 Low Kick"}}},
    {"RUN",   {{0, 80, "P2 BACK"}, {90, 130, "P2 FWD"}, {92, 130, "P2 Run"}}},
    {"ELBOWC", {{0, 90, "P2 FWD"}}, react = {"P2 High Punch", "P2 High Punch", "P2 Low Kick",
                                             "P2 High Kick", "P2 Low Punch"}, want = 5},
    {"KNEEC",  {{0, 90, "P2 FWD"}}, react = {"P2 High Kick", "P2 High Kick", "P2 Low Punch"}, want = 3},
    {"THROW", {{0, 90, "P2 FWD"}, {96, 100, "P2 Low Punch"}}},
    {"AIRTH", {{0, 130, "P2 FWD"}, {140, 144, "P1 Up"}, {140, 144, "P2 Up"},
               {150, 152, "P2 Block"}, {156, 158, "P2 Block"}, {162, 164, "P2 Block"},
               {168, 170, "P2 Block"}}},
}
if NOTAP then
    local keep = {}
    for _, sp in ipairs(SPECIALS) do if sp[1] == "RUN" or sp[1] == "ELBOWC" then keep[#keep + 1] = sp end end
    SPECIALS = keep
end
if ONLY then
    local keep = {}
    for _, sp in ipairs(SPECIALS) do if ("," .. ONLY .. ","):find("," .. sp[1] .. ",", 1, true) then keep[#keep + 1] = sp end end
    SPECIALS = keep
end
do
    local at = 200
    for _, sp in ipairs(SPECIALS) do sp.start = at; sp.stop = at + 280; at = at + 320 end
end

local frame, started, sel, fight, ill0 = 0, false, nil, nil, nil
local res = {}
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
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
        if gs == 2 then fight = frame; log("fight at %d", frame) end
        if rel > 4000 then done("no fight - NO VERDICT") end
        return
    end
    local rel = frame - fight
    if r16(A.p2_bar) < 0x80 then w16(A.p2_bar, 0xa1) end
    if rel == 150 then
        manager.machine.video:snapshot()
        local p2o = r32(A.p2_obj)
        local och = p2o ~= 0 and r16(p2o + OCHAR) or -1
        local want = NOTAP and 9 or 24
        log("P2 ochar %d (want %d), %d bad taps", och, want, bad)
        if och ~= want or bad ~= 0 then done("FAIL P2 ochar %d (want %d), %d bad taps", och, want, bad) end
        if NOTAP then log("control: P2 fights as Reptile; now his run and combos must NOT happen") end
    end
    if rel < 150 then return end
    local p2o = r32(A.p2_obj)
    local proc = r32(A.p2_proc)
    local act = proc ~= 0 and r16(proc + PACT) or 0
    local inv = p2o ~= 0 and (r16(p2o + OFLAGS2) & M_INVISO) ~= 0
    for _, sp in ipairs(SPECIALS) do
        local d = rel - sp.start
        if d >= 0 and d < sp.stop - sp.start then
            local p1o = r32(A.p1_obj)
            local x1, x2 = r16(p1o + OXPOS), p2o ~= 0 and r16(p2o + OXPOS) or 0
            local fwd = x2 > x1 and "P2 Left" or "P2 Right"
            local back = x2 > x1 and "P2 Right" or "P2 Left"
            for _, s in ipairs(sp[2]) do
                if d >= s[1] and d < s[2] then
                    local n = s[3] == "P2 FWD" and fwd or s[3] == "P2 BACK" and back or s[3]
                    F[n]:set_value(1)
                end
            end
            if sp[1] == "AIRTH" and d >= 125 and d <= 175 and d % 3 == 0 then
                local gy = S.ground_y and r16(S.ground_y) or 0
                log("  AIRTH +%d dx %d  P1 y %d  P2 y %d  ground %d  P2 act %04x", d, x2 - x1,
                    r16(p1o + OYPOS), r16(p2o + OYPOS), gy, act)
            end
            if d == 0 then sp.bar0 = r16(A.p1_bar); sp.acts = {}; sp.k = 1; sp.hits = {}; sp.last = sp.bar0
                sp.clip0 = r16(S.ani2_clip) end
            if sp.react and os.getenv("RS_PCTRACE") and d >= 96 and d <= 130 then
                local pc = manager.machine.devices[":maincpu"].state["PC"].value
                log("  %s +%d PC %08x P2 act %04x P2 pwake %08x", sp[1], d, pc, act, r32(proc + 0x0e0))
            end
            if sp.react and d >= 95 then
                local b = r16(A.p1_bar)
                if b < sp.last then
                    sp.hits[#sp.hits + 1] = string.format("%d@%d", sp.last - b, d)
                    sp.k = sp.k + 1
                end
                sp.last = b
                local btn = sp.react[sp.k]
                if btn and (d % 4) < 2 then F[btn]:set_value(1) end
            end
            if sp[1] == "RUN" then
                -- his turbo, out of rs_turbo (p2's word, 16 bits in): the words
                -- sit on an odd byte, which the TMS34010 reads and MAME's Lua
                -- read_u16 (aligned down) does not - so two byte reads.  His bar
                -- is NOT drawn (rsturbobar 0, RSMOKEM.ASM): both widths must be 0
                local ta = S.rs_turbo + 16
                local tb = space:read_u8(ta) | (space:read_u8(ta + 8) << 8)
                if d == 100 then sp.x0 = x2 end
                if d == 120 then sp.speed = math.abs(x2 - sp.x0) / 20 end
                if d == 125 then
                    sp.spent = tb
                    sp.w22 = r16(entry(22) + 32 * 3); sp.w21 = r16(entry(21) + 32 * 3)
                end
                if d == 275 then sp.refill = tb end
            end
            if act ~= sp.lastact then
                sp.acts[#sp.acts + 1] = string.format("%04x@%d", act, d); sp.lastact = act
            end
            if inv then sp.inv = true end
            if d > 60 and not inv then sp.vis = true end
            if TRACE and p2o ~= 0 then
                -- RS_TRACE=1: his frame every tick - the multipart frame
                -- pointer (oimg), the first piece's record, inviso, ani2 guard
                local img = r32(p2o + 0x1a0)
                local pc1 = img ~= 0 and r32(img) or 0
                log("  T %s +%d act %04x img %08x p1 %08x inv %s clip %d", sp[1], d, act, img, pc1,
                    tostring(inv), r16(S.ani2_clip))
            end
            if d % (SNAPALL and 1 or 6) == 0 then manager.machine.video:snapshot() end
        end
        if d == sp.stop - sp.start then
            local drop = sp.bar0 - r16(A.p1_bar)
            local acts = table.concat(sp.acts, " ")
            local ok
            if sp[1] == "INVIS" then ok = inv
            elseif sp[1] == "VISIB" then ok = not inv
            elseif sp[1] == "SPEAR" then ok = acts:find("0011@") ~= nil and drop > 0
            elseif sp[1] == "TELE" then ok = acts:find("020a@") ~= nil and acts:find("0107@") ~= nil and drop > 0
            elseif sp[1] == "AIRTH" or sp[1] == "THROW" then ok = acts:find("0507@") ~= nil and drop > 0
            elseif sp[1] == "RUN" then
                ok = sp.speed and sp.speed >= 6 and sp.speed <= 8 and sp.spent < 48
                     and sp.w22 == 0 and sp.w21 == 0 and sp.refill == 48
                log("  RUN: %.2f px/tick, turbo %s at the run's end, his bar %s wide (want 0, not drawn), P1's %s, %s after the refill",
                    sp.speed or -1, tostring(sp.spent), tostring(sp.w22), tostring(sp.w21), tostring(sp.refill))
            elseif sp.react then
                ok = #sp.hits == sp.want
                log("  %s: %d hits (want %d): %s", sp[1], #sp.hits, sp.want, table.concat(sp.hits, " "))
            end
            local clip = r16(S.ani2_clip) - sp.clip0
            if clip ~= 0 then log("  %s: ani2_clip +%d - a frame list ran away (he vanished)", sp[1], clip); ok = false end
            res[#res + 1] = ok and "" or sp[1]
            log("%s: %s - P2 acts %s; P1 bar %d -> %d (-%d); invisible now %s",
                sp[1], ok and "ok" or "MISSED", acts, sp.bar0, r16(A.p1_bar), drop, tostring(inv))
            if r16(A.p1_bar) < 0x50 then w16(A.p1_bar, 0xa1) end
        end
    end
    if rel == SPECIALS[#SPECIALS].stop + 10 then
        local miss = {}
        for _, m in ipairs(res) do if m ~= "" then miss[#miss + 1] = m end end
        if NOTAP then
            if #miss == #SPECIALS then done("PASS control: Reptile neither runs nor chains Smoke's combo, no turbo bar")
            else done("FAIL control: Reptile got Smoke's run or combo") end
        elseif #miss == 0 then done("PASS robot Smoke picked by the START tap on Reptile; all specials worked, no reboot")
        else done("FAIL: %s", table.concat(miss, ",")) end
    end
end)
