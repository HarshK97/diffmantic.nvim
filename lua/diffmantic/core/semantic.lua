local M = {}
local roles = require("diffmantic.core.roles")

-- Leaf-level diffs for small updates; otherwise return empty.
function M.find_leaf_changes(src_node, dst_node, src_buf, dst_buf)
	local changes = {}

	local function get_all_leaves(node, bufnr)
		local leaves = {}
		local function traverse(n)
			if n:child_count() == 0 then
				table.insert(leaves, {
					node = n,
					text = vim.treesitter.get_node_text(n, bufnr),
					type = n:type(),
				})
			else
				for child in n:iter_children() do
					traverse(child)
				end
			end
		end
		traverse(node)
		return leaves
	end

	local src_leaves = get_all_leaves(src_node, src_buf)
	local dst_leaves = get_all_leaves(dst_node, dst_buf)

	if #src_leaves ~= #dst_leaves then
		return {}
	end

	if math.abs(#src_leaves - #dst_leaves) > 2 then
		return {}
	end

	local min_len = math.min(#src_leaves, #dst_leaves)
	local max_len = math.max(#src_leaves, #dst_leaves)
	local same_count = 0

	for i = 1, min_len do
		local sl, dl = src_leaves[i], dst_leaves[i]
		if sl.type == dl.type and sl.text == dl.text then
			same_count = same_count + 1
		elseif sl.type == dl.type and sl.text ~= dl.text then
			table.insert(changes, {
				src_node = sl.node,
				dst_node = dl.node,
				src_text = sl.text,
				dst_text = dl.text,
			})
		end
	end

	local similarity = same_count / max_len

	if similarity < 0.5 then
		return {}
	end

	if #changes > 5 then
		return {}
	end

	return changes
end

function M.node_in_field(parent, field_name, node)
	local nodes = parent:field(field_name)
	if not nodes then
		return false
	end
	for _, field_node in ipairs(nodes) do
		if field_node:equal(node) or field_node:child_with_descendant(node) then
			return true
		end
	end
	return false
end

function M.is_rename_identifier(node, role_index)
	if not node then
		return false
	end

	if role_index and roles.has_kind(node, role_index, "rename_identifier") then
		return true
	end

	local node_type = node:type()
	if node_type ~= "identifier" and node_type ~= "type_identifier" and node_type ~= "field_identifier" then
		return false
	end

	local parent = node:parent()
	if not parent then
		return false
	end

	local parent_type = parent:type()
	if parent_type == "parameters" or parent_type == "parameter_list" or parent_type == "formal_parameters" then
		return true
	end

	if parent_type == "assignment" and M.node_in_field(parent, "left", node) then
		return true
	end

	if parent_type == "assignment_statement" and M.node_in_field(parent, "variable", node) then
		return true
	end
	if parent_type == "variable_list" then
		return true
	end

	-- Language-specific name heuristics.
	local current = node
	while parent do
		local ptype = parent:type()
		if (ptype == "function_declaration" or ptype == "function_definition" or ptype == "class_definition" or ptype == "class_declaration")
			and M.node_in_field(parent, "name", current)
		then
			return true
		end
		if (ptype == "class_specifier" or ptype == "struct_specifier" or ptype == "enum_specifier" or ptype == "union_specifier")
			and (M.node_in_field(parent, "name", current) or M.node_in_field(parent, "tag", current))
		then
			return true
		end
		if ptype == "function_declarator" then
			return true
		end
		if ptype == "init_declarator" and M.node_in_field(parent, "declarator", current) then
			return true
		end
		if ptype == "field_declaration" and M.node_in_field(parent, "declarator", current) then
			return true
		end
		if ptype == "declarator" then
			return true
		end
		if ptype == "field" then
			return true
		end
		current = parent
		parent = parent:parent()
	end

	return false
end

function M.is_value_node(node, text)
	local node_type = node and node:type() or ""
	if node_type:find("string") or node_type:find("number") or node_type:find("integer") or node_type:find("float") or node_type:find("boolean") then
		return true
	end
	if node_type == "char_literal" or node_type:find("char") and node_type:find("literal") then
		return true
	end
	if text then
		if text:match("^%s*['\"].*['\"]%s*$") then
			return true
		end
		if text:match("^%s*[%d%.]+%s*$") then
			return true
		end
		if text == "true" or text == "false" or text == "nil" then
			return true
		end
	end
	return false
end

local function expand_word_fragment(text, start_idx, end_idx)
	local s = start_idx
	local e = end_idx
	while s > 1 and text:sub(s - 1, s - 1):match("[%w_]") do
		s = s - 1
	end
	while e <= #text and text:sub(e, e):match("[%w_]") do
		e = e + 1
	end
	return s, e - 1
end

local function expand_assignment_suffix(text, end_idx)
	local i = end_idx + 1
	while i <= #text and text:sub(i, i):match("%s") do
		i = i + 1
	end
	if i <= #text and text:sub(i, i) == "=" then
		local j = i + 1
		while j <= #text and text:sub(j, j):match("%s") do
			j = j + 1
		end
		return j - 1
	end
	return end_idx
end

function M.classify_text_change(old_text, new_text)
	if old_text == new_text then
		return nil
	end

	local max_prefix = math.min(#old_text, #new_text)
	local prefix = 0
	while prefix < max_prefix and old_text:sub(prefix + 1, prefix + 1) == new_text:sub(prefix + 1, prefix + 1) do
		prefix = prefix + 1
	end

	local max_suffix = math.min(#old_text - prefix, #new_text - prefix)
	local suffix = 0
	while suffix < max_suffix do
		local o = old_text:sub(#old_text - suffix, #old_text - suffix)
		local n = new_text:sub(#new_text - suffix, #new_text - suffix)
		if o ~= n then
			break
		end
		suffix = suffix + 1
	end

	local old_start = prefix + 1
	local old_end = #old_text - suffix
	local new_start = prefix + 1
	local new_end = #new_text - suffix

	local has_old = old_start <= old_end
	local has_new = new_start <= new_end
	if not has_old and not has_new then
		return nil
	end

	if has_old then
		old_start, old_end = expand_word_fragment(old_text, old_start, old_end)
		old_end = expand_assignment_suffix(old_text, old_end)
	end
	if has_new then
		new_start, new_end = expand_word_fragment(new_text, new_start, new_end)
		new_end = expand_assignment_suffix(new_text, new_end)
	end

	local kind = "replace"
	if has_new and not has_old then
		kind = "insert"
	elseif has_old and not has_new then
		kind = "delete"
	end

	return {
		kind = kind,
		old_start = old_start,
		old_end = old_end,
		new_start = new_start,
		new_end = new_end,
		old_fragment = has_old and old_text:sub(old_start, old_end) or "",
		new_fragment = has_new and new_text:sub(new_start, new_end) or "",
	}
end

function M.diff_fragment(old_text, new_text)
	local change = M.classify_text_change(old_text, new_text)
	if not change or change.kind ~= "replace" then
		return nil
	end
	return {
		old_start = change.old_start,
		old_end = change.old_end,
		new_start = change.new_start,
		new_end = change.new_end,
		old_fragment = change.old_fragment,
		new_fragment = change.new_fragment,
	}
end

return M
