-- sweep_addon_medal.lua - MK4AMULET replaces MKMEDAL2 under the life bars.
--
-- Two things need proving and only one of them is visible.
--
--   1. The art and its palette. MKMEDAL2 shared the score area's SCORE_P;
--      MK4AMULET is its own art with its own gold ramp, so update_knotches now
--      stamps a second slot into the four knotch entries. Wrong slot = a
--      medal in somebody else's colours.
--
--   2. That the stamp lands on the const:pal field and nothing else. The
--      score entry's fields run DOWN from score_ram_end - control 000h,
--      sag 020h, coor 040h, size 060h, const:pal 080h - so p?_knotch?, which
--      points at the SIZE field, has const:pal one long BELOW it and the
--      coordinate one long ABOVE. Get that sign wrong and the write lands on
--      the coordinate instead: the medal still appears, in the right colours,
--      somewhere else on the screen or on top of the power bar. So this reads
--      the neighbours back and checks they still hold what setup_score_ram
--      put there.
--
-- Forces a real round win rather than poking p1_matchw, because
-- update_knotches is only called from two places in MAIN.ASM - nothing
-- refreshes those entries per frame, and a poke would prove nothing about
-- the path that actually runs.
--
-- Env: MEDAL_LOG.  Driven by run_medal_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("MEDAL_LOG") or (ROOT .. "/tools/medal.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

local space
local logf = io.open(OUT, "w")
local function log(fmt, ...)
    local s = "[medal] " .. string.format(fmt, ...)
    print(s)
    if logf then logf:write(s .. "\n"); logf:flush() end
end

-- The four knotch entries. Each name is the address of that entry's SIZE
-- field (scr_size 060h); const:pal (080h) is +32 and the coordinate
-- (scr_coor 040h) is -32.  The scr_ offsets grow with the address.
local KNOTCH = {
    { name = "p1_knotch1", addr = sym.p1_knotch1, coor = 0x0002f0018 },
    { name = "p1_knotch2", addr = sym.p1_knotch2, coor = 0x0002f0027 },
    { name = "p2_knotch1", addr = sym.p2_knotch1, coor = 0x0002f016b },
    { name = "p2_knotch2", addr = sym.p2_knotch2, coor = 0x0002f015c },
}
local MEDAL_SIZE = 0x000d000d       -- MEDAL5 is 13x13 (y:x)

local drained, checked, t, won_at = false, false, 0, 0
local shots = 0

emu.register_frame(function()
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]
    end
    t = t + 1

    local p1w = space:read_u16(sym.p1_matchw) & 0xffff
    local p2b = space:read_u16(sym.p2_bar) & 0xffff

    -- Drain whenever p2 is at full and p1 has no win yet. Draining ONCE was
    -- wrong: the first frame p2_bar reads full is not the first frame of the
    -- fight, it is any time the variable happens to hold 161 - the select
    -- screen included - and round init then refilled it. Re-draining is
    -- self-correcting, and stopping at the first win keeps the next round
    -- from being held at zero.
    if p1w < 1 then
        if p2b >= 0xa1 and t > 120 then
            space:write_u16(sym.p2_bar, 0)
            if not drained then log("draining p2 from frame %d", t) end
            drained = true
        end
        return
    end
    if checked then return end
    if won_at == 0 then won_at = t; log("p1 took the round at frame %d", t) end
    if t - won_at < 150 then return end         -- let update_knotches run AND
                                            --   the score DMA draw a frame
    if space:read_u32(sym.p1_knotch1) == 0 then return end

    checked = true
    -- MK4AMULET carries its own dark-to-gold ramp; update_knotches re-reads the
    -- colour map holding it and stamps that into all four entries.
    local pal = space:read_u32(sym.amulet_pal) & 0xffffffff
    log("p1_matchw=%d  amulet_pal=%#x (AMULET_P's colour map)", p1w, pal)
    local bad = 0
    if pal == 0 then
        log("FAIL: amulet_pal is 0 - get_amulet_pal never ran"); bad = bad + 1
    end
    for _, k in ipairs(KNOTCH) do
        local size = space:read_u32(k.addr) & 0xffffffff
        local cpal = space:read_u32(k.addr + 32) & 0xffffffff
        local coor = space:read_u32(k.addr - 32) & 0xffffffff
        local vis  = (size ~= 0)
        log("  %-11s size=%#010x%s cpal=%#010x coor=%#010x",
            k.name, size, vis and " (shown)" or " (hidden)", cpal, coor)
        if cpal ~= pal then
            log("    FAIL: const:pal is %#x, expected %#x", cpal, pal); bad = bad + 1
        end
        if coor ~= k.coor then
            log("    FAIL: coordinate clobbered - %#x, setup_score_ram wrote %#x",
                coor, k.coor); bad = bad + 1
        end
        if vis and size ~= MEDAL_SIZE then
            log("    FAIL: size %#x is not MEDAL5's %#x", size, MEDAL_SIZE); bad = bad + 1
        end
    end
    -- What palram actually holds right now. Foreground slot i lives at
    -- palram + i*palrsiz and its first long is the palette's ROM address, so
    -- this says plainly which slot AMULET_P is in - or that it is in none.
    local PALRSIZ, PALCNT = 0x40, 0x20
    for i = 0, 7 do
        local base = sym.palram + i * PALRSIZ
        local id  = space:read_u32(base) & 0xffffffff
        local cnt = space:read_u16(base + PALCNT) & 0xffff
        local tag = ""
        if id == sym.SCORE2_P then tag = "  <-- SCORE2_P"
        elseif id == sym.SCORE_P then tag = "  <-- SCORE_P" end
        log("  palram[%d] id=%#010x cnt=%d%s", i, id, cnt, tag)
    end
    log("  (SCORE2_P=%#x  SCORE_P=%#x)", sym.SCORE2_P or 0, sym.SCORE_P or 0)

    -- Did the queued transfer actually land? palset's destination is
    -- pal#<<8 in COLOURS, and colour RAM is 16 bits per entry from 0x1800000.
    -- Slot 1 is SCORE_P, whose contents are known, so it doubles as a check
    -- that this addressing is right before slot 2 is believed.
    local CRAM = 0x01800000
    for _, sl in ipairs({1, 2}) do
        local base = CRAM + (sl * 256) * 16
        local t = {}
        for i = 0, 7 do t[#t+1] = string.format("%04x", space:read_u16(base + i*16) & 0xffff) end
        log("  cram[slot %d] %s", sl, table.concat(t, " "))
    end

    if bad == 0 then
        log("VERDICT PASS - medal palette stamped, neighbours intact")
    else
        log("VERDICT FAIL - %d problem(s)", bad)
    end
    pcall(function() manager.machine.video:snapshot(); shots = shots + 1 end)
end)

-- The invariant that actually matters, checked every frame for a window that
-- spans a round transition: the colour map the entry names must be a palram
-- slot that is holding AMULET_P right now. A fixed slot number does not
-- survive - palram is recycled between rounds - so this is what says the
-- re-read in update_knotches is doing its job.
local after, bad_frames, checked_frames, worst = 0, 0, 0, nil
emu.register_frame(function()
    if not checked or not space then return end
    after = after + 1
    if after > 600 then return end
    local cpal = space:read_u32(sym.p1_knotch1 + 32) & 0xffffffff
    local size = space:read_u32(sym.p1_knotch1) & 0xffffffff
    if size == 0 then return end            -- hidden: nothing is drawn
    checked_frames = checked_frames + 1
    local slot = cpal & 0xff
    local id = space:read_u32(sym.palram + slot * 0x40) & 0xffffffff
    if id ~= sym.SCORE2_P then
        bad_frames = bad_frames + 1
        if not worst then
            worst = string.format("+%d: cpal=%#06x -> palram[%d]=%#010x, not SCORE2_P",
                                  after, cpal, slot, id)
        end
    end
    if after == 120 or after == 420 then
        log("+%d  cpal=%#06x slot=%d palram[%d]=%#010x %s", after, cpal, slot, slot, id,
            id == sym.SCORE2_P and "OK" or "WRONG")
        pcall(function() manager.machine.video:snapshot(); shots = shots + 1 end)
    end
    if after == 600 then
        log("INVARIANT %d/%d visible frames named a slot holding SCORE2_P",
            checked_frames - bad_frames, checked_frames)
        if worst then log("  first miss %s", worst) end
        log(bad_frames == 0 and "VERDICT PASS - medal colour map correct every frame"
                            or  "VERDICT FAIL - colour map wrong on some frames")
    end
end)
