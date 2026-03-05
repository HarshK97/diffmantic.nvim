
local M = {}

local compute_hunks
local word_diff_cols
local clamp_non_empty_range
local make_range
local line_len
local local_to_abs_range
local full_node_range
local should_use_full_token_hunk

local FULL_TOKEN_TYPES = {
	identifier = true,
	field_identifier = true,
	type_identifier = true,
	preproc_arg = true,
	string_literal = true,
	number_literal = true,
	char_literal = true,
}


function M.enrich(actions, opts)
	opts = opts or {}
	local src_buf = opts.src_buf
	local dst_buf = opts.dst_buf

	for _, action in ipairs(actions) do
		if action.type == "update" and action.src_node and action.dst_node then
			local ok_src, src_text = pcall(vim.treesitter.get_node_text, action.src_node, src_buf)
			local ok_dst, dst_text = pcall(vim.treesitter.get_node_text, action.dst_node, dst_buf)

			if ok_src and ok_dst and src_text and dst_text then
				local hunks = compute_hunks(src_text, dst_text, action, src_buf, dst_buf)
				action.analysis = { hunks = hunks }
			else
				action.analysis = { hunks = {} }
			end
		end
	end
end

line_len = function(lines, idx)
	local line = lines[idx] or ""
	return #line
end

clamp_non_empty_range = function(range, lines)
	if not range then
		return nil
	end
	range.start_row = range.start_row or 0
	range.end_row = range.end_row or range.start_row
	range.start_col = range.start_col or 0
	if range.end_col == nil then
		local rel_end = (range.end_row - range.start_row) + 1
		range.end_col = line_len(lines or {}, rel_end)
	end
	if range.start_row == range.end_row and range.end_col <= range.start_col then
		range.end_col = range.start_col + 1
	end
	return range
end

make_range = function(start_row, end_row, start_col, end_col, lines)
	return clamp_non_empty_range({
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
	}, lines)
end

local_to_abs_range = function(base_row, base_col, local_start_row, local_end_row, local_start_col, local_end_col, lines)
	local abs_start_row = base_row + local_start_row
	local abs_end_row = base_row + local_end_row
	local abs_start_col = local_start_col + (local_start_row == 0 and base_col or 0)
	local abs_end_col = local_end_col + (local_end_row == 0 and base_col or 0)
	return make_range(abs_start_row, abs_end_row, abs_start_col, abs_end_col, lines)
end

full_node_range = function(node, text)
	if not node then
		return nil
	end
	local sr, sc, er, ec = node:range()
	return make_range(sr, er, sc, ec, vim.split(text or "", "\n", { plain = true }))
end

should_use_full_token_hunk = function(action, src_text, dst_text)
	local node_type = action and action.metadata and action.metadata.node_type or nil
	if node_type and FULL_TOKEN_TYPES[node_type] then
		return true
	end
	if src_text:find("\n", 1, true) or dst_text:find("\n", 1, true) then
		return false
	end
	local function is_word_like(s)
		return s:match("^[%a_][%w_]*$") ~= nil
			or s:match("^%d+$") ~= nil
			or s:match("^\"[^\"]*\"$") ~= nil
			or s:match("^'[^']*'$") ~= nil
	end
	return is_word_like(src_text) and is_word_like(dst_text)
end

