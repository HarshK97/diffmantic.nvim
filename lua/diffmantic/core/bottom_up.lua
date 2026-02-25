local M = {}
local roles = require("diffmantic.core.roles")

local function node_key(info)
	if info.start_row ~= nil then
		return info.start_row, info.start_col, info.end_row, info.end_col
	end
	local sr, sc, er, ec = info.node:range()
	return sr, sc, er, ec
end

local function compare_info_order(a_info, b_info)
	local asr, asc, aer, aec = node_key(a_info)
	local bsr, bsc, ber, bec = node_key(b_info)
	if asr ~= bsr then
		return asr < bsr
	end
	if asc ~= bsc then
		return asc < bsc
	end
	if aer ~= ber then
		return aer < ber
	end
	if aec ~= bec then
		return aec < bec
	end
	return a_info.type < b_info.type
end

-- Bottom-up matching: match nodes from leaves up, using parent mappings
-- Tries to match nodes with the same type and label, and optionally name
function M.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, src_buf, dst_buf, opts)
	opts = opts or {}
	local src_role_index = opts.src_role_index or roles.build_index(src_root, src_buf)
	local dst_role_index = opts.dst_role_index or roles.build_index(dst_root, dst_buf)
	local src_root_id = src_root:id()

	local node_text_cache = {}
	local function node_text(node, bufnr)
		local key = tostring(bufnr) .. ":" .. tostring(node:id())
		local cached = node_text_cache[key]
		if cached ~= nil then
			return cached
		end
		local text = vim.treesitter.get_node_text(node, bufnr)
		node_text_cache[key] = text
		return text
	end

	-- Build O(1) lookup tables
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	-- Get the name of a declaration node (function or variable)
	local function get_declaration_name(node, bufnr, role_index, name_cache)
		local node_id = node:id()
		local cached = name_cache[node_id]
		if cached ~= nil then
			return cached or nil
		end

		local function cache_and_return(value)
			name_cache[node_id] = value or false
			return value
		end

		local function find_first_identifier(n)
			if not n then
				return nil
			end
			if n:child_count() == 0 then
				local t = n:type()
				if t == "identifier" or t == "field_identifier" or t == "property_identifier" then
					return n
				end
				return nil
			end
			for child in n:iter_children() do
				local found = find_first_identifier(child)
				if found then
					return found
				end
			end
			return nil
		end

		local function_name = roles.get_kind_name_text(node, role_index, bufnr, "function")
		if function_name and #function_name > 0 then
			return cache_and_return(function_name)
		end

		local class_name = roles.get_kind_name_text(node, role_index, bufnr, "class")
		if class_name and #class_name > 0 then
			return cache_and_return(class_name)
		end

		local variable_name = roles.get_kind_name_text(node, role_index, bufnr, "variable")
		if variable_name and #variable_name > 0 then
			return cache_and_return(variable_name)
		end

		if
			node:type() == "class_specifier"
			or node:type() == "struct_specifier"
			or node:type() == "enum_specifier"
			or node:type() == "union_specifier"
		then
			local name_node = node:field("name")[1] or node:field("tag")[1]
			if name_node then
				return cache_and_return(node_text(name_node, bufnr))
			end
		end

		if node:type() == "function_declaration" then
			local function lua_name_from_node(name_node)
				if not name_node then
					return nil
				end
				local ntype = name_node:type()
				if ntype == "identifier" then
					return node_text(name_node, bufnr)
				end
				if ntype == "dot_index_expression" then
					local tbl = name_node:field("table")[1]
					local field = name_node:field("field")[1]
					local left = lua_name_from_node(tbl)
					local right = lua_name_from_node(field)
					if left and right then
						return left .. "." .. right
					end
				end
				if ntype == "method_index_expression" then
					local tbl = name_node:field("table")[1]
					local method = name_node:field("method")[1]
					local left = lua_name_from_node(tbl)
					local right = lua_name_from_node(method)
					if left and right then
						return left .. ":" .. right
					end
				end
				return node_text(name_node, bufnr)
			end

			local name_nodes = node:field("name")
			if name_nodes and name_nodes[1] then
				local full_name = lua_name_from_node(name_nodes[1])
				if full_name and #full_name > 0 then
					return cache_and_return(full_name)
				end
			end
		end

		for child in node:iter_children() do
			if child:type() == "identifier" then
				return cache_and_return(node_text(child, bufnr))
			end
		end

		-- Special case for Lua variable_declaration
		if node:type() == "variable_declaration" or node:type() == "local_variable_declaration" then
			for child in node:iter_children() do
				if child:type() == "assignment_statement" then
					for subchild in child:iter_children() do
						if subchild:type() == "variable_list" then
							for id_node in subchild:iter_children() do
								if id_node:type() == "identifier" then
									return cache_and_return(node_text(id_node, bufnr))
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
					local found = find_first_identifier(child)
					if found then
						return cache_and_return(node_text(found, bufnr))
					end
				end
			end
		end

		-- C/C++ declaration (variables)
		if node:type() == "declaration" then
			for child in node:iter_children() do
				if child:type() == "init_declarator" then
					local decl = child:field("declarator")[1]
					if decl then
						for subchild in decl:iter_children() do
							if subchild:type() == "identifier" or subchild:type() == "field_identifier" then
								return cache_and_return(node_text(subchild, bufnr))
							end
						end
					end
				end
			end
		end

		-- C/C++ field declaration (struct/class fields)
		if node:type() == "field_declaration" then
			local decl = node:field("declarator")[1]
			if decl then
				for subchild in decl:iter_children() do
					if subchild:type() == "identifier" or subchild:type() == "field_identifier" then
						return cache_and_return(node_text(subchild, bufnr))
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
							return cache_and_return(node_text(subchild, bufnr))
						end
					end
				end
			end
		end

		return cache_and_return(nil)
	end

	-- Try to extract a stable "value hash" for assignments to disambiguate renames.
	local function get_assignment_value_hash(node, info, cache)
		if not node then
			return nil
		end
		local node_id = node:id()
		local cached = cache[node_id]
		if cached ~= nil then
			return cached or nil
		end
		-- Python: expression_statement (assignment left: ..., right: ...)
		if node:type() == "expression_statement" then
			for child in node:iter_children() do
				if child:type() == "assignment" then
					local right = child:field("right")[1] or child:field("value")[1]
					if not right then
						local last = nil
						for subchild in child:iter_children() do
							last = subchild
						end
						right = last
					end
					if right and info[right:id()] then
						cache[node_id] = info[right:id()].hash
						return cache[node_id]
					end
				end
			end
		end
		cache[node_id] = false
		return nil
	end

	local function name_similarity(src_name, dst_name)
		if not src_name or not dst_name then
			return 0
		end
		if dst_name:find(src_name, 1, true) then
			return 1
		end
		if src_name:find(dst_name, 1, true) then
			return 1
		end

		local function tokens(name)
			local out = {}
			for part in name:gmatch("[A-Za-z0-9]+") do
				table.insert(out, part:lower())
			end
			return out
		end

		local function token_match(a, b)
			if a == b then
				return true
			end
			if #a >= 3 and #b >= 3 then
				if a:find(b, 1, true) == 1 or b:find(a, 1, true) == 1 then
					return true
				end
			end
			return false
		end

		local src_tokens = tokens(src_name)
		local dst_tokens = tokens(dst_name)
		if #src_tokens == 0 or #dst_tokens == 0 then
			return 0
		end

		local common = 0
		local used_dst = {}
		for _, s in ipairs(src_tokens) do
			for i, d in ipairs(dst_tokens) do
				if not used_dst[i] and token_match(s, d) then
					common = common + 1
					used_dst[i] = true
					break
				end
			end
		end
		return common / math.max(#src_tokens, #dst_tokens)
	end

	-- Types that have a name (function, variable)
	local identifier_types = {
		function_declaration = true,
		variable_declaration = true,
		local_variable_declaration = true,
		class_definition = true,
		class_specifier = true,
		struct_specifier = true,
		enum_specifier = true,
		union_specifier = true,
		function_definition = true,
		declaration = true,
		field_declaration = true,
		expression_statement = true,
	}

	local unique_structure_fallback_types = {
		function_declaration = true,
		function_definition = true,
		class_definition = true,
		class_specifier = true,
		struct_specifier = true,
	}

	local function is_identifier_type(info, role_index)
		if
			roles.has_structural_kind(info.node, role_index, "function")
			or roles.has_structural_kind(info.node, role_index, "class")
			or roles.has_structural_kind(info.node, role_index, "variable")
			or roles.has_structural_kind(info.node, role_index, "assignment")
		then
			return true
		end
		return identifier_types[info.type] or false
	end

	local function is_unique_structure_fallback_type(info, role_index)
		if
			roles.has_structural_kind(info.node, role_index, "function")
			or roles.has_structural_kind(info.node, role_index, "class")
		then
			return true
		end
		return unique_structure_fallback_types[info.type] or false
	end

	local src_ids = {}
	for id in pairs(src_info) do
		table.insert(src_ids, id)
	end
	table.sort(src_ids, function(a, b)
		local ah = src_info[a].height or 0
		local bh = src_info[b].height or 0
		if ah == bh then
			return compare_info_order(src_info[a], src_info[b])
		end
		return ah < bh
	end)

	local src_decl_name_cache = {}
	local dst_decl_name_cache = {}
	local src_value_hash_cache = {}
	local dst_value_hash_cache = {}
	local parent_candidates = {}

	local function candidate_signature(info)
		return info.type .. "\x1f" .. info.label
	end

	local function build_parent_candidates(dest_parent_id)
		local state = { by_sig = {} }
		local function push_child(child)
			local child_id = child:id()
			if dst_to_src[child_id] then
				return
			end
			local d_info = dst_info[child_id]
			if not d_info then
				return
			end
			local sig = candidate_signature(d_info)
			local queue = state.by_sig[sig]
			if not queue then
				queue = { head = 1, items = {} }
				state.by_sig[sig] = queue
			end
			local items = queue.items
			items[#items + 1] = child_id
		end

		if dest_parent_id then
			local d_parent = dst_info[dest_parent_id] and dst_info[dest_parent_id].node or nil
			if d_parent then
				for child in d_parent:iter_children() do
					push_child(child)
				end
			end
		else
			for child in dst_root:iter_children() do
				push_child(child)
			end
		end
		return state
	end

	local function queue_for_parent_sig(dest_parent_id, sig)
		local key = dest_parent_id or 0
		local state = parent_candidates[key]
		if not state then
			state = build_parent_candidates(dest_parent_id)
			parent_candidates[key] = state
		end
		return state.by_sig[sig]
	end

	local function first_unmapped_candidate_id(queue)
		if not queue then
			return nil
		end
		local items = queue.items
		local head = queue.head
		while head <= #items and dst_to_src[items[head]] do
			head = head + 1
		end
		queue.head = head
		return items[head]
	end

	-- Try to match unmapped nodes whose parent is mapped
	for _, id in ipairs(src_ids) do
		local info = src_info[id]
		if not src_to_dst[id] then
			local parent_id = info.parent_id
			local parent_mapped = false
			local dest_parent_id = nil

			if not parent_id then
				parent_mapped = true
			elseif parent_id == src_root_id then
				parent_mapped = true
			else
				local dst_id = src_to_dst[parent_id]
				if dst_id then
					parent_mapped = true
					dest_parent_id = dst_id
				end
			end

			if parent_mapped then
				local queue = queue_for_parent_sig(dest_parent_id, candidate_signature(info))
				local candidates = queue and queue.items or nil

				local src_name = nil
				if is_identifier_type(info, src_role_index) then
					src_name = get_declaration_name(info.node, src_buf, src_role_index, src_decl_name_cache)
				end
				local src_value_hash = get_assignment_value_hash(info.node, src_info, src_value_hash_cache)

				local rename_candidate = nil
				local structure_candidates = {}
				local rename_score = -1
				local rename_tie = false
				if not src_name then
					local candidate_id = first_unmapped_candidate_id(queue)
					if candidate_id then
						table.insert(mappings, { src = id, dst = candidate_id })
						src_to_dst[id] = candidate_id
						dst_to_src[candidate_id] = id
					end
				elseif candidates then
					local start_idx = queue and queue.head or 1
					for i = start_idx, #candidates do
						local candidate_id = candidates[i]
						if not dst_to_src[candidate_id] then
							local cand = dst_info[candidate_id].node
							local d_info = dst_info[candidate_id]
							local dst_name = get_declaration_name(cand, dst_buf, dst_role_index, dst_decl_name_cache)
							if src_name == dst_name then
								table.insert(mappings, { src = id, dst = candidate_id })
								src_to_dst[id] = candidate_id
								dst_to_src[candidate_id] = id
								rename_candidate = nil
								break
							elseif dst_name and src_info[id].structure_hash == d_info.structure_hash then
								local dst_value_hash = get_assignment_value_hash(cand, dst_info, dst_value_hash_cache)
								if src_value_hash and dst_value_hash and src_value_hash ~= dst_value_hash then
									goto continue_candidate
								end
								table.insert(structure_candidates, candidate_id)
								local score = name_similarity(src_name, dst_name)
								if score < 0.8 then
									goto continue_candidate
								end
								if score > rename_score then
									rename_candidate = candidate_id
									rename_score = score
									rename_tie = false
								elseif score == rename_score and score > 0 then
									rename_tie = true
								end
							end
						end
						::continue_candidate::
					end
				end

				if not src_to_dst[id] and rename_candidate and not rename_tie and rename_score > 0 then
					table.insert(mappings, { src = id, dst = rename_candidate })
					src_to_dst[id] = rename_candidate
					dst_to_src[rename_candidate] = id
				elseif not src_to_dst[id] and is_unique_structure_fallback_type(info, src_role_index) then
					if #structure_candidates == 1 then
						local candidate_id = structure_candidates[1]
						table.insert(mappings, { src = id, dst = candidate_id })
						src_to_dst[id] = candidate_id
						dst_to_src[candidate_id] = id
					end
				end
			end
		end
	end

	return mappings
end

return M
