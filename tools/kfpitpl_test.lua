-- kfpitpl_test.lua
-- Drives MK2 into the KFPITPL test stage, holds the Pit camera stable, dumps
-- runtime background state, and takes a MAME framebuffer snapshot.
--
-- Usage:
--   C:\MAME\mame.exe mk2 -script C:\Users\you\Workplace\mk2-main\tools\kfpitpl_test.lua

local frame = 0
local fields = {}
local space = nil
local did_snapshot = false
local stage_select_seen = nil
local stage_left_start = nil
local stage_right_start = nil
local stage_seeded_curback = false

local GSTATE = 0x01129d90
local P1_STATE = 0x01129db0
local P2_STATE = 0x0112a980
local P1_CHAR = 0x01129e40
local P2_CHAR = 0x0112aa10
local CURBACK = 0x0112b680
local BAKLST1 = 0x01127010
local BAKLST2 = BAKLST1 - 0x20
local BAK1MODS = 0x010dbd90
local BAK2MODS = BAK1MODS + 0x20
local WORLDTLY = 0x01126cd0
local WORLDTLX0 = 0x01126f10
local WORLDTLX2 = 0x01126ed0
local KFPITPL_BG_BMOD = 0xffb61540
local P1_OBJ = 0x01129de0
local P2_OBJ = 0x0112a9b0
local ACTIVE = 0x010dc6d0

local PROC_ID = 0x020
local P_TIME = 0x030
local P_SPTR = 0x040
local P_A11 = 0x060
local P_A10 = 0x080
local P_A9 = 0x0a0
local P_WAKE = 0x0e0
local PID_MASTER = 3

local OBJ_NEXT = 0x000
local OBJ_OXPOS = 0x090
local OBJ_OYPOS = 0x0b0
local OBJ_OFLAGS = 0x0f0
local OBJ_OSAG = 0x100
local OBJ_OSIZE = 0x120
local OBJ_OPAL = 0x140
local OBJ_OIMG = 0x1a0

local function env_number(name, default)
	if os ~= nil and os.getenv ~= nil then
		local value = tonumber(os.getenv(name) or "")
		if value ~= nil then return value end
	end
	return default
end

local SNAPSHOT_FRAME = env_number("KFPITPL_SNAPSHOT_FRAME", 9000)
local FORCE_STAGE_UNTIL = SNAPSHOT_FRAME + 120
local PIN_WORLDX = env_number("KFPITPL_WORLDX", 0)
local PIN_WORLDY = env_number("KFPITPL_WORLDY", 32)
local CURBACK_STAGE = env_number("KFPITPL_CURBACK", 10)
local FORCE_CURBACK = env_number("KFPITPL_FORCE_CURBACK", 1) ~= 0
local STAGE_SELECT_CURBACK = env_number("KFPITPL_STAGE_SELECT_CURBACK", -1)
local SELECT_STAGE_LEFT = env_number("KFPITPL_SELECT_STAGE_LEFT", 0) ~= 0
local SELECT_STAGE_RIGHT = env_number("KFPITPL_SELECT_STAGE_RIGHT", 0) ~= 0
local DUMP_CRAM = env_number("KFPITPL_DUMP_CRAM", 0) ~= 0
local COLRAM_YUNIT = 0x01810000
local COLRAM_NONY = 0x01800000
local TARGET_FILL_RGB555 = 0x1cc6 -- #393535 in MK2 RGB555

local function main_screen()
	local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
	if ok and screen ~= nil then return screen end
	ok, screen = pcall(function() return manager.machine.screens:at(1) end)
	if ok and screen ~= nil then return screen end
	ok, screen = pcall(function() return manager.machine.screens:at(0) end)
	if ok and screen ~= nil then return screen end
	return nil
end

local function cache_fields()
	local wanted = {
		["Coin 1"] = true,
		["1 Player Start"] = true,
		["P1 High Punch"] = true,
		["P1 Low Punch"] = true,
		["P1 High Kick"] = true,
		["P1 Low Kick"] = true,
		["P1 Left"] = true,
		["P1 Right"] = true,
		["P1 Block"] = true,
		["P1 Block 2"] = true,
		["2 Player Start"] = true,
		["2 Players Start"] = true,
		["P2 High Punch"] = true,
		["P2 Low Punch"] = true,
		["P2 High Kick"] = true,
		["P2 Low Kick"] = true,
		["P2 Left"] = true,
		["P2 Right"] = true,
		["P2 Block"] = true,
		["P2 Block 2"] = true,
		["UI Select"] = true,
	}
	for _, port in pairs(manager.machine.ioport.ports) do
		for _, field in pairs(port.fields) do
			if wanted[field.name] then
				fields[field.name] = field
				print(string.format("[kfpitpl] found input: %s", field.name))
			end
		end
	end
