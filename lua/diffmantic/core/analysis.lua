local semantic = require("diffmantic.core.semantic")

local M = {}

local function range_metadata(node)
	if not node then
		return nil
	end
	local sr, sc, er, ec = node:range()
	return {
		start_row = sr,
		start_col = sc,
		end_row = er,
		end_col = ec,
		start_line = sr + 1,
		end_line = er + 1,
	}
end

local function clone_range(r)
	if not r then
		return nil
	end
	return {
		start_row = r.start_row,
		start_col = r.start_col,
		end_row = r.end_row,
		end_col = r.end_col,
		start_line = r.start_line,
		end_line = r.end_line,
	}
end

local function line_text(buf, row)
	local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
	return lines[1] or ""
end

local function base_col_for_row(row, start_row, start_col)
	if row == start_row then
		return start_col
	end
	return 0
end

local function tokenize_line(text)
	local tokens = {}
	local i = 1
	local len = #text
	while i <= len do
		local ch = text:sub(i, i)
		if ch:match("%s") then
			i = i + 1
		elseif ch:match("[%w_]") then
			local j = i + 1
			while j <= len and text:sub(j, j):match("[%w_]") do
				j = j + 1
			end
			table.insert(tokens, { text = text:sub(i, j - 1), start_col = i, end_col = j - 1 })
			i = j
		else
			local j = i + 1
			while j <= len and not text:sub(j, j):match("[%w_%s]") do
				j = j + 1
			end
			table.insert(tokens, { text = text:sub(i, j - 1), start_col = i, end_col = j - 1 })
			i = j
		end
	end
	return tokens
end

local function tokens_equal(a, b, rename_map)
	if a.text == b.text then
		return true
	end
	if rename_map and rename_map[a.text] == b.text then
		return true
	end
	return false
end

local function lcs_matches(a, b, rename_map)
	local n = #a
	local m = #b
	if n == 0 or m == 0 then
		return {}, {}
	end

	local dp = {}
	for i = 0, n do
		dp[i] = {}
		dp[i][0] = 0
	end
	for j = 1, m do
		dp[0][j] = 0
	end

	for i = 1, n do
		for j = 1, m do
			if tokens_equal(a[i], b[j], rename_map) then
				dp[i][j] = dp[i - 1][j - 1] + 1
			else
				local up = dp[i - 1][j]
				local left = dp[i][j - 1]
				dp[i][j] = (up >= left) and up or left
			end
		end
	end

	local match_a = {}
	local match_b = {}
	local i = n
	local j = m
	while i > 0 and j > 0 do
		if tokens_equal(a[i], b[j], rename_map) then
			match_a[i] = true
			match_b[j] = true
			i = i - 1
			j = j - 1
		else
			local up = dp[i - 1][j]
			local left = dp[i][j - 1]
			if up >= left then
				i = i - 1
			else
				j = j - 1
			end
		end
	end
	return match_a, match_b
end

local function unmatched_token_spans(tokens, matched, source_line)
	local spans = {}
	local i = 1
	while i <= #tokens do
		if matched[i] then
			i = i + 1
		else
			local start_col = tokens[i].start_col
			local end_col = tokens[i].end_col
			local j = i + 1
			while j <= #tokens and not matched[j] do
				local gap_start = end_col + 1
				local gap_end = tokens[j].start_col - 1
				local gap = ""
				if gap_start <= gap_end then
					gap = source_line:sub(gap_start, gap_end)
				end
				if gap ~= "" and not gap:match("^%s+$") then
					break
				end
				end_col = tokens[j].end_col
				j = j + 1
			end
			table.insert(spans, { start_col = start_col, end_col = end_col })
			i = j
		end
	end
	return spans
end

local function make_range(row, start_col, end_col)
	if row == nil or start_col == nil or end_col == nil or end_col <= start_col then
		return nil
	end
	return {
		start_row = row,
		start_col = start_col,
		end_row = row,
		end_col = end_col,
		start_line = row + 1,
		end_line = row + 1,
	}
end

local function trimmed_range_for_line(buf, row, base_col, line_value)
	if not line_value then
		return nil
	end
	local first = line_value:find("%S")
	if not first then
		return nil
	end
	local rev_last = line_value:reverse():find("%S")
	local last = #line_value - rev_last + 1
	return make_range(row, base_col + first - 1, base_col + last)
end

local function hunk_change(src_range, dst_range)
	return { kind = "change", src = src_range, dst = dst_range }
end

local function hunk_insert(dst_range)
	return { kind = "insert", src = nil, dst = dst_range }
end

local function hunk_delete(src_range)
	return { kind = "delete", src = src_range, dst = nil }
end

