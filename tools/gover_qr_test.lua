-- gover_qr_test.lua - the Discord QR on GORO'S LAIR's game-over screen.
--
-- Plays a real 1P game to GAME OVER (P1 never touches the stick; his bar is
-- held at 1 so the CPU's first hit ends each round), with the ROM's
-- `movi 20,a0 / calla randper` in ending_gover_entry patched to 1000 IN
-- MEMORY so the GORO'S LAIR variant (2 in 1000 on a real board) is the one
-- that comes up.  GQ_NOPATCH=1 leaves the dice alone: the plain variant must
-- then show NO QR (gover_qr stays 0) - the control.
--
-- Reports: whether gover_qr was armed, how long, the worst `overload` /
-- `peak_overload` while it was, and snapshots at +30/+150/+300 frames.
--
-- Env: GQ_LOG, GQ_NOPATCH, GQ_MAP

local LOGP = os.getenv("GQ_LOG") or "C:/Users/you/Workplace/mk2-main/tools/gover_qr_test.log"
local MAP  = os.getenv("GQ_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local NOPATCH = os.getenv("GQ_NOPATCH") == "1"

if _G.GQ_LOADED then return end
_G.GQ_LOADED = true

local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[gq] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(MAP, "r")
    if not fh then log("FATAL no map %s", MAP) end
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n)
    local v = symbols[n]
    if not v then log("FATAL symbol %s missing from map", n) end
    return v or 0
end

local A = {
    gstate = sym("gstate"), p1_state = sym("p1_state"), p1_bar = sym("p1_bar"),
    gover_qr = sym("gover_qr"), overload = sym("overload"),
    peak_overload = sym("peak_overload"), randper = sym("randper"),
}

local cpu = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v) end

-- the dice ----------------------------------------------------------------
local function patch_dice()
    local reg = manager.machine.memory.regions[":maincpu"]
    if not reg then log("FATAL no :maincpu region"); return false end
    local lo, hi = A.randper & 0xffff, (A.randper >> 16) & 0xffff
    local hits = {}
    for off = 0, reg.size - 16, 2 do
        if reg:read_u16(off) == 0x09C0 and reg:read_u16(off + 2) == 0x0014
           and reg:read_u16(off + 4) == 0x0D5F and reg:read_u16(off + 6) == lo
           and reg:read_u16(off + 8) == hi and (reg:read_u16(off + 10) & 0xff00) == 0xC900
           and reg:read_u16(off + 12) == 0x192B then
            hits[#hits + 1] = off
        end
    end
    if #hits ~= 1 then log("FATAL dice pattern found %d times (want 1)", #hits); return false end
    if NOPATCH then log("dice left alone at 0x%x (control)", hits[1]); return true end
    reg:write_u16(hits[1] + 2, 1000)
    log("dice patched at region 0x%x: randper 20 -> 1000", hits[1])
    return true
end

-- inputs --------------------------------------------------------------------
local fields, held, frame = {}, {}, 0
for _, port in pairs(manager.machine.ioport.ports) do
    for _, f in pairs(port.fields) do
        if f.name == "Coin 1" or f.name == "1 Player Start" or f.name == "P1 Start" or f.name == "Start 1" then
            fields[f.name] = f
        end
    end
end
local START = fields["1 Player Start"] or fields["P1 Start"] or fields["Start 1"]
local function press(f, n) if f then held[f] = frame + n end end

local st, mark, armed_at, armed_frames = "boot", 0, nil, 0
local worst_ol, worst_peak, snaps = 0, 0, 0
local saw_gameover = false

local function finish(verdict)
    log("RESULT %s armed_frames=%d worst_overload=%d peak_overload=%d snaps=%d",
        verdict, armed_frames, worst_ol, worst_peak, snaps)
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

emu.register_frame_done(function()
    frame = frame + 1
    for f, til in pairs(held) do
        if frame < til then f:set_value(1) else f:set_value(0); held[f] = nil end
    end
    local gs = r16(A.gstate)

    if st == "boot" then
        if frame == 2 then if not patch_dice() then finish("NO_VERDICT") end end
        if gs == 1 and frame > 300 then
            st = "coin"; mark = frame
            log("attract at frame %d", frame)
        end
    elseif st == "coin" then
        local k = frame - mark
        if k == 10 or k == 40 then press(fields["Coin 1"], 8) end
        if k == 90 then press(START, 8) end
        if k == 100 then st = "play"; log("started, gs=%d", gs) end
    elseif st == "play" then
        -- tap START on the character select so it never waits on us
        if gs == 4 and frame % 120 == 0 then press(START, 6) end
        if gs == 2 then
            local b = r16(A.p1_bar)
            if b > 1 and b < 0x8000 then w16(A.p1_bar, 1) end
        end
        if gs == 0x0b then saw_gameover = true end
        local q = r16(A.gover_qr)
        if q ~= 0 then
            if not armed_at then
                armed_at = frame
                log("gover_qr armed at frame %d (gstate %d)", frame, gs)
                w16(A.peak_overload, 0)
            end
            armed_frames = armed_frames + 1
            local ol = r16(A.overload)
            if ol > worst_ol and ol < 0x8000 then worst_ol = ol end
            local pk = r16(A.peak_overload)
            if pk > worst_peak and pk < 0x8000 then worst_peak = pk end
            local k = frame - armed_at
            if k == 30 or k == 150 or k == 300 then
                manager.machine.video:snapshot(); snaps = snaps + 1
                log("snapshot at armed+%d", k)
            end
        elseif armed_at then
            log("gover_qr cleared at frame %d after %d frames (gstate %d)", frame, armed_frames, gs)
            finish(NOPATCH and "FAIL_control_armed" or "PASS")
            return
        end
        if saw_gameover and gs == 1 and not armed_at then
            finish(NOPATCH and "PASS_control" or "FAIL_never_armed")
            return
        end
    end
end)

log("loaded; map gover_qr=%08x randper=%08x nopatch=%s", A.gover_qr, A.randper, tostring(NOPATCH))
