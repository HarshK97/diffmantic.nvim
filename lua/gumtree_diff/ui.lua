local M = {}

local ns = vim.api.nvim_create_namespace("GumtreeDiff")

function M.clear_highlights(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	end
end

function M.apply_highlights(src_buf, dst_buf, actions)
	M.clear_highlights(src_buf)
	M.clear_highlights(dst_buf)

	for _, action in ipairs(actions) do
		local node = action.node
		local sr, sc, er, ec = node:range()

		if action.type == "move" then
			local target = action.target
			local tr, _, _, _ = target:range()
			local src_line = sr + 1
			local dst_line = tr + 1

			pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffText",
				virt_text = { { string.format(" ⤷ moved L%d → L%d", src_line, dst_line), "Comment" } },
				virt_text_pos = "eol",
				sign_text = "M",
				sign_hl_group = "DiffText",
			})
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, tr, 0, {
				end_row = tr + (er - sr),
				end_col = ec,
				hl_group = "DiffText",
				virt_text = { { string.format(" ⤶ from L%d", src_line), "Comment" } },
				virt_text_pos = "eol",
				sign_text = "M",
				sign_hl_group = "DiffText",
			})
		elseif action.type == "update" then
			local target = action.target
			local tr, tc, ter, tec = target:range()

			pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffChange",
				sign_text = "~",
				sign_hl_group = "DiffChange",
			})
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, tr, tc, {
				end_row = ter,
				end_col = tec,
				hl_group = "DiffChange",
				sign_text = "~",
				sign_hl_group = "DiffChange",
			})
		elseif action.type == "delete" then
			pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffDelete",
				sign_text = "-",
				sign_hl_group = "DiffDelete",
			})
		elseif action.type == "insert" then
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffAdd",
				sign_text = "+",
				sign_hl_group = "DiffAdd",
			})
		end
	end
end

return M