local function range_contains(outer, inner)
	if not outer or not inner then
		return false
	end
	if outer.start_row == nil or outer.end_row == nil or outer.start_col == nil or outer.end_col == nil then
		return false
	end
	if inner.start_row == nil or inner.end_row == nil or inner.start_col == nil or inner.end_col == nil then
		return false
	end
	if inner.start_row < outer.start_row or inner.end_row > outer.end_row then
		return false
	end
	if inner.start_row == outer.start_row and inner.start_col < outer.start_col then
		return false
	end
	if inner.end_row == outer.end_row and inner.end_col > outer.end_col then
		return false
	end
	return true
end

local function clone_range_like(r)
	return clone_range(r)
end

local function collect_suppressed_rename_pairs(actions)
	local pairs = {}
	local declaration_pairs = {}
	for _, action in ipairs(actions) do
		if action.type == "rename" then
			local old_name = action.metadata and action.metadata.old_name or action.from
			local new_name = action.metadata and action.metadata.new_name or action.to
			if action.context and action.context.declaration and old_name and new_name and old_name ~= new_name then
				declaration_pairs[old_name] = new_name
			end

			local suppressed = action.metadata and action.metadata.suppressed_renames or nil
			if suppressed then
				for _, usage in ipairs(suppressed) do
					local src = clone_range_like(usage.src or usage.src_range)
					local dst = clone_range_like(usage.dst or usage.dst_range)
					if src and dst then
						table.insert(pairs, { src = src, dst = dst })
					end
				end
			end
		end
	end
	return pairs, declaration_pairs
end

local function text_for_range(buf, range)
	if not buf or not range then
		return nil
	end
	if range.start_row == nil or range.end_row == nil or range.start_col == nil or range.end_col == nil then
		return nil
	end
	if range.start_row ~= range.end_row then
		return nil
	end
	local line = line_text(buf, range.start_row)
	if not line or line == "" then
		return nil
	end
	local start_col = range.start_col + 1
	local end_col = range.end_col
	if end_col < start_col then
		return nil
	end
	return line:sub(start_col, end_col)
end

local function is_suppressed_change_hunk(hunk_src, hunk_dst, suppressed_pairs, declaration_pairs, src_buf, dst_buf)
	if not hunk_src or not hunk_dst then
		return false
	end
	for _, pair in ipairs(suppressed_pairs) do
		if range_contains(hunk_src, pair.src) and range_contains(hunk_dst, pair.dst) then
			return true
		end
	end
	if declaration_pairs and next(declaration_pairs) then
		local src_text = text_for_range(src_buf, hunk_src)
		local dst_text = text_for_range(dst_buf, hunk_dst)
		if src_text and dst_text and declaration_pairs[src_text] == dst_text then
			return true
		end
	end
	return false
end

