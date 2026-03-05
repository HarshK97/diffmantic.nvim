
local M = {}

local MIN_HEIGHT = 1


local function build_maps(mappings)
	local s2d, d2s = {}, {}
	for _, m in ipairs(mappings) do
		s2d[m.src] = m.dst
		d2s[m.dst] = m.src
	end
	return s2d, d2s
end

local function get_children(node, info)
	local kids = {}
	for child in node:iter_children() do
		local cid = child:id()
		if info[cid] then
			table.insert(kids, child)
		end
	end
	return kids
end

local CONTAINER_TYPES = {
	function_definition = true,
	method_definition = true,
	function_declaration = true,
	function_item = true,
	local_function = true,
	function_expression = true,
	arrow_function = true,
}
local function get_container(node_id, info)
	local cur = info[node_id]
	if not cur then
		return nil
	end
	local pid = cur.parent_id
	while pid do
		local pi = info[pid]
		if not pi then
			break
		end
		if CONTAINER_TYPES[pi.type] then
			return pid
		end
		pid = pi.parent_id
	end
	return nil
end

local function container_eligible(src_id, dst_id, src_info, dst_info, s2d)
	local sc = get_container(src_id, src_info)
	local dc = get_container(dst_id, dst_info)
	if not sc and not dc then
		return true
	end
	if not sc or not dc then
		return false
	end
	local sci = src_info[sc]
	local dci = dst_info[dc]
	if not sci or not dci or sci.type ~= dci.type then
		return false
	end
	local mapped_dc = s2d[sc]
	return mapped_dc == nil or mapped_dc == dc
end

