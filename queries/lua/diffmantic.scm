(function_declaration
  name: [(identifier) (dot_index_expression) (method_index_expression)] @diff.function.name
  body: (block) @diff.function.body) @diff.function.outer

(variable_declaration
  (assignment_statement
    (variable_list name: (identifier) @diff.function.name)
    (expression_list value: (function_definition
      body: (block) @diff.function.body)))) @diff.function.outer

(variable_declaration
  (assignment_statement
    (variable_list name: (_) @diff.variable.name)
    (expression_list))) @diff.variable.outer

(assignment_statement
  (variable_list) @diff.assignment.lhs
  (expression_list) @diff.assignment.rhs) @diff.assignment.outer

(return_statement) @diff.return.outer

(identifier) @diff.identifier.rename
