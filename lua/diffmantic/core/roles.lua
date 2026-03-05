
local M = {}


function M.build_index(root, buf)
	local ft   = vim.bo[buf] and vim.bo[buf].filetype or ""
	local lang = vim.treesitter.language.get_lang(ft) or ft
	local index = {}

	local ok, query = pcall(vim.treesitter.query.get, lang, "diffmantic")
	if not ok or not query then
		ok, query = pcall(vim.treesitter.query.get, ft, "diffmantic")
		if not ok or not query then return index end
	end

	local outer_set = {}
	for cap_id, node in query:iter_captures(root, buf, 0, -1) do
		local cap_name = query.captures[cap_id]
		if cap_name then
			local kind, role = cap_name:match("^diff%.(%w+)%.(%w+)$")
			if kind and role == "outer" then
				outer_set[node:id()] = { kind = kind, node = node }
			end
		end
	end

	for cap_id, node in query:iter_captures(root, buf, 0, -1) do
		local cap_name = query.captures[cap_id]
		if cap_name then
			local kind, role = cap_name:match("^diff%.(%w+)%.(%w+)$")
			if kind and role == "name" then
				local name_text = vim.treesitter.get_node_text(node, buf) or ""
				local name_id   = node:id()

				local cur = node:parent()
				while cur do
					local entry = outer_set[cur:id()]
					if entry and entry.kind == kind then
						local outer_id = cur:id()
						index[outer_id] = {
							kind    = kind,
							name    = name_text,
							node    = cur,
							is_name = false,
						}
						index[name_id] = {
							kind     = kind,
							name     = name_text,
							node     = node,
							is_name  = true,
							outer_id = outer_id,
						}
						break
					end
					cur = cur:parent()
				end
			end
		end
	end

	return index
end


function M.get_kind_name_text(node, role_index, _buf, kind)
	local current = node
	while current do
		local id   = current:id()
		local info = role_index[id]
		if info and info.name and info.name ~= "" then
			if kind == nil or info.kind == kind then
				return info.name
			end
		end
		current = current:parent()
	end
	return ""
end

return M
