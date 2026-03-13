
local M = {}


local RULES = {
	c = {
		ignored = {
			[";"] = true, [","] = true, ["."] = true,
			["("] = true, [")"] = true, ["{"] = true, ["}"] = true,
			["["] = true, ["]"] = true, ["->"] = true, [":"] = true,
			["#"] = true,
		},
		flattened = {
			string_literal    = true,
			char_literal      = true,
			system_lib_string = true,
			number_literal    = true,
		},
		aliased = {
			struct_specifier  = "class_declaration",
			union_specifier   = "class_declaration",
			enum_specifier    = "class_declaration",
			init_declarator   = "variable_declaration",
			field_declaration = "variable_declaration",
		},
	},

	cpp = {
		ignored = {
			[";"] = true, [","] = true, ["."] = true,
			["("] = true, [")"] = true, ["{"] = true, ["}"] = true,
			["["] = true, ["]"] = true, ["->"] = true, ["::"] = true,
			[":"] = true, ["#"] = true,
		},
		flattened = {
			string_literal    = true,
			char_literal      = true,
			system_lib_string = true,
			number_literal    = true,
		},
		aliased = {
			struct_specifier   = "class_declaration",
			class_specifier    = "class_declaration",
			enum_specifier     = "class_declaration",
			init_declarator    = "variable_declaration",
			field_declaration  = "variable_declaration",
		},
	},

	go = {
		ignored = {
			["\n"] = true,
			["("]  = true, [")"] = true,
			["{"]  = true, ["}"] = true,
			["."]  = true,
		},
		flattened = {
			interpreted_string_literal = true,
			raw_string_literal         = true,
		},
		aliased = {},
	},

	javascript = {
		ignored = {
			[";"] = true, ["."] = true, [","] = true,
			["{"] = true, ["}"] = true, ["("] = true, [")"] = true,
			["["] = true, ["]"] = true,
		},
		flattened = {
			string          = true,
			template_string = true,
			number          = true,
			regex           = true,
		},
		aliased = {
			arrow_function      = "function_declaration",
			function_expression = "function_declaration",
			method_definition   = "function_declaration",
			class_expression    = "class_declaration",
		},
	},

	typescript = {
		ignored = {
			[";"] = true, ["."] = true, [","] = true,
			["{"] = true, ["}"] = true, ["("] = true, [")"] = true,
			["["] = true, ["]"] = true, [":"] = true, ["?"] = true,
		},
		flattened = {
			string          = true,
			template_string = true,
			number          = true,
			regex           = true,
			union_type      = true,  -- left-recursive binary nesting; flatten for stable diffs
		},
		aliased = {
			arrow_function        = "function_declaration",
			function_expression   = "function_declaration",
			method_definition     = "function_declaration",
			class_expression      = "class_declaration",
			interface_declaration = "class_declaration",
			type_alias_declaration = "class_declaration",
		},
	},

	python = {
		ignored = {
			["("] = true, [")"] = true, ["{"] = true, ["}"] = true,
			["["] = true, ["]"] = true, ["."] = true, [":"] = true,
			[","] = true,
			["default_parameter ="] = true,
			["def"]    = true, ["for"]    = true, ["in"]     = true,
			["if"]     = true, ["with"]   = true, ["return"] = true,
		},
		flattened = {
			string             = true,
			concatenated_string = true,
		},
		aliased = {
			augmented_assignment = "assignment",
		},
		label_ignored = {},
	},

	lua = {
		ignored = {
			[";"]        = true, [","]        = true, ["."]   = true,
			["("]        = true, [")"]        = true, ["{"]   = true,
			["}"]        = true, ["["]        = true, ["]"]   = true,
			["then"]     = true, ["do"]       = true, ["end"] = true,
			["local"]    = true, ["function"] = true, ["="]   = true,
		},
		flattened = {
			string = true,
		},
		aliased = {},
		label_ignored = {},
	},
}

local EMPTY = { ignored = {}, flattened = {}, aliased = {}, label_ignored = {} }

local function qkey(parent_type, type_)
	if parent_type and parent_type ~= "" then
		return parent_type .. " " .. type_
	end
	return nil
end

local function matches(tbl, type_, parent_type)
	if not tbl then
		return false
	end
	if tbl[type_] == true then
		return true
	end
	local key = qkey(parent_type, type_)
	return key and tbl[key] == true or false
end

local function lookup_alias(tbl, type_, parent_type)
	if not tbl then
		return nil
	end
	local key = qkey(parent_type, type_)
	if key and tbl[key] ~= nil then
		return tbl[key]
	end
	return tbl[type_]
end


function M.get(lang)
	local rules = RULES[lang]
	if not rules then
		return EMPTY
	end
	rules.ignored = rules.ignored or {}
	rules.flattened = rules.flattened or {}
	rules.aliased = rules.aliased or {}
	rules.label_ignored = rules.label_ignored or {}
	return rules
end

function M.is_ignored(rules, type_, parent_type)
	return matches(rules.ignored, type_, parent_type)
end

function M.is_flattened(rules, type_, parent_type)
	return matches(rules.flattened, type_, parent_type)
end

function M.is_label_ignored(rules, type_, parent_type)
	return matches(rules.label_ignored, type_, parent_type)
end

function M.canonical_type(rules, type_, parent_type)
	return lookup_alias(rules.aliased, type_, parent_type) or type_
end

return M
