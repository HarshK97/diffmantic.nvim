local M = {}
local semantic = require("diffmantic.core.semantic")
local roles = require("diffmantic.core.roles")

local function range_metadata(node)
	if not node then
		return nil
	end
	local sr, sc, er, ec = node:range()
	return {
		start_row = sr,
		start_col = sc,
		end_row = er,
		end_col = ec,
		start_line = sr + 1,
		end_line = er + 1,
	}
end

local function build_action(action_type, src_node, dst_node, extra)
	local src_range = range_metadata(src_node)
	local dst_range = range_metadata(dst_node)

	local action = {
		type = action_type,
		kind = action_type,
		node = src_node or dst_node,
		target = (src_node and dst_node) and dst_node or nil,
		src_node = src_node,
		dst_node = dst_node,
		src_range = src_range,
		dst_range = dst_range,
		lines = {
			from_line = src_range and src_range.start_line or nil,
			to_line = dst_range and dst_range.start_line or nil,
		},
	}

	if extra then
		for key, value in pairs(extra) do
			action[key] = value
		end
	end

	return action
end

local function build_summary(actions_list)
	local summary = {
		counts = {
			move = 0,
			rename = 0,
			update = 0,
			insert = 0,
			delete = 0,
			total = #actions_list,
		},
		moves = {},
		renames = {},
		updates = {},
		inserts = {},
		deletes = {},
	}

	local function action_node_type(action)
		local node = action.src_node or action.dst_node
		return node and node:type() or nil
	end

	for _, action in ipairs(actions_list) do
		local t = action.type
		if summary.counts[t] ~= nil then
			summary.counts[t] = summary.counts[t] + 1
		end

		if t == "move" then
			table.insert(summary.moves, {
				node_type = action_node_type(action),
				from_line = action.lines and action.lines.from_line or nil,
				to_line = action.lines and action.lines.to_line or nil,
				src_range = action.src_range,
				dst_range = action.dst_range,
			})
		elseif t == "rename" then
			table.insert(summary.renames, {
				node_type = action_node_type(action),
				from = action.from,
				to = action.to,
				from_line = action.lines and action.lines.from_line or nil,
				to_line = action.lines and action.lines.to_line or nil,
				src_range = action.src_range,
				dst_range = action.dst_range,
			})
		elseif t == "update" then
			table.insert(summary.updates, {
				node_type = action_node_type(action),
				from_line = action.lines and action.lines.from_line or nil,
				to_line = action.lines and action.lines.to_line or nil,
				src_range = action.src_range,
				dst_range = action.dst_range,
			})
		elseif t == "insert" then
			table.insert(summary.inserts, {
				node_type = action_node_type(action),
				line = action.lines and action.lines.to_line or nil,
				dst_range = action.dst_range,
			})
		elseif t == "delete" then
			table.insert(summary.deletes, {
				node_type = action_node_type(action),
				line = action.lines and action.lines.from_line or nil,
				src_range = action.src_range,
			})
		end
	end

	return summary
end

