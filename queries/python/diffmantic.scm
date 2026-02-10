(function_definition
  name: (identifier) @diff.function.name
  body: (block) @diff.function.body) @diff.function.outer

(class_definition
  name: (identifier) @diff.class.name
  body: (block) @diff.class.body) @diff.class.outer

(assignment
  left: (_) @diff.assignment.lhs
  right: (_) @diff.assignment.rhs) @diff.assignment.outer

(import_statement) @diff.import.outer
(import_from_statement) @diff.import.outer
(return_statement) @diff.return.outer

(identifier) @diff.identifier.rename
