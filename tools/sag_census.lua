-- sag_census.lua - every SAG the DMA was actually told to draw.
--
-- The runtime check for tools/art_ref_graph.py.  That tool decides from the
-- built ROM which sprite records are reachable; the one thing a static model
-- cannot see is art reached by arithmetic (a base header plus an index).  So
-- this rides along with an existing driver rig and records the data-start
-- address of EVERY blit - objects, multipart pieces, background blocks,
-- floors, HUD - by tapping the DMA register block itself, not the object
-- lists.  Any SAG it sees that the graph calls DEAD is a graph bug.
--
-- dmasagl / dmasagh (SYSEQU.ASM) hold the low and high 16 bits; a blit starts
-- when dmactrl is written, so a SAG is committed at that write, from the two
-- halves most recently programmed.  The tap learns whether the space is
-- addressed in bits or bytes from the first writes it sees.
--
-- It drives nothing: it installs the taps, then dofile()s SC_TARGET inside
-- SC_ROOT (a frozen src/ + tools/ matching the ROM; repo paths the rig opens
-- are redirected there, as tools/hitlight_watch.lua does).
--
-- Env: SC_TARGET, SC_ROOT, SC_OUT (one "sag count" line per SAG), SC_LABEL
local REPO = "C:/Users/you/Workplace/mk2-main"
local FROOT = assert(os.getenv("SC_ROOT"), "SC_ROOT"):gsub("\\", "/")
local OUT = assert(os.getenv("SC_OUT"), "SC_OUT")
local LABEL = os.getenv("SC_LABEL") or "sag_census"
local TARGET = assert(os.getenv("SC_TARGET"), "SC_TARGET"):gsub("\\", "/")

local function redirect(p)
    if type(p) ~= "string" then return p end
    local q = p:gsub("\\", "/")
    local low = q:lower()
    if low:sub(1, #FROOT) == FROOT:lower() then return q end
    local rest = q:sub(#REPO + 1)
    if low:sub(1, #REPO) == REPO:lower() and (rest:lower():sub(1, 5) == "/src/" or rest:lower():sub(1, 7) == "/tools/") then
        return FROOT .. rest
    end
    return q
end
local orig_open, orig_dofile, orig_loadfile = io.open, dofile, loadfile
io.open = function(p, m) return orig_open(redirect(p), m) end
dofile = function(p) return orig_dofile(redirect(p)) end
loadfile = function(p, ...) return orig_loadfile(redirect(p), ...) end

-- register addresses in BITS (SYSEQU.ASM); byte addresses are these / 8
local CTRL, SAGL, SAGH = 0x01a80010, 0x01a80020, 0x01a80030
local BLOCK_LO, BLOCK_HI = 0x01a80000, 0x01a800ff

local seen = {}          -- sag -> count
local commits, lo, hi = 0, nil, nil
local scale = nil        -- 1 if taps report bit addresses, 8 if byte addresses
local offsets = {}       -- first distinct offsets, for the log

local function flush()
    local fh = orig_open(OUT, "w")
    if not fh then return end
    fh:write(string.format("# %s commits=%d scale=%s\n", LABEL, commits, tostring(scale)))
    local keys = {}
    for k in pairs(seen) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do fh:write(string.format("%08x %d\n", k, seen[k])) end
    fh:close()
end

local function on_write(offset, data, mask)
    if scale == nil then
        -- learn the addressing from where writes land
        if offset == CTRL or offset == SAGL or offset == SAGH then
            scale = 1
        elseif offset * 8 == CTRL or offset * 8 == SAGL or offset * 8 == SAGH then
            scale = 8
        end
        if #offsets < 8 then offsets[#offsets + 1] = string.format("%x", offset) end
    end
    if scale == nil then return data end
    local bit = offset * scale
    if bit == SAGL then
        lo = data & 0xffff
    elseif bit == SAGH then
        hi = data & 0xffff
    elseif bit == CTRL and lo ~= nil and hi ~= nil then
        local sag = (hi << 16) | lo
        seen[sag] = (seen[sag] or 0) + 1
        commits = commits + 1
    end
    return data
end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local taps = {}
for _, range in ipairs({ { BLOCK_LO, BLOCK_HI }, { BLOCK_LO // 8, BLOCK_HI // 8 } }) do
    local ok, h = pcall(function()
        return space:install_write_tap(range[1], range[2], "sag_census_" .. range[1], on_write)
    end)
    if ok and h then taps[#taps + 1] = h end
end

local frames = 0
emu.register_frame_done(function()
    frames = frames + 1
    if frames % 600 == 0 then flush() end
end)
emu.register_stop(function()
    flush()
    local fh = orig_open(OUT .. ".log", "w")
    if fh then
        fh:write(string.format("%s taps=%d scale=%s commits=%d distinct=%d frames=%d offsets=%s\n",
            LABEL, #taps, tostring(scale), commits, (function() local n = 0 for _ in pairs(seen) do n = n + 1 end return n end)(),
            frames, table.concat(offsets, ",")))
        fh:close()
    end
end)

dofile(FROOT .. "/" .. TARGET)
