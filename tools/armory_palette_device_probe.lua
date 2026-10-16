local LOG_PATH = os.getenv("ARMORY_AUDIT_LOG") or "C:/Users/you/Workplace/mk2-main/tools/armory_palette_device_probe.log"
local logfh = io.open(LOG_PATH, "w")
local function logprint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local done = false
local frame = 0
emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame < 200 then return end
    done = true

    local pal = manager.machine.devices[":palette"]
    logprint("[pdprobe] palette device type: " .. tostring(pal))

    -- Try common palette_device lua API surfaces.
    local ok, items = pcall(function() return pal.items end)
    logprint("[pdprobe] pal.items ok=" .. tostring(ok) .. " val=" .. tostring(items))

    ok, items = pcall(function() return pal:item("colors") end)
    logprint("[pdprobe] pal:item('colors') ok=" .. tostring(ok) .. " val=" .. tostring(items))

    -- Enumerate fields via pairs on the device itself.
    local fieldnames = {}
    local ok2 = pcall(function()
        for k, v in pairs(pal) do fieldnames[#fieldnames+1] = tostring(k) end
    end)
    logprint("[pdprobe] pairs(pal) ok=" .. tostring(ok2) .. " fields=" .. table.concat(fieldnames, ","))

    -- Try item list on the device (palette devices often expose a "colors" state item array via items table)
    local ok3, itm = pcall(function() return pal.items["colors"] end)
    logprint("[pdprobe] pal.items['colors'] ok=" .. tostring(ok3) .. " val=" .. tostring(itm))

    -- manager.machine.colortables (alternate global path some MAME versions expose)
    local ok4, ct = pcall(function() return manager.machine.colortables end)
    logprint("[pdprobe] manager.machine.colortables ok=" .. tostring(ok4) .. " val=" .. tostring(ct))

    -- Enumerate pal.items keys (device_state_interface registered items)
    local ok5 = pcall(function()
        for k, v in pairs(pal.items) do
            logprint("[pdprobe] pal.items key=" .. tostring(k) .. " val=" .. tostring(v))
        end
    end)
    logprint("[pdprobe] enumerate pal.items ok=" .. tostring(ok5))

    -- Try direct method calls some MAME palette_device bindings expose.
    for _, mname in ipairs({"pen_color", "entry_color", "raw_color", "black_pen", "white_pen"}) do
        local ok6, res = pcall(function() return pal[mname](pal, 0) end)
        logprint(string.format("[pdprobe] pal:%s(0) ok=%s val=%s", mname, tostring(ok6), tostring(res)))
    end

    -- Try indexing pal directly like an array/table for a "entries" or "colors" length property.
    for _, pname in ipairs({"entries", "colors", "max_index", "indirected"}) do
        local ok7, res = pcall(function() return pal[pname] end)
        logprint(string.format("[pdprobe] pal.%s ok=%s val=%s", pname, tostring(ok7), tostring(res)))
    end
end)
