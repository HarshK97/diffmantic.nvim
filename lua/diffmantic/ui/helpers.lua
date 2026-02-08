local semantic = require("diffmantic.core.semantic")

local M = {}

M.find_leaf_changes = semantic.find_leaf_changes
M.node_in_field = semantic.node_in_field
M.is_rename_identifier = semantic.is_rename_identifier
M.is_value_node = semantic.is_value_node
M.classify_text_change = semantic.classify_text_change
M.diff_fragment = semantic.diff_fragment

function M.set_inline_virt_text(buf, ns, row, col, text, hl)
	local opts = {
		virt_text = { { text, hl } },
		virt_text_pos = "inline",
	}
	local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
	if ok then
		return
	end
	opts.virt_text_pos = "eol"
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

function M.highlight_internal_diff(src_node, dst_node, src_buf, dst_buf, ns, opts)
	local src_text = vim.treesitter.get_node_text(src_node, src_buf)
	local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
	if not src_text or not dst_text or src_text == "" or dst_text == "" then
		return false
	end

	local src_lines = vim.split(src_text, "\n", { plain = true })
	local dst_lines = vim.split(dst_text, "\n", { plain = true })

	local ok, hunks = pcall(vim.text.diff, src_text, dst_text, {
		result_type = "indices",
		linematch = 60,
	})

	local sr, _, er, _ = src_node:range()
	local tr, _, ter, _ = dst_node:range()
	local src_end = er - 1
	local dst_end = ter - 1
	local signs_src = opts and opts.signs_src or nil
	local signs_dst = opts and opts.signs_dst or nil
	local rename_map = opts and opts.rename_map or nil

	local function mark_fragment(buf, row, start_col, end_col, hl_group)
		if row < 0 or end_col <= start_col then
			return false
		end
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, start_col, {
			end_row = row,
			end_col = end_col,
			hl_group = hl_group,
		})
	end

	local function mark_sign(buf, row, text, hl_group, sign_rows)
		if row < 0 then
			return false
		end
		if sign_rows and sign_rows[row] then
			return false
		end
		local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
			sign_text = text,
			sign_hl_group = hl_group,
		})
		if ok and sign_rows then
			sign_rows[row] = true
		end
		return ok
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

	local function tokens_equal(a, b)
		if a.text == b.text then
			return true
		end
		if rename_map and rename_map[a.text] == b.text then
			return true
		end
		return false
	end

	local function lcs_matches(a, b)
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
				if tokens_equal(a[i], b[j]) then
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
			if tokens_equal(a[i], b[j]) then
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

	local function mark_full_line(buf, row, hl_group)
		if row < 0 then
			return false
		end
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
			end_row = row + 1,
			end_col = 0,
			hl_group = hl_group,
			hl_eol = true,
		})
	end

	local function highlight_line_pair(src_row, dst_row, s_line, d_line)
		if s_line and d_line and s_line ~= d_line then
			local tokens_src = tokenize_line(s_line)
			local tokens_dst = tokenize_line(d_line)
			if #tokens_src > 0 or #tokens_dst > 0 then
				local match_src, match_dst = lcs_matches(tokens_src, tokens_dst)
				local did_src = false
				local did_dst = false
				if src_row <= src_end then
					for i, tok in ipairs(tokens_src) do
						if not match_src[i] then
							did_src = mark_fragment(src_buf, src_row, tok.start_col - 1, tok.end_col, "DiffChangeText") or did_src
						end
					end
					if did_src then
						mark_sign(src_buf, src_row, "U", "DiffChangeText", signs_src)
					end
				end
				if dst_row <= dst_end then
					for i, tok in ipairs(tokens_dst) do
						if not match_dst[i] then
							did_dst = mark_fragment(dst_buf, dst_row, tok.start_col - 1, tok.end_col, "DiffChangeText") or did_dst
						end
					end
					if did_dst then
						mark_sign(dst_buf, dst_row, "U", "DiffChangeText", signs_dst)
					end
				end
				if did_src or did_dst then
					return true
				end
				return false
			end
			local fragment = M.diff_fragment(s_line, d_line)
			if fragment then
				local did = false
				if src_row <= src_end then
					did = mark_fragment(src_buf, src_row, fragment.old_start - 1, fragment.old_end, "DiffChangeText") or did
					mark_sign(src_buf, src_row, "U", "DiffChangeText", signs_src)
				end
				if dst_row <= dst_end then
					did = mark_fragment(dst_buf, dst_row, fragment.new_start - 1, fragment.new_end, "DiffChangeText") or did
					mark_sign(dst_buf, dst_row, "U", "DiffChangeText", signs_dst)
				end
				return did
			end
			local did = false
			if src_row <= src_end then
				did = mark_full_line(src_buf, src_row, "DiffChangeText") or did
				mark_sign(src_buf, src_row, "U", "DiffChangeText", signs_src)
			end
			if dst_row <= dst_end then
				did = mark_full_line(dst_buf, dst_row, "DiffChangeText") or did
				mark_sign(dst_buf, dst_row, "U", "DiffChangeText", signs_dst)
			end
			return did
		end
		if s_line and not d_line then
			if src_row <= src_end then
				mark_sign(src_buf, src_row, "-", "DiffDeleteText", signs_src)
				return mark_full_line(src_buf, src_row, "DiffDeleteText")
			end
		elseif d_line and not s_line then
			if dst_row <= dst_end then
				mark_sign(dst_buf, dst_row, "+", "DiffAddText", signs_dst)
				return mark_full_line(dst_buf, dst_row, "DiffAddText")
			end
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

			if count_a > overlap then
				for i = overlap, count_a - 1 do
					local src_row = sr + start_a - 1 + i
					if src_row <= src_end then
						mark_sign(src_buf, src_row, "-", "DiffDeleteText", signs_src)
						did_highlight = mark_full_line(src_buf, src_row, "DiffDeleteText") or did_highlight
					end
				end
			end

			if count_b > overlap then
				for i = overlap, count_b - 1 do
					local dst_row = tr + start_b - 1 + i
					if dst_row <= dst_end then
						mark_sign(dst_buf, dst_row, "+", "DiffAddText", signs_dst)
						did_highlight = mark_full_line(dst_buf, dst_row, "DiffAddText") or did_highlight
					end
				end
			end
		end

		return did_highlight
	end

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

	return did_highlight
end

return M
