-- lightning_test.lua
-- Tests Raiden's ambient lightning bolt effect (pid_lightning = 8).
-- Forces both players to Raiden, starts a match, then monitors the
-- lightning process and bolt objects every 60 frames.
-- Takes screenshots at key moments and logs crash indicators.
--
-- Usage:
--   C:\MAME\mame.exe mk2 -window -resolution 800x600 -skip_gameinfo
--     -script C:\Users\you\Workplace\mk2-main\tools\lightning_test.lua
--   or use run_lightning_test.bat in this directory

local frame = 0
local fields = {}
local space = nil
local cpu = nil
local snapshots_taken = {}
local last_gstate = -1
local charsel_frame = 0   -- frame when gstate first became GS_PSEL
local select_logged = false
local active_snap_count = 0
local last_active_snap_frame = -999

-- ── Memory map (TMS34010 bit addresses, matching mk2.map) ────────────────────
local ACTIVE     = 0x010dc6d0  -- process list head
local GSTATE     = 0x01129d90  -- game state word
local P1_STATE   = 0x01129db0
local P2_STATE   = 0x0112a980
local P1_CHAR    = 0x01129e40  -- fighter type word
local P2_CHAR    = 0x0112aa10
local P1_OBJ     = 0x01129de0  -- p1 object pointer
local P2_OBJ     = 0x0112a9b0
local OBJLST     = 0x01127030  -- foreground object list head
local PF_RAM     = 0x0112b660  -- system_lockup saves error/current value here

-- ── Process block field offsets (bit offsets within process block) ───────────
local PROC_NEXT  = 0x000       -- next process pointer (32b)
local PROC_ID    = 0x020       -- process id (16b)
local PROC_TIME  = 0x030       -- sleep countdown (16b)
local PROC_WAKE  = 0x0e0       -- wake address (32b)
local PROC_RAIDEN_OBJ = 0x140  -- p_otherguy = pdata(0x100) + 0x040 (32b)

-- ── Object block field offsets ───────────────────────────────────────────────
local OBJ_NEXT   = 0x000       -- next object pointer (32b)
local OBJ_OSLINK = 0x020       -- link to process (32b)
local OBJ_OXVAL  = 0x080       -- x position (32b)
local OBJ_OYVAL  = 0x0a0       -- y position (32b)
local OBJ_OZVAL  = 0x0c0       -- z position (32b)  ← our bolt sets this to 0x10000
local OBJ_OXPOS  = 0x090       -- x pixel pos (16b)
local OBJ_OYPOS  = 0x0b0       -- y pixel pos (16b)
local OBJ_OFLAGS = 0x0f0       -- render flags (16b)
local OBJ_OFLAGS2= 0x160       -- game flags (32b)
local OBJ_OPAL   = 0x140       -- palette slot (16b)
local OBJ_OIMG   = 0x1a0       -- multipart RAM ptr (32b)
local OBJ_OID    = 0x1c0       -- object id (16b)

-- ── Game constants ────────────────────────────────────────────────────────────
local GS_PSEL      = 4         -- character select
local GS_PFSETUP   = 6
local GS_ROUND     = 7
local GS_FIGHTING  = 2
local FT_RAIDEN    = 7         -- ft_raiden .set 7
local PID_LIGHTNING = 8        -- pid_lightning .set 8
local PID_MPO       = 0x109    -- multipart object process pid
local PS_ACTIVE     = 1

-- ── Snapshot frames ───────────────────────────────────────────────────────────
local SNAP_FRAMES = { 3000, 3600, 4200, 4800, 5400, 6000, 7200, 8400, 9600 }

-- ── Input helpers ─────────────────────────────────────────────────────────────
local function cache_fields()
    local wanted = {
        ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true,
        ["P2 High Punch"]=true, ["P2 Low Kick"]=true,
        ["P1 Right"]=true, ["P1 Down"]=true,
        ["UI Select"]=true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function take_snap(label)
    local s = main_screen()
    if s then
        local ok, err = pcall(function() s:snapshot() end)
        print(string.format("[lightning] SNAPSHOT frame=%d label=%s ok=%s %s",
            frame, label, tostring(ok), ok and "" or tostring(err)))
    end
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, value = pcall(function() return item.value end)
    if okv then return value end
    okv, value = pcall(function() return item() end)
    if okv then return value end
    return nil
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value)
end