local function fallback_hunks_from_diff(src_node, dst_node, src_buf, dst_buf, rename_pairs)
	local src_text = vim.treesitter.get_node_text(src_node, src_buf)
	local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
	if not src_text or not dst_text then
		return {}
	end

	local src_lines = vim.split(src_text, "\n", { plain = true })
	local dst_lines = vim.split(dst_text, "\n", { plain = true })
	local ok, hunks = pcall(vim.text.diff, src_text, dst_text, {
		result_type = "indices",
		linematch = 60,
	})
	if not ok or not hunks then
		return {}
	end

	local rename_map = rename_pairs or {}
	local sr, sc = src_node:range()
	local tr, tc = dst_node:range()
	local out = {}

	local function push_change_line(src_row, dst_row, src_line, dst_line)
		local src_base = base_col_for_row(src_row, sr, sc)
		local dst_base = base_col_for_row(dst_row, tr, tc)
		if not src_line or not dst_line or src_line == dst_line then
			return
		end

		local tokens_src = tokenize_line(src_line)
		local tokens_dst = tokenize_line(dst_line)
		if #tokens_src > 0 or #tokens_dst > 0 then
			local match_src, match_dst = lcs_matches(tokens_src, tokens_dst, rename_map)
			local src_spans = unmatched_token_spans(tokens_src, match_src, src_line)
			local dst_spans = unmatched_token_spans(tokens_dst, match_dst, dst_line)
			local count = math.min(#src_spans, #dst_spans)
			for i = 1, count do
				local src_range = make_range(
					src_row,
					src_base + src_spans[i].start_col - 1,
					src_base + src_spans[i].end_col
				)
				local dst_range = make_range(
					dst_row,
					dst_base + dst_spans[i].start_col - 1,
					dst_base + dst_spans[i].end_col
				)
				if src_range and dst_range then
					table.insert(out, hunk_change(src_range, dst_range))
				end
			end
			return
		end

		local fragment = semantic.diff_fragment(src_line, dst_line)
		if fragment then
			local src_range = make_range(
				src_row,
				src_base + math.max(fragment.old_start - 1, 0),
				src_base + math.max(fragment.old_end, 0)
			)
			local dst_range = make_range(
				dst_row,
				dst_base + math.max(fragment.new_start - 1, 0),
				dst_base + math.max(fragment.new_end, 0)
			)
			if src_range and dst_range then
				table.insert(out, hunk_change(src_range, dst_range))
			end
			return
		end

		local src_range = trimmed_range_for_line(src_buf, src_row, src_base, src_line)
		local dst_range = trimmed_range_for_line(dst_buf, dst_row, dst_base, dst_line)
		if src_range and dst_range then
			table.insert(out, hunk_change(src_range, dst_range))
		end
	end

	for _, h in ipairs(hunks) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		local overlap = math.min(count_a, count_b)

		for i = 0, overlap - 1 do
			local src_row = sr + start_a - 1 + i
			local dst_row = tr + start_b - 1 + i
			push_change_line(src_row, dst_row, src_lines[start_a + i], dst_lines[start_b + i])
		end

		for i = overlap, count_a - 1 do
			local src_row = sr + start_a - 1 + i
			local src_line = src_lines[start_a + i]
			local src_base = base_col_for_row(src_row, sr, sc)
			local src_range = trimmed_range_for_line(src_buf, src_row, src_base, src_line)
			if src_range then
				table.insert(out, hunk_delete(src_range))
			end
		end

		for i = overlap, count_b - 1 do
			local dst_row = tr + start_b - 1 + i
			local dst_line = dst_lines[start_b + i]
			local dst_base = base_col_for_row(dst_row, tr, tc)
			local dst_range = trimmed_range_for_line(dst_buf, dst_row, dst_base, dst_line)
			if dst_range then
				table.insert(out, hunk_insert(dst_range))
			end
		end
	end

	return out
end

function M.enrich(actions, opts)
	local src_buf = opts and opts.src_buf or nil
	local dst_buf = opts and opts.dst_buf or nil
	if not src_buf or not dst_buf then
		return
	end
	local suppressed_pairs, declaration_pairs = collect_suppressed_rename_pairs(actions)

	for _, action in ipairs(actions) do
		if action.type == "update" and action.src_node and action.dst_node then
			local raw_leaf_changes = action.analysis and action.analysis.leaf_changes or {}
			local rename_pairs = action.analysis and action.analysis.rename_pairs or {}
			local normalized_leaf = {}
			local hunks = {}

			for _, change in ipairs(raw_leaf_changes) do
				local src_range = range_metadata(change.src_node)
				local dst_range = range_metadata(change.dst_node)
				table.insert(normalized_leaf, {
					src = clone_range(src_range),
					dst = clone_range(dst_range),
					src_text = change.src_text,
					dst_text = change.dst_text,
				})

				if change.src_text ~= change.dst_text and rename_pairs[change.src_text] ~= change.dst_text then
					local hunk_src = src_range
					local hunk_dst = dst_range

					if
						src_range
						and dst_range
						and src_range.start_row == src_range.end_row
						and dst_range.start_row == dst_range.end_row
					then
						local fragment = semantic.diff_fragment(change.src_text or "", change.dst_text or "")
						if fragment then
							hunk_src = make_range(
								src_range.start_row,
								src_range.start_col + math.max(fragment.old_start - 1, 0),
								src_range.start_col + math.max(fragment.old_end, 0)
							)
							hunk_dst = make_range(
								dst_range.start_row,
								dst_range.start_col + math.max(fragment.new_start - 1, 0),
								dst_range.start_col + math.max(fragment.new_end, 0)
							)
						end
					end

					if
						hunk_src
						and hunk_dst
						and not is_suppressed_change_hunk(
							hunk_src,
							hunk_dst,
							suppressed_pairs,
							declaration_pairs,
							src_buf,
							dst_buf
						)
					then
						table.insert(hunks, hunk_change(hunk_src, hunk_dst))
					end
				end
			end

			if #hunks == 0 then
				hunks = fallback_hunks_from_diff(action.src_node, action.dst_node, src_buf, dst_buf, rename_pairs)
			end
			if #suppressed_pairs > 0 and #hunks > 0 then
				local filtered = {}
				for _, hunk in ipairs(hunks) do
					if
						hunk.kind ~= "change"
						or not is_suppressed_change_hunk(
							hunk.src,
							hunk.dst,
							suppressed_pairs,
							declaration_pairs,
							src_buf,
							dst_buf
						)
					then
						table.insert(filtered, hunk)
					end
				end
				hunks = filtered
			end

			action.analysis = {
				leaf_changes = normalized_leaf,
				rename_pairs = rename_pairs,
				hunks = hunks,
			}
		end
	end
end

return M
