local M = {}
local hunk_utils = require("diffmantic.ui.hunks")
local VIRT_LINE_LEN = 300
local HL_ADD = "DiffmanticAddFiller"
local HL_DELETE = "DiffmanticDeleteFiller"
local HL_MOVE = "DiffmanticMoveFiller"

local function make_virt_line(hl_group)
	return { { string.rep("╱", VIRT_LINE_LEN), hl_group } }
end

--- Return the number of lines a range spans (1-indexed count).
local function line_span(range)
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

local function ranges_equal(a, b)
	if not a or not b then
		return false
	end
	return a.start_row == b.start_row
		and a.start_col == b.start_col
		and a.end_row == b.end_row
		and a.end_col == b.end_col
end

local function ranges_related(a, b)
	return ranges_equal(a, b) or range_contains(a, b) or range_contains(b, a)
end

local function hl_for_type(action_type)
	if action_type == "insert" then
		return HL_ADD
	elseif action_type == "delete" then
		return HL_DELETE
	end
	return HL_MOVE
end

local function clamp_row(row, line_count)
	row = tonumber(row) or 0
	if row < 0 then
		return 0
	end
	if row > line_count then
		return line_count
	end
	return row
end

local function count_trailing_blank_lines(buf, range)
	if not buf or not range or range.end_row == nil then
		return 0
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count <= 0 then
		return 0
	end
	local row = range.end_row + 1
	if row < 0 then
		row = 0
	end
	if row >= line_count then
		return 0
	end
	local lines = vim.api.nvim_buf_get_lines(buf, row, line_count, false)
	local count = 0
	for _, line in ipairs(lines) do
		if line:match("^%s*$") then
			count = count + 1
		else
			break
		end
	end
	return count
end

local function count_leading_blank_lines(buf, range)
	if not buf or not range or range.start_row == nil then
		return 0
	end
	local row = range.start_row - 1
	if row < 0 then
		return 0
	end
	local count = 0
	while row >= 0 do
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		if line:match("^%s*$") then
			count = count + 1
			row = row - 1
		else
			break
		end
	end
	return count
end

local function padding_mode_for_buf(buf)
	if not buf then
		return "default"
	end
	local ft = vim.bo[buf] and vim.bo[buf].filetype or ""
	if ft == "python" then
		return "python_bottom"
	end
	return "default"
end

local function normalize_move_padding(leading, trailing, mode)
	leading = math.max(0, tonumber(leading) or 0)
	trailing = math.max(0, tonumber(trailing) or 0)
	local gap = math.max(leading, trailing)
	if gap <= 0 then
		return 0, 0
	end
	if leading > 0 and trailing == 0 then
		local top = math.floor((gap + 1) / 2)
		local bottom = gap - top
		return top, bottom
	end
	if mode == "python_bottom" then
		return 0, gap
	end
	local top = math.floor(gap / 2)
	local bottom = gap - top
	return top, bottom
end

local function style_priority(style)
	if not style then
		return -1
	end
	if style.transparent then
		return 0
	end
	local hl = style.hl_group
	if hl == HL_ADD or hl == HL_DELETE then
		return 2
	end
	if hl == HL_MOVE then
		return 1
	end
	return 1
end

local function merge_style(existing, candidate)
	if not existing then
		return {
			hl_group = candidate.hl_group,
			transparent = candidate.transparent or false,
		}
	end
	if candidate.transparent then
		return existing
	end
	if existing.transparent then
		return {
			hl_group = candidate.hl_group,
			transparent = false,
		}
	end
	if style_priority(candidate) >= style_priority(existing) then
		return {
			hl_group = candidate.hl_group,
			transparent = false,
		}
	end
	return existing
end

local function ensure_entry(side_rows, row)
	local entry = side_rows[row]
	if entry then
		return entry
	end
	entry = {
		row = row,
		line_styles = {},
	}
	side_rows[row] = entry
	return entry
end

local function find_first_group(line_styles, group)
	for idx, style in ipairs(line_styles or {}) do
		if style and not style.transparent and style.hl_group == group then
			return idx
		end
	end
	return nil
end

