-- attract_probe.lua
-- Dismisses only MAME's warning screen, then lets MK2 attract mode run.
-- Saves snapshots every 120 frames and prints basic runtime state.

local frame = 0
local ui_select = nil
local snap_count = 0
local SNAP_INTERVAL = 120

local GSTATE = 0x01129d90
local F_START = 0x0112b5a0
local P1_STATE = 0x01129db0
local P2_STATE = 0x0112a980
local CURBACK = 0x0112b680

local function maincpu_space()
	local dev = manager.machine.devices[":maincpu"]
	return dev.spaces["program"]
end

local mem = maincpu_space()

local function r16(addr)
	return mem:read_u16(addr)
end

local function main_screen()
	local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
	if ok and screen ~= nil then return screen end
	ok, screen = pcall(function() return manager.machine.screens:at(1) end)
	if ok and screen ~= nil then return screen end
	ok, screen = pcall(function() return manager.machine.screens:at(0) end)
	if ok and screen ~= nil then return screen end
	return nil
end

local function cache_ui_select()
	for _, port in pairs(manager.machine.ioport.ports) do
		for _, field in pairs(port.fields) do
			if field.name == "UI Select" then
				ui_select = field
				return
			end
		end
	end
end

emu.register_frame(function()
	frame = frame + 1
	if frame == 1 then
		cache_ui_select()
		print("[attract_probe] started")
	end

	if ui_select ~= nil then
		if frame >= 5 and frame < 35 then
			ui_select:set_value(1)
		else
			ui_select:clear_value()
		end
	end

	if frame % SNAP_INTERVAL == 0 then
		snap_count = snap_count + 1
		local screen = main_screen()
		local ok, err = pcall(function()
			if not screen then error("no screen") end
			screen:snapshot()
		end)
		print(string.format(
			"[attract_probe] snap=%d frame=%d ok=%s gstate=%d f_start=%d p1st=%d p2st=%d curback=%d",
			snap_count, frame, tostring(ok), r16(GSTATE), r16(F_START), r16(P1_STATE), r16(P2_STATE), r16(CURBACK)
		))
	end

end)
