--[[
    mk2_test.lua  —  MK2 fight test helper for MAME
    Usage: mame.exe mk2 -lua mk2_test.lua

    Hotkeys (while MAME window is active):
      Ins   = Kill P2 to 1 HP  (trigger FINISH HIM)
      Home  = Snap P1 to close fatality range
      End   = Snap P1 to far/sweep fatality range
      PgUp  = Dump game state to console + log
      PgDn  = Toggle auto-drain (keeps P2 at 1 HP every frame)
      Del   = Run input sequence manually

    First run prints all port/field names to the log.
    Configure CFG.p1_port_tag and CFG.sequence after checking the log.

    After any rebuild, update _B table:
      python sym_resolve.py --dump | grep <symbol>   -> gives BIT address
      MAME byte addr = bit_addr // 8
--]]

-- ============================================================
-- CONFIGURATION  (edit this section)
-- ============================================================
local CFG = {
    log_file      = "C:\\Users\\you\\Workplace\\mk2-main\\mk2_test_log.txt",
    watch_crash   = true,
    crash_secs    = 3,

    -- P1 snap distances in screen pixels (P1 left of P2, facing right)
    range_close   = 60,    -- decapitation / blade range
    range_far     = 110,   -- sweep / stomp range

    -- Port tag for P1 inputs — check log after first run, e.g. ":IN1"
    -- Leave nil to auto-detect (looks for fields named "P1 *")
    p1_port_tag   = nil,

    -- Set true to auto-run sequence when FINISH HIM fires
    auto_run_seq  = false,
    -- Frames to wait after FINISH HIM before launching sequence
    auto_seq_delay = 30,
    -- Set true to force a background index during emulation.
    auto_set_background  = false,
    -- WAFFLE HOUSE background index (17h in source tables, 23 decimal)
    forced_background    = 23,

    -- Input sequence: list of { hold_frames, field_name }
    -- field_name must match exactly what appears in the port listing.
    -- Use "" or nil for a release/gap frame block.
    --
    -- JC headhole: Back Back Back HP (P1 facing right)
    -- Uncomment and adjust field names to match your MAME version:
    --
    -- sequence = {
    --     {12, "P1 Left"},
    --     { 6, ""},
    --     {12, "P1 Left"},
    --     { 6, ""},
    --     {12, "P1 Left"},
    --     { 6, ""},
    --     { 6, "P1 Button 1"},   -- HP; button name varies by MAME driver
    -- },
    sequence      = nil,
}

-- ============================================================
-- ADDRESS TABLE
-- Values are TMS34010 BIT addresses directly from mk2.map.
-- MAME byte addr = bit_addr // 8.
-- ============================================================
local _B = {
    gstate    = 0x0112a7f0,
    p1_state  = 0x0112a810,
    p1_obj    = 0x0112a840,  -- 32-bit ptr -> P1 object block (itself a bit addr)
    p1_char   = 0x0112a8a0,
    p1_bar    = 0x0112a910,
    p1_matchw = 0x0112a930,
    p2_state  = 0x0112b3e0,
    p2_obj    = 0x0112b410,
    p2_char   = 0x0112b470,
    p2_bar    = 0x0112b4e0,
    p2_matchw = 0x0112b500,
    curback   = 0x0112c0f0,
    round_num = 0x0112c120,
    winner_status = 0x0112c130,
}

