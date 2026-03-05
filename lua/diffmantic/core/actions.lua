
local M = {}

local MIN_MOVE_SIZE = 3

local FIELD_ID_BLOCKED_PARENTS = {
	field_declaration = true,
}
local function is_update_blocked(si, info)
	if si.type ~= "field_identifier" then return false end
	if si.parent_id then
		local pi = info[si.parent_id]
		if pi and FIELD_ID_BLOCKED_PARENTS[pi.type] then
			return true
		end
	end
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

local function lis_membership(seq)
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
			in_lis[i] = true
			prev_val = seq[i]
			cur = cur - 1
		end
	end
	return in_lis
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
		if (not parent_did or d2s[parent_did]) and dst_size > 1 then
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
					from_line = range and (range.start_row + 1) or nil,
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
					update_allowed = false
				elseif di.parent_id and not d2s[di.parent_id] then
					update_allowed = false
				end
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
	local TOP_LEVEL_MOVE_TYPES = {
		function_definition = true,
		function_declaration = true,  -- Lua uses this for `local function`
		struct_specifier = true,
		class_specifier = true,
		enum_specifier = true,
		class_declaration = true,
		interface_declaration = true,
		type_declaration = true,
	}
	for _, m in ipairs(mappings) do
		local sid = m.src
		local did = m.dst
		if sid ~= src_root_id and not moved_src[sid] then
			local si = src_info[sid]
			local di = dst_info[did]
			if si and di and TOP_LEVEL_MOVE_TYPES[si.type] and si.type == di.type then
				local src_top = is_top_level_like(sid, src_info, src_root_id)
				local dst_top = is_top_level_like(did, dst_info, dst_root_id)
				local old_name = node_label(si, src_buf)
				local new_name = node_label(di, dst_buf)
				if src_top and dst_top then
					local has_body = (old_name:find("{", 1, true) and new_name:find("{", 1, true))
						or si.type == "function_declaration"   -- Lua
						or si.type == "function_definition"    -- Python (also C/Go/JS but { already matches)
					if has_body then
						local src_range = node_range(si.node)
						local dst_range = node_range(di.node)
						if src_range and dst_range and src_range.start_row ~= dst_range.start_row then
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
							moved_src[sid] = true
						end
					end
				end
			end
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
		local size_ok = src_size > 1 or si.type == "shorthand_property_identifier"
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

	return actions
end

return M
