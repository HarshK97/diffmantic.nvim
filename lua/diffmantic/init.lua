local M = {}
local core = require("diffmantic.core")
local ui = require("diffmantic.ui")
local debug_utils = require("diffmantic.debug_utils")

local function hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if not ok then
		return {}
	end
	return value or {}
end

local function pick_bg(names)
	for _, name in ipairs(names) do
		local value = hl(name).bg
		if value then
			return value
		end
	end
	return nil
end

local function pick_fg(names, fallback)
	for _, name in ipairs(names) do
		local value = hl(name).fg
		if value then
			return value
		end
	end
	return fallback
end

local function setup_highlights()
	local add_bg = pick_bg({ "DiffAdd", "DiffText" })
	local delete_bg = pick_bg({ "DiffDelete", "DiffText" })
	local change_bg = pick_bg({ "DiffText", "DiffChange" })
	local move_bg = pick_bg({ "DiffText", "DiffChange" })

	local add_sign_fg = pick_fg({ "DiffAdd" }, 0x49D17D)
	local delete_sign_fg = pick_fg({ "DiffDelete" }, 0xFF6B6B)
	local change_sign_fg = pick_fg({ "DiagnosticWarn", "DiffChange" }, 0xE8C95A)
	local move_sign_fg = pick_fg({ "DiagnosticInfo", "DiffText" }, 0x5AA2FF)

	vim.api.nvim_set_hl(0, "DiffmanticAdd", { fg = add_sign_fg, bg = add_bg })
	vim.api.nvim_set_hl(0, "DiffmanticDelete", { fg = delete_sign_fg, bg = delete_bg })
	vim.api.nvim_set_hl(0, "DiffmanticChange", { fg = change_sign_fg, bg = change_bg })
	vim.api.nvim_set_hl(0, "DiffmanticMove", { fg = move_sign_fg, bg = move_bg })
	vim.api.nvim_set_hl(0, "DiffmanticRename", { fg = change_sign_fg, underline = true, bold = true, italic = true })

	vim.api.nvim_set_hl(0, "DiffmanticAddSign", { fg = add_sign_fg, bg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffmanticDeleteSign", { fg = delete_sign_fg, bg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffmanticChangeSign", { fg = change_sign_fg, bg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffmanticMoveSign", { fg = move_sign_fg, bg = "NONE" })
	vim.api.nvim_set_hl(0, "DiffmanticRenameSign", { fg = change_sign_fg, bg = "NONE" })

end

function M.setup(opts)
	setup_highlights()

	local aug = vim.api.nvim_create_augroup("diffmantic_highlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = aug,
		callback = setup_highlights,
	})
end

function M.diff(args)
	setup_highlights()
	local parts = vim.split(args, " ", { trimempty = true })
	if #parts == 0 then
		print("Please provide one or two files paths to compare.")
		return
	end

	local file1, file2 = parts[1], parts[2]
	local buf1, buf2
	local win1, win2

	if file2 then
		-- Case: 2 files provided. Open them in split.
		vim.cmd("tabnew")
		vim.cmd("edit " .. file1)
		buf1 = vim.api.nvim_get_current_buf()
		win1 = vim.api.nvim_get_current_win()

		vim.cmd("vsplit " .. file2)
		buf2 = vim.api.nvim_get_current_buf()
		win2 = vim.api.nvim_get_current_win()
	else
		-- Case: 1 file provided. Compare current buffer vs file.
		buf1 = vim.api.nvim_get_current_buf()
		win1 = vim.api.nvim_get_current_win()
		local expanded_path = vim.fn.expand(file1)

		vim.cmd("vsplit " .. expanded_path)
		buf2 = vim.api.nvim_get_current_buf()
		win2 = vim.api.nvim_get_current_win()
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

	vim.api.nvim_win_set_cursor(win1, { 1, 0 })
	vim.api.nvim_win_set_cursor(win2, { 1, 0 })
	vim.wo[win1].scrollbind = true
	vim.wo[win1].cursorbind = true
	vim.wo[win2].scrollbind = true
	vim.wo[win2].cursorbind = true
end

return M
