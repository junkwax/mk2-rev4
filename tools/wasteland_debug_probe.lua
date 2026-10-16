-- wasteland_debug_probe.lua
-- Current-map probe for Wasteland / coin-page background crashes.

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/wasteland_debug_probe.log"
local logfh = io.open(LOG_PATH, "w")

local function log(line)
	print(line)
	if logfh then
		logfh:write(line, "\n")
		logfh:flush()
	end
end

local frame = 0
local ui_select = nil
local space = nil
local cpu = nil

local A = {
	tick = 0x01126c70,
	dlists = 0x01126ca0,
	worldtly = 0x01126d00,
	worldtlx8 = 0x01126e40,
	worldtlx7 = 0x01126e60,
	worldtlx6 = 0x01126e80,
	worldtlx5 = 0x01126ea0,
	worldtlx4 = 0x01126ec0,
	worldtlx3 = 0x01126ee0,
	worldtlx2 = 0x01126f00,
	worldtlx = 0x01126f20,
	worldtlx0 = 0x01126f40,
	baklst1 = 0x01127040,
	ground_y = 0x011288c0,
	gstate = 0x01129dc0,
	p1_obj = 0x01129e10,
	p2_obj = 0x0112a9e0,
	f_start = 0x0112b5e0,
	curback = 0x0112b6c0,
	winner_status = 0x0112b700,
	battle_num = 0x0112b740,
	palram = 0x01125710,
	bpalram = 0x01125d50,
	bak1mods = 0x010dbd90,
}

local O = {
	next = 0x000,
	oxpos = 0x090,
	oypos = 0x0b0,
	oflags = 0x0f0,
	osag = 0x100,
	osize = 0x120,
	opal = 0x140,
	oflags2 = 0x160,
	oimg = 0x1a0,
	oid = 0x1c0,
	oshape = 0x1d0,
}

local NUMPAL = 60
local PALRSIZ = 0x40
local SNAP_FRAME = 1500
local EXIT_FRAME = 4200

local function r16(addr)
	return space:read_u16(addr)
end

local function ri16(addr)
	return space:read_i16(addr)
end

local function r32(addr)
	return space:read_u32(addr)
end

local function cpu_reg(name)
	if not cpu then return nil end
	local ok, item = pcall(function() return cpu.state[name] end)
	if not ok or not item then return nil end
	local okv, value = pcall(function() return item.value end)
	if okv then return value end
	okv, value = pcall(function() return item() end)
	if okv then return value end
	return nil
end

local function hx(v)
	if v == nil then return "nil" end
	return string.format("0x%08x", v & 0xffffffff)
end

local function list_addr(n)
	return A.baklst1 - ((n - 1) * 0x20)
end

local function count_list(head)
	local c = 0
	local q = head
	while q ~= 0 and c < 160 do
		c = c + 1
		q = r32(q + O.next)
	end
	return c
end

local function dump_list_head(label, n)
	local head = r32(list_addr(n))
	local count = count_list(head)
	if head == 0 then
		log(string.format("[waste-probe] %s baklst%d empty", label, n))
		return
	end
	log(string.format(
		"[waste-probe] %s baklst%d head=%s count=%d ox=%d oy=%d oid=%04x opal=%04x osag=%s osize=%s oimg=%s flags=%04x flags2=%s next=%s",
		label, n, hx(head), count,
		ri16(head + O.oxpos), ri16(head + O.oypos),
		r16(head + O.oid), r16(head + O.opal),
		hx(r32(head + O.osag)), hx(r32(head + O.osize)), hx(r32(head + O.oimg)),
		r16(head + O.oflags), hx(r32(head + O.oflags2)), hx(r32(head + O.next))))
end

local function dump_palram(label)
	local used = {}
	for i = 0, NUMPAL - 1 do
		local base = A.palram + (i * PALRSIZ)
		local id = r32(base)
		local cnt = r16(base + 0x20)
		if cnt ~= 0 or id ~= 0 then
			used[#used + 1] = string.format("%02d:%s/c%d", i, hx(id), cnt)
		end
	end
	log(string.format("[waste-probe] %s palram used=%d %s", label, #used, table.concat(used, " ")))
end

local function dump_bgmods(label)
	for i = 1, 8 do
		local ptr = r32(A.bak1mods + ((i - 1) * 0x20))
		local bmod = ptr ~= 0 and r32(ptr) or 0
		log(string.format("[waste-probe] %s bak%dmods ptr=%s bmod=%s", label, i, hx(ptr), hx(bmod)))
	end
end

local function dump_state(label)
	local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
	log(string.format(
		"[waste-probe] %s frame=%d tick=%04x pc=%s g=%04x cur=%04x battle=%04x win=%04x f_start=%04x ground=%d dlists=%s world=(%d,%d)",
		label, frame, r16(A.tick), hx(pc), r16(A.gstate), r16(A.curback),
		r16(A.battle_num), r16(A.winner_status), r16(A.f_start), ri16(A.ground_y),
		hx(r32(A.dlists)), ri16(A.worldtlx + 0x10), ri16(A.worldtly + 0x10)))
	for i = 8, 1, -1 do
		dump_list_head(label, i)
	end
	dump_palram(label)
	dump_bgmods(label)
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
		cpu = manager.machine.devices[":maincpu"]
		space = cpu.spaces["program"]
		cache_ui_select()
		log("[waste-probe] started")
	end

	if ui_select ~= nil then
		if frame >= 5 and frame < 35 then
			ui_select:set_value(1)
		else
			ui_select:clear_value()
		end
	end

	if frame == 120 or frame == 300 or frame == 600 or frame == 900 or frame == 1200 or frame == 1500 or frame == 2100 or frame == 3000 then
		dump_state("sample")
	end

	if frame == SNAP_FRAME then
		local screen = main_screen()
		local ok, err = pcall(function()
			if screen == nil then error("no screen") end
			screen:snapshot()
		end)
		log("[waste-probe] snapshot ok=" .. tostring(ok) .. " err=" .. tostring(err))
	end

	local pc = cpu_reg("PC") or 0
	if pc == 0xffa51e10 or pc == 0xffa51fa0 then
		dump_state("lockup-pc")
		manager.machine:exit()
	end

	if frame >= EXIT_FRAME then
		dump_state("final")
		manager.machine:exit()
	end
end)
