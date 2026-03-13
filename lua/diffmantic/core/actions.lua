
local M = {}

local MIN_MOVE_SIZE = 3

local function is_update_blocked(si, info)
	return false
end

local MOVE_EMIT_TYPES = {
	function_definition = true,
	method_definition = true,
	function_declaration = true,
	function_item = true,
	local_function = true,
	class_declaration = true,
	class_specifier = true,
	struct_specifier = true,
	enum_specifier = true,
	interface_declaration = true,
	type_declaration = true,
	type_alias_declaration = true,
}

local FUNCTION_CONTAINER_TYPES = {
	function_definition = true,
	method_definition = true,
	function_declaration = true,
	function_item = true,
	local_function = true,
	function_expression = true,
	arrow_function = true,
}

local function is_descendant_or_same(id, ancestor_id, info)
	local cur = id
	while cur do
		if cur == ancestor_id then
			return true
		end
		local entry = info[cur]
		cur = entry and entry.parent_id or nil
	end
	return false
end

local function nearest_call_expression(id, info)
	local cur = id
	while cur do
		local entry = info[cur]
		if not entry then
			return nil
		end
		if entry.type == "call_expression" then
			return cur
		end
		cur = entry.parent_id
	end
	return nil
end

local function call_callee_id(call_id, info)
	local call = info[call_id]
	if not call or not call.node then
		return nil
	end
	for child in call.node:iter_children() do
		local cid = child:id()
		local cinfo = info[cid]
		if cinfo and child:named() then
			if cinfo.type ~= "argument_list" then
				return cid
			end
		end
	end
	return nil
end

local function call_arg_count(call_id, info)
	local call = info[call_id]
	if not call or not call.node then
		return nil
	end
	for child in call.node:iter_children() do
		local cid = child:id()
		local cinfo = info[cid]
		if cinfo and cinfo.type == "argument_list" and cinfo.node then
			local count = 0
			for arg in cinfo.node:iter_children() do
				if arg:named() and info[arg:id()] then
					count = count + 1
				end
			end
			return count
		end
	end
	return nil
end

local function call_callee_arity_compatible(sid, did, src_info, dst_info)
	local src_call = nearest_call_expression(sid, src_info)
	local dst_call = nearest_call_expression(did, dst_info)
	if not src_call or not dst_call then
		return true
	end

	local src_callee = call_callee_id(src_call, src_info)
	local dst_callee = call_callee_id(dst_call, dst_info)
	if not src_callee or not dst_callee then
		return true
	end

	if not is_descendant_or_same(sid, src_callee, src_info) or not is_descendant_or_same(did, dst_callee, dst_info) then
		return true
	end

	local src_args = call_arg_count(src_call, src_info)
	local dst_args = call_arg_count(dst_call, dst_info)
	if src_args and dst_args and src_args ~= dst_args then
		return false
	end
	return true
end


local function build_maps(mappings)
	local s2d, d2s = {}, {}
	for _, m in ipairs(mappings) do
		s2d[m.src] = m.dst
		d2s[m.dst] = m.src
	end
	return s2d, d2s
end

local function node_range(node)
	if not node then return nil end
	local ok, sr, sc, er, ec = pcall(node.range, node)
	if not ok then return nil end
	return { start_row = sr, start_col = sc, end_row = er, end_col = ec }
end

local function node_label(info_entry, buf)
	if not info_entry then return "" end
	if info_entry.label and info_entry.label ~= "" then return info_entry.label end
	if info_entry.node and buf then
		local ok, txt = pcall(vim.treesitter.get_node_text, info_entry.node, buf)
		if ok and txt then
			local first = txt:match("^[^\n]*") or ""
			if #first > 80 then first = first:sub(1, 80) .. "…" end
			return first
		end
	end
	return ""
end

local function effective_label(info_entry, buf)
	if not info_entry then
		return ""
	end
	if info_entry.label and info_entry.label ~= "" then
		return info_entry.label
	end
	if info_entry.node and buf then
		local ok, txt = pcall(vim.treesitter.get_node_text, info_entry.node, buf)
		if ok and txt then
			local first = txt:match("^[^\n]*") or ""
			return vim.trim(first)
		end
	end
	return ""
end

local function node_text(node, buf)
	if not node or not buf then
		return ""
	end
	local ok, txt = pcall(vim.treesitter.get_node_text, node, buf)
	if not ok or not txt then
		return ""
	end
	return vim.trim(txt)
end

local function pair_key_text(node, buf)
	if not node then
		return ""
	end
	for child in node:iter_children() do
		local ok_named, is_named = pcall(child.named, child)
		if ok_named and is_named then
			local txt = node_text(child, buf)
			if txt ~= "" then
				return txt
			end
		end
	end
	return ""
end

local function pair_value_node(node, info)
	if not node then
		return nil
	end
	local named = {}
	for child in node:iter_children() do
		local ok_named, is_named = pcall(child.named, child)
		if ok_named and is_named and info[child:id()] then
			table.insert(named, child)
		end
	end
	return named[2]
end

local function property_key_text(info_entry, buf)
	if not info_entry or not info_entry.node then
		return ""
	end
	if info_entry.type == "pair" then
		return pair_key_text(info_entry.node, buf)
	end
	return node_text(info_entry.node, buf)
end

local function is_leaf_info(info_entry)
	if not info_entry then
		return false
	end
	if info_entry.size == 1 then
		return true
	end
	if info_entry.node then
		local ok, cnt = pcall(info_entry.node.named_child_count, info_entry.node)
		if ok and cnt == 0 then
			return true
		end
	end
	return false
end

