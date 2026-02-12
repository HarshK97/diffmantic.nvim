local M = {}

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

return M