end

local function master_saved_word(offset)
	if not space then return nil end
	local p = space:read_u32(ACTIVE)
	local index = 0
	while p ~= 0 and index < 64 do
		if space:read_u16(p + PROC_ID) == PID_MASTER then
			return space:read_u32(p + offset)
		end
		p = space:read_u32(p)
		index = index + 1
	end
	return nil
end

local function pressed(name)
	-- Dismiss "one or more ROM/disk images..." if MAME starts the script early
	-- enough. The PowerShell wrapper also posts Space, so this is a belt-and-
	-- suspenders path.
	local in_stage_select = space and space:read_u16(GSTATE) == 13
	if in_stage_select then
		if stage_select_seen == nil then
			stage_select_seen = frame
		end
		if not stage_seeded_curback and STAGE_SELECT_CURBACK >= 0 then
			space:write_i16(CURBACK, STAGE_SELECT_CURBACK)
			stage_seeded_curback = true
			print(string.format("[kfpitpl] seeded stage select curback=%d", STAGE_SELECT_CURBACK))
		end
	elseif space then
		stage_select_seen = nil
		stage_left_start = nil
		stage_right_start = nil
		stage_seeded_curback = false
	end
	if name == "UI Select" then
		return frame >= 5 and frame < 35
	end
	if name == "Coin 1" then
		return frame >= 760 and frame < 1350 and (frame % 120) < 24
	end
	if name == "1 Player Start" then
		if frame >= 900 and frame < 1500 and (frame % 90) < 24 then
			return true
		end
		if in_stage_select and stage_select_seen ~= nil then
			local dt = frame - stage_select_seen
			return dt >= 320 and (dt % 90) < 18
		end
		return false
	end
	if name == "2 Player Start" or name == "2 Players Start" then
		if frame >= 980 and frame < 1600 and (frame % 100) < 24 then
			return true
		end
		if in_stage_select and stage_select_seen ~= nil then
			local dt = frame - stage_select_seen
			return dt >= 320 and (dt % 90) < 18
		end
		return false
	end
	if in_stage_select then
		local dt = frame - stage_select_seen
		if SELECT_STAGE_LEFT and stage_left_start == nil then
			if dt >= 260 then stage_left_start = frame end
		end
		if SELECT_STAGE_RIGHT and stage_right_start == nil then
			if dt >= 260 then stage_right_start = frame end
		end
	end
	if name == "P1 Left" or name == "P2 Left" then
		return stage_left_start ~= nil and frame >= stage_left_start and frame < (stage_left_start + 8)
	end
	if name == "P1 Right" or name == "P2 Right" then
		return stage_right_start ~= nil and frame >= stage_right_start and frame < (stage_right_start + 8)
	end
	if name == "P1 High Punch" then
		return frame >= 3900 and frame < SNAPSHOT_FRAME and (frame % 55) < 22
	end
	if name == "P1 Low Punch" then
		return frame >= 3950 and frame < SNAPSHOT_FRAME and (frame % 80) < 18
	end
	if name == "P1 High Kick" then
		return frame >= 4000 and frame < SNAPSHOT_FRAME and (frame % 110) < 18
	end
	if name == "P1 Low Kick" then
		return frame >= 4050 and frame < SNAPSHOT_FRAME and (frame % 130) < 18
	end
	if name == "P2 High Punch" then
		return frame >= 3900 and frame < SNAPSHOT_FRAME and (frame % 65) < 22
	end
	if name == "P2 Low Punch" then
		return frame >= 3950 and frame < SNAPSHOT_FRAME and (frame % 85) < 18
	end
	if name == "P2 High Kick" then
		return frame >= 4000 and frame < SNAPSHOT_FRAME and (frame % 115) < 18
	end
	if name == "P2 Low Kick" then
		return frame >= 4050 and frame < SNAPSHOT_FRAME and (frame % 135) < 18
	end
	if name == "P1 Block" or name == "P1 Block 2" then
		return frame >= 4400 and frame < SNAPSHOT_FRAME
	end
	if name == "P2 Block" or name == "P2 Block 2" then
		return frame >= 4400 and frame < SNAPSHOT_FRAME
	end
	return false