local function is_top_level_like(id, info, root_id)
	local entry = info[id]
	if not entry then
		return false
	end
	if entry.parent_id == root_id then
		return true
	end
	local p = entry.parent_id and info[entry.parent_id] or nil
	return p and p.parent_id == root_id or false
end

local function should_emit_move_type(type_)
	return MOVE_EMIT_TYPES[type_] == true
end

local function nearest_function_container(id, info)
	local cur = info[id]
	while cur and cur.parent_id do
		local p = info[cur.parent_id]
		if not p then
			return nil
		end
		if FUNCTION_CONTAINER_TYPES[p.type] then
			return cur.parent_id
		end
		cur = p
	end
	return nil
end

local function should_emit_named_leaf_edit(info_entry)
	if not info_entry or not info_entry.node then
		return false
	end
	if (info_entry.size or 0) > 1 then
		return false
	end
	if not info_entry.node:named() then
		return false
	end
	return true
end

local function range_contains(outer, inner)
	if not outer or not inner then
		return false
	end
	if outer.start_row == nil or outer.end_row == nil or outer.start_col == nil or outer.end_col == nil then
		return false
	end
	if inner.start_row == nil or inner.end_row == nil or inner.start_col == nil or inner.end_col == nil then
		return false
	end
	if inner.start_row < outer.start_row or inner.end_row > outer.end_row then
		return false
	end
	if inner.start_row == outer.start_row and inner.start_col < outer.start_col then
		return false
	end
	if inner.end_row == outer.end_row and inner.end_col > outer.end_col then
		return false
	end
	return true
end

local function range_span(range)
	if not range then
		return 0
	end
	local sr = range.start_row or 0
	local er = range.end_row or sr
	return math.max(1, (er - sr) + 1)
end

local function bfs_order(root, dst_info)
	local order = {}
	local queue = { root:id() }
	local head  = 1
	while head <= #queue do
		local id = queue[head]; head = head + 1
		table.insert(order, id)
		local di = dst_info[id]
		if di and di.node then
			for child in di.node:iter_children() do
				local cid = child:id()
				if dst_info[cid] then table.insert(queue, cid) end
			end
		end
	end
	return order
end

local function post_order(root, src_info)
	local order = {}
	local function visit(id)
		local si = src_info[id]
		if not si or not si.node then return end
		for child in si.node:iter_children() do
			local cid = child:id()
			if src_info[cid] then visit(cid) end
		end
		table.insert(order, id)
	end
	visit(root:id())
	return order
end

local function child_positions(parent_id, info)
	local pos  = {}
	local list = {}
	local p = info[parent_id]
	if not p or not p.node then return pos, list end
	local i = 0
	for child in p.node:iter_children() do
		local cid = child:id()
		if info[cid] then
			i = i + 1
			pos[cid] = i
			table.insert(list, cid)
		end
	end
	return pos, list
end

local function mapped_prev_next(id, parent_id, info, peer_map)
	local p = info[parent_id]
	if not p or not p.node then
		return nil, nil
	end

	local mapped_children = {}
	for child in p.node:iter_children() do
		local cid = child:id()
		if info[cid] and peer_map[cid] then
			table.insert(mapped_children, cid)
		end
	end

	for i, cid in ipairs(mapped_children) do
		if cid == id then
			return mapped_children[i - 1], mapped_children[i + 1]
		end
	end
	return nil, nil
end

local function has_stable_mapped_neighbors(sid, did, src_info, dst_info, s2d, d2s)
	local si = src_info[sid]
	local di = dst_info[did]
	if not si or not di then
		return false
	end
	if not si.parent_id or not di.parent_id then
		return false
	end
	if s2d[si.parent_id] ~= di.parent_id then
		return false
	end

	local sprev, snext = mapped_prev_next(sid, si.parent_id, src_info, s2d)
	local dprev, dnext = mapped_prev_next(did, di.parent_id, dst_info, d2s)

	local prev_ok = (sprev == nil and dprev == nil) or (sprev ~= nil and dprev ~= nil and s2d[sprev] == dprev)
	local next_ok = (snext == nil and dnext == nil) or (snext ~= nil and dnext ~= nil and s2d[snext] == dnext)
	return prev_ok and next_ok
end

local function allow_unmapped_field_decl_parent(si, di, src_info, dst_info, s2d)
	if not si or not di then
		return false
	end
	if si.type ~= "field_identifier" or di.type ~= "field_identifier" then
		return false
	end
	local spid = si.parent_id
	local dpid = di.parent_id
	if not spid or not dpid then
		return false
	end
	local sp = src_info[spid]
	local dp = dst_info[dpid]
	if not sp or not dp then
		return false
	end
	if sp.type ~= "field_declaration" or dp.type ~= "field_declaration" then
		return false
	end
	local sgpid = sp.parent_id
	local dgpid = dp.parent_id
	if not sgpid or not dgpid then
		return false
	end
	return s2d[sgpid] == dgpid
end

local function lis_membership(seq, displacement)
	local n = #seq
	if n == 0 then return {} end

	local dp = {}
	for i = 1, n do dp[i] = 1 end
	for i = 2, n do
		for j = 1, i - 1 do
			if seq[j] < seq[i] then
				dp[i] = math.max(dp[i], dp[j] + 1)
			end
		end
	end

	local max_len = 0
	for i = 1, n do max_len = math.max(max_len, dp[i]) end

	local in_lis = {}
	local cur = max_len
	local prev_val = math.huge
	for i = n, 1, -1 do
		if dp[i] == cur and seq[i] < prev_val then
			if displacement then
				local best_j = i
				for j = i - 1, 1, -1 do
					if dp[j] == cur and seq[j] < prev_val and seq[j] <= seq[best_j] then
						if (displacement[j] or 0) < (displacement[best_j] or 0) then
							best_j = j
						end
					end
				end
				if best_j ~= i and dp[best_j] == cur and seq[best_j] < prev_val then
					in_lis[best_j] = true
					prev_val = seq[best_j]
					cur = cur - 1
					goto continue_lis
				end
			end
			in_lis[i] = true
			prev_val = seq[i]
			cur = cur - 1
		end
		::continue_lis::
	end
	return in_lis
