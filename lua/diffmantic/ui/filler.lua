local M = {}

local VIRT_LINE_LEN = 300

local function make_virt_line(hl_group, char)
	return { { string.rep(char or "╱", VIRT_LINE_LEN), hl_group } }
end

local function trailing_blanks(buf, end_row, end_col)
	local last_occupied = end_col > 0 and end_row or (end_row - 1)
	local buf_count = vim.api.nvim_buf_line_count(buf)
	local count = 0
	local row = last_occupied + 1
	while row < buf_count do
		local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
		if lines[1] and lines[1]:match("^%s*$") then
			count = count + 1
			row = row + 1
		else
			break
		end
	end
	return count
end

local function is_top_level(node)
	if not node then
		return false
	end
	local parent = node:parent()
	return parent ~= nil and parent:parent() == nil
end

function M.compute(actions, src_buf, dst_buf)
	local src_fillers = {}
	local dst_fillers = {}

	for _, action in ipairs(actions) do
		local t = action.type

		if t == "insert" and action.dst_node and is_top_level(action.dst_node) then
			local sr, _, er, ec = action.dst_node:range()
			local count = er - sr
			if ec > 0 then
				count = count + 1
			end
			count = count + trailing_blanks(dst_buf, er, ec)
			if count > 0 then
				table.insert(src_fillers, {
					row = sr,
					count = count,
					hl_group = "DiffmanticAddFiller",
				})
			end
		elseif t == "delete" and action.src_node and is_top_level(action.src_node) then
			local sr, _, er, ec = action.src_node:range()
			local count = er - sr
			if ec > 0 then
				count = count + 1
			end
			count = count + trailing_blanks(src_buf, er, ec)
			if count > 0 then
				table.insert(dst_fillers, {
					row = sr,
					count = count,
					hl_group = "DiffmanticDeleteFiller",
				})
			end
		elseif t == "move" and action.src_node and action.dst_node and is_top_level(action.src_node) then
			local ssr, _, ser, sec = action.src_node:range()
			local src_body = ser - ssr
			if sec > 0 then
				src_body = src_body + 1
			end
			local src_trailing = trailing_blanks(src_buf, ser, sec)
			local src_count = src_body + src_trailing

			local dsr, _, der, dec = action.dst_node:range()
			local dst_body = der - dsr
			if dec > 0 then
				dst_body = dst_body + 1
			end
			local dst_trailing = trailing_blanks(dst_buf, der, dec)
			local dst_count = dst_body + dst_trailing

			local src_text = vim.treesitter.get_node_text(action.src_node, src_buf)
			local dst_text = vim.treesitter.get_node_text(action.dst_node, dst_buf)
			local ok, hunks = pcall(vim.text.diff, src_text, dst_text, {
				result_type = "indices",
				linematch = 60,
			})

			local dst_inserted = {}
			local src_deleted = {}
			if ok and hunks then
				for _, h in ipairs(hunks) do
					local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
					local overlap = math.min(count_a, count_b)
					if count_b > overlap then
						for i = start_b + overlap, start_b + count_b - 1 do
							dst_inserted[i] = true
						end
					end
					if count_a > overlap then
						for i = start_a + overlap, start_a + count_a - 1 do
							src_deleted[i] = true
						end
					end
				end
			end

			if dst_count > 0 then
				local lines = {}
				for i = 1, dst_body do
					lines[i] = dst_inserted[i] and "DiffmanticAddFiller" or "DiffmanticMoveFiller"
				end
				for i = dst_body + 1, dst_count do
					lines[i] = "DiffmanticMoveFiller"
				end
				table.insert(src_fillers, {
					row = dsr,
					lines = lines,
				})
			end

			if src_count > 0 then
				local src_block_end = sec > 0 and (ser + 1) or ser
				local best_dst_row = nil
				local best_src_row = math.huge
				for _, other in ipairs(actions) do
					if other ~= action and other.src_node and other.dst_node then
						local osr = select(1, other.src_node:range())
						local odr = select(1, other.dst_node:range())
						if osr >= src_block_end and osr < best_src_row then
							best_src_row = osr
							best_dst_row = odr
						end
					end
				end
				if best_dst_row then
					local lines = {}
					for i = 1, src_body do
						lines[i] = src_deleted[i] and "DiffmanticDeleteFiller" or "DiffmanticMoveFiller"
					end
					for i = src_body + 1, src_count do
						lines[i] = "DiffmanticMoveFiller"
					end
					table.insert(dst_fillers, {
						row = best_dst_row,
						lines = lines,
					})
				end
			end
		end
	end

	table.sort(src_fillers, function(a, b)
		return a.row < b.row
	end)
	table.sort(dst_fillers, function(a, b)
		return a.row < b.row
	end)

	return src_fillers, dst_fillers
end

function M.apply(buf, ns, fillers)
	if not fillers or #fillers == 0 then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)

	for _, filler in ipairs(fillers) do
		local row = filler.row
		if row >= line_count then
			row = line_count - 1
		end
		if row < 0 then
			row = 0
		end

		local virt_lines = {}
		if filler.lines then
			for i, hl in ipairs(filler.lines) do
				virt_lines[i] = make_virt_line(hl)
			end
		else
			for i = 1, filler.count do
				virt_lines[i] = make_virt_line(filler.hl_group)
			end
		end

		pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
			virt_lines = virt_lines,
			virt_lines_above = true,
		})
	end
end

return M
