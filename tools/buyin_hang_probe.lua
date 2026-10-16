-- buyin_hang_probe.lua
--
-- The continue / buy-in screen (gs_buyin = 3) is reached but never leaves --
-- buyin_crash_probe.log shows gstate stuck at 3 for 7000+ ticks with no trap.
-- So the master process is PARKED in one of do_buyin's sleep loops, not
-- crashed.  This probe says WHICH one.
--
-- prcslp (MPROC.ASM) saves A7-A12 into the process block before sleeping:
--     pwake(A7)=0xe0  pa8(A8)=0xc0  A9=0xa0  A10=0x80  A11=0x60  A12=0x40
--     ptime=0x30  procid=0x20   next=0x00
-- so the parked PC and the countdown registers are all readable from RAM.
--
-- Resume addresses in do_buyin (from tools/buyin_dasm.txt):
--     0xffa703d0  buyin2       - waiting on f_novel (menu slide finished?)
--     0xffa70860  bcount4      - the tick countdown itself
--     0xffa70700  coins_were_added (re-entered when get_credits changes)
--
-- Env: BUYIN_LOG
-- Usage: tools\run_buyin_hang_probe.ps1

local LOGP = os.getenv("BUYIN_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/buyin_hang_probe.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[buyin] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), active = sym("active"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), winner_status = sym("winner_status"),
    f_novel = sym("f_novel"), l_decoy = sym("l_decoy"),
    f_auto_erase = sym("f_auto_erase"),
    call_every_tick = sym("call_every_tick"),
    f_start_pressed = sym("f_start_pressed"),
    baklst1 = sym("baklst1"), baklst2 = sym("baklst2"),
    baklst3 = sym("baklst3"), baklst4 = sym("baklst4"),
    do_buyin = sym("do_buyin"),
}

-- process block offsets (bits), see header
local P_NEXT, P_PROCID, P_PTIME = 0x00, 0x20, 0x30
local P_A12, P_A11, P_A10, P_A9, P_A8, P_WAKE = 0x40, 0x60, 0x80, 0xa0, 0xc0, 0xe0
local P_ANIRATE, P_ANICOUNT = 0x100 + 0xd0, 0x100 + 0xe0
local PID_MASTER = 3

local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING, GS_BUYIN = 4, 2, 3
local P1_CHAR, P2_CHAR, STAGE = 1, 11, 0    -- kang vs jax, dead pool

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local buyin_frame, samples, done, did_select = 0, 0, false, false
local fields = {}
local last_gstate = -1

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end

local function finish(why)
    if done then return end
    done = true
    log("DONE: %s", why)
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

local function list_len(head)
    local n, p = 0, r32(head)
    while p ~= 0 and n < 64 do n = n + 1; p = r32(p) end
    return n
end

local function dump()
    samples = samples + 1
    log("---- sample %d (frame %d, %d ticks into gs_buyin) ----",
        samples, frame, frame - buyin_frame)
    log("  gstate=%d p1_state=%d p2_state=%d winner=%d",
        r16(A.gstate), r16(A.p1_state), r16(A.p2_state), r16(A.winner_status))
    log("  f_novel=%d l_decoy=%d f_auto_erase=%d f_start_pressed=%d call_every_tick=0x%08x",
        r16(A.f_novel), r16(A.l_decoy), r16(A.f_auto_erase),
        r16(A.f_start_pressed), r32(A.call_every_tick))
    log("  baklst 1/2/3/4 lengths = %d/%d/%d/%d",
        list_len(A.baklst1), list_len(A.baklst2), list_len(A.baklst3), list_len(A.baklst4))

    local p, n = r32(A.active), 0
    while p ~= 0 and n < 48 do
        n = n + 1
        local pid = r16(p + P_PROCID)
        local wake = r32(p + P_WAKE)
        local tag = ""
        if pid == PID_MASTER then tag = "  <== MASTER" end
        if wake == 0xffa703d0 then tag = tag .. "  [buyin2: waiting on f_novel]" end
        if wake == 0xffa70860 then tag = tag .. "  [bcount4: countdown]" end
        if wake == 0xffa70700 then tag = tag .. "  [coins_were_added]" end
        log("  proc 0x%08x pid=%3d ptime=%5d pwake=0x%08x a11=%d a10=%d anicount=%d anirate=%d%s",
            p, pid, r16(p + P_PTIME), wake,
            r32(p + P_A11), r32(p + P_A10),
            r16(p + P_ANICOUNT), r16(p + P_ANIRATE), tag)
        p = r32(p + P_NEXT)
    end
    log("  (%d active processes)", n)
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- buyin hang probe: do_buyin=0x%08x active=0x%08x ----",
            A.do_buyin, A.active)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, P1_CHAR)
        w16(A.p2_char, P2_CHAR)
        w16(A.curback, STAGE)
        if A.map_position ~= 0 then w16(A.map_position, STAGE) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if not did_select then did_select = true; log("forced kang vs jax on stage %d", STAGE) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then finish("never reached fight") end
        return
    end

    if gs ~= last_gstate then
        log("gstate %d -> %d at frame %d (p1_hp=%d p2_hp=%d)",
            last_gstate, gs, frame, r16(A.p1_bar), r16(A.p2_bar))
        last_gstate = gs
    end

    if gs == GS_BUYIN then
        if buyin_frame == 0 then
            buyin_frame = frame
            log("*** entered gs_buyin at frame %d ***", frame)
        end
        local rel = frame - buyin_frame
        if rel == 30 or rel == 120 or rel == 300 or rel == 600 or
           rel == 900 or rel == 1200 or rel == 1800 or rel == 2400 then
            dump()
        end
        if rel > 2600 then finish("still in gs_buyin after 2600 ticks - HUNG") end
    elseif buyin_frame > 0 then
        log("*** LEFT gs_buyin after %d ticks -> gstate %d (no hang) ***",
            frame - buyin_frame, gs)
        finish("buyin completed normally")
    end

    if frame - fighting_frame > 12000 then finish("match never ended") end
    if frame > 24000 then finish("global timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
