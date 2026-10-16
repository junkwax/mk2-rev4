-- Adds NOOBPORT packing assertions to the existing shadow-portal input rig.
--
-- tools/noob_portal_test.lua proves the move WORKS: the hole opens under the
-- victim, swallows him, and a jump clears it.  Its own header says what it
-- cannot prove - "matching SAGs prove the tables are reached, not that the art
-- is right" - and after opportunity 03 that gap is exactly where a regression
-- would live, because this sidecar is now packed at TWO depths:
--
--     NOOBPORTAL1-12    5 bpp   the vortex
--     NSPORTALSHOT1-3   6 bpp   Noob's own body, A/B strips
--     NOOBAIRGUNK3-8    5 bpp   the blast
--
-- A wrong depth is not a crash and not a missing object.  It is the same
-- object, in the same place, at the same time, drawing the right pixels
-- through the wrong stride - which every check in the rig above still passes.
-- So this watches the CONTROL WORD the game actually handed the blitter:
--
--   * every live piece's mpram control word equals its own source record's,
--     flip bits aside.  ani2 rewrites it from the record every frame, so a
--     stale depth bit surviving a frame change (the SONICCLAP failure) shows
--     up here as an inequality rather than as a garbled screenshot.
--   * the depth field is the one that record was packed at - 5 for the two
--     effect sets, 6 for the body strips.  Both are asserted on the SAME
--     sequence, so this is the mixed-depth claim itself under test.
--   * palette ownership does not move under an object mid-animation.
--   * every record in the file is reached at least once across the run.
--
-- NBP_LOG names this observer's log; the rig's own env vars are unchanged.
local root = (os.getenv('MK2_ROOT') or 'C:/Users/you/Workplace/mk2-main'):gsub('\\','/')
local out = assert(io.open(assert(os.getenv('NBP_LOG'), 'NBP_LOG not set'), 'w'))
local function log(s) out:write('[nbp] '..s..'\n'); out:flush() end

local symbols = {}
for line in assert(io.open(root..'/src/mk2.map')):lines() do
    for a,n in line:gmatch('(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)') do symbols[n]=tonumber(a,16) end
end
local function sym(n) return assert(symbols[n], 'Missing map symbol '..n) end

-- Depth is a property of the BLOCK in data/NOOBPORT.LOD, so derive the
-- expectation from the record name rather than from a hand-kept list that
-- would have to be renumbered every time a frame is added.
local function expected_bpp(name)
    if name:sub(1,12) == 'NSPORTALSHOT' then return 6 end
    return 5
end

-- The vortex table has twelve frames and the move cannot show the last two.
-- noob_portal_proc runs NOOB_PORTAL_OPEN + NOOB_PORTAL_LIFE = 50 ticks at
-- NOOB_PORTAL_SPIN = 5 ticks a frame, so an untouched portal dies on frame
-- 10; a portal that CONNECTS dies sooner still, because the hit REPLACES the
-- remaining life with NOOB_PORTAL_HOLD rather than adding to it.  So 11 and
-- 12 are art that never reaches the screen - measured here, not assumed, and
-- equally unreachable before this repack.  Listed rather than tolerated: if
-- the constants are ever retimed this check fails and says so.
local UNREACHABLE = { NOOBPORTAL11 = true, NOOBPORTAL12 = true }

-- The generated table is the source of truth for both the SAG and the control
-- word.  Parsing it here rather than trusting the rig's sag_name map means a
-- table that was never re-promoted after a repack fails as an unknown SAG.
local by_sag, records, total = {}, {}, 0
do
    local label, w, h, sag
    for line in assert(io.open(root..'/src/NOOBPORT.TBL')):lines() do
        local l = line:match('^(%w+):')
        if l then label, w, sag = l, nil, nil end
        local a, b = line:match('^%s*%.word%s+(%-?%d+),(%-?%d+),')
        if a then w, h = tonumber(a), tonumber(b) end
        local s = line:match('^%s*%.long%s+0?(%x+)[Hh]')
        if s and w then sag = tonumber(s, 16) end
        local c = line:match('^%s*%.word%s+0?(%x+)[Hh]%s*$')
        if c and sag and label then
            by_sag[sag & 0x00ffffff] = {name=label, w=w, h=h, ctrl=tonumber(c,16)}
            records[label], total = false, total + 1
            label, sag = nil, nil
        end
    end
