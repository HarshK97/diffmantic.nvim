local M = {}

local CAPTURE_BY_KIND = {
	["function"] = {
		"diff.function.outer",
		"diff.function.name",
		"diff.function.body",
	},
	["class"] = {
		"diff.class.outer",
		"diff.class.name",
		"diff.class.body",
	},
	["variable"] = {
		"diff.variable.outer",
		"diff.variable.name",
	},
	["assignment"] = {
		"diff.assignment.outer",
		"diff.assignment.lhs",
		"diff.assignment.rhs",
	},
	["import"] = { "diff.import.outer" },
	["return"] = { "diff.return.outer" },
	["preproc"] = { "diff.preproc.outer" },
	["rename_identifier"] = { "diff.identifier.rename" },
}

local STRUCTURAL_CAPTURE_BY_KIND = {
	["function"] = { "diff.function.outer" },
	["class"] = { "diff.class.outer" },
	["variable"] = { "diff.variable.outer" },
	["assignment"] = { "diff.assignment.outer" },
	["import"] = { "diff.import.outer" },
	["return"] = { "diff.return.outer" },
	["preproc"] = { "diff.preproc.outer" },
}

local FALLBACK_QUERY = "((_) @diff.fallback.node)"

local function add_capture(index, capture, node)
	local id = node:id()
	index.by_node[id] = index.by_node[id] or {}
	index.by_node[id][capture] = true

	index.by_capture[capture] = index.by_capture[capture] or {}
	index.by_capture[capture][id] = node
end

local function resolve_lang(bufnr)
	local ft = vim.bo[bufnr].filetype
	if not ft or ft == "" then
		return nil
	end
	return vim.treesitter.language.get_lang(ft) or ft
end

local function get_query(lang)
	local ok, query = pcall(vim.treesitter.query.get, lang, "diffmantic")
	if ok and query then
		return query
	end

	local parsed_ok, parsed = pcall(vim.treesitter.query.parse, lang, FALLBACK_QUERY)
	if parsed_ok and parsed then
		return parsed
	end

	return nil
end

function M.build_index(root, bufnr)
	local lang = resolve_lang(bufnr)
	if not lang then
		return nil
	end

	local query = get_query(lang)
	if not query then
		return nil
	end

	local index = {
		lang = lang,
		by_node = {},
		by_capture = {},
	}

	for id, node in query:iter_captures(root, bufnr, 0, -1) do
		local capture = query.captures[id]
		if capture then
			add_capture(index, capture, node)
		end
	end

	return index
end

function M.has_capture(node, index, capture)
	if not node or not index then
		return false
	end
	local by_node = index.by_node[node:id()]
	return by_node and by_node[capture] or false
end

function M.find_descendant_with_capture(node, index, capture)
	if not node or not index then
		return nil
	end

	local by_capture = index.by_capture[capture]
	if not by_capture then
		return nil
	end

	for _, captured in pairs(by_capture) do
		if node:equal(captured) or node:child_with_descendant(captured) then
			return captured
		end
	end

	return nil
end

function M.has_kind(node, index, kind)
	local captures = CAPTURE_BY_KIND[kind]
	if not captures then
		return false
	end

	for _, capture in ipairs(captures) do
		if M.has_capture(node, index, capture) then
			return true
		end
	end

	return false
end

function M.has_structural_kind(node, index, kind)
	local captures = STRUCTURAL_CAPTURE_BY_KIND[kind]
	if not captures then
		return M.has_kind(node, index, kind)
	end

	for _, capture in ipairs(captures) do
		if M.has_capture(node, index, capture) then
			return true
		end
	end

	return false
end

function M.get_kind_name_node(node, index, kind)
	local capture = string.format("diff.%s.name", kind)
	return M.find_descendant_with_capture(node, index, capture)
end

function M.get_kind_name_text(node, index, bufnr, kind)
	local name_node = M.get_kind_name_node(node, index, kind)
	if not name_node then
		return nil
	end
	return vim.treesitter.get_node_text(name_node, bufnr)
end

return M
