-- sa_heli_block_test.lua
--
-- Drives Baraka's World View dive (Up,Up + LK -> do_sa_helitest) on the
-- test-mode ROM (P1 Baraka, P2 Jax human) and logs enough per frame to tell a
-- crash from a mis-timed input.
--
--   MK2_HELI_MODE=block   P2 holds Block for the whole run
--   MK2_HELI_MODE=twice   P2 stands there and the move is fired TWICE
--   MK2_HELI_MODE=spam    five dives back to back
--   MK2_HELI_MODE=once    one clean dive, for a baseline
--
-- A LOCKUP here is `ermac' - MACROS.HDR expands it to a bare `jauc $' - so the
-- CPU pins on ONE address and every process stops while the object system
-- keeps integrating velocities.  Sampling the PC and watching it stop moving
-- is therefore the whole crash detector.
--
-- Addresses are read out of src/mk2.map at load.  They shift on EVERY relink
-- and a hardcoded list silently turns every read into garbage - which reads
-- exactly like "the ROM never booted".

local MODE = os.getenv("MK2_HELI_MODE") or "block"
local REPO = "C:/Users/you/Workplace/mk2-main"
local LOG  = REPO .. "/tools/sa_heli_block_test." .. MODE .. ".log"

local logfh = io.open(LOG, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- ---------------------------------------------------------------- symbols
local SYM = {}
do
    local fh = io.open(REPO .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_]+)") do
                if SYM[name] == nil then SYM[name] = tonumber(addr, 16) end
            end
        end
        fh:close()
    end
end
local function sym(n)
    local v = SYM[n]
    if not v then error("symbol not in mk2.map: " .. n) end
    return v
end

local GSTATE  = sym("gstate")
local P1_OBJ  = sym("p1_obj")
local P1_PROC = sym("p1_proc")
local P1_CHAR = sym("p1_char")
local P1_BAR  = sym("p1_bar")
local P2_OBJ  = sym("p2_obj")
local P2_PROC = sym("p2_proc")
local P2_CHAR = sym("p2_char")
local P2_BAR  = sym("p2_bar")
local F_NOREP = sym("f_norepell")

local OBJ_OXPOS  = 0x090
local OBJ_OYPOS  = 0x0b0
local OBJ_OFLAGS = 0x0f0
local OBJ_OIMG   = 0x1a0

local P_ACTION = 0x1f0
local P_FLAGS  = 0x210
local P_STORE1 = 0x230
local P_STORE2 = 0x250

-- Sound tap.  triple_sound ends up strobing the sound board at `sound`
-- (SYSEQU.ASM, 1d01030h) and the tap takes the RAW address, not a /8 byte
-- conversion.  The tap is PARTIAL - it catches roughly a handful of codes a
-- round - so a code appearing here proves it was sent; a code missing proves
-- nothing.  That is enough: the question is whether the blade cues fire at
-- all.
local SOUND_PORT = 0x1d01030
local sndlog = {}

local frame, space, maincpu = 0, nil, nil
local fields  = {}
local fight0  = 0
local shots   = {}
local burst   = 0
local burst0  = 0
local fired   = 0
local done    = false
local pctrace = {}
local snaps   = 0
local lastpc, samepc = nil, 0

local function s16(v)
    v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if f.name == "P1 Up"        then fields.p1up = f end
            if f.name == "P1 Low Kick"  then fields.p1lk = f end
            if f.name == "P1 Block"     then fields.p1bl = f end
            if f.name == "P2 Block"     then fields.p2bl = f end
        end
    end
    print("[rig] mode=" .. MODE)
    print(string.format("[rig] gstate=%08x p1_obj=%08x p2_obj=%08x",
        GSTATE, P1_OBJ, P2_OBJ))
    for _, k in ipairs({"p1up","p1lk","p1bl","p2bl"}) do
        print(string.format("[rig] field %-5s %s", k, fields[k] and "ok" or "MISSING"))
    end
end