end
assert(total == 23, 'Expected the 23 NOOBPORT records, parsed '..total)

local OIMG, ONEXT, OFLAGS, OPAL = 0x1a0, 0x00, 0xf0, 0x140
local MP_SAG, MP_CTRL, MP_LEN = 0x00, 0x40, 0x70

local failures, samples, pieces, seen_pal = 0, 0, 0, {}
local depth_hits = {}
local function check(ok, why)
    if not ok then
        failures = failures + 1
        if failures < 25 then log('ERROR '..why) end
    end
end

-- Reuse the established real-input setup, placement and counterplay checks.
dofile(root..'/tools/noob_portal_test.lua')

local space
emu.register_frame(function()
    space = space or manager.machine.devices[':maincpu'].spaces['program']
    local function r16(a) return space:read_u16(a) end
    local function r32(a) return space:read_u32(a) end
    samples = samples + 1
    for _, list in ipairs({'objlst','objlst2','objlst3'}) do
        local obj, guard = r32(sym(list)), 0
        while obj ~= 0 and guard < 400 do
            local image = r32(obj + OIMG)
            if image ~= 0 then
                local opal, mine = r16(obj + OPAL), nil
                for i = 0, 12 do
                    local raw = r32(image + i*MP_LEN + MP_SAG)
                    if raw == 0 then break end
                    local rec = by_sag[raw & 0x00ffffff]
                    if rec then
                        mine = true
                        pieces = pieces + 1
                        records[rec.name] = true
                        local live = r16(image + i*MP_LEN + MP_CTRL)
                        local bpp = (live >> 12) & 7
                        depth_hits[rec.name] = bpp
                        -- ani2 substitutes only the flip bits (DISPEQU 0x30).
                        check((live & 0xffcf) == (rec.ctrl & 0xffcf),
                            string.format('%s live control %04x != record %04x',
                                          rec.name, live, rec.ctrl))
                        check(bpp == expected_bpp(rec.name),
                            string.format('%s drew at %d bpp, packed at %d',
                                          rec.name, bpp, expected_bpp(rec.name)))
                    end
                end
                if mine then
                    local was = seen_pal[obj]
                    if was == nil then
                        seen_pal[obj] = opal
                    else
                        check(was == opal, string.format(
                            'object %08x changed palette %04x -> %04x mid-animation',
                            obj, was, opal))
                    end
                elseif seen_pal[obj] ~= nil then
                    seen_pal[obj] = nil   -- object recycled away from this art
                end
            end
            obj = r32(obj + ONEXT); guard = guard + 1
        end
        check(guard < 400, 'object list cycle/overflow on '..list)
    end
end)

emu.register_stop(function()
    local missing, reached = {}, 0
    for name, hit in pairs(records) do
        if hit then reached = reached + 1 else missing[#missing+1] = name end
    end
    table.sort(missing)
    for name, bpp in pairs(depth_hits) do
        log(string.format('reached %-16s %d bpp', name, bpp))
    end
    local unexpected = {}
    for _, name in ipairs(missing) do
        if not UNREACHABLE[name] then unexpected[#unexpected+1] = name end
    end
    for name in pairs(UNREACHABLE) do
        if records[name] then unexpected[#unexpected+1] = name..' (newly reachable)' end
    end
    check(#unexpected == 0, 'record coverage changed: '..table.concat(unexpected, ','))
    -- The point of the prototype: two depths, live, in one sequence.
    local five, six = 0, 0
    for name, bpp in pairs(depth_hits) do
        if bpp == 5 then five = five + 1 elseif bpp == 6 then six = six + 1 end
    end
    check(five == 15 and six == 6, string.format(
        'expected 15 five-bit and 6 six-bit records live, saw %d and %d', five, six))
    log(string.format('records=%d/%d pieces=%d samples=%d five_bpp=%d six_bpp=%d',
                      reached, total, pieces, samples, five, six))
    log(string.format('%s records=%d failures=%d',
                      failures == 0 and 'PASS' or 'FAIL', reached, failures))
    out:close()
end)
