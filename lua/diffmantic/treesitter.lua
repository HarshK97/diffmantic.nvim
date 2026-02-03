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
function M.preprocess_tree(root, bufnr)
	local info = {}

	local function visit(node)
		local id = node:id()
		local type = node:type()
		local label = get_label(node, bufnr)

		local height = 1
		local size = 1
		local child_hashes = ""
		local child_structure_hashes = ""

		-- Recursively process all children first (post-order traversal)
		for child in node:iter_children() do
			local child_info = visit(child)
			height = math.max(height, child_info.height + 1)
			size = size + child_info.size
			child_hashes = child_hashes .. tostring(child_info.hash)
			child_structure_hashes = child_structure_hashes .. tostring(child_info.structure_hash)
			info[child:id()].parent = node
		end

		-- hash: unique if type + label + children all match (exact match)
		local hash = string_hash(type .. label .. child_hashes)
		-- structure_hash: unique if type + children structure match (ignores labels)
		-- useful for detecting moved/renamed code
		local structure_hash = string_hash(type .. child_structure_hashes)

		info[id] = {
			node = node,
			height = height,
			size = size,
			hash = hash,
			structure_hash = structure_hash,
			type = type,
			label = label,
			id = id,
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
