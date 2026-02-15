local M = {}

local VIRT_LINE_LEN = 300

local function make_virt_line(hl_group, char)
	return { { string.rep(char or "╱", VIRT_LINE_LEN), hl_group } }
end

local function line_count(range)
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

local function trailing_blanks(buf, range)
	if not buf or not range or range.end_row == nil then
		return 0
	end

	local last_occupied = range.end_row
	if (range.end_col or 0) == 0 then
		last_occupied = last_occupied - 1
	end
	if last_occupied < (range.start_row or 0) then
		last_occupied = range.start_row or 0
	end

	local buf_lines = vim.api.nvim_buf_line_count(buf)
	local row = last_occupied + 1
	local count = 0

	while row < buf_lines do
		local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
		local line = lines[1] or ""
		if line:match("^%s*$") then
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

local function ensure_lines(entry, count, default_hl)
	for i = #entry.lines + 1, count do
		entry.lines[i] = default_hl
	end
end

local function mark_lines(entry, start_idx, count, hl_group)
	if not entry or start_idx == nil or count == nil or count <= 0 then
		return
	end
	ensure_lines(entry, start_idx + count - 1, "DiffmanticMoveFiller")
	for i = start_idx, start_idx + count - 1 do
		entry.lines[i] = hl_group
	end
end

local function add_simple(fillers, row, count, hl_group)
	if row == nil or count == nil or count <= 0 or not hl_group then
		return
	end
	table.insert(fillers, {
		row = row,
		count = count,
		hl_group = hl_group,
	})
end

