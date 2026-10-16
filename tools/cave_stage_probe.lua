-- cave_stage_probe.lua
-- THE CAVE (curback 019h, src/MK3CAVE.ASM) reached the way a player reaches
-- it: coin up a 2P game, confirm both fighters, then press LEFT on the VS
-- stage-select screen.  Dead Pool is where a fresh game starts and THE CAVE
-- is the last entry of vs_stage_cycle, so one press from Dead Pool must land
-- on it - that is the selectable path, not a memory poke.
--
-- Once the fight starts it parks both fighters at the left limit, the middle
-- and the right limit, and at each stop logs every plane's worldtlx, the
-- floor's skew state, the background list lengths, the free-object count and
-- the frame-overrun meter, and snapshots the screen.  make_mk3cave.py
-- --preview <camx> renders the same camera for comparison.
--
-- env: MK2_CAVE_TAG - log/snapshot tag (default "base")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_CAVE_TAG") or "base"
local LOG_PATH = ROOT .. "/tools/cave_stage_probe_" .. TAG .. ".log"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local missing = false
local function sym(name)
    local v = symbols[name]
    if not v then print("[cave] FATAL missing map symbol " .. name); missing = true end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtly = sym("worldtly"), ground_y = sym("ground_y"),
    left_edge = sym("left_edge"), right_edge = sym("right_edge"),
    skew_oc = sym("skew_oc"), skew_dx = sym("skew_dx"), skew_y = sym("skew_y"),
    skew_height = sym("skew_height"), skew_sag = sym("skew_sag"), f_skew = sym("f_skew"),
    obj_free = symbols["obj_free"], peak_overload = symbols["peak_overload"],
    qdma_drops = symbols["qdma_drops"],
}
for _, n in ipairs({"worldtlx", "worldtlx2", "worldtlx3", "worldtlx4", "worldtlx5",
                    "worldtlx6", "worldtlx7", "worldtlx8",
                    "baklst1", "baklst2", "baklst3", "baklst4", "baklst5",
                    "baklst6", "baklst7", "baklst8"}) do
    A[n] = sym(n)
end

