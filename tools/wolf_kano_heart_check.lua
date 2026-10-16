-- wolf_kano_heart_check.lua - MK1 KANO's HEART RIP (Wolf, ochar 22) against MK1.
--
-- P1 Shang becomes Kano each round (Back, Forward + Block), beats an idle Jax
-- (his bar held at 1), and at FINISH HIM in round 2 does Back, Down, Forward +
-- Low Punch.  Checks what tools/run_mk1_kano_probe.ps1 -Win -Heart measured:
--   * the HEART is an object of its own, every tick on KNHEART_P, on HIS
--     anchor (its anipoints put it in his raised fist);
--   * it reaches its beating frames (5, 6, 7);
--   * MK1's tearing sound, then lub / dub alternating, lub first, at least
--     twelve of them, lub to lub 40-44 ticks (MK1: 42) - and he is still Kano.
-- Env as tools/wolf_kano_mk1_check.lua.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_kano_heart_check start")

local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
-- every record's SAG in his pack, by family
local FAM = {}            -- sag -> "hand" | "flight" | "hit"
do
    local lab
    for l in io.lines(os.getenv("WS_TBL")) do
        local nm = l:match("^(%w+):")
        if nm then lab = nm end
        local h = l:match("%.long%s+0?(%x+)[hH]")
        if lab and h and #h >= 7 then
            local fam
            if lab:match("^KNHEART%d+%u$") then fam = lab:match("^KNHEART(%d+)") end
            if fam then FAM[tonumber(h, 16)] = fam end
            lab = nil
        end
    end
end
-- his MK1 tracks: the channel-1 track of each mk1kn_ row
local TRK = {}
for l in io.lines(os.getenv("WS_SND")) do
    local t, key = l:match("%.word%s+%x+h|%d+,0?(%x+)h%s*;%s*%x+%s+(mk1kn_[%w_]+)")
    if t then local n = tonumber(t, 16); TRK[n] = key; TRK[n + 1] = key; TRK[n + 2] = key end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "curback",
                    "illop_count", "p1_bar", "p2_bar", "p1_state", "p2_state", "objlst", "objlst2", "objlst3", "palram",
                    "KNHEART_P", "winner_status"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { olink = 0, oxpos = 0x090, oflags = 0x0f0, opal = 0x140, oimg = 0x1a0, ochar = 0x1f0 }
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 High Kick", "P1 Low Kick", "P1 Block", "P1 Up", "P1 Down", "P1 Left", "P1 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end

-- drawn left/right of a multipart object (shape RAM: mp_sizex at 20h, mp_anix at 50h)
local function bounds(o)
    local node, x0 = r32(o + O.oimg), r16(o + O.oxpos)
    local lo, hi = 1e9, -1e9
    for _ = 1, 16 do
        if node == 0 or r32(node) == 0 then break end
        local w = r16(node + 0x20)
        local ax = (r16(node + 0x50) + 0x8000) % 0x10000 - 0x8000
        lo = math.min(lo, x0 - ax); hi = math.max(hi, x0 - ax + w)
        node = node + 112
    end
    return lo, hi
end
local function pal_of(o) return r32(A.palram + ((r16(o + O.opal) >> 8) & 0xff) * 0x40) end
-- THE HOLD: the last 80 ticks before the heart appears - how far the fist's
-- end is inside the victim's near edge, and the palette the victim is on
local hold, vic_pal0 = {}, nil
local OSAG = 0x100
-- THE DRIPS: MKBLOOD's bludglob records (the Wolf build's own table, beside its map)
local GLOB, drips_seen, drip_ticks = {}, 0, 0
do
    local lab
    for l in io.lines((os.getenv("WS_MAP"):gsub("[^/\\]+$", "MKBLOOD.TBL"))) do
        local nm = l:match("^(%w+):")
        if nm then lab = nm end
        local h = l:match("%.long%s+0?(%x+)[hH]")
        if lab and h and #h >= 7 then
            if lab:match("^bludglob%d+$") then GLOB[tonumber(h, 16)] = true end
            lab = nil
        end
    end
end
local function count_drips()
    local n = 0
    for _, l in ipairs({A.objlst, A.objlst2, A.objlst3}) do
        local o = r32(l)
        for _ = 1, 200 do
            if o == 0 then break end
            if GLOB[r32(o + OSAG)] then n = n + 1 end
            o = r32(o + O.olink)
        end
    end
    return n
end

