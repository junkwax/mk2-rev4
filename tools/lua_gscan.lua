-- Scan memory around expected gstate address and log any word that changes
-- This diagnoses whether gstate address is off after BSS changes
local logf = io.open("C:/Users/you/Workplace/mk2-main/gscan.log", "w")
local function lg(s) print(s); logf:write(s.."\n"); logf:flush() end

local space
local ok = pcall(function()
    local cpu = manager.machine.devices[":maincpu"]
    space = cpu.spaces["program"]
end)
if not ok or not space then lg("ERROR: no space"); return end

-- Read a range of addresses around expected gstate (byte addrs)
-- gstate old: 0x01129d90//8 = 0x2253B2
-- gstate new: 0x01129dc0//8 = 0x2253B8
-- Scan 0x2253A0..0x2253D0 (16 words)
local BASE = 0x2253A0
local SCAN_WORDS = 16
local prev = {}
for i = 0, SCAN_WORDS-1 do
    prev[i] = space:read_u16(BASE + i*2)
end

lg(string.format("Initial values at 0x%06X:", BASE))
for i = 0, SCAN_WORDS-1 do
    lg(string.format("  [%+4d] 0x%06X = 0x%04X", i*2, BASE+i*2, prev[i]))
end

local frame = 0
local logged_changes = 0

emu.register_frame_done(function()
    if not space then return end
    frame = frame + 1
    if frame % 60 ~= 0 then return end  -- log every second

    local secs = frame // 60
    for i = 0, SCAN_WORDS-1 do
        local v = space:read_u16(BASE + i*2)
        if v ~= prev[i] then
            lg(string.format("T+%ds CHANGE: [%+4d] 0x%06X: 0x%04X -> 0x%04X",
                secs, i*2, BASE+i*2, prev[i], v))
            prev[i] = v
            logged_changes = logged_changes + 1
        end
    end

    if secs <= 30 and secs % 5 == 0 then
        -- also log gstate candidates every 5 seconds
        local gstate_old = space:read_u16(0x2253B2)  -- 0x01129d90//8
        local gstate_new = space:read_u16(0x2253B8)  -- 0x01129dc0//8
        lg(string.format("T+%ds: gstate@old=0x%04X  gstate@new=0x%04X  changes_so_far=%d",
            secs, gstate_old, gstate_new, logged_changes))
    end
end)

lg("gscan initialized, watching " .. SCAN_WORDS .. " words at " .. string.format("0x%06X", BASE))
