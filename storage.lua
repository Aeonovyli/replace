local srp_pos1 = {}
local srp_pos2 = {}
local srp_undo_history = {}
local srp_redo_history = {}

local MAX_VOLUME = 65536
local HISTORY_CAP = 32

local function get_save_path(param)
	if not param:match("^[%w_%-%.]+$") then
		return nil
	end
	local dir = minetest.get_worldpath() .. "/simple_replace_plus_data"
	minetest.mkdir(dir)
	return dir .. "/" .. param .. ".txt"
end

local old_pos1 = minetest.registered_chatcommands["pos1"]
if old_pos1 and old_pos1.func then
	local old_pos1_func = old_pos1.func -- FIX: Extract function directly
	minetest.registered_chatcommands["pos1"].func = function(name, param)
		local status, msg = old_pos1_func(name, param)
		local p = minetest.get_player_by_name(name)
		if status and p then
			srp_pos1[name] = vector.round(p:get_pos())
		end
		return status, msg
	end
end

local old_pos2 = minetest.registered_chatcommands["pos2"]
if old_pos2 and old_pos2.func then
	local old_pos2_func = old_pos2.func -- FIX: Extract function directly
	minetest.registered_chatcommands["pos2"].func = function(name, param)
		local status, msg = old_pos2_func(name, param)
		local p = minetest.get_player_by_name(name)
		if status and p then
			srp_pos2[name] = vector.round(p:get_pos())
		end
		return status, msg
	end
end

local function encode_meta(pos)
	local raw = minetest.get_meta(pos):to_table()
	if not raw then return nil end
	local has_fields = raw.fields and next(raw.fields) ~= nil
	local has_inv = raw.inventory and next(raw.inventory) ~= nil
	if not has_fields and not has_inv then return nil end
	for k, v in pairs(raw.fields or {}) do
		if type(v) == "table" then
			raw.fields[k] = { "__json__", minetest.write_json(v, false) }
		end
	end
	return minetest.write_json({ fields = raw.fields, inventory = raw.inventory }, false)
end

local function decode_meta(str)
	if not str or str == "" then return nil end
	local raw = minetest.parse_json(str)
	if type(raw) ~= "table" then return nil end
	for k, v in pairs(raw.fields or {}) do
		if type(v) == "table" and v[1] == "__json__" then
			raw.fields[k] = minetest.parse_json(v[2])
		end
	end
	return raw
end

local function apply_meta(pos, encoded)
	local m = minetest.get_meta(pos)
	local raw = decode_meta(encoded)
	if not raw then
		local tbl = m:to_table()
		if tbl and tbl.fields then
			for k in pairs(tbl.fields) do m:set_string(k, "") end
		end
		local inv = m:get_inventory()
		for _, name in ipairs({ "main", "recipe", "craft", "upgraded", "trades", "whitelist" }) do
			inv:set_list(name, {})
		end
		return
	end
	if raw.fields then
		for k, v in pairs(raw.fields) do
			if type(v) == "table" then
				m:set_table(k, v)
			else
				m:set_string(k, tostring(v))
			end
		end
	end
	if raw.inventory then
		for list_name, list in pairs(raw.inventory) do
			m:get_inventory():set_list(list_name, list)
		end
	end
end


local function clear_meta(pos)
	local m = minetest.get_meta(pos)
	local tbl = m:to_table()
	if tbl and tbl.fields then
		for k in pairs(tbl.fields) do
			m:set_string(k, "")
		end
	end
	local inv = m:get_inventory()
	for _, name in ipairs({ "main", "recipe", "craft", "upgraded", "trades", "whitelist" }) do
		inv:set_list(name, {})
	end
end


local function save_node_timer(pos)
	return nil
end

local function restore_node_timer(pos, saved)
	return
end

local function get_bounds(name)
	local p1 = srp_pos1[name]
	local p2 = srp_pos2[name]
	if not p1 or not p2 then return nil end
	return {
		min = { x = math.min(p1.x, p2.x), y = math.min(p1.y, p2.y), z = math.min(p1.z, p2.z) },
		max = { x = math.max(p1.x, p2.x), y = math.max(p1.y, p2.y), z = math.max(p1.z, p2.z) },
		origin = { x = p1.x, y = p1.y, z = p1.z }
	}
