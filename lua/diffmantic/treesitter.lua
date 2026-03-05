local rules_mod = require("diffmantic.core.rules")
local M = {}

-- Simple hash function: takes a string and returns a number
local function string_hash(str)
	local h = 5381
	for i = 1, #str do
		h = ((h * 33) + string.byte(str, i)) % 4294967296
	end
	return h
end

local function hash_combine(acc, value)
	return ((acc * 33) + value + 97) % 4294967296
end

local function is_leaf(node)
	return node:named_child_count() == 0
end

local function get_label(node, bufnr, rules, parent_type)
	if is_leaf(node) then
		if rules_mod.is_label_ignored(rules, node:type(), parent_type) then
			return ""
		end
		return vim.treesitter.get_node_text(node, bufnr)
	else
		return ""
	end
end

function M.preprocess_tree(root, bufnr, opts)
	opts = opts or {}

	local lang = opts.lang
	if not lang then
		lang = vim.bo[bufnr] and vim.bo[bufnr].filetype or ""
	end
	local rules = rules_mod.get(lang)

	local info = {}
	local label_hash_cache = {}
	local type_hash_cache  = {}

	local function cached_hash(cache, text)
		local v = cache[text]
		if v == nil then v = string_hash(text); cache[text] = v end
		return v
	end

	local function visit(node, parent_id, parent_type)
		local id    = node:id()
		local type_ = node:type()

		if rules_mod.is_ignored(rules, type_, parent_type) then
			return nil
		end

		local hash_type = rules_mod.canonical_type(rules, type_, parent_type)
		local sr, sc, er, ec = node:range()

		if rules_mod.is_flattened(rules, type_, parent_type) then
			local full_text = ""
			if not rules_mod.is_label_ignored(rules, type_, parent_type) then
				full_text = vim.treesitter.get_node_text(node, bufnr) or ""
			end
			local h = cached_hash(type_hash_cache, hash_type)
			h = hash_combine(h, cached_hash(label_hash_cache, full_text))
			info[id] = {
				node      = node,
				height    = 1,
				size      = 1,
				hash      = h,
				structure_hash = cached_hash(type_hash_cache, hash_type),
				type      = type_,
				label     = full_text,
				id        = id,
				start_row = sr, start_col = sc,
				end_row   = er, end_col   = ec,
				parent_id = parent_id,
			}
			if parent_id then
				local pi = info[parent_id]
				if pi then pi.parent_id = pi.parent_id end -- already set
			end
			return info[id]
		end

		local height          = 1
		local size            = 1
		local hash_acc        = cached_hash(type_hash_cache, hash_type)
		local struct_hash_acc = hash_acc

		for child in node:iter_children() do
			local cinfo = visit(child, id, type_)
			if cinfo then
				height        = math.max(height, cinfo.height + 1)
				size          = size + cinfo.size
				hash_acc      = hash_combine(hash_acc, cinfo.hash)
				struct_hash_acc = hash_combine(struct_hash_acc, cinfo.structure_hash)
				cinfo.parent_id = id
			end
		end

		local label = get_label(node, bufnr, rules, parent_type)
		if label ~= "" then
			hash_acc = hash_combine(hash_acc, cached_hash(label_hash_cache, label))
		else
			hash_acc = hash_combine(hash_acc, 0)
		end

		info[id] = {
			node           = node,
			height         = height,
			size           = size,
			hash           = hash_acc,
			structure_hash = struct_hash_acc,
			type           = type_,
			label          = label,
			id             = id,
			start_row      = sr, start_col = sc,
			end_row        = er, end_col   = ec,
			parent_id      = parent_id,
		}
		return info[id]
	end

	visit(root, nil, nil)
	return info
end

function M.get_descendants(node)
	local descendants = {}
	local function traverse(n)
		for child in n:iter_children() do
			table.insert(descendants, child)
			traverse(child)
		end
	end
	traverse(node)
	return descendants
end

return M
