local fill={}
local pos1={}
local pos2={}
local replace={}
local clipboard_state={}
local clipboard_entities={}
local selected_node={}
local delete_mode={}
local selection_shape={}
local undo_stack = {}
local redo_stack = {}
local paste_id_counter = 0
local MAX_HISTORY = 64

local function sort_pos(p1, p2)
    return {
        x = math.min(p1.x, p2.x),
        y = math.min(p1.y, p2.y),
        z = math.min(p1.z, p2.z)
    }, {
        x = math.max(p1.x, p2.x),
        y = math.max(p1.y, p2.y),
        z = math.max(p1.z, p2.z)
    }
end

local function is_liquid_content_id(content_id)
    local node_name = core.get_name_from_content_id(content_id)
    local def = core.registered_nodes[node_name]
    return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end

local function resolve_target_node(name, arg)
    if arg == "setnode" then
        local node_name = selected_node[name]
        if not node_name then
            return nil, "Use /setnode first."
        end
        return node_name
    end
    if not core.registered_nodes[arg] then
        return nil, "Not a registered node: " .. arg
    end
    return arg
end

local function resolve_match_pattern(name, arg)
    if arg == "setnode" then
        local node_name = selected_node[name]
        if not node_name then
            return nil, "Use /setnode first."
        end
        return node_name
    end
    if arg == "water" then
        return arg
    end
    if not arg:find("*", 1, true) and not core.registered_nodes[arg] then
        return nil, "Not a registered node: " .. arg
    end
    return arg
end

local function node_name_matches(node_name, pattern)
    if pattern == "*" then
        return true
    end
    if not pattern:find("*", 1, true) then
        return node_name == pattern
    end
    local lua_pattern = "^"
        .. pattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*")
        .. "$"
    return node_name:match(lua_pattern) ~= nil
end

local function make_node_filter(pattern, include_everything)
    if pattern == "water" then
        return function(cid)
            return is_liquid_content_id(cid)
        end
    end
    if pattern == nil then
        if include_everything then
            return function() return true end
        end
        return function(cid)
            local n = core.get_name_from_content_id(cid)
            return n ~= "air" and not is_liquid_content_id(cid)
        end
    end
    return function(cid)
        local n = core.get_name_from_content_id(cid)
        return node_name_matches(n, pattern)
    end
end

local function encode_meta(pos)
	local raw = core.get_meta(pos):to_table()
	if not raw then return nil end
	local has_fields = raw.fields and next(raw.fields) ~= nil
	local has_inv = raw.inventory and next(raw.inventory) ~= nil
	if not has_fields and not has_inv then return nil end

	local fields = {}
	for k, v in pairs(raw.fields or {}) do
		fields[k] = tostring(v)
	end

	local inventory = {}
	for list_name, list in pairs(raw.inventory or {}) do
		local items = {}
		for i, stack in ipairs(list) do
			items[i] = ItemStack(stack):to_string()
		end
		inventory[list_name] = items
	end

	return core.write_json({ fields = fields, inventory = inventory }, false)
end

local function decode_meta(str)
	if type(str) ~= "string" or str == "" then return nil end
	local raw = core.parse_json(str)
	if type(raw) ~= "table" then return nil end
	raw.fields = raw.fields or {}
	raw.inventory = raw.inventory or {}
	return raw
end

local function clear_meta(pos)
	local m = core.get_meta(pos)
	for _, key in ipairs(m:get_keys()) do
		m:set_string(key, "")
	end
	local inv = m:get_inventory()
	for list_name in pairs(inv:get_lists()) do
		inv:set_list(list_name, {})
	end
end

local function apply_meta(pos, encoded)
	local m = core.get_meta(pos)
	local raw = decode_meta(encoded)
	if not raw then
		clear_meta(pos)
		return
	end
	for k, v in pairs(raw.fields) do
		m:set_string(k, tostring(v))
	end
	for list_name, list in pairs(raw.inventory) do
		if type(list) == "table" then
			m:get_inventory():set_list(list_name, list)
		end
	end
