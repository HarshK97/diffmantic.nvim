local signs = require("diffmantic.ui.signs")
local filler = require("diffmantic.ui.filler")

local M = {}

local HL_PRIORITY = {
	DiffmanticMove = 10,
	DiffmanticAdd = 20,
	DiffmanticDelete = 20,
	DiffmanticChange = 30,
	DiffmanticChangeAccent = 35,
	DiffmanticRename = 40,
}

local function set_extmark(buf, ns, row, col, opts)
	if opts and opts.hl_group and not opts.priority then
		opts.priority = HL_PRIORITY[opts.hl_group] or 20
	end
	return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

local function apply_span(buf, ns, range, hl_group)
	if not range or not hl_group then
		return
	end
	local sr = range.start_row
	local sc = range.start_col
	local er = range.end_row or sr
	local ec = range.end_col
	if sr == nil or sc == nil or ec == nil then
		return
	end
	if sr == er and ec <= sc then
		ec = sc + 1
	end
	set_extmark(buf, ns, sr, sc, {
		end_row = er,
		end_col = ec,
		hl_group = hl_group,
	})
end

local function apply_sign(buf, ns, row, text, hl_group, seen_rows)
	if row == nil or not text or not hl_group then
		return
	end
	signs.mark(buf, ns, row, 0, text, hl_group, seen_rows)
end

local function ranges_overlap(a, b)
	if not a or not b then
		return false
	end
	if a.start_row == nil or a.end_row == nil or a.start_col == nil or a.end_col == nil then
		return false
	end
	if b.start_row == nil or b.end_row == nil or b.start_col == nil or b.end_col == nil then
		return false
	end
	if a.end_row < b.start_row or b.end_row < a.start_row then
		return false
	end
	if a.start_row == b.end_row and a.start_col >= b.end_col then
		return false
	end
	if b.start_row == a.end_row and b.start_col >= a.end_col then
		return false
	end
	return true
end

local function overlaps_any(range, ranges)
	if not range or not ranges then
		return false
	end
	for _, candidate in ipairs(ranges) do
		if ranges_overlap(range, candidate) then
			return true
		end
	end
	return false
end

local function apply_virt(buf, ns, row, col, text, hl_group, pos)
	if row == nil or not text then
		return
	end
	local opts = {
		virt_text = { { text, hl_group or "Comment" } },
		virt_text_pos = pos or "eol",
	}
	local ok = set_extmark(buf, ns, row, col or 0, opts)
	if not ok and opts.virt_text_pos == "inline" then
		opts.virt_text_pos = "eol"
		set_extmark(buf, ns, row, col or 0, opts)
	end
end

local TYPE_STYLE = {
	move = { hl = "DiffmanticMove", sign = "M" },
	rename = { hl = "DiffmanticRename", sign = "R" },
	update = { hl = "DiffmanticChange", sign = "U" },
	insert = { hl = "DiffmanticAdd", sign = "+" },
	delete = { hl = "DiffmanticDelete", sign = "-" },
}

local HUNK_STYLE = {
	change = {
		src_hl = "DiffmanticChange",
		dst_hl = "DiffmanticChange",
		src_sign = "U",
		dst_sign = "U",
	},
	insert = {
		src_hl = nil,
		dst_hl = "DiffmanticAdd",
		src_sign = nil,
		dst_sign = "+",
	},
	delete = {
		src_hl = "DiffmanticDelete",
		dst_hl = nil,
		src_sign = "-",
		dst_sign = nil,
	},
}

local function range_text(buf, range)
	if not buf or not range then
		return nil
	end
	if range.start_row == nil or range.end_row == nil or range.start_col == nil or range.end_col == nil then
		return nil
	end
	if range.start_row ~= range.end_row then
		return nil
	end
	local line = vim.api.nvim_buf_get_lines(buf, range.start_row, range.start_row + 1, false)[1] or ""
	if line == "" then
		return nil
	end
	local start_col = range.start_col + 1
	local end_col = range.end_col
	if end_col < start_col then
		return nil
	end
	return line:sub(start_col, end_col)
end

local function hunk_is_effective_non_rename(hunk, rename_pairs, src_buf, dst_buf)
	if not hunk then
		return false
	end
	if hunk.kind == "insert" or hunk.kind == "delete" then
		return true
	end
	if hunk.kind ~= "change" then
		return false
	end
	local src_text = range_text(src_buf, hunk.src)
	local dst_text = range_text(dst_buf, hunk.dst)
	if not src_text or not dst_text then
		return true
	end
	return src_text ~= dst_text and rename_pairs[src_text] ~= dst_text
end

