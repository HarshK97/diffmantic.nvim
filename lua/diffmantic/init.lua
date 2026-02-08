local M = {}
local core = require("diffmantic.core")
local ui = require("diffmantic.ui")
local debug_utils = require("diffmantic.debug_utils")

local function setup_highlights()
	local add_fg = vim.api.nvim_get_hl(0, { name = "DiffAdd" }).fg or 0xa6e3a1
	local delete_fg = vim.api.nvim_get_hl(0, { name = "DiffDelete" }).fg or 0xf38ba8
	local change_fg = vim.api.nvim_get_hl(0, { name = "DiffChange" }).fg or 0xf9e2af

	vim.api.nvim_set_hl(0, "DiffAddText", { fg = add_fg, bg = "NONE", ctermbg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffDeleteText", { fg = delete_fg, bg = "NONE", ctermbg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffChangeText", { fg = change_fg, bg = "NONE", ctermbg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffMoveText", { fg = 0x89b4fa, bg = "NONE", ctermbg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffRenameText", { fg = change_fg, bg = "NONE", ctermbg = "NONE", underline = true })
end

function M.setup(opts)
	setup_highlights()
end

function M.diff(args)
	local parts = vim.split(args, " ", { trimempty = true })
	if #parts == 0 then
		print("Please provide one or two files paths to compare.")
		return
	end

	local file1, file2 = parts[1], parts[2]
	local buf1, buf2

	if file2 then
		-- Case: 2 files provided. Open them in split.
		vim.cmd("tabnew")
		vim.cmd("edit " .. file1)
		buf1 = vim.api.nvim_get_current_buf()
		local win1 = vim.api.nvim_get_current_win()

		vim.cmd("vsplit " .. file2)
		buf2 = vim.api.nvim_get_current_buf()
		local win2 = vim.api.nvim_get_current_win()

		vim.wo[win1].scrollbind = true
		vim.wo[win1].cursorbind = true
		vim.wo[win2].scrollbind = true
		vim.wo[win2].cursorbind = true
	else
		-- Case: 1 file provided. Compare current buffer vs file.
		buf1 = vim.api.nvim_get_current_buf()
		local win1 = vim.api.nvim_get_current_win()
		local expanded_path = vim.fn.expand(file1)

		vim.cmd("vsplit " .. expanded_path)
		buf2 = vim.api.nvim_get_current_buf()
		local win2 = vim.api.nvim_get_current_win()

		vim.wo[win1].scrollbind = true
		vim.wo[win1].cursorbind = true
		vim.wo[win2].scrollbind = true
		vim.wo[win2].cursorbind = true
	end

	local lang = vim.treesitter.language.get_lang(vim.bo[buf1].filetype)
	if not lang then
		print("Unsupported filetype for Treesitter.")
		return
	end

	local parser1 = vim.treesitter.get_parser(buf1, lang)
	local parser2 = vim.treesitter.get_parser(buf2, lang)
	if not parser1 or not parser2 then
		print("Failed to get Treesitter parser for one of the buffers.")
		return
	end
	local root1 = parser1:parse()[1]:root()
	local root2 = parser2:parse()[1]:root()

	local mappings, src_info, dst_info = core.top_down_match(root1, root2, buf1, buf2)
	-- print("Top-down mappings: " .. #mappings)

	-- local before_bottom_up = #mappings
	mappings = core.bottom_up_match(mappings, src_info, dst_info, root1, root2, buf1, buf2)
	-- print("Mappings after Bottom-up: " .. #mappings .. " (+" .. (#mappings - before_bottom_up) .. " new)")

	-- local before_recovery = #mappings
	mappings = core.recovery_match(root1, root2, mappings, src_info, dst_info, buf1, buf2)
	-- debug_utils.print_recovery_mappings(mappings, before_recovery, src_info, dst_info, buf1, buf2)

	local actions = core.generate_actions(root1, root2, mappings, src_info, dst_info, {
		src_buf = buf1,
		dst_buf = buf2,
	})

	-- debug_utils.print_actions(actions, buf1, buf2)
	-- debug_utils.print_mappings(mappings, src_info, dst_info, buf1, buf2)
	ui.apply_highlights(buf1, buf2, actions)
end

return M
