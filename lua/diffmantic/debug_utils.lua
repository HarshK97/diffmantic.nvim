local M = {}

local function describe_node(node, bufnr)
	local text = vim.treesitter.get_node_text(node, bufnr) or ""
	text = text:gsub("\n", " ")
	text = text:sub(1, 60)

	local sr, sc, er, ec = node:range()
	return string.format('%s [%d:%d - %d:%d] "%s"', node:type(), sr + 1, sc + 1, er + 1, ec + 1, text)
end

function M.print_recovery_mappings(mappings, before_recovery, src_info, dst_info, buf1, buf2)
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
end

function M.print_actions(actions, buf1, buf2)
	print("\n========== EDIT ACTIONS ==========")

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