end

minetest.register_chatcommand("save", {
	privs = { server = true },
	params = "<slot_name>",
	description = "Save structural contents inside selected nodes to persistent database",
	func = function(name, param)
		if param == "" then return false, "Usage: /save <slot_name>" end
		local bounds = get_bounds(name)
		if not bounds then return false, "You must set both pos1 and pos2 first!" end

		local vol = (bounds.max.x - bounds.min.x + 1) *
		            (bounds.max.y - bounds.min.y + 1) *
		            (bounds.max.z - bounds.min.z + 1)
		if vol > MAX_VOLUME then
			return false, "Area too large. Maximum volume is " .. MAX_VOLUME .. "."
		end

		local vm = minetest.get_voxel_manip()
		local minp, maxp = vm:read_from_map(bounds.min, bounds.max)
		local area = VoxelArea:new({ MinEdge = minp, MaxEdge = maxp })
		local data = vm:get_data()
		local param2 = vm:get_param2_data()

		local schematic = {}
		for z = bounds.min.z, bounds.max.z do
			for y = bounds.min.y, bounds.max.y do
				for x = bounds.min.x, bounds.max.x do
					local i = area:index(x, y, z)
					local node_name = minetest.get_name_from_content_id(data[i])
					if node_name ~= "air" then
						local meta = encode_meta({ x = x, y = y, z = z })
						local timer = save_node_timer({ x = x, y = y, z = z })
						schematic[#schematic + 1] = {
							off = { x = x - bounds.origin.x, y = y - bounds.origin.y, z = z - bounds.origin.z },
							node = { name = node_name, param2 = param2[i] },
							meta = meta,
							timer = timer
						}
					end
				end
			end
		end

		if #schematic == 0 then
			return false, "No non-air nodes found in the selected area."
		end

		local file_path = get_save_path(param)
		if not file_path then return false, "Invalid slot name." end
		local file = io.open(file_path, "w")
		if not file then return false, "Failed to write file." end
		file:write(minetest.serialize(schematic))
		file:close()

		return true, "Saved " .. #schematic .. " nodes to slot: " .. param
	end
})

