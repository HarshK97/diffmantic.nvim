local M = {}
local roles = require("diffmantic.core.roles")

-- Bottom-up matching: match nodes from leaves up, using parent mappings
-- Tries to match nodes with the same type and label, and optionally name
function M.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, src_buf, dst_buf)
	local src_role_index = roles.build_index(src_root, src_buf)
	local dst_role_index = roles.build_index(dst_root, dst_buf)

	-- Build O(1) lookup tables
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	-- Get the name of a declaration node (function or variable)
	local function get_declaration_name(node, bufnr, role_index)
		local function_name = roles.get_kind_name_text(node, role_index, bufnr, "function")
		if function_name and #function_name > 0 then
			return function_name
		end

		local class_name = roles.get_kind_name_text(node, role_index, bufnr, "class")
		if class_name and #class_name > 0 then
			return class_name
		end

		local variable_name = roles.get_kind_name_text(node, role_index, bufnr, "variable")
		if variable_name and #variable_name > 0 then
			return variable_name
		end

		if node:type() == "class_specifier" or node:type() == "struct_specifier" or node:type() == "enum_specifier" or node:type() == "union_specifier" then
			local name_node = node:field("name")[1] or node:field("tag")[1]
			if name_node then
				return vim.treesitter.get_node_text(name_node, bufnr)
			end
		end

		if node:type() == "function_declaration" then
			local function lua_name_from_node(name_node)
				if not name_node then
					return nil
				end
				local ntype = name_node:type()
				if ntype == "identifier" then
					return vim.treesitter.get_node_text(name_node, bufnr)
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
				return vim.treesitter.get_node_text(name_node, bufnr)
			end

			local name_nodes = node:field("name")
			if name_nodes and name_nodes[1] then
				local full_name = lua_name_from_node(name_nodes[1])
				if full_name and #full_name > 0 then
					return full_name
				end
			end
		end

		for child in node:iter_children() do
			if child:type() == "identifier" then
				return vim.treesitter.get_node_text(child, bufnr)
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

		-- C/C++ declaration (variables)
		if node:type() == "declaration" then
			for child in node:iter_children() do
				if child:type() == "init_declarator" then
					local decl = child:field("declarator")[1]
					if decl then
						for subchild in decl:iter_children() do
							if subchild:type() == "identifier" or subchild:type() == "field_identifier" then
								return vim.treesitter.get_node_text(subchild, bufnr)
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
						return vim.treesitter.get_node_text(subchild, bufnr)
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

	-- Try to extract a stable "value hash" for assignments to disambiguate renames.
	local function get_assignment_value_hash(node, info)
		if not node then
			return nil
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
						return info[right:id()].hash
					end
				end
			end
		end
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
		if roles.has_kind(info.node, role_index, "function")
			or roles.has_kind(info.node, role_index, "class")
			or roles.has_kind(info.node, role_index, "variable")
			or roles.has_kind(info.node, role_index, "assignment")
		then
			return true
		end
		return identifier_types[info.type] or false
	end

	local function is_unique_structure_fallback_type(info, role_index)
		if roles.has_kind(info.node, role_index, "function") or roles.has_kind(info.node, role_index, "class") then
			return true
		end
		return unique_structure_fallback_types[info.type] or false
	end

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
				if is_identifier_type(info, src_role_index) then
					src_name = get_declaration_name(info.node, src_buf, src_role_index)
				end
				local src_value_hash = get_assignment_value_hash(info.node, src_info)

				local rename_candidate = nil
				local structure_candidates = {}
				local rename_score = -1
				local rename_tie = false
				for _, cand in ipairs(candidates) do
					local d_info = dst_info[cand:id()]
					if d_info.type == info.type and d_info.label == info.label then
						if src_name then
							local dst_name = get_declaration_name(cand, dst_buf, dst_role_index)
							if src_name == dst_name then
								table.insert(mappings, { src = id, dst = cand:id() })
								src_to_dst[id] = cand:id()
								dst_to_src[cand:id()] = id
								rename_candidate = nil
								break
							elseif dst_name and src_info[id].structure_hash == d_info.structure_hash then
								local dst_value_hash = get_assignment_value_hash(cand, dst_info)
								if src_value_hash and dst_value_hash and src_value_hash ~= dst_value_hash then
									goto continue_candidate
								end
								table.insert(structure_candidates, cand:id())
								local score = name_similarity(src_name, dst_name)
								if score < 0.8 then
									goto continue_candidate
								end
								if score > rename_score then
									rename_candidate = cand:id()
									rename_score = score
									rename_tie = false
								elseif score == rename_score and score > 0 then
									rename_tie = true
								end
							end
						else
							table.insert(mappings, { src = id, dst = cand:id() })
							src_to_dst[id] = cand:id()
							dst_to_src[cand:id()] = id
							rename_candidate = nil
							break
						end
					end
					::continue_candidate::
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
