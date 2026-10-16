local frame = 0
local fields = {}
local space = nil
local CURBACK = 0x0112b680
local GROUND_Y = 0x01128890
local P1_OBJ = 0x01129de0
local P1_PROC = 0x01129e20
local P2_OBJ = 0x0112a9b0
local P2_PROC = 0x0112a9f0
local BAKLST1 = 0x01127010
local BAK1MODS = 0x010dbd90
local PALRAM = 0x011256e0
local PALRSIZ = 0x40
local COLRAM = 0x01800000
local NUMPAL = 60
local did_snapshot = false
local SNAPSHOT_FRAME = 2400
local CURBACK_FORCE_UNTIL = 2600
local DRIVE_ATTACKS = false
local HOLD_CENTER_CAMERA = false
local DUMP_RUNTIME_DEBUG = false
local WASTELAND_CURBACK = 2
local CENTER_WORLDX = 401
local WORLDTLX8 = 0x01126e10
local WORLDTLX7 = 0x01126e30
local WORLDTLX6 = 0x01126e50
local WORLDTLX5 = 0x01126e70
local WORLDTLX4 = 0x01126e90
local WORLDTLX3 = 0x01126eb0
local WORLDTLX2 = 0x01126ed0
local WORLDTLX1 = 0x01126ef0
local WORLDTLX0 = 0x01126f10
local OBJ_OXPOS = 0x090
local OBJ_OYPOS = 0x0b0
local OBJ_OFLAGS = 0x0f0
local OBJ_OSAG = 0x100
local OBJ_OSIZE = 0x120
local OBJ_OPAL = 0x140
local OBJ_OIMG = 0x1a0
local OBJ_OFSET = 0x0e0
local OBJ_OFLAGS2 = 0x160
local OBJ_OSHAPE = 0x1d0
local PROC_GANIY = 0x200
local MP_SAG = 0x00
local MP_YXSIZE = 0x20
local MP_CONTROL = 0x40
local MP_ANIX = 0x50
local MP_ANIY = 0x60
local MP_LENGTH = 0x70

local function write_world_x(base, value)
	space:write_i16(base + 16, value)
end

local function hold_center_camera()
	if not space or not HOLD_CENTER_CAMERA then
		return
	end

	-- Match the ROM-byte center preview at worldx=401.  The parallax planes
	-- use their own camera values, so holding only worldtlx would make the
	-- endpoint pillars dominate the live proof.
	write_world_x(WORLDTLX8, 0)
	write_world_x(WORLDTLX7, 351)
	write_world_x(WORLDTLX6, 301)
	write_world_x(WORLDTLX5, CENTER_WORLDX)
	write_world_x(WORLDTLX4, CENTER_WORLDX)
	write_world_x(WORLDTLX3, CENTER_WORLDX)
	write_world_x(WORLDTLX2, 0)
	write_world_x(WORLDTLX1, CENTER_WORLDX)
	write_world_x(WORLDTLX0, CENTER_WORLDX)

	local p1_obj = space:read_u32(P1_OBJ)
	if p1_obj ~= 0 then
		space:write_i16(p1_obj + OBJ_OXPOS, CENTER_WORLDX + 132)
	end
	local p2_obj = space:read_u32(P2_OBJ)
	if p2_obj ~= 0 then
		space:write_i16(p2_obj + OBJ_OXPOS, CENTER_WORLDX + 258)
	end
end

local function list_addr(n)
	return BAKLST1 - ((n - 1) * 0x20)
end

local function count_list(head)
	local c = 0
	local q = head
	while q ~= 0 and c < 120 do
		c = c + 1
		q = space:read_u32(q)
	end
	return c
end