local function effective_update_hunks(action, src_buf, dst_buf)
	local analysis = action and action.analysis or nil
	local hunks = analysis and analysis.hunks or nil
	if not hunks or #hunks == 0 then
		return {}
	end
	local rename_pairs = analysis.rename_pairs or {}
	local effective = {}
	for _, hunk in ipairs(hunks) do
		if hunk_is_effective_non_rename(hunk, rename_pairs, src_buf, dst_buf) then
			table.insert(effective, hunk)
		end
	end
	return effective
end

local function move_to_arrow(from_line, to_line)
	if type(from_line) ~= "number" or type(to_line) ~= "number" then
		return "⤴"
	end
	if to_line > from_line then
		return "⤵"
	end
	return "⤴"
end

function M.render(src_buf, dst_buf, actions, ns, opts)
	local src_sign_rows = {}
	local dst_sign_rows = {}
	local src_move_ranges = {}
	local dst_move_ranges = {}
	local src_fillers, dst_fillers = filler.compute(actions, src_buf, dst_buf, opts)

	filler.apply(src_buf, ns, src_fillers)
	filler.apply(dst_buf, ns, dst_fillers)

	for _, action in ipairs(actions) do
		if action.type == "move" then
			if action.src then
				table.insert(src_move_ranges, action.src)
			end
			if action.dst then
				table.insert(dst_move_ranges, action.dst)
			end
		end
	end

	for _, action in ipairs(actions) do
		local base_style = TYPE_STYLE[action.type]
		if base_style then
			local src = action.src
			local dst = action.dst
			local meta = action.metadata or {}
			local style = base_style

			if action.type == "update" then
				local effective_hunks = effective_update_hunks(action, src_buf, dst_buf)
				if #effective_hunks == 0 then
					goto continue
				end
				local rendered_hunk = false
				for _, hunk in ipairs(effective_hunks) do
					local hstyle = HUNK_STYLE[hunk.kind] or HUNK_STYLE.change
					if hunk.render_as_change then
						hstyle = HUNK_STYLE.change
					end
					if hunk.src and hstyle.src_hl then
						apply_span(src_buf, ns, hunk.src, hstyle.src_hl)
						if hstyle.src_hl == "DiffmanticChange" and overlaps_any(hunk.src, src_move_ranges) then
							-- Add a foreground/underline accent so updates stay visible over moved regions.
							apply_span(src_buf, ns, hunk.src, "DiffmanticChangeAccent")
						end
						apply_sign(src_buf, ns, hunk.src.start_row, hstyle.src_sign, hstyle.src_hl, src_sign_rows)
						rendered_hunk = true
					end
					if hunk.dst and hstyle.dst_hl then
						apply_span(dst_buf, ns, hunk.dst, hstyle.dst_hl)
						if hstyle.dst_hl == "DiffmanticChange" and overlaps_any(hunk.dst, dst_move_ranges) then
							-- Add a foreground/underline accent so updates stay visible over moved regions.
							apply_span(dst_buf, ns, hunk.dst, "DiffmanticChangeAccent")
						end
						apply_sign(dst_buf, ns, hunk.dst.start_row, hstyle.dst_sign, hstyle.dst_hl, dst_sign_rows)
						rendered_hunk = true
					end
				end
				if not rendered_hunk then
					goto continue
				end
			else
				if (action.type == "insert" or action.type == "delete") and meta.render_as_change then
					-- render_as_change inserts/deletes are represented by update hunks only.
					goto continue
				end
				if src then
					apply_span(src_buf, ns, src, style.hl)
					apply_sign(src_buf, ns, src.start_row, style.sign, style.hl, src_sign_rows)
				end
				if dst then
					apply_span(dst_buf, ns, dst, style.hl)
					apply_sign(dst_buf, ns, dst.start_row, style.sign, style.hl, dst_sign_rows)
				end

				if action.type == "move" then
					if src and meta.to_line then
						local arrow = move_to_arrow(meta.from_line, meta.to_line)
						apply_virt(
							src_buf,
							ns,
							src.start_row,
							src.end_col or 0,
							string.format(" %s moved to L%d", arrow, meta.to_line),
							"Comment",
							"eol"
						)
					end
					if dst and meta.from_line then
						apply_virt(
							dst_buf,
							ns,
							dst.start_row,
							dst.end_col or 0,
							string.format(" ⤶ from L%d", meta.from_line),
							"Comment",
							"eol"
						)
					end
				elseif action.type == "rename" then
					if src and meta.new_name then
						apply_virt(
							src_buf,
							ns,
							src.start_row,
							src.end_col or 0,
							" -> " .. meta.new_name,
							"Comment",
							"inline"
						)
					end
					if dst and meta.old_name then
						apply_virt(
							dst_buf,
							ns,
							dst.start_row,
							dst.end_col or 0,
							string.format(" (was %s)", meta.old_name),
							"Comment",
							"inline"
						)
					end
				end
			end
			::continue::
		end
	end

	return {
		src_fillers = src_fillers,
		dst_fillers = dst_fillers,
	}
end

return M
