-- Scope-aware rename promotion over identifier update actions.

local M = {}

local IDENTIFIER_TYPES = {
	identifier = true,
	field_identifier = true,
	property_identifier = true,
	type_identifier = true,
}

local COARSE_DROP_UPDATE_TYPES = {
	identifier = true,
	field_identifier = true,
	property_identifier = true,
	type_identifier = true,
	namespace_identifier = true,
	string_literal = true,
	number_literal = true,
	char_literal = true,
}

local FUNCTION_CONTAINER_TYPES = {
	function_definition = true,
	method_definition = true,
	function_declaration = true,
	function_item = true,
	local_function = true,
	function_expression = true,
	arrow_function = true,
}

local CLASS_CONTAINER_TYPES = {
	class_specifier = true,
	class_declaration = true,
	struct_specifier = true,
	interface_declaration = true,
	type_declaration = true,
	type_alias_declaration = true,
}

local function function_pair_key(old_name, new_name)
	return table.concat({
		old_name,
		new_name,
	}, "|")
end

local function build_maps(mappings)
	local s2d, d2s = {}, {}
	for _, m in ipairs(mappings or {}) do
		s2d[m.src] = m.dst
		d2s[m.dst] = m.src
	end
	return s2d, d2s
end

local function trim_name(v)
	if type(v) ~= "string" then
		return ""
	end
	return vim.trim(v)
end

