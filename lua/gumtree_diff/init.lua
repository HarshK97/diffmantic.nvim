local M = {}
local core = require("gumtree_diff.core")
local ui = require("gumtree_diff.ui")

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
	if not parser1 or not parser2 then
		print("Failed to get Treesitter parser for one of the buffers.")
		return
	end
	local root1 = parser1:parse()[1]:root()
	local root2 = parser2:parse()[1]:root()

	local mappings, src_info, dst_info = core.top_down_match(root1, root2, buf1, buf2)
	print("Top-down mappings: " .. #mappings)

	local before_bottom_up = #mappings
	mappings = core.bottom_up_match(mappings, src_info, dst_info, root1, root2, buf1, buf2)
	print("Mappings after Bottom-up: " .. #mappings .. " (+" .. (#mappings - before_bottom_up) .. " new)")

	local before_recovery = #mappings
	mappings = core.recovery_match(root1, root2, mappings, src_info, dst_info, buf1, buf2)
	local recovery_count = #mappings - before_recovery
	print("Total mappings after Recovery: " .. #mappings .. " (+" .. recovery_count .. " new)")

	if recovery_count > 0 then
		print("\n=== New Mappings from Recovery ===")
		for i = before_recovery + 1, #mappings do
			local m = mappings[i]
			local s = src_info[m.src]
			local d = dst_info[m.dst]
			if s and d then
				local src_text = vim.treesitter.get_node_text(s.node, buf1):gsub("\n", " ")
				local dst_text = vim.treesitter.get_node_text(d.node, buf2):gsub("\n", " ")
				src_text = src_text:sub(1, 40)
				dst_text = dst_text:sub(1, 40)
				print(string.format("[%s] '%s' -> '%s'", s.type, src_text, dst_text))
			end
		end
		print("==================================\n")
	else
		print("(Recovery found no new mappings)")
	end

	local actions = core.generate_actions(root1, root2, mappings, src_info, dst_info)

	print("\n========== EDIT ACTIONS ==========")

	local function describe_node(node, bufnr)
		local text = vim.treesitter.get_node_text(node, bufnr) or ""
		text = text:gsub("\n", " ")
		text = text:sub(1, 60)

		local sr, sc, er, ec = node:range()
		return string.format('%s [%d:%d - %d:%d] "%s"', node:type(), sr + 1, sc + 1, er + 1, ec + 1, text)
	end

	for _, action in ipairs(actions) do
		if action.type == "delete" then
			print("DELETE  " .. describe_node(action.node, buf1))
		elseif action.type == "insert" then
			print("INSERT  " .. describe_node(action.node, buf2))
		elseif action.type == "update" then
			print("UPDATE  " .. describe_node(action.node, buf1) .. "  -->  " .. describe_node(action.target, buf2))
		elseif action.type == "move" then
			print("MOVE    " .. describe_node(action.node, buf1) .. "  -->  " .. describe_node(action.target, buf2))
		end
	end

	print("Total edit actions: " .. #actions)
	print("==================================\n")

	M.print_mappings(mappings, src_info, dst_info, buf1, buf2)
	ui.apply_highlights(buf1, buf2, actions)
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