local function heart_obj()
    for _, l in ipairs({A.objlst, A.objlst2, A.objlst3}) do
        local o = r32(l)
        for _ = 1, 200 do
            if o == 0 then break end
            local node = r32(o + O.oimg)
            if node ~= 0 then
                local fam = FAM[r32(node)]
                if fam then return o, fam end
            end
            o = r32(o + O.olink)
        end
    end
end

local sounds, prevb, beats = {}, nil, {}
local frame = 0
_G.kn_heart_tap = space:install_write_tap(0x01680000, 0x0168001f, "knhrt", function(o, d, m)
    local v = d & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    local k = TRK[c]
    if k then
        sounds[k] = (sounds[k] or 0) + 1
        if k:match("heart_[ld]ub") and (#beats == 0 or beats[#beats][2] ~= frame) then
            beats[#beats + 1] = {k:match("heart_(%a+)"), frame}
        end
    end
    return d
end)

local started, sel, fight, confirm, ill0 = false, nil, nil, nil, nil
local round, last_gs, fin_f, rip_f, hticks, hbad, hfams, hdy, snaps = 0, -1, nil, nil, 0, 0, {}, nil, 0
local hold_ok = false
local function done(msg) log(msg); f:close(); manager.machine:exit() end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("KNHEART_P %08X", A.KNHEART_P)
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0)
            if r16(A.p1_state) ~= 0 then w16(A.p2_state, r16(A.p1_state)) end   -- p2 human at select   -- Shang v Jax, Dead Pool
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); log("fight at %d", frame) end
        if frame > 12000 then done("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done(string.format("FAIL illop_count moved at %d (a reboot)", frame)); return end
    if gs ~= last_gs then
        if gs == 2 then round = round + 1; log("round %d fighting at %d", round, frame) end
        last_gs = gs
    end
    if r16(A.p1_state) ~= 0 and r16(A.p2_state) == 0 then
        w16(A.p2_state, r16(A.p1_state))   -- P2 an idle HUMAN, never the CPU, however the start went
    end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local och = r16(p1o + O.ochar)
    local ws = r16(A.winner_status)
    w16(A.p1_bar, 0xa1)

    -- the heart, every tick it exists
    local ho, fam = heart_obj()
    if not ho and not rip_f then
        if ws == 0 then vic_pal0 = pal_of(p2o) end          -- his costume, in the fight
        local k0, k1 = bounds(p1o)
        local v0, v1 = bounds(p2o)
        hold[#hold + 1] = {k1 - v0, pal_of(p2o)}
        if #hold > 80 then table.remove(hold, 1) end
    end
    if ho then
        if not rip_f then
            -- the fist is in for 64 ticks before the heart: judge ticks -60..-6
            local lo, hi, badpal = 1e9, -1e9, 0
            for i = math.max(1, #hold - 60), #hold - 6 do
                lo = math.min(lo, hold[i][1]); hi = math.max(hi, hold[i][1])
                if hold[i][2] ~= vic_pal0 then badpal = badpal + 1 end
            end
            hold_ok = lo >= 8 and hi <= 16 and hi - lo == 2 and badpal == 0
            log("HOLD: fist end %d..%d px inside his near edge (MK1 11..15; ours shakes 2 px); victim off his own palette on %d ticks -> %s",
                lo, hi, badpal, hold_ok and "ok" or "BAD")
        end
        rip_f = rip_f or frame
        hticks = hticks + 1
        hfams[fam] = true
        local map = (r16(ho + O.opal) >> 8) & 0xff
        local pal = r32(A.palram + map * 0x40)
        if pal ~= A.KNHEART_P then
            hbad = hbad + 1
            if hbad <= 3 then log("BAD PALETTE: heart frame %s on map %d = %08X", fam, map, pal) end
        end
        if not hdy then
            hdy = (r16(ho + 0x0b0) - r16(p1o + 0x0b0) + 0x8000) % 0x10000 - 0x8000
            log("heart out at %d: frame %s, map %d (%08X), y %+d from his object", frame, fam, map, pal, hdy)
        end
        local rel = frame - rip_f
        local nd = count_drips()
        if nd > 0 then drip_ticks = drip_ticks + 1 end
        drips_seen = math.max(drips_seen, nd)
        if rel % 10 == 5 and rel < 130 then
            -- where the heart is drawn, off HIS object's x / y (for the drips)
            local node, lo, hi, top, bot = r32(ho + O.oimg), 1e9, -1e9, 1e9, -1e9
            local hx, hy = r16(ho + O.oxpos), r16(ho + 0x0b0)
            for _ = 1, 16 do
                if node == 0 or r32(node) == 0 then break end
                local w, h = r16(node + 0x20), r16(node + 0x30)
                local ay = (r16(node + 0x60) + 0x8000) % 0x10000 - 0x8000
                local ax = (r16(node + 0x50) + 0x8000) % 0x10000 - 0x8000
                lo = math.min(lo, hx - ax); hi = math.max(hi, hx - ax + w)
                top = math.min(top, hy - ay); bot = math.max(bot, hy - ay + h)
                node = node + 112
            end
            log("HEART AT rip+%d frame %s: x %+d..%+d  y %+d..%+d off his object (flip %d)", rel, fam,
                lo - r16(p1o + O.oxpos), hi - r16(p1o + O.oxpos), top - r16(p1o + 0x0b0), bot - r16(p1o + 0x0b0),
                (r16(p1o + O.oflags) >> 4) & 1)
        end
        if snaps < 6 and (rel == 12 or rel == 45 or rel == 62 or rel == 72 or rel == 84 or rel == 150) then
            snaps = snaps + 1; manager.machine.video:snapshot(); log("snapshot at rip+%d (heart frame %s)", rel, fam)
        end
        if rel >= 420 then
            local seq, gaps = {}, {}
            for i, b in ipairs(beats) do
                seq[#seq + 1] = b[1]
                if i > 1 then gaps[#gaps + 1] = b[2] - beats[i - 1][2] end
            end
            log("beats: %s", table.concat(seq, " "))
            log("gaps:  %s", table.concat(gaps, " "))
            local fl = {}; for k in pairs(hfams) do fl[#fl + 1] = k end; table.sort(fl)
            log("heart frames seen: %s; on screen %d ticks, %d NOT on KNHEART_P", table.concat(fl, " "), hticks, hbad)
            local alt, period = true, true
            for i = 2, #beats do if beats[i][1] == beats[i - 1][1] then alt = false end end
            for i = 3, #beats do
                local p = beats[i][2] - beats[i - 2][2]
                if p < 40 or p > 44 then period = false end
            end
            log("drips off the heart: on screen %d of %d ticks, up to %d at once", drip_ticks, hticks, drips_seen)
            local ok = hold_ok and drip_ticks >= 60 and sounds.mk1kn_heart_rip and #beats >= 12 and beats[1][1] == "lub" and alt and period
                and hbad == 0 and hdy == 0 and hfams["5"] and hfams["6"] and hfams["7"] and och == 22
            done(ok and "PASS" or "FAIL")
        end
        return
    end
    if rip_f then
        done(string.format("FAIL the heart was gone %d ticks after it came out (ochar %d, gstate %d)", frame - rip_f, och, gs))
        return
    end

    if gs ~= 2 then return end
    if och ~= 22 then                       -- become Kano (again, each round)
        local k = frame % 60
        F["P1 Left"]:set_value(k < 4 and 1 or 0)
        F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
        F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        return
    end
    if ws == 0 then                         -- beat him: his bar held at 1, walk in punching
        if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
        F["P1 Right"]:set_value(1)
        F["P1 High Punch"]:set_value((frame % 16) < 3 and 1 or 0)
        fin_f = nil
    elseif ws == 3 then                     -- FINISH HIM: Back, Down, Forward + Low Punch, close
        fin_f = fin_f or frame
        local rel = frame - fin_f
        local x1, x2 = r16(p1o + O.oxpos), r16(p2o + O.oxpos)
        if rel == 30 then                   -- stand him in reach, on the side he already is
            local nx = (x2 > x1) and (x1 + 50) or (x1 - 50)
            w16(p2o + O.oxpos, nx); space:write_u32(p2o + 0x080, (nx << 16) & 0xffffffff)
        end
        if rel >= 40 then
            local t = (rel - 40) % 50
            local back, fwd = "P1 Left", "P1 Right"
            if x2 < x1 then back, fwd = fwd, back end
            if t == 0 then log("heart rip input at %d (distance %d)", frame, math.abs(x2 - x1)) end
            F[back]:set_value(t < 4 and 1 or 0)
            F["P1 Down"]:set_value((t >= 5 and t < 9) and 1 or 0)
            F[fwd]:set_value((t >= 10 and t < 16) and 1 or 0)
            F["P1 Low Punch"]:set_value((t >= 12 and t < 16) and 1 or 0)
        end
        if rel > 600 then done("FAIL the heart rip never came out") end
    end
    if frame - fight > 14000 then done("FAIL out of frames") end
end)