local function escape_lua_pattern(s)
	return (tostring(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function is_identifier_text(s)
	return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function node_range(node)
	if not node then
		return nil
	end
	local ok, sr, sc, er, ec = pcall(node.range, node)
	if not ok then
		return nil
	end
	return { start_row = sr, start_col = sc, end_row = er, end_col = ec }
end

local function node_trim_text(node, buf)
	if not node or not buf then
		return ""
	end
	local ok, txt = pcall(vim.treesitter.get_node_text, node, buf)
	if not ok or not txt then
		return ""
	end
	return vim.trim(txt)
end

local function nearest_function_container(id, info)
	local cur = info and info[id] or nil
	while cur and cur.parent_id do
		local p = info[cur.parent_id]
		if not p then
			return nil
		end
		if FUNCTION_CONTAINER_TYPES[p.type] then
			return cur.parent_id
		end
		cur = p
	end
	return nil
end

local function nearest_class_container(id, info)
	local cur = info and info[id] or nil
	while cur and cur.parent_id do
		local p = info[cur.parent_id]
		if not p then
			return nil
		end
		if CLASS_CONTAINER_TYPES[p.type] then
			return cur.parent_id
		end
		cur = p
	end
	return nil
end

local function mapped_scope_key(src_id, dst_id, src_info, dst_info, s2d, scope_fn, prefix)
	local src_scope = scope_fn(src_id, src_info)
	local dst_scope = scope_fn(dst_id, dst_info)
	if src_scope and dst_scope and s2d[src_scope] == dst_scope then
		return prefix .. ":" .. tostring(src_scope) .. "|" .. tostring(dst_scope)
	end
	return nil
end

local function function_scope_key_for_pair(src_id, dst_id, src_info, dst_info, s2d)
	return mapped_scope_key(src_id, dst_id, src_info, dst_info, s2d, nearest_function_container, "FN")
end

local function class_scope_key_for_pair(src_id, dst_id, src_info, dst_info, s2d)
	return mapped_scope_key(src_id, dst_id, src_info, dst_info, s2d, nearest_class_container, "CLS")
end

local function scope_key_for_pair(src_id, dst_id, src_info, dst_info, s2d)
	local fn_scope = function_scope_key_for_pair(src_id, dst_id, src_info, dst_info, s2d)
	if fn_scope then
		return fn_scope
	end
	return "GLOBAL"
end

local function node_pos_lt(src_info, a_id, a_idx, b_id, b_idx)
	local ai = src_info and src_info[a_id] or nil
	local bi = src_info and src_info[b_id] or nil
	if ai and bi then
		if ai.start_row ~= bi.start_row then
			return (ai.start_row or math.huge) < (bi.start_row or math.huge)
		end
		if ai.start_col ~= bi.start_col then
			return (ai.start_col or math.huge) < (bi.start_col or math.huge)
		end
		if ai.start_byte ~= bi.start_byte then
			return (ai.start_byte or math.huge) < (bi.start_byte or math.huge)
		end
	end
	return a_idx < b_idx
end

local function lang_for_buf(buf, opts)
	if opts and opts.lang then
		return opts.lang
	end
	local ft = (buf and vim.bo[buf] and vim.bo[buf].filetype) or ""
	return vim.treesitter.language.get_lang(ft) or ft
end

local function is_c_family_lang(buf, opts)
	local lang = lang_for_buf(buf, opts)
	return lang == "c" or lang == "cpp"
end

local function collect_rename_capture_ids(root, buf, opts)
	local ids = {}
	if not root or not buf then
		return ids
	end

	local ft = (vim.bo[buf] and vim.bo[buf].filetype) or ""
	local lang = lang_for_buf(buf, opts)

	local ok, query = pcall(vim.treesitter.query.get, lang, "diffmantic")
	if not ok or not query then
		ok, query = pcall(vim.treesitter.query.get, ft, "diffmantic")
		if not ok or not query then
			return ids
		end
	end

	for cap_id, node in query:iter_captures(root, buf, 0, -1) do
		local cap_name = query.captures[cap_id]
		if cap_name == "diff.identifier.rename" then
			ids[node:id()] = true
		end
	end
	return ids
end

local function is_candidate_update(action)
	if not action or action.type ~= "update" then
		return false
	end
	if not action.src_node or not action.dst_node then
		return false
	end
	local meta = action.metadata or {}
	local node_type = meta.node_type
	if not IDENTIFIER_TYPES[node_type] then
		return false
	end
	local old_name = trim_name(meta.old_name)
	local new_name = trim_name(meta.new_name)
	if old_name == "" or new_name == "" then
		return false
	end
	return old_name ~= new_name
end

local function pick_anchor(group, src_info)
	if not group or #group == 0 then
		return nil
	end

	local decl_like = {}
	for _, c in ipairs(group) do
		if c.decl_like then
			table.insert(decl_like, c)
		end
	end

	local target = decl_like
	if #target == 0 then
		-- Conservative guardrail: avoid converting a single isolated use to rename.
		if #group < 2 then
			return nil
		end
		target = group
	end

	table.sort(target, function(a, b)
		return node_pos_lt(src_info, a.src_id, a.idx, b.src_id, b.idx)
	end)

	return target[1]
end

local function role_kind_for_name_node(id, role_index)
	local entry = role_index and role_index[id] or nil
	if not entry then
		return nil
	end
	if entry.is_name then
		return entry.kind
	end
	return nil
end

local function is_function_decl_name_node(id, info)
	local cur = info and info[id] or nil
	while cur and cur.parent_id do
		local p = info[cur.parent_id]
		if not p then
			return false
		end
		if p.type == "function_declarator" then
			return true
		end
		cur = p
	end
	return false
end

local function is_function_container_name_node(id, info)
	local cur = info and info[id] or nil
	if not cur or not cur.parent_id then
		return false
	end
	local p = info[cur.parent_id]
	return p ~= nil and FUNCTION_CONTAINER_TYPES[p.type] == true
end

local function is_call_ref_node(id, info)
	local cur = info and info[id] or nil
	local depth = 0
	while cur and cur.parent_id and depth < 4 do
		local p = info[cur.parent_id]
		if not p then
			return false
		end
		local ptype = p.type or ""
		if ptype:find("call", 1, true) then
			return true
		end
		if ptype == "method_invocation" then
			return true
		end
		cur = p
		depth = depth + 1
	end
	return false
end

local function named_child_slot(parent_id, child_id, info)
	local parent = info and info[parent_id] or nil
	if not parent or not parent.node then
		return nil
	end
	local slot = 0
	for child in parent.node:iter_children() do
		local cid = child:id()
		local ok_named, is_named = pcall(child.named, child)
		if ok_named and is_named and info[cid] then
			slot = slot + 1
			if cid == child_id then
				return slot
			end
		end
	end
	return nil
end

local function parameter_slot_info(id, info)
	local cur_id = id
	while cur_id do
		local cur = info and info[cur_id] or nil
		if not cur then
			return nil
		end
		if cur.type == "parameter_declaration" then
			local list_id = cur.parent_id
			local list = list_id and info[list_id] or nil
			if list and list.type == "parameter_list" then
				return {
					slot = named_child_slot(list_id, cur_id, info),
					list_id = list_id,
				}
			end
			return nil
		end
		cur_id = cur.parent_id
	end
	return nil
end

local function argument_slot_info(id, info)
	local cur_id = id
	while cur_id do
		local cur = info and info[cur_id] or nil
		if not cur then
			return nil
		end
		local pid = cur.parent_id
		local p = pid and info[pid] or nil
		if p and p.type == "argument_list" then
			return {
				slot = named_child_slot(pid, cur_id, info),
				list_id = pid,
			}
		end
		cur_id = cur.parent_id
	end
	return nil
end

local function slot_info_compatible(src_slot, dst_slot, s2d)
	if not src_slot and not dst_slot then
		return true
	end
	if not src_slot or not dst_slot then
		return false
	end
	if not src_slot.slot or not dst_slot.slot or src_slot.slot ~= dst_slot.slot then
		return false
	end
	if src_slot.list_id and dst_slot.list_id and s2d[src_slot.list_id] and s2d[src_slot.list_id] ~= dst_slot.list_id then
		return false
	end
	return true
end

local function ordered_paren_slot_compatible(sid, did, src_info, dst_info, s2d)
	local src_param = parameter_slot_info(sid, src_info)
	local dst_param = parameter_slot_info(did, dst_info)
	if not slot_info_compatible(src_param, dst_param, s2d) then
		return false
	end

	local src_arg = argument_slot_info(sid, src_info)
	local dst_arg = argument_slot_info(did, dst_info)
	if not slot_info_compatible(src_arg, dst_arg, s2d) then
		return false
	end

	return true
end

local function first_identifier_descendant(node, info)
	if not node then
		return nil
	end
	local stack = { node }
	local head = 1
	local type_fallback = nil
	while head <= #stack do
		local cur = stack[head]
		head = head + 1
		local cid = cur:id()
		local cinfo = info[cid]
		if cinfo and IDENTIFIER_TYPES[cinfo.type] then
			if cinfo.type ~= "type_identifier" then
				return cur
			end
			type_fallback = type_fallback or cur
		end
		for child in cur:iter_children() do
			table.insert(stack, child)
		end
	end
	return type_fallback
end

local function realign_parameter_updates(actions, src_info, dst_info, s2d, dst_buf)
	local by_src = {}
	for idx, action in ipairs(actions or {}) do
		if action.type == "update" and action.src_node and action.dst_node then
			by_src[action.src_node:id()] = idx
		end
	end

	for src_list_id, dst_list_id in pairs(s2d or {}) do
		local src_list = src_info[src_list_id]
		local dst_list = dst_info[dst_list_id]
		if src_list and dst_list and src_list.type == "parameter_list" and dst_list.type == "parameter_list" then
			local src_slot = 0
			for src_decl in src_list.node:iter_children() do
				local ok_named_src, is_named_src = pcall(src_decl.named, src_decl)
				if not ok_named_src or not is_named_src then
					goto continue_src_decl
				end
				local src_decl_id = src_decl:id()
				local src_decl_info = src_info[src_decl_id]
				if not src_decl_info or src_decl_info.type ~= "parameter_declaration" then
					goto continue_src_decl
				end
				src_slot = src_slot + 1

				local src_name = first_identifier_descendant(src_decl, src_info)
				if not src_name then
					goto continue_src_decl
				end

				local dst_slot = 0
				local dst_name = nil
				for dst_decl in dst_list.node:iter_children() do
					local ok_named_dst, is_named_dst = pcall(dst_decl.named, dst_decl)
					if ok_named_dst and is_named_dst then
						local dst_decl_id = dst_decl:id()
						local dst_decl_info = dst_info[dst_decl_id]
						if dst_decl_info and dst_decl_info.type == "parameter_declaration" then
							dst_slot = dst_slot + 1
							if dst_slot == src_slot then
								dst_name = first_identifier_descendant(dst_decl, dst_info)
								break
							end
						end
					end
				end
				if not dst_name then
					goto continue_src_decl
				end

				local src_name_id = src_name:id()
				local dst_name_id = dst_name:id()
				if s2d[src_name_id] == dst_name_id then
					goto continue_src_decl
				end

				local idx = by_src[src_name_id]
				if not idx then
					goto continue_src_decl
				end
				local action = actions[idx]
				if not action or action.type ~= "update" then
					goto continue_src_decl
				end

				action.dst_node = dst_name
				action.dst = node_range(dst_name)
				action.metadata = action.metadata or {}
				action.metadata.new_name = node_trim_text(dst_name, dst_buf)
				action.metadata.to_line = action.dst and (action.dst.start_row + 1) or nil

				::continue_src_decl::
			end
		end
	end

	return actions
end

local function is_decl_like_pair(sid, did, src_decl_ids, dst_decl_ids, src_role_index, dst_role_index, src_info, dst_info, s2d)
	if src_decl_ids[sid] and dst_decl_ids[did] then
		return true
	end
	local src_kind = role_kind_for_name_node(sid, src_role_index)
	local dst_kind = role_kind_for_name_node(did, dst_role_index)
	if src_kind ~= nil and dst_kind ~= nil and src_kind == dst_kind then
		return true
	end
	local src_param = parameter_slot_info(sid, src_info)
	local dst_param = parameter_slot_info(did, dst_info)
	if src_param and dst_param and slot_info_compatible(src_param, dst_param, s2d) then
		return true
	end
	if is_function_container_name_node(sid, src_info) and is_function_container_name_node(did, dst_info) then
		return true
	end
	return is_function_decl_name_node(sid, src_info) and is_function_decl_name_node(did, dst_info)
end

local function collect_identifier_rename_pairs(actions)
	local out = {}
	local seen = {}
	for _, action in ipairs(actions or {}) do
		if action.type == "rename" and action.src_node and action.dst_node then
			local meta = action.metadata or {}
			local node_type = meta.node_type or ""
			if IDENTIFIER_TYPES[node_type] then
				local old_name = trim_name(meta.old_name)
				local new_name = trim_name(meta.new_name)
				if old_name == "" then
					old_name = trim_name(meta.src_text)
				end
				if new_name == "" then
					new_name = trim_name(meta.dst_text)
				end
				if is_identifier_text(old_name) and is_identifier_text(new_name) and old_name ~= new_name then
					local key = old_name .. "|" .. new_name
					if not seen[key] then
						seen[key] = true
						table.insert(out, { old_name = old_name, new_name = new_name })
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return #a.old_name > #b.old_name
	end)
	return out
end

local function apply_identifier_renames(text, rename_pairs)
	local out = text
	for _, p in ipairs(rename_pairs or {}) do
		local pattern = "%f[%w_]" .. escape_lua_pattern(p.old_name) .. "%f[^%w_]"
		out = out:gsub(pattern, p.new_name)
	end
	return out
end

local function is_condition_rename_only_update(action, rename_pairs)
	if not action or action.type ~= "update" then
		return false
	end
	local meta = action.metadata or {}
	if meta.condition_update ~= true then
		return false
	end
	local src_text = trim_name(meta.src_text)
	local dst_text = trim_name(meta.dst_text)
	if src_text == "" then
		src_text = trim_name(meta.old_name)
	end
	if dst_text == "" then
		dst_text = trim_name(meta.new_name)
	end
	if src_text == "" or dst_text == "" then
		return false
	end
	return apply_identifier_renames(src_text, rename_pairs) == dst_text
end

local function is_duplicate_of_rename(action, rename_pairs_by_node)
	if not action or action.type ~= "update" or not action.src_node or not action.dst_node then
		return false
	end
	local sid = action.src_node:id()
	local did = action.dst_node:id()
	return rename_pairs_by_node[sid .. "|" .. did] == true
end

local function preserve_coarse_update(action, _src_info, _dst_info, _src_buf, _opts)
	if not action or action.type ~= "update" then
		return false
	end
	local meta = action.metadata or {}
	return meta.node_type == "string_literal" or meta.node_type == "char_literal"
end

function M.promote(actions, ctx)
	if not actions or #actions == 0 then
		return actions
	end
	ctx = ctx or {}

	local mappings = ctx.mappings or {}
	local src_info = ctx.src_info or {}
	local dst_info = ctx.dst_info or {}
	local src_root = ctx.src_root
	local dst_root = ctx.dst_root
	local src_buf = ctx.src_buf
	local dst_buf = ctx.dst_buf
	local opts = ctx.opts or {}
	local src_role_index = opts.src_role_index or {}
	local dst_role_index = opts.dst_role_index or {}

	local s2d = build_maps(mappings)
	local src_decl_ids = collect_rename_capture_ids(src_root, src_buf, opts)
	local dst_decl_ids = collect_rename_capture_ids(dst_root, dst_buf, opts)
	actions = realign_parameter_updates(actions, src_info, dst_info, s2d, dst_buf)

	local groups = {}
	local group_order = {}
	local candidate_by_idx = {}

	for idx, action in ipairs(actions) do
		if is_candidate_update(action) then
			local sid = action.src_node:id()
			local did = action.dst_node:id()
			local pair_mapped = s2d[sid] == did
			if not pair_mapped then
				local src_param = parameter_slot_info(sid, src_info)
				local dst_param = parameter_slot_info(did, dst_info)
				pair_mapped = src_param and dst_param and slot_info_compatible(src_param, dst_param, s2d) or false
			end
			if pair_mapped then
				if not ordered_paren_slot_compatible(sid, did, src_info, dst_info, s2d) then
					goto continue_action
				end
				local meta = action.metadata or {}
				local old_name = trim_name(meta.old_name)
				local new_name = trim_name(meta.new_name)
				local node_type = meta.node_type
				local scope_key = scope_key_for_pair(sid, did, src_info, dst_info, s2d)
				local key = table.concat({
					scope_key,
					tostring(node_type),
					old_name,
					new_name,
				}, "|")
				local decl_like = is_decl_like_pair(
					sid,
					did,
					src_decl_ids,
					dst_decl_ids,
					src_role_index,
					dst_role_index,
					src_info,
					dst_info,
					s2d
				)
				if not groups[key] then
					groups[key] = {}
					table.insert(group_order, key)
				end
				table.insert(groups[key], {
					idx = idx,
					src_id = sid,
					dst_id = did,
					decl_like = decl_like,
					node_type = node_type,
					old_name = old_name,
					new_name = new_name,
				})
				candidate_by_idx[idx] = {
					src_id = sid,
					dst_id = did,
					decl_like = decl_like,
					node_type = node_type,
					old_name = old_name,
					new_name = new_name,
				}
			end
			::continue_action::
		end
	end

	local drop = {}
	local decl_anchor_ctx = {}
	for _, key in ipairs(group_order) do
		local group = groups[key]
		local anchor = pick_anchor(group, src_info)
		if anchor then
			actions[anchor.idx].type = "rename"
			if anchor.decl_like then
				local pair_key = function_pair_key(anchor.old_name, anchor.new_name)
				local ctx_entry = decl_anchor_ctx[pair_key]
				if not ctx_entry then
					ctx_entry = {
						fn_scopes = {},
						class_scopes = {},
						global = false,
						has_function_decl = false,
					}
					decl_anchor_ctx[pair_key] = ctx_entry
				end

				local src_kind = role_kind_for_name_node(anchor.src_id, src_role_index)
				local dst_kind = role_kind_for_name_node(anchor.dst_id, dst_role_index)
				local function_decl_like = (src_kind == "function" and dst_kind == "function")
					or (
						is_function_decl_name_node(anchor.src_id, src_info)
						and is_function_decl_name_node(anchor.dst_id, dst_info)
					)
				if function_decl_like then
					ctx_entry.has_function_decl = true
				end

				local fn_scope = function_scope_key_for_pair(anchor.src_id, anchor.dst_id, src_info, dst_info, s2d)
				local class_scope = class_scope_key_for_pair(anchor.src_id, anchor.dst_id, src_info, dst_info, s2d)
				if fn_scope then
					ctx_entry.fn_scopes[fn_scope] = true
				end
				if class_scope then
					ctx_entry.class_scopes[class_scope] = true
				end
				if not fn_scope and not class_scope then
					ctx_entry.global = true
				end
			end
			for _, c in ipairs(group) do
				if c.idx ~= anchor.idx then
					drop[c.idx] = true
				end
			end
		end
	end

	-- If a declaration rename was anchored, suppress matching references.
	if next(decl_anchor_ctx) ~= nil then
		for idx, c in pairs(candidate_by_idx) do
			if not drop[idx] and not c.decl_like then
				local pair_key = function_pair_key(c.old_name, c.new_name)
				local anchor_ctx = decl_anchor_ctx[pair_key]
				if not anchor_ctx then
					goto continue_candidate
				end

				-- Once a declaration rename is anchored for this pair, suppress all
				-- matching reference updates (including cross-class/method call-sites).
				drop[idx] = true
			end
			::continue_candidate::
		end
	end

	-- Remove noisy updates that duplicate an existing rename pair.
	local rename_pairs_by_node = {}
	for _, action in ipairs(actions) do
		if action.type == "rename" and action.src_node and action.dst_node then
			rename_pairs_by_node[action.src_node:id() .. "|" .. action.dst_node:id()] = true
		end
	end

	-- Remove condition updates that only reflect identifier renames.
	local rename_pairs = collect_identifier_rename_pairs(actions)
	for idx, action in ipairs(actions) do
		if not drop[idx] then
			if is_duplicate_of_rename(action, rename_pairs_by_node) then
				drop[idx] = true
			elseif is_condition_rename_only_update(action, rename_pairs) then
				drop[idx] = true
			end
		end
	end

	if opts.word_level_actions ~= true then
		for idx, action in ipairs(actions) do
			if not drop[idx] and action.type == "update" then
				local meta = action.metadata or {}
				if COARSE_DROP_UPDATE_TYPES[meta.node_type]
					and not preserve_coarse_update(action, src_info, dst_info, src_buf, opts) then
					drop[idx] = true
				end
			end
		end
	end

	if next(drop) == nil then
		return actions
	end

	local filtered = {}
	for idx, action in ipairs(actions) do
		if not drop[idx] then
			table.insert(filtered, action)
		end
	end
	return filtered
end

return M
