
-- Inspired by: GumTree-style multi-phase AST source differencing.
-- Reference: https://hal.science/hal-04855170v1/file/GumTree_simple__fine_grained__accurate_and_scalable_source_differencing.pdf

local top_down_mod   = require("diffmantic.core.top_down")
local bottom_up_mod  = require("diffmantic.core.bottom_up")
local recovery_mod   = require("diffmantic.core.recovery")
local actions_mod    = require("diffmantic.core.actions")
local rename_mod     = require("diffmantic.core.rename")
local analysis_mod   = require("diffmantic.core.analysis")
local prematch_mod   = require("diffmantic.core.line_prematch")
local ts             = require("diffmantic.treesitter")

local M = {}

local function node_sort_key(info, id)
	local e = info and info[id] or nil
	if not e then
		return "nil|-1|-1|-1|-1|-1|-1||"
	end
	return table.concat({
		tostring(e.start_byte or -1),
		tostring(e.end_byte or -1),
		tostring(e.start_row or -1),
		tostring(e.start_col or -1),
		tostring(e.end_row or -1),
		tostring(e.end_col or -1),
		tostring(e.type or ""),
		tostring(e.label or ""),
	}, "|")
end

local function sort_mappings(mappings, src_info, dst_info)
	if not mappings or #mappings < 2 then
		return mappings
	end
	table.sort(mappings, function(a, b)
		local as = node_sort_key(src_info, a.src)
		local bs = node_sort_key(src_info, b.src)
		if as ~= bs then
			return as < bs
		end
		local ad = node_sort_key(dst_info, a.dst)
		local bd = node_sort_key(dst_info, b.dst)
		return ad < bd
	end)
	return mappings
end

function M.pre_match(src_root, dst_root, src_buf, dst_buf, src_info_or_opts, dst_info, opts)
	local src_info
	if dst_info ~= nil or opts ~= nil then
		src_info = src_info_or_opts
		opts = opts or {}
	else
		opts = src_info_or_opts or {}
		src_info = opts.src_info
		dst_info = opts.dst_info
	end

	src_info = src_info or ts.preprocess_tree(src_root, src_buf, opts)
	dst_info = dst_info or ts.preprocess_tree(dst_root, dst_buf, opts)
	local mappings = prematch_mod.prematch_unchanged(src_info, dst_info, src_buf, dst_buf)
	return sort_mappings(mappings, src_info, dst_info)
end

function M.top_down_match(src_root, dst_root, src_buf, dst_buf, opts)
	opts = opts or {}

	local src_info = opts.src_info or ts.preprocess_tree(src_root, src_buf, opts)
	local dst_info = opts.dst_info or ts.preprocess_tree(dst_root, dst_buf, opts)

	local mappings = top_down_mod.top_down_match(
		src_root, dst_root,
		src_buf,  dst_buf,
		src_info, dst_info,
		opts.existing_mappings,
		opts
	)
	sort_mappings(mappings, src_info, dst_info)
	return mappings, src_info, dst_info
end

function M.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, src_buf, dst_buf, opts)
	return bottom_up_mod.bottom_up_match(
		mappings, src_info, dst_info,
		src_root, dst_root,
		src_buf,  dst_buf,
		opts
	)
end

function M.recovery_match(src_root, dst_root, mappings, src_info, dst_info, src_buf, dst_buf, opts)
	return recovery_mod.recovery_match(
		src_root, dst_root,
		mappings, src_info, dst_info,
		src_buf,  dst_buf,
		opts
	)
end

function M.generate_actions(src_root, dst_root, mappings, src_info, dst_info, opts)
	local acts = actions_mod.generate_actions(
		src_root, dst_root,
		mappings, src_info, dst_info,
		opts
	)
	acts = rename_mod.promote(acts, {
		mappings = mappings,
		src_info = src_info,
		dst_info = dst_info,
		src_root = src_root,
		dst_root = dst_root,
		src_buf = opts and opts.src_buf,
		dst_buf = opts and opts.dst_buf,
		opts = opts,
	})
	analysis_mod.enrich(acts, {
		src_buf = opts and opts.src_buf,
		dst_buf = opts and opts.dst_buf,
	})
	return acts
end

function M.diff(src_root, dst_root, src_buf_or_opts, dst_buf, opts)
	local src_buf, use_table_return
	if type(src_buf_or_opts) == "table" then
		opts             = src_buf_or_opts
		src_buf          = opts.src_buf
		dst_buf          = opts.dst_buf
		use_table_return = true
	else
		src_buf          = src_buf_or_opts
		opts             = opts or {}
		opts.src_buf     = opts.src_buf or src_buf
		opts.dst_buf     = opts.dst_buf or dst_buf
		use_table_return = false
	end
	opts         = opts or {}
	opts.src_buf = opts.src_buf or src_buf
	opts.dst_buf = opts.dst_buf or dst_buf

	local src_info = ts.preprocess_tree(src_root, src_buf, opts)
	local dst_info = ts.preprocess_tree(dst_root, dst_buf, opts)
	local pre_mappings = M.pre_match(
		src_root, dst_root, src_buf, dst_buf,
		src_info, dst_info, opts
	)

	opts.src_info = src_info
	opts.dst_info = dst_info
	opts.existing_mappings = pre_mappings

	local mappings
	mappings, src_info, dst_info = M.top_down_match(
		src_root, dst_root, src_buf, dst_buf, opts
	)

	mappings = M.bottom_up_match(
		mappings, src_info, dst_info,
		src_root, dst_root,
		src_buf,  dst_buf,
		opts
	)

	mappings = M.recovery_match(
		src_root, dst_root,
		mappings, src_info, dst_info,
		src_buf,  dst_buf,
		opts
	)
	sort_mappings(mappings, src_info, dst_info)

	local acts = M.generate_actions(
		src_root, dst_root,
		mappings, src_info, dst_info,
		opts
	)

	if use_table_return then
		return {
			actions = acts,
			src_info = src_info,
			dst_info = dst_info,
			mappings = mappings,
		}
	end
	return acts, src_info, dst_info, mappings
end

return M
