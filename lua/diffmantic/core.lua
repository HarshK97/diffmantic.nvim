local ts_utils = require("diffmantic.treesitter")

local M = {}

-- Top-down matching: match nodes from the top of the tree downwards
-- Matches nodes with the same hash at each height level
function M.top_down_match(src_root, dst_root, src_buf, dst_buf)
	local mappings = {}
	local src_info = ts_utils.preprocess_tree(src_root, src_buf)
	local dst_info = ts_utils.preprocess_tree(dst_root, dst_buf)

	local src_mapped = {}
	local dst_mapped = {}

	-- Group nodes by their height in the tree
	local function get_nodes_by_height(info)
		local by_height = {}
		for _, data in pairs(info) do
			if not by_height[data.height] then
				by_height[data.height] = {}
			end
			table.insert(by_height[data.height], data)
		end
		return by_height
	end
	local src_by_height = get_nodes_by_height(src_info)
	local dst_by_height = get_nodes_by_height(dst_info)

	-- Find the maximum height in both trees
	local max_h = 0
	for h in pairs(src_by_height) do
		if h > max_h then
			max_h = h
		end
	end
	for h in pairs(dst_by_height) do
		if h > max_h then
			max_h = h
		end
	end

	-- For each height, match nodes with the same hash using hash indexing
	for h = max_h, 1, -1 do
		local s_nodes = src_by_height[h] or {}
		local d_nodes = dst_by_height[h] or {}

		local dst_by_hash = {}
		for _, d in ipairs(d_nodes) do
			if not dst_mapped[d.id] then
				if not dst_by_hash[d.hash] then
					dst_by_hash[d.hash] = {}
				end
				table.insert(dst_by_hash[d.hash], d)
			end
		end

		for _, s in ipairs(s_nodes) do
			if not src_mapped[s.id] then
				local candidates = dst_by_hash[s.hash]
				if candidates then
					for i, d in ipairs(candidates) do
						if not dst_mapped[d.id] then
							table.insert(mappings, { src = s.id, dst = d.id })
							src_mapped[s.id] = true
							dst_mapped[d.id] = true
							table.remove(candidates, i)
							break
						end
					end
				end
			end
		end
	end

	return mappings, src_info, dst_info
end

-- Bottom-up matching: match nodes from leaves up, using parent mappings
-- Tries to match nodes with the same type and label, and optionally name
function M.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, src_buf, dst_buf)
	-- Build O(1) lookup tables
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	-- Get the name of a declaration node (function or variable)
	local function get_declaration_name(node, bufnr)
		for child in node:iter_children() do
			if child:type() == "identifier" then
				return vim.treesitter.get_node_text(child, bufnr)
			end
		end

		-- Special case for Lua variable_declaration
		if node:type() == "variable_declaration" then
			for child in node:iter_children() do
				if child:type() == "assignment_statement" then
					for subchild in child:iter_children() do
						if subchild:type() == "variable_list" then
							for id_node in subchild:iter_children() do
								if id_node:type() == "identifier" then
									return vim.treesitter.get_node_text(id_node, bufnr)
								end
							end
						end
					end
				end
			end
		end

		-- Special case for C function_definition
		if node:type() == "function_definition" then
			for child in node:iter_children() do
				if child:type() == "function_declarator" then
					for subchild in child:iter_children() do
						if subchild:type() == "identifier" then
							return vim.treesitter.get_node_text(subchild, bufnr)
						end
					end
				end
			end
		end

		-- Special case for Python expression_statement 
		if node:type() == "expression_statement" then
			for child in node:iter_children() do
				if child:type() == "assignment" then
					for subchild in child:iter_children() do
						if subchild:type() == "identifier" then
							return vim.treesitter.get_node_text(subchild, bufnr)
						end
					end
				end
			end
		end

		return nil
	end

	-- Types that have a name (function, variable)
	local identifier_types = {
		function_declaration = true,
		variable_declaration = true,
		class_definition = true,
		function_definition = true,
		expression_statement = true, 
	}

	-- Try to match unmapped nodes whose parent is mapped
	for id, info in pairs(src_info) do
		if not src_to_dst[id] then
			local parent = info.parent
			local parent_mapped = false
			local dest_parent_id = nil

			if not parent then
				parent_mapped = true
			elseif parent:id() == src_root:id() then
				parent_mapped = true
			else
				local dst_id = src_to_dst[parent:id()]
				if dst_id then
					parent_mapped = true
					dest_parent_id = dst_id
				end
			end

			if parent_mapped then
				local candidates = {}
				if dest_parent_id then
					local d_parent = dst_info[dest_parent_id].node
					for child in d_parent:iter_children() do
						if not dst_to_src[child:id()] then
							table.insert(candidates, child)
						end
					end
				else
					for child in dst_root:iter_children() do
						if not dst_to_src[child:id()] then
							table.insert(candidates, child)
						end
					end
				end

				local src_name = nil
				if identifier_types[info.type] then
					src_name = get_declaration_name(info.node, src_buf)
				end

				for _, cand in ipairs(candidates) do
					local d_info = dst_info[cand:id()]
					if d_info.type == info.type and d_info.label == info.label then
						if src_name then
							local dst_name = get_declaration_name(cand, dst_buf)
							if src_name == dst_name then
								table.insert(mappings, { src = id, dst = cand:id() })
								src_to_dst[id] = cand:id()
								dst_to_src[cand:id()] = id
								break
							end
						else
							table.insert(mappings, { src = id, dst = cand:id() })
							src_to_dst[id] = cand:id()
							dst_to_src[cand:id()] = id
							break
						end
					end
				end
			end
		end
	end

	return mappings