minetest.register_chatcommand("load", {
	privs = { server = true },
	params = "<slot_name>",
	description = "Load persistent slot structural configurations onto current pos1 position",
	func = function(name, param)
		if param == "" then return false, "Usage: /load <slot_name>" end

		local file_path = get_save_path(param)
		if not file_path then return false, "Invalid slot name." end
		local file = io.open(file_path, "r")
		if not file then return false, "Slot '" .. param .. "' not found." end
		local raw_data = file:read("*all")
		file:close()

		local schematic = minetest.deserialize(raw_data)
		if not schematic or type(schematic) ~= "table" or #schematic == 0 then
			return false, "Corrupted or empty schematic data."
		end

		local anchor = srp_pos1[name]
		if not anchor then return false, "You must set /pos1 first." end

		local min_offset = { x = math.huge, y = math.huge, z = math.huge }
		local max_offset = { x = -math.huge, y = -math.huge, z = -math.huge }
		for _, entry in ipairs(schematic) do
			min_offset.x = math.min(min_offset.x, entry.off.x)
			min_offset.y = math.min(min_offset.y, entry.off.y)
			min_offset.z = math.min(min_offset.z, entry.off.z)
			max_offset.x = math.max(max_offset.x, entry.off.x)
			max_offset.y = math.max(max_offset.y, entry.off.y)
			max_offset.z = math.max(max_offset.z, entry.off.z)
		end

		local p1 = { x = anchor.x + min_offset.x, y = anchor.y + min_offset.y, z = anchor.z + min_offset.z }
		local p2 = { x = anchor.x + max_offset.x, y = anchor.y + max_offset.y, z = anchor.z + max_offset.z }
		local sort_p1 = { x = math.min(p1.x, p2.x), y = math.min(p1.y, p2.y), z = math.min(p1.z, p2.z) }
		local sort_p2 = { x = math.max(p1.x, p2.x), y = math.max(p1.y, p2.y), z = math.max(p1.z, p2.z) }

		local vol = (sort_p2.x - sort_p1.x + 1) * (sort_p2.y - sort_p1.y + 1) * (sort_p2.z - sort_p1.z + 1)
		if vol > MAX_VOLUME then
			return false, "Loaded area exceeds maximum volume of " .. MAX_VOLUME .. "."
		end

		local vm = minetest.get_voxel_manip()
		local minp, maxp = vm:read_from_map(sort_p1, sort_p2)
		local area = VoxelArea:new({ MinEdge = minp, MaxEdge = maxp })
		local data = vm:get_data()
		local param2 = vm:get_param2_data()

		local indices = {}
		local old_nodes = {}
		local old_param2 = {}
		local old_meta = {}
		local old_timers = {}

		for _, entry in ipairs(schematic) do
			local tx = anchor.x + entry.off.x
			local ty = anchor.y + entry.off.y
			local tz = anchor.z + entry.off.z
			local i = area:index(tx, ty, tz)
			local pos = { x = tx, y = ty, z = tz }

			table.insert(indices, i)
			table.insert(old_nodes, data[i])
			table.insert(old_param2, param2[i])

			table.insert(old_meta, { pos = pos, data = encode_meta(pos) })
			table.insert(old_timers, save_node_timer(pos))

			data[i] = minetest.get_content_id(entry.node.name)
			param2[i] = entry.node.param2 or 0
		end

		vm:set_data(data)
		vm:set_param2_data(param2)
		vm:write_to_map()
		
		minetest.fix_light(sort_p1, sort_p2)

		for j, entry in ipairs(schematic) do
			local pos = { x = anchor.x + entry.off.x, y = anchor.y + entry.off.y, z = anchor.z + entry.off.z }
			clear_meta(pos)
			apply_meta(pos, entry.meta)
			restore_node_timer(pos, entry.timer)
		end

		srp_undo_history[name] = srp_undo_history[name] or {}
		srp_undo_history[name][#srp_undo_history[name] + 1] = {
			p1 = sort_p1,
			p2 = sort_p2,
			indices = indices,
			old_nodes = old_nodes,
			old_param2 = old_param2,
			old_meta = old_meta,
			old_timers = old_timers
		}

		if #srp_undo_history[name] > HISTORY_CAP then
			table.remove(srp_undo_history[name], 1)
		end

		return true, "Loaded " .. #schematic .. " nodes from slot: " .. param
	end
})

local old_undo = minetest.registered_chatcommands["undo"]
if old_undo and old_undo.func then
	local old_undo_func = old_undo.func -- FIX: Extract function directly
	minetest.registered_chatcommands["undo"].func = function(name, param)
		local history = srp_undo_history[name]
		if history and #history > 0 then
			local action = table.remove(history)
			local vm = minetest.get_voxel_manip()
			local minp, maxp = vm:read_from_map(action.p1, action.p2)
			local area = VoxelArea:new({ MinEdge = minp, MaxEdge = maxp })
			local data = vm:get_data()
			local param2 = vm:get_param2_data()

			for j, idx in ipairs(action.indices) do
				data[idx] = action.old_nodes[j]
				param2[idx] = action.old_param2[j]
			end

			vm:set_data(data)
			vm:set_param2_data(param2)
			vm:write_to_map()

			for j, meta_restore in ipairs(action.old_meta) do
				clear_meta(meta_restore.pos)
				apply_meta(meta_restore.pos, meta_restore.data)
				restore_node_timer(meta_restore.pos, action.old_timers[j])
			end

			minetest.fix_light(action.p1, action.p2)

			srp_redo_history[name] = srp_redo_history[name] or {}
			srp_redo_history[name][#srp_redo_history[name] + 1] = action

			if #srp_redo_history[name] > HISTORY_CAP then
				table.remove(srp_redo_history[name], 1)
			end

			return true, "Loaded structural changes are reverted."
		end
		return old_undo_func(name, param)
	end
end