end

local function count_list(head)
	local count = 0
	local p = head
	while p ~= 0 and count < 200 do
		count = count + 1
		p = space:read_u32(p + OBJ_NEXT)
	end
	return count
end

local function dump_obj(label, p)
	if p == 0 then
		print(string.format("[kfpitpl] %s obj=0", label))
		return
	end
	print(string.format(
		"[kfpitpl] %s obj=0x%08x next=0x%08x ox=%d oy=%d flags=0x%04x sag=0x%08x size=0x%08x opal=0x%04x oimg=0x%08x",
		label,
		p,
		space:read_u32(p + OBJ_NEXT),
		space:read_i16(p + OBJ_OXPOS),
		space:read_i16(p + OBJ_OYPOS),
		space:read_u16(p + OBJ_OFLAGS),
		space:read_u32(p + OBJ_OSAG),
		space:read_u32(p + OBJ_OSIZE),
		space:read_u16(p + OBJ_OPAL),
		space:read_u32(p + OBJ_OIMG)))
end

local function dump_master_process(label)
	if not space then return end
	local p = space:read_u32(ACTIVE)
	local index = 0
	while p ~= 0 and index < 64 do
		local pid = space:read_u16(p + PROC_ID)
		if pid == PID_MASTER then
			print(string.format(
				"[kfpitpl] %s master_proc=0x%08x time=%d wake=0x%08x a9=0x%08x a10=0x%08x a11=0x%08x sp=0x%08x",
				label,
				p,
				space:read_i16(p + P_TIME),
				space:read_u32(p + P_WAKE),
				space:read_u32(p + P_A9),
				space:read_u32(p + P_A10),
				space:read_u32(p + P_A11),
				space:read_u32(p + P_SPTR)))
			return
		end
		p = space:read_u32(p)
		index = index + 1
	end
	print(string.format("[kfpitpl] %s master_proc not found", label))
end

local function color_distance(a, b)
	local ab = a % 32
	local ag = math.floor(a / 32) % 32
	local ar = math.floor(a / 1024) % 32
	local bb = b % 32
	local bg = math.floor(b / 32) % 32
	local br = math.floor(b / 1024) % 32
	local dr = ar - br
	local dg = ag - bg
	local db = ab - bb
	return (dr * dr) + (dg * dg) + (db * db)
end

local function dump_cram_base(base, label)
	local best_pen = 0
	local best_color = 0
	local best_dist = 999999
	for pen = 0, 255 do
		local color = space:read_u16(base + (pen * 0x10))
		local dist = color_distance(color, TARGET_FILL_RGB555)
		if dist < best_dist then
			best_pen = pen
			best_color = color
			best_dist = dist
		end
	end
	print(string.format("[kfpitpl] cram %s best pen=0x%02x color=0x%04x dist=%d target=0x%04x",
		label, best_pen, best_color, best_dist, TARGET_FILL_RGB555))
	for pen = 0, 255 do
		local color = space:read_u16(base + (pen * 0x10))
		if color == TARGET_FILL_RGB555 then
			print(string.format("[kfpitpl] cram %s exact pen=0x%02x color=0x%04x",
				label, pen, color))
		end
	end
end

local function dump_cram()
	if not space then return end
	dump_cram_base(COLRAM_YUNIT, "yunit")
	dump_cram_base(COLRAM_NONY, "nony")
end

