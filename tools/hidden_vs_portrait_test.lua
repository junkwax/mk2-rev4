-- hidden_vs_portrait_test.lua
-- Proves a hidden fighter's own VS portrait reaches the screen.
--
-- The four hidden fighters each used to borrow the picture of the character
-- they unlock from, because none of them had art of their own.  They now have
-- appended zipped_pics slots:
--
--   MK2_VS_CHAR=noob   ft_noob  (15) -> VS_NB, slot 10h, VSNBMOV.LOD (video ROM)
--   MK2_VS_CHAR=jade   ft_jade  (16) -> VS_JD, slot 11h, VSJDMOV.LOD (video ROM)
--   MK2_VS_CHAR=smoke  ft_smoke (14) -> VS_SM, slot 12h, VSSMMOV.LOD (video ROM)
--   MK2_VS_CHAR=ermac  ft_ermac (17) -> VS_EM, slot 13h, MK8MIL.LOD  (PROGRAM ROM)
--   MK2_VS_CHAR=rain   ft_rain  (19) -> VS_RN, slot 14h, MK8MIL.LOD  (PROGRAM ROM)
--
-- (The slots were 28h/29h/2ah until the endings were retired on 2026-08-11.)
--
-- tools/verify_movies.py already proves each payload decodes out of the ROM
-- byte-for-byte, so what is left to check is the DISPATCH: that the VS screen
-- really pulls the appended index for that pick rather than clamping to 0
-- (Kung Lao) or borrowing a neighbour.
--
-- Method: reach character select, confirm BOTH players, and hold the fighter's
-- unlock flag set so <char>_select_cheat_apply (MAIN.ASM) overrides p1_char
-- right before vs_screen runs - the same path the real select-screen unlock
-- takes, without having to drive its stick/button sequence.  Then snapshot the
-- VS page.
--
-- It MUST be a 2-player game.  vs_screen (MKSEL.ASM) opens with
--
--     calla count_active_players
--     cmpi  2,a0
--     jrne  vs_exit
--
-- so on a 1P game there is no VS page at all: gstate passes through 0dh in two
-- frames and no portrait is ever drawn.  A 1P run of this harness would still
-- report PASS on p1_char while proving nothing about the portrait, which is
-- exactly the false green this comment exists to prevent.
--
--   $env:MK2_VS_CHAR="smoke"
--   powershell tools/run_mame_small.ps1 `
--       -Script "<abs path>/tools/hidden_vs_portrait_test.lua" `
--       -SnapshotDirectory "<abs path>/tools/snap_vs" `
--       -OutputDirectory "<abs path>/tools/snap_vs" `
--       -AutoCloseSeconds 150 -NoSound -NoThrottle
--
-- NOTE: -Script must be an ABSOLUTE path - run_mame_small.ps1 launches MAME
-- with its working directory set to C:\MAME, so a repo-relative path fails
-- with "Error loading autoboot script" and the lua never runs.
--
-- NOTE 2: if you invoke mame.exe DIRECTLY (the reliable route when
-- run_mame_small.ps1's Start-Process silently fails to load the script), it
-- runs with the REPO as its working directory and therefore picks up
-- ./cfg/mk2.cfg and ./nvram/mk2 instead of C:\MAME's.  The repo's committed
-- cfg/mk2.cfg has the TEST switch held on:
--
--     <port tag=":IN1" type="DIPSWITCH" mask="16" defvalue="16" value="0" />
--
-- so the ROM boots straight into the MK2 TEST MENU and parks in gstate 8
-- (gs_diag) forever.  That looks exactly like a boot regression in whatever
-- you just changed.  Always pass isolated directories:
--
--     -cfg_directory <scratch>/cfg  -nvram_directory <scratch>/nvram
--
-- which also keeps MAME from rewriting the tracked repo files on exit.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")

-- name -> { fighter id, unlock flag symbol, zipped_pics slot (for the log) }
local CHARS = {
    noob  = { ft = 15, flag = "f_noob_cheat1",  slot = 0x10 },
    jade  = { ft = 16, flag = "f_jade_cheat1",  slot = 0x11 },
    smoke = { ft = 14, flag = "f_smoke_cheat1", slot = 0x12 },
    ermac = { ft = 17, flag = "f_ermac_cheat1", slot = 0x13 },
    rain  = { ft = 19, flag = "f_rain_cheat1",  slot = 0x14 },
}
local WHICH = (os.getenv("MK2_VS_CHAR") or "jade"):lower()
local CH = CHARS[WHICH]

local LOG = os.getenv("MK2_VS_LOG")
    or (ROOT .. "/tools/hidden_vs_portrait_" .. WHICH .. ".log")
local logfh = io.open(LOG, "w")
local raw = print
print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    local l = table.concat(t, "\t")
    raw(l); if logfh then logfh:write(l, "\n"); logfh:flush() end
end
local function log(f, ...)
    print("[vsport] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f)))
end

if not CH then
    log("ERROR unknown MK2_VS_CHAR=%q - expected noob, jade, smoke, ermac or rain", WHICH)
    return
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n)
    local v = symbols[n]
    if not v then log("WARN missing symbol %s", n) end
    return v or 0
end

local A = {
    gstate   = sym("gstate"),
    p1_char  = sym("p1_char"),
    p2_char  = sym("p2_char"),
    cheat    = sym(CH.flag),
}

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local frame, cpu, space = 0, nil, nil
local fields = {}
local last_gs, charsel_frame, vs_frame, fighting_frame = -1, 0, 0, 0
local p1_confirm_start = 0
local snaps, forced, saw_target = 0, 0, false
local done = false

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v) end

