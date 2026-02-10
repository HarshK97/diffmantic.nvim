(function_declaration
  name: (identifier) @diff.function.name
  body: (statement_block) @diff.function.body) @diff.function.outer

(method_definition
  name: (property_identifier) @diff.function.name
  body: (statement_block) @diff.function.body) @diff.function.outer

(class_declaration
  name: (identifier) @diff.class.name
  body: (class_body) @diff.class.body) @diff.class.outer

(variable_declarator
  name: [(identifier) (object_pattern) (array_pattern)] @diff.variable.name) @diff.variable.outer

(assignment_expression
  left: (_) @diff.assignment.lhs
  right: (_) @diff.assignment.rhs) @diff.assignment.outer

(import_statement) @diff.import.outer
(return_statement) @diff.return.outer

[(identifier) (property_identifier)] @diff.identifier.rename
