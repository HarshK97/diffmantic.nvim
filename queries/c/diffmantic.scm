(function_definition
  declarator: (function_declarator
    declarator: (identifier) @diff.function.name)
  body: (compound_statement) @diff.function.body) @diff.function.outer

(struct_specifier
  name: (type_identifier) @diff.class.name
  body: (field_declaration_list) @diff.class.body) @diff.class.outer

(union_specifier
  name: (type_identifier) @diff.class.name
  body: (field_declaration_list) @diff.class.body) @diff.class.outer

(enum_specifier
  name: (type_identifier) @diff.class.name
  body: (enumerator_list) @diff.class.body) @diff.class.outer

(init_declarator
  declarator: [(identifier) (field_identifier)] @diff.variable.name) @diff.variable.outer

(assignment_expression
  left: (_) @diff.assignment.lhs
  right: (_) @diff.assignment.rhs) @diff.assignment.outer

(return_statement) @diff.return.outer
(preproc_include) @diff.preproc.outer
(preproc_def) @diff.preproc.outer
(preproc_function_def) @diff.preproc.outer

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @diff.identifier.rename))

(struct_specifier
  name: (type_identifier) @diff.identifier.rename)

(union_specifier
  name: (type_identifier) @diff.identifier.rename)

(enum_specifier
  name: (type_identifier) @diff.identifier.rename)

(init_declarator
  declarator: [(identifier) (field_identifier)] @diff.identifier.rename)