local function find_last_group(line_styles, group)
	local last = nil
	for idx, style in ipairs(line_styles or {}) do
		if style and not style.transparent and style.hl_group == group then
			last = idx
		end
	end
	return last
end

local function add_filler_lines(side_rows, row, count, opts)
	count = tonumber(count) or 0
	if count <= 0 then
		return
	end
	opts = opts or {}
	local entry = ensure_entry(side_rows, row)
	local line_styles = entry.line_styles
	local candidate
	if opts.transparent then
		candidate = { transparent = true }
	else
		candidate = {
			hl_group = opts.hl_group or HL_MOVE,
			transparent = false,
		}
	end
	local offset = opts.offset
	if offset == nil then
		if opts.append_if_existing and not candidate.transparent then
			local insert_at = #line_styles + 1
			if candidate.hl_group == HL_ADD then
				local first_delete = find_first_group(line_styles, HL_DELETE)
				if first_delete then
					insert_at = first_delete
				end
			elseif candidate.hl_group == HL_DELETE then
				local last_add = find_last_group(line_styles, HL_ADD)
				if last_add then
					insert_at = last_add + 1
				end
			end
			for i = 1, count do
				table.insert(line_styles, insert_at + (i - 1), {
					hl_group = candidate.hl_group,
					transparent = false,
				})
			end
			return
		end
		offset = opts.append_if_existing and #line_styles or 0
	end
	if offset < 0 then
		offset = 0
	end
	for i = 1, count do
		local idx = offset + i
		local last = #line_styles
		if idx > last + 1 then
			for gap = last + 1, idx - 1 do
				line_styles[gap] = { transparent = true }
			end
		end
		line_styles[idx] = merge_style(line_styles[idx], candidate)
	end
end

local function find_containing_move(moves, target, side_key)
	for _, move in ipairs(moves) do
		local container = move[side_key]
		if range_contains(container, target) then
			return move
		end
	end
	return nil
end

local function summed_contained_span(actions, action_type, side_key, container_range)
	if not container_range then
		return 0
	end
	local total = 0
	for _, action in ipairs(actions or {}) do
		local meta = action.metadata or {}
		if action.type == action_type and not meta.render_as_change then
			local target = action[side_key]
			if range_contains(container_range, target) then
				total = total + line_span(target)
			end
		end
	end
	return total
end

local function uncovered_update_hunk_ranges(update_action, actions, kind, side_key, src_buf, dst_buf)
	local analysis = update_action and update_action.analysis or nil
	local hunks = analysis and analysis.hunks or nil
	if not hunks or #hunks == 0 then
		return {}
	end
	hunks = hunk_utils.normalize_list(hunks, src_buf, dst_buf)
	analysis.hunks = hunks
	if #hunks == 0 then
		return {}
	end
	local ranges = {}
	for _, hunk in ipairs(hunks) do
		if hunk.kind == kind and not hunk.render_as_change then
			local target = hunk[side_key]
			if target then
				local covered = false
				for _, action in ipairs(actions or {}) do
					local meta = action.metadata or {}
					if action.type == kind and not meta.render_as_change and action[side_key] then
						if ranges_related(action[side_key], target) then
							covered = true
							break
						end
					end
				end
				if not covered then
					table.insert(ranges, target)
				end
			end
		end
	end
	table.sort(ranges, function(a, b)
		if a.start_row ~= b.start_row then
			return a.start_row < b.start_row
		end
		return (a.start_col or 0) < (b.start_col or 0)
	end)
	return ranges
end

local function merge_adjacent_ranges(ranges)
	if not ranges or #ranges == 0 then
		return {}
	end
	table.sort(ranges, function(a, b)
		if a.start_row ~= b.start_row then
			return a.start_row < b.start_row
		end
		return (a.start_col or 0) < (b.start_col or 0)
	end)
	local out = {}
	local current = nil
	for _, r in ipairs(ranges) do
		if not current then
			current = {
				start_row = r.start_row,
				start_col = r.start_col,
				end_row = r.end_row,
				end_col = r.end_col,
			}
		else
			local touch_or_overlap = r.start_row <= (current.end_row + 1)
			if touch_or_overlap then
				if
					r.end_row > current.end_row
					or (r.end_row == current.end_row and (r.end_col or 0) > (current.end_col or 0))
				then
					current.end_row = r.end_row
					current.end_col = r.end_col
				end
			else
				table.insert(out, current)
				current = {
					start_row = r.start_row,
					start_col = r.start_col,
					end_row = r.end_row,
					end_col = r.end_col,
				}
			end
		end
	end
	if current then
		table.insert(out, current)
	end
	return out
