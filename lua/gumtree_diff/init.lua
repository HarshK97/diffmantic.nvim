local M = {}
local core = require("gumtree_diff.core")

function M.setup(opts) end

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

		vim.cmd("vsplit " .. file2)
		buf2 = vim.api.nvim_get_current_buf()
	else
		-- Case: 1 file provided. Compare current buffer vs file.
		buf1 = vim.api.nvim_get_current_buf()
		local expanded_path = vim.fn.expand(file1)

		vim.cmd("vsplit " .. expanded_path)
		buf2 = vim.api.nvim_get_current_buf()
	end

	local lang = vim.treesitter.language.get_lang(vim.bo[buf1].filetype)
	if not lang then
		print("Unsupported filetype for Treesitter.")
		return
	end

	local parser1 = vim.treesitter.get_parser(buf1, lang)
	local parser2 = vim.treesitter.get_parser(buf2, lang)
	local root1 = parser1:parse()[1]:root()
	local root2 = parser2:parse()[1]:root()

	local mappings, src_info, dst_info = core.top_down_match(root1, root2, buf1, buf2)
	print("Top-down mappings: " .. #mappings)

	mappings = core.bottom_up_match(mappings, src_info, dst_info, root1, root2, buf1, buf2)
	print("Total mappings after Bottom-up: " .. #mappings)

	M.print_mappings(mappings, src_info, dst_info, buf1, buf2)
end

function M.print_mappings(mappings, src_info, dst_info, buf1, buf2)
	print("\n=== Function and Variable Mappings ===")
	for _, m in ipairs(mappings) do
		local src = src_info[m.src]
		local dst = dst_info[m.dst]
		if src and dst then
			if src.type == "function_declaration" or src.type == "variable_declaration" then
				local src_text = vim.treesitter.get_node_text(src.node, buf1):sub(1, 50)
				local dst_text = vim.treesitter.get_node_text(dst.node, buf2):sub(1, 50)
				print(string.format("%s: '%s' -> '%s'", src.type, src_text, dst_text))
			end
		end
	end
	print("===================================\n")
end

return M