local function pressed(name)
    if name == "UI Select"      then return frame >= 5 and frame < 35 end
    if name == "Coin 1"         then return frame >= 760 and frame < 1200 and (frame % 120) < 24 end
    if name == "1 Player Start" then
        if charsel_frame > 0 then return false end
        return frame >= 900 and frame < 980
    end

    -- char select navigation relative to when GS_PSEL started:
    --   RIGHT x3 at +30/+50/+70 frames  →  moves cursor right 3 columns
    --   DOWN  x2 at +105/+130 frames     →  moves from Reptile to Jax to Raiden
    --   HP confirm at +200 frames          →  locks in Raiden
    if charsel_frame > 0 then
        local r = frame - charsel_frame
        if name == "P1 Right" then
            return (r >= 30 and r < 36) or (r >= 55 and r < 61) or (r >= 80 and r < 86)
        end
        if name == "P1 Down" then
            return (r >= 110 and r < 116) or (r >= 138 and r < 144)
        end
        if name == "P1 High Punch" then
            return (r >= 190 and r < 225) or (frame >= 3200 and (frame % 80) < 20)
        end
    else
        if name == "P1 High Punch" then return frame >= 3200 and (frame % 80) < 20 end
    end

    if name == "P1 Low Kick"    then return frame >= 3400 and (frame % 120) < 18 end
    if name == "P2 High Punch"  then return frame >= 3200 and (frame % 90) < 20 end
    if name == "P2 Low Kick"    then return frame >= 3400 and (frame % 130) < 18 end
    return false
end

-- ── Process scanner ───────────────────────────────────────────────────────────
local function find_process_by_pid(pid)
    if not space then return nil end
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid then return p end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return nil
end

local function count_process_by_pid(pid)
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local count = 0
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid then count = count + 1 end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return count
end

local function count_all_processes()
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local count = 0
    local guard = 0
    while p ~= 0 and guard < 256 do
        count = count + 1
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return count
end

-- ── Object list helpers ───────────────────────────────────────────────────────
local function scan_objlst_for_ozval(target_ozval)
    -- Returns count of objects in objlst with ozval == target_ozval
    if not space then return 0 end
    local p = space:read_u32(OBJLST)
    local count = 0
    local guard = 0
    while p ~= 0 and guard < 256 do
        local oz = space:read_u32(p + OBJ_OZVAL)
        if oz == target_ozval then count = count + 1 end
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    return count
end

local function find_objlst_by_ozval(target_ozval)
    if not space then return 0 end
    local p = space:read_u32(OBJLST)
    local guard = 0
    while p ~= 0 and guard < 256 do
        local oz = space:read_u32(p + OBJ_OZVAL)
        if oz == target_ozval then return p end
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    return 0
end

local function objlst_count()
    if not space then return 0 end
    local p = space:read_u32(OBJLST)
    local count = 0
    local guard = 0
    while p ~= 0 and guard < 256 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    return count
end