end

-- Recovery matching: tries to match remaining unmapped nodes using LCS and unique type
function M.recovery_match(src_root, dst_root, mappings, src_info, dst_info, src_buf, dst_buf)
	-- Build O(1) lookup tables
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	-- Longest Common Subsequence (LCS) for matching children
	local function lcs(src_list, dst_list, hash_key)
		local m, n = #src_list, #dst_list
		if m == 0 or n == 0 then
			return {}
		end

		local dp = {}
		for i = 0, m do
			dp[i] = {}
			for j = 0, n do
				dp[i][j] = 0
			end
		end

		for i = 1, m do
			for j = 1, n do
				local s, d = src_list[i], dst_list[j]
				if src_info[s:id()][hash_key] == dst_info[d:id()][hash_key] and s:type() == d:type() then
					dp[i][j] = dp[i - 1][j - 1] + 1
				else
					dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
				end
			end
		end

		-- Backtrack to find matches
		local result = {}
		local i, j = m, n
		while i > 0 and j > 0 do
			local s, d = src_list[i], dst_list[j]
			if src_info[s:id()][hash_key] == dst_info[d:id()][hash_key] and s:type() == d:type() then
				table.insert(result, 1, { src = s, dst = d })
				i, j = i - 1, j - 1
			elseif dp[i - 1][j] > dp[i][j - 1] then
				i = i - 1
			else
				j = j - 1
			end
		end
		return result
	end

	-- Helper to add a mapping and update lookup tables
	local function add_mapping(src_id, dst_id)
		table.insert(mappings, { src = src_id, dst = dst_id })
		src_to_dst[src_id] = dst_id
		dst_to_src[dst_id] = src_id
	end

	-- Try to match children using LCS and unique type
	local function simple_recovery(src_node, dst_node)
		local src_children, dst_children = {}, {}
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				table.insert(src_children, child)
			end
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				table.insert(dst_children, child)
			end
		end
		if #src_children == 0 or #dst_children == 0 then
			return
		end

		-- Step 1: match children with same hash (exact match)
		for _, match in ipairs(lcs(src_children, dst_children, "hash")) do
			if not src_to_dst[match.src:id()] and not dst_to_src[match.dst:id()] then
				add_mapping(match.src:id(), match.dst:id())
			end
		end

		-- Step 2: match children with same structure_hash (for updates)
		src_children, dst_children = {}, {}
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				table.insert(src_children, child)
			end
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				table.insert(dst_children, child)
			end
		end
		for _, match in ipairs(lcs(src_children, dst_children, "structure_hash")) do
			if not src_to_dst[match.src:id()] and not dst_to_src[match.dst:id()] then
				add_mapping(match.src:id(), match.dst:id())
			end
		end

		-- Step 3: match children with unique type (type appears only once)
		src_children, dst_children = {}, {}
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				table.insert(src_children, child)
			end
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				table.insert(dst_children, child)
			end
		end

		local src_by_type, dst_by_type = {}, {}
		local src_type_count, dst_type_count = {}, {}
		for _, c in ipairs(src_children) do
			local t = c:type()
			src_type_count[t] = (src_type_count[t] or 0) + 1
			src_by_type[t] = c
		end
		for _, c in ipairs(dst_children) do
			local t = c:type()
			dst_type_count[t] = (dst_type_count[t] or 0) + 1
			dst_by_type[t] = c
		end

		for t, count in pairs(src_type_count) do
			if count == 1 and dst_type_count[t] == 1 then
				local s, d = src_by_type[t], dst_by_type[t]
				if not src_to_dst[s:id()] and not dst_to_src[d:id()] then
					add_mapping(s:id(), d:id())
					simple_recovery(s, d)
				end
			end
		end
	end

	-- Apply recovery to all mapped nodes
	for id, info in pairs(src_info) do
		local dst_id = src_to_dst[id]
		if dst_id then
			simple_recovery(info.node, dst_info[dst_id].node)
		end
	end

	return mappings
