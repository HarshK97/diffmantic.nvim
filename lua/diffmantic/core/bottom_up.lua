
local M = {}


local function build_maps(mappings)
	local s2d, d2s = {}, {}
	for _, m in ipairs(mappings) do
		s2d[m.src] = m.dst
		d2s[m.dst] = m.src
	end
	return s2d, d2s
end

local function pair_parent_consistent(src_id, dst_id, s2d, d2s, src_info, dst_info)
	local si = src_info[src_id]
	local di = dst_info[dst_id]
	if not si or not di then
		return false
	end
	local sp = si.parent_id
	local dp = di.parent_id
	if sp and s2d[sp] and s2d[sp] ~= dp then
		return false
	end
	if dp and d2s[dp] and d2s[dp] ~= sp then
		return false
	end
	return true
end

local CONTAINER_TYPES_BU = {
	function_definition = true,
	method_definition = true,
	function_declaration = true,
	function_item = true,
	local_function = true,
	function_expression = true,
	arrow_function = true,
}
local function get_container_bu(node_id, info)
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
		if CONTAINER_TYPES_BU[pi.type] then
			return pid
		end
		pid = pi.parent_id
	end
	return nil
end

local function maps_to_list(s2d)
	local out = {}
	for src, dst in pairs(s2d) do
		table.insert(out, { src = src, dst = dst })
	end
	return out
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

local function post_order(root_id, info)
	local children = {}
	for id, v in pairs(info) do
		local pid = v.parent_id
		if pid then
			children[pid] = children[pid] or {}
			table.insert(children[pid], id)
		end
	end

	for _, kids in pairs(children) do
		table.sort(kids, function(a, b)
			return node_pos_lt(a, b, info)
		end)
	end

	local order = {}
	local visited = {}
	local function visit(id)
		if visited[id] then
			return
		end
		visited[id] = true
		for _, cid in ipairs(children[id] or {}) do
			visit(cid)
		end
		table.insert(order, id)
	end
	visit(root_id)
	return order, children
end

local function has_unmapped_children(node, map, info)
	if not node then
		return false
	end
	for child in node:iter_children() do
		local cid = child:id()
		if info[cid] and not map[cid] then
			return true
		end
	end
	return false
end

local function child_position(parent_id, child_id, info)
	local p = info[parent_id]
	if not p or not p.node then
		return nil
	end
	local pos = 0
	for child in p.node:iter_children() do
		local cid = child:id()
		if info[cid] then
			pos = pos + 1
			if cid == child_id then
				return pos
			end
		end
	end
	return nil
end

local function dice_similarity(src_id, dst_id, s2d, d2s, src_info, dst_info)
	local si = src_info[src_id]
	local di = dst_info[dst_id]
	if not si or not di then
		return 0
	end

	local sc = get_container_bu(src_id, src_info)
	local dc = get_container_bu(dst_id, dst_info)
	if sc or dc then
		if not sc or not dc then
			return 0
		end
		if (s2d[sc] and s2d[sc] ~= dc) or (d2s[dc] and d2s[dc] ~= sc) then
			return 0
		end
	end

	if not pair_parent_consistent(src_id, dst_id, s2d, d2s, src_info, dst_info) then
		return 0
	end

	local src_size = (si.size or 1) - 1
	local dst_size = (di.size or 1) - 1

	if src_size + dst_size == 0 then
		if si.type == di.type then
			return 1.0
		else
			return 0.0
		end
	end

	local function is_desc_of(node_id, ancestor_id, info)
		local cur_id = info[node_id] and info[node_id].parent_id
		while cur_id do
			if cur_id == ancestor_id then
				return true
			end
			local p = info[cur_id]
			cur_id = p and p.parent_id
		end
		return false
	end

	local common = 0
	local snode = si.node
	if snode then
		local count_desc
		count_desc = function(node)
			for child in node:iter_children() do
				local cid = child:id()
				if src_info[cid] then
					local mapped_dst = s2d[cid]
					if mapped_dst and is_desc_of(mapped_dst, dst_id, dst_info) then
						common = common + 1
					end
					count_desc(child)
				end
			end
		end
		count_desc(snode)
	end

	local score = 2.0 * common / (src_size + dst_size)

	local sp = si.parent_id
	local dp = di.parent_id
	if sp and dp and s2d[sp] == dp then
		score = math.min(1.0, score + 0.15)
	end

	return score
end

