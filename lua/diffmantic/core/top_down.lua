local ts_utils = require("diffmantic.treesitter")

local M = {}

local function node_key(node)
	local sr, sc, er, ec = node:range()
	return sr, sc, er, ec
end

local function compare_node_order(a, b)
	local asr, asc, aer, aec = node_key(a.node)
	local bsr, bsc, ber, bec = node_key(b.node)
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
	return a.type < b.type
end

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

		for _, nodes in pairs(by_height) do
			table.sort(nodes, compare_node_order)
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

return M
