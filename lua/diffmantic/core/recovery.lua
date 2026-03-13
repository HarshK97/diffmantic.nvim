
local bottom_up_mod = require("diffmantic.core.bottom_up")
local simple_recovery = bottom_up_mod._simple_recovery
local prune_mappings = bottom_up_mod._prune_mappings

local M = {}


local function build_maps(mappings)
	local s2d, d2s = {}, {}
	for _, m in ipairs(mappings) do
		s2d[m.src] = m.dst
		d2s[m.dst] = m.src
	end
	return s2d, d2s
end

local function dedupe_mappings(mappings)
	local out = {}
	local seen = {}
	for _, m in ipairs(mappings or {}) do
		local key = tostring(m.src) .. "|" .. tostring(m.dst)
		if not seen[key] then
			seen[key] = true
			table.insert(out, m)
		end
	end
	return out
end

local function mapping_signature(mappings)
	local keys = {}
	local seen = {}
	for _, m in ipairs(mappings or {}) do
		local key = tostring(m.src) .. "|" .. tostring(m.dst)
		if not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return table.concat(keys, ";")
end

local function has_unmapped_src_desc(node, s2d, src_info)
	for child in node:iter_children() do
		local cid = child:id()
		if src_info[cid] then
			if not s2d[cid] then return true end
			if has_unmapped_src_desc(child, s2d, src_info) then return true end
		end
	end
	return false
end


function M.recovery_match(_src_root, _dst_root, mappings, src_info, dst_info,
                           _src_buf, _dst_buf, _opts)
	_opts = _opts or {}
	local max_passes = _opts.recovery_max_passes or 6
	mappings = dedupe_mappings(mappings)
	local prev_sig = mapping_signature(mappings)

	for _ = 1, max_passes do
		local s2d, d2s = build_maps(mappings)

		local snapshot = {}
		for _, m in ipairs(mappings) do
			table.insert(snapshot, m)
		end

		for _, m in ipairs(snapshot) do
			local sid = m.src
			local did = m.dst
			local si  = src_info[sid]
			local di  = dst_info[did]
			if si and di and si.node and di.node then
				if has_unmapped_src_desc(si.node, s2d, src_info) then
					simple_recovery(sid, did, s2d, d2s, src_info, dst_info, mappings)
				end
			end
		end

		mappings = dedupe_mappings(mappings)
		if prune_mappings then
			mappings = prune_mappings(mappings, src_info, dst_info)
			mappings = dedupe_mappings(mappings)
		end

		local next_sig = mapping_signature(mappings)
		if next_sig == prev_sig then
			break
		end
		prev_sig = next_sig
	end

	return mappings
end

return M
