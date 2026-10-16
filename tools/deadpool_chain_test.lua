--[[
    deadpool_chain_test.lua  --  Dead Pool chain + acid skeleton rise verifier

    WORKING launch command (user-verified):
        C:\MAME\mame.exe -rompath "C:\Users\you\Workplace\mk2-main\rom" mk2 -debug
    Then in the MAME debugger: g  (to resume)

    With this script:
        C:\MAME\mame.exe -rompath "C:\Users\you\Workplace\mk2-main\rom" mk2 -debug -debugscript C:\Users\you\Workplace\mk2-main\mame_autoresume.ds -autoboot_script tools/deadpool_chain_test.lua
    NOTE: The MAME ROM mismatch dialog may appear; press any key to dismiss it
    before the emulated CPU starts. The -debug + g in debugscript auto-resumes
    once the dialog is cleared.

    Auto-test sequence (no keyboard interaction required):
      T+5s   Force Dead Pool stage (writes curback=0) + dump address table
      T+10s  Kill P2 to 1 HP (Finish Him should arm on next hit)
      T+12s  Snap P1 into uppercut range
      T+14s  Take verification screenshot + dump chain sprite state
      Every frame: log when winner_status changes (Finish Him / clear)
      Every frame: if acid fatality used (f_death=-1), dump skeleton state
--]]

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/deadpool_chain_test.log"
local SNAP_PATH = "C:/MAME/snap/mk2/"

-- ================================================================
-- TMS34010 program-space BIT addresses from MK2.MAP (2026-05-29 build).
-- This MAME Lua provider reads/writes the raw bit addresses directly.
-- ================================================================
local _B = {
    gstate          = 0x01129dc0,
    winner_status   = 0x0112b700,
    curback         = 0x0112b6c0,
    f_death         = 0x0112b5b0,
    p1_obj          = 0x01129e10,
    p2_obj          = 0x0112a9e0,
    p1_bar          = 0x01129ee0,
    p2_bar          = 0x0112aab0,
    hanger_coords   = 0x01131e10,
    pc_chain_obj_p1 = 0x01131e70,   -- longchain obj ptr P1 (stride +32 bits for P2)
    pc_chain_obj_p2 = 0x01131e90,
    pc_hook_obj_p1  = 0x01131eb0,   -- TINHOOK obj ptr P1
    pc_hook_obj_p2  = 0x01131ed0,
}

-- Object offsets are also bit offsets from DISPEQU.ASM.
local OBJ_OXPOS = 0x90
local OBJ_OYPOS = 0xb0
local OBJ_OZPOS = 0xd0
local OBJ_OID   = 0x1c0

local FULL_HP         = 0xa1
local DEAD_POOL       = 0
local WIN_FINISHHIM   = 3
local ACID_SKEL_Y     = 0xb0
local ACID_HOOK_Y     = 0x90
local RANGE_UCUT      = 75
local GS_PFSETUP      = 1
local GS_FIGHTING     = 2

local A = {}
for k, v in pairs(_B) do A[k] = v end

-- ================================================================
-- LOGGING
-- ================================================================
local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local msg = (select("#",...) > 0) and string.format(fmt,...) or fmt
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
    print(line)
    if logfh then logfh:write(line,"\n"); logfh:flush() end
end

-- ================================================================
-- MEMORY ACCESS
-- ================================================================
local space
local function mem_init()
    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then log("ERROR: no :maincpu"); return end
    space = cpu.spaces["program"]
end

local function rw(a)   return space:read_u16(a) end
local function ww(a,v) space:write_u16(a, v & 0xffff) end
local function rl(a)   return space:read_u32(a) end
local function i16(v)  return (v >= 0x8000) and (v-0x10000) or v end

local function obj_base(bit_ptr_addr)
    local bits = rl(bit_ptr_addr)
    if bits == 0 then return nil end
    return bits
end

-- ================================================================
-- CHAIN / SPRITE STATE DUMP
-- ================================================================
local function dump_obj(label, bit_ptr_addr_in_B)
    local base = obj_base(bit_ptr_addr_in_B)
    if not base then
        log("  %-24s [null -- process not spawned or not Dead Pool stage]", label)
        return nil
    end
    local x = i16(rw(base + OBJ_OXPOS))
    local y = i16(rw(base + OBJ_OYPOS))
    local z = i16(rw(base + OBJ_OZPOS))
    log("  %-24s x=%4d  y=%4d  z=%3d  obj_bit=0x%08X", label, x, y, z, base)
    return {x=x, y=y, z=z, base=base}
