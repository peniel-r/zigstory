# First-pass performance and usability

- [x] Fast-forward local `main` to `zig016-migration`, preserving that branch.
- [x] Create `performance_optimizations`; obtain user approval to commit the first pass.
- [x] Add timestamp and directory/timestamp indexes with deterministic ordering.
- [x] Share prepared recording statements across single and batch writes; update
  history, command statistics, and ranks atomically. Repair incomplete statistics
  during explicit rank recalculation, including databases with gaps in IDs.
- [x] Paginate substring search without reducing accessible results; reclaim old
  result memory, coalesce queued edits, and preserve filtering/counts on clear.
- [x] Use JSON serializers for PowerShell recording and `perf --format json`.
- [x] Add regression coverage, run the functional suite and `zig build run` with
  Zig 0.16, and update directly related documentation.

Validation completed with Zig 0.16.0: 13 core/TUI tests passed in both Debug and
ReleaseFast; 73 functional checks and 11 JSON regression checks passed. The
functional runner skipped its build step (the binary was rebuilt separately) and
four optional sqlite3 checks because sqlite3 is unavailable. Core tests verify
the new index query plans directly. Final `zig build run` succeeded.

The installed Engram executable does not support this project's documented
`status` or `impact` commands; those checks were attempted before source edits.
Do not push or commit the optimization changes without human review.
