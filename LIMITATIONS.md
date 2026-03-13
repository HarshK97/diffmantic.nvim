# diffmantic.nvim Limitations (v0.5 alpha track)

This document lists current constraints of the rewritten semantic diff pipeline.
These limitations are used to prioritize roadmap milestones.

## Scope

- Goal right now: stable semantic signal for review workflows, not full refactor intelligence.
- Existing quality assets: fixture comparisons (`test/comparison`) and benchmark script (`test/benchmark.lua`).
- Test coverage is still incomplete and not yet enforced as CI quality gates.

## Known Limitations

### L1) Move detection is function/struct level only

Move detection works at the top-level declaration boundary — functions, structs,
and similar named containers. Sub-block moves (if/else branches, class methods,
loop bodies) are not tracked as moves and will appear as deletes + inserts instead.

Planned in roadmap: v0.7.0.

### L2) No side-by-side alignment or filler lines

The side-by-side view has no filler line insertion. When one side has significantly
more content than the other, the two panels drift out of visual sync. There is no
blank-line padding to keep corresponding hunks aligned.

Planned in roadmap: v0.6.0.

### L3) Update hunk granularity is heuristic

`analysis.lua` uses practical hunk refinement rules, but some edits still render
as broader node/line-level changes than ideal token-level spans.

Planned in roadmap: v0.6.0-v0.7.0.

### L4) Query quality varies by language and construct

Query packs exist for `c`, `cpp`, `go`, `javascript`, `lua`, `python`, and
`typescript`, but semantic-role quality still depends on grammar/query coverage
for each construct.

Planned in roadmap: v0.6.0+ with broader hardening in v0.7.0.

### L5) No native `:diffthis`/`:diffget`/`:diffput` integration

Current rendering uses extmarks/signs in plugin-managed windows. Native diff
operations and fold semantics are not integrated. No integration is planned
in the near-term roadmap.

### L6) Performance degrades on larger files

The pipeline has not been optimized for large inputs. Files approaching or
exceeding ~2500 lines of code will see noticeable slowdowns. There is no
time-budget threshold or large-file guardrail yet.

Planned in roadmap: v0.6.0 (guardrails/threshold), v0.9.0-v1.0.0 (full optimization pass).

### L7) No enforced performance/correctness gates

Benchmarks and fixtures are available, but there is no formal pass/fail budget
or regression gate on performance/correctness yet.

Planned in roadmap: v0.9.0-v1.0.0.

## Roadmap Link

See `ROADMAP.md` for milestone mapping and expected sequence of fixes.
