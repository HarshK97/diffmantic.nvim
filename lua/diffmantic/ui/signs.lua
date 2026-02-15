local M = {}

local SIGN_GROUP_BY_TEXT_GROUP = {
	DiffmanticAdd = "DiffmanticAddSign",
	DiffmanticDelete = "DiffmanticDeleteSign",
	DiffmanticChange = "DiffmanticChangeSign",
	DiffmanticMove = "DiffmanticMoveSign",
	DiffmanticRename = "DiffmanticRenameSign",
}

local SIGN_PRIORITY_BY_TEXT_GROUP = {
	DiffmanticAdd = 40,
	DiffmanticDelete = 40,
	DiffmanticChange = 20,
	DiffmanticMove = 10,
	DiffmanticRename = 30,
}

function M.glyph()
	return vim.g.diffmantic_side_sign_glyph or "▎"
end

function M.style()
	return vim.g.diffmantic_sign_style or "both"
end

local function normalize_sign_char(text)
	if not text or text == "" then
		return nil
	end
	return text:sub(1, 1)
end

function M.sign_text(text)
	local sign_char = normalize_sign_char(text)
	if not sign_char then
		return nil
	end

	local style = M.style()
	if style == "letter" then
		return sign_char
	end
	if style == "gutter" then
		return M.glyph()
	end
	return M.glyph() .. sign_char
end

function M.group_for_hl(hl_group)
	return SIGN_GROUP_BY_TEXT_GROUP[hl_group] or hl_group
end

function M.priority_for_hl(hl_group)
	return SIGN_PRIORITY_BY_TEXT_GROUP[hl_group] or 0
end

function M.mark(buf, ns, row, col, text, hl_group, sign_rows)
	if row == nil or row < 0 then
		return false
	end
	if not text or text == "" then
		return false
	end

	local priority = M.priority_for_hl(hl_group)
	local existing_priority = -1
	if sign_rows and sign_rows[row] then
		local existing = sign_rows[row]
		existing_priority = type(existing) == "number" and existing or 0
	end
	if existing_priority >= priority then
		return false
	end

	local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col or 0, {
		sign_text = M.sign_text(text),
		sign_hl_group = M.group_for_hl(hl_group),
		priority = priority,
	})

	if ok and sign_rows then
		sign_rows[row] = priority
	end
	return ok
end

return M
