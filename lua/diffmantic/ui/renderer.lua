local signs = require("diffmantic.ui.signs")
local filler = require("diffmantic.ui.filler")

local M = {}

local HL_PRIORITY = {
	DiffmanticMove = 10,
	DiffmanticAdd = 20,
	DiffmanticDelete = 20,
	DiffmanticChange = 30,
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

local function move_to_arrow(from_line, to_line)
	if type(from_line) ~= "number" or type(to_line) ~= "number" then
		return "⤴"
	end
	if to_line > from_line then
		return "⤵"
	end
	return "⤴"
end

function M.render(src_buf, dst_buf, actions, ns)
	local src_sign_rows = {}
	local dst_sign_rows = {}
	local src_fillers, dst_fillers = filler.compute(actions, src_buf, dst_buf)
	filler.apply(src_buf, ns, src_fillers)
	filler.apply(dst_buf, ns, dst_fillers)

	for _, action in ipairs(actions) do
		local style = TYPE_STYLE[action.type]
		if style then
			local src = action.src
			local dst = action.dst
			local meta = action.metadata or {}

			if action.type == "update" and action.analysis and action.analysis.hunks then
				local rendered_hunk = false
				for _, hunk in ipairs(action.analysis.hunks) do
					local hstyle = HUNK_STYLE[hunk.kind] or HUNK_STYLE.change
					if hunk.src and hstyle.src_hl then
						apply_span(src_buf, ns, hunk.src, hstyle.src_hl)
						apply_sign(src_buf, ns, hunk.src.start_row, hstyle.src_sign, hstyle.src_hl, src_sign_rows)
						rendered_hunk = true
					end
					if hunk.dst and hstyle.dst_hl then
						apply_span(dst_buf, ns, hunk.dst, hstyle.dst_hl)
						apply_sign(dst_buf, ns, hunk.dst.start_row, hstyle.dst_sign, hstyle.dst_hl, dst_sign_rows)
						rendered_hunk = true
					end
				end

				if rendered_hunk and src and src.start_row ~= nil then
					apply_sign(src_buf, ns, src.start_row, "U", "DiffmanticChange", src_sign_rows)
				end
				if rendered_hunk and dst and dst.start_row ~= nil then
					apply_sign(dst_buf, ns, dst.start_row, "U", "DiffmanticChange", dst_sign_rows)
				end
			else
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
						apply_virt(src_buf, ns, src.start_row, src.end_col or 0, string.format(" %s moved to L%d", arrow, meta.to_line), "Comment", "eol")
					end
					if dst and meta.from_line then
						apply_virt(dst_buf, ns, dst.start_row, dst.end_col or 0, string.format(" ⤶ from L%d", meta.from_line), "Comment", "eol")
					end
				elseif action.type == "rename" then
					if src and meta.new_name then
						apply_virt(src_buf, ns, src.start_row, src.end_col or 0, " -> " .. meta.new_name, "Comment", "inline")
					end
					if dst and meta.old_name then
						apply_virt(dst_buf, ns, dst.start_row, dst.end_col or 0, string.format(" (was %s)", meta.old_name), "Comment", "inline")
					end
				end
			end
		end
	end
end

return M