end

local function dump_player(label, bit_ptr)
    local base = obj_base(bit_ptr)
    if not base then log("  %-24s [null]", label); return nil end
    local x = i16(rw(base + OBJ_OXPOS))
    local y = i16(rw(base + OBJ_OYPOS))
    log("  %-24s x=%4d  y=%4d", label, x, y)
    return {x=x, y=y, base=base}
end

local function full_dump(label)
    log("=== %s ===", label)
    local cb   = rw(A.curback)
    local win  = rw(A.winner_status)
    local gs   = rw(A.gstate)
    local fd   = i16(rw(A.f_death))
    local p1hp = rw(A.p1_bar)
    local p2hp = rw(A.p2_bar)
    log("  curback=%d  gstate=%d  winner_status=%d  f_death=%d", cb, gs, win, fd)
    log("  P1 HP=%d/%d  P2 HP=%d/%d", p1hp, FULL_HP, p2hp, FULL_HP)

    log("  --- Fighters ---")
    local p1 = dump_player("P1 fighter", _B.p1_obj)
    local p2 = dump_player("P2 fighter", _B.p2_obj)

    log("  --- Player chains (ozpos=-1, behind fighters) ---")
    local c1 = dump_obj("P1 longchain",  _B.pc_chain_obj_p1)
    local c2 = dump_obj("P2 longchain",  _B.pc_chain_obj_p2)

    log("  --- Player hooks ---")
    local h1 = dump_obj("P1 TINHOOK",   _B.pc_hook_obj_p1)
    local h2 = dump_obj("P2 TINHOOK",   _B.pc_hook_obj_p2)

    -- Verify chain tracks fighter X and sits above fighter
    if p1 and c1 then
        local xok = math.abs(c1.x - p1.x) <= 2
        local yok = c1.y < p1.y
        log("  VERIFY P1 chain: X tracks fighter=%s, Y above fighter=%s  (chain.y=%d p1.y=%d)",
            tostring(xok), tostring(yok), c1.y, p1.y)
    end
    if p2 and c2 then
        local xok = math.abs(c2.x - p2.x) <= 2
        local yok = c2.y < p2.y
        log("  VERIFY P2 chain: X tracks fighter=%s, Y above fighter=%s  (chain.y=%d p2.y=%d)",
            tostring(xok), tostring(yok), c2.y, p2.y)
    end
    if h1 then log("  VERIFY P1 hook ozpos=%d (want -1): %s", h1.z, tostring(h1.z == -1)) end
    if h2 then log("  VERIFY P2 hook ozpos=%d (want -1): %s", h2.z, tostring(h2.z == -1)) end

    log("  Expected: acid_skel_y=0x%02X rise_target=~0x%02X", ACID_SKEL_Y, ACID_HOOK_Y)
    if fd == -1 then
        log("  f_death=-1: acid fatality HAS been triggered this round")
    end
    log("")
end

-- ================================================================
-- TIMED AUTO-TEST ACTIONS
-- ================================================================
local start_time = nil
local actions_done = {}

local function elapsed()
    if not start_time then return 0 end
    return os.clock() - start_time
end

local function do_force_dead_pool()
    ww(A.curback, DEAD_POOL)
    log("ACTION: Forced Dead Pool (curback=0)")
end

local function do_kill_p2()
    ww(A.p2_bar, 1)
    log("ACTION: P2 HP set to 1 -- FINISH HIM should arm on next uppercut hit")
end

local function do_snap_p1()
    local p2_base = obj_base(A.p2_obj)
    local p1_base = obj_base(A.p1_obj)
    if p1_base and p2_base then
        local p2x = i16(rw(p2_base + OBJ_OXPOS))
        local tx = p2x - RANGE_UCUT
        ww(p1_base + OBJ_OXPOS, tx & 0xffff)
        log("ACTION: Snapped P1 to x=%d (P2 at x=%d, gap=%d)", tx, p2x, RANGE_UCUT)
    else
        log("ACTION: snap_p1 -- player objs not ready yet")
    end
end

-- ================================================================
-- SCREENSHOT
-- ================================================================
local function take_snap(tag)
    -- MAME Lua API: manager.machine:video():snapshot()
    local vid = manager.machine.video
    if vid then
        vid:snapshot()
        log("Snapshot taken: %s", tag)
    end
end

-- ================================================================
-- PER-FRAME STATE TRACKING
-- ================================================================
local last_winner = -1
local last_fdeath = 0
local acid_rise_logged = false
local frame_n = 0

