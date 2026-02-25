(function_definition
  declarator: (function_declarator)
  body: (compound_statement) @diff.function.body) @diff.function.outer

(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator))
  body: (compound_statement) @diff.function.body) @diff.function.outer

(function_declarator
  declarator: (identifier) @diff.function.name)

(function_declarator
  declarator: (pointer_declarator
    declarator: (identifier) @diff.function.name))

(class_specifier
  name: (type_identifier) @diff.class.name
  body: (field_declaration_list) @diff.class.body) @diff.class.outer

(struct_specifier
  name: (type_identifier) @diff.class.name
  body: (field_declaration_list) @diff.class.body) @diff.class.outer

(init_declarator
  declarator: [
    (identifier) @diff.variable.name
    (field_identifier) @diff.variable.name
  ]) @diff.variable.outer

(field_declaration
  declarator: [
    (field_identifier) @diff.variable.name
    (pointer_declarator
      declarator: (field_identifier) @diff.variable.name)
    (array_declarator
      declarator: (field_identifier) @diff.variable.name)
    (pointer_declarator
      declarator: (array_declarator
        declarator: (field_identifier) @diff.variable.name))
    (array_declarator
      declarator: (pointer_declarator
        declarator: (field_identifier) @diff.variable.name))
  ]) @diff.variable.outer

(field_declaration
  [
    (field_identifier) @diff.variable.name
    (pointer_declarator
      declarator: (field_identifier) @diff.variable.name)
    (array_declarator
      declarator: (field_identifier) @diff.variable.name)
    (pointer_declarator
      declarator: (array_declarator
        declarator: (field_identifier) @diff.variable.name))
    (array_declarator
      declarator: (pointer_declarator
        declarator: (field_identifier) @diff.variable.name))
  ]) @diff.variable.outer

(assignment_expression
  left: (_) @diff.assignment.lhs
  right: (_) @diff.assignment.rhs) @diff.assignment.outer

(return_statement) @diff.return.outer
(preproc_include) @diff.preproc.outer
(preproc_def) @diff.preproc.outer
(preproc_function_def) @diff.preproc.outer

(function_declarator
  declarator: (identifier) @diff.identifier.rename)

(function_declarator
  declarator: (pointer_declarator
    declarator: (identifier) @diff.identifier.rename))

(class_specifier
  name: (type_identifier) @diff.identifier.rename)

(struct_specifier
  name: (type_identifier) @diff.identifier.rename)

(init_declarator
  declarator: [
    (identifier) @diff.identifier.rename
  ])
