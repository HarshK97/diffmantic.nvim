local M = {}

local function node_key(node)
	local sr, sc, er, ec = node:range()
	return sr, sc, er, ec
end

local function compare_info_order(a_info, b_info)
	local asr, asc, aer, aec = node_key(a_info.node)
	local bsr, bsc, ber, bec = node_key(b_info.node)
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

-- Recovery matching: tries to match remaining unmapped nodes using LCS and unique type
function M.recovery_match(src_root, dst_root, mappings, src_info, dst_info, src_buf, dst_buf)
	-- Build O(1) lookup tables
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	-- Longest Common Subsequence (LCS) for matching children
	local function lcs(src_list, dst_list, hash_key)
		local m, n = #src_list, #dst_list
		if m == 0 or n == 0 then
			return {}
		end

		local dp = {}
		for i = 0, m do
			dp[i] = {}
			for j = 0, n do
				dp[i][j] = 0
			end
		end

		for i = 1, m do
			for j = 1, n do
				local s, d = src_list[i], dst_list[j]
				if src_info[s:id()][hash_key] == dst_info[d:id()][hash_key] and s:type() == d:type() then
					dp[i][j] = dp[i - 1][j - 1] + 1
				else
					dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
				end
			end
		end

		-- Backtrack to find matches
		local result = {}
		local i, j = m, n
		while i > 0 and j > 0 do
			local s, d = src_list[i], dst_list[j]
			if src_info[s:id()][hash_key] == dst_info[d:id()][hash_key] and s:type() == d:type() then
				table.insert(result, 1, { src = s, dst = d })
				i, j = i - 1, j - 1
			elseif dp[i - 1][j] > dp[i][j - 1] then
				i = i - 1
			else
				j = j - 1
			end
		end
		return result
	end

	-- Helper to add a mapping and update lookup tables
	local function add_mapping(src_id, dst_id)
		table.insert(mappings, { src = src_id, dst = dst_id })
		src_to_dst[src_id] = dst_id
		dst_to_src[dst_id] = src_id
	end

	-- Try to match children using LCS and unique type
	local function simple_recovery(src_node, dst_node)
		local src_children, dst_children = {}, {}
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				table.insert(src_children, child)
			end
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				table.insert(dst_children, child)
			end
		end
		if #src_children == 0 or #dst_children == 0 then
			return
		end

		-- Step 1: match children with same hash (exact match)
		for _, match in ipairs(lcs(src_children, dst_children, "hash")) do
			if not src_to_dst[match.src:id()] and not dst_to_src[match.dst:id()] then
				add_mapping(match.src:id(), match.dst:id())
			end
		end

		-- Step 2: match children with same structure_hash (for updates)
		src_children, dst_children = {}, {}
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				table.insert(src_children, child)
			end
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				table.insert(dst_children, child)
			end
		end
		for _, match in ipairs(lcs(src_children, dst_children, "structure_hash")) do
			if not src_to_dst[match.src:id()] and not dst_to_src[match.dst:id()] then
				add_mapping(match.src:id(), match.dst:id())
			end
		end

		-- Step 3: match children with unique type (type appears only once)
		src_children, dst_children = {}, {}
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				table.insert(src_children, child)
			end
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				table.insert(dst_children, child)
			end
		end

		local src_by_type, dst_by_type = {}, {}
		local src_type_count, dst_type_count = {}, {}
		for _, c in ipairs(src_children) do
			local t = c:type()
			src_type_count[t] = (src_type_count[t] or 0) + 1
			src_by_type[t] = c
		end
		for _, c in ipairs(dst_children) do
			local t = c:type()
			dst_type_count[t] = (dst_type_count[t] or 0) + 1
			dst_by_type[t] = c
		end

		for t, count in pairs(src_type_count) do
			if count == 1 and dst_type_count[t] == 1 then
				local s, d = src_by_type[t], dst_by_type[t]
				if not src_to_dst[s:id()] and not dst_to_src[d:id()] then
					add_mapping(s:id(), d:id())
					simple_recovery(s, d)
				end
			end
		end
	end

	-- Apply recovery to all mapped nodes
	local src_ids = {}
	for id in pairs(src_info) do
		table.insert(src_ids, id)
	end
	table.sort(src_ids, function(a, b)
		return compare_info_order(src_info[a], src_info[b])
	end)

	for _, id in ipairs(src_ids) do
		local info = src_info[id]
		local dst_id = src_to_dst[id]
		if dst_id then
			simple_recovery(info.node, dst_info[dst_id].node)
		end
	end

	return mappings
end

return M