end

local function is_projection_context(action)
	if not action or not action.src or not action.dst then
		return false
	end
	local atype = action.type
	if atype == "insert" or atype == "delete" or atype == "rename" or atype == "move" then
		return false
	end
	return true
end

local function is_valid_range(range)
	if not range then
		return false
	end
	if range.start_row == nil or range.start_col == nil then
		return false
	end
	if range.end_row == nil or range.end_col == nil then
		return false
	end
	return true
end

local function to_range(info)
	if not info then
		return nil
	end
	local range = {
		start_row = info.start_row,
		start_col = info.start_col,
		end_row = info.end_row,
		end_col = info.end_col,
	}
	if not is_valid_range(range) then
		return nil
	end
	return range
end

local function build_projection_contexts_from_actions(actions)
	local contexts = {}
	for _, action in ipairs(actions or {}) do
		if is_projection_context(action) then
			table.insert(contexts, {
				src = action.src,
				dst = action.dst,
			})
		end
	end
	return contexts
end

local function build_projection_contexts_from_mappings(mappings, src_info, dst_info)
	local contexts = {}
	local seen = {}
	for _, mapping in ipairs(mappings or {}) do
		local src = src_info and src_info[mapping.src] or nil
		local dst = dst_info and dst_info[mapping.dst] or nil
		if src and dst and src.parent_id ~= nil and dst.parent_id ~= nil then
			local src_node = src.node
			local dst_node = dst.node
			if src_node and dst_node and src_node:named() and dst_node:named() then
				local src_range = to_range(src)
				local dst_range = to_range(dst)
				if src_range and dst_range then
					local key = table.concat({
						src_range.start_row,
						src_range.start_col,
						src_range.end_row,
						src_range.end_col,
						"|",
						dst_range.start_row,
						dst_range.start_col,
						dst_range.end_row,
						dst_range.end_col,
					}, ":")
					if not seen[key] then
						seen[key] = true
						table.insert(contexts, {
							src = src_range,
							dst = dst_range,
						})
					end
				end
			end
		end
	end
	return contexts
end

local function sort_projection_contexts(contexts)
	table.sort(contexts, function(a, b)
		local as = (a.src and a.src.start_row) or 0
		local bs = (b.src and b.src.start_row) or 0
		if as ~= bs then
			return as < bs
		end
		local ae = (a.src and a.src.end_row) or as
		local be = (b.src and b.src.end_row) or bs
		return ae < be
	end)
	return contexts
end

local function build_projection_contexts(actions, mappings, src_info, dst_info)
	local contexts = build_projection_contexts_from_mappings(mappings, src_info, dst_info)
	if #contexts == 0 then
		contexts = build_projection_contexts_from_actions(actions)
	else
		local action_contexts = build_projection_contexts_from_actions(actions)
		for _, ctx in ipairs(action_contexts) do
			table.insert(contexts, ctx)
		end
	end
	return sort_projection_contexts(contexts)
end

local function contains_row(range, row)
	if not range or range.start_row == nil or range.end_row == nil then
		return false
	end
	return row >= range.start_row and row <= range.end_row
end

local function best_containing_context(contexts, from_key, row)
	local best = nil
	local best_span = math.huge
	for _, ctx in ipairs(contexts or {}) do
		local r = ctx[from_key]
		if contains_row(r, row) then
			local span = line_span(r)
			if span < best_span then
				best = ctx
				best_span = span
			end
		end
	end
	return best
end

