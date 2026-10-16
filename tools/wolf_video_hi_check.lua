-- wolf_video_hi_check.lua - does art from rom/wolf_video_hi.bin land where the
-- DMA reads it?  makewolf.py interleaves that image into u121..u118 (12 MB)
-- and u113..u110 (20 MB); this reads MAME's :video region back at sample
-- offsets and compares with the expected pattern byte(i) = (i*7 + (i>>8)*13 +
-- (i>>16)*31) & 0xFF, i = linear offset - 12 MB.  run_wolf_video_hi_check.ps1
-- writes that pattern; a wrong chip name or lane order shows up as mismatches.
local LOG = os.getenv("WB_LOG")
local done = false
emu.register_frame(function()
    if done or manager.machine.time:as_double() < 0.5 then return end
    done = true
    local vid = manager.machine.memory.regions[":video"]
    local f = io.open(LOG, "w")
    local ok, bad, first = 0, 0, nil
    -- WVH_BLOCKS: the 4 MB blocks to sample (default the two stock MAME loads);
    -- tools/make_wolf_video_pattern.py --extra fills the twelve EMPTY-socket
    -- chips instead, for 0x1000000,0x1800000,0x1C00000 (mk2wolf.exe only)
    local blocks = {}
    for v in (os.getenv("WVH_BLOCKS") or "0xC00000,0x1400000"):gmatch("[^,]+") do blocks[#blocks + 1] = tonumber(v) end
    for _, base in ipairs(blocks) do
        for k = 0, 4095 do
            local off = base + k * 1021              -- spans all 4 lanes and the whole block
            local i = off - 0xC00000
            local want = (i * 7 + (i >> 8) * 13 + (i >> 16) * 31) & 0xFF
            local got = vid:read_u8(off)
            if got == want then ok = ok + 1 else
                bad = bad + 1
                first = first or string.format("0x%07X got %02X want %02X", off, got, want)
            end
        end
    end
    f:write(string.format("VIDEO_HI ok=%d bad=%d%s\n", ok, bad, first and (" first " .. first) or ""))
    f:close()
    manager.machine:exit()
end)