end

local function save_node_timer(pos)
	local timer = core.get_node_timer(pos)
	if timer and timer:is_started() then
		return {
			timeout = timer:get_timeout(),
			elapsed = timer:get_elapsed()
		}
	end
	return nil
end

local function restore_node_timer(pos, saved)
	local timer = core.get_node_timer(pos)
	if not timer then return end
	if type(saved) ~= "table" or saved.started == false then
		timer:stop()
		return
	end
	if saved.timeout and saved.elapsed then
		timer:set(saved.timeout, saved.elapsed)
	elseif saved.remaining then
		timer:start(saved.remaining)
	end
end

local function push_action(name, action)
	undo_stack[name] = undo_stack[name] or {}
	undo_stack[name][#undo_stack[name] + 1] = action
	if #undo_stack[name] > MAX_HISTORY then
		table.remove(undo_stack[name], 1)
	end
	redo_stack[name] = {}
end

-- Spawner dolls are recreated by the spawner itself, so copying them would
-- leave a duplicate doll behind.
local ENTITY_COPY_SKIP = {
	["mcl_mobspawners:doll"] = true,
}

local function get_area_objects(p1, p2)
	if core.get_objects_in_area then
		return core.get_objects_in_area(p1, p2)
	end
	local center = vector.multiply(vector.add(p1, p2), 0.5)
	local radius = vector.distance(p1, p2) * 0.5 + 1
	local result = {}
	for _, obj in ipairs(core.get_objects_inside_radius(center, radius)) do
		local pos = obj:get_pos()
		if pos
			and pos.x >= p1.x - 0.5 and pos.x <= p2.x + 0.5
			and pos.y >= p1.y - 0.5 and pos.y <= p2.y + 0.5
			and pos.z >= p1.z - 0.5 and pos.z <= p2.z + 0.5 then
			result[#result + 1] = obj
		end
	end
	return result
end

local function spawn_action_entities(action)
	for _, entry in ipairs(action.entities or {}) do
		local obj = core.add_entity(entry.pos, entry.name, entry.staticdata or "")
		if obj then
			if entry.yaw then
				obj:set_yaw(entry.yaw)
			end
			local ent = obj:get_luaentity()
			if ent then
				ent._replace_paste_id = action.paste_id
			end
		end
	end
end

local function remove_action_entities(action)
	if not action.paste_id then return end
	if not action.entities or #action.entities == 0 then return end
	local p1 = action.entity_p1 or action.p1
	local p2 = action.entity_p2 or action.p2
	for _, obj in ipairs(get_area_objects(p1, p2)) do
		if not obj:is_player() then
			local ent = obj:get_luaentity()
			if ent and ent._replace_paste_id == action.paste_id then
				obj:remove()
			end
		end
	end
end

local function apply_action(action, use_new)
	local nodes = use_new and action.new_nodes or action.old_nodes
	local param2_values = use_new and action.new_param2 or action.old_param2
	local light_values = use_new and action.new_param1 or action.old_param1
	local metas = use_new and action.new_meta or action.old_meta

	local vm = core.get_voxel_manip()
	vm:read_from_map(action.p1, action.p2)
	local data = vm:get_data()
	local param2 = param2_values and vm:get_param2_data()
	local light = light_values and vm:get_light_data()

	for idx, i in ipairs(action.indices) do
		data[i] = nodes[idx]
		if param2 then param2[i] = param2_values[idx] end
		if light then light[i] = light_values[idx] end
	end

	vm:set_data(data)
	if param2 then vm:set_param2_data(param2) end
	if light then vm:set_light_data(light) end
	vm:write_to_map()

	if metas then
		for _, entry in ipairs(metas) do
			clear_meta(entry.pos)
			apply_meta(entry.pos, entry.data)
			restore_node_timer(entry.pos, entry.timer)
		end
	end

	if use_new then
		spawn_action_entities(action)
	else
		remove_action_entities(action)
	end
end

-- Rectangle is the default; sphere is fitted inside the pos1/pos2 box.
-- A non-cubic box produces an ellipsoid, which still fits the box exactly.
local function make_shape_filter(name, p1, p2)
    if selection_shape[name] ~= "sphere" then
        return function() return true end
    end
    local center_x = (p1.x + p2.x) / 2
    local center_y = (p1.y + p2.y) / 2
    local center_z = (p1.z + p2.z) / 2
    local radius_x = (p2.x - p1.x + 1) / 2
    local radius_y = (p2.y - p1.y + 1) / 2
    local radius_z = (p2.z - p1.z + 1) / 2
    return function(x, y, z)
        local dx = (x - center_x) / radius_x
        local dy = (y - center_y) / radius_y
        local dz = (z - center_z) / radius_z
        return dx * dx + dy * dy + dz * dz <= 1
    end
end

local function replace_area(name, p1, p2, filter, newnode)
    local in_shape = make_shape_filter(name, p1, p2)
    local vm = core.get_voxel_manip()
    local minp, maxp = vm:read_from_map(p1, p2)
    local area = VoxelArea:new({MinEdge = minp, MaxEdge = maxp})
    local data = vm:get_data()
    local param2 = vm:get_param2_data()
    local cid_new = core.get_content_id(newnode)
    local indices = {}
    local old_nodes = {}
    local old_param2 = {}
    local new_nodes = {}
    local new_param2 = {}
    for z = p1.z, p2.z do
        for y = p1.y, p2.y do
            for x = p1.x, p2.x do
                local i = area:index(x, y, z)
                local old = data[i]
                if in_shape(x, y, z) and filter(old) then
                    indices[#indices+1] = i
                    old_nodes[#old_nodes+1] = old
                    old_param2[#old_param2+1] = param2[i]
                    data[i] = cid_new
                    param2[i] = 0
                    new_nodes[#new_nodes+1] = cid_new
                    new_param2[#new_param2+1] = 0
                end
            end
        end
    end
    vm:set_data(data)
    vm:set_param2_data(param2)
    vm:write_to_map()
    push_action(name, {
        p1 = vector.new(p1),
        p2 = vector.new(p2),
        indices = indices,
        old_nodes = old_nodes,
        old_param2 = old_param2,
        new_nodes = new_nodes,
        new_param2 = new_param2
    })
end

core.register_chatcommand("pos1",{
 privs={server=true},
    func = function(name)
        local p = core.get_player_by_name(name)
        if not p then return end
        pos1[name] = vector.round(p:get_pos())
        return true, "Position 1 set to " .. core.pos_to_string(pos1[name])
    end
})

core.register_chatcommand("pos2",{
 privs={server=true},
    func = function(name)
        local p = core.get_player_by_name(name)
        if not p then return end
        pos2[name] = vector.round(p:get_pos())
        return true, "Position 2 set to " .. core.pos_to_string(pos2[name])
    end
})

core.register_chatcommand("fill_type",{
 privs={server=true},
    params="[rectangle|sphere]",
    description="Choose the selection shape used by replace, fill, delete, copy and save",
    func = function(name, param)
        local arg = param:match("^%s*(.-)%s*$")
        if arg == "" then
            local current = selection_shape[name] or "rectangle"
            return true, "Fill type is " .. current .. ". Usage: /fill_type <rectangle|sphere>"
        end
        if arg ~= "rectangle" and arg ~= "sphere" then
            return false, "Usage: /fill_type <rectangle|sphere>"
        end
        selection_shape[name] = arg
        return true, "Fill type set to " .. arg .. "."
    end
})

core.register_chatcommand("setnode",{
 privs={server=true},
 params="[<node_name>]",
 description="Select a replacement node by name or from your hand.",
    func = function(name, param)
        local p = core.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local node_name = param:match("^%s*(.-)%s*$")
        if node_name == "" then
            node_name = p:get_wielded_item():get_name()
            if node_name == "" then return false, "No node in hand." end
        end
        if not core.registered_nodes[node_name] then return false, "Not a placeable node: " .. node_name end
        selected_node[name] = node_name
        return true, "Selected node: " .. node_name
    end
})

core.register_chatcommand("replace",{
 privs={server=true},
 params="[<from>] [<to>]",
 description="Replace selected area. Use * as a wildcard and setnode for the selected node.",
    func = function(name, param)
        if not pos1[name] or not pos2[name] then return false, "Set pos1 and pos2 first." end
        local a, b = param:match("(%S+)%s+(%S+)")
        local from, to, err
        if a and b then
            from, err = resolve_match_pattern(name, a)
            if not from then return false, err end
            to, err = resolve_target_node(name, b)
            if not to then return false, err end
        elseif param:match("%S") then
            local single = param:match("^%s*(.-)%s*$")
            if single == "water" then
                if not selected_node[name] then return false, "Use /setnode first." end
                from = "water"
                to = selected_node[name]
            else
                to, err = resolve_target_node(name, single)
                if not to then return false, err end
                selected_node[name] = to
            end
        else
            if not selected_node[name] then return false, "Use /setnode first." end
            to = selected_node[name]
        end
        local p1, p2 = sort_pos(pos1[name], pos2[name])
        replace_area(name, p1, p2, make_node_filter(from), to)
        if from then
            return true, "Replaced nodes matching " .. from .. " with " .. to
        end
        return true, "Replaced area with " .. to
    end
})

core.register_chatcommand("fill",{
 privs={server=true},
 params="[<from>] [<to>]",
 description="Fill selected area, including air. Use * as a wildcard and setnode for the selected node.",
    func = function(name, param)
        if not pos1[name] or not pos2[name] then return false, "Set pos1 and pos2 first." end
        local a, b = param:match("(%S+)%s+(%S+)")
        local from, to, err
        if a and b then
            from, err = resolve_match_pattern(name, a)
            if not from then return false, err end
            to, err = resolve_target_node(name, b)
            if not to then return false, err end
        elseif param:match("%S") then
            local single = param:match("^%s*(.-)%s*$")
            if single == "water" then
                if not selected_node[name] then return false, "Use /setnode first." end
                from = "water"
                to = selected_node[name]
            else
                to, err = resolve_target_node(name, single)
                if not to then return false, err end
                selected_node[name] = to
            end
        else
            if not selected_node[name] then return false, "Use /setnode first." end
            to = selected_node[name]
        end
        local p1, p2 = sort_pos(pos1[name], pos2[name])
        replace_area(name, p1, p2, make_node_filter(from, true), to)
        fill[name] = true
        if from then
            return true, "Filled nodes matching " .. from .. " with " .. to
        end
        return true, "Filled area with " .. to
    end
})

core.register_chatcommand("delete",{
 privs={server=true},
 params="[<node_name>]",
 description="Delete blocks within pos1 and pos2. Use * as a wildcard and setnode for the selected node.",
    func = function(name, param)
        if not pos1[name] or not pos2[name] then return false, "Set pos1 and pos2 first." end
        local p1, p2 = sort_pos(pos1[name], pos2[name])
        local arg = param:match("^%s*(.-)%s*$")
        local pattern, err
        if arg ~= "" then
            pattern, err = resolve_match_pattern(name, arg)
            if not pattern then return false, err end
        end
        replace_area(name, p1, p2, make_node_filter(pattern), "air")
        delete_mode[name] = true
        if pattern then
            return true, "Deleted nodes matching " .. pattern .. " within the selected area"
        end
        return true, "Deleted nodes within the selected area"
    end
})

core.register_chatcommand("undo",{
 privs={server=true},
    func = function(name)
        local stack = undo_stack[name]
        if not stack or #stack == 0 then return false, "Nothing to undo." end
        local action = table.remove(stack)
        redo_stack[name] = redo_stack[name] or {}
        redo_stack[name][#redo_stack[name] + 1] = action
        if #redo_stack[name] > MAX_HISTORY then
            table.remove(redo_stack[name], 1)
        end
        apply_action(action, false)
        return true, "Nodes changed are reverted."
    end
})

core.register_chatcommand("redo",{
 privs={server=true},
    func = function(name)
        local stack = redo_stack[name]
        if not stack or #stack == 0 then return false, "Nothing to redo." end
        local action = table.remove(stack)
        undo_stack[name] = undo_stack[name] or {}
        undo_stack[name][#undo_stack[name] + 1] = action
        if #undo_stack[name] > MAX_HISTORY then
            table.remove(undo_stack[name], 1)
        end
        apply_action(action, true)
        return true, "Action redone."
    end
})

local ROTATE_STEPS = {[90] = 1, [180] = 2, [270] = 3}

local FACEDIR_ROTATE = {
    [1] = { 1,  2,  3,  0, 13, 14, 15, 12, 17, 18, 19, 16,
            9, 10, 11,  8,  5,  6,  7,  4, 23, 20, 21, 22},
    [2] = { 2,  3,  0,  1, 10, 11,  8,  9,  6,  7,  4,  5,
           18, 19, 16, 17, 14, 15, 12, 13, 22, 23, 20, 21},
    [3] = { 3,  0,  1,  2, 19, 16, 17, 18, 15, 12, 13, 14,
            7,  4,  5,  6, 11,  8,  9, 10, 21, 22, 23, 20},
}

local WALLMOUNTED_ROTATE = {
    [1] = {0, 1, 5, 4, 2, 3, 0, 0},
    [2] = {0, 1, 3, 2, 5, 4, 0, 0},
    [3] = {0, 1, 4, 5, 3, 2, 0, 0},
}

local function get_clipboard_pivots(nodes_list)
    local min_x, max_x = math.huge, -math.huge
    local min_z, max_z = math.huge, -math.huge
    for _, entry in ipairs(nodes_list) do
        min_x = math.min(min_x, entry.offset.x)
        max_x = math.max(max_x, entry.offset.x)
        min_z = math.min(min_z, entry.offset.z)
        max_z = math.max(max_z, entry.offset.z)
    end
    local center_x = (min_x + max_x) / 2
    local center_z = (min_z + max_z) / 2
    local rotate_x, rotate_z = center_x, center_z
    if (rotate_x - math.floor(rotate_x)) ~= (rotate_z - math.floor(rotate_z)) then
        rotate_x = math.floor(rotate_x + 0.5)
        rotate_z = math.floor(rotate_z + 0.5)
    end
    return {
        center_x = center_x,
        center_z = center_z,
        rotate_x = rotate_x,
        rotate_z = rotate_z,
        steps = 0,
    }
end

local function get_rotation_pivot(state, steps)
    if steps % 2 == 0 then
        return {x = state.center_x, z = state.center_z}
    end
    return {x = state.rotate_x, z = state.rotate_z}
end

local function rotate_offset(offset, steps, pivot)
    local dx, dz = offset.x - pivot.x, offset.z - pivot.z
    local x, z
    if steps == 1 then
        x, z = pivot.x + dz, pivot.z - dx
    elseif steps == 2 then
        x, z = pivot.x - dx, pivot.z - dz
    elseif steps == 3 then
        x, z = pivot.x - dz, pivot.z + dx
    else
        x, z = offset.x, offset.z
    end
    return vector.new(x, offset.y, z)
end

local function rotate_param2(param2, paramtype2, steps)
    if steps == 0 then
        return param2
    end
    if paramtype2 == "facedir" or paramtype2 == "colorfacedir" then
        local orient = param2 % 32
        return param2 - orient + (FACEDIR_ROTATE[steps][orient + 1] or orient)
    elseif paramtype2 == "4dir" or paramtype2 == "color4dir" then
        local orient = param2 % 4
        return param2 - orient + ((orient + steps) % 4)
    elseif paramtype2 == "wallmounted" or paramtype2 == "colorwallmounted" then
        local orient = param2 % 8
        return param2 - orient + (WALLMOUNTED_ROTATE[steps][orient + 1] or orient)
    elseif paramtype2 == "degrotate" then
        return (param2 - steps * 60) % 240
    elseif paramtype2 == "colordegrotate" then
        local rotation = param2 % 32
        local color = param2 - rotation
        return color + ((rotation - steps * 6) % 24)
    end
    return param2
end

core.register_chatcommand("rotate", {
    privs = {server = true},
    params = "<90|180|270>",
    description = "Rotate the copied blocks and entities around the Y axis. Rotations add up; run /rotate with no value to see the current rotation.",
    func = function(name, param)
        local arg = param:match("^%s*(.-)%s*$")
        if arg == "" then
            local state = clipboard_state[name]
            local nodes_list = replace[name]
            if state and nodes_list and #nodes_list > 0 then
                return true, "Clipboard rotation is " .. (state.steps * 90)
                    .. " degrees. Usage: /rotate <90|180|270>"
            end
            return false, "Usage: /rotate <90|180|270>"
        end
        local angle = tonumber(arg)
        local steps = angle and ROTATE_STEPS[angle]
        if not steps then
            return false, "Usage: /rotate <90|180|270>"
        end
        local nodes_list = replace[name]
        if not nodes_list or type(nodes_list) ~= "table" or #nodes_list == 0 then
            return false, "Clipboard is empty. Run /copy first."
        end
        local state = clipboard_state[name]
        if not state then
            return false, "Clipboard state is missing. Run /copy again."
        end
        local total_steps = (state.steps + steps) % 4
        state.steps = total_steps
        local pivot = get_rotation_pivot(state, total_steps)
        local registered_nodes = core.registered_nodes
        for _, entry in ipairs(nodes_list) do
            entry.offset = rotate_offset(entry.base_offset or entry.offset, total_steps, pivot)
            local node_name = core.get_name_from_content_id(entry.data)
            local def = node_name and registered_nodes[node_name]
            if def then
                entry.param2 = rotate_param2(entry.base_param2 or entry.param2,
                    def.paramtype2, total_steps)
            end
        end
        for _, entry in ipairs(clipboard_entities[name] or {}) do
            entry.offset = rotate_offset(entry.base_offset or entry.offset, total_steps, pivot)
            entry.yaw = (entry.base_yaw or 0) - total_steps * math.pi / 2
        end
        return true, "Rotated clipboard by " .. (steps * 90)
            .. " degrees; total rotation is " .. (total_steps * 90) .. " degrees."
    end
})

core.register_chatcommand("copy", {
    privs = {server = true},
    description = "Copy blocks, block data and entities in the selected area to the clipboard",
    func = function(name)
        if not pos1[name] or not pos2[name] then return false, "Set /pos1 and /pos2 first." end
        local p = core.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local p1, p2 = sort_pos(pos1[name], pos2[name])
        local origin_pos = pos1[name]
        local vm = core.get_voxel_manip()
        local minp, maxp = vm:read_from_map(p1, p2)
        local area = VoxelArea:new({MinEdge = minp, MaxEdge = maxp})
        local data = vm:get_data()
        local param1 = vm:get_light_data()
        local param2 = vm:get_param2_data()
        local air_cid = core.get_content_id("air")
        local in_shape = make_shape_filter(name, p1, p2)
        local nodes_list = {}
        local count = 0
        for z = p1.z, p2.z do
            for y = p1.y, p2.y do
                for x = p1.x, p2.x do
                    local i = area:index(x, y, z)
                    if in_shape(x, y, z) and data[i] ~= air_cid then
                        local offset = vector.new(x - origin_pos.x, y - origin_pos.y, z - origin_pos.z)
                        count = count + 1
                        nodes_list[count] = {
                            offset = offset,
                            data = data[i],
                            param1 = param1[i],
                            param2 = param2[i],
                            base_param2 = param2[i],
                            meta = encode_meta({x = x, y = y, z = z}),
                            timer = save_node_timer({x = x, y = y, z = z})
                        }
                    end
                end
            end
        end
        if count == 0 then
            return false, "No non-air nodes found in the selected area."
        end
        local min_offset
        for _, entry in ipairs(nodes_list) do
            local o = entry.offset
            if not min_offset then
                min_offset = vector.new(o)
            else
                min_offset.x = math.min(min_offset.x, o.x)
                min_offset.y = math.min(min_offset.y, o.y)
                min_offset.z = math.min(min_offset.z, o.z)
            end
        end
        for _, entry in ipairs(nodes_list) do
            entry.offset = vector.subtract(entry.offset, min_offset)
            entry.base_offset = vector.new(entry.offset)
        end
        local entities_list = {}
        for _, obj in ipairs(get_area_objects(p1, p2)) do
            if not obj:is_player() then
                local pos = obj:get_pos()
                local ent = obj:get_luaentity()
                if pos and ent and ent.name and not ENTITY_COPY_SKIP[ent.name]
                    and in_shape(pos.x, pos.y, pos.z) then
                    local staticdata = ""
                    if type(ent.get_staticdata) == "function" then
                        local ok, data_str = pcall(ent.get_staticdata, ent)
                        if ok and type(data_str) == "string" then
                            staticdata = data_str
                            -- Mobs use "remove" to mean "despawn instead of reload".
                            if staticdata == "remove" then staticdata = "" end
                        end
                    end
                    local offset = vector.subtract(
                        vector.subtract(pos, origin_pos), min_offset)
                    entities_list[#entities_list + 1] = {
                        name = ent.name,
                        offset = offset,
                        base_offset = vector.new(offset),
                        staticdata = staticdata,
                        yaw = obj:get_yaw(),
                        base_yaw = obj:get_yaw()
                    }
                end
            end
        end
        replace[name] = nodes_list
        clipboard_entities[name] = entities_list
        clipboard_state[name] = get_clipboard_pivots(nodes_list)
        return true, "Copied " .. count .. " nodes and " .. #entities_list
            .. " entities to structural clipboard."
    end
})

core.register_chatcommand("paste", {
    privs = {server = true},
    func = function(name)
        local nodes_list = replace[name]
        if not nodes_list or type(nodes_list) ~= "table" or #nodes_list == 0 then
            return false, "Clipboard is empty. Run /copy first."
        end
        local p = core.get_player_by_name(name)
        if not p then return false, "Player not found." end
        local player_pos = vector.round(p:get_pos())
        local min_offset = vector.new(math.huge, math.huge, math.huge)
        local max_offset = vector.new(-math.huge, -math.huge, -math.huge)
        for _, entry in ipairs(nodes_list) do
            min_offset.x = math.min(min_offset.x, entry.offset.x)
            min_offset.y = math.min(min_offset.y, entry.offset.y)
            min_offset.z = math.min(min_offset.z, entry.offset.z)
            max_offset.x = math.max(max_offset.x, entry.offset.x)
            max_offset.y = math.max(max_offset.y, entry.offset.y)
            max_offset.z = math.max(max_offset.z, entry.offset.z)
        end
        local p1 = vector.add(player_pos, min_offset)
        local p2 = vector.add(player_pos, max_offset)
        local vm = core.get_voxel_manip()
        local minp, maxp = vm:read_from_map(p1, p2)
        local area = VoxelArea:new({MinEdge = minp, MaxEdge = maxp})
        local data = vm:get_data()
        local param1 = vm:get_light_data()
        local param2 = vm:get_param2_data()
        local indices = {}
        local old_nodes = {}
        local old_param1 = {}
        local old_param2 = {}
        local new_nodes = {}
        local new_param1 = {}
        local new_param2 = {}
        local old_meta = {}
        local new_meta = {}
        for idx, entry in ipairs(nodes_list) do
            local absolute_pos = vector.add(player_pos, entry.offset)
            local pos = {x = absolute_pos.x, y = absolute_pos.y, z = absolute_pos.z}
            local i = area:index(absolute_pos.x, absolute_pos.y, absolute_pos.z)
            indices[idx] = i
            old_nodes[idx] = data[i]
            old_param1[idx] = param1[i]
            old_param2[idx] = param2[i]
            old_meta[idx] = {
                pos = pos,
                data = encode_meta(pos),
                timer = save_node_timer(pos)
            }
            data[i] = entry.data
            param1[i] = entry.param1
            param2[i] = entry.param2
            new_nodes[idx] = entry.data
            new_param1[idx] = entry.param1
            new_param2[idx] = entry.param2
            new_meta[idx] = {
                pos = pos,
                data = entry.meta,
                timer = entry.timer
            }
        end
        vm:set_data(data)
        vm:set_light_data(param1)
        vm:set_param2_data(param2)
        vm:write_to_map()
        for _, entry in ipairs(new_meta) do
            clear_meta(entry.pos)
            apply_meta(entry.pos, entry.data)
            restore_node_timer(entry.pos, entry.timer)
        end
        local entity_spawns = {}
        local entity_p1 = vector.new(math.huge, math.huge, math.huge)
        local entity_p2 = vector.new(-math.huge, -math.huge, -math.huge)
        for _, entry in ipairs(clipboard_entities[name] or {}) do
            local spawn_pos = vector.add(player_pos, entry.offset)
            entity_spawns[#entity_spawns + 1] = {
                name = entry.name,
                pos = spawn_pos,
                staticdata = entry.staticdata,
                yaw = entry.yaw
            }
            entity_p1.x = math.min(entity_p1.x, spawn_pos.x)
            entity_p1.y = math.min(entity_p1.y, spawn_pos.y)
            entity_p1.z = math.min(entity_p1.z, spawn_pos.z)
            entity_p2.x = math.max(entity_p2.x, spawn_pos.x)
            entity_p2.y = math.max(entity_p2.y, spawn_pos.y)
            entity_p2.z = math.max(entity_p2.z, spawn_pos.z)
        end
        if #entity_spawns == 0 then
            entity_p1, entity_p2 = p1, p2
        else
            entity_p1 = vector.subtract(entity_p1, vector.new(3, 3, 3))
            entity_p2 = vector.add(entity_p2, vector.new(3, 3, 3))
        end
        paste_id_counter = paste_id_counter + 1
        local action = {
            action_type = "paste",
            p1 = p1,
            p2 = p2,
            entity_p1 = entity_p1,
            entity_p2 = entity_p2,
            paste_id = paste_id_counter,
            entities = entity_spawns,
            indices = indices,
            old_nodes = old_nodes,
            old_param1 = old_param1,
            old_param2 = old_param2,
            new_nodes = new_nodes,
            new_param1 = new_param1,
            new_param2 = new_param2,
            old_meta = old_meta,
            new_meta = new_meta
        }
        push_action(name, action)
        spawn_action_entities(action)
        return true, "Successfully pasted " .. #nodes_list .. " nodes and "
            .. #entity_spawns .. " entities relative to your location."
    end
})

local register_storage = dofile(core.get_modpath("replace") .. "/storage.lua")
register_storage({
    pos1 = pos1,
    pos2 = pos2,
    push_action = push_action,
    make_shape_filter = make_shape_filter,
    encode_meta = encode_meta,
    apply_meta = apply_meta,
    clear_meta = clear_meta,
    save_node_timer = save_node_timer,
    restore_node_timer = restore_node_timer,
})