end

local function collapse_shorthand_pair_updates(actions, src_info, dst_info, s2d, src_buf, dst_buf)
	local delete_idxs = {}
	local insert_idxs = {}
	for i, action in ipairs(actions) do
		if action.type == "delete" and action.src_node then
			local sid = action.src_node:id()
			local si = src_info[sid]
			if si and si.type == "shorthand_property_identifier" then
				table.insert(delete_idxs, i)
			end
		elseif action.type == "insert" and action.dst_node then
			local did = action.dst_node:id()
			local di = dst_info[did]
			if di and di.type == "pair" then
				table.insert(insert_idxs, i)
			end
		end
	end

	if #delete_idxs == 0 or #insert_idxs == 0 then
		return actions
	end

	local used_insert = {}
	local drop = {}
	local appended = {}

	for _, del_idx in ipairs(delete_idxs) do
		local del_action = actions[del_idx]
		local sid = del_action.src_node and del_action.src_node:id() or nil
		local si = sid and src_info[sid] or nil
		if not si then
			goto continue_delete
		end

		local src_key = node_text(del_action.src_node, src_buf)
		if src_key == "" then
			goto continue_delete
		end
		local mapped_parent = si.parent_id and s2d[si.parent_id] or nil

		local best_idx = nil
		local best_dist = nil
		for _, ins_idx in ipairs(insert_idxs) do
			if used_insert[ins_idx] then
				goto continue_insert
			end

			local ins_action = actions[ins_idx]
			local did = ins_action.dst_node and ins_action.dst_node:id() or nil
			local di = did and dst_info[did] or nil
			if not di then
				goto continue_insert
			end
			if mapped_parent and di.parent_id ~= mapped_parent then
				goto continue_insert
			end

			local dst_key = pair_key_text(ins_action.dst_node, dst_buf)
			if dst_key ~= src_key then
				goto continue_insert
			end

			local srow = del_action.src and del_action.src.start_row or 0
			local drow = ins_action.dst and ins_action.dst.start_row or 0
			local dist = math.abs(srow - drow)
			if not best_idx or dist < best_dist then
				best_idx = ins_idx
				best_dist = dist
			end

			::continue_insert::
		end

		if best_idx then
			local ins_action = actions[best_idx]
			local did = ins_action.dst_node and ins_action.dst_node:id() or nil
			local di = did and dst_info[did] or nil

			used_insert[best_idx] = true
			drop[del_idx] = true
			drop[best_idx] = true

			table.insert(appended, {
				type = "update",
				src = del_action.src,
				dst = ins_action.dst,
				src_node = del_action.src_node,
				dst_node = ins_action.dst_node,
				metadata = {
					node_type = "pair",
					old_name = node_label(si, src_buf),
					new_name = node_label(di, dst_buf),
					from_line = (del_action.src and (del_action.src.start_row + 1))
						or (del_action.metadata and del_action.metadata.from_line)
						or nil,
					to_line = (ins_action.dst and (ins_action.dst.start_row + 1))
						or (ins_action.metadata and ins_action.metadata.to_line)
						or (ins_action.metadata and ins_action.metadata.from_line)
						or nil,
				},
			})
		end

		::continue_delete::
	end

	if next(drop) == nil then
		return actions
	end

	local filtered = {}
	for i, action in ipairs(actions) do
		if not drop[i] then
			table.insert(filtered, action)
		end
	end
	for _, action in ipairs(appended) do
		table.insert(filtered, action)
	end

	return filtered
end

