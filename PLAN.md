# Implementation status

Updated October 28, 2026. All previously approved work is committed and pushed on
`performance_optimizations`, through `64ddac2` (predictor-aware safe upgrades).
The user confirmed deployment and installed smoke testing. The branch remains
unmerged. GitHub Actions is not configured/used; local validation is the release
gate. The final follow-up pass below has also been deployed and smoke-tested by
the user, who approved committing and pushing it on October 28, 2026.

## First-pass performance and usability

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

At third-pass validation, installed files and history had not been changed.
The user subsequently upgraded successfully. Back up the entire database
directory before upgrading because schema version 2 requires restoring that
backup when rolling back to an older binary.

## Safe upgrade automation

- [x] Add a dedicated Just recipe and fail-fast upgrade script with idle-process
  checks, persistent backups, post-install validation and database-aware rollback.
- [x] Exercise success, preflight refusal, and rollback against isolated installs;
  document invocation and recovery, then verify `zig build run`.

Initially added `just safe-upgrade` without rebuilding or changing predictor/PATH/
main-profile settings. Predictor publishing/replacement was subsequently added in
`64ddac2`; PATH and the main profile remain untouched.
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
No installation was performed by the agent; the user subsequently deployed and
smoke-tested successfully. Engram impact analysis remains
unavailable because the installed tool rejects the documented `impact` command.

## Logging and remaining optimizations

- [x] Add rotating local logs to CLI/TUI, PowerShell and predictor, defaulting to
  Error; exclude commands and history contents. Validate and commit logging first
  as explicitly requested (no push requested).
- [x] Correct Unicode truncation/highlight columns and imported-history chronology.
- [x] Replace per-cell fills and avoid redraws without visible state changes.
- [x] Split startup measurements into process, database and query costs; optimize
  measured bottlenecks rather than assuming a slow SQL query.
- [x] Benchmark and improve literal substring counts/grouping/deep pagination.
- [x] Add repeatable Windows CI performance gates and final regression validation.

Immediate recording remains required; batching and persistent-writer architecture
are excluded.

Logging validation passed: 21 core/TUI regressions, the complete PowerShell runner
(including 12 new logging checks), predictor regressions and ReleaseFast
`zig build run`. The user explicitly requested committing logging before the
remaining optimization work.

Logging was committed as `9f4c1b2`; the optimization pass as `f329806`, including
the correction preserving console diagnostics when persistent logging is disabled.
Both were reviewed, pushed and subsequently deployed by the user.

The remaining pass implements cell-aware grapheme truncation/highlighting, bulk
screen/row fills, visible-state redraw suppression and chronological PSReadLine
imports. Literal searches materialize deduplicated IDs in per-state SQLite TEMP
tables, invalidate after detected local/external writes, and page by indexed
position. Latest-row selection now uses timestamp then ID consistently, including
nonmonotonic timestamps and ties. Clearing the query releases its TEMP table.
Result strings stay page-bounded; SQLite TEMP storage still grows with matches.
No new persistent migration or recording batching is introduced.

Warm 100k-row, 25k-distinct synthetic substring measurements:

| Measurement | Previous | Cached-ID implementation |
| --- | --- | --- |
| Initial query median | 55.67 ms | 59.14 ms |
| Deep page at offset 24,900 median | 42.68 ms | 0.039 ms |
| Next page median | 38.43 ms | 0.030 ms |

The initial query costs roughly 6% more; the gain is avoiding repeated grouping
and deep OFFSET work. SQLite fixture/cache peak was 10,752,184 bytes; result arena
was 22,412 bytes. Headless rendering was approximately 1.06 ms on a 4,113-row local
snapshot versus the earlier 4.27 ms on 4,108 rows; this is not an exact controlled
before/after comparison.

A validated synthetic profile: CLI empty metrics median 178.02 ms, help-only 174.26 ms;
internal runtime/environment/database/query/shutdown medians total about 3.11 ms.
External process launch/loading overhead remains unresolved; no specific host
component is blamed. Broad/narrow TUI searches peaked at 237 loaded rows and a
98,316-byte result arena in both halves. Headless frame median/p95 were
1.41/2.01 ms; sampled process working set peaked at 26,939,392 bytes.

