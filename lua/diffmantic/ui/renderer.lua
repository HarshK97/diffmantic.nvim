local signs = require("diffmantic.ui.signs")

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

local function apply_spans(buf, ns, spans)
	if not spans then
		return
	end
	for _, span in ipairs(spans) do
		if span and span.row ~= nil and span.start_col ~= nil and span.end_col ~= nil and span.hl_group then
			set_extmark(buf, ns, span.row, span.start_col, {
				end_row = span.end_row or span.row,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

local function apply_signs(buf, ns, list, seen_rows)
	if not list then
		return
	end
	for _, item in ipairs(list) do
		if item and item.row ~= nil and item.text and item.hl_group then
			signs.mark(buf, ns, item.row, item.col or 0, item.text, item.hl_group, seen_rows)
		end
	end
end

local function apply_virt(buf, ns, list)
	if not list then
		return
	end
	for _, item in ipairs(list) do
		if item and item.row ~= nil and item.text then
			local opts = {
				virt_text = { { item.text, item.hl_group or "Comment" } },
				virt_text_pos = item.pos or "eol",
			}
			local ok = set_extmark(buf, ns, item.row, item.col or 0, opts)
			if not ok and opts.virt_text_pos == "inline" then
				opts.virt_text_pos = "eol"
				set_extmark(buf, ns, item.row, item.col or 0, opts)
			end
		end
	end
end

function M.render(src_buf, dst_buf, actions, ns)
	local src_sign_rows = {}
	local dst_sign_rows = {}

	for _, action in ipairs(actions) do
		local render = action.render
		if render then
			apply_spans(src_buf, ns, render.src_spans)
			apply_spans(dst_buf, ns, render.dst_spans)
			apply_signs(src_buf, ns, render.src_signs, src_sign_rows)
			apply_signs(dst_buf, ns, render.dst_signs, dst_sign_rows)
			apply_virt(src_buf, ns, render.src_virt)
			apply_virt(dst_buf, ns, render.dst_virt)
		end
	end

end

return M