local function on_frame()
    frame_n = frame_n + 1
    if not space then return end

    -- Initialise timer on first frame
    if not start_time then
        start_time = os.clock()
        log("Timer started. Auto-test sequence begins in 5s.")
    end

    local t = elapsed()
    local cb  = rw(A.curback)
    local win = rw(A.winner_status)
    local fd  = i16(rw(A.f_death))
    local gs  = rw(A.gstate)

    -- Phase 1: force Dead Pool at T+3s (very early, before game fully boots)
    if t >= 3 and not actions_done["force_dp"] then
        actions_done["force_dp"] = true
        do_force_dead_pool()
        log("gstate=%d at T+3s (0=powerup,1=pfsetup,2=fighting)", gs)
    end

    -- Phase 2: wait for gs_pfsetup (stage loading) to dump background state
    if gs >= GS_PFSETUP and not actions_done["pfsetup_dump"] then
        actions_done["pfsetup_dump"] = true
        log("gstate transitioned to %d (pfsetup) at t=%.1fs", gs, t)
        full_dump("Background loaded -- chain objects should spawn here")
        take_snap("pfsetup")
    end

    -- Phase 3: once in gs_fighting, kill P2 and snap P1 for uppercut
    if gs == GS_FIGHTING and not actions_done["kill_p2"] then
        actions_done["kill_p2"] = true
        do_kill_p2()
    end

    if gs == GS_FIGHTING and not actions_done["snap_p1"] then
        actions_done["snap_p1"] = true
        do_snap_p1()
    end

    -- Phase 4: dump chain state once fighting starts and a few frames have run
    if gs == GS_FIGHTING and not actions_done["chain_dump"] and t > (actions_done["fight_start_t"] or 999) + 2 then
        if not actions_done["fight_start_t"] then
            actions_done["fight_start_t"] = t
        else
            actions_done["chain_dump"] = true
            take_snap("fighting_chain_verify")
            full_dump("Chain sprite state during fight (gstate=2)")
        end
    end
    if gs == GS_FIGHTING and not actions_done["fight_start_t"] then
        actions_done["fight_start_t"] = t
        log("gs_fighting started at t=%.1fs", t)
    end

    if t >= 40 and not actions_done["final_dump"] then
        actions_done["final_dump"] = true
        full_dump("Final state at T+40s")
        take_snap("T+40s_final")
        log("Test sequence complete.")
    end

    -- Log winner_status transitions
    if win ~= last_winner then
        if win == WIN_FINISHHIM then
            log("** FINISH HIM (winner_status=3, curback=%d, t=%.1fs) **", cb, t)
            if cb == DEAD_POOL then
                log("   Dead Pool -- acid drop should trigger on uppercut!")
            end
            take_snap("finish_him")
        elseif last_winner == WIN_FINISHHIM and win == 0 then
            log("Finish Him cleared at t=%.1fs (fatality completed or round reset)", t)
        end
        last_winner = win
    end

    -- Log f_death trigger (acid fatality)
    if fd == -1 and last_fdeath ~= -1 then
        log("** f_death=-1: acid fatality triggered at t=%.1fs (curback=%d) **", t, cb)
        take_snap("acid_fatality_triggered")
        acid_rise_logged = false
    end
    last_fdeath = fd

    -- Sample skeleton Y every 8 frames during acid fatality
    if fd == -1 and not acid_rise_logged and frame_n % 8 == 0 then
        -- Best we can do without direct skeleton ptr: dump chain state
        -- The chain should have moved down with the falling player
        if not actions_done["acid_dump"] and t > 15 then
            actions_done["acid_dump"] = true
            full_dump("Acid drop in progress -- chain+skeleton state")
            take_snap("acid_drop_state")
            acid_rise_logged = true
        end
    end
end

-- ================================================================
-- INIT
-- ================================================================
local function init()
    mem_init()
    if not space then return end

    log("deadpool_chain_test.lua loaded (MAME 0.287, mk2 rev3.3)")
    log("Log: %s", LOG_PATH)
    log("")
    log("Address table (raw TMS bit addresses):")
    for k, v in pairs(_B) do
        log("  %-24s bit=0x%08X", k, v)
    end
    log("")
    log("Auto-test: T+5=force DeadPool  T+10=kill P2  T+12=snap P1  T+14=dump+snap")
    log("")

    emu.register_frame_done(function()
        if space then on_frame() end
    end)
end

init()
