-- wolf_kano_mk1_check.lua - MK1 KANO (Wolf, ochar 22) against MK1 itself.
--
-- Morphs P1 Shang into Kano (Back, Forward + Block) against an idle P2 Jax and
-- checks what tools/run_mk1_kano_probe.ps1 measured in MAME `mk`:
--   * THE KNIFE'S PALETTE: every tick a knife object is on screen, its colour
--     map (opal bits 8-15) must hold KNKNIFE_P in palram - not his costume;
--   * ITS LANES: the in-hand frames (KNKNIFE1-3) first, then the flight;
--   * THE IMPACT is logged (it is centred on the victim's body now - the
--     user's call - and tools/wolf_kano_moves_check.lua checks that);
--   * HIS SPECIALS' SOUNDS: every code on the sound port in his MK1 track
--     range, named from src/WOLFSND.ASM - knife throw, knife hit, cannonball
--     roll and yell.  (His voice is MK2's standard male set - the user's call.)
-- Env: WB_LOG, WS_MAP (the Wolf build's MK2.MAP), WS_TBL (src/MK1KNO.TBL),
--      WS_SND (src/WOLFSND.ASM).  Launch through tools/run_wolf_boot_probe.ps1.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_kano_mk1_check start")

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
            if lab:match("^KNKNIFEHIT") then fam = "hit"
            elseif lab:match("^KNKNIFE[123]%u$") then fam = "hand"
            elseif lab:match("^KNKNIFE%d+%u$") then fam = "flight" end
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
                    "KNKNIFE_P"}) do
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

-- the knife: any object on the three lists whose first piece is one of its records
local function knife_obj()
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

local sounds, prevb = {}, nil
_G.kn_mk1_tap = space:install_write_tap(0x01680000, 0x0168001f, "knmk1", function(o, d, m)
    local v = d & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if TRK[c] then sounds[TRK[c]] = (sounds[TRK[c]] or 0) + 1 end
    return d
end)