local function get_candidates(src_id, s2d, d2s, src_info, dst_info)
	local si = src_info[src_id]
	if not si or not si.node then
		return {}
	end

	local src_type = si.type
	local seeds = {}

	local function gather_seeds(node)
		for child in node:iter_children() do
			local cid = child:id()
			if src_info[cid] then
				local mapped = s2d[cid]
				if mapped then
					table.insert(seeds, mapped)
				end
				gather_seeds(child)
			end
		end
	end
	gather_seeds(si.node)

	local visited = {}
	local candidates = {}
	for _, seed_id in ipairs(seeds) do
		local cur_id = dst_info[seed_id] and dst_info[seed_id].parent_id
		while cur_id do
			if visited[cur_id] then
				break
			end
			visited[cur_id] = true
			local di = dst_info[cur_id]
			if di and di.type == src_type and not d2s[cur_id] and di.parent_id ~= nil then
				table.insert(candidates, cur_id)
			end
			cur_id = di and di.parent_id
		end
	end

	return candidates
end


local function lcs_match(src_ids, dst_ids, key_fn)
	local m, n = #src_ids, #dst_ids
	if m == 0 or n == 0 then
		return {}
	end

	local sk, dk = {}, {}
	for i, id in ipairs(src_ids) do
		sk[i] = key_fn(id, "src")
	end
	for j, id in ipairs(dst_ids) do
		dk[j] = key_fn(id, "dst")
	end

	local dp = {}
	for i = 0, m do
		dp[i] = {}
		for j = 0, n do
			dp[i][j] = 0
		end
	end
	for i = m - 1, 0, -1 do
		for j = n - 1, 0, -1 do
			if sk[i + 1] == dk[j + 1] and sk[i + 1] ~= nil then
				dp[i][j] = dp[i + 1][j + 1] + 1
			else
				dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
			end
		end
	end

	local result = {}
	local i, j = 0, 0
	while i < m and j < n do
		if sk[i + 1] == dk[j + 1] and sk[i + 1] ~= nil then
			table.insert(result, { src_id = src_ids[i + 1], dst_id = dst_ids[j + 1] })
			i = i + 1
			j = j + 1
		elseif dp[i + 1][j] >= dp[i][j + 1] then
			i = i + 1
		else
			j = j + 1
		end
	end
	return result
end

