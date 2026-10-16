-- mk1throne_chair_test.lua
--
-- THE THRONE ROOM (MK1), curback 01Ch: when Shang Tsung is IN the fight the
-- throne is drawn EMPTY (mk1thrn_calla -> mk1t_chair, MK1THRN.ASM); when he
-- is not, the seated Shang is drawn as before.
--
-- It walks mk1p_sky_lst - the one list both ride - and reads the SAG of every
-- object's image record, then sorts each into the empty throne's strips
-- (src/THRCHP1-3.TBL) or Shang's pieces (src/MK1TRSH.TBL, MK1TRS2.TBL).  The
-- SAGs are read out of the TBLs every run, so a rebuild cannot leave the rig
-- comparing against stale numbers.
--
--   MK2_CHAIR_MODE=shang    P2 is forced to Shang Tsung: all the strips, and
--                           not one Shang piece, must be on the list
--   MK2_CHAIR_MODE=control  nobody is Shang: Shang's pieces and NO strip
--
-- In shang mode P1 then walks right and back so the camera crosses the
-- throne, snapping every 20 frames and logging plane 4's camera
-- (`[chair] SNAP n p4=`): tools/mk1throne_chair_sky.py finds the throne in
-- each real frame from that and counts sky-blue pixels in its box - the
-- leaks a start-camera-only patch had.
-- env: MK2_CHAIR_MODE, MK2_CHAIR_TAG

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local MODE = os.getenv("MK2_CHAIR_MODE") or "shang"
local TAG = os.getenv("MK2_CHAIR_TAG") or MODE
local LOG_PATH = ROOT .. "/tools/mk1throne_chair_test_" .. TAG .. ".log"
local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols, fatal = {}, false
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if not fh then log("[chair] FATAL no src/mk2.map"); fatal = true
    else
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n)
    local v = symbols[n]
    if not v then log("[chair] FATAL missing map symbol %s", n); fatal = true end
    return v
end

-- record name -> SAG, out of the LOAD2 tables in src/
local function tbl_sags(file, into, tag)
    local fh = io.open(ROOT .. "/src/" .. file, "r")
    if not fh then log("[chair] FATAL no src/%s", file); fatal = true; return end
    local name, n = nil, 0
    for line in fh:lines() do
        local lab = line:match("^([%w_]+):")
        if lab then name = lab
        else
            local sag = line:match("^%s*%.long%s+(%x+)[Hh]")
            if sag and name then into[tonumber(sag, 16)] = tag .. ":" .. name; name = nil; n = n + 1 end
        end
    end
    fh:close()
    if n == 0 then log("[chair] FATAL no records in src/%s", file); fatal = true end
    return n
end
local SAGS = {}
local nstrip = 0
for _, f in ipairs({"THRCHP1.TBL", "THRCHP2.TBL", "THRCHP3.TBL"}) do
    nstrip = nstrip + (tbl_sags(f, SAGS, "chair") or 0)
end
tbl_sags("MK1TRSH.TBL", SAGS, "shang")
tbl_sags("MK1TRS2.TBL", SAGS, "shang")

local A = { gstate = sym("gstate"), curback = sym("curback"), worldtlx4 = sym("worldtlx4"),
            p2_char = sym("p2_char"), p1_char = sym("p1_char"),
            lst = sym("mk1p_sky_lst"), p1bar = sym("p1_bar"), p2bar = sym("p2_bar") }
local GS_PSEL, GS_FIGHTING = 4, 2
local STAGE, FT_ST = 0x1c, 6
local OIMG = 0x1a0

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["Coin 2"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true, ["P1 Left"] = true, ["P1 Right"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end
local function press(name, on)
    local f = fields[name]
    if f then f:set_value(on and 1 or 0) end
end

local function finish(ok, msg)
    log("[chair] RESULT %s mode=%s %s", ok and "PASS" or "FAIL", MODE, msg)
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

local select_frame, fight_frame = 0, 0
local snaps = 0
local verdict = nil
local function wx(a) local v = (r32(a) >> 16) & 0xffff; if v >= 0x8000 then v = v - 0x10000 end; return v end

emu.register_frame_done(function()
    frame = frame + 1
    if fatal then finish(false, "reason=setup"); return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
    end
    local gs = r16(A.gstate)

    if fight_frame == 0 then
        local k = frame % 60
        press("Coin 1", frame > 120 and frame < 400 and k < 4)
        press("Coin 2", frame > 120 and frame < 400 and k >= 8 and k < 12)
        press("1 Player Start", frame > 200 and frame < 500 and k >= 20 and k < 24)
        press("2 Players Start", frame > 200 and frame < 500 and k >= 30 and k < 34)
        press("P1 High Punch", frame > 500 and frame < 640 and k < 4)
        press("P2 High Punch", frame > 500 and frame < 640 and k >= 8 and k < 12)
        if gs == GS_PSEL and select_frame == 0 then select_frame = frame end
        if select_frame > 0 then
            press("P1 Left", r16(A.curback) ~= STAGE and ((frame - select_frame) % 16) < 3)
            -- the selection is overridden until the fight starts: setup_players
            -- and the stage's calla both read @p2_char in the round intro
            if MODE == "shang" then w16(A.p2_char, FT_ST) end
        end
        if gs == GS_FIGHTING and r16(A.curback) == STAGE then
            fight_frame = frame
            log("[chair] FIGHT on curback=%02x at frame=%d p1_char=%d p2_char=%d",
                r16(A.curback), frame, r16(A.p1_char), r16(A.p2_char))
        end
        if frame > 4000 then finish(false, "reason=never_reached_stage") end
        return
    end

    w16(A.p1bar, 0xA1); w16(A.p2bar, 0xA1)
    local rel = frame - fight_frame
    if rel == 60 or rel == 120 then
        manager.machine.video:snapshot(); snaps = snaps + 1
    end
    if rel < 120 then return end
    if verdict then
        -- the sweep: right for 260 frames, left for 360, snapping as it goes
        local t = rel - 121
        press("P1 Right", t < 260)
        press("P1 Left", t >= 260 and t < 620)
        if t % 20 == 0 then
            manager.machine.video:snapshot(); snaps = snaps + 1
            log("[chair] SNAP %d p4=%d", snaps - 1, wx(A.worldtlx4))
        end
        if t >= 640 then finish(verdict[1], verdict[2]) end
        return
    end

    -- walk the list
    local chair, shang, other, seen = 0, 0, 0, {}
    local o, guard = r32(A.lst), 0
    while o ~= 0 and guard < 64 do
        local img = r32(o + OIMG)
        local sag = r32(img + 64)
        local who = SAGS[sag]
        if who and who:sub(1, 5) == "chair" then
            chair = chair + 1; seen[who] = true
            log("[chair]   %s at x=%d y=%d z=%d", who, r16(o + 0x90), r16(o + 0xb0), r16(o + 0xd0))
        elseif who then shang = shang + 1
        else other = other + 1; log("[chair]   unknown SAG %08X", sag) end
        o = r32(o); guard = guard + 1
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    log("[chair] list: %d chair strip(s) (%d distinct of %d), %d Shang piece(s), %d other; p2_char=%d",
        chair, distinct, nstrip, shang, other, r16(A.p2_char))
    if MODE == "shang" then
        verdict = { distinct == nstrip and chair == nstrip and shang == 0 and other == 0,
                    string.format("strips=%d/%d shang=%d other=%d", distinct, nstrip, shang, other) }
    else
        finish(chair == 0 and shang >= 5 and other == 0,
               string.format("strips=%d shang=%d other=%d", chair, shang, other))
    end
end)
