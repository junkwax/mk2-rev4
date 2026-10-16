-- Wrap the existing portal-move driver with an independent live-piece witness.
local root = assert(os.getenv('KAHN_TEST_ROOT')):gsub('\\', '/')
local out = assert(os.getenv('KFR_OUT')):gsub('\\', '/')
local mirrored = os.getenv('KFR_MIRROR') == '1'
local multipart = os.getenv('KFR_MULTIPART') == '1'
local symbols = {}
for line in io.lines(root .. '/src/mk2.map') do
    for addr, name in line:gmatch('(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)') do
        symbols[name] = tonumber(addr, 16)
    end
end
local function sym(name) return assert(symbols[name], 'Missing symbol ' .. name) end
local head = sym(mirrored and 'BGBIGFIST1C_MIRROR' or 'BGBIGFIST1C')
local source = sym(mirrored and 'BGBIGFIST1B' or 'BGBIGFIST1C')
local list = sym('objlst')
local fh = assert(io.open(out .. '/witness.txt', 'w'))
local frame, samples, failures, last_seen = 0, 0, 0, 0
dofile(root .. '/driver.lua')
emu.register_frame_done(function()
    frame = frame + 1
    local space = manager.machine.devices[':maincpu'].spaces['program']
    if multipart then
        local anim = space:read_u32(sym('sk_anitab2') + 6 * 32)
        local shape = space:read_u32(anim)
        local actor = space:read_u32(sym('p2_obj'))
        if actor ~= 0 and space:read_u32(actor + 0x1d0) == shape then
            local node = space:read_u32(actor + 0x1a0) + 4 * 112
            local facing = space:read_u16(actor + 0xf0) & 0x10
            local control = space:read_u16(node + 64)
            local expected = facing ~ (mirrored and 0x10 or 0)
            if (control & 0x10) ~= expected or
               space:read_u32(node) ~= space:read_u32(source + 0x40) then
                failures = failures + 1
            end
            fh:write(string.format('MULTI %d %d %d %d %d %d\n', frame,
                space:read_u16(actor + 0x90), space:read_u16(actor + 0xb0),
                facing, space:read_u16(node + 80), space:read_u16(node + 96)))
        end
    end
    local obj = space:read_u32(list)
    local visited = {}
    while obj ~= 0 do
        if visited[obj] then failures = failures + 1; break end
        visited[obj] = true
        if space:read_u32(obj + 0x1a0) == head then
            samples = samples + 1
            last_seen = frame
            local sag = space:read_u32(obj + 0x100)
            if sag ~= space:read_u32(source + 0x40) then failures = failures + 1 end
            local flags = space:read_u16(obj + 0xf0)
            -- Compare the placement-facing bits after removing the alias flip.
            if mirrored then flags = flags ~ 0x10 end
            fh:write(string.format('PIECE %d %d %d %d %d\n', frame,
                space:read_u16(obj + 0x90), space:read_u16(obj + 0xb0),
                flags & 0x30, space:read_u16(obj + 0x140)))
        end
        obj = space:read_u32(obj)
    end
end)
emu.register_stop(function()
    local clean_tail = frame - last_seen
    fh:write(string.format('RESULT samples=%d failures=%d clean_tail=%d\n', samples, failures, clean_tail))
    fh:close()
end)
