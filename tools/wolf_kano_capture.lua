-- wolf_kano_capture.lua - snapshots of MK1 Kano's crouch, flip kick, cannonball and
-- knife impact on the Wolf ROM, to set beside MK1's own.  Env as wolf_kano_mk1_check.lua.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_kano_capture start")

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

local NAME = {}
do
    local lab
    for l in io.lines(os.getenv("WS_TBL")) do
        local nm = l:match("^(%w+):")
        if nm then lab = nm end
        local h = l:match("%.long%s+0?(%x+)[hH]")
        if lab and h and #h >= 7 then NAME[tonumber(h, 16)] = lab; lab = nil end
    end
end
local function first_name(o)
    local node = r32(o + O.oimg)
    return node ~= 0 and (NAME[r32(node)] or "?") or "?"
end
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local pt, step = 0, 1
local function place(p1o, p2o, d)
    local nx = r16(p1o + O.oxpos) + d
    w16(p2o + O.oxpos, nx); space:write_u32(p2o + 0x080, (nx << 16) & 0xffffffff)
end
local function done(msg) log(msg); f:close(); manager.machine:exit() end
local function press(names) for _, n in ipairs(names) do F[n]:set_value(1) end end
local function snap(tag) manager.machine.video:snapshot(); log("snap %s", tag) end
-- {name, ticks, setup distance, function(s) inputs, snapshot ticks}
local STEPS = {
    {"walk_fwd", 100, 360, function(s) if s >= 20 and s < 90 then press({"P1 Right"}) end end, {}},
    {"walk_back", 100, 150, function(s) if s >= 20 and s < 60 then press({"P1 Left"}) end end, {}},
    {"jump_up", 120, 300, function(s) if s >= 40 and s < 46 then press({"P1 Up"}) end end, {}},
    {"flip_fwd", 120, 360, function(s) if s >= 40 and s < 46 then press({"P1 Up", "P1 Right"}) end end, {}},
    {"flip_back", 120, 300, function(s) if s >= 40 and s < 46 then press({"P1 Up", "P1 Left"}) end end, {}},
    {"flip_fwd2", 120, 360, function(s) if s >= 40 and s < 46 then press({"P1 Up", "P1 Right"}) end end, {}},
    {"flip_fwd3", 120, 360, function(s) if s >= 40 and s < 46 then press({"P1 Up", "P1 Right"}) end end, {}},
    {"flip_back2", 120, 300, function(s) if s >= 40 and s < 46 then press({"P1 Up", "P1 Left"}) end end, {}},
    {"knife0", 110, 140, function(s)
        if s >= 10 and s < 14 then press({"P1 Block"}) end
        if s >= 14 and s < 18 then press({"P1 Block", "P1 Left"}) end
        if s >= 18 and s < 20 then press({"P1 Block"}) end
        if s >= 20 and s < 24 then press({"P1 Block", "P1 Right"}) end
     end, {}},
    {"duck", 70, 160, function(s) if s >= 10 and s < 60 then press({"P1 Down"}) end end, {40}},
    {"flipkick", 90, 200, function(s)
        if s >= 10 and s < 16 then press({"P1 Up", "P1 Right"}) end
        if s >= 26 and s < 30 then press({"P1 High Kick"}) end
     end, {26, 30, 34, 38, 42, 46, 50, 54}},
    {"ball", 120, 160, function(s)
        if s >= 10 and s < 16 then press({"P1 Block"}) end
        if s >= 16 and s < 19 then press({"P1 Block", "P1 Right"}) end
        if s >= 19 and s < 22 then press({"P1 Block", "P1 Down"}) end
        if s >= 22 and s < 25 then press({"P1 Block", "P1 Left"}) end
        if s >= 25 and s < 28 then press({"P1 Block", "P1 Up"}) end
     end, {34, 40, 44, 48, 52, 56, 60, 66, 72, 78, 84}},
    {"knife", 110, 140, function(s)
        if s >= 10 and s < 14 then press({"P1 Block"}) end
        if s >= 14 and s < 18 then press({"P1 Block", "P1 Left"}) end
        if s >= 18 and s < 20 then press({"P1 Block"}) end
        if s >= 20 and s < 24 then press({"P1 Block", "P1 Right"}) end
     end, {}},
}
local hit_t, y0, arc_x0, arc_y0, wx0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
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
            if r16(A.p1_state) ~= 0 then w16(A.p2_state, r16(A.p1_state)) end   -- p2 human at select
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count) end
        if frame > 12000 then done("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done("FAIL a reboot"); return end
    if r16(A.p1_state) ~= 0 and r16(A.p2_state) == 0 then
        w16(A.p2_state, r16(A.p1_state))   -- P2 an idle HUMAN, never the CPU, however the start went
    end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 or gs ~= 2 then return end
    if r16(A.p1_bar) < 60 then w16(A.p1_bar, 0xa1) end
    if r16(A.p2_bar) < 60 then w16(A.p2_bar, 0xa1) end
    w16(S.f_freeze_timer, 1)
    if r16(p1o + O.ochar) ~= 22 then
        local k = frame % 60
        F["P1 Left"]:set_value(k < 4 and 1 or 0)
        F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
        F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        pt = 0
        return
    end
    local st = STEPS[step]
    if not st then done("DONE"); return end
    pt = pt + 1
    if pt == 1 then place(p1o, p2o, st[3]); hit_t, y0 = nil, r16(p1o + 0x0b0); log("== %s", st[1]) end
    st[4](pt)
    for _, k in ipairs(st[5]) do if pt == k then snap(st[1] .. "+" .. k) end end
    local n = first_name(p1o)
    if st[1] == "ball" and pt >= 28 and pt % 2 == 0 then
        log("  ball +%d %s x %d y %+d", pt, n, r16(p1o + O.oxpos), r16(p1o + 0x0b0) - y0)
    end
    if st[1]:match("^walk_") and pt >= 18 and pt <= 92 then
        log("  WALKX %s %d %d act %04x flip %d jax %d", st[1], pt, r16(p1o + O.oxpos), r16(r32(A.p1_proc) + 0x1f0),
            (r16(p1o + O.oflags) >> 4) & 1, r16(p2o + O.oxpos))
    end
    if st[1] == "jump_up" or st[1]:match("^flip_") then
        if pt == 1 then arc_x0, arc_y0 = r16(p1o + O.oxpos), r16(p1o + 0x0b0) end
        if pt >= 36 then
            local dy = (arc_y0 - r16(p1o + 0x0b0) + 0x8000) % 0x10000 - 0x8000
            log("  ARC %s %d %d %d x0 %d act %04x flip %d jax %d", st[1], pt, r16(p1o + O.oxpos) - arc_x0, dy, arc_x0,
                r16(r32(A.p1_proc) + 0x1f0), (r16(p1o + O.oflags) >> 4) & 1, r16(p2o + O.oxpos))
        end
    end
    if st[1] == "duck" and pt == 40 then log("  duck pose %s", n) end
    if st[1] == "flipkick" and pt >= 24 and pt <= 60 and pt % 2 == 0 then log("  flip +%d %s", pt, n) end
    if st[1]:match("^knife") then
        for _, l in ipairs({A.objlst, A.objlst2, A.objlst3}) do
            local o = r32(l)
            for _ = 1, 200 do
                if o == 0 then break end
                local n = first_name(o)
                if n:match("^KNKNIFE") and pt % 2 == 0 then
                    log("  knife +%d %s x %d xvel %08x flip %d | jax x %d", pt, n, r16(o + O.oxpos),
                        r32(o + 0x040), (r16(o + O.oflags) >> 4) & 1, r16(p2o + O.oxpos))
                end
                if n:match("^KNKNIFEHIT") then hit_t = hit_t or pt end
                o = r32(o + O.olink)
            end
        end
        if hit_t and (pt - hit_t) % 3 == 0 and pt - hit_t <= 21 then snap("knife impact+" .. (pt - hit_t)) end
    end
    if pt >= st[2] then step = step + 1; pt = 0 end
end)
