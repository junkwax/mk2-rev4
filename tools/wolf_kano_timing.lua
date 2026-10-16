-- wolf_kano_timing.lua - MK1 KANO's normals on the Wolf ROM, timed and measured
-- the way tools/mk1_kano_timing_probe.lua measures MK1: Kano (P1, Shang
-- morphed) against an idle human Jax, walking in to a gap before each move,
-- direction held first.  KT_WHO=jax has Jax hit HIM instead.  P lines: both
-- drawn extents and the records Kano is drawn on; read with
-- tools/kano_timing_compare.py.  Env as tools/wolf_kano_mk1_check.lua.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_kano_timing start")

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
local function piecekey(o)
    local node, t = r32(o + O.oimg), {}
    for _ = 1, 16 do
        if node == 0 or r32(node) == 0 then break end
        t[#t + 1] = NAME[r32(node)] or string.format("%x", r32(node))
        node = node + 112
    end
    return table.concat(t, "+")
end
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
-- the same script as tools/mk1_kano_timing_probe.lua: {who, name, dir, button, gap}
local KANO_MOVES = {
  {"kano", "hipunch_close", nil, "High Punch", 8}, {"kano", "hikick_close", nil, "High Kick", 8},
  {"kano", "hipunch", nil, "High Punch", 34}, {"kano", "lopunch", nil, "Low Punch", 34}, {"kano", "hikick", nil, "High Kick", 40},
  {"kano", "lokick", nil, "Low Kick", 40}, {"kano", "uppercut", "Down", "High Punch", 12}, {"kano", "duckkick", "Down", "Low Kick", 24},
  {"kano", "duckhikick", "Down", "High Kick", 24}, {"kano", "sweep", "away", "Low Kick", 24}, {"kano", "roundhouse", "away", "High Kick", 24},
  {"kano", "hp_g12", nil, "High Punch", 12}, {"kano", "hk_g10", nil, "High Kick", 10}, {"kano", "hk_g4", nil, "High Kick", 4},
}
local JAX_MOVES = {
  {"jax", "hipunch", nil, "High Punch", 30}, {"jax", "hikick", nil, "High Kick", 36}, {"jax", "lokick", nil, "Low Kick", 36},
  {"jax", "uppercut", "Down", "High Punch", 12}, {"jax", "sweep", "away", "Low Kick", 24}, {"jax", "roundhouse", "away", "High Kick", 24},
}
-- KT_WHO=flip: his flips, back and forth across the stage - J lines log his x
-- and the camera's every tick, for whether the SCREEN keeps step with him
local FLIP_MOVES = {
  {"kano", "flip1", "flipR", nil, 999}, {"kano", "flip2", "flipR", nil, 999}, {"kano", "flip3", "flipL", nil, 999},
  {"kano", "flip4", "flipL", nil, 999}, {"kano", "flip5", "flipR", nil, 999}, {"kano", "flip6", "flipL", nil, 999},
}
local KT = os.getenv("KT_WHO")
local MOVES = (KT == "jax") and JAX_MOVES or (KT == "flip") and FLIP_MOVES or KANO_MOVES
local function key(who, what)
    local p = (who == "kano") and "P1 " or "P2 "
    if what == "toward" then return p .. ((who == "kano") and "Right" or "Left") end
    if what == "away" then return p .. ((who == "kano") and "Left" or "Right") end
    return p .. what
end
local ALLIN = {}
for _, q in pairs(manager.machine.ioport.ports) do for n, fld in pairs(q.fields) do ALLIN[n] = fld end end

local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local mi, phase, pt, move = 1, "approach", 0, "-"
local function done(msg) log(msg); f:close(); manager.machine:exit() end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
    end
    frame = frame + 1
    for _, fld in pairs(ALLIN) do fld:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        ALLIN["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        ALLIN["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0)
            if r16(A.p1_state) ~= 0 then w16(A.p2_state, r16(A.p1_state)) end
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                ALLIN["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                ALLIN["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count) end
        if frame > 12000 then done("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done("FAIL a reboot"); return end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 or gs ~= 2 then return end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    w16(S.f_freeze_timer, 1)
    if r16(p1o + O.ochar) ~= 22 then               -- (re)become Kano; the script waits
        local k = frame % 60
        ALLIN["P1 Left"]:set_value(k < 4 and 1 or 0)
        ALLIN["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
        ALLIN["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        if phase == "go" then phase, pt = "approach", 0 end
        return
    end
    local k0, k1 = bounds(p1o)
    local s0, s1 = bounds(p2o)
    log("P %d %d %d %d %d %s", frame, k0, k1, s0, s1, piecekey(p1o))
    local mv = MOVES[mi]
    if not mv then done("DONE"); return end
    local who, name, dir, btn, want = mv[1], mv[2], mv[3], mv[4], mv[5]
    pt = pt + 1
    if phase == "approach" then
        move = "approach"
        if s0 - k1 > want and pt < 150 then ALLIN[key(who, "toward")]:set_value(1)
        else phase, pt = "settle", 0 end
    elseif phase == "settle" then
        if pt >= 25 then
            phase, pt = "go", 0
            log("MOVE %d %s_%s gap %d ax %d", frame, who, name, s0 - k1, math.abs(r16(p2o + O.oxpos) - r16(p1o + O.oxpos)))
        end
    elseif phase == "go" then
        if dir == "flipR" or dir == "flipL" then
            if pt <= 8 then
                ALLIN["P1 Up"]:set_value(1)
                ALLIN[dir == "flipR" and "P1 Right" or "P1 Left"]:set_value(1)
            end
            log("J %d %d %d", frame, r16(p1o + O.oxpos), r32(S.worldtlx) >> 16)
        else
        if dir and pt <= 14 then ALLIN[key(who, dir)]:set_value(1) end
        if pt >= 10 and pt < 15 then ALLIN[key(who, btn)]:set_value(1) end
        end
        if pt >= 150 then phase, pt = "backoff", 0 end
    elseif phase == "backoff" then
        if pt < 25 then ALLIN[key(who, "away")]:set_value(1) end
        if pt >= 40 then phase, pt = "approach", 0; mi = mi + 1 end
    end
    if frame - fight > 30000 then done("FAIL out of frames") end
end)
