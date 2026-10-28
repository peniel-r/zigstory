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

## Second pass (uncommitted)

First pass committed as `a2d6e79`; do not merge or push. The user chose to keep
immediate recording, so write batching is deferred.

- [x] Version database migrations; remove full-history startup scans and repeated
  ALTER attempts. Provide explicit FTS rebuild/optimization maintenance and avoid
  FTS updates for rank/hash-only changes.
- [x] Improve predictor cancellation, invalidate cached results after committed
  database changes, preserve returned suggestion ownership, and measure prefix
  query plans before selecting them.
- [x] Delete complete Unicode graphemes and permit colons in Windows-path searches
  while retaining `:q` from an empty query.
- [x] Add targeted regressions, benchmark representative histories, update docs,
  run functional suites and `zig build run`; leave the second pass for review.

Second-pass validation: 19 Zig regressions passed in Debug and ReleaseFast;
73 functional checks, 14 JSON/maintenance checks, and predictor regressions
passed. The same five functional skips apply as above. Final `zig build run`
succeeded. Migration tests also verify fewer than 50 SQLite page-cache misses on
reopening a migrated 10,000-row history, with no schema changes on reopen.

Warm 100,000-row query benchmark (median of 21 runs; SQL work only, not complete
prediction latency):

| Prefix | Previous query | Adaptive production query |
| --- | --- | --- |
| `git` (broad) | 0.058 ms | 0.075 ms |
| `notfound` | 19.756 ms | 0.011 ms |
| `git status 10000` (selective) | 23.003 ms | 0.025 ms |

Always using the bound-prefix plan took 11.019 ms for broad `git`; the bounded
128-candidate probe avoids that regression at a small common-prefix overhead.
These synthetic measurements are not a universal latency guarantee.