local function collapse_object_pair_updates(actions, src_info, dst_info, s2d, d2s, src_buf, dst_buf)
	local function is_source_property(info_entry)
		return info_entry and (info_entry.type == "shorthand_property_identifier" or info_entry.type == "pair")
	end

	local function build_dst_pair_index()
		local index = {}
		for did, di in pairs(dst_info or {}) do
			if di and di.type == "pair" and di.parent_id then
				local key = property_key_text(di, dst_buf)
				if key ~= "" then
					index[di.parent_id] = index[di.parent_id] or {}
					index[di.parent_id][key] = index[di.parent_id][key] or {}
					table.insert(index[di.parent_id][key], did)
				end
			end
		end
		return index
	end

	local insert_by_node = {}
	local delete_by_node = {}
	local update_by_dst = {}
	for idx, action in ipairs(actions or {}) do
		if action.type == "insert" and action.dst_node then
			local did = action.dst_node:id()
			insert_by_node[did] = idx
		elseif action.type == "delete" and action.src_node then
			local sid = action.src_node:id()
			delete_by_node[sid] = idx
		elseif action.type == "update" and action.dst_node then
			local did = action.dst_node:id()
			update_by_dst[did] = update_by_dst[did] or {}
			table.insert(update_by_dst[did], idx)
		end
	end

	local drop = {}
	local appended = {}
	local used_dst = {}
	local dst_pair_index = build_dst_pair_index()

	for sid, si in pairs(src_info or {}) do
		if not is_source_property(si) or s2d[sid] then
			goto continue_src
		end
		local mapped_parent = si.parent_id and s2d[si.parent_id] or nil
		if not mapped_parent then
			goto continue_src
		end

		local src_key = property_key_text(si, src_buf)
		if src_key == "" then
			goto continue_src
		end

		local best_di = nil
		local best_dist = nil
		local candidates = dst_pair_index[mapped_parent] and dst_pair_index[mapped_parent][src_key] or nil
		for _, did in ipairs(candidates or {}) do
			local di = dst_info[did]
			if used_dst[did] or d2s[did] then
				goto continue_candidate
			end
			local dist = math.abs((si.start_row or 0) - (di.start_row or 0))
			if not best_di or dist < best_dist then
				best_di = did
				best_dist = dist
			end
			::continue_candidate::
		end

		if not best_di then
			goto continue_src
		end

		local di = dst_info[best_di]
		local src_range = node_range(si.node)
		local dst_range = node_range(di.node)
		if not src_range or not dst_range then
			goto continue_src
		end

		local dst_value = pair_value_node(di.node, dst_info)
		local dst_value_text = node_text(dst_value, dst_buf)
		local dst_text = node_label(di, dst_buf)
		if dst_text == "" and dst_value_text ~= "" then
			dst_text = src_key .. ": " .. dst_value_text
		end

		local existing_insert = insert_by_node[best_di]
		if existing_insert then
			drop[existing_insert] = true
		end
		local existing_delete = delete_by_node[sid]
		if existing_delete then
			drop[existing_delete] = true
		end
		for _, idx in ipairs(update_by_dst[best_di] or {}) do
			drop[idx] = true
		end

		table.insert(appended, {
			type = "update",
			src = src_range,
			dst = dst_range,
			src_node = si.node,
			dst_node = di.node,
			metadata = {
				node_type = "pair",
				old_name = node_label(si, src_buf),
				new_name = dst_text,
				from_line = src_range.start_row + 1,
				to_line = dst_range.start_row + 1,
			},
		})
		used_dst[best_di] = true

		::continue_src::
	end

	if next(drop) == nil and #appended == 0 then
		return actions
	end

	local filtered = {}
	for idx, action in ipairs(actions or {}) do
		if not drop[idx] then
			table.insert(filtered, action)
		end
	end
	for _, action in ipairs(appended) do
		table.insert(filtered, action)
	end
	return filtered
end

local function build_children_index(info)
	local out = {}
	for id, entry in pairs(info or {}) do
		local pid = entry.parent_id
		if pid then
			out[pid] = out[pid] or {}
			table.insert(out[pid], id)
		end
	end
	return out
end

local function descendants_fully_mapped(root_id, info, peer_map, children_by_parent)
	local children = children_by_parent[root_id]
	if not children or #children == 0 then
		return false
	end

	local stack = {}
	for _, cid in ipairs(children) do
		table.insert(stack, cid)
	end

	local named_count = 0
	local named_mapped = 0
	while #stack > 0 do
		local id = table.remove(stack)
		local entry = info[id]
		if entry and entry.node and entry.node:named() then
			named_count = named_count + 1
			if peer_map[id] then
				named_mapped = named_mapped + 1
			end
		end
		for _, cid in ipairs(children_by_parent[id] or {}) do
			table.insert(stack, cid)
		end
	end

	return named_count > 0 and named_mapped == named_count and named_mapped > 0
end

local function collapse_redundant_field_wrappers(actions, src_info, dst_info, s2d, d2s)
	local function is_wrapper_type(type_)
		return type_ == "field" or type_ == "field_declaration" or type_ == "if_statement"
	end

	local src_children = build_children_index(src_info)
	local dst_children = build_children_index(dst_info)
	local drop = {}

	for i, action in ipairs(actions) do
		if action.type == "insert" and action.dst_node then
			local did = action.dst_node:id()
			local di = dst_info[did]
			if di and is_wrapper_type(di.type) and descendants_fully_mapped(did, dst_info, d2s, dst_children) then
				drop[i] = true
			end
		elseif action.type == "delete" and action.src_node then
			local sid = action.src_node:id()
			local si = src_info[sid]
			if si and is_wrapper_type(si.type) and descendants_fully_mapped(sid, src_info, s2d, src_children) then
				drop[i] = true
			end
		end
	end

	if next(drop) == nil then
		return actions
	end

	local filtered = {}
	for i, action in ipairs(actions) do
		if not drop[i] then
			table.insert(filtered, action)
		end
	end
	return filtered
end

local LEAF_EDIT_TYPES = {
	identifier = true,
	field_identifier = true,
	property_identifier = true,
	type_identifier = true,
	namespace_identifier = true,
	number_literal = true,
	string_literal = true,
	char_literal = true,
}

local function suppress_fragmented_updates(actions)
	local delete_regions = {}
	local insert_regions = {}

	for _, action in ipairs(actions or {}) do
		local meta = action.metadata or {}
		local node_type = meta.node_type
		if action.type == "delete" and action.src and not LEAF_EDIT_TYPES[node_type] then
			table.insert(delete_regions, action.src)
		elseif action.type == "insert" and action.dst and not LEAF_EDIT_TYPES[node_type] then
			table.insert(insert_regions, action.dst)
		end
	end

	if #delete_regions == 0 or #insert_regions == 0 then
		return actions
	end

	local filtered = {}
	for _, action in ipairs(actions) do
		if action.type == "update" and action.src and action.dst then
			local in_delete = false
			for _, region in ipairs(delete_regions) do
				if range_contains(region, action.src) then
					in_delete = true
					break
				end
			end

			local in_insert = false
			for _, region in ipairs(insert_regions) do
				if range_contains(region, action.dst) then
					in_insert = true
					break
				end
			end

			if in_delete or in_insert then
				goto continue_action
			end
		end

		table.insert(filtered, action)
		::continue_action::
	end

	return filtered
end