`just prepare` applies the checked-in four-file Zig 0.16 SQLite compatibility patch
without overwriting divergent local changes. Pristine fetch/patch/ReleaseFast
tests and repeated preparation were verified. `just performance` builds profiling
tools and runs synthetic correctness/latency/memory gates locally. The checked-in
Windows workflow is an unused optional definition, not an active project service.

Final validation passed: 26 core/TUI regressions in both Debug and ReleaseFast;
73 functional checks (five existing skips), 14 JSON checks, 32 recording checks,
isolated safe-upgrade regressions, 13 logging checks, predictor regressions and
synthetic performance budgets. `zig build run -Doptimize=ReleaseFast` succeeded.
Formatting and tracked diff checks passed. Temporary investigation artifacts were
removed. Engram synchronization was attempted, but the installed tool also rejects
the documented `sync` command. Subsequent user-approved commits and deployment
are recorded in the current status above.

## Predictor deployment in safe-upgrade

- [x] Publish Release/win-x64 predictor into fresh temporary staging with SDK-local
  runtime selection; fail before installed changes if publishing/validation fails.
- [x] Back up the entire installed predictor directory and replace all published
  files, including native dependencies, without leaving stale DLLs.
- [x] Validate loading/registration and SQLite in a separate NoProfile process;
  include the predictor in rollback and preserve failed files for recovery.
- [x] Extend isolated success/failure/absence regressions, update automation docs,
  and verify the required ReleaseFast application run.

Committed and pushed as `64ddac2`; user-confirmed safe-upgrade deployment and
installed smoke testing are complete.

Validated a real Release/win-x64 publish and clean-process predictor
loading/registration/native SQLite. Expanded isolated regressions passed for
success, absent modules, failed publish, invalid staging, partial DLL replacement,
installed-module validation, predictor restoration failure, existing upgrade
rollback cases, manifest recovery destinations and staging cleanup. Displaced
modules are removed after successful validation; complete backup copies and
failed replacement directories remain available for recovery after failure.
`just safe-upgrade` dry-run and `zig build run -Doptimize=ReleaseFast` succeeded.
Only isolated fixtures were modified during agent validation.

## Final follow-up pass (high to low priority)

- [x] Add an empty same-compiler/native-CRT process baseline with process creation,
  wall and CPU timings. One run measured 163 ms empty-process median against
  143-172 ms full application medians; instrumented internal phases total ~3 ms.
  Host launch overhead is demonstrated, not eliminated or attributed to a specific
  security product. No security settings or persistent-writer architecture changed.
- [x] Replace window-partition sorting with a small SQLite latest-ID aggregate.
  Initial 100k-row/25k-distinct substring median is ~32 ms (previously ~60 ms),
  with ~0.04 ms deep pages. Preserve exact-command grouping, directory filters,
  max(timestamp, ID), local/external invalidation and bounded result strings.
- [x] Add opt-in actual-TTY first-frame, negotiation, output and input-to-frame
  timings; stamp the actual Ctrl+R launch path and provide `just terminal-profile`.
  An isolated 100x30 ConPTY check measured ~127 ms launch-to-first-frame and
  ~0.23 ms first-frame output; physical keys/display composition remain outside
  scope. Terminal-specific reports can now be collected directly on either host.
- [x] Add a local Windows x64 release ZIP/SHA256 pipeline and checksummed prebuilt
  safe upgrades without local Zig/Git/.NET SDK requirements. Preserve all existing
  backups, validation and rollback; hashes are integrity checks, not signatures.
- [x] Refresh current commit/deployment status, scoped performance claims, roadmap,
  local validation and new usage documentation. Do not treat unused Actions as
  a merge prerequisite.

The user confirmed the final safe-upgrade deployment works and approved committing
and pushing these changes. Agent validation changed only isolated fixtures.

Final local validation: 28 core/TUI regressions passed in Debug and ReleaseFast,
including reference-window comparison for the new aggregate; the complete
PowerShell runner, predictor suite, ConPTY check and tightened performance gates
passed. The final substring run measured 31.80 ms initial median/33.12 ms p95,
0.038 ms deep-page median, and a 22,412-byte result arena. The empty native-process
baseline remained ~165 ms wall, with ~63 ms in creation and ~31 ms process CPU.
`just release 0.0.0-performance` created a local Windows x64 ZIP and SHA256
sidecar under ignored `dist`; package regression tests verify compiler-free
deployment and checksum refusal against isolated installations.