local function project_within_range(from_range, to_range, row)
	if not from_range or not to_range then
		return row
	end
	local from_start = from_range.start_row or row
	local from_end = from_range.end_row or from_start
	local to_start = to_range.start_row or row
	local to_end = to_range.end_row or to_start
	local from_span = math.max(1, (from_end - from_start) + 1)
	local to_span = math.max(1, (to_end - to_start) + 1)
	if from_span == 1 or to_span == 1 then
		local rel = row - from_start
		if rel < 0 then
			rel = 0
		end
		if rel > to_span - 1 then
			rel = to_span - 1
		end
		return to_start + rel
	end
	local rel = row - from_start
	if rel < 0 then
		rel = 0
	elseif rel > from_span - 1 then
		rel = from_span - 1
	end
	local ratio = rel / (from_span - 1)
	return math.floor(to_start + (ratio * (to_span - 1)) + 0.5)
end

local function neighbor_projected_row(row, contexts, from_key, to_key, opts)
	opts = opts or {}
	local preserve_gap = opts.preserve_gap or false
	local to_buf = opts.to_buf

	local function prev_anchor(prev_to)
		if not prev_to or prev_to.end_row == nil then
			return nil
		end
		local anchor = prev_to.end_row + 1
		if preserve_gap and to_buf then
			anchor = anchor + count_trailing_blank_lines(to_buf, prev_to)
		end
		return anchor
	end

	local function next_anchor(next_to)
		if not next_to or next_to.start_row == nil then
			return nil
		end
		local anchor = next_to.start_row
		if preserve_gap and to_buf then
			anchor = anchor - count_leading_blank_lines(to_buf, next_to)
		end
		return anchor
	end

	local prev_ctx = nil
	local next_ctx = nil
	for _, ctx in ipairs(contexts) do
		local from = ctx[from_key]
		if from then
			if from.end_row and from.end_row < row then
				if not prev_ctx or from.end_row > ((prev_ctx[from_key] and prev_ctx[from_key].end_row) or -1) then
					prev_ctx = ctx
				end
			end
			if from.start_row and from.start_row > row then
				if
					not next_ctx
					or from.start_row < ((next_ctx[from_key] and next_ctx[from_key].start_row) or math.huge)
				then
					next_ctx = ctx
				end
			end
		end
	end

	local raw_row
	if prev_ctx and next_ctx then
		local prev_from = prev_ctx[from_key]
		local next_from = next_ctx[from_key]
		local prev_to = prev_ctx[to_key]
		local next_to = next_ctx[to_key]
		local prev_distance = row - (prev_from and prev_from.end_row or row)
		local next_distance = (next_from and next_from.start_row or row) - row
		if next_distance < prev_distance and next_to and next_to.start_row ~= nil then
			raw_row = next_anchor(next_to)
		elseif prev_to and prev_to.end_row ~= nil then
			raw_row = prev_anchor(prev_to)
		end
	end
	if raw_row == nil and prev_ctx and prev_ctx[to_key] and prev_ctx[to_key].end_row ~= nil then
		raw_row = prev_anchor(prev_ctx[to_key])
	elseif raw_row == nil and next_ctx and next_ctx[to_key] and next_ctx[to_key].start_row ~= nil then
		raw_row = next_anchor(next_ctx[to_key])
	elseif raw_row == nil then
		raw_row = row
	end
	return raw_row
end

local function project_row_from_contexts(row, contexts, from_key, to_key, line_count, opts)
	opts = opts or {}
	if row == nil then
		return 0
	end
	if not contexts or #contexts == 0 then
		return clamp_row(row, line_count)
	end
	local containing = nil
	if not opts.prefer_neighbors then
		containing = best_containing_context(contexts, from_key, row)
	end
	local raw_row
	if containing then
		raw_row = project_within_range(containing[from_key], containing[to_key], row)
	else
		raw_row = neighbor_projected_row(row, contexts, from_key, to_key, opts)
	end
	return clamp_row(raw_row, line_count)
end

local function move_overlaps_context(action, contexts)
	local src = action and action.src
	local dst = action and action.dst
	if not src or not dst then
		return false
	end
	for _, ctx in ipairs(contexts or {}) do
		if ranges_related(ctx.src, src) and ranges_related(ctx.dst, dst) then
			return true
		end
	end
	return false
end