local function suppress_nested_leaf_edits(actions)
	local delete_regions = {}
	local insert_regions = {}

	for _, action in ipairs(actions or {}) do
		local meta = action.metadata or {}
		local node_type = meta.node_type
		if action.type == "delete" and action.src and not LEAF_EDIT_TYPES[node_type] then
			table.insert(delete_regions, action.src)
		elseif action.type == "insert" and action.dst and not LEAF_EDIT_TYPES[node_type] then
			table.insert(insert_regions, action.dst)
		end
	end

	if #delete_regions == 0 and #insert_regions == 0 then
		return actions
	end

	local filtered = {}
	for _, action in ipairs(actions or {}) do
		local drop = false
		local meta = action.metadata or {}
		local node_type = meta.node_type
		if LEAF_EDIT_TYPES[node_type] then
			if action.type == "delete" and action.src then
				for _, region in ipairs(delete_regions) do
					if range_contains(region, action.src) then
						drop = true
						break
					end
				end
			elseif action.type == "insert" and action.dst then
				for _, region in ipairs(insert_regions) do
					if range_contains(region, action.dst) then
						drop = true
						break
					end
				end
			end
		end

		if not drop then
			table.insert(filtered, action)
		end
	end

	return filtered
end

local function is_control_condition_expr(id, info)
	local entry = info and info[id] or nil
	if not entry or entry.type ~= "binary_expression" then
		return false
	end
	local pid = entry.parent_id
	local p = pid and info[pid] or nil
	if not p then
		return false
	end
	if p.type == "condition_clause" then
		return true
	end
	if p.type == "for_statement" or p.type == "while_statement" then
		return true
	end
	return false
end

local function add_control_condition_updates(actions, mappings, src_info, dst_info, src_buf, dst_buf)
	local seen_src = {}
	for _, action in ipairs(actions or {}) do
		if action.type == "update" and action.src_node then
			seen_src[action.src_node:id()] = true
		end
	end

	for _, m in ipairs(mappings or {}) do
		local sid = m.src
		local did = m.dst
		if not seen_src[sid] then
			local si = src_info[sid]
			local di = dst_info[did]
			if si and di and si.type == di.type and is_control_condition_expr(sid, src_info) and is_control_condition_expr(did, dst_info) then
				local src_text = node_text(si.node, src_buf)
				local dst_text = node_text(di.node, dst_buf)
				if src_text ~= "" and dst_text ~= "" and src_text ~= dst_text then
					local src_range = node_range(si.node)
					local dst_range = node_range(di.node)
					table.insert(actions, {
						type = "update",
						src = src_range,
						dst = dst_range,
						src_node = si.node,
						dst_node = di.node,
						metadata = {
							node_type = si.type,
							old_name = src_text,
							new_name = dst_text,
							from_line = src_range and (src_range.start_row + 1) or nil,
							to_line = dst_range and (dst_range.start_row + 1) or nil,
							condition_update = true,
						},
					})
					seen_src[sid] = true
				end
			end
		end
	end

	return actions
end

local function suppress_condition_nested_edits(actions)
	local condition_pairs = {}
	for _, action in ipairs(actions or {}) do
		local meta = action.metadata or {}
		if action.type == "update" and meta.condition_update and action.src and action.dst then
			table.insert(condition_pairs, { src = action.src, dst = action.dst, action = action })
		end
	end

	if #condition_pairs == 0 then
		return actions
	end

	local filtered = {}
	for _, action in ipairs(actions) do
		local drop = false
		if action.type == "insert" and action.dst then
			for _, pair in ipairs(condition_pairs) do
				if range_contains(pair.dst, action.dst) then
					drop = true
					break
				end
			end
		elseif action.type == "delete" and action.src then
			for _, pair in ipairs(condition_pairs) do
				if range_contains(pair.src, action.src) then
					drop = true
					break
				end
			end
		elseif action.type == "update" then
			local meta = action.metadata or {}
			if not meta.condition_update and action.src and action.dst then
				for _, pair in ipairs(condition_pairs) do
					if range_contains(pair.src, action.src) or range_contains(pair.dst, action.dst) then
						drop = true
						break
					end
				end
			end
		end

		if not drop then
			table.insert(filtered, action)
		end
	end

	return filtered
end