local function cache_fields()
    local want = {
        ["Coin 1"] = true, ["Coin 2"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    local missing = {}
    for n in pairs(want) do if not fields[n] then missing[#missing + 1] = n end end
    if #missing > 0 then log("WARN unmatched ioport fields: %s", table.concat(missing, ", ")) end
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end) end
    snaps = snaps + 1
    log("SNAP %d %s (p1_char=%d p2_char=%d)", snaps, label, r16(A.p1_char), r16(A.p2_char))
end

local function pressed(name)
    -- Coin-mode path only; this build boots FREE PLAY, so the select screen
    -- opens on its own and these must then stay quiet or they desync it.
    if name == "Coin 1" or name == "Coin 2" then
        return charsel_frame == 0 and frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then
        return charsel_frame == 0 and frame >= 1000 and frame < 1080
    end
    if name == "2 Players Start" then
        -- Join P2 as soon as the select screen opens so this is a 2P game -
        -- without it vs_screen exits immediately and draws no portrait.
        if charsel_frame > 0 and fighting_frame == 0 then
            local r = frame - charsel_frame
            return r >= 5 and r < 45
        end
        return charsel_frame == 0 and frame >= 1040 and frame < 1140
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        -- P1 confirms whoever is highlighted; the unlock flag overrides the
        -- pick afterwards, so which character it is does not matter.
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
        -- Stage select sits on the VS page.  vs_screen takes over page
        -- flipping and composes into page 0 while page 1 still shows the
        -- grabbed select screen, so the page is not visible - and not ready
        -- for input - for a few hundred frames.  Pulse rather than firing one
        -- fixed window, and keep pulsing until gstate leaves 0dh.
        if name == "P1 Low Kick" and vs_frame > 0 then
            local rel = frame - vs_frame
            return rel >= 600 and (rel % 90) < 20
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("testing %s: expect p1_char=%d, zipped_pics slot %02xh, flag %s@%08x",
            WHICH, CH.ft, CH.slot, CH.flag, A.cheat)
    end

    if space and not done then
        local gs = r16(A.gstate)
        if gs ~= last_gs then
            log("frame=%d gstate %d -> %d", frame, last_gs, gs)
            if gs == GS_PSEL and charsel_frame == 0 then
                charsel_frame = frame
                p1_confirm_start = frame + 60
            end
            if gs == GS_POST and vs_frame == 0 then
                vs_frame = frame
                log("VS page opened at frame %d, p1_char=%d p2_char=%d",
                    frame, r16(A.p1_char), r16(A.p2_char))
            end
            if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
            last_gs = gs
        end

        -- Hold the unlock flag through select so <char>_select_cheat_apply picks
        -- it up on the way out.  It clears the flag itself once applied.
        if charsel_frame > 0 and vs_frame == 0 and A.cheat ~= 0 then
            if r16(A.cheat) ~= 1 then
                w16(A.cheat, 1)
                forced = forced + 1
            end
        end

        if r16(A.p1_char) == CH.ft and not saw_target then
            saw_target = true
            log("p1_char became %d at frame %d (forced flag %d times)", CH.ft, frame, forced)
        end

        -- Sample the VS page itself.  gstate 0dh is vs_screen; on a 2P game it
        -- lingers for the stage-select loop, so this catches the portraits.
        if vs_frame > 0 and fighting_frame == 0 then
            local rel = frame - vs_frame
            if rel > 0 and rel % 60 == 0 and rel <= 1800 then snap("vs+" .. rel) end
        end

        if fighting_frame > 0 and frame - fighting_frame > 30 then
            snap("fight_start")
            local pc = r16(A.p1_char)
            local vs_ran = vs_frame > 0 and (fighting_frame - vs_frame) > 30
            log("RESULT %s p1_char=%d vs_page_frames=%d %s", WHICH, pc,
                vs_frame > 0 and (fighting_frame - vs_frame) or 0,
                (pc == CH.ft and vs_ran) and "PASS"
                    or (pc ~= CH.ft and ("FAIL (p1_char expected " .. CH.ft .. ")")
                        or "FAIL (VS page never ran - was this a 1P game?)"))
            done = true
            manager.machine:exit()
            return
        end

        if frame > 7000 then
            log("TIMEOUT charsel=%d vs_frame=%d p1_char=%d",
                charsel_frame, vs_frame, r16(A.p1_char))
            snap("timeout")
            manager.machine:exit()
            return
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