local function filter_contexts_for_move_anchor(contexts, move_action)
	if not move_action then
		return contexts or {}
	end
	local out = {}
	for _, ctx in ipairs(contexts or {}) do
		local same_pair = ranges_related(ctx.src, move_action.src) and ranges_related(ctx.dst, move_action.dst)
		if not same_pair then
			table.insert(out, ctx)
		end
	end
	return out
end

local function rows_to_fillers(side_rows)
	local out = {}
	for _, entry in pairs(side_rows) do
		table.insert(out, {
			row = entry.row,
			line_styles = entry.line_styles,
		})
	end
	table.sort(out, function(a, b)
		return a.row < b.row
	end)
	return out
end

local function total_virtual_lines(side_rows)
	local total = 0
	for _, entry in pairs(side_rows) do
		total = total + #(entry.line_styles or {})
	end
	return total
end

function M.compute(actions, src_buf, dst_buf, opts)
	opts = opts or {}
	local src_line_count = src_buf and vim.api.nvim_buf_line_count(src_buf) or 0
	local dst_line_count = dst_buf and vim.api.nvim_buf_line_count(dst_buf) or 0
	local src_rows = {}
	local dst_rows = {}
	local moves = {}
	local updates = {}
	local move_layout = {}
	local src_move_events = {}
	local dst_move_events = {}
	local projection_contexts = build_projection_contexts(actions, opts.mappings, opts.src_info, opts.dst_info)

	for _, action in ipairs(actions or {}) do
		if action.type == "update" and action.analysis and action.analysis.hunks then
			action.analysis.hunks = hunk_utils.normalize_list(action.analysis.hunks, src_buf, dst_buf)
		end
		if action.type == "move" and action.src and action.dst then
			table.insert(moves, action)
			table.insert(src_move_events, action)
			table.insert(dst_move_events, action)
		elseif (action.type == "update" or action.type == "rename") and action.src and action.dst then
			table.insert(updates, action)
		end
	end

	table.sort(src_move_events, function(a, b)
		return a.dst.start_row < b.dst.start_row
	end)
	table.sort(dst_move_events, function(a, b)
		return a.src.start_row < b.src.start_row
	end)

	local src_shift = 0
	local single_src_move = #src_move_events == 1
	local src_move_padding_mode = padding_mode_for_buf(dst_buf)
	for _, action in ipairs(src_move_events) do
		local leading = count_leading_blank_lines(dst_buf, action.dst)
		local trailing = count_trailing_blank_lines(dst_buf, action.dst)
		local raw_row
		if single_src_move then
			local move_anchor_contexts = filter_contexts_for_move_anchor(projection_contexts, action)
			raw_row = project_row_from_contexts(
				action.dst.start_row,
				move_anchor_contexts,
				"dst",
				"src",
				src_line_count,
				{ preserve_gap = false, to_buf = src_buf, prefer_neighbors = true }
			)
			if leading > 0 and trailing > 0 then
				raw_row = clamp_row(raw_row + math.min(leading, trailing), src_line_count)
			end
		else
			raw_row = clamp_row(action.dst.start_row, src_line_count)
		end
		local row = raw_row - src_shift
		if row < 0 then
			row = 0
		end
		local entry = src_rows[row]
		local base_offset = entry and #(entry.line_styles or {}) or 0
		local span = line_span(action.dst)
		leading, trailing = normalize_move_padding(leading, trailing, src_move_padding_mode)
		add_filler_lines(src_rows, row, leading, { offset = base_offset, transparent = true })
		add_filler_lines(src_rows, row, span, { offset = base_offset + leading, hl_group = HL_MOVE })
		add_filler_lines(src_rows, row, trailing, { offset = base_offset + leading + span, transparent = true })
		src_shift = src_shift + leading + span + trailing
		move_layout[action] = move_layout[action] or {}
		move_layout[action].src_row = row
		move_layout[action].src_base_offset = base_offset + leading
	end

	local dst_move_padding_mode = padding_mode_for_buf(src_buf)
	for _, action in ipairs(dst_move_events) do
		local move_anchor_contexts = filter_contexts_for_move_anchor(projection_contexts, action)
		local row = project_row_from_contexts(
			action.src.start_row,
			move_anchor_contexts,
			"src",
			"dst",
			dst_line_count,
			{ preserve_gap = true, to_buf = dst_buf }
		)
		local entry = dst_rows[row]
		local base_offset = entry and #(entry.line_styles or {}) or 0
		local span = line_span(action.src)
		local leading = count_leading_blank_lines(src_buf, action.src)
		local trailing = count_trailing_blank_lines(src_buf, action.src)
		leading, trailing = normalize_move_padding(leading, trailing, dst_move_padding_mode)
		add_filler_lines(dst_rows, row, leading, { offset = base_offset, transparent = true })
		add_filler_lines(dst_rows, row, span, { offset = base_offset + leading, hl_group = HL_MOVE })
		add_filler_lines(dst_rows, row, trailing, { offset = base_offset + leading + span, transparent = true })
		move_layout[action] = move_layout[action] or {}
		move_layout[action].dst_row = row
		move_layout[action].dst_base_offset = base_offset + leading
	end

	for _, action in ipairs(actions or {}) do
		local meta = action.metadata or {}
		if meta.render_as_change then
			goto continue
		end
		local atype = action.type
		local src = action.src
		local dst = action.dst

		if atype == "insert" and dst then
			local span = line_span(dst)
			local nested_move = find_containing_move(moves, dst, "dst")
			if nested_move then
				local layout = move_layout[nested_move] or {}
				local row = layout.src_row or clamp_row(nested_move.dst.start_row, src_line_count)
				local base_offset = layout.src_base_offset or 0
				local offset = base_offset + (dst.start_row - nested_move.dst.start_row)
				add_filler_lines(src_rows, row, span, { hl_group = HL_ADD, offset = offset })
			else
				local row = project_row_from_contexts(
					dst.start_row,
					projection_contexts,
					"dst",
					"src",
					src_line_count,
					{ prefer_neighbors = true }
				)
				add_filler_lines(src_rows, row, span, { hl_group = HL_ADD, append_if_existing = true })
			end
		elseif atype == "delete" and src then
			local span = line_span(src)
			local nested_move = find_containing_move(moves, src, "src")
			if nested_move then
				local layout = move_layout[nested_move] or {}
				local row = layout.dst_row or clamp_row(nested_move.src.start_row, dst_line_count)
				local base_offset = layout.dst_base_offset or 0
				local offset = base_offset + (src.start_row - nested_move.src.start_row)
				add_filler_lines(dst_rows, row, span, { hl_group = HL_DELETE, offset = offset })
			else
				local row = project_row_from_contexts(
					src.start_row,
					projection_contexts,
					"src",
					"dst",
					dst_line_count,
					{ prefer_neighbors = true }
				)
				add_filler_lines(dst_rows, row, span, { hl_group = HL_DELETE, append_if_existing = true })
			end
		elseif (atype == "update" or atype == "rename") and src and dst then
			local overlaps_move = move_overlaps_context(action, moves)
			local src_lines = line_span(src)
			local dst_lines = line_span(dst)
			local uncovered_delete =
				merge_adjacent_ranges(uncovered_update_hunk_ranges(action, actions, "delete", "src", src_buf, dst_buf))
			local uncovered_insert =
				merge_adjacent_ranges(uncovered_update_hunk_ranges(action, actions, "insert", "dst", src_buf, dst_buf))
			local uncovered_delete_span = 0
			local uncovered_insert_span = 0

			for _, hunk_src in ipairs(uncovered_delete) do
				local span = line_span(hunk_src)
				local nested_move = overlaps_move and find_containing_move(moves, hunk_src, "src") or nil
				if nested_move then
					local layout = move_layout[nested_move] or {}
					local row = layout.dst_row or clamp_row(nested_move.src.start_row, dst_line_count)
					local base_offset = layout.dst_base_offset or 0
					local offset = base_offset + (hunk_src.start_row - nested_move.src.start_row)
					add_filler_lines(dst_rows, row, span, { hl_group = HL_DELETE, offset = offset })
				else
					local row = project_row_from_contexts(
						hunk_src.start_row,
						projection_contexts,
						"src",
						"dst",
						dst_line_count,
						{ prefer_neighbors = true }
					)
					add_filler_lines(dst_rows, row, span, { hl_group = HL_DELETE, append_if_existing = true })
				end
				uncovered_delete_span = uncovered_delete_span + span
			end

			for _, hunk_dst in ipairs(uncovered_insert) do
				local span = line_span(hunk_dst)
				local nested_move = overlaps_move and find_containing_move(moves, hunk_dst, "dst") or nil
				if nested_move then
					local layout = move_layout[nested_move] or {}
					local row = layout.src_row or clamp_row(nested_move.dst.start_row, src_line_count)
					local base_offset = layout.src_base_offset or 0
					local offset = base_offset + (hunk_dst.start_row - nested_move.dst.start_row)
					add_filler_lines(src_rows, row, span, { hl_group = HL_ADD, offset = offset })
				else
					local row = project_row_from_contexts(
						hunk_dst.start_row,
						projection_contexts,
						"dst",
						"src",
						src_line_count,
						{ prefer_neighbors = true }
					)
					add_filler_lines(src_rows, row, span, { hl_group = HL_ADD, append_if_existing = true })
				end
				uncovered_insert_span = uncovered_insert_span + span
			end

			if overlaps_move then
				goto continue
			end

			if src_lines > dst_lines then
				local delete_inside = summed_contained_span(actions, "delete", "src", src)
				local remaining = (src_lines - dst_lines) - delete_inside - uncovered_delete_span
				if remaining > 0 then
					local row = clamp_row(dst.start_row + dst_lines, dst_line_count)
					add_filler_lines(dst_rows, row, remaining, { hl_group = HL_DELETE, append_if_existing = true })
				end
			elseif dst_lines > src_lines then
				local insert_inside = summed_contained_span(actions, "insert", "dst", dst)
				local remaining = (dst_lines - src_lines) - insert_inside - uncovered_insert_span
				if remaining > 0 then
					local row = clamp_row(src.start_row + src_lines, src_line_count)
					add_filler_lines(src_rows, row, remaining, { hl_group = HL_ADD, append_if_existing = true })
				end
			end
		end
		::continue::
	end

	local src_total = total_virtual_lines(src_rows)
	local dst_total = total_virtual_lines(dst_rows)
	local src_visual = src_line_count + src_total
	local dst_visual = dst_line_count + dst_total
	if src_visual > dst_visual then
		add_filler_lines(dst_rows, dst_line_count, src_visual - dst_visual, {
			transparent = true,
			append_if_existing = true,
		})
	elseif dst_visual > src_visual then
		add_filler_lines(src_rows, src_line_count, dst_visual - src_visual, {
			transparent = true,
			append_if_existing = true,
		})
	end

	return rows_to_fillers(src_rows), rows_to_fillers(dst_rows)