end

-- Generate edit actions from node mappings
-- Actions describe what changed: insert, delete, update, move
function M.generate_actions(src_root, dst_root, mappings, src_info, dst_info)
	local actions = {}

	-- Build O(1) lookup tables
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
		if_statement = true,
		return_statement = true,
		expression_statement = true,
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
        preproc_include = true,
        preproc_def = true,
        preproc_function_def = true,
	}

	-- only these top-level constructs should be tracked for moves
	local movable_types = {
		function_declaration = true,
		function_definition = true,
		class_definition = true,
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
				if nodes_with_changes[p_id] and significant_types[p_info.type] then
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
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]

		if nodes_with_changes[m.src] and significant_types[s.type] then
			if not src_has_updated_sig_ancestor[m.src] then
				table.insert(actions, { type = "update", node = s.node, target = d.node })
			end
		end
	end

	-- MOVES: check if parent changed or sibling order changed
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]
		if not movable_types[s.type] then
			goto continue_move
		end
		if not s.parent or not d.parent then
			goto continue_move
		end

		local dst_of_src_parent = src_to_dst[s.parent:id()]
		local is_move = false

		local src_parent_is_root = (s.parent:id() == src_root:id())
		local dst_parent_is_root = (d.parent:id() == dst_root:id())
		
		if src_parent_is_root and dst_parent_is_root then
			is_move = false
		elseif dst_of_src_parent ~= d.parent:id() then
			is_move = true
		end
		
		if not is_move then
			local prev_src_sibling = nil
			for child in s.parent:iter_children() do
				if child:id() == s.node:id() then
					break
				end
				local child_info = src_info[child:id()]
				if src_to_dst[child:id()] and child_info and movable_types[child_info.type] then
					prev_src_sibling = child:id()
				end
			end

			local prev_dst_sibling = nil
			for child in d.parent:iter_children() do
				if child:id() == d.node:id() then
					break
				end
				local child_info = dst_info[child:id()]
				if dst_to_src[child:id()] and child_info and movable_types[child_info.type] then
					prev_dst_sibling = child:id()
				end
			end

			if prev_src_sibling then
				local expected_prev = src_to_dst[prev_src_sibling]
				if prev_dst_sibling ~= expected_prev then
					is_move = true
				end
			elseif prev_dst_sibling then
				is_move = true
			end
		end

		if is_move then
			local src_line = s.node:range()
			local dst_line = d.node:range()
			local line_diff = math.abs(dst_line - src_line)
			if line_diff > 3 then
				table.insert(actions, { type = "move", node = s.node, target = d.node })
			end
		end

		::continue_move::
	end

	-- DELETES: unmapped source nodes
	for id, info in pairs(src_info) do
		if not src_to_dst[id] and significant_types[info.type] then
			if not src_has_unmapped_sig_ancestor[id] then
				table.insert(actions, { type = "delete", node = info.node })
			end
		end
	end

	-- INSERTS: unmapped destination nodes
	for id, info in pairs(dst_info) do
		if not dst_to_src[id] and significant_types[info.type] then
			if not dst_has_unmapped_sig_ancestor[id] then
				table.insert(actions, { type = "insert", node = info.node })
			end
		end
	end

	return actions
end

return M