-- Object block field byte offsets (DISPEQU.ASM bit offsets / 8)
local OBJ = { oxval=0x80//8, oxpos=0x90//8, oyval=0xa0//8, oypos=0xb0//8 }
--            oxval=16       oxpos=18        oyval=20        oypos=22

-- MAME byte addresses
local A = {}
for k, v in pairs(_B) do A[k] = v // 8 end

-- Game constants
local FULL_HP  = 0xa1    -- 161 max health (from MAINEQU.ASM full_strength)
local PB_FIN   = 0x0001  -- matchw bit: "I finish other guy"
local GS_FIGHT = 0x0002  -- gstate value during active round

-- Character names (ft_* equates from MAINEQU.ASM)
local CNAMES = {
    [0]="KungLao", [1]="LiuKang",  [2]="JCage",   [3]="Baraka",
    [4]="Kitana",  [5]="Mileena",  [6]="Shang",    [7]="Raiden",
    [8]="SubZero", [9]="Reptile",  [10]="Scorpion",[11]="Jax",
    [12]="Kintaro",[13]="SHaoKahn",[14]="Smoke",   [15]="Noob", [16]="Jade",
}
local function cname(n) return CNAMES[n] or ("??["..tostring(n).."]") end

-- ============================================================
-- MEMORY ACCESS
-- ============================================================
local space

local function mem_init()
    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then print("[mk2] ERROR: no :maincpu device"); return end
    space = cpu.spaces["program"]
    if not space then print("[mk2] ERROR: no program address space") end
end

local function rw(a)  return space:read_u16(a) end
local function ww(a,v) space:write_u16(a, v & 0xffff) end
local function rl(a)  return space:read_u32(a) end
local function wl(a,v) space:write_u32(a, v & 0xffffffff) end

-- Sign-extend a 16-bit value
local function i16(v) return (v >= 0x8000) and (v - 0x10000) or v end

-- Return byte base of player object, or nil if object not present
local function obj_base(obj_ptr_addr)
    local bits = rl(obj_ptr_addr)
    if bits == 0 then return nil end
    return bits // 8
end

local function read_xpos(obj_ptr_addr)
    local b = obj_base(obj_ptr_addr)
    if not b then return nil end
    return i16(rw(b + OBJ.oxpos))
end

local function write_xpos(obj_ptr_addr, x)
    local b = obj_base(obj_ptr_addr)
    if not b then return false end
    ww(b + OBJ.oxpos, x)
    wl(b + OBJ.oxval, (x << 16) & 0xffffffff)  -- integer part high word, zero fraction
    return true
end

-- ============================================================
-- LOGGING
-- ============================================================
local logf

local function log(msg)
    local s = string.format("[%s] %s\n", os.date("%H:%M:%S"), msg)
    io.write(s); io.flush()
    if logf then logf:write(s); logf:flush() end
end

-- ============================================================
-- STATE DUMP
-- ============================================================
local function dump_state()
    local gs  = rw(A.gstate)
    local rnd = rw(A.round_num)
    local bk  = rw(A.curback)
    local p1h = rw(A.p1_bar)
    local p2h = rw(A.p2_bar)
    local p1m = rw(A.p1_matchw)
    local p2m = rw(A.p2_matchw)
    local p1c = rw(A.p1_char)
    local p2c = rw(A.p2_char)
    local p1x = read_xpos(A.p1_obj)
    local p2x = read_xpos(A.p2_obj)
    local dist = (p1x and p2x) and math.abs(p2x - p1x) or -1
    log(string.format(
        "gs=%04x rnd=%d bg=%d | P1:%s hp=%d mw=%04x x=%s | P2:%s hp=%d mw=%04x x=%s | dist=%d",
        gs, rnd, bk,
        cname(p1c), p1h, p1m, tostring(p1x),
        cname(p2c), p2h, p2m, tostring(p2x), dist))
end

-- ============================================================
-- ACTIONS
-- ============================================================
local auto_drain = false

local function act_kill_p2()
    ww(A.p2_bar, 1)
    log("P2 HP -> 1")
end

local function act_close()
    local p2x = read_xpos(A.p2_obj)
    if not p2x then log("close: no P2 object"); return end
    if write_xpos(A.p1_obj, p2x - CFG.range_close) then
        log(string.format("P1 -> close range (%dpx from P2 @ x=%d)", CFG.range_close, p2x))
    end
end

local function act_far()
    local p2x = read_xpos(A.p2_obj)
    if not p2x then log("far: no P2 object"); return end
    if write_xpos(A.p1_obj, p2x - CFG.range_far) then
        log(string.format("P1 -> far range (%dpx from P2 @ x=%d)", CFG.range_far, p2x))
    end
end

local function act_toggle_drain()
    auto_drain = not auto_drain
    log("auto-drain: " .. (auto_drain and "ON" or "OFF"))
end

local function apply_background()
    if not CFG.auto_set_background or not space then return end
    local target = CFG.forced_background & 0xff
    if rw(A.curback) ~= target then
        ww(A.curback, target)
        log("Forcing background to " .. tostring(target))
    end
end

-- ============================================================
-- INPUT PORTS  (enumerate on start, then configure above)
-- ============================================================
local p1_fields = {}

-- Modern MAME: the port table lives at manager.machine.ioports.ports
local function port_table()
    local ok, iom = pcall(function() return manager.machine.ioports end)
    if not ok or not iom then return {} end
    local ok2, ports = pcall(function() return iom.ports end)
    if ok2 and ports then return ports end
    return iom
end

local function enum_ports()
    log("--- Input ports ---")
    for tag, port in pairs(port_table()) do
        local names = {}
        for name, _ in pairs(port.fields) do table.insert(names, name) end
        if #names > 0 then
            table.sort(names)
            log(string.format("  [%s]: %s", tag, table.concat(names, " | ")))
        end
    end
    log("---")
end

local function find_p1_port()
    local n = 0
    for t, port in pairs(port_table()) do
        for name, field in pairs(port.fields) do
            if name:match("^P1") or name:match("^1 Player") then
                p1_fields[name] = field
                n = n + 1
            end
        end
    end
    if n == 0 then
        log("WARNING: no P1 fields found — input injection disabled")
        return
    end
    local names = {}
    for name, _ in pairs(p1_fields) do table.insert(names, name) end
    table.sort(names)
    log(string.format("P1 fields ready (%d): %s", n, table.concat(names, " | ")))
end

-- Find a P1 field by pattern, e.g. field_like("High Kick")
local function field_like(pat)
    for name, field in pairs(p1_fields) do
        if name:match(pat) then return field, name end
    end
    return nil
end

-- ============================================================
-- INPUT SEQUENCE PLAYER
-- ============================================================
local seq_active    = false
local seq_step      = 1
local seq_ticks     = 0
local seq_cur_field = nil

local function seq_release()
    if seq_cur_field then
        pcall(function() seq_cur_field:set_value(0) end)
        seq_cur_field = nil
    end
end

local function seq_start()
    if not CFG.sequence then
        log("No sequence configured — set CFG.sequence in the script")
        return
    end
    seq_release()
    seq_active = true
    seq_step   = 1
    seq_ticks  = 0
    log("Sequence started")
end

local function seq_tick()
    if not seq_active then return end
    local step = CFG.sequence[seq_step]
    if not step then
        seq_release()
        seq_active = false
        log("Sequence done")
        return
    end
    local hold, fname = step[1], step[2]
    if seq_ticks == 0 then
        seq_release()
        if fname and fname ~= "" then
            local f = p1_fields[fname]
            if f then
                pcall(function() f:set_value(1) end)
                seq_cur_field = f
            else
                log("WARNING: field not found: [" .. fname .. "]")
            end
        end
    end
    seq_ticks = seq_ticks + 1
    if seq_ticks >= hold then
        seq_step  = seq_step + 1
        seq_ticks = 0
    end
end

-- ============================================================
-- AUTO-FATALITY DRIVER
-- Fully hands-off test: KO P2 with HK, wait for FINISH HIM,
-- snap to sweep range, press HK to fire the fatality hook.
-- ============================================================
local GS_AMODE  = 0x0001
local auto_fatal = {
    enabled  = true,
    state    = "wait_fight",
    timer    = 0,
    hk       = nil,      -- P1 HK field, resolved lazily
    hk_name  = nil,
    range    = 90,       -- inside the 0x60 (96px) sweep gate
}

local function af_press_hk(hold)
    if not auto_fatal.hk then
        auto_fatal.hk, auto_fatal.hk_name = field_like("[Hh]igh [Kk]ick")
        if not auto_fatal.hk then
            auto_fatal.hk, auto_fatal.hk_name = field_like("HK")
        end
        if not auto_fatal.hk then
            log("AUTO: no P1 High Kick field — check port listing")
            auto_fatal.enabled = false
            return
        end
        log("AUTO: using field [" .. auto_fatal.hk_name .. "]")
    end
    pcall(function() auto_fatal.hk:set_value(1) end)
    auto_fatal.timer = hold
end

local function af_release_hk()
    if auto_fatal.hk then pcall(function() auto_fatal.hk:set_value(0) end) end
end

local function auto_fatal_tick()
    local af = auto_fatal
    if not af.enabled then return end

    -- hold/release timing for a pressed button
    if af.timer > 0 then
        af.timer = af.timer - 1
        if af.timer == 0 then af_release_hk() end
        return
    end

    local gs = rw(A.gstate)
    local ws = rw(A.winner_status)

    if af.state == "wait_fight" then
        if gs == GS_FIGHT and read_xpos(A.p1_obj) and read_xpos(A.p2_obj) then
            af.state = "intro_delay"
            af.timer2 = 180        -- let the round intro finish
        else
            -- Still on MAME's ROM-warning screen or game boot: pulse a P1
            -- input every second to click through ("press any key").
            af.boot = (af.boot or 0) + 1
            if af.boot % 60 == 0 then
                local f = field_like("Start") or field_like("[Hh]igh [Kk]ick")
                if f then
                    pcall(function() f:set_value(1) end)
                elseif af.boot % 120 == 0 then
                    log("AUTO: no pressable field yet for boot-skip")
                end
            elseif af.boot % 60 == 5 then
                local f = field_like("Start") or field_like("[Hh]igh [Kk]ick")
                if f then pcall(function() f:set_value(0) end) end
            end
        end
    elseif af.state == "intro_delay" then
        af.timer2 = af.timer2 - 1
        if af.timer2 <= 0 then
            ww(A.p2_bar, 1)
            log("AUTO: P2 HP -> 1, moving in for the KO")
            af.state = "ko"
        end
    elseif af.state == "ko" then
        if ws == 3 then
            log("AUTO: FINISH HIM detected")
            af.state = "finish_wait"
            af.timer2 = 90         -- let the dizzy stand-up settle
        elseif gs == GS_FIGHT and rw(A.p2_bar) >= 1 then
            local p2x = read_xpos(A.p2_obj)
            if p2x then
                write_xpos(A.p1_obj, p2x - 45)   -- point blank
                af_press_hk(8)                    -- HK -> KO
            end
        end
    elseif af.state == "finish_wait" then
        af.timer2 = af.timer2 - 1
        if af.timer2 <= 0 then
            local p2x = read_xpos(A.p2_obj)
            if p2x then
                write_xpos(A.p1_obj, p2x - af.range)
                log(string.format("AUTO: sweep range (%dpx), pressing HK", af.range))
                af_press_hk(8)
                af.state = "fired"
                af.timer2 = 600
            end
        end
    elseif af.state == "fired" then
        af.timer2 = af.timer2 - 1
        -- Snapshot the whole fatality: every 15 frames for ~10 seconds
        af.snap = (af.snap or 0) + 1
        if af.snap % 15 == 0 then
            pcall(function() manager.machine.video:snapshot() end)
        end
        if ws ~= 3 and af.timer2 < 540 then
            log("AUTO: fatality transferred (winner_status=" .. ws .. ") — watching")
        end
        if af.timer2 <= 0 then
            if ws == 3 then
                log("AUTO: no transfer after HK press — retrying")
                af.state = "finish_wait"
                af.timer2 = 30
            else
                log("AUTO: fatality sequence captured — done")
                af.state = "done"
            end
        end
    elseif af.state == "done" then
        -- harness restarts the fight; re-arm for the next loop
        if gs ~= GS_FIGHT and ws == 0 then
            af.state = "wait_fight"
            af.boot = 0
            af.snap = 0
            log("AUTO: re-armed for next fight")
        end
    end
end

-- ============================================================
-- FINISH HIM AUTO-TRIGGER
-- ============================================================
local finish_seen      = false
local finish_countdown = 0

local function finish_monitor()
    if not CFG.auto_run_seq or not CFG.sequence then return end
    local active = (rw(A.p1_matchw) & PB_FIN) ~= 0
    if active and not finish_seen then
        finish_seen     = true
        finish_countdown = CFG.auto_seq_delay
        log(string.format("FINISH HIM — sequence in %d frames", finish_countdown))
    end
    if not active then
        finish_seen     = false
        finish_countdown = 0
    end
    if finish_countdown > 0 then
        finish_countdown = finish_countdown - 1
        if finish_countdown == 0 and not seq_active then seq_start() end
    end
end

-- ============================================================
-- CRASH WATCHDOG
-- ============================================================
local wd_frame      = 0
local wd_time       = os.clock()
local wd_reported   = false

local function crash_watch(frame)
    if not CFG.watch_crash then return end
    if frame ~= wd_frame then
        wd_frame    = frame
        wd_time     = os.clock()
        wd_reported = false
    else
        local dt = os.clock() - wd_time
        if dt >= CFG.crash_secs and not wd_reported then
            log(string.format("!!! HANG: frame %d stuck %.1fs !!!", frame, dt))
            wd_reported = true
        end
    end
end

-- ============================================================
-- HOTKEYS
-- ============================================================
local input_sys
local debounce = {}

local HOTKEYS = {
    { "KEYCODE_INSERT", act_kill_p2      },
    { "KEYCODE_HOME",   act_close        },
    { "KEYCODE_END",    act_far          },
    { "KEYCODE_PGUP",   dump_state       },
    { "KEYCODE_PGDN",   act_toggle_drain },
    { "KEYCODE_DEL",    seq_start        },
}

local function hotkeys()
    for _, hk in ipairs(HOTKEYS) do
        local code = input_sys:code_from_token(hk[1])
        local down  = input_sys:code_pressed(code)
        if down and not debounce[hk[1]] then hk[2]() end
        debounce[hk[1]] = down
    end
end

-- ============================================================
-- FRAME CALLBACK
-- ============================================================
local frame_n = 0

local function on_frame()
    if not space then
        mem_init()
        if not space then return end
    end
    -- autoboot_script runs after machine start, so the register_start
    -- callback may never fire; lazily finish init here instead.
    if not input_sys then
        input_sys = manager.machine.input
        enum_ports()
        find_p1_port()
        log("Ready | Ins=kill P2 HP  Home=close range  End=far range  PgUp=dump  PgDn=drain  Del=sequence")
    end
    frame_n = frame_n + 1
    crash_watch(frame_n)
    hotkeys()
    apply_background()
    local gs = rw(A.gstate)

    if auto_drain and gs == GS_FIGHT then
        if rw(A.p2_bar) > 1 then ww(A.p2_bar, 1) end
    end

    finish_monitor()
    seq_tick()
    auto_fatal_tick()
end

-- ============================================================
-- STARTUP
-- ============================================================
logf = io.open(CFG.log_file, "a")
log("=== mk2_test.lua start ===")

-- All init happens lazily on the first frame (see on_frame): with
-- -autoboot_script the machine is already running when this file loads,
-- and register_start callbacks race machine bring-up.
emu.register_frame_done(on_frame)
