
local M = {}

local function compute_changed_lines(src_text, dst_text)
	local hunks = vim.diff(src_text, dst_text, { result_type = "indices" })

	local src_changed = {}
	local dst_changed = {}

	for _, hunk in ipairs(hunks) do
		local s_start, s_count, d_start, d_count = hunk[1], hunk[2], hunk[3], hunk[4]
		for i = s_start, s_start + s_count - 1 do
			src_changed[i] = true
		end
		for i = d_start, d_start + d_count - 1 do
			dst_changed[i] = true
		end
	end

	return src_changed, dst_changed
end

local function nodes_by_line(info)
	local by_line = {}
	for id, v in pairs(info) do
		if v.start_row ~= nil then
			local line = v.start_row + 1  -- convert 0-indexed to 1-indexed
			by_line[line] = by_line[line] or {}
			table.insert(by_line[line], id)
		end
	end
	for _, ids in pairs(by_line) do
		table.sort(ids, function(a, b)
			local ca = info[a].start_col or 0
			local cb = info[b].start_col or 0
			if ca == cb then
				return tostring(a) < tostring(b)
			end
			return ca < cb
		end)
	end
	return by_line
end

local function build_line_mapping(src_lines, dst_lines, src_changed, dst_changed)
	local src_unchanged = {}  -- { {line=, text=}, ... }
	for i, text in ipairs(src_lines) do
		if not src_changed[i] then
			table.insert(src_unchanged, { line = i, text = text })
		end
	end

	local dst_unchanged = {}
	for i, text in ipairs(dst_lines) do
		if not dst_changed[i] then
			table.insert(dst_unchanged, { line = i, text = text })
		end
	end

	local line_map = {}
	local di = 1
	for _, src_entry in ipairs(src_unchanged) do
		while di <= #dst_unchanged do
			if dst_unchanged[di].text == src_entry.text then
				line_map[src_entry.line] = dst_unchanged[di].line
				di = di + 1
				break
			end
			di = di + 1
		end
	end

	return line_map
end

function M.prematch_unchanged(src_info, dst_info, src_buf, dst_buf)
	local src_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
	local dst_lines = vim.api.nvim_buf_get_lines(dst_buf, 0, -1, false)

	local src_text = table.concat(src_lines, "\n") .. "\n"
	local dst_text = table.concat(dst_lines, "\n") .. "\n"

	local src_changed, dst_changed = compute_changed_lines(src_text, dst_text)

	local line_map = build_line_mapping(src_lines, dst_lines, src_changed, dst_changed)

	local src_by_line = nodes_by_line(src_info)
	local dst_by_line = nodes_by_line(dst_info)

	local mappings = {}
	local s2d = {}
	local d2s = {}

	local sorted_lines = {}
	for src_line in pairs(line_map) do
		table.insert(sorted_lines, src_line)
	end
	table.sort(sorted_lines)

	for _, src_line in ipairs(sorted_lines) do
		local dst_line = line_map[src_line]
		local src_nodes = src_by_line[src_line] or {}
		local dst_nodes = dst_by_line[dst_line] or {}

		local dst_lookup = {}
		for _, did in ipairs(dst_nodes) do
			local di = dst_info[did]
			if di and not d2s[did] then
				local key = di.type .. ":" .. tostring(di.start_col or 0)
				dst_lookup[key] = dst_lookup[key] or {}
				table.insert(dst_lookup[key], did)
			end
		end

		for _, sid in ipairs(src_nodes) do
			if not s2d[sid] then
				local si = src_info[sid]
				if si then
					local key = si.type .. ":" .. tostring(si.start_col or 0)
					local candidates = dst_lookup[key]
					if candidates and #candidates > 0 then
						local did = table.remove(candidates, 1)
						s2d[sid] = did
						d2s[did] = sid
						table.insert(mappings, { src = sid, dst = did })
					end
				end
			end
		end
	end

	return mappings
end

return M
