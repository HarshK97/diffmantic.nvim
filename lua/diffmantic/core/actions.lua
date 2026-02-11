local M = {}
local semantic = require("diffmantic.core.semantic")
local roles = require("diffmantic.core.roles")
local payload = require("diffmantic.core.payload")

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
			rename_suppressed = 0,
			update = 0,
			insert = 0,
			delete = 0,
			total = #actions_list,
		},
		moves = {},
		renames = {},
		suppressed_renames = {},
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
			local suppressed_usages = action.context and action.context.suppressed_usages or {}
			local suppressed_count = #suppressed_usages
			summary.counts.rename_suppressed = summary.counts.rename_suppressed + suppressed_count

			table.insert(summary.renames, {
				node_type = action_node_type(action),
				from = action.from,
				to = action.to,
				from_line = action.lines and action.lines.from_line or nil,
				to_line = action.lines and action.lines.to_line or nil,
				src_range = action.src_range,
				dst_range = action.dst_range,
				suppressed_usage_count = suppressed_count,
			})

			for _, usage in ipairs(suppressed_usages) do
				table.insert(summary.suppressed_renames, {
					from = usage.from,
					to = usage.to,
					from_line = usage.lines and usage.lines.from_line or nil,
					to_line = usage.lines and usage.lines.to_line or nil,
					src_range = usage.src_range,
					dst_range = usage.dst_range,
					suppressed_by = {
						from = action.from,
						to = action.to,
						from_line = action.lines and action.lines.from_line or nil,
						to_line = action.lines and action.lines.to_line or nil,
					},
				})
			end
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
		local src_buf = opts and opts.src_buf or nil
		local dst_buf = opts and opts.dst_buf or nil
		local is_buf_available = src_buf and dst_buf

		local function pair_key(from_text, to_text)
			return tostring(from_text) .. "\x1f" .. tostring(to_text)
		end

		local function push_rename(src_node, dst_node, from_text, to_text, context)
			if not src_node or not dst_node or not from_text or not to_text then
				return
			end
			if from_text == to_text then
				return
			end
			local key = table.concat({
				tostring(src_node:id()),
				tostring(dst_node:id()),
				from_text,
				to_text,
			}, ":")
			if seen[key] then
				return
			end
			seen[key] = true
			table.insert(renames, build_action("rename", src_node, dst_node, {
				from = from_text,
				to = to_text,
				context = context,
			}))
		end

		local function is_decl_rename(src_node, dst_node)
			return semantic.is_rename_identifier(src_node, src_role_index)
				and semantic.is_rename_identifier(dst_node, dst_role_index)
		end

		local seed_pairs = {}
		local function add_seed(from_text, to_text)
			if from_text and to_text and from_text ~= to_text then
				seed_pairs[pair_key(from_text, to_text)] = true
			end
		end

		local function collect_param_identifiers(node, bufnr)
			if not node or not bufnr then
				return {}
			end

			local parameter_kinds = {
				parameters = true,
				parameter_list = true,
				formal_parameters = true,
			}

			local function find_parameter_node(n)
				if parameter_kinds[n:type()] then
					return n
				end
				for child in n:iter_children() do
					local found = find_parameter_node(child)
					if found then
						return found
					end
				end
				return nil
			end

			local params_root = find_parameter_node(node)
			if not params_root then
				return {}
			end

			local out = {}
			local function walk(n)
				if n:child_count() == 0 then
					local t = n:type()
					if t == "identifier" or t == "type_identifier" or t == "field_identifier" or t == "property_identifier" then
						local text = vim.treesitter.get_node_text(n, bufnr)
						if text and text:match("^[%a_][%w_]*$") then
							table.insert(out, { node = n, text = text })
						end
					end
					return
				end
				for child in n:iter_children() do
					walk(child)
				end
			end

			walk(params_root)
			return out
		end

		-- Pass 1a: high-confidence declaration-like rename seeds from semantic leaf changes.
		for _, action in ipairs(actions_list) do
			if action.type == "update" and action.semantic and action.semantic.leaf_changes then
				for _, change in ipairs(action.semantic.leaf_changes) do
					local src_node = change.src_node
					local dst_node = change.dst_node
					if src_node and dst_node and change.src_text ~= change.dst_text and is_decl_rename(src_node, dst_node) then
						add_seed(change.src_text, change.dst_text)
					end
				end
			end
		end

		-- Pass 1a.2: positional parameter rename seeds/actions for updated functions.
		if is_buf_available then
			for _, action in ipairs(actions_list) do
				if action.type == "update" and action.src_node and action.dst_node then
					local src_params = collect_param_identifiers(action.src_node, src_buf)
					local dst_params = collect_param_identifiers(action.dst_node, dst_buf)
					if #src_params > 0 and #src_params == #dst_params and #src_params <= 16 then
						for i = 1, #src_params do
							local s = src_params[i]
							local d = dst_params[i]
							if s.text ~= d.text then
								add_seed(s.text, d.text)
								if is_decl_rename(s.node, d.node) then
									push_rename(s.node, d.node, s.text, d.text, {
										src_parent_type = action.node and action.node:type() or nil,
										dst_parent_type = action.target and action.target:type() or nil,
										source = "parameter_positional",
										declaration = true,
									})
								end
							end
						end
					end
				end
			end
		end

		-- Pass 1b: strict fallback seed collection from mapped leaf identifiers.
		if is_buf_available then
			local src_to_dst_local = {}
			for _, m in ipairs(mappings) do
				src_to_dst_local[m.src] = m.dst
			end

			local function child_index(node)
				local parent = node and node:parent() or nil
				if not parent then
					return -1
				end
				local idx = 0
				for child in parent:iter_children() do
					if child:equal(node) then
						return idx
					end
					idx = idx + 1
				end
				return -1
			end

			local function is_identifier_node(node)
				if not node then
					return false
				end
				local t = node:type()
				return t == "identifier" or t == "type_identifier" or t == "field_identifier" or t == "property_identifier"
			end

			local function is_identifier_like(text)
				return text and text:match("^[%a_][%w_]*$") ~= nil
			end

			for _, m in ipairs(mappings) do
				local s = src_info[m.src]
				local d = dst_info[m.dst]
				if s and d and s.node and d.node then
					local src_node = s.node
					local dst_node = d.node
					if src_node:child_count() == 0 and dst_node:child_count() == 0 then
						local src_parent = src_node:parent()
						local dst_parent = dst_node:parent()
						if src_parent and dst_parent and src_to_dst_local[src_parent:id()] == dst_parent:id() then
							if src_parent:type() == dst_parent:type() and child_index(src_node) == child_index(dst_node) then
								local src_text = vim.treesitter.get_node_text(src_node, src_buf)
								local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
								if src_text and dst_text and src_text ~= dst_text then
									if
										is_decl_rename(src_node, dst_node)
										and is_identifier_node(src_node)
										and is_identifier_node(dst_node)
										and is_identifier_like(src_text)
										and is_identifier_like(dst_text)
									then
										add_seed(src_text, dst_text)
									end
								end
							end
						end
					end
				end
			end
		end

		-- Pass 2: emit leaf rename actions gated by seeds (and declaration renames).
		for _, action in ipairs(actions_list) do
			if action.type == "update" and action.semantic and action.semantic.leaf_changes then
				for _, change in ipairs(action.semantic.leaf_changes) do
					local src_node = change.src_node
					local dst_node = change.dst_node
					local src_text = change.src_text
					local dst_text = change.dst_text
					if src_node and dst_node and src_text and dst_text and src_text ~= dst_text then
						local is_decl = is_decl_rename(src_node, dst_node)
						local key = pair_key(src_text, dst_text)
						if seed_pairs[key] or is_decl then
							push_rename(src_node, dst_node, src_text, dst_text, {
								src_parent_type = action.node and action.node:type() or nil,
								dst_parent_type = action.target and action.target:type() or nil,
								declaration = is_decl,
							})
						end
					end
				end
			end
		end

		-- Pass 3: emit strict mapped-leaf rename actions for seed pairs not present in leaf_changes.
		if is_buf_available then
			local src_to_dst_local = {}
			for _, m in ipairs(mappings) do
				src_to_dst_local[m.src] = m.dst
			end

			local function child_index(node)
				local parent = node and node:parent() or nil
				if not parent then
					return -1
				end
				local idx = 0
				for child in parent:iter_children() do
					if child:equal(node) then
						return idx
					end
					idx = idx + 1
				end
				return -1
			end

			local function is_identifier_node(node)
				if not node then
					return false
				end
				local t = node:type()
				return t == "identifier" or t == "type_identifier" or t == "field_identifier" or t == "property_identifier"
			end

			local function is_identifier_like(text)
				return text and text:match("^[%a_][%w_]*$") ~= nil
			end

			for _, m in ipairs(mappings) do
				local s = src_info[m.src]
				local d = dst_info[m.dst]
				if s and d and s.node and d.node then
					local src_node = s.node
					local dst_node = d.node
					if src_node:child_count() == 0 and dst_node:child_count() == 0 then
						local src_parent = src_node:parent()
						local dst_parent = dst_node:parent()
						if src_parent and dst_parent and src_to_dst_local[src_parent:id()] == dst_parent:id() then
							if src_parent:type() == dst_parent:type() and child_index(src_node) == child_index(dst_node) then
								local src_text = vim.treesitter.get_node_text(src_node, src_buf)
								local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
								if src_text and dst_text and src_text ~= dst_text then
									if
										is_decl_rename(src_node, dst_node)
										and is_identifier_node(src_node)
										and is_identifier_node(dst_node)
										and is_identifier_like(src_text)
										and is_identifier_like(dst_text)
									then
										local key = pair_key(src_text, dst_text)
										if seed_pairs[key] then
											push_rename(src_node, dst_node, src_text, dst_text, {
												src_parent_type = src_parent:type(),
												dst_parent_type = dst_parent:type(),
												source = "mapping_seed",
												declaration = true,
											})
										end
									end
								end
							end
						end
					end
				end
			end
		end

		-- If a declaration rename exists for a pair, suppress usage-level duplicates for that pair.
		local declaration_pairs = {}
		for _, rename_action in ipairs(renames) do
			if rename_action.context and rename_action.context.declaration then
				declaration_pairs[pair_key(rename_action.from, rename_action.to)] = true
			end
		end

		local suppressed_by_pair = {}
		local filtered_renames = {}
		for _, rename_action in ipairs(renames) do
			local key = pair_key(rename_action.from, rename_action.to)
			local is_declaration = rename_action.context and rename_action.context.declaration
			if not declaration_pairs[key] or is_declaration then
				table.insert(filtered_renames, rename_action)
			else
				suppressed_by_pair[key] = suppressed_by_pair[key] or {}
				table.insert(suppressed_by_pair[key], {
					from = rename_action.from,
					to = rename_action.to,
					src_range = rename_action.src_range,
					dst_range = rename_action.dst_range,
					lines = rename_action.lines,
					context = rename_action.context,
				})
			end
		end

		for _, rename_action in ipairs(filtered_renames) do
			if rename_action.context and rename_action.context.declaration then
				local key = pair_key(rename_action.from, rename_action.to)
				local suppressed_usages = suppressed_by_pair[key]
				if suppressed_usages and #suppressed_usages > 0 then
					rename_action.context.suppressed_usages = suppressed_usages
					rename_action.context.suppressed_usage_count = #suppressed_usages
				end
			end
		end

		for _, rename_action in ipairs(filtered_renames) do
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

	local render_start = start_timer()
	if src_buf and dst_buf then
		payload.enrich(actions, {
			src_buf = src_buf,
			dst_buf = dst_buf,
		})
	end
	stop_timer(render_start, "payload")

	local summary_start = start_timer()
	local summary = build_summary(actions)
	stop_timer(summary_start, "summary")

	return actions, timings, summary
end

return M