-- Generate edit actions from node mappings
-- Actions describe what changed: insert, delete, update, move, rename
function M.generate_actions(src_root, dst_root, mappings, src_info, dst_info, opts)
	local actions = {}
	local timings = nil
	local hrtime = nil
	if opts and opts.timings then
		timings = {}
		if vim and vim.loop and vim.loop.hrtime then
			hrtime = vim.loop.hrtime
		end
	end

	local src_role_index = nil
	local dst_role_index = nil

	local function start_timer()
		if not hrtime then
			return nil
		end
		return hrtime()
	end

	local function stop_timer(started_at, key)
		if not timings or not started_at then
			return
		end
		timings[key] = (hrtime() - started_at) / 1e6
	end

	local function enrich_update_actions_with_semantics(actions_list)
		local src_buf = opts and opts.src_buf or nil
		local dst_buf = opts and opts.dst_buf or nil
		if not src_buf or not dst_buf then
			return
		end

		for _, action in ipairs(actions_list) do
			local src_node = action.src_node or action.node
			local dst_node = action.dst_node or action.target
			if action.type == "update" and src_node and dst_node then
				local leaf_changes = semantic.find_leaf_changes(src_node, dst_node, src_buf, dst_buf)
				local rename_pairs = {}
				for _, change in ipairs(leaf_changes) do
					if
						semantic.is_rename_identifier(change.src_node, src_role_index)
						or semantic.is_rename_identifier(change.dst_node, dst_role_index)
					then
						rename_pairs[change.src_text] = change.dst_text
					end
				end

				action.semantic = {
					leaf_changes = leaf_changes,
					rename_pairs = rename_pairs,
				}
			end
		end
	end

	local function emit_rename_actions(actions_list)
		local renames = {}
		local seen = {}

		for _, action in ipairs(actions_list) do
			if action.type == "update" and action.semantic and action.semantic.leaf_changes then
				for _, change in ipairs(action.semantic.leaf_changes) do
					local src_node = change.src_node
					local dst_node = change.dst_node
					if src_node and dst_node and change.src_text ~= change.dst_text then
						local is_rename = semantic.is_rename_identifier(src_node, src_role_index)
							or semantic.is_rename_identifier(dst_node, dst_role_index)
						if is_rename then
							local key = table.concat({
								tostring(src_node:id()),
								tostring(dst_node:id()),
								change.src_text,
								change.dst_text,
							}, ":")

							if not seen[key] then
								seen[key] = true
								table.insert(renames, build_action("rename", src_node, dst_node, {
									from = change.src_text,
									to = change.dst_text,
									context = {
										src_parent_type = action.node and action.node:type() or nil,
										dst_parent_type = action.target and action.target:type() or nil,
									},
								}))
							end
						end
					end
				end
			end
		end

		for _, rename_action in ipairs(renames) do
			table.insert(actions_list, rename_action)
		end
	end

	-- Build O(1) lookup tables
	local precompute_start = start_timer()
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	local roles_start = start_timer()
	local src_buf = opts and opts.src_buf or nil
	local dst_buf = opts and opts.dst_buf or nil
	if src_buf and dst_buf then
		src_role_index = roles.build_index(src_root, src_buf)
		dst_role_index = roles.build_index(dst_root, dst_buf)
	end
	stop_timer(roles_start, "roles")

	local significant_types = {
		function_declaration = true,
		variable_declaration = true,
		function_definition = true,
		class_specifier = true,
		struct_specifier = true,
		enum_specifier = true,
		union_specifier = true,
		namespace_definition = true,
		if_statement = true,
		return_statement = true,
		expression_statement = true,
		assignment = true,
		assignment_statement = true,
		for_statement = true,
		while_statement = true,
		function_call = true,
		-- Python
		class_definition = true,
		import_statement = true,
		import_from_statement = true,
		decorator = true,
		-- C
		declaration = true,
		field_declaration = true,
		preproc_include = true,
		preproc_def = true,
		preproc_function_def = true,
	}

	local transparent_update_ancestors = {
		struct_specifier = true,
		class_specifier = true,
	}

	-- only these top-level constructs should be tracked for moves
	local movable_types = {
		function_declaration = true,
		function_definition = true,
		class_definition = true,
		class_specifier = true,
		struct_specifier = true,
	}

	local function has_kind(node, index, kind)
		return index and roles.has_kind(node, index, kind) or false
	end

	local function is_significant(info, index)
		local node = info.node
		if has_kind(node, index, "function")
			or has_kind(node, index, "class")
			or has_kind(node, index, "variable")
			or has_kind(node, index, "assignment")
			or has_kind(node, index, "import")
			or has_kind(node, index, "return")
			or has_kind(node, index, "preproc")
		then
			return true
		end
		return significant_types[info.type] or false
	end

	local function is_transparent_update_ancestor(info, index)
		if has_kind(info.node, index, "class") then
			return true
		end
		return transparent_update_ancestors[info.type] or false
	end

	local function is_movable(info, index)
		if has_kind(info.node, index, "function") or has_kind(info.node, index, "class") then
			return true
		end
		return movable_types[info.type] or false
	end

	-- Helper: check if node or any descendant has different content
	local function has_content_change(src_node, dst_node)
		local src_info_data = src_info[src_node:id()]
		local dst_info_data = dst_info[dst_node:id()]

		if src_info_data.hash ~= dst_info_data.hash then
			return true
		end

		return false
	end

	local nodes_with_changes = {}
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]
		if has_content_change(s.node, d.node) then
			nodes_with_changes[m.src] = true
		end
	end

	-- Precompute ancestry flags for source nodes (unmapped significant ancestors)
	local src_has_unmapped_sig_ancestor = {}
	for id, info in pairs(src_info) do
		local current = info.parent
		while current do
			local p_id = current:id()
			local p_info = src_info[p_id]
			if p_info then
				if not src_to_dst[p_id] and is_significant(p_info, src_role_index) then
					src_has_unmapped_sig_ancestor[id] = true
					break
				end
				current = p_info.parent
			else
				break
			end
		end
	end

	-- Precompute ancestry flags for destination nodes (unmapped significant ancestors)
	local dst_has_unmapped_sig_ancestor = {}
	for id, info in pairs(dst_info) do
		local current = info.parent
		while current do
			local p_id = current:id()
			local p_info = dst_info[p_id]
			if p_info then
				if not dst_to_src[p_id] and is_significant(p_info, dst_role_index) then
					dst_has_unmapped_sig_ancestor[id] = true
					break
				end
				current = p_info.parent
			else
				break
			end
		end
	end

	-- Precompute ancestry flags for updated significant ancestors
	local src_has_updated_sig_ancestor = {}
	for id, info in pairs(src_info) do
		local current = info.parent
		while current do
			local p_id = current:id()
			local p_info = src_info[p_id]
			if p_info then
				if
					nodes_with_changes[p_id]
					and is_significant(p_info, src_role_index)
					and not is_transparent_update_ancestor(p_info, src_role_index)
				then
					src_has_updated_sig_ancestor[id] = true
					break
				end
				current = p_info.parent
			else
				break
			end
		end
	end

	-- UPDATES: mapped nodes with different content, but only significant types without updated ancestors
	stop_timer(precompute_start, "precompute")
	local updates_start = start_timer()
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]

		if nodes_with_changes[m.src] and is_significant(s, src_role_index) then
			if not src_has_updated_sig_ancestor[m.src] then
				table.insert(actions, build_action("update", s.node, d.node))
			end
		end
	end
	stop_timer(updates_start, "updates")

	-- MOVES: use LCS to find which top-level mapped functions changed relative order
	-- Only functions not in the LCS are considered moved.
	local moves_start = start_timer()
	local movable_pairs = {} 
	for _, m in ipairs(mappings) do
		local s = src_info[m.src]
		if s and is_movable(s, src_role_index) then
			local src_parent_is_root = s.parent and s.parent:id() == src_root:id()
			local d = dst_info[m.dst]
			local dst_parent_is_root = d and d.parent and d.parent:id() == dst_root:id()
			if src_parent_is_root and dst_parent_is_root then
				local src_line = s.node:range()
				local dst_line = d.node:range()
				table.insert(movable_pairs, {
					src_id = m.src,
					dst_id = m.dst,
					src_line = src_line,
					dst_line = dst_line,
				})
			end
		end
	end

	table.sort(movable_pairs, function(a, b)
		return a.src_line < b.src_line
	end)

	-- Get destination line orders and compute LCS
	local dst_order = {}
	for i, pair in ipairs(movable_pairs) do
		dst_order[i] = pair.dst_line
	end

	local function longest_increasing_subsequence(arr)
		local n = #arr
		if n == 0 then
			return {}
		end
		local dp = {}
		local prev = {}
		for i = 1, n do
			dp[i] = 1
			prev[i] = nil
			for j = 1, i - 1 do
				if arr[j] < arr[i] and dp[j] + 1 > dp[i] then
					dp[i] = dp[j] + 1
					prev[i] = j
				end
			end
		end
		local max_len, max_idx = 0, 1
		for i = 1, n do
			if dp[i] > max_len then
				max_len = dp[i]
				max_idx = i
			end
		end
		-- Reconstruct LIS indices
		local lis_indices = {}
		local idx = max_idx
		while idx do
			table.insert(lis_indices, 1, idx)
			idx = prev[idx]
		end
		return lis_indices
	end

	local lis_indices = longest_increasing_subsequence(dst_order)
	local in_lis = {}
	for _, i in ipairs(lis_indices) do
		in_lis[i] = true
	end

	-- Mark nodes NOT in LIS as moved (only if line difference is significant)
	for i, pair in ipairs(movable_pairs) do
		if not in_lis[i] then
			local line_diff = math.abs(pair.dst_line - pair.src_line)
			if line_diff > 3 then
				local s = src_info[pair.src_id]
				local d = dst_info[pair.dst_id]
				if s and d then
					table.insert(actions, build_action("move", s.node, d.node))
				end
			end
		end
	end
	stop_timer(moves_start, "moves")

	-- DELETES: unmapped source nodes
	local deletes_start = start_timer()
	for id, info in pairs(src_info) do
		if not src_to_dst[id] and is_significant(info, src_role_index) then
			if not src_has_unmapped_sig_ancestor[id] then
				table.insert(actions, build_action("delete", info.node, nil))
			end
		end
	end
	stop_timer(deletes_start, "deletes")

	-- INSERTS: unmapped destination nodes
	local inserts_start = start_timer()
	for id, info in pairs(dst_info) do
		if not dst_to_src[id] and is_significant(info, dst_role_index) then
			if not dst_has_unmapped_sig_ancestor[id] then
				table.insert(actions, build_action("insert", nil, info.node))
			end
		end
	end
	stop_timer(inserts_start, "inserts")

	local semantic_start = start_timer()
	enrich_update_actions_with_semantics(actions)
	stop_timer(semantic_start, "semantic")

	local rename_start = start_timer()
	emit_rename_actions(actions)
	stop_timer(rename_start, "renames")

	local summary_start = start_timer()
	local summary = build_summary(actions)
	stop_timer(summary_start, "summary")

	return actions, timings, summary
end

return M
