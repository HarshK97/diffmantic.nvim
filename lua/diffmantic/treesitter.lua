local M = {}

-- Simple hash function: takes a string and returns a number
-- Used to create unique identifiers for tree nodes
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

-- A leaf node has no children (e.g., a variable name, number, string literal)
local function is_leaf(node)
	return node:named_child_count() == 0
end

-- Get the text content of a node, but only if it's a leaf
-- Non-leaf nodes get empty label (their structure matters, not their text)
local function get_label(node, bufnr)
	if is_leaf(node) then
		return vim.treesitter.get_node_text(node, bufnr)
	else
		return ""
	end
end

-- Walk through the entire syntax tree and compute metadata for each node
-- Returns a table mapping node IDs to their computed info
function M.preprocess_tree(root, bufnr, opts)
	opts = opts or {}
	local info = {}
	local label_hash_cache = {}
	local type_hash_cache = {}

	local function cached_string_hash(cache, text)
		local value = cache[text]
		if value == nil then
			value = string_hash(text)
			cache[text] = value
		end
		return value
	end

	local function visit(node)
		local id = node:id()
		local type = node:type()
		local label = get_label(node, bufnr)
		local sr, sc, er, ec = node:range()

		local height = 1
		local size = 1
		local hash_acc = cached_string_hash(type_hash_cache, type)
		local structure_hash_acc = hash_acc

		-- Recursively process all children first (post-order traversal)
		for child in node:iter_children() do
			local child_info = visit(child)
			height = math.max(height, child_info.height + 1)
			size = size + child_info.size
			hash_acc = hash_combine(hash_acc, child_info.hash)
			structure_hash_acc = hash_combine(structure_hash_acc, child_info.structure_hash)
			child_info.parent = node
			child_info.parent_id = id
		end

		if label ~= "" then
			hash_acc = hash_combine(hash_acc, cached_string_hash(label_hash_cache, label))
		else
			hash_acc = hash_combine(hash_acc, 0)
		end

		-- hash: unique if type + label + children all match (exact match)
		local hash = hash_acc
		-- structure_hash: unique if type + children structure match (ignores labels)
		-- useful for detecting moved/renamed code
		local structure_hash = structure_hash_acc

		info[id] = {
			node = node,
			height = height,
			size = size,
			hash = hash,
			structure_hash = structure_hash,
			type = type,
			label = label,
			id = id,
			start_row = sr,
			start_col = sc,
			end_row = er,
			end_col = ec,
			parent_id = nil,
		}
		return info[id]
	end

	visit(root)
	return info
end

-- Get all nodes under a given node (children, grandchildren, etc.)
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
