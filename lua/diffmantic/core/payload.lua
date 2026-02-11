local semantic = require("diffmantic.core.semantic")

local M = {}
local RENDER_UPDATE_TOKENS = true

local function node_range(node)
	if not node then
		return nil
	end
	local ok, sr, sc, er, ec = pcall(function()
		return node:range()
	end)
	if not ok then
		return nil
	end
	return sr, sc, er, ec
end

local function inclusive_end_row(sr, er, ec)
	if er < sr then
		return sr
	end
	if er == sr then
		return sr
	end
	if ec == 0 then
		return er - 1
	end
	return er
end

local function line_text(buf, row)
	local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
	return lines[1] or ""
end

local function append_span(spans, row, start_col, end_col, hl_group, buf)
	if row < 0 or end_col <= start_col then
		return false
	end

	local text = line_text(buf, row)
	local safe_start = math.max(start_col, 0)
	local safe_end = math.min(end_col, #text)
	if safe_end <= safe_start then
		return false
	end

	local segment = text:sub(safe_start + 1, safe_end)
	local first = segment:find("%S")
	if not first then
		return false
	end
	local rev_last = segment:reverse():find("%S")
	local last = #segment - rev_last + 1

	table.insert(spans, {
		row = row,
		start_col = safe_start + first - 1,
		end_row = row,
		end_col = safe_start + last,
		hl_group = hl_group,
	})
	return true
end

local function append_sign(signs, row, text, hl_group)
	if row == nil or row < 0 then
		return
	end
	if not text or text == "" then
		return
	end
	table.insert(signs, {
		row = row,
		col = 0,
		text = text,
		hl_group = hl_group,
	})
end

local function append_virt(virt, row, col, text, hl_group, pos)
	if row == nil or row < 0 then
		return
	end
	table.insert(virt, {
		row = row,
		col = col or 0,
		text = text,
		hl_group = hl_group or "Comment",
		pos = pos or "eol",
	})
end

local function append_node_tokens(spans, buf, node, hl_group, opts)
	local sr, sc, er, ec = node_range(node)
	if not sr then
		return false
	end

	local first_line_only = opts and opts.first_line_only or false
	local end_row = first_line_only and sr or inclusive_end_row(sr, er, ec)
	local highlighted = false

	for row = sr, end_row do
		local text = line_text(buf, row)
		local start_col = (row == sr) and sc or 0
		local end_col
		if first_line_only then
			end_col = #text
		elseif row == end_row then
			if er == sr then
				end_col = ec
			elseif row == er then
				end_col = ec
			else
				end_col = #text
			end
		else
			end_col = #text
		end
		highlighted = append_span(spans, row, start_col, end_col, hl_group, buf) or highlighted
	end

	return highlighted
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

local function unmatched_token_spans(tokens, matched, line_text_value)
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
					gap = line_text_value:sub(gap_start, gap_end)
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

local function build_internal_diff(src_node, dst_node, src_buf, dst_buf, rename_map, only_changes)
	local src_text = vim.treesitter.get_node_text(src_node, src_buf)
	local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
	if not src_text or not dst_text or src_text == "" or dst_text == "" then
		return nil
	end

	local src_lines = vim.split(src_text, "\n", { plain = true })
	local dst_lines = vim.split(dst_text, "\n", { plain = true })

	local ok, hunks = pcall(vim.text.diff, src_text, dst_text, {
		result_type = "indices",
		linematch = 60,
	})

	local sr, sc = src_node:range()
	local tr, tc = dst_node:range()

	local out = {
		src_spans = {},
		dst_spans = {},
		src_signs = {},
		dst_signs = {},
	}

	local function base_col_for_row(row, start_row, start_col)
		if row == start_row then
			return start_col
		end
		return 0
	end

	local function mark_line_tokens(buf, side_spans, row, line_value, base_col, hl_group)
		if row < 0 or not line_value then
			return false
		end
		local first = line_value:find("%S")
		if not first then
			return false
		end
		local rev_last = line_value:reverse():find("%S")
		local last = #line_value - rev_last + 1
		return append_span(side_spans, row, base_col + first - 1, base_col + last, hl_group, buf)
	end

	local function highlight_line_pair(src_row, dst_row, s_line, d_line)
		local src_base = base_col_for_row(src_row, sr, sc)
		local dst_base = base_col_for_row(dst_row, tr, tc)

		if s_line and d_line and s_line ~= d_line then
			local tokens_src = tokenize_line(s_line)
			local tokens_dst = tokenize_line(d_line)
			if #tokens_src > 0 or #tokens_dst > 0 then
				local match_src, match_dst = lcs_matches(tokens_src, tokens_dst, rename_map)
				local did_src = false
				local did_dst = false

				for _, span in ipairs(unmatched_token_spans(tokens_src, match_src, s_line)) do
					did_src = append_span(
						out.src_spans,
						src_row,
						src_base + span.start_col - 1,
						src_base + span.end_col,
						"DiffChangeText",
						src_buf
					) or did_src
				end

				for _, span in ipairs(unmatched_token_spans(tokens_dst, match_dst, d_line)) do
					did_dst = append_span(
						out.dst_spans,
						dst_row,
						dst_base + span.start_col - 1,
						dst_base + span.end_col,
						"DiffChangeText",
						dst_buf
					) or did_dst
				end

				if did_src then
					append_sign(out.src_signs, src_row, "U", "DiffChangeText")
				end
				if did_dst then
					append_sign(out.dst_signs, dst_row, "U", "DiffChangeText")
				end
				return did_src or did_dst
			end

			local fragment = semantic.diff_fragment(s_line, d_line)
			if fragment then
				local did = false
				did = append_span(
					out.src_spans,
					src_row,
					src_base + fragment.old_start - 1,
					src_base + fragment.old_end,
					"DiffChangeText",
					src_buf
				) or did
				did = append_span(
					out.dst_spans,
					dst_row,
					dst_base + fragment.new_start - 1,
					dst_base + fragment.new_end,
					"DiffChangeText",
					dst_buf
				) or did
				append_sign(out.src_signs, src_row, "U", "DiffChangeText")
				append_sign(out.dst_signs, dst_row, "U", "DiffChangeText")
				return did
			end

			return false
		end

		if s_line and not d_line then
			if only_changes then
				return false
			end
			local did = mark_line_tokens(src_buf, out.src_spans, src_row, s_line, src_base, "DiffDeleteText")
			append_sign(out.src_signs, src_row, "-", "DiffDeleteText")
			return did
		elseif d_line and not s_line then
			if only_changes then
				return false
			end
			local did = mark_line_tokens(dst_buf, out.dst_spans, dst_row, d_line, dst_base, "DiffAddText")
			append_sign(out.dst_signs, dst_row, "+", "DiffAddText")
			return did
		end

		return false
	end

	local did_highlight = false
	if ok and hunks and #hunks > 0 then
		for _, h in ipairs(hunks) do
			local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
			local overlap = math.min(count_a, count_b)

			for i = 0, overlap - 1 do
				local src_row = sr + start_a - 1 + i
				local dst_row = tr + start_b - 1 + i
				local s_line = src_lines[start_a + i]
				local d_line = dst_lines[start_b + i]
				if highlight_line_pair(src_row, dst_row, s_line, d_line) then
					did_highlight = true
				end
			end

			if count_a > overlap and not only_changes then
				for i = overlap, count_a - 1 do
					local src_row = sr + start_a - 1 + i
					local s_line = src_lines[start_a + i]
					local src_base = base_col_for_row(src_row, sr, sc)
					append_sign(out.src_signs, src_row, "-", "DiffDeleteText")
					did_highlight = mark_line_tokens(src_buf, out.src_spans, src_row, s_line, src_base, "DiffDeleteText")
						or did_highlight
				end
			end

			if count_b > overlap and not only_changes then
				for i = overlap, count_b - 1 do
					local dst_row = tr + start_b - 1 + i
					local d_line = dst_lines[start_b + i]
					local dst_base = base_col_for_row(dst_row, tr, tc)
					append_sign(out.dst_signs, dst_row, "+", "DiffAddText")
					did_highlight = mark_line_tokens(dst_buf, out.dst_spans, dst_row, d_line, dst_base, "DiffAddText")
						or did_highlight
				end
			end
		end
	else
		local max_lines = math.max(#src_lines, #dst_lines)
		for i = 1, max_lines do
			local src_row = sr + i - 1
			local dst_row = tr + i - 1
			local s_line = src_lines[i]
			local d_line = dst_lines[i]
			if highlight_line_pair(src_row, dst_row, s_line, d_line) then
				did_highlight = true
			end
		end
	end

	if did_highlight or #out.src_spans > 0 or #out.dst_spans > 0 then
		return out
	end
	return nil
end

local function append_change_leaf(render, src_buf, dst_buf, src_node, dst_node, src_text, dst_text)
	local sr, sc, er, ec = node_range(src_node)
	local tr, tc, ter, tec = node_range(dst_node)
	if not sr or not tr then
		return false
	end

	local highlighted = false
	local fragment = semantic.diff_fragment(src_text or "", dst_text or "")
	if fragment and er == sr and ter == tr then
		local src_start = sc + math.max(fragment.old_start - 1, 0)
		local src_end = sc + math.max(fragment.old_end, 0)
		local dst_start = tc + math.max(fragment.new_start - 1, 0)
		local dst_end = tc + math.max(fragment.new_end, 0)

		highlighted = append_span(render.src_spans, sr, src_start, src_end, "DiffChangeText", src_buf) or highlighted
		highlighted = append_span(render.dst_spans, tr, dst_start, dst_end, "DiffChangeText", dst_buf) or highlighted
	else
		highlighted = append_node_tokens(render.src_spans, src_buf, src_node, "DiffChangeText", nil) or highlighted
		highlighted = append_node_tokens(render.dst_spans, dst_buf, dst_node, "DiffChangeText", nil) or highlighted
	end

	append_sign(render.src_signs, sr, "U", "DiffChangeText")
	append_sign(render.dst_signs, tr, "U", "DiffChangeText")

	return highlighted
end

function M.enrich(actions, opts)
	local src_buf = opts and opts.src_buf or nil
	local dst_buf = opts and opts.dst_buf or nil
	if not src_buf or not dst_buf then
		return
	end

	local rename_map = {}
	local rename_src_nodes = {}
	local rename_dst_nodes = {}

	for _, action in ipairs(actions) do
		if action.type == "rename" then
			if action.from and action.to then
				rename_map[action.from] = action.to
			end
			if action.src_node then
				rename_src_nodes[action.src_node:id()] = true
			end
			if action.dst_node then
				rename_dst_nodes[action.dst_node:id()] = true
			end
		end
	end

	for _, action in ipairs(actions) do
		local src_node = action.src_node
		local dst_node = action.dst_node
		local render = {
			src_spans = {},
			dst_spans = {},
			src_signs = {},
			dst_signs = {},
			src_virt = {},
			dst_virt = {},
		}
		local touched = false

		if action.type == "move" and src_node and dst_node then
			local sr, sc = node_range(src_node)
			local tr, tc = node_range(dst_node)
			local src_line = action.lines and action.lines.from_line or (sr and sr + 1 or nil)
			local dst_line = action.lines and action.lines.to_line or (tr and tr + 1 or nil)

			touched = append_node_tokens(render.src_spans, src_buf, src_node, "DiffMoveText", nil) or touched
			touched = append_node_tokens(render.dst_spans, dst_buf, dst_node, "DiffMoveText", nil) or touched

			if sr and sc then
				append_sign(render.src_signs, sr, "M", "DiffMoveText")
				append_virt(
					render.src_virt,
					sr,
					sc,
					string.format(" ⤷ moved L%d → L%d", src_line or 0, dst_line or 0),
					"Comment",
					"eol"
				)
				touched = true
			end
			if tr and tc then
				append_sign(render.dst_signs, tr, "M", "DiffMoveText")
				append_virt(render.dst_virt, tr, tc, string.format(" ⤶ from L%d", src_line or 0), "Comment", "eol")
				touched = true
			end
		elseif action.type == "rename" and src_node and dst_node then
			local sr, _, _, sec = node_range(src_node)
			local tr, _, _, tec = node_range(dst_node)

			touched = append_node_tokens(render.src_spans, src_buf, src_node, "DiffRenameText", nil) or touched
			touched = append_node_tokens(render.dst_spans, dst_buf, dst_node, "DiffRenameText", nil) or touched

			if sr and sec and action.to then
				append_sign(render.src_signs, sr, "R", "DiffRenameText")
				append_virt(render.src_virt, sr, sec, " -> " .. action.to, "Comment", "inline")
				touched = true
			end
			if tr and tec and action.from then
				append_sign(render.dst_signs, tr, "R", "DiffRenameText")
				append_virt(render.dst_virt, tr, tec, string.format(" (was %s)", action.from), "Comment", "inline")
				touched = true
			end
		elseif action.type == "update" and src_node and dst_node and RENDER_UPDATE_TOKENS then
			local leaf_changes = action.semantic and action.semantic.leaf_changes or nil
			local rename_pairs = action.semantic and action.semantic.rename_pairs or {}
			local did_leaf_highlight = false

			if leaf_changes and #leaf_changes > 0 then
				for _, change in ipairs(leaf_changes) do
					local change_src = change.src_node
					local change_dst = change.dst_node
					if change_src and change_dst and change.src_text ~= change.dst_text then
						local src_id = change_src:id()
						local dst_id = change_dst:id()
						local is_rename = rename_src_nodes[src_id]
							or rename_dst_nodes[dst_id]
							or (change.src_text and rename_pairs[change.src_text] == change.dst_text)
							or (change.src_text and rename_map[change.src_text] == change.dst_text)
						if not is_rename then
							local highlighted = append_change_leaf(
								render,
								src_buf,
								dst_buf,
								change_src,
								change_dst,
								change.src_text,
								change.dst_text
							)
							did_leaf_highlight = highlighted or did_leaf_highlight
							touched = highlighted or touched
						end
					end
				end
			end

			if not did_leaf_highlight then
				local diff_ops = build_internal_diff(src_node, dst_node, src_buf, dst_buf, rename_map, false)
				if diff_ops then
					for _, span in ipairs(diff_ops.src_spans) do
						table.insert(render.src_spans, span)
					end
					for _, span in ipairs(diff_ops.dst_spans) do
						table.insert(render.dst_spans, span)
					end
					for _, sign in ipairs(diff_ops.src_signs) do
						table.insert(render.src_signs, sign)
					end
					for _, sign in ipairs(diff_ops.dst_signs) do
						table.insert(render.dst_signs, sign)
					end
					touched = true
				end
			end
		elseif action.type == "delete" and src_node then
			touched = append_node_tokens(render.src_spans, src_buf, src_node, "DiffDeleteText", nil) or touched
			local sr = node_range(src_node)
			if sr then
				append_sign(render.src_signs, sr, "-", "DiffDeleteText")
				touched = true
			end
		elseif action.type == "insert" and dst_node then
			touched = append_node_tokens(render.dst_spans, dst_buf, dst_node, "DiffAddText", nil) or touched
			local tr = node_range(dst_node)
			if tr then
				append_sign(render.dst_signs, tr, "+", "DiffAddText")
				touched = true
			end
		end

		if touched then
			action.render = render
		end
	end
end

return M
