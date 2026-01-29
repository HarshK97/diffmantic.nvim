local M = {}

local function string_hash(str)
	local h = 5381
	for i = 1, #str do
		h = ((h * 33) + string.byte(str, i)) % 4294967296
	end
	return h
end

local function is_leaf(node)
	return node:named_child_count() == 0
end

local function get_label(node, bufnr)
	if is_leaf(node) then
		return vim.treesitter.get_node_text(node, bufnr)
	else
		return ""
	end
end

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

		for child in node:iter_children() do
			local child_info = visit(child)
			height = math.max(height, child_info.height + 1)
			size = size + child_info.size
			child_hashes = child_hashes .. tostring(child_info.hash)
			child_structure_hashes = child_structure_hashes .. tostring(child_info.structure_hash)
			info[child:id()].parent = node
		end

		local hash = string_hash(type .. label .. child_hashes)
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