local function dump_obj(label, list_name, p)
	if p == 0 then
		return
	end
	local oimg = space:read_u32(p + OBJ_OIMG)
	local header_words = {}
	for off = 0, 0x80, 0x10 do
		header_words[#header_words + 1] = string.format("+%02x=%04x", off, space:read_u16(oimg + off))
	end
	print(string.format(
		"[mk2-wasteland] %s %s first ox=%d oy=%d ofset=0x%04x oflags=0x%04x ocntl32=0x%08x osag=0x%08x osize=0x%08x opal=0x%04x oimg=0x%08x hdrwords={%s} next=0x%08x",
		label,
		list_name,
		space:read_i16(p + OBJ_OXPOS),
		space:read_i16(p + OBJ_OYPOS),
		space:read_u16(p + OBJ_OFSET),
		space:read_u16(p + OBJ_OFLAGS),
		space:read_u32(p + OBJ_OFSET),
		space:read_u32(p + OBJ_OSAG),
		space:read_u32(p + OBJ_OSIZE),
		space:read_u16(p + OBJ_OPAL),
		oimg,
		table.concat(header_words, " "),
		space:read_u32(p)))
end

local function dump_multipart(label, list_name, p)
	if p == 0 then
		return
	end

	local oimg = space:read_u32(p + OBJ_OIMG)
	local oflags2 = space:read_u32(p + OBJ_OFLAGS2)
	local oshape = space:read_u32(p + OBJ_OSHAPE)
	print(string.format(
		"[mk2-wasteland] %s %s multipart oimg=0x%08x oflags2=0x%08x oshape=0x%08x",
		label, list_name, oimg, oflags2, oshape))

	for i = 0, 7 do
		local base = oimg + (i * MP_LENGTH)
		local sag = space:read_u32(base + MP_SAG)
		local yxsize = space:read_u32(base + MP_YXSIZE)
		local control = space:read_u16(base + MP_CONTROL)
		local anix = space:read_i16(base + MP_ANIX)
		local aniy = space:read_i16(base + MP_ANIY)
		print(string.format(
			"[mk2-wasteland] %s %s mp%02d base=0x%08x sag=0x%08x yxsize=0x%08x ctrl=0x%04x anix=%d aniy=%d",
			label, list_name, i, base, sag, yxsize, control, anix, aniy))
		if sag == 0 and yxsize == 0 and control == 0 then
			break
		end
	end
end

local function dump_runtime_bg(label)
	if not space then
		return
	end

	for i = 1, 8 do
		local slot = BAK1MODS + ((i - 1) * 0x20)
		local modentry = space:read_u32(slot)
		local bmod = 0
		local modx = 0
		local mody = 0
		if modentry ~= 0 then
			bmod = space:read_u32(modentry)
			modx = space:read_i16(modentry + 0x20)
			mody = space:read_i16(modentry + 0x30)
		end
		print(string.format("[mk2-wasteland] %s bak%dmods=0x%08x bmod=0x%08x modx=%d mody=%d",
			label, i, modentry, bmod, modx, mody))
	end

	for i = 8, 1, -1 do
		local addr = list_addr(i)
		local head = space:read_u32(addr)
		local c = count_list(head)
		print(string.format("[mk2-wasteland] %s baklst%d head=0x%08x count<=120=%d", label, i, head, c))
		dump_obj(label, "baklst" .. i, head)
	end
end

local dump_palette_slot

local function dump_players(label)
	if not space then
		return
	end

	local p1_obj = space:read_u32(P1_OBJ)
	local p2_obj = space:read_u32(P2_OBJ)
	local p1_proc = space:read_u32(P1_PROC)
	local p2_proc = space:read_u32(P2_PROC)
	print(string.format(
		"[mk2-wasteland] %s ground_y=%d p1_obj=0x%08x p1_oy=%d p1_ganiy=%d p2_obj=0x%08x p2_oy=%d p2_ganiy=%d",
		label,
		space:read_i16(GROUND_Y),
		p1_obj,
		p1_obj ~= 0 and space:read_i16(p1_obj + OBJ_OYPOS) or -999,
		p1_proc ~= 0 and space:read_i16(p1_proc + PROC_GANIY) or -999,
		p2_obj,
		p2_obj ~= 0 and space:read_i16(p2_obj + OBJ_OYPOS) or -999,
		p2_proc ~= 0 and space:read_i16(p2_proc + PROC_GANIY) or -999))
	dump_obj(label, "p1", p1_obj)
	dump_obj(label, "p2", p2_obj)
	dump_multipart(label, "p1", p1_obj)
	dump_multipart(label, "p2", p2_obj)
	if dump_palette_slot then
		if p1_obj ~= 0 then
			dump_palette_slot(label, "p1", space:read_u16(p1_obj + OBJ_OPAL))
		end
		if p2_obj ~= 0 then
			dump_palette_slot(label, "p2", space:read_u16(p2_obj + OBJ_OPAL))
		end
	end
end

local function dump_bgprof_palram(label)
	if not space then
		return
	end

	local hits = {}
	for i = 0, NUMPAL - 1 do
		local addr = PALRAM + (i * PALRSIZ)
		local id = space:read_u32(addr)
		if id >= 0xffb00000 and id <= 0xffb20000 then
			hits[#hits + 1] = string.format("%02d:0x%08x/c%d", i, id, space:read_u16(addr + 0x20))
		end
	end
	print(string.format("[mk2-wasteland] %s bgprof-palram %s", label, table.concat(hits, " ")))
end

local function safe_u16(addr)
	local ok, value = pcall(function() return space:read_u16(addr) end)
	if ok then
		return value
	end
	return -1
end

local function color_word(slot, color_index)
	return safe_u16(COLRAM + (slot * 0x1000) + (color_index * 0x10))
end

dump_palette_slot = function(label, owner, opal)
	if not space then
		return
	end

	local slot = opal % 256
	local id = space:read_u32(PALRAM + (slot * PALRSIZ))
	local count = space:read_u16(PALRAM + (slot * PALRSIZ) + 0x20)
	print(string.format(
		"[mk2-wasteland] %s %s-pal opal=0x%04x slot=%02x id=0x%08x count=%d c01=%04x c02=%04x c03=%04x c04=%04x c07=%04x c0b=%04x c0f=%04x",
		label,
		owner,
		opal,
		slot,
		id,
		count,
		color_word(slot, 1),
		color_word(slot, 2),
		color_word(slot, 3),
		color_word(slot, 4),
		color_word(slot, 7),
		color_word(slot, 11),
		color_word(slot, 15)))
end

local function collect_palette_slots()
	local slots = {}
	for i = 1, 8 do
		local q = space:read_u32(list_addr(i))
		local guard = 0
		while q ~= 0 and guard < 120 do
			local opal = space:read_u16(q + OBJ_OPAL)
			local slot = opal % 256
			slots[slot] = true
			q = space:read_u32(q)
			guard = guard + 1
		end
	end
	return slots
end

local function dump_color_slots(label)
	if not space then
		return
	end

	local slots = collect_palette_slots()
	for slot = 0, NUMPAL - 1 do
		if slots[slot] then
			local id = space:read_u32(PALRAM + (slot * PALRSIZ))
			if id >= 0xffb00000 and id <= 0xffb20000 then
				print(string.format(
					"[mk2-wasteland] %s palslot=%02x id=0x%08x c01=%04x c03=%04x c07=%04x c0b=%04x c0f=%04x",
					label,
					slot,
					id,
					color_word(slot, 1),
					color_word(slot, 3),
					color_word(slot, 7),
					color_word(slot, 11),
					color_word(slot, 15)))
			end
		end
	end
end

local function main_screen()
	local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
	if ok and screen ~= nil then
		return screen
	end
	ok, screen = pcall(function() return manager.machine.screens:at(1) end)
	if ok and screen ~= nil then
		return screen
	end
	ok, screen = pcall(function() return manager.machine.screens:at(0) end)
	if ok and screen ~= nil then
		return screen
	end
	return nil
end

local function cache_fields()
	local wanted = {
		["Coin 1"] = true,
		["1 Player Start"] = true,
		["P1 Block"] = true,
		["P1 Block 2"] = true,
		["P1 High Punch"] = true,
		["P1 Low Punch"] = true,
		["P1 High Kick"] = true,
		["P1 Low Kick"] = true,
		["UI Select"] = true,
	}

	for _, port in pairs(manager.machine.ioport.ports) do
		for _, field in pairs(port.fields) do
			if wanted[field.name] then
				fields[field.name] = field
				print(string.format("[mk2-wasteland] found input: %s", field.name))
			end
		end
	end
end

local function pressed(name)
	-- Dismiss MAME ROM-warning dialog ("Press any key to continue")
	-- fires at frame 5-25 before game inputs begin.
	if name == "UI Select" then
		return frame >= 5 and frame < 25
	end

	-- All game inputs shifted +500 frames to clear startup panels.
	if name == "Coin 1" then
		return (frame >= 800 and frame < 820)
			or (frame >= 1020 and frame < 1040)
	end
	if name == "1 Player Start" then
		return (frame >= 920 and frame < 955)
			or (frame >= 1160 and frame < 1195)
	end

	if name == "P1 High Punch"
		or name == "P1 Low Punch"
		or name == "P1 High Kick"
		or name == "P1 Low Kick"
		or name == "P1 Block"
		or name == "P1 Block 2" then
		if not DRIVE_ATTACKS then
			if name == "P1 High Punch" then
				return frame >= 1320 and frame < 2150 and (frame % 70) < 18
			end
			if name == "P1 Block" or name == "P1 Block 2" then
				return frame >= 2250 and frame < 3800
			end
			return false
		end
		if frame < 1400 or frame > 4000 then
			return false
		end
		return (frame % 55) < 18
	end

	return false
end

emu.register_frame(function()
	frame = frame + 1
	if frame == 1 then
		cache_fields()
		space = manager.machine.devices[":maincpu"].spaces["program"]
	end

	if space and frame >= 1 and frame < CURBACK_FORCE_UNTIL then
		space:write_u16(CURBACK, WASTELAND_CURBACK)
	end
	if space and frame >= 1 and frame <= SNAPSHOT_FRAME + 4 then
		hold_center_camera()
	end

	for name, field in pairs(fields) do
		if pressed(name) then
			field:set_value(1)
		else
			field:clear_value()
		end
	end

	if frame % 300 == 0 then
		local curback = space and space:read_u16(CURBACK) or -1
		print(string.format("[mk2-wasteland] frame %d curback=%d", frame, curback))
	end

	if DUMP_RUNTIME_DEBUG and (frame == SNAPSHOT_FRAME or frame == 1500 or frame == 1800 or frame == 2400) then
		dump_players("frame" .. frame)
		dump_runtime_bg("frame" .. frame)
		dump_bgprof_palram("frame" .. frame)
	end

	if DUMP_RUNTIME_DEBUG and frame >= 1800 and frame <= 3000 and frame % 120 == 0 then
		dump_color_slots("frame" .. frame)
	end

	if frame == SNAPSHOT_FRAME and not did_snapshot then
		did_snapshot = true
		local screen = main_screen()
		local ok, err = pcall(function()
			if screen == nil then
				error("no MAME screen found")
			end
			screen:snapshot()
		end)
		print("[mk2-wasteland] snapshot frame" .. SNAPSHOT_FRAME .. " ok=" .. tostring(ok) .. " err=" .. tostring(err))
	end
end)
