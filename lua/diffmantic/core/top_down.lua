local ts_utils = require("diffmantic.treesitter")

local M = {}

local function node_key(info)
	return info.start_row, info.start_col, info.end_row, info.end_col
end

local function compare_node_order(a, b)
	local asr, asc, aer, aec = node_key(a)
	local bsr, bsc, ber, bec = node_key(b)
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
function M.top_down_match(src_root, dst_root, src_buf, dst_buf, opts)
	opts = opts or {}
	local mappings = {}
	local src_info = opts.src_info or ts_utils.preprocess_tree(src_root, src_buf, opts)
	local dst_info = opts.dst_info or ts_utils.preprocess_tree(dst_root, dst_buf, opts)

	local src_mapped = {}
	local dst_mapped = {}
	local src_to_dst = {}
	local src_root_id = src_root:id()
	local dst_root_id = dst_root:id()

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

	local function dst_parent_key(info)
		local parent_id = info.parent_id
		if not parent_id then
			return 0
		end
		if parent_id == dst_root_id then
			return dst_root_id
		end
		return parent_id
	end

	local function src_parent_key(info)
		local parent_id = info.parent_id
		if not parent_id then
			return 0
		end
		if parent_id == src_root_id then
			return dst_root_id
		end
		return src_to_dst[parent_id] or -1
	end

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

	-- For each height, match nodes with the same hash and compatible mapped parent.
	-- Parent buckets avoid O(k) scans through all same-hash candidates.
	for h = max_h, 1, -1 do
		local s_nodes = src_by_height[h] or {}
		local d_nodes = dst_by_height[h] or {}

		local dst_by_hash_parent = {}
		for _, d in ipairs(d_nodes) do
			if not dst_mapped[d.id] then
				local hash_buckets = dst_by_hash_parent[d.hash]
				if not hash_buckets then
					hash_buckets = {}
					dst_by_hash_parent[d.hash] = hash_buckets
				end

				local pkey = dst_parent_key(d)
				local queue = hash_buckets[pkey]
				if not queue then
					queue = { head = 1, items = {} }
					hash_buckets[pkey] = queue
				end
				local items = queue.items
				items[#items + 1] = d
			end
		end

		for _, s in ipairs(s_nodes) do
			if not src_mapped[s.id] then
				local pkey = src_parent_key(s)
				if pkey ~= -1 then
					local hash_buckets = dst_by_hash_parent[s.hash]
					local queue = hash_buckets and hash_buckets[pkey] or nil
					if queue then
						local head = queue.head
						local items = queue.items
						local d = items[head]
						if d then
							queue.head = head + 1
							table.insert(mappings, { src = s.id, dst = d.id })
							src_mapped[s.id] = true
							dst_mapped[d.id] = true
							src_to_dst[s.id] = d.id
						end
					end
				end
			end
		end
	end

	return mappings, src_info, dst_info
end

return M