local function dump_runtime(label)
	if not space then return end
	local head = space:read_u32(BAKLST1)
	local fg_head = space:read_u32(BAKLST2)
	local modentry = space:read_u32(BAK1MODS)
	local fg_modentry = space:read_u32(BAK2MODS)
	local bmod = 0
	local fg_bmod = 0
	local modx = 0
	local mody = 0
	local fg_modx = 0
	local fg_mody = 0
	if modentry ~= 0 then
		bmod = space:read_u32(modentry)
		modx = space:read_i16(modentry + 0x20)
		mody = space:read_i16(modentry + 0x30)
	end
	if fg_modentry ~= 0 then
		fg_bmod = space:read_u32(fg_modentry)
		fg_modx = space:read_i16(fg_modentry + 0x20)
		fg_mody = space:read_i16(fg_modentry + 0x30)
	end
	print(string.format(
		"[kfpitpl] %s frame=%d gstate=%d p1state=%d p2state=%d p1char=%d p2char=%d curback=%d worldy=%d worldx=%d worldx2=%d bak1mods=0x%08x bmod=0x%08x mod=(%d,%d) baklst1=0x%08x count=%d bak2mods=0x%08x fgbmod=0x%08x fgmod=(%d,%d) baklst2=0x%08x fgcount=%d",
		label,
		frame,
		space:read_u16(GSTATE),
		space:read_u16(P1_STATE),
		space:read_u16(P2_STATE),
		space:read_u16(P1_CHAR),
		space:read_u16(P2_CHAR),
		space:read_u16(CURBACK),
		space:read_i16(WORLDTLY + 16),
		space:read_i16(WORLDTLX0 + 16),
		space:read_i16(WORLDTLX2 + 16),
		modentry,
		bmod,
		modx,
		mody,
		head,
		count_list(head),
		fg_modentry,
		fg_bmod,
		fg_modx,
		fg_mody,
		fg_head,
		count_list(fg_head)))
	dump_obj(label .. " bak1[0]", head)
	if head ~= 0 then
		dump_obj(label .. " bak1[1]", space:read_u32(head + OBJ_NEXT))
	end
	dump_obj(label .. " bak2[0]", fg_head)
	if fg_head ~= 0 then
		dump_obj(label .. " bak2[1]", space:read_u32(fg_head + OBJ_NEXT))
	end
	dump_obj(label .. " p1", space:read_u32(P1_OBJ))
	dump_obj(label .. " p2", space:read_u32(P2_OBJ))
	dump_master_process(label)
end

emu.register_frame(function()
	frame = frame + 1
	if frame == 1 then
		cache_fields()
		space = manager.machine.devices[":maincpu"].spaces["program"]
		print(string.format("[kfpitpl] loaded snapshot_frame=%d worldx=%d worldy=%d curback=%d force_curback=%s", SNAPSHOT_FRAME, PIN_WORLDX, PIN_WORLDY, CURBACK_STAGE, tostring(FORCE_CURBACK)))
	end

	if space and frame < FORCE_STAGE_UNTIL then
		local gstate = space:read_u16(GSTATE)
		if FORCE_CURBACK and gstate ~= 13 then
			space:write_i16(CURBACK, CURBACK_STAGE)
		end
		local modentry = space:read_u32(BAK1MODS)
		local bmod = 0
		if modentry ~= 0 then
			bmod = space:read_u32(modentry)
		end
		if bmod == KFPITPL_BG_BMOD then
			space:write_i16(WORLDTLY + 16, PIN_WORLDY)
			space:write_i16(WORLDTLX0 + 16, PIN_WORLDX)
			space:write_i16(WORLDTLX2 + 16, PIN_WORLDX)
		end
	end

	for name, field in pairs(fields) do
		if pressed(name) then
			field:set_value(1)
		else
			field:clear_value()
		end
	end

	-- fine-grained light probe around the known crash window
	if space and frame >= 4000 and frame <= 5500 and (frame % 20) == 0 then
		print(string.format("[kfpitpl] tick frame=%d gstate=%d p1st=%d p2st=%d curback=%d bak1mods=0x%08x",
			frame,
			space:read_u16(GSTATE),
			space:read_u16(P1_STATE),
			space:read_u16(P2_STATE),
			space:read_u16(CURBACK),
			space:read_u32(BAK1MODS)))
		dump_master_process("tick")
	end

	if frame == 300 or frame == 1200 or frame == 1800 or frame == 2400
	   or frame == 3000 or frame == 3600 or frame == 4200
	   or frame == 4300 or frame == 4400 or frame == 4500
	   or frame == 4600 or frame == 4700 or frame == 4800
	   or frame == 5100 or frame == 5400 or frame == 5700
	   or frame == 6000 or frame == 6600 or frame == 7200
	   or frame == 7800 or frame == SNAPSHOT_FRAME then
		dump_runtime("probe")
	end

	if frame == SNAPSHOT_FRAME and not did_snapshot then
		did_snapshot = true
		if DUMP_CRAM then
			dump_cram()
		end
		local screen = main_screen()
		local ok, err = pcall(function()
			if screen == nil then error("no MAME screen found") end
			screen:snapshot()
		end)
		print("[kfpitpl] snapshot frame " .. SNAPSHOT_FRAME .. " ok=" .. tostring(ok) .. " err=" .. tostring(err))
	end
end)