local frame, started = 0, false
local sel, fight, confirm, morph_f, ill0
local knife_ticks, knife_badpal, fams_seen, order = 0, 0, {}, {}
local last_flight_x, hit_back, last_fam, hit_snap, hit_n
-- after the morph: three knives from range, the cannonball, then normals up close
local SCRIPT = {{40, {}}}
local function add(...) for _, s in ipairs({...}) do SCRIPT[#SCRIPT + 1] = s end end
for _ = 1, 3 do
    add({1, {}, "far"}, {4, {"P1 Block"}}, {4, {"P1 Block", "P1 Left"}}, {2, {"P1 Block"}},
        {4, {"P1 Block", "P1 Right"}}, {110, {}})
end
add({1, {}, "far"}, {4, {"P1 Block"}}, {4, {"P1 Block", "P1 Right"}}, {4, {"P1 Block", "P1 Down"}},
    {4, {"P1 Block", "P1 Left"}}, {4, {"P1 Block", "P1 Up"}}, {110, {}})
for _ = 1, 3 do
    for _, b in ipairs({"P1 High Punch", "P1 Low Punch", "P1 High Kick", "P1 Low Kick"}) do
        add({1, {}, "near"}, {5, {b}}, {35, {}})
    end
end
local si, st = 1, 0

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
        local n = 0; for _ in pairs(FAM) do n = n + 1 end
        local k = {}; for t, key in pairs(TRK) do if t % 3 == 0 or true then k[key] = t end end
        log("knife records %d; KNKNIFE_P %08X", n, A.KNKNIFE_P)
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
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    local rel = frame - fight
    if r16(A.p1_state) ~= 0 and r16(A.p2_state) == 0 then
        w16(A.p2_state, r16(A.p1_state))   -- P2 an idle HUMAN, never the CPU, however the start went
    end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local och = r16(p1o + O.ochar)
    if r16(A.p1_bar) < 60 then w16(A.p1_bar, 0xa1) end
    if r16(A.p2_bar) < 60 then w16(A.p2_bar, 0xa1) end
    if not morph_f then
        if rel >= 40 then
            local k = (rel - 40) % 60
            F["P1 Left"]:set_value(k < 4 and 1 or 0)
            F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
            F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        end
        if och == 22 then morph_f = frame; log("MORPHED to Kano at +%d", rel) end
        if rel > 900 then log("FAIL the morph never happened"); f:close(); manager.machine:exit() end
        return
    end
    local t = frame - morph_f
    if och ~= 22 then           -- Shang's morph timer took him back: morph again, script paused
        local k = frame % 60
        F["P1 Left"]:set_value(k < 4 and 1 or 0)
        F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
        F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        if frame - morph_f > 6000 then log("FAIL he never came back as Kano"); f:close(); manager.machine:exit() end
        return
    end

    -- the knife, every tick it exists
    local ko, fam = knife_obj()
    if ko then
        knife_ticks = knife_ticks + 1
        local map = (r16(ko + O.opal) >> 8) & 0xff
        local pal = r32(A.palram + map * 0x40)
        if pal ~= A.KNKNIFE_P then
            knife_badpal = knife_badpal + 1
            if knife_badpal <= 3 then log("BAD PALETTE: knife (%s) on map %d = %08X at +%d", fam, map, pal, t) end
        end
        local x = r16(ko + O.oxpos)
        -- snapshots of the FIRST knife: the last flight tick and impact ticks 1, 2, 4, 9
        if not hit_snap then
            hit_n = (fam == "hit") and (hit_n or 0) + 1 or hit_n
            local want = (fam == "flight") and false or ({[1] = true, [2] = true, [4] = true, [9] = true})[hit_n or 0]
            if want then manager.machine.video:snapshot(); log("snapshot: impact tick %d at +%d", hit_n, t) end
            if (hit_n or 0) >= 9 then hit_snap = true end
        end
        if fam ~= last_fam then
            order[#order + 1] = fam
            log("knife %s at +%d x=%d map %d (%08X) victim x=%d", fam, t, x, map, pal, r16(p2o + O.oxpos))
            if fam == "hit" and last_flight_x then
                local back = x - last_flight_x
                if r16(ko + O.oflags) & 0x10 ~= 0 then back = -back end    -- facing left
                hit_back = hit_back or back
                log("  impact frame anchor moved %+d px from the last flight tick", back)
            end
        end
        if fam == "flight" then last_flight_x = x end
        fams_seen[fam] = true
        last_fam = fam
    else
        last_fam = nil
    end

    -- the script
    if si <= #SCRIPT then
        local s = SCRIPT[si]
        if s[3] and st == 0 then        -- place the victim: far for the specials, near for normals
            local x1 = r16(p1o + O.oxpos)
            local d = (s[3] == "far") and 170 or 60
            local nx = x1 + d
            w16(p2o + O.oxpos, nx); space:write_u32(p2o + 0x080, (nx << 16) & 0xffffffff)
        end
        for _, n in ipairs(s[2]) do F[n]:set_value(1) end
        st = st + 1
        if st >= s[1] then si = si + 1; st = 0 end
    end
    if r16(A.illop_count) ~= ill0 then log("FAIL illop_count moved at +%d (a reboot)", t); f:close(); manager.machine:exit(); return end
    if si > #SCRIPT then
        local ks, grunts = {}, 0
        for k, n in pairs(sounds) do ks[#ks + 1] = string.format("%s x%d", k, n); if k:match("attack") then grunts = grunts + 1 end end
        table.sort(ks)
        log("knife on screen %d ticks, %d of them NOT on KNKNIFE_P", knife_ticks, knife_badpal)
        log("knife lanes in order: %s", table.concat(order, " "))
        log("impact pulled back: %s", tostring(hit_back))
        log("his MK1 sounds: %s", #ks > 0 and table.concat(ks, ", ") or "none")
        local ok = knife_ticks > 20 and knife_badpal == 0 and order[1] == "hand" and fams_seen.flight
            and fams_seen.hit
            and sounds.mk1kn_knife_throw and sounds.mk1kn_knife_stab and sounds.mk1kn_ball_roll
            and sounds.mk1kn_ball_go and grunts == 0  -- his voice is MK2's male set (MK1's ball has no yell)
        log(ok and "PASS" or "FAIL")
        f:close(); manager.machine:exit()
    end
end)