local function simple_recovery(src_id, dst_id, s2d, d2s, src_info, dst_info, mappings_out)
	local si = src_info[src_id]
	local di = dst_info[dst_id]
	if not si or not di or not si.node or not di.node then
		return
	end

	local src_kids, dst_kids = {}, {}
	for child in si.node:iter_children() do
		local cid = child:id()
		if src_info[cid] and not s2d[cid] then
			table.insert(src_kids, cid)
		end
	end
	for child in di.node:iter_children() do
		local cid = child:id()
		if dst_info[cid] and not d2s[cid] then
			table.insert(dst_kids, cid)
		end
	end

	if #src_kids == 0 or #dst_kids == 0 then
		return
	end

	local function map_recursive(sid, did)
		if s2d[sid] or d2s[did] then
			return
		end
		local s = src_info[sid]
		local d = dst_info[did]
		if not s or not d or s.type ~= d.type then
			return
		end
		if not pair_parent_consistent(sid, did, s2d, d2s, src_info, dst_info) then
			return
		end
		s2d[sid] = did
		d2s[did] = sid
		table.insert(mappings_out, { src = sid, dst = did })
		local sn = src_info[sid] and src_info[sid].node
		local dn = dst_info[did] and dst_info[did].node
		if not sn or not dn then
			return
		end
		local skids, dkids = {}, {}
		for c in sn:iter_children() do
			if src_info[c:id()] then
				table.insert(skids, c:id())
			end
		end
		for c in dn:iter_children() do
			if dst_info[c:id()] then
				table.insert(dkids, c:id())
			end
		end
		local nb = math.min(#skids, #dkids)
		for i = 1, nb do
			map_recursive(skids[i], dkids[i])
		end
	end

	local lcs_e = lcs_match(src_kids, dst_kids, function(id, side)
		if side == "src" then
			return src_info[id] and src_info[id].hash
		else
			return dst_info[id] and dst_info[id].hash
		end
	end)
	for _, pair in ipairs(lcs_e) do
		if
			not s2d[pair.src_id]
			and not d2s[pair.dst_id]
			and pair_parent_consistent(pair.src_id, pair.dst_id, s2d, d2s, src_info, dst_info)
		then
			map_recursive(pair.src_id, pair.dst_id)
		end
	end

	src_kids, dst_kids = {}, {}
	for child in si.node:iter_children() do
		local cid = child:id()
		if src_info[cid] and not s2d[cid] then
			table.insert(src_kids, cid)
		end
	end
	for child in di.node:iter_children() do
		local cid = child:id()
		if dst_info[cid] and not d2s[cid] then
			table.insert(dst_kids, cid)
		end
	end
	if #src_kids == 0 or #dst_kids == 0 then
		return
	end

	local lcs_s = lcs_match(src_kids, dst_kids, function(id, side)
		if side == "src" then
			return src_info[id] and src_info[id].structure_hash
		else
			return dst_info[id] and dst_info[id].structure_hash
		end
	end)
	for _, pair in ipairs(lcs_s) do
		if
			not s2d[pair.src_id]
			and not d2s[pair.dst_id]
			and pair_parent_consistent(pair.src_id, pair.dst_id, s2d, d2s, src_info, dst_info)
		then
			map_recursive(pair.src_id, pair.dst_id)
		end
	end

	src_kids, dst_kids = {}, {}
	for child in si.node:iter_children() do
		local cid = child:id()
		if src_info[cid] and not s2d[cid] then
			table.insert(src_kids, cid)
		end
	end
	for child in di.node:iter_children() do
		local cid = child:id()
		if dst_info[cid] and not d2s[cid] then
			table.insert(dst_kids, cid)
		end
	end
	if #src_kids == 0 or #dst_kids == 0 then
		return
	end

	local src_type_count, dst_type_count = {}, {}
	local src_by_type, dst_by_type = {}, {}
	for _, cid in ipairs(src_kids) do
		local t = src_info[cid] and src_info[cid].type
		if t then
			src_type_count[t] = (src_type_count[t] or 0) + 1
			src_by_type[t] = cid
		end
	end
	for _, cid in ipairs(dst_kids) do
		local t = dst_info[cid] and dst_info[cid].type
		if t then
			dst_type_count[t] = (dst_type_count[t] or 0) + 1
			dst_by_type[t] = cid
		end
	end

	local unique_types = {}
	for t, s_count in pairs(src_type_count) do
		if s_count == 1 and dst_type_count[t] == 1 then
			table.insert(unique_types, t)
		end
	end
	table.sort(unique_types)

	for _, t in ipairs(unique_types) do
		local sa = src_by_type[t]
		local da = dst_by_type[t]
		if not s2d[sa] and not d2s[da] and pair_parent_consistent(sa, da, s2d, d2s, src_info, dst_info) then
			s2d[sa] = da
			d2s[da] = sa
			table.insert(mappings_out, { src = sa, dst = da })
			simple_recovery(sa, da, s2d, d2s, src_info, dst_info, mappings_out)
		end
	end
end

local function prune_inconsistent_mappings(mappings, src_info, dst_info)
	local STRICT_STRUCTURE_TYPES = {
		field_declaration = true,
		field = true,
		pair = true,
	}

	local FIELD_TYPES = {
		field_declaration = true,
	}

	local function field_name_matches(si, di)
		if not si.node or not di.node then
			return true
		end
		local function find_field_name(node, info, parent_type)
			for child in node:iter_children() do
				local ci = info[child:id()]
				if ci then
					if ci.type == "field_identifier" then
						return ci.label or ""
					end
					if parent_type == "field" and ci.type == "identifier" then
						return ci.label or ""
					end
					if parent_type == "pair" and ci.type == "string" then
						return ci.label or ""
					end
				end
			end
			return nil
		end
		local sname = find_field_name(si.node, src_info, si.type)
		local dname = find_field_name(di.node, dst_info, di.type)
		if sname == nil or dname == nil then
			return true
		end
		return sname == dname
	end

	local current = mappings
	for _ = 1, 8 do
		local s2d, d2s = build_maps(current)
		local filtered = {}
		local removed = false
		for _, m in ipairs(current) do
			local si = src_info[m.src]
			local di = dst_info[m.dst]
			local strict_ok = true
			if si and di and STRICT_STRUCTURE_TYPES[si.type] then
				strict_ok = (si.structure_hash == di.structure_hash)
			end
			if strict_ok and si and di and FIELD_TYPES[si.type] then
				strict_ok = field_name_matches(si, di)
			end
			if
				strict_ok
				and si
				and di
				and si.type == "if_statement"
				and si.parent_id
				and di.parent_id
				and s2d[si.parent_id] == di.parent_id
			then
				local spos = child_position(si.parent_id, m.src, src_info)
				local dpos = child_position(di.parent_id, m.dst, dst_info)
				if spos and dpos then
					if math.abs(spos - dpos) > 1 then
						strict_ok = false
					end
					if strict_ok then
						for _, m2 in ipairs(current) do
							if m2.src ~= m.src then
								local si2 = src_info[m2.src]
								local di2 = dst_info[m2.dst]
								if
									si2
									and di2
									and si2.type == "if_statement"
									and si2.parent_id == si.parent_id
									and di2.parent_id == di.parent_id
								then
									local spos2 = child_position(si2.parent_id, m2.src, src_info)
									local dpos2 = child_position(di2.parent_id, m2.dst, dst_info)
									if spos2 and dpos2 then
										local src_order = spos < spos2
										local dst_order = dpos < dpos2
										if src_order ~= dst_order then
											if math.abs(spos - dpos) >= math.abs(spos2 - dpos2) then
												strict_ok = false
											end
											break
										end
									end
								end
							end
						end
					end
				end
			end
			if
				si
				and di
				and si.type == di.type
				and strict_ok
				and pair_parent_consistent(m.src, m.dst, s2d, d2s, src_info, dst_info)
			then
				table.insert(filtered, m)
			else
				removed = true
			end
		end
		current = filtered
		if not removed then
			break
		end
	end
	return current
end


function M.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, _src_buf, _dst_buf, _opts)
	_opts = _opts or {}
	local s2d, d2s = build_maps(mappings)

	local src_root_id = src_root:id()
	local dst_root_id = dst_root:id()

	local src_post, src_children = post_order(src_root_id, src_info)

	for _, sid in ipairs(src_post) do
		local si = src_info[sid]
		if not si then
			goto continue
		end

		if sid == src_root_id then
			if not s2d[sid] and not d2s[dst_root_id] then
				s2d[sid] = dst_root_id
				d2s[dst_root_id] = sid
				table.insert(mappings, { src = sid, dst = dst_root_id })
			end
			simple_recovery(sid, dst_root_id, s2d, d2s, src_info, dst_info, mappings)
			break
		end

		if s2d[sid] then
			local did = s2d[sid]
			local di = dst_info[did]
			if
				di
				and has_unmapped_children(si.node, s2d, src_info)
				and has_unmapped_children(di.node, d2s, dst_info)
			then
				simple_recovery(sid, did, s2d, d2s, src_info, dst_info, mappings)
			end
			goto continue
		end

		local has_children = false
		for _ in (si.node and si.node:iter_children() or (function() end)()) do
			has_children = true
			break
		end
		if src_children[sid] and #src_children[sid] > 0 then
			has_children = true
		end
		if not has_children then
			goto continue
		end

		local candidates = get_candidates(sid, s2d, d2s, src_info, dst_info)

		local best_did = nil
		local best_sim = -1.0
		local best_dist = math.huge
		local src_desc_size = math.max(0, (si.size or 1) - 1)
		for _, did in ipairs(candidates) do
			local sim = dice_similarity(sid, did, s2d, d2s, src_info, dst_info)
			local dsi = dst_info[did]
			local dst_desc_size = math.max(0, (dsi and dsi.size or 1) - 1)
			local threshold = _opts.bu_minsim
			if threshold == nil then
				threshold = 1.0 / (1.0 + math.log(src_desc_size + dst_desc_size + 1))
			end
			local dist = math.huge
			local sp = si.parent_id
			local dp = dsi and dsi.parent_id or nil
			if sp and dp and s2d[sp] == dp then
				local spos = child_position(sp, sid, src_info)
				local dpos = child_position(dp, did, dst_info)
				if spos and dpos then
					dist = math.abs(spos - dpos)
				end
			end
			local better = false
			if sim > best_sim then
				better = true
			elseif sim == best_sim and dist < best_dist then
				better = true
			end
			if better and sim >= threshold then
				best_sim = sim
				best_dist = dist
				best_did = did
			end
		end

		if best_did then
			simple_recovery(sid, best_did, s2d, d2s, src_info, dst_info, mappings)
			if
				not s2d[sid]
				and not d2s[best_did]
				and pair_parent_consistent(sid, best_did, s2d, d2s, src_info, dst_info)
			then
				s2d[sid] = best_did
				d2s[best_did] = sid
				table.insert(mappings, { src = sid, dst = best_did })
			end
		end

		::continue::
	end

	mappings = prune_inconsistent_mappings(mappings, src_info, dst_info)
	return mappings
end

M._simple_recovery = simple_recovery
M._prune_mappings = prune_inconsistent_mappings

return M