local function coalesce_simple(fillers)
	local simple = {}
	local rich = {}
	for _, filler in ipairs(fillers) do
		if filler.lines then
			table.insert(rich, filler)
		else
			table.insert(simple, filler)
		end
	end

	table.sort(simple, function(a, b)
		return a.row < b.row
	end)

	local merged = {}
	for _, filler in ipairs(simple) do
		local prev = merged[#merged]
		if prev and prev.hl_group == filler.hl_group and filler.row <= (prev.row + prev.count) then
			local prev_end = prev.row + prev.count
			local this_end = filler.row + filler.count
			prev.count = math.max(prev_end, this_end) - prev.row
		else
			table.insert(merged, {
				row = filler.row,
				count = filler.count,
				hl_group = filler.hl_group,
			})
		end
	end

	for _, filler in ipairs(rich) do
		table.insert(merged, filler)
	end

	table.sort(merged, function(a, b)
		return a.row < b.row
	end)
	return merged
end

local function count_filler_lines_before(fillers, row)
	if row == nil or not fillers then
		return 0
	end
	local total = 0
	for _, filler in ipairs(fillers) do
		if filler.row and filler.row < row then
			if filler.lines then
				total = total + (filler.base_count or #filler.lines)
			elseif filler.count then
				total = total + filler.count
			end
		end
	end
	return total
end

local function find_move_region_for_src(move_regions, src_range)
	if not src_range then
		return nil
	end
	for _, region in ipairs(move_regions) do
		if range_within(src_range, region.src) then
			return region
		end
	end
	return nil
end

local function find_move_region_for_dst(move_regions, dst_range)
	if not dst_range then
		return nil
	end
	for _, region in ipairs(move_regions) do
		if range_within(dst_range, region.dst) then
			return region
		end
	end
	return nil
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
		local count = line_count(range)
		local current = runs[#runs]
		if current and range.start_row <= (current.end_row + 1) then
			current.end_row = math.max(current.end_row, range.end_row)
			current.count = current.count + count
		else
			table.insert(runs, {
				start_row = range.start_row,
				end_row = range.end_row,
				start_col = range.start_col,
				end_col = range.end_col,
				count = count,
			})
		end
	end
	return runs
end

local function range_from_run(run)
	return {
		start_row = run.start_row,
		start_col = run.start_col or 0,
		end_row = run.end_row,
		end_col = run.end_col or 1,
	}
end

local function move_anchor_after_blank_run(buf, row)
	if not buf or row == nil or row < 0 then
		return row
	end
	local max_row = vim.api.nvim_buf_line_count(buf) - 1
	local cursor = math.min(row, max_row)

	while cursor <= max_row do
		local lines = vim.api.nvim_buf_get_lines(buf, cursor, cursor + 1, false)
		local line = lines[1] or ""
		if line:match("^%s*$") then
			cursor = cursor + 1
		else
			break
		end
	end

	if cursor > max_row then
		return row
	end
	return cursor
end

function M.compute(actions, src_buf, dst_buf)
	local src_fillers = {}
	local dst_fillers = {}
	local move_regions = {}

	for _, action in ipairs(actions) do
		if action.type == "move" and action.src and action.dst then
			local src_base_count = line_count(action.src)
			local dst_base_count = line_count(action.dst)
			local src_count = src_base_count + trailing_blanks(src_buf, action.src)
			local dst_count = dst_base_count + trailing_blanks(dst_buf, action.dst)

			local src_entry = {
				row = action.dst.start_row,
				lines = {},
				base_count = dst_base_count,
			}
			ensure_lines(src_entry, dst_count, "DiffmanticMoveFiller")

			local dst_entry = {
				row = action.src.start_row,
				lines = {},
				base_count = src_base_count,
			}
			ensure_lines(dst_entry, src_count, "DiffmanticMoveFiller")

			table.insert(src_fillers, src_entry)
			table.insert(dst_fillers, dst_entry)

			table.insert(move_regions, {
				src = action.src,
				dst = action.dst,
				src_entry = src_entry,
				dst_entry = dst_entry,
			})
		end
	end

	for _, action in ipairs(actions) do
		if action.type == "insert" and action.dst then
			local count = line_count(action.dst)
			if count > 0 then
				local region = find_move_region_for_dst(move_regions, action.dst)
				if region then
					local start_idx = (action.dst.start_row - region.dst.start_row) + 1
					mark_lines(region.src_entry, start_idx, count, "DiffmanticAddFiller")
				else
					add_simple(src_fillers, action.dst.start_row, count, "DiffmanticAddFiller")
				end
			end
		elseif action.type == "delete" and action.src then
			local count = line_count(action.src)
			if count > 0 then
				local region = find_move_region_for_src(move_regions, action.src)
				if region then
					local start_idx = (action.src.start_row - region.src.start_row) + 1
					mark_lines(region.dst_entry, start_idx, count, "DiffmanticDeleteFiller")
				else
					add_simple(dst_fillers, action.src.start_row, count, "DiffmanticDeleteFiller")
				end
			end
		elseif action.type == "update" and action.src and action.dst and action.analysis and action.analysis.hunks then
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
				local run_range = range_from_run(run)
				local dst_move_region = find_move_region_for_dst(move_regions, run_range)
				if dst_move_region then
					local start_idx = (run.start_row - dst_move_region.dst.start_row) + 1
					mark_lines(dst_move_region.src_entry, start_idx, run.count, "DiffmanticAddFiller")
				else
					local anchor = action.src.start_row + math.max(0, run.start_row - action.dst.start_row)
					local deleted_before = 0
					for _, d in ipairs(delete_runs) do
						if d.start_row <= anchor then
							deleted_before = deleted_before + d.count
						end
					end
					anchor = anchor + deleted_before
					add_simple(src_fillers, anchor, run.count, "DiffmanticAddFiller")
				end
			end

			for _, run in ipairs(delete_runs) do
				local run_range = range_from_run(run)
				local src_move_region = find_move_region_for_src(move_regions, run_range)
				if src_move_region then
					local start_idx = (run.start_row - src_move_region.src.start_row) + 1
					mark_lines(src_move_region.dst_entry, start_idx, run.count, "DiffmanticDeleteFiller")
				else
					local anchor = action.dst.start_row + math.max(0, run.start_row - action.src.start_row)
					local inserted_before = 0
					for _, ins in ipairs(insert_runs) do
						if ins.start_row <= anchor then
							inserted_before = inserted_before + ins.count
						end
					end
					anchor = anchor + inserted_before
					add_simple(dst_fillers, anchor, run.count, "DiffmanticDeleteFiller")
				end
			end
		end
	end

	for _, region in ipairs(move_regions) do
		region.src_entry.row = region.src_entry.row + count_filler_lines_before(dst_fillers, region.src_entry.row)
		region.dst_entry.row = region.dst_entry.row + count_filler_lines_before(src_fillers, region.dst_entry.row)
		region.dst_entry.row = move_anchor_after_blank_run(dst_buf, region.dst_entry.row)
	end

	return coalesce_simple(src_fillers), coalesce_simple(dst_fillers)
end

function M.apply(buf, ns, fillers)
	if not fillers or #fillers == 0 then
		return
	end

	local line_count_buf = vim.api.nvim_buf_line_count(buf)
	for _, filler in ipairs(fillers) do
		local row = filler.row
		if row >= line_count_buf then
			row = line_count_buf - 1
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
