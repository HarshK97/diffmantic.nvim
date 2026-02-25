local M = {}

local function node_key(info)
	if info.start_row ~= nil then
		return info.start_row, info.start_col, info.end_row, info.end_col
	end
	local sr, sc, er, ec = info.node:range()
	return sr, sc, er, ec
end

local function compare_info_order(a_info, b_info)
	local asr, asc, aer, aec = node_key(a_info)
	local bsr, bsc, ber, bec = node_key(b_info)
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

-- Recovery matching: tries to match remaining unmapped nodes using LCS and unique type.
function M.recovery_match(src_root, dst_root, mappings, src_info, dst_info, src_buf, dst_buf, opts)
	opts = opts or {}
	local lcs_cell_limit = opts.recovery_lcs_cell_limit or 6000
	local skip_unique_type_match = {
		field_declaration = true,
	}

	-- Build O(1) lookup tables.
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	local function can_match(src_node, dst_node, hash_key)
		local s = src_info[src_node:id()]
		local d = dst_info[dst_node:id()]
		if not s or not d then
			return false
		end
		return s[hash_key] == d[hash_key] and src_node:type() == dst_node:type()
	end

	local function greedy_lcs(src_list, dst_list, hash_key)
		local result = {}
		local j = 1
		for i = 1, #src_list do
			local src_node = src_list[i]
			while j <= #dst_list do
				local dst_node = dst_list[j]
				j = j + 1
				if can_match(src_node, dst_node, hash_key) then
					table.insert(result, { src = src_node, dst = dst_node })
					break
				end
			end
		end
		return result
	end

	-- Longest Common Subsequence (LCS) for matching children.
	-- Reconstructed left-to-right so duplicate-compatible nodes prefer earlier dst siblings.
	local function lcs(src_list, dst_list, hash_key)
		local m, n = #src_list, #dst_list
		if m == 0 or n == 0 then
			return {}
		end
		if (m * n) > lcs_cell_limit then
			return greedy_lcs(src_list, dst_list, hash_key)
		end

		local dp = {}
		for i = 1, m + 1 do
			dp[i] = {}
			for j = 1, n + 1 do
				dp[i][j] = 0
			end
		end

		for i = m, 1, -1 do
			for j = n, 1, -1 do
				if can_match(src_list[i], dst_list[j], hash_key) then
					dp[i][j] = dp[i + 1][j + 1] + 1
				else
					dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
				end
			end
		end

		-- Deterministic left-biased reconstruction.
		local result = {}
		local i, j = 1, 1
		while i <= m and j <= n do
			if can_match(src_list[i], dst_list[j], hash_key) and dp[i][j] == (dp[i + 1][j + 1] + 1) then
				table.insert(result, { src = src_list[i], dst = dst_list[j] })
				i = i + 1
				j = j + 1
			else
				local skip_src = dp[i + 1][j]
				local skip_dst = dp[i][j + 1]
				if skip_dst > skip_src then
					j = j + 1
				elseif skip_src > skip_dst then
					i = i + 1
				else
					-- Tie: advance src to keep earlier destination candidates.
					i = i + 1
				end
			end
		end
		return result
	end

	local function has_unmatched_on_both_sides(src_node, dst_node)
		local src_has = false
		for child in src_node:iter_children() do
			if not src_to_dst[child:id()] then
				src_has = true
				break
			end
		end
		if not src_has then
			return false
		end
		for child in dst_node:iter_children() do
			if not dst_to_src[child:id()] then
				return true
			end
		end
		return false
	end

	local pending = {}
	local queued = {}

	local function queue_key(src_id, dst_id)
		return tostring(src_id) .. ":" .. tostring(dst_id)
	end

	local function enqueue(src_id, dst_id)
		local key = queue_key(src_id, dst_id)
		if queued[key] then
			return
		end
		queued[key] = true
		pending[#pending + 1] = { src_id = src_id, dst_id = dst_id, key = key }
	end

	-- Helper to add a mapping and update lookup tables.
	local function add_mapping(src_id, dst_id)
		if src_to_dst[src_id] or dst_to_src[dst_id] then
			return false
		end
		table.insert(mappings, { src = src_id, dst = dst_id })
		src_to_dst[src_id] = dst_id
		dst_to_src[dst_id] = src_id
		local src_entry = src_info[src_id]
		local dst_entry = dst_info[dst_id]
		if src_entry and dst_entry and has_unmatched_on_both_sides(src_entry.node, dst_entry.node) then
			enqueue(src_id, dst_id)
		end
		return true
	end

	local function unmatched_children(src_node, dst_node)
		local src_children = {}
		local dst_children = {}
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
		return src_children, dst_children
	end

	-- Try to match children using LCS and unique type.
	local function simple_recovery(src_node, dst_node)
		local src_children, dst_children = unmatched_children(src_node, dst_node)
		if #src_children == 0 or #dst_children == 0 then
			return
		end

		-- Step 1: match children with same hash (exact match).
		for _, match in ipairs(lcs(src_children, dst_children, "hash")) do
			if add_mapping(match.src:id(), match.dst:id()) then
				simple_recovery(match.src, match.dst)
			end
		end

		-- Step 2: match children with same structure_hash (for updates).
		src_children, dst_children = unmatched_children(src_node, dst_node)
		for _, match in ipairs(lcs(src_children, dst_children, "structure_hash")) do
			if match.src:type() ~= "field_declaration" and add_mapping(match.src:id(), match.dst:id()) then
				simple_recovery(match.src, match.dst)
			end
		end

		-- Step 3: match children with unique type (type appears only once).
		src_children, dst_children = unmatched_children(src_node, dst_node)

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
			if count == 1 and dst_type_count[t] == 1 and not skip_unique_type_match[t] then
				local s, d = src_by_type[t], dst_by_type[t]
				if add_mapping(s:id(), d:id()) then
					simple_recovery(s, d)
				end
			end
		end
	end

	-- Seed worklist only with mapped pairs that still have unmatched children on both sides.
	for _, mapping in ipairs(mappings) do
		local src_entry = src_info[mapping.src]
		local dst_entry = dst_info[mapping.dst]
		if src_entry and dst_entry and has_unmatched_on_both_sides(src_entry.node, dst_entry.node) then
			enqueue(mapping.src, mapping.dst)
		end
	end

	while #pending > 0 do
		local pair = table.remove(pending)
		queued[pair.key] = nil
		local src_entry = src_info[pair.src_id]
		local dst_entry = dst_info[pair.dst_id]
		if src_entry and dst_entry and has_unmatched_on_both_sides(src_entry.node, dst_entry.node) then
			simple_recovery(src_entry.node, dst_entry.node)
		end
	end

	return mappings
end

return M
