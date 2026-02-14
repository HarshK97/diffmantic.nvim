local M = {}

local VIRT_LINE_LEN = 300

local function make_virt_line(hl_group, char)
	return { { string.rep(char or "╱", VIRT_LINE_LEN), hl_group } }
end

local function span_line_count(range)
	if not range then
		return 0
	end
	local sr = range.start_row
	local er = range.end_row
	local ec = range.end_col
	if sr == nil or er == nil or ec == nil then
		return 0
	end
	local count = er - sr
	if ec > 0 then
		count = count + 1
	end
	if count <= 0 then
		count = 1
	end
	return count
end

local function line_trim_bounds(line)
	if not line then
		return nil, nil
	end
	local first = line:find("%S")
	if not first then
		return nil, nil
	end
	local rev_last = line:reverse():find("%S")
	local last = #line - rev_last + 1
	return first - 1, last
end

local function is_whole_line_span(buf, range)
	if not range then
		return false
	end
	if range.start_row == nil or range.end_row == nil then
		return false
	end
	if range.start_row ~= range.end_row then
		return true
	end
	local row = range.start_row
	local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
	local line = lines[1] or ""
	local first_col, last_col_exclusive = line_trim_bounds(line)
	if not first_col then
		return false
	end
	return range.start_col <= first_col and range.end_col >= last_col_exclusive
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

local function range_within(inner, outer)
	if not inner or not outer then
		return false
	end
	if inner.start_row == nil or inner.end_row == nil or inner.start_col == nil or inner.end_col == nil then
		return false
	end
	if outer.start_row == nil or outer.end_row == nil or outer.start_col == nil or outer.end_col == nil then
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

local function add_filler(dst_list, seen, row, count, hl_group)
	if row == nil or count == nil or count <= 0 or not hl_group then
		return
	end
	local key = table.concat({ tostring(row), tostring(count), hl_group }, ":")
	if seen[key] then
		return
	end
	seen[key] = true
	table.insert(dst_list, {
		row = row,
		count = count,
		hl_group = hl_group,
	})
end

local function mirror_dst_row_into_src(update_src, update_dst, dst_row)
	if not update_src or not update_dst or dst_row == nil then
		return dst_row
	end
	local offset = math.max(0, dst_row - update_dst.start_row)
	return update_src.start_row + offset
end

local function mirror_src_row_into_dst(update_src, update_dst, src_row)
	if not update_src or not update_dst or src_row == nil then
		return src_row
	end
	local offset = math.max(0, src_row - update_src.start_row)
	return update_dst.start_row + offset
end

local function collect_runs(ranges)
	if not ranges or #ranges == 0 then
		return {}
	end
	table.sort(ranges, function(a, b)
		return a.start_row < b.start_row
	end)
	local runs = {}
	for _, range in ipairs(ranges) do
		local count = span_line_count(range)
		local current = runs[#runs]
		if current and range.start_row <= (current.end_row + 1) then
			current.end_row = math.max(current.end_row, range.end_row)
			current.count = current.count + count
		else
			table.insert(runs, {
				start_row = range.start_row,
				end_row = range.end_row,
				count = count,
			})
		end
	end
	return runs
end

function M.compute(actions, src_buf, dst_buf)
	local src_fillers = {}
	local dst_fillers = {}
	local seen_src = {}
	local seen_dst = {}
	local move_src_ranges = {}
	local move_dst_ranges = {}

	for _, action in ipairs(actions) do
		if action.type == "move" then
			local src = action.src or action.src_range
			local dst = action.dst or action.dst_range
			if src then
				table.insert(move_src_ranges, src)
			end
			if dst then
				table.insert(move_dst_ranges, dst)
			end
		end
	end

	local function inside_move_src(range)
		if not range then
			return false
		end
		for _, moved in ipairs(move_src_ranges) do
			if range_within(range, moved) then
				return true
			end
		end
		return false
	end

	local function inside_move_dst(range)
		if not range then
			return false
		end
		for _, moved in ipairs(move_dst_ranges) do
			if range_within(range, moved) then
				return true
			end
		end
		return false
	end

	for _, action in ipairs(actions) do
		local t = action.type
		local src = action.src or action.src_range
		local dst = action.dst or action.dst_range

		if t == "insert" and dst and dst.start_row ~= nil then
			if inside_move_dst(dst) then
				goto continue
			end
			if not is_whole_line_span(dst_buf, dst) then
				goto continue
			end
			local count = span_line_count(dst)
			if count >= 1 then
				add_filler(src_fillers, seen_src, dst.start_row, count, "DiffmanticAddFiller")
			end
		elseif t == "delete" and src and src.start_row ~= nil then
			if inside_move_src(src) then
				goto continue
			end
			if not is_whole_line_span(src_buf, src) then
				goto continue
			end
			local count = span_line_count(src)
			if count >= 1 then
				add_filler(dst_fillers, seen_dst, src.start_row, count, "DiffmanticDeleteFiller")
			end
		elseif t == "move" and action.src_node and action.dst_node then
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
		elseif t == "update" and action.analysis and action.analysis.hunks then
			local update_src = action.src or action.src_range
			local update_dst = action.dst or action.dst_range
			local move_related_update = inside_move_src(update_src) or inside_move_dst(update_dst)
			if move_related_update then
				goto continue
			end

			local insert_ranges = {}
			local delete_ranges = {}
			for _, hunk in ipairs(action.analysis.hunks) do
				if hunk.kind == "insert" and hunk.dst then
					table.insert(insert_ranges, hunk.dst)
				elseif hunk.kind == "delete" and hunk.src then
					table.insert(delete_ranges, hunk.src)
				end
			end

			local insert_runs = collect_runs(insert_ranges)
			local delete_runs = collect_runs(delete_ranges)

			for _, run in ipairs(insert_runs) do
				local anchor = mirror_dst_row_into_src(update_src, update_dst, run.start_row)
				local deleted_before = 0
				for _, d in ipairs(delete_runs) do
					if d.start_row <= anchor then
						deleted_before = deleted_before + d.count
					end
				end
				anchor = anchor + deleted_before
				add_filler(src_fillers, seen_src, anchor, run.count, "DiffmanticAddFiller")
			end

			for _, run in ipairs(delete_runs) do
				local anchor = mirror_src_row_into_dst(update_src, update_dst, run.start_row)
				local inserted_before = 0
				for _, ins in ipairs(insert_runs) do
					if ins.start_row <= anchor then
						inserted_before = inserted_before + ins.count
					end
				end
				anchor = anchor + inserted_before
				add_filler(dst_fillers, seen_dst, anchor, run.count, "DiffmanticDeleteFiller")
			end
		end
		::continue::
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
