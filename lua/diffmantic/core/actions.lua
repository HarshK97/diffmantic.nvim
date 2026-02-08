local M = {}
local semantic = require("diffmantic.core.semantic")

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
			if action.type == "update" and action.node and action.target then
				local leaf_changes = semantic.find_leaf_changes(action.node, action.target, src_buf, dst_buf)
				local rename_pairs = {}
				for _, change in ipairs(leaf_changes) do
					if semantic.is_rename_identifier(change.src_node) or semantic.is_rename_identifier(change.dst_node) then
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
						local is_rename = semantic.is_rename_identifier(src_node) or semantic.is_rename_identifier(dst_node)
						if is_rename then
							local key = table.concat({
								tostring(src_node:id()),
								tostring(dst_node:id()),
								change.src_text,
								change.dst_text,
							}, ":")

							if not seen[key] then
								seen[key] = true
								table.insert(renames, {
									type = "rename",
									node = src_node,
									target = dst_node,
									from = change.src_text,
									to = change.dst_text,
									src_range = range_metadata(src_node),
									dst_range = range_metadata(dst_node),
									context = {
										src_parent_type = action.node and action.node:type() or nil,
										dst_parent_type = action.target and action.target:type() or nil,
									},
								})
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
				if not src_to_dst[p_id] and significant_types[p_info.type] then
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
				if not dst_to_src[p_id] and significant_types[p_info.type] then
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
				if nodes_with_changes[p_id]
					and significant_types[p_info.type]
					and not transparent_update_ancestors[p_info.type]
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

		if nodes_with_changes[m.src] and significant_types[s.type] then
			if not src_has_updated_sig_ancestor[m.src] then
				table.insert(actions, { type = "update", node = s.node, target = d.node })
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
		if s and movable_types[s.type] then
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
					table.insert(actions, { type = "move", node = s.node, target = d.node })
				end
			end
		end
	end
	stop_timer(moves_start, "moves")

	-- DELETES: unmapped source nodes
	local deletes_start = start_timer()
	for id, info in pairs(src_info) do
		if not src_to_dst[id] and significant_types[info.type] then
			if not src_has_unmapped_sig_ancestor[id] then
				table.insert(actions, { type = "delete", node = info.node })
			end
		end
	end
	stop_timer(deletes_start, "deletes")

	-- INSERTS: unmapped destination nodes
	local inserts_start = start_timer()
	for id, info in pairs(dst_info) do
		if not dst_to_src[id] and significant_types[info.type] then
			if not dst_has_unmapped_sig_ancestor[id] then
				table.insert(actions, { type = "insert", node = info.node })
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

	return actions, timings
end

return M
