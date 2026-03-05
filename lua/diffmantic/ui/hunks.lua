local M = {}

local function line_length(buf, row)
	if not buf or row == nil then
		return 1
	end
	local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
	local line = lines[1] or ""
	return #line
end

local function normalize_range(range, buf)
	if type(range) ~= "table" then
		return nil
	end
	if range.start_row == nil and range.end_row == nil then
		return nil
	end
	local out = {
		start_row = range.start_row or range.end_row,
		end_row = range.end_row or range.start_row,
		start_col = range.start_col or 0,
		end_col = range.end_col,
	}
	if out.start_row == nil then
		return nil
	end
	if out.end_col == nil then
		out.end_col = line_length(buf, out.end_row)
	end
	if out.start_row == out.end_row and out.end_col <= out.start_col then
		out.end_col = out.start_col + 1
	end
	return out
end

local function legacy_range(prefix, hunk, buf)
	local start_row = hunk[prefix .. "_start"]
	local end_row = hunk[prefix .. "_end"]
	local start_col = hunk[prefix .. "_col_start"]
	local end_col = hunk[prefix .. "_col_end"]
	if start_row == nil and end_row == nil then
		return nil
	end
	return normalize_range({
		start_row = start_row or end_row,
		end_row = end_row or start_row,
		start_col = start_col,
		end_col = end_col,
	}, buf)
end

function M.normalize_hunk(hunk, src_buf, dst_buf)
	if type(hunk) ~= "table" then
		return nil
	end

	local normalized = {
		src = normalize_range(hunk.src, src_buf) or legacy_range("src", hunk, src_buf),
		dst = normalize_range(hunk.dst, dst_buf) or legacy_range("dst", hunk, dst_buf),
		render_as_change = hunk.render_as_change,
	}

	local kind = hunk.kind
	if kind ~= "change" and kind ~= "insert" and kind ~= "delete" then
		if normalized.src and normalized.dst then
			kind = "change"
		elseif normalized.src then
			kind = "delete"
		elseif normalized.dst then
			kind = "insert"
		else
			return nil
		end
	end

	if kind == "insert" then
		normalized.src = nil
	elseif kind == "delete" then
		normalized.dst = nil
	elseif kind == "change" then
		if not normalized.src and normalized.dst then
			kind = "insert"
		elseif normalized.src and not normalized.dst then
			kind = "delete"
		elseif not normalized.src and not normalized.dst then
			return nil
		end
	end

	normalized.kind = kind
	return normalized
end

function M.normalize_list(hunks, src_buf, dst_buf)
	local out = {}
	for _, hunk in ipairs(hunks or {}) do
		local normalized = M.normalize_hunk(hunk, src_buf, dst_buf)
		if normalized then
			table.insert(out, normalized)
		end
	end
	return out
end

return M