-- ── Lightning process logger ──────────────────────────────────────────────────
local function log_lightning()
    if not space then return end

    local gstate = space:read_u16(GSTATE)
    -- log during char select (4), post_psel/VS (13), pfsetup (6), round_intro (7), fighting (2)
    if gstate ~= GS_FIGHTING and gstate ~= GS_PFSETUP and gstate ~= GS_ROUND
       and gstate ~= GS_PSEL and gstate ~= 0xd then
        return
    end

    local lproc = find_process_by_pid(PID_LIGHTNING)
    local mpo_count = count_process_by_pid(PID_MPO)
    local bolt_objs = scan_objlst_for_ozval(0x10000)  -- our bolt ozval marker
    local bolt_obj = find_objlst_by_ozval(0x10000)
    local total_objs = objlst_count()
    local p1obj = space:read_u32(P1_OBJ)
    local p1oz = p1obj ~= 0 and space:read_u32(p1obj + OBJ_OZVAL) or -1

    local total_procs = count_all_processes()
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local sp = cpu_reg("SP")
    local b14 = cpu_reg("B14") or cpu_reg("b14")
    local a0r = cpu_reg("A0") or cpu_reg("a0")
    local pf = space:read_u32(PF_RAM)
    local bolt_info = "bolt=none"
    if bolt_obj ~= 0 then
        local bx = space:read_u16(bolt_obj + OBJ_OXPOS)
        local by = space:read_u16(bolt_obj + OBJ_OYPOS)
        local bop = space:read_u16(bolt_obj + OBJ_OPAL)
        local bimg = space:read_u32(bolt_obj + OBJ_OIMG)
        local bsag = bimg ~= 0 and space:read_u32(bimg) or 0
        local bsize = bimg ~= 0 and space:read_u32(bimg + 0x20) or 0
        local bdx = bimg ~= 0 and space:read_u16(bimg + 0x50) or 0
        local bdy = bimg ~= 0 and space:read_u16(bimg + 0x60) or 0
        bolt_info = string.format("bolt=0x%08x xy=%d,%d opal=0x%x oimg=0x%08x sag=0x%08x size=0x%08x dxy=%d,%d",
            bolt_obj, bx, by, bop, bimg, bsag, bsize, bdx, bdy)
    end
    if bolt_objs > 0 and active_snap_count < 6 and frame - last_active_snap_frame >= 10 then
        active_snap_count = active_snap_count + 1
        last_active_snap_frame = frame
        take_snap("bolt_active_" .. tostring(active_snap_count))
    end
    if lproc then
        local raiden_obj = space:read_u32(lproc + PROC_RAIDEN_OBJ)
        local ltime  = space:read_u16(lproc + PROC_TIME)
        local lwake  = space:read_u32(lproc + PROC_WAKE)
        print(string.format(
            "[lightning] frame=%-6d gstate=%d  pid8=FOUND proc=0x%08x time=%d wake=0x%08x raiden=0x%08x | mpo=%d bolt_objs=%d objs=%d procs=%d p1oz=0x%x %s pc=%s sp=%s b14=%s a0=%s pf=%s",
            frame, gstate, lproc, ltime, lwake, raiden_obj,
            mpo_count, bolt_objs, total_objs, total_procs, p1oz, bolt_info,
            hx(pc), hx(sp), hx(b14), hx(a0r), hx(pf)))
    else
        print(string.format(
            "[lightning] frame=%-6d gstate=%d  pid8=MISSING | mpo=%d bolt_objs=%d objs=%d procs=%d p1oz=0x%x %s pc=%s sp=%s b14=%s a0=%s pf=%s",
            frame, gstate, mpo_count, bolt_objs, total_objs, total_procs, p1oz,
            bolt_info, hx(pc), hx(sp), hx(b14), hx(a0r), hx(pf)))
    end
end

-- ── Main frame callback ───────────────────────────────────────────────────────
emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cache_fields()
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        print("[lightning] test script loaded — driving P1 cursor to Raiden (ft=7)")
    end

    -- Track gstate transitions
    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            print(string.format("[lightning] frame=%d  gstate: %d -> %d", frame, last_gstate, gs))
            last_gstate = gs
        end

        if charsel_frame > 0 and not select_logged and frame - charsel_frame >= 188 then
            print(string.format("[lightning] frame=%d  pre-confirm p1_char=%d (want Raiden=%d)",
                frame, space:read_u16(P1_CHAR), FT_RAIDEN))
            select_logged = true
        end
    end

    -- Apply inputs
    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    -- Periodic lightning probe (every 60 frames while in any fight-related state)
    if frame >= 300 and (frame % 60) == 0 then
        log_lightning()
    end

    -- Snapshots
    for _, sf in ipairs(SNAP_FRAMES) do
        if frame == sf and not snapshots_taken[sf] then
            snapshots_taken[sf] = true
            take_snap(tostring(sf))
        end
    end

    -- Crash watchdog: starting from frame 300
    if frame > 300 and space then
        local gs = space:read_u16(GSTATE)
        if gs == 0 or gs > 0x0f then
            print(string.format("[lightning] CRASH/RESET DETECTED frame=%d gstate=0x%x", frame, gs))
        end
    end

    -- Auto-quit after 12000 frames (~3.3 min) to avoid hanging
    if frame == 12000 then
        print("[lightning] frame limit reached — test complete")
        take_snap("final")
        manager.machine:exit()
    end
end)
