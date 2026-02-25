local renderer = require("diffmantic.ui.renderer")

local M = {}

local ns = vim.api.nvim_create_namespace("GumtreeDiff")

function M.clear_highlights(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	end
end

function M.apply_highlights(src_buf, dst_buf, actions, opts)
	M.clear_highlights(src_buf)
	M.clear_highlights(dst_buf)
	return renderer.render(src_buf, dst_buf, actions, ns, opts)
end

return M
