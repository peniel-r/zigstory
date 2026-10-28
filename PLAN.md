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

## Second pass

First pass committed as `a2d6e79`; second pass committed as `ad691b4`. Both were
pushed to `performance_optimizations` with user approval, without merging. The user chose to keep
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

## Third pass

- [x] Preserve immediate asynchronous recording with durable per-user payloads,
  automatic success cleanup, persistent failure diagnostics and safe retry.
- [x] Capture pre-execution directory, actual execution time, session identity,
  64-bit duration and exit status without reusing stale native failure codes.
- [x] Profile a read-only snapshot of local history; expose aggregate results only,
  distinguish full startup/prediction timings from TUI paging/memory measurements.
- [x] Add failure-path/metadata/migration regressions, update docs and installation
  steps, and verify `zig build run`.

The user confirmed the installed upgrade works and approved committing and
pushing the third pass and safe-upgrade automation. Keep the branch unmerged.

Third-pass validation: 21 Zig regressions passed in Debug and ReleaseFast;
73 functional checks, 14 JSON checks, 32 recording checks, and predictor
regressions passed. The same five functional skips apply. Recording coverage
includes a separate shell exiting immediately after launching its importer.
Final `zig build run -Doptimize=ReleaseFast` succeeded.

Local ReleaseFast profile of a read-only snapshot (4,108 history entries, warm OS
caches; no command text or prefixes reported):

| Measurement | Median | p95 |
| --- | --- | --- |
| CLI process startup + empty-directory metrics | 178.879 ms | 192.272 ms |
| Full predictor request with a new connection | 0.0575 ms | 0.5951 ms |
| Cached predictor request | 0.0043 ms | 0.0077 ms |
| TUI search/browsing data path | 0.7935 ms | 1.0224 ms |
| Headless TUI rendering, 160x240 stress viewport | 4.2659 ms | 4.6700 ms |

Across 80 TUI iterations, both result-arena halves peaked at 97,988 bytes;
frame-arena capacity peaked at 3,636 bytes. Sampled process working set peaked at
21,839,872 bytes (20.8 MiB). These measurements include headless rendering to a
discard sink, not terminal I/O, the input thread, or interactive startup latency.
CLI startup remains the largest measured cost; these are measurements, not a
claimed before/after speedup.

Installed files and the original history database remain unchanged. Upgrade executable first,
then profile script; no predictor update is needed. Back up the entire database
directory before upgrading because schema version 2 requires restoring that
backup when rolling back to an older binary.

## Safe upgrade automation

- [x] Add a dedicated Just recipe and fail-fast upgrade script with idle-process
  checks, persistent backups, post-install validation and database-aware rollback.
- [x] Exercise success, preflight refusal, and rollback against isolated installs;
  document invocation and recovery, then verify `zig build run`.

Added `just safe-upgrade` (no rebuild and no predictor/PATH/main-profile changes).
Backups retain executable, hook, complete history/WAL/pending files, destination
manifest and result log. Checks require a quiet installation and a NoProfile
invocation chain; validation has a 30-second timeout. Failed history is preserved
separately before restoring the original directory. Live-process or restoration
failures report blocked/incomplete recovery instead of claiming rollback success.

Isolated regressions passed for success, incomplete backup, replacement failure,
post-migration failure, a real malformed-database validation error, absent prior
history, process refusal, rollback blockage/failure and invalid profile syntax.
Real process preflight refused an active shell as intended; Just dry-run resolves
the new recipe correctly. `zig build run -Doptimize=ReleaseFast` succeeded.
The updated PowerShell runner passed functional, JSON, recording and upgrade
regressions; the existing five functional skips remain unchanged.
No actual installation/upgrade was performed. Engram impact analysis remains
unavailable because the installed tool rejects the documented `impact` command.

## Logging and remaining optimizations

- [x] Add rotating local logs to CLI/TUI, PowerShell and predictor, defaulting to
  Error; exclude commands and history contents. Validate and commit logging first
  as explicitly requested (no push requested).
- [ ] Correct Unicode truncation/highlight columns and imported-history chronology.
- [ ] Replace per-cell fills and avoid redraws without visible state changes.
- [ ] Split startup measurements into process, database and query costs; optimize
  measured bottlenecks rather than assuming a slow SQL query.
- [ ] Benchmark and improve literal substring counts/grouping/deep pagination.
- [ ] Add repeatable Windows CI performance gates and final regression validation.

Immediate recording remains required; batching and persistent-writer architecture
are excluded. Leave subsequent optimizations uncommitted pending review.

Logging validation passed: 21 core/TUI regressions, the complete PowerShell runner
(including 12 new logging checks), predictor regressions and ReleaseFast
`zig build run`. The user explicitly requested committing logging before the
remaining optimization work; no installation or push is part of this step.