local function add_mapping_recursively(snode, dnode, src_info, dst_info, s2d, d2s, out)
	local sid = snode:id()
	local did = dnode:id()
	if s2d[sid] or d2s[did] then
		return
	end
	s2d[sid] = did
	d2s[did] = sid
	table.insert(out, { src = sid, dst = did })

	local skids = get_children(snode, src_info)
	local dkids = get_children(dnode, dst_info)
	local n = math.min(#skids, #dkids)
	for i = 1, n do
		add_mapping_recursively(skids[i], dkids[i], src_info, dst_info, s2d, d2s, out)
	end
end


local function node_pos_lt(a, b, info)
	local ai = info[a]
	local bi = info[b]
	if not ai or not bi then
		return tostring(a) < tostring(b)
	end
	local ar = ai.start_row
	local br = bi.start_row
	if ar ~= br then
		if ar == nil then
			return false
		end
		if br == nil then
			return true
		end
		return ar < br
	end
	local ac = ai.start_col
	local bc = bi.start_col
	if ac ~= bc then
		if ac == nil then
			return false
		end
		if bc == nil then
			return true
		end
		return ac < bc
	end
	local aer = ai.end_row
	local ber = bi.end_row
	if aer ~= ber then
		if aer == nil then
			return false
		end
		if ber == nil then
			return true
		end
		return aer < ber
	end
	local aec = ai.end_col
	local bec = bi.end_col
	if aec ~= bec then
		if aec == nil then
			return false
		end
		if bec == nil then
			return true
		end
		return aec < bec
	end
	return tostring(a) < tostring(b)
end

local function collect_sorted(info, type_set, exclude_map)
	local result = {}
	for id, v in pairs(info) do
		if type_set[v.type] and not exclude_map[id] then
			table.insert(result, id)
		end
	end
	table.sort(result, function(a, b)
		return node_pos_lt(a, b, info)
	end)
	return result
end


local FUNC_PREMATCH_TYPES = {
	function_definition = true,
	method_definition = true,
	function_declaration = true,
	function_item = true,
	local_function = true,
	function_expression = true,
	arrow_function = true,
}

local FUNC_PREMATCH_THRESHOLD = 0.30

local function get_func_name(node_id, info)
	local ni = info[node_id]
	if not ni or not ni.node then
		return nil
	end
	local NAME_TYPES = {
		field_identifier = true,
		identifier = true,
		name = true,
	}
	for child in ni.node:iter_children() do
		local cid = child:id()
		local ci = info[cid]
		if ci and NAME_TYPES[ci.type] and ci.label and ci.label ~= "" then
			return ci.label
		end
	end
	return nil
end

local function func_child_dice(sid, did, src_info, dst_info)
	local si = src_info[sid]
	local di = dst_info[did]
	if not si or not di or not si.node or not di.node then
		return 0
	end

	local src_hashes = {}
	local total_src, total_dst = 0, 0
	for child in si.node:iter_children() do
		local cid = child:id()
		local ci = src_info[cid]
		if ci then
			src_hashes[ci.hash] = (src_hashes[ci.hash] or 0) + 1
			total_src = total_src + 1
		end
	end
	for child in di.node:iter_children() do
		local cid = child:id()
		local ci = dst_info[cid]
		if ci then
			total_dst = total_dst + 1
		end
	end

	if total_src + total_dst == 0 then
		return 0
	end

	local common = 0
	for child in di.node:iter_children() do
		local cid = child:id()
		local ci = dst_info[cid]
		if ci and src_hashes[ci.hash] and src_hashes[ci.hash] > 0 then
			common = common + 1
			src_hashes[ci.hash] = src_hashes[ci.hash] - 1
		end
	end

	return 2.0 * common / (total_src + total_dst)
end

local function prematch_functions(src_info, dst_info, s2d, d2s, out)
	local src_fns = collect_sorted(src_info, FUNC_PREMATCH_TYPES, s2d)
	local dst_fns = collect_sorted(dst_info, FUNC_PREMATCH_TYPES, d2s)
	if #src_fns == 0 or #dst_fns == 0 then
		return
	end

	local dst_by_name = {}
	for _, did in ipairs(dst_fns) do
		local name = get_func_name(did, dst_info)
		if name then
			dst_by_name[name] = dst_by_name[name] or {}
			table.insert(dst_by_name[name], did)
		end
	end

	for _, sid in ipairs(src_fns) do
		if s2d[sid] then
			goto next_p1
		end
		local sname = get_func_name(sid, src_info)
		local si = src_info[sid]
		if sname and dst_by_name[sname] then
			local best_did, best_score = nil, -1
			for _, did in ipairs(dst_by_name[sname]) do
				if not d2s[did] and dst_info[did].type == si.type then
					local score = func_child_dice(sid, did, src_info, dst_info)
					if score > best_score then
						best_score = score
						best_did = did
					end
				end
			end
			if best_did then
				local di = dst_info[best_did]
				if si.hash == di.hash then
					add_mapping_recursively(si.node, di.node, src_info, dst_info, s2d, d2s, out)
				else
					s2d[sid] = best_did
					d2s[best_did] = sid
					table.insert(out, { src = sid, dst = best_did })
				end
			end
		end
		::next_p1::
	end

	local candidates = {}
	for _, sid in ipairs(src_fns) do
		if s2d[sid] then
			goto next_p2
		end
		local si = src_info[sid]
		for _, did in ipairs(dst_fns) do
			if not d2s[did] and dst_info[did].type == si.type then
				local score = func_child_dice(sid, did, src_info, dst_info)
				if score >= FUNC_PREMATCH_THRESHOLD then
					table.insert(candidates, {
						sid = sid,
						did = did,
						score = score,
						size = si.size or 0,
					})
				end
			end
		end
		::next_p2::
	end

	table.sort(candidates, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.size > b.size
	end)

	for _, c in ipairs(candidates) do
		if not s2d[c.sid] and not d2s[c.did] then
			local si = src_info[c.sid]
			local di = dst_info[c.did]
			if si.hash == di.hash then
				add_mapping_recursively(si.node, di.node, src_info, dst_info, s2d, d2s, out)
			else
				s2d[c.sid] = c.did
				d2s[c.did] = c.sid
				table.insert(out, { src = c.sid, dst = c.did })
			end
		end
	end
end


local function build_height_queue(info)
	local by_height = {}
	for id, v in pairs(info) do
		if v.height >= MIN_HEIGHT then
			by_height[v.height] = by_height[v.height] or {}
			table.insert(by_height[v.height], id)
		end
	end
	local heights = {}
	for h in pairs(by_height) do
		table.insert(heights, h)
	end
	table.sort(heights, function(a, b)
		return a > b
	end)
	return by_height, heights
end


function M.top_down_match(_src_root, _dst_root, _src_buf, _dst_buf, src_info, dst_info, init_mappings, _opts)
	local mappings = {}
	local s2d, d2s = {}, {}

	local opts = _opts or {}
	if opts.enable_function_prematch == true then
		prematch_functions(src_info, dst_info, s2d, d2s, mappings)
	end

	if init_mappings then
		for _, m in ipairs(init_mappings) do
			if not s2d[m.src] and not d2s[m.dst] then
				s2d[m.src] = m.dst
				d2s[m.dst] = m.src
				table.insert(mappings, m)
			end
		end
	end

	local src_by_h, src_heights = build_height_queue(src_info)
	local dst_by_h, dst_heights = build_height_queue(dst_info)

	local all_heights_set = {}
	for _, h in ipairs(src_heights) do
		all_heights_set[h] = true
	end
	for _, h in ipairs(dst_heights) do
		all_heights_set[h] = true
	end
	local all_heights = {}
	for h in pairs(all_heights_set) do
		table.insert(all_heights, h)
	end
	table.sort(all_heights, function(a, b)
		return a > b
	end)

	local src_open = {}
	local dst_open = {}

	for _, ids in pairs(src_by_h) do
		for _, id in ipairs(ids) do
			local h = src_info[id].height
			src_open[h] = src_open[h] or {}
			table.insert(src_open[h], id)
		end
	end
	for _, ids in pairs(dst_by_h) do
		for _, id in ipairs(ids) do
			local h = dst_info[id].height
			dst_open[h] = dst_open[h] or {}
			table.insert(dst_open[h], id)
		end
	end

	local ambiguous = {}

	for _, h in ipairs(all_heights) do
		local sids = src_open[h] or {}
		local dids = dst_open[h] or {}
		if #sids == 0 or #dids == 0 then
			goto continue_h
		end

		local src_by_hash = {}
		for _, sid in ipairs(sids) do
			if not s2d[sid] then
				local hsh = src_info[sid].hash
				src_by_hash[hsh] = src_by_hash[hsh] or {}
				table.insert(src_by_hash[hsh], sid)
			end
		end

		local dst_by_hash = {}
		for _, did in ipairs(dids) do
			if not d2s[did] then
				local hsh = dst_info[did].hash
				if src_by_hash[hsh] then
					dst_by_hash[hsh] = dst_by_hash[hsh] or {}
					table.insert(dst_by_hash[hsh], did)
				end
			end
		end

		local sorted_hashes = {}
		for hsh in pairs(src_by_hash) do
			table.insert(sorted_hashes, hsh)
		end
		table.sort(sorted_hashes)

		for _, hsh in ipairs(sorted_hashes) do
			local srcs = src_by_hash[hsh]
			local dsts = dst_by_hash[hsh]
			if not dsts then
				for _, sid in ipairs(srcs) do
					if not s2d[sid] then
						local si = src_info[sid]
						if si.node then
							for child in si.node:iter_children() do
								local cid = child:id()
								if src_info[cid] and src_info[cid].height >= MIN_HEIGHT then
									src_open[src_info[cid].height] = src_open[src_info[cid].height] or {}
									table.insert(src_open[src_info[cid].height], cid)
								end
							end
						end
					end
				end
			elseif #srcs == 1 and #dsts == 1 then
				local sid = srcs[1]
				local did = dsts[1]
				if not s2d[sid] and not d2s[did] then
					if container_eligible(sid, did, src_info, dst_info, s2d) then
						add_mapping_recursively(
							src_info[sid].node,
							dst_info[did].node,
							src_info,
							dst_info,
							s2d,
							d2s,
							mappings
						)
					else
						local si = src_info[sid]
						local di = dst_info[did]
						if si and si.node then
							for child in si.node:iter_children() do
								local cid = child:id()
								if src_info[cid] and src_info[cid].height >= MIN_HEIGHT then
									src_open[src_info[cid].height] = src_open[src_info[cid].height] or {}
									table.insert(src_open[src_info[cid].height], cid)
								end
							end
						end
						if di and di.node then
							for child in di.node:iter_children() do
								local cid = child:id()
								if dst_info[cid] and dst_info[cid].height >= MIN_HEIGHT then
									dst_open[dst_info[cid].height] = dst_open[dst_info[cid].height] or {}
									table.insert(dst_open[dst_info[cid].height], cid)
								end
							end
						end
					end
				end
			else
				table.insert(ambiguous, { srcs = srcs, dsts = dsts, height = h })
				for _, sid in ipairs(srcs) do
					if not s2d[sid] then
						local si = src_info[sid]
						if si.node then
							for child in si.node:iter_children() do
								local cid = child:id()
								if src_info[cid] and src_info[cid].height >= MIN_HEIGHT then
									src_open[src_info[cid].height] = src_open[src_info[cid].height] or {}
									table.insert(src_open[src_info[cid].height], cid)
								end
							end
						end
					end
				end
				for _, did in ipairs(dsts) do
					if not d2s[did] then
						local di = dst_info[did]
						if di.node then
							for child in di.node:iter_children() do
								local cid = child:id()
								if dst_info[cid] and dst_info[cid].height >= MIN_HEIGHT then
									dst_open[dst_info[cid].height] = dst_open[dst_info[cid].height] or {}
									table.insert(dst_open[dst_info[cid].height], cid)
								end
							end
						end
					end
				end
			end
		end

		::continue_h::
	end

	table.sort(ambiguous, function(a, b)
		local sa = 0
		for _, id in ipairs(a.srcs) do
			sa = math.max(sa, src_info[id].size or 0)
		end
		local sb = 0
		for _, id in ipairs(b.srcs) do
			sb = math.max(sb, src_info[id].size or 0)
		end
		return sa > sb
	end)

	for _, group in ipairs(ambiguous) do
		local pairs_list = {}
		for _, sid in ipairs(group.srcs) do
			for _, did in ipairs(group.dsts) do
				table.insert(pairs_list, { sid = sid, did = did, size = src_info[sid].size or 0 })
			end
		end
		table.sort(pairs_list, function(a, b)
			return a.size > b.size
		end)

		for _, p in ipairs(pairs_list) do
			if not s2d[p.sid] and not d2s[p.did] then
				if container_eligible(p.sid, p.did, src_info, dst_info, s2d) then
					add_mapping_recursively(
						src_info[p.sid].node,
						dst_info[p.did].node,
						src_info,
						dst_info,
						s2d,
						d2s,
						mappings
					)
				end
			end
		end
	end

	return mappings, src_info, dst_info
end

return M
