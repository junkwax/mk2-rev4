-- armory_cram_search.lua
-- Empirically locate MARFLOR's and LAVA_P's real color data in color RAM by
-- brute-force search, instead of deriving the address/stride math by hand
-- (two prior attempts at that failed cross-validation). Dumps a wide window
-- of color RAM as u16 words and searches for the known-correct MARFLOR
-- color sequence (and LAVA_P's) as a contiguous subsequence at any 2-byte
-- offset. Whatever offset/stride it's actually found at IS the ground truth.

local ROOT = os.getenv("ARMORY_AUDIT_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("ARMORY_AUDIT_LOG") or (ROOT .. "/tools/armory_cram_search.log")
local logfh = io.open(LOG_PATH, "w")
local function logprint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local COLOR_RAM = 0x01800000
local DUMP_WORDS = 0x10000  -- 128KB window, covers far more than the documented 60*0x1000=240KB slot table; widen if nothing found

local MARFLOR_EXPECTED = {
    0x0000,0x24a2,0x2083,0x2082,0x24a4,0x2ce4,0x28c3,0x28c4,
    0x1841,0x1420,0x1862,0x1441,0x1c62,0x28a3,0x20a3,0x24c4,
}
local LAVA_P_EXPECTED = {
    0x0000,0x3127,0x1827,0x2ce3,0x1820,0x2040,0x2460,0x2c80,
    0x30a0,0x38a0,0x40c0,0x48e0,0x5120,0x5d60,0x5d80,0x65a0,
    0x6de0,0x7a40,0x7aa0,0x7ae0,0x7b20,0x7b60,0x7fa0,0x7fe0,
    0x7260,0x7220,0x71a0,0x1005,0x2029,
}

local function search(words, pattern, label)
    local found = 0
    for start = 1, #words - #pattern + 1 do
        local ok = true
        for i = 1, #pattern do
            if words[start + i - 1] ~= pattern[i] then ok = false; break end
        end
        if ok then
            local byte_off = (start - 1) * 2
            logprint(string.format("[cram-search] FOUND %s at word-index=%d byte-offset=0x%05x (colram+0x%05x) slot-if-0x1000=%d",
                label, start - 1, byte_off, byte_off, byte_off // 0x1000))
            found = found + 1
        end
    end
    if found == 0 then
        logprint(string.format("[cram-search] %s: NOT FOUND anywhere in dumped %d-word window", label, #words))
    end
    return found
end

local done = false
local frame = 0
emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame < 200 then return end -- let test_mode direct-boot settle
    done = true

    local cpu = manager.machine.devices[":maincpu"]
    local space = cpu.spaces["program"]

    logprint(string.format("[cram-search] dumping %d words (0x%x bytes) from colram=0x%08x", DUMP_WORDS, DUMP_WORDS*2, COLOR_RAM))
    local words = {}
    for i = 0, DUMP_WORDS - 1 do
        words[i + 1] = space:read_u16(COLOR_RAM + i * 2)
    end

    local nonzero = 0
    for _, w in ipairs(words) do if w ~= 0 then nonzero = nonzero + 1 end end
    logprint(string.format("[cram-search] non-zero word count in dump: %d / %d", nonzero, #words))

    search(words, MARFLOR_EXPECTED, "MARFLOR")
    search(words, LAVA_P_EXPECTED, "LAVA_P")

    logprint("[cram-search] done")
end)