-- MK2_CAVE_WATCH: comma-separated 16-bit .bss counters (e.g. THE WARRIOR
-- SHRINE's wf_lines,wf_short,wf_ran) - each one's largest per-frame value
-- since the fight began is printed at every stop.
local WATCH, WATCH_MAX = {}, {}
for n in (os.getenv("MK2_CAVE_WATCH") or ""):gmatch("[%w_]+") do
    WATCH[#WATCH + 1] = n
    A["w_" .. n] = sym(n)
    WATCH_MAX[n] = 0
end

local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, osag = 0x100 }
local GS_PSEL, GS_FIGHTING = 4, 2
-- MK2_CAVE_STAGE (hex) retargets the probe at another VS-selectable stage,
-- e.g. 1a for THE PIT (MK1).  Default is THE CAVE.
local CAVE = tonumber(os.getenv("MK2_CAVE_STAGE") or "", 16) or 0x19

local fields, space = {}, nil
local last_gstate, last_curback = -1, -1
local charsel_frame, select_frame, confirm_frame, vs_snap_frame, fight_frame = 0, 0, 0, 0, 0
local curback_path = {}
local done_frame = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end return v end
local function wx(a) return s16(r32(a) >> 16) end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 High Punch"]=true, ["P2 High Punch"]=true, ["P1 Left"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do
        if not fields[n] then print("[cave] WARN no input field named " .. n) end
    end
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not s then return end
    pcall(function() s:snapshot() end)
    print(string.format("[cave] SNAP %s frame=%d %s", TAG, frame, label))
end

local function list_len(head)
    local p, c = r32(head), 0
    while p ~= 0 and c < 400 do p = r32(p + O.next); c = c + 1 end
    return c
end

local function free_objs()
    if not A.obj_free then return -1 end
    local p, c = r32(A.obj_free), 0
    while p ~= 0 and c < 1000 do p = r32(p + O.next); c = c + 1 end
    return c
end

local function report(label)
    print(string.format(
        "[cave] %s curback=%02x worldtly=%d ground_y=%d edges=%d..%d  x1=%d x2=%d x3=%d x4=%d x5=%d x6=%d x7=%d x8=%d",
        label, r16(A.curback), s16(r32(A.worldtly) >> 16), s16(r16(A.ground_y)),
        s16(r16(A.left_edge)), s16(r16(A.right_edge)),
        wx(A.worldtlx), wx(A.worldtlx2), wx(A.worldtlx3), wx(A.worldtlx4),
        wx(A.worldtlx5), wx(A.worldtlx6), wx(A.worldtlx7), wx(A.worldtlx8)))
    print(string.format("[cave] %s floor f_skew=%d skew_y=%d height=%d sag=%08x oc=%.2f dx=%.4f",
        label, r16(A.f_skew), s16(r16(A.skew_y)), r16(A.skew_height), r32(A.skew_sag),
        s32(r32(A.skew_oc)) / 65536, s32(r32(A.skew_dx)) / 65536))
    local lens = {}
    for i = 1, 8 do lens[#lens + 1] = string.format("b%d=%d", i, list_len(A["baklst" .. i])) end
    print(string.format("[cave] %s lists %s free_objs=%d", label, table.concat(lens, " "), free_objs()))
    if A.peak_overload then
        print(string.format("[cave] %s peak_overload=%d qdma_drops=%d",
            label, r16(A.peak_overload), r16(A.qdma_drops)))
    end
    for _, n in ipairs(WATCH) do
        print(string.format("[cave] %s watch %s now=%d max=%d", label, n, r16(A["w_" .. n]), WATCH_MAX[n]))
    end
    -- first few cavern blocks, in SCREEN coordinates (dclipl subtracts the
    -- plane's own worldtl) - an object's world coords alone prove nothing
    local p, c = r32(A.baklst3), 0
    while p ~= 0 and c < 4 do
        print(string.format("[cave]   baklst3[%d] screen=(%d,%d) sag=%08x", c,
            s16(r16(p + O.oxpos)) - wx(A.worldtlx3), s16(r16(p + O.oypos)) - s16(r32(A.worldtly) >> 16),
            r32(p + O.osag)))
        p = r32(p + O.next); c = c + 1
    end
end

local function park(x)
    for _, h in ipairs({A.p1_obj, A.p2_obj}) do
        local o = r32(h)
        if o ~= 0 then w32(o + O.oxval, (x & 0xffff) << 16) end
    end
end

local HOLD = 360
local STOPS = {
    {name = "left",  x = -200, at = HOLD},
    {name = "mid",   x = 550,  at = HOLD * 2},
    {name = "right", x = 1300, at = HOLD * 3},
}

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    -- BOTH start buttons: "2 Players Start" is player 2's own start, so
    -- pressing only it makes a one-player game for P2 - no VS stage select,
    -- and the tower picks the stage.  Keep coining/starting into the first
    -- 100 frames of select, because whichever player starts first flips
    -- gstate to psel and the other one still has to join.
    local r = charsel_frame > 0 and (frame - charsel_frame) or 0
    if charsel_frame == 0 or r < 100 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 6000 and (frame % 80) < 20
        end
        if name == "1 Player Start" then
            return frame >= 220 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 40
        end
        if name == "2 Players Start" then
            return frame >= 220 and frame < 6000 and (frame % 80) >= 50 and (frame % 80) < 60
        end
        return false
    end
    if select_frame == 0 then
        if name == "P1 High Punch" then return r >= 130 and r < 170 end
        if name == "P2 High Punch" then return r >= 190 and r < 230 end
        return false
    end
    if confirm_frame == 0 then
        -- walk LEFT one tap at a time until THE CAVE; each tap is 3 frames
        -- down, 13 up, clear of vssl's 10-tick repeat guard
        if name == "P1 Left" then return r16(A.curback) ~= CAVE and ((frame - select_frame) % 16) < 3 end
        return false
    end
    -- hold on THE CAVE long enough to snapshot the name, then confirm
    if name == "P1 High Punch" then return frame - confirm_frame >= 30 and frame - confirm_frame < 40 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print("[cave] loaded, tag=" .. TAG)
    end
    if not space or missing then
        if missing then manager.machine:exit() end
        return
    end
    if fight_frame > 0 then
        for _, n in ipairs(WATCH) do
            local v = r16(A["w_" .. n])
            if v > WATCH_MAX[n] then WATCH_MAX[n] = v end
        end
    end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[cave] frame=%d gstate %d -> %d curback=%02x", frame, last_gstate, gs, r16(A.curback)))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        last_gstate = gs
    end
    local cb = r16(A.curback)
    if cb ~= last_curback then
        print(string.format("[cave] frame=%d curback %02x -> %02x", frame, last_curback & 0xffff, cb))
        if select_frame > 0 and fight_frame == 0 then curback_path[#curback_path + 1] = string.format("%02x", cb) end
        last_curback = cb
    end

    -- the VS stage select takes over after both fighters are picked
    -- (gs_post_psel 0dh, then the VS screen composes its portraits)
    if charsel_frame > 0 and select_frame == 0 and frame - charsel_frame > 300 then
        select_frame = frame
        print(string.format("[cave] stage select at frame=%d curback=%02x", frame, cb))
    end
    if select_frame > 0 and confirm_frame == 0 and cb == CAVE then
        confirm_frame = frame
        print(string.format("[cave] reached THE CAVE at frame=%d via %s", frame, table.concat(curback_path, ",")))
    end
    if confirm_frame > 0 and vs_snap_frame == 0 and frame - confirm_frame == 25 then
        vs_snap_frame = frame
        snap("vs_select")
    end

    if fight_frame == 0 and gs == GS_FIGHTING and confirm_frame > 0 then
        fight_frame = frame
        print(string.format("[cave] FIGHT on curback=%02x at frame=%d%s", cb, frame,
            cb == CAVE and "" or "  <-- WRONG STAGE"))
        if A.peak_overload then w16(A.peak_overload, 0); w16(A.qdma_drops, 0) end
    end

    if fight_frame > 0 then
        local rel = frame - fight_frame
        if rel == 60 then report("open"); snap("open") end
        for _, st in ipairs(STOPS) do
            if rel >= st.at - HOLD + 60 and rel < st.at then park(st.x) end
            if rel == st.at then report(st.name); snap(st.name) end
        end
        if rel > STOPS[#STOPS].at + 20 and done_frame == 0 then
            done_frame = frame; print("[cave] finished")
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 9000 then print("[cave] TIMEOUT"); manager.machine:exit(); return end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close(); logfh = nil end end)