local function add_assignment_replacements(actions, mappings, src_info, dst_info, src_buf, dst_buf, s2d)
	local function assignment_lr_types(info_entry, info)
		if not info_entry or not info_entry.node then
			return nil, nil
		end
		local named = {}
		for child in info_entry.node:iter_children() do
			local ok_named, is_named = pcall(child.named, child)
			if ok_named and is_named then
				local cinfo = info[child:id()]
				if cinfo then
					table.insert(named, cinfo.type)
				end
			end
		end
		if #named < 2 then
			return nil, nil
		end
		return named[1], named[#named]
	end

	local covered_src = {}
	local covered_dst = {}
	for _, action in ipairs(actions or {}) do
		if action.src_node then
			covered_src[action.src_node:id()] = true
		end
		if action.dst_node then
			covered_dst[action.dst_node:id()] = true
		end
	end

	for _, m in ipairs(mappings or {}) do
		local sid = m.src
		local did = m.dst
		local si = src_info[sid]
		local di = dst_info[did]
		if not si or not di then
			goto continue_mapping
		end
		if si.type ~= "assignment_expression" or di.type ~= "assignment_expression" then
			goto continue_mapping
		end

		local rep_sid, rep_did = sid, did
		local rep_si, rep_di = si, di
		local spid = si.parent_id
		local dpid = di.parent_id
		local sp = spid and src_info[spid] or nil
		local dp = dpid and dst_info[dpid] or nil
		if sp and dp and sp.type == "expression_statement" and dp.type == "expression_statement" and s2d[spid] == dpid then
			rep_sid, rep_did = spid, dpid
			rep_si, rep_di = sp, dp
		end

		if covered_src[rep_sid] or covered_dst[rep_did] then
			goto continue_mapping
		end

		local src_text = node_text(rep_si.node, src_buf)
		local dst_text = node_text(rep_di.node, dst_buf)
		if src_text == "" or dst_text == "" or src_text == dst_text then
			goto continue_mapping
		end

		local src_lhs_type, src_rhs_type = assignment_lr_types(si, src_info)
		local dst_lhs_type, dst_rhs_type = assignment_lr_types(di, dst_info)
		local shape_changed = (src_lhs_type and dst_lhs_type and src_lhs_type ~= dst_lhs_type)
			or (src_rhs_type and dst_rhs_type and src_rhs_type ~= dst_rhs_type)
		if not shape_changed then
			goto continue_mapping
		end

		local src_range = node_range(rep_si.node)
		local dst_range = node_range(rep_di.node)
		if not src_range or not dst_range then
			goto continue_mapping
		end

		table.insert(actions, {
			type = "delete",
			src = src_range,
			dst = nil,
			src_node = rep_si.node,
			dst_node = nil,
			metadata = {
				node_type = rep_si.type,
				old_name = src_text,
				from_line = src_range.start_row + 1,
			},
		})
		table.insert(actions, {
			type = "insert",
			src = nil,
			dst = dst_range,
			src_node = nil,
			dst_node = rep_di.node,
			metadata = {
				node_type = rep_di.type,
				new_name = dst_text,
				to_line = dst_range.start_row + 1,
			},
		})

		covered_src[rep_sid] = true
		covered_dst[rep_did] = true
		::continue_mapping::
	end

	return actions
end


function M.generate_actions(src_root, dst_root, mappings, src_info, dst_info, opts)
	opts = opts or {}
	local src_buf = opts.src_buf
	local dst_buf = opts.dst_buf

	local s2d, d2s = build_maps(mappings)
	local src_root_id = src_root:id()
	local dst_root_id = dst_root:id()

	local actions = {}

	local dst_bfs = bfs_order(dst_root, dst_info)
	for _, did in ipairs(dst_bfs) do
		if d2s[did] then goto cont_ins end
		local di = dst_info[did]
		if not di then goto cont_ins end
		local parent_did = di.parent_id
		local dst_size = di.size or 1
		local size_ok = dst_size > 1 and not LEAF_EDIT_TYPES[di.type]
		if (not parent_did or d2s[parent_did]) and size_ok then
			local emit_info = di
			if di.type == "expression_statement" and di.node then
				local children = {}
				for child in di.node:iter_children() do
					local cinfo = dst_info[child:id()]
					if cinfo then
						table.insert(children, cinfo)
					end
				end
				if #children == 1 and children[1].type == "assignment_expression" and not d2s[children[1].node:id()] then
					emit_info = children[1]
				end
			end
			local range = node_range(emit_info.node)
			table.insert(actions, {
				type     = "insert",
				src      = nil,
				dst      = range,
				src_node = nil,
				dst_node = emit_info.node,
				metadata = {
					node_type = emit_info.type,
					new_name  = node_label(emit_info, dst_buf),
					to_line   = range and (range.start_row + 1) or nil,
				},
			})
		end
		::cont_ins::
	end

	local moved_all = {}   -- all nodes involved in a parent-change move
	for _, m in ipairs(mappings) do
		local sid = m.src
		local did = m.dst
		if sid == src_root_id then goto cont_mu end

		local si = src_info[sid]
		local di = dst_info[did]
		if not si or not di then goto cont_mu end

		local src_label = effective_label(si, src_buf)
		local dst_label = effective_label(di, dst_buf)
		local update_allowed = si.type == di.type
			and not is_update_blocked(si, src_info)
			and is_leaf_info(si)
			and is_leaf_info(di)
				and src_label ~= ""
				and dst_label ~= ""
				and src_label ~= dst_label
				if update_allowed then
					if si.parent_id and not s2d[si.parent_id] then
						update_allowed = allow_unmapped_field_decl_parent(si, di, src_info, dst_info, s2d)
					elseif di.parent_id and not d2s[di.parent_id] then
						update_allowed = allow_unmapped_field_decl_parent(si, di, src_info, dst_info, s2d)
					end
				end
				if update_allowed then
					update_allowed = call_callee_arity_compatible(sid, did, src_info, dst_info)
				end
				if update_allowed then
					local src_fc = nearest_function_container(sid, src_info)
				local dst_fc = nearest_function_container(did, dst_info)
				if (src_fc and not dst_fc) or (dst_fc and not src_fc) then
					update_allowed = false
				elseif src_fc and dst_fc and s2d[src_fc] ~= dst_fc then
					update_allowed = false
				end
			end
			if update_allowed then
				local sp = si.parent_id and src_info[si.parent_id] or nil
				local dp = di.parent_id and dst_info[di.parent_id] or nil
				if (sp and not dp) or (dp and not sp) then
					update_allowed = false
				elseif sp and dp then
					if sp.type ~= dp.type then
						update_allowed = false
					else
						local sgp = sp.parent_id and src_info[sp.parent_id] or nil
						local dgp = dp.parent_id and dst_info[dp.parent_id] or nil
						if (sgp and not dgp) or (dgp and not sgp) then
							update_allowed = false
						elseif sgp and dgp and sgp.type ~= dgp.type then
							update_allowed = false
						end
					end
				end
			end
			if update_allowed then
			local src_range = node_range(si.node)
			local dst_range = node_range(di.node)
			table.insert(actions, {
				type     = "update",
				src      = src_range,
				dst      = dst_range,
				src_node = si.node,
				dst_node = di.node,
				metadata = {
					node_type = si.type,
					old_name  = src_label,
					new_name  = dst_label,
					from_line = src_range and (src_range.start_row + 1) or nil,
				},
			})
		end

		local src_parent = si.parent_id
		local dst_parent = di.parent_id
		if src_parent and dst_parent then
			local src_parent_dst = s2d[src_parent]
			if src_parent_dst ~= dst_parent then
				moved_all[sid] = true
			end
		end

		::cont_mu::
	end

	local root_moved = {}
	for sid in pairs(moved_all) do
		local si = src_info[sid]
		if si and (not si.parent_id or not moved_all[si.parent_id]) then
			if (src_info[sid].size or 0) >= MIN_MOVE_SIZE then
				root_moved[sid] = true
			end
		end
	end

	for sid in pairs(root_moved) do
		local did = s2d[sid]
		local si  = src_info[sid]
		local di  = dst_info[did]
		if si and di then
			if not should_emit_move_type(si.type) then goto cont_mv end
			if si.node and not si.node:named() then goto cont_mv end
			if is_top_level_like(sid, src_info, src_root_id) and is_top_level_like(did, dst_info, dst_root_id) then
				goto cont_mv
			end
			local src_range = node_range(si.node)
			local dst_range = node_range(di.node)
			table.insert(actions, {
				type     = "move",
				src      = src_range,
				dst      = dst_range,
				src_node = si.node,
				dst_node = di.node,
				metadata = {
					node_type = si.type,
					old_name  = node_label(si, src_buf),
					new_name  = node_label(di, dst_buf),
					from_line = src_range and (src_range.start_row + 1) or nil,
					to_line   = dst_range and (dst_range.start_row + 1) or nil,
				},
			})
			::cont_mv::
		end
	end

	local enable_reorder_moves = opts.enable_reorder_moves == true
	if enable_reorder_moves then
		local processed_parent_pairs = {}
		for _, m in ipairs(mappings) do
			local sid = m.src
			local did = m.dst
			local si  = src_info[sid]
			local di  = dst_info[did]
			if not si or not di then goto skip_b end
			if not si.parent_id or not di.parent_id then goto skip_b end
			if not should_emit_move_type(si.type) then goto skip_b end

			local src_pid = si.parent_id
			local dst_pid = di.parent_id
			if s2d[src_pid] ~= dst_pid then goto skip_b end  -- parent changed = handled above

			local key = src_pid .. ":" .. dst_pid
			if processed_parent_pairs[key] then goto skip_b end
			processed_parent_pairs[key] = true

			do
				local src_pos = child_positions(src_pid, src_info)
				local dst_pos = child_positions(dst_pid, dst_info)

				local pairs_by_src_order = {}
				for cid, spos in pairs(src_pos) do
					local dcid = s2d[cid]
					if dcid and dst_pos[dcid] then
						table.insert(pairs_by_src_order, {
							sid   = cid,
							did   = dcid,
							spos  = spos,
							dpos  = dst_pos[dcid],
						})
					end
				end
				table.sort(pairs_by_src_order, function(a, b) return a.spos < b.spos end)

				if #pairs_by_src_order < 2 then goto skip_b end

				local dpos_seq = {}
				for _, p in ipairs(pairs_by_src_order) do
					table.insert(dpos_seq, p.dpos)
				end

				local in_lis = lis_membership(dpos_seq)

				for i, p in ipairs(pairs_by_src_order) do
					if not in_lis[i] then
						local csi = src_info[p.sid]
						local cdi = dst_info[p.did]
						if csi and cdi and csi.node and csi.node:named() then
							local sz = csi.size or 0
							if sz >= MIN_MOVE_SIZE and not root_moved[p.sid] and not moved_all[p.sid] then
								local src_range = node_range(csi.node)
								local dst_range = node_range(cdi.node)
								table.insert(actions, {
									type     = "move",
									src      = src_range,
									dst      = dst_range,
									src_node = csi.node,
									dst_node = cdi.node,
									metadata = {
										node_type = csi.type,
										old_name  = node_label(csi, src_buf),
										new_name  = node_label(cdi, dst_buf),
										from_line = src_range and (src_range.start_row + 1) or nil,
										to_line   = dst_range and (dst_range.start_row + 1) or nil,
									},
								})
							end
						end
					end
				end
			end

			::skip_b::
		end
	end

	local moved_src = {}
	for _, action in ipairs(actions) do
		if action.type == "move" and action.src_node then
			moved_src[action.src_node:id()] = true
		end
	end

	do
		local TOP_LEVEL_MOVE_TYPES = {
			function_definition = true,
			function_declaration = true,
			struct_specifier = true,
			class_specifier = true,
			enum_specifier = true,
			class_declaration = true,
			interface_declaration = true,
			type_declaration = true,
		}

		local parent_groups = {}
		for _, m in ipairs(mappings) do
			local sid, did = m.src, m.dst
			if sid == src_root_id or moved_src[sid] then goto skip_tl end
			local si, di = src_info[sid], dst_info[did]
			if not si or not di then goto skip_tl end
			if not TOP_LEVEL_MOVE_TYPES[si.type] or si.type ~= di.type then goto skip_tl end
			if not is_top_level_like(sid, src_info, src_root_id) then goto skip_tl end
			if not is_top_level_like(did, dst_info, dst_root_id) then goto skip_tl end

			local src_pid = si.parent_id or src_root_id
			local dst_pid = di.parent_id or dst_root_id
			local key = src_pid .. ":" .. dst_pid
			if not parent_groups[key] then
				parent_groups[key] = { src_pid = src_pid, dst_pid = dst_pid, items = {} }
			end
			table.insert(parent_groups[key].items, { sid = sid, did = did })
			::skip_tl::
		end

		for _, group in pairs(parent_groups) do
			local items = group.items
			if #items < 2 then goto next_group end

			local src_pos = child_positions(group.src_pid, src_info)
			local dst_pos = child_positions(group.dst_pid, dst_info)

			table.sort(items, function(a, b)
				return (src_pos[a.sid] or 0) < (src_pos[b.sid] or 0)
			end)

			local dpos_seq = {}
			local disp_seq = {}
			for idx, item in ipairs(items) do
				local sp = src_pos[item.sid] or 0
				local dp = dst_pos[item.did] or 0
				table.insert(dpos_seq, dp)
				table.insert(disp_seq, math.abs(sp - dp))
			end

			local in_lis = lis_membership(dpos_seq, disp_seq)

			for i, item in ipairs(items) do
				if not in_lis[i] then
					local si = src_info[item.sid]
					local di = dst_info[item.did]
					if si and di and si.node and si.node:named() then
						local old_name = node_label(si, src_buf)
						local new_name = node_label(di, dst_buf)
						local has_body = (old_name:find("{", 1, true) and new_name:find("{", 1, true))
							or si.type == "function_declaration"
							or si.type == "function_definition"
						if has_body then
							local src_range = node_range(si.node)
							local dst_range = node_range(di.node)
							if src_range and dst_range then
								table.insert(actions, {
									type = "move",
									src = src_range,
									dst = dst_range,
									src_node = si.node,
									dst_node = di.node,
									metadata = {
										node_type = si.type,
										old_name = old_name,
										new_name = new_name,
										from_line = src_range.start_row + 1,
										to_line = dst_range.start_row + 1,
									},
								})
								moved_src[item.sid] = true
							end
						end
					end
				end
			end
			::next_group::
		end
	end

	do
		local move_items = {}
		for i, action in ipairs(actions) do
			if action.type == "move" and action.src and action.dst then
				table.insert(move_items, { idx = i, action = action })
			end
		end
		table.sort(move_items, function(a, b)
			local as = range_span(a.action.src)
			local bs = range_span(b.action.src)
			if as ~= bs then
				return as > bs
			end
			return (a.action.src.start_row or 0) < (b.action.src.start_row or 0)
		end)

			local drop = {}
			local kept = {}
			local seen_src = {}
			for _, item in ipairs(move_items) do
				local action = item.action
				local src_id = action.src_node and action.src_node:id() or nil
				local dst_id = action.dst_node and action.dst_node:id() or nil
				if src_id and seen_src[src_id] then
					drop[item.idx] = true
					goto continue_move
				end
				if src_id and dst_id and has_stable_mapped_neighbors(src_id, dst_id, src_info, dst_info, s2d, d2s) then
					drop[item.idx] = true
					goto continue_move
				end
				for _, parent_move in ipairs(kept) do
					if range_contains(parent_move.src, action.src) and range_contains(parent_move.dst, action.dst) then
						drop[item.idx] = true
						goto continue_move
					end
			end
			table.insert(kept, action)
			if src_id then
				seen_src[src_id] = true
			end
			::continue_move::
		end

		if next(drop) ~= nil then
			local filtered = {}
			for i, action in ipairs(actions) do
				if not drop[i] then
					table.insert(filtered, action)
				end
			end
			actions = filtered
		end
	end

	local src_post = post_order(src_root, src_info)
	for _, sid in ipairs(src_post) do
		if s2d[sid] then goto cont_del end
		local si = src_info[sid]
		if not si then goto cont_del end
		local parent_sid = si.parent_id
		local src_size = si.size or 1
		local size_ok = src_size > 1 and not LEAF_EDIT_TYPES[si.type]
		if (not parent_sid or s2d[parent_sid]) and size_ok then
			local range = node_range(si.node)
			table.insert(actions, {
				type     = "delete",
				src      = range,
				dst      = nil,
				src_node = si.node,
				dst_node = nil,
				metadata = {
					node_type = si.type,
					old_name  = node_label(si, src_buf),
					from_line = range and (range.start_row + 1) or nil,
				},
			})
		end
		::cont_del::
	end

	do
		local filtered = {}
		local seen_update_src = {}
		for _, action in ipairs(actions) do
			local keep = true
			if action.type == "insert" and action.dst_node then
				local did = action.dst_node:id()
				if d2s[did] then
					keep = false
				end
			elseif action.type == "delete" and action.src_node then
				local sid = action.src_node:id()
				if s2d[sid] then
					keep = false
				end
			elseif action.type == "update" and action.src_node and action.dst_node then
				local sid = action.src_node:id()
				local did = action.dst_node:id()
				if s2d[sid] ~= did then
					keep = false
				elseif seen_update_src[sid] then
					keep = false
				else
					seen_update_src[sid] = true
				end
			elseif action.type == "move" and action.src_node and action.dst_node then
				local sid = action.src_node:id()
				local did = action.dst_node:id()
				if s2d[sid] ~= did then
					keep = false
				end
			end

			if keep then
				table.insert(filtered, action)
			end
		end
		actions = filtered
	end

	actions = add_control_condition_updates(actions, mappings, src_info, dst_info, src_buf, dst_buf)
	actions = suppress_condition_nested_edits(actions)
	actions = collapse_shorthand_pair_updates(actions, src_info, dst_info, s2d, src_buf, dst_buf)
	actions = collapse_object_pair_updates(actions, src_info, dst_info, s2d, d2s, src_buf, dst_buf)
	actions = collapse_redundant_field_wrappers(actions, src_info, dst_info, s2d, d2s)
	actions = suppress_fragmented_updates(actions)
	actions = suppress_nested_leaf_edits(actions)
	actions = add_assignment_replacements(actions, mappings, src_info, dst_info, src_buf, dst_buf, s2d)

	return actions
end

return M