-- Up, Up + LK, with P1 Block held over the two Up taps so they do not become a
-- real jump (SAHT_GROUND_BAND in MOVES.ASM refuses the move above 40px), and
-- released before the kick so the button is not eaten.
local function drive_burst(t)
    if fields.p1bl then
        if t >= 0 and t < 14 then fields.p1bl:set_value(1) end
        if t == 14 then fields.p1bl:clear_value() end
    end
    if     t == 0  then fields.p1up:set_value(1)
    elseif t == 4  then fields.p1up:clear_value()
    elseif t == 8  then fields.p1up:set_value(1)
    elseif t == 12 then fields.p1up:clear_value()
    elseif t == 16 then fields.p1lk:set_value(1)
    elseif t == 20 then fields.p1lk:clear_value(); return true
    end
    return false
end

local function report(why)
    if done then return end
    done = true
    local scr = manager.machine.screens[":screen"]
    if scr then pcall(function() scr:snapshot() end) end
    print("")
    print("[rig] ===== RESULT =====")
    print("[rig] " .. why)
    print("[rig] pc trace: " .. table.concat(pctrace, " | "))
    print("[rig] sound writes: " .. table.concat(sndlog, " "))
    print("[rig] ==================")
    manager.machine:exit()
end

local function tick()
    frame = frame + 1
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        maincpu = cpu
        space = cpu.spaces["program"]
        cache_fields()
        local ok = pcall(function()
            space:install_write_tap(SOUND_PORT, SOUND_PORT + 0x1f, "snd",
                function(offset, data, mask)
                    sndlog[#sndlog+1] = string.format("%d:%04x", frame, data & 0xffff)
                    return data
                end)
        end)
        print("[rig] sound tap " .. (ok and "installed" or "UNAVAILABLE"))
        return
    end

    local gs = space:read_u16(GSTATE)
    local o1 = space:read_u32(P1_OBJ)
    local o2 = space:read_u32(P2_OBJ)

    if fight0 == 0 then
        if gs ~= 2 or o1 == 0 or o2 == 0 then
            if frame % 180 == 0 then
                print(string.format("[rig] f=%d waiting gs=0x%x p1obj=0x%08x", frame, gs, o1))
            end
            if frame > 2400 then report("never reached a fight") end
            return
        end
        fight0 = frame
        shots = { frame + 90 }
        if MODE == "twice" then shots[2] = 0 end          -- scheduled after burst 1
        if MODE == "block2" then shots[2] = 0 end
        if MODE == "spam"  then for i = 2, 5 do shots[i] = 0 end end
        if MODE == "drone" then for i = 2, 14 do shots[i] = 0 end end
        if MODE == "rapid" then for i = 2, 6 do shots[i] = 0 end end
        print(string.format("[rig] f=%d FIGHT LIVE p1=%d p2=%d",
            frame, space:read_u16(P1_CHAR), space:read_u16(P2_CHAR)))
    end

    if MODE == "block" and fields.p2bl then fields.p2bl:set_value(1) end
    -- block2: he eats the first dive and guards the second, so the block lands
    -- while he is still coming out of the first one's reaction.
    if MODE == "block2" and burst >= 1 and fields.p2bl then fields.p2bl:set_value(1) end
    -- Keep both bars full so the fight never ends on damage: the point of the
    -- drone run is hours of dives against a live opponent, not a match.
    if MODE == "drone" then
        space:write_u16(P1_BAR, 0xa1)
        space:write_u16(P2_BAR, 0xa1)
    end

    if gs ~= 2 then
        -- Round transitions (gs_pfsetup 6 / gs_round_intro 7 / gs_bonus 5) are
        -- normal.  Only a gstate outside the state machine is a crash; a
        -- LOCKUP is caught by the pinned-PC test below.
        if gs >= 1 and gs <= 0x10 then
            if fight0 ~= 0 then
                print(string.format("[rig] f=%d round over (gs=0x%x) - waiting", frame, gs))
                fight0, burst, burst0, fired = 0, 0, 0, 0
            end
            return
        end
        report(string.format("CRASH - gstate out of range at f=%d gs=0x%04x", frame, gs))
        return
    end
    if o1 == 0 or o2 == 0 or (o1 >> 24) ~= 0x01 or (o2 >> 24) ~= 0x01 then
        report(string.format("CRASH? object pointer garbage f=%d p1obj=0x%08x p2obj=0x%08x",
            frame, o1, o2))
        return
    end

    local ok, pc = pcall(function() return maincpu.state["PC"].value end)
    if ok and pc then
        pctrace[#pctrace+1] = string.format("%d:%08x", frame, pc)
        if #pctrace > 40 then table.remove(pctrace, 1) end
        if pc == lastpc then
            samepc = samepc + 1
            if samepc == 45 then
                report(string.format("LOCKUP - pc pinned at %08x for 45 frames (ermac)", pc))
                return
            end
        else
            lastpc, samepc = pc, 0
        end
    end

    if burst < #shots and shots[burst + 1] ~= 0 and frame >= shots[burst + 1] then
        if burst0 == 0 then burst0 = frame end
        if drive_burst(frame - burst0) then
            burst  = burst + 1
            burst0 = 0
            fired  = frame
            print(string.format("[rig] f=%d BURST %d sent", frame, burst))
            if MODE == "twice" and burst == 1 then shots[2] = frame + 220 end
            if MODE == "block2" and burst == 1 then shots[2] = frame + 200 end
            if MODE == "spam" and burst < #shots then shots[burst + 1] = frame + 200 end
            if MODE == "rapid" and burst < #shots then shots[burst + 1] = frame + 100 end
            if MODE == "drone" and burst < #shots then shots[burst + 1] = frame + 150 end
        end
    end

    if fired > 0 then
        local p1p = space:read_u32(P1_PROC)
        local p2p = space:read_u32(P2_PROC)
        local a1  = (p1p >> 24) == 0x01 and space:read_u16(p1p + P_ACTION) or 0xdead
        local a2  = (p2p >> 24) == 0x01 and space:read_u16(p2p + P_ACTION) or 0xdead
        local img = space:read_u32(o1 + OBJ_OIMG)
        local sag = (img >> 24) == 0x01 and space:read_u32(img) or 0
        local im2 = space:read_u32(o2 + OBJ_OIMG)
        local sg2 = (im2 >> 24) == 0x01 and space:read_u32(im2) or 0
        print(string.format(
            "[rig] f=%-5d p1act=0x%04x p2act=0x%04x p1(%d,%d) p2(%d,%d) " ..
            "sag=0x%08x/0x%08x fh=%d fv=%d bars=%d/%d st2=0x%08x norep=%d pass=%d",
            frame, a1 & 0xffff, a2 & 0xffff,
            s16(space:read_u16(o1 + OBJ_OXPOS)), s16(space:read_u16(o1 + OBJ_OYPOS)),
            s16(space:read_u16(o2 + OBJ_OXPOS)), s16(space:read_u16(o2 + OBJ_OYPOS)),
            sag, sg2,
            (space:read_u16(o1 + OBJ_OFLAGS) & 0x0010) ~= 0 and 1 or 0,
            (space:read_u16(o1 + OBJ_OFLAGS) & 0x0020) ~= 0 and 1 or 0,
            s16(space:read_u16(P1_BAR)), s16(space:read_u16(P2_BAR)),
            (p1p >> 24) == 0x01 and space:read_u32(p1p + P_STORE2) or 0,
            s16(space:read_u16(F_NOREP)),
            (p1p >> 24) == 0x01 and space:read_u16(p1p + P_STORE1) or -1))
        if snaps < 160 and frame % 4 == 0 and MODE ~= "drone" then
            snaps = snaps + 1
            local scr = manager.machine.screens[":screen"]
            if scr then pcall(function() scr:snapshot() end) end
        end
    end

    if fired > 0 and burst >= #shots and frame - fired > 380 then
        report("survived to the end of the run")
    end
    if frame > (MODE == "drone" and 14000 or 6000) then report("timeout") end
end

emu.register_frame_done(tick)
print("[rig] loaded")
