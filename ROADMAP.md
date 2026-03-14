# diffmantic.nvim Roadmap: v0.5 -> v1.0

## Current State

Why: stabilize the rewritten core pipeline before broadening integrations.

- [x] Written core pipeline (`pre_match -> top_down -> bottom_up -> recovery -> actions`)
- [x] Unified engine entrypoint in `lua/diffmantic/core.lua` (`core.diff`)
- [x] Side-by-side semantic UI rendering path
- [x] Query packs present for `c`, `cpp`, `go`, `javascript`, `lua`, `python`, `typescript` (+ `fallback`)
- [x] Comparison fixtures and benchmark script in `test/`
- [ ] ~~Filler lines for alignment~~
- [x] Known limitations documented (`LIMITATIONS.md`)

## v0.6.0 - Usability and Stability

Why: make day-to-day usage safer and less noisy.

- [ ] Configuration surface for matching and UI knobs
- [ ] Community feedback loop for query quality and language support
- [ ] Filler lines for alignment in side-by-side mode
- [ ] Better error handling
- [ ] Large-file guardrails and time budget controls
- [ ] Navigation helpers (`next`/`prev` semantic change)
- [ ] Noise reduction for rename/update edge cases
- [ ] Smoke tests for core command flow

## v0.7.0 - Accuracy and Communicate with Plugin Developers

Why: improve correctness on real refactors and add regression confidence.

- [ ] Better handling for extract-method and related structural refactors
- [ ] Communicate with Plugin Developers about API shape and integration points
- [ ] More precise update hunks for multiline edits
- [ ] Expanded language-query quality checks
- [ ] Core regression tests for top-down/bottom-up/recovery/action phases
- [ ] User docs for troubleshooting and tuning

## v0.8.0 - Git-Facing Foundation

Why: connect semantic diff output to practical git workflows.

- [ ] Compare working tree vs staged file content
- [ ] Compare file content between commits/branches
- [ ] Validate behavior around ignored/generated files
- [ ] Integration tests for git input -> semantic pipeline

## v0.9.0 - API and Ecosystem Polish

Why: prepare for wider adoption and downstream integrations.

- [ ] Stabilize public Lua API shape and return payloads
- [ ] Improve command UX and completion behavior
- [ ] Performance profiling pass on larger fixtures
- [ ] Regression suite combining correctness + benchmark checks
- [ ] Examples for plugin-level integration

## v1.0.0 - Hardening

Why: production-ready behavior for large code reviews.

- [ ] Performance hardening (caching, fewer traversals)
- [ ] Non-blocking execution path for heavy diffs
- [ ] Stable configuration and migration notes
- [ ] Reliability baseline on larger multi-language repositories
