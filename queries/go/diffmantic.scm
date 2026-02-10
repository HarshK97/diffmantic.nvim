(function_declaration
  name: (identifier) @diff.function.name
  body: (block) @diff.function.body) @diff.function.outer

(method_declaration
  name: (field_identifier) @diff.function.name
  body: (block) @diff.function.body) @diff.function.outer

(type_declaration
  (type_spec
    name: (type_identifier) @diff.class.name
    type: (struct_type) @diff.class.body)) @diff.class.outer

(var_declaration
  (var_spec
    name: (identifier) @diff.variable.name)) @diff.variable.outer

(short_var_declaration
  left: (expression_list (identifier) @diff.variable.name)) @diff.variable.outer

(assignment_statement
  left: (_) @diff.assignment.lhs
  right: (_) @diff.assignment.rhs) @diff.assignment.outer

(import_declaration) @diff.import.outer
(return_statement) @diff.return.outer

[(identifier) (field_identifier) (type_identifier)] @diff.identifier.rename