end

function M.apply(buf, ns, fillers)
	if not buf or not ns or not fillers or #fillers == 0 then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count <= 0 then
		return
	end
	for _, filler in ipairs(fillers) do
		local row = clamp_row(filler.row or 0, line_count)
		local virt_lines = {}
		local line_styles = filler.line_styles
		if line_styles and #line_styles > 0 then
			for _, style in ipairs(line_styles) do
				if style and style.transparent then
					table.insert(virt_lines, {})
				else
					local hl = (style and style.hl_group) or filler.hl_group or HL_MOVE
					table.insert(virt_lines, make_virt_line(hl))
				end
			end
		else
			local count = filler.count or 0
			local hl = filler.hl_group or HL_MOVE
			for _ = 1, count do
				table.insert(virt_lines, make_virt_line(hl))
			end
		end
		if #virt_lines > 0 then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
				virt_lines = virt_lines,
				virt_lines_above = true,
			})
		end
	end
end

M._private = {
	line_span = line_span,
	range_contains = range_contains,
	clamp_row = clamp_row,
	count_trailing_blank_lines = count_trailing_blank_lines,
	count_leading_blank_lines = count_leading_blank_lines,
	summed_contained_span = summed_contained_span,
	add_filler_lines = add_filler_lines,
	total_virtual_lines = total_virtual_lines,
}

return M
