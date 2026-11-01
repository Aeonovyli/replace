local MAX_VOLUME = 65536

local function get_save_path(param)
	if not param:match("^[%w_%-%.]+$") then
		return nil
	end
	local dir = minetest.get_worldpath() .. "/simple_replace_plus_data"
	minetest.mkdir(dir)
	return dir .. "/" .. param .. ".txt"
end

local function validate_schematic(schematic)
	if type(schematic) ~= "table" or #schematic == 0 then
		return nil, "Corrupted or empty schematic data."
	end
	for _, entry in ipairs(schematic) do
		if type(entry) ~= "table"
			or type(entry.off) ~= "table"
			or type(entry.off.x) ~= "number"
			or type(entry.off.y) ~= "number"
			or type(entry.off.z) ~= "number"
			or type(entry.node) ~= "table"
			or type(entry.node.name) ~= "string" then
			return nil, "Corrupted schematic data."
		end
		if not minetest.registered_nodes[entry.node.name] then
			return nil, "Slot references an unknown node: " .. entry.node.name
		end
		if entry.node.param2 ~= nil and type(entry.node.param2) ~= "number" then
			return nil, "Corrupted schematic data."
		end
	end
	return schematic
end

return function(srp)
	minetest.register_chatcommand("save", {
		privs = { server = true },
		params = "<slot_name>",
		description = "Save structural contents inside selected nodes to persistent database",
		func = function(name, param)
			if param == "" then return false, "Usage: /save <slot_name>" end
			local p1 = srp.pos1[name]
			local p2 = srp.pos2[name]
			if not p1 or not p2 then return false, "You must set both pos1 and pos2 first!" end

			local min_pos = {
				x = math.min(p1.x, p2.x),
				y = math.min(p1.y, p2.y),
				z = math.min(p1.z, p2.z)
			}
			local max_pos = {
				x = math.max(p1.x, p2.x),
				y = math.max(p1.y, p2.y),
				z = math.max(p1.z, p2.z)
			}

			local vol = (max_pos.x - min_pos.x + 1) *
			            (max_pos.y - min_pos.y + 1) *
			            (max_pos.z - min_pos.z + 1)
			if vol > MAX_VOLUME then
				return false, "Area too large. Maximum volume is " .. MAX_VOLUME .. "."
			end

			local file_path = get_save_path(param)
			if not file_path then return false, "Invalid slot name." end

			local vm = minetest.get_voxel_manip()
			local minp, maxp = vm:read_from_map(min_pos, max_pos)
			local area = VoxelArea:new({ MinEdge = minp, MaxEdge = maxp })
			local data = vm:get_data()
			local param2 = vm:get_param2_data()

			local origin = p1
			local schematic = {}
			for z = min_pos.z, max_pos.z do
				for y = min_pos.y, max_pos.y do
					for x = min_pos.x, max_pos.x do
						local i = area:index(x, y, z)
						local node_name = minetest.get_name_from_content_id(data[i])
						if node_name and node_name ~= "air" then
							local pos = { x = x, y = y, z = z }
							schematic[#schematic + 1] = {
								off = { x = x - origin.x, y = y - origin.y, z = z - origin.z },
								node = { name = node_name, param2 = param2[i] },
								meta = srp.encode_meta(pos),
								timer = srp.save_node_timer(pos)
							}
						end
					end
				end
			end

			if #schematic == 0 then
				return false, "No non-air nodes found in the selected area."
			end

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

			local anchor = srp.pos1[name]
			if not anchor then return false, "You must set /pos1 first." end

			local file_path = get_save_path(param)
			if not file_path then return false, "Invalid slot name." end
			local file = io.open(file_path, "r")
			if not file then return false, "Slot '" .. param .. "' not found." end
			local raw_data = file:read("*all")
			file:close()

			local schematic, err = validate_schematic(minetest.deserialize(raw_data))
			if not schematic then return false, err end

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

			local sort_p1 = {
				x = anchor.x + min_offset.x,
				y = anchor.y + min_offset.y,
				z = anchor.z + min_offset.z
			}
			local sort_p2 = {
				x = anchor.x + max_offset.x,
				y = anchor.y + max_offset.y,
				z = anchor.z + max_offset.z
			}

			local vol = (sort_p2.x - sort_p1.x + 1) *
			            (sort_p2.y - sort_p1.y + 1) *
			            (sort_p2.z - sort_p1.z + 1)
			if vol > MAX_VOLUME then
				return false, "Loaded area exceeds maximum volume of " .. MAX_VOLUME .. "."
			end

			local vm = minetest.get_voxel_manip()
			local minp, maxp = vm:read_from_map(sort_p1, sort_p2)
			local area = VoxelArea:new({ MinEdge = minp, MaxEdge = maxp })
			local data = vm:get_data()
			local param2 = vm:get_param2_data()

			local indices = {}
			local old_nodes, old_param2 = {}, {}
			local old_meta = {}
			local new_nodes, new_param2 = {}, {}
			local new_meta = {}

			for _, entry in ipairs(schematic) do
				local tx = anchor.x + entry.off.x
				local ty = anchor.y + entry.off.y
				local tz = anchor.z + entry.off.z
				local i = area:index(tx, ty, tz)
				local pos = { x = tx, y = ty, z = tz }
				local cid = minetest.get_content_id(entry.node.name)

				indices[#indices + 1] = i

				old_nodes[#old_nodes + 1] = data[i]
				old_param2[#old_param2 + 1] = param2[i]
				old_meta[#old_meta + 1] = {
					pos = pos,
					data = srp.encode_meta(pos),
					timer = srp.save_node_timer(pos)
				}

				data[i] = cid
				param2[i] = entry.node.param2 or 0

				new_nodes[#new_nodes + 1] = cid
				new_param2[#new_param2 + 1] = param2[i]
				new_meta[#new_meta + 1] = {
					pos = { x = tx, y = ty, z = tz },
					data = entry.meta,
					timer = entry.timer
				}
			end

			vm:set_data(data)
			vm:set_param2_data(param2)
			vm:write_to_map()

			for j, entry in ipairs(schematic) do
				local pos = { x = anchor.x + entry.off.x, y = anchor.y + entry.off.y, z = anchor.z + entry.off.z }
				srp.clear_meta(pos)
				srp.apply_meta(pos, entry.meta)
				srp.restore_node_timer(pos, entry.timer)
			end

			srp.push_action(name, {
				p1 = sort_p1,
				p2 = sort_p2,
				indices = indices,
				old_nodes = old_nodes,
				old_param2 = old_param2,
				new_nodes = new_nodes,
				new_param2 = new_param2,
				old_meta = old_meta,
				new_meta = new_meta
			})

			return true, "Loaded " .. #schematic .. " nodes from slot: " .. param
		end
	})
end