compute_hunks = function(src_text, dst_text, action, _src_buf, _dst_buf)
	local hunks = {}

	if should_use_full_token_hunk(action, src_text, dst_text) then
		local src_range = full_node_range(action.src_node, src_text)
		local dst_range = full_node_range(action.dst_node, dst_text)
		if src_range and dst_range then
			table.insert(hunks, {
				kind = "change",
				src = src_range,
				dst = dst_range,
			})
		end
		return hunks
	end

	local ok, diff_result = pcall(vim.diff, src_text, dst_text, {
		algorithm     = "histogram",
		result_type   = "indices",
		ignore_whitespace = false,
	})

	if not ok or not diff_result then
		if src_text ~= dst_text then
			local sr, sc, ser, sec = 0, 0, 0, 1
			local dr, dc, der, dec = 0, 0, 0, 1
			if action.src_node then
				sr, sc, ser, sec = action.src_node:range()
			end
			if action.dst_node then
				dr, dc, der, dec = action.dst_node:range()
			end
			table.insert(hunks, {
				kind = "change",
				src = make_range(sr, ser, sc, sec, vim.split(src_text, "\n", { plain = true })),
				dst = make_range(dr, der, dc, dec, vim.split(dst_text, "\n", { plain = true })),
			})
		end
		return hunks
	end

	local src_lines = vim.split(src_text, "\n", { plain = true })
	local dst_lines = vim.split(dst_text, "\n", { plain = true })

	local src_base_row, src_base_col = 0, 0
	local dst_base_row, dst_base_col = 0, 0
	if action.src_node then
		src_base_row, src_base_col = action.src_node:start()
		src_base_row = src_base_row or 0
		src_base_col = src_base_col or 0
	end
	if action.dst_node then
		dst_base_row, dst_base_col = action.dst_node:start()
		dst_base_row = dst_base_row or 0
		dst_base_col = dst_base_col or 0
	end

	for _, hunk in ipairs(diff_result) do
		local src_s, src_c, dst_s, dst_c = hunk[1], hunk[2], hunk[3], hunk[4]

		local rel_src_start = src_s - 1
		local rel_src_end   = src_s + src_c - 2
		local rel_dst_start = dst_s - 1
		local rel_dst_end   = dst_s + dst_c - 2

		if src_c == 0 and dst_c > 0 then
			local dst_end_col = line_len(dst_lines, dst_s + dst_c - 1)
			table.insert(hunks, {
				kind = "insert",
				src = nil,
				dst = local_to_abs_range(
					dst_base_row, dst_base_col,
					rel_dst_start, rel_dst_end,
					0, dst_end_col,
					dst_lines
				),
			})
		elseif dst_c == 0 and src_c > 0 then
			local src_end_col = line_len(src_lines, src_s + src_c - 1)
			table.insert(hunks, {
				kind = "delete",
				src = local_to_abs_range(
					src_base_row, src_base_col,
					rel_src_start, rel_src_end,
					0, src_end_col,
					src_lines
				),
				dst = nil,
			})
		else
			local src_col_s = 0
			local src_col_e = line_len(src_lines, src_s + src_c - 1)
			local dst_col_s = 0
			local dst_col_e = line_len(dst_lines, dst_s + dst_c - 1)
			if src_c == 1 and dst_c == 1 then
				local sl = src_lines[src_s] or ""
				local dl = dst_lines[dst_s] or ""
				src_col_s, src_col_e, dst_col_s, dst_col_e = word_diff_cols(sl, dl)
			end
			table.insert(hunks, {
				kind = "change",
				src = local_to_abs_range(
					src_base_row, src_base_col,
					rel_src_start, rel_src_end,
					src_col_s, src_col_e,
					src_lines
				),
				dst = local_to_abs_range(
					dst_base_row, dst_base_col,
					rel_dst_start, rel_dst_end,
					dst_col_s, dst_col_e,
					dst_lines
				),
			})
		end
	end

	return hunks
end

word_diff_cols = function(s, d)
	local plen = 0
	local slen = #s
	local dlen = #d
	while plen < slen and plen < dlen and s:sub(plen+1, plen+1) == d:sub(plen+1, plen+1) do
		plen = plen + 1
	end
	local suflen = 0
	while suflen < (slen - plen) and suflen < (dlen - plen)
		and s:sub(slen - suflen, slen - suflen) == d:sub(dlen - suflen, dlen - suflen) do
		suflen = suflen + 1
	end
	local sc_s = plen
	local sc_e = slen - suflen
	local dc_s = plen
	local dc_e = dlen - suflen
	if sc_e <= sc_s then sc_e = slen end
	if dc_e <= dc_s then dc_e = dlen end
	return sc_s, sc_e, dc_s, dc_e
end

return M
