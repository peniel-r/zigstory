# zigstory — Functional Tests

This folder contains the PowerShell 7 functional, JSON, recording, safe-upgrade and
logging regression suites. The runner executes all five; Zig core/TUI and predictor
tests run separately.

## Prerequisites

| Tool | Minimum Version |
|------|----------------|
| Zig | 0.16.0 |
| PowerShell | 7.0 |
| .NET SDK | 8.0 |
| sqlite3 (optional) | any | ← enables T20 DB-introspection tests |

## Running

```powershell
# From the repository root — build + run all tests
just prepare
pwsh -NoProfile -File tests/run_tests.ps1

# Skip rebuild (use existing zig-out\bin\zigstory.exe)
pwsh -NoProfile -File tests/run_tests.ps1 -SkipBuild

# Show stdout/stderr for every command under test
pwsh -NoProfile -File tests/run_tests.ps1 -Verbose

# Keep the temporary test database after the run (for inspection)
pwsh -NoProfile -File tests/run_tests.ps1 -KeepDb
```

## Test Groups

Core and TUI regressions run with Zig 0.16:

```powershell
zig build test
zig build test-core
zig build test-tui
zig build test -Doptimize=ReleaseFast

# After building the executable
pwsh -NoProfile -File tests\json_regressions.ps1
pwsh -NoProfile -File tests\recording_regressions.ps1
```

Core tests check index selection, atomic recording/imports, validation, recency,
statistics repair, and rank recalculation with sparse IDs. TUI tests cover startup
resource ownership/first-frame rendering, more than 50,000 matches, directory
filtering, queued edits, page navigation, large viewports, and bounded result
memory. JSON regressions exercise the actual PowerShell recording serializer and
CLI output, including long, quoted, multiline, and Unicode commands. They extract
the recording helpers and mock process launch without installing hooks.
Core regressions also cover legacy-schema migration, atomic rollback, future
schema rejection, bounded startup page reads, FTS maintenance, and metadata-only
updates. TUI regressions include Unicode grapheme deletion and Windows-path
colons, cell-aware truncation/highlighting, unchanged-event redraw suppression,
deterministic latest-row deduplication, independent search caches, and cache
invalidation after same-connection and external writes (including read-only main
connections). Core tests also verify PSReadLine import chronology.
JSON regressions exercise the explicit maintenance command. Recording
tests run real asynchronous importers against isolated history, covering launch,
import, database-startup and post-commit cleanup failures, retry/deduplication,
shell exit before import completes, 64-bit duration, history-filter preservation,
and prompt status/directory/time.
They extract helper functions without loading the complete profile or predictor.

`pwsh -NoProfile -File tests\upgrade_regressions.ps1` exercises safe upgrades on
isolated installations with real executable/database validation. It publishes the
real predictor once and validates loading, registration and native SQLite in
separate NoProfile processes, then reuses that publish for the isolated cases.
It requires the .NET SDK and may restore the project's existing dependencies.
It covers
backups, replacement failure, post-migration failure, exact database restoration,
pending payloads, WAL separation, no prior history, busy-shell refusal, blocked or
incomplete rollback, and invalid source profiles. Predictor cases cover complete
module backups, stale-file removal, fresh installation, publishing/staging failures,
partial replacement, installed-module validation failure, native dependency
restoration, absence-preserving rollback, predictor restore failure, manifest
destinations and temporary-directory cleanup. Process inventory and injected
failures are mocked; no installed files or real user history are changed. This
suite also runs through `tests\run_tests.ps1`.

`tests\logging_regressions.ps1` verifies CLI/PowerShell default Error filtering,
case-insensitive overrides, Off, one-MiB rotation, private argument handling and
visible log-write failures in isolated directories. Predictor regressions verify
its default filtering, rotation and persistent database-error diagnostics.

For aggregate profiling of a real local history, without printing command text:

```powershell
zig build -Doptimize=ReleaseFast
zig build profile-tools -Doptimize=ReleaseFast
dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release -- --profile "$env:USERPROFILE\.zigstory\history.db" "$PWD\zig-out\bin\zigstory.exe" "$PWD\zig-out\bin\zigstory-tui-profile.exe"
```

The profiler opens the source read-only and uses SQLite backup to include committed
WAL data, then migrates/profiles/deletes its temporary snapshot. It measures full
CLI process startup plus an empty-directory query, prediction requests on
internally sampled prefixes, and actual TUI search/browsing pages. It reports
median/p95 times and first/second-half result-arena peaks to expose memory growth.
It separately reports help-only process overhead and 21-sample internal runtime,
environment, database, query and shutdown timings using `zigstory-startup-profile`.
The TUI profiler also runs real rendering on a headless 160x240 stress viewport
with output discarded, alternates narrow/broad substring searches and browsing,
and reports frame-arena capacity and render timings.
Sampled process memory excludes terminal I/O and the input thread; interactive
first-frame latency is not measured.

Predictor regressions use an isolated .NET console harness without additional
test-framework packages:

```powershell
dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release
# Optional 100,000-row warm query benchmark (median of 21 runs)
dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release -- --benchmark
```

These check cache freshness after committed writes/rank changes, stable suggestion
ownership, literal wildcard/path handling, concurrent callers, in-flight SQLite
cancellation, and error diagnostics. All databases are temporary; no profile is
loaded or installed.

## Performance gates

```powershell
just performance
```

Requires Zig 0.16.0, .NET SDK 8+ and prepared dependencies (`just prepare`).
The recipe builds ReleaseFast CLI/profile tools and runs temporary synthetic
100,000-row fixtures. No installed files, profile or user history are modified.

| Budget | Limit |
| --- | --- |
| Full CLI startup plus empty metrics p95 | < 1,000 ms |
| New-connection / cached prediction p95 | < 50 / 10 ms |
| Headless 160x240 frame p95 | < 50 ms |
| Loaded TUI rows / result-arena capacity | <= 237 / < 1 MiB |
| Second-half result-arena peak | <= first-half peak |
| Sampled TUI process working set | < 128 MiB |
| Broad substring initial / deep-page p95 | < 500 / 10 ms |
| SQLite synthetic fixture/cache memory peak | < 64 MiB |

`zigstory-search-benchmark` checks 25,000 distinct matches across 100,000 rows,
including nonmonotonic timestamps, and measures 21 initial/deep/next-page samples.
Result-string arenas are bounded independently of SQLite TEMP ID storage.
Budgets use warm OS caches and generous regression thresholds, not universal
latency promises. Process-memory sampling may miss transient peaks.

`.github\workflows\performance.yml` prepares pinned dependencies, runs Debug and
ReleaseFast Zig regressions, `zig build run`, PowerShell/predictor regressions,
and these budgets on Windows. Local equivalents have been exercised; the newly
added hosted workflow still needs its first GitHub run after publication.

| ID | Area | What is tested |
|----|------|----------------|
| T01 | `help` | No-args, `--help`, `-h` — output structure |
| T02 | `add` | Single inserts with long and short flags |
| T03 | `add` validation | Missing required args produce an error |
| T04 | `import --file` | JSON batch import, count reporting, idempotency |
| T05 | `import` (auto) | Auto-locate PSReadline history file |
| T06 | `list` | Default count, explicit count, boundary |
| T07 | `stats` | All sections present, total count > 0 |
| T08 | `perf` text | Duration format, slow-command detection |
| T09 | `perf --format json` | JSON field presence and value sanity |
| T10 | `perf --threshold` | Custom threshold triggers warning |
| T11 | `recalc-rank` | Exit 0, idempotency |
| T12 | high-volume `add` | 20 sequential inserts, stats consistency |
| T13 | `list` boundary | `list 0` does not crash |
| T14 | `perf` unknown dir | Unknown cwd exits 0 |
| T15 | `import` missing file | Error reported, non-zero exit |
| T16 | special characters | Quotes, backslashes, `&`, `?` in cmd |
| T17 | Unicode / emoji | Multi-byte characters in cmd field |
| T18 | `perf --format text` | Explicit text format |
| T19 | `recalc-rank` post-bulk | Ranks rebuilt after mass inserts |
| T20 | DB introspection | sqlite3 row counts, FTS5 index health |

## Isolation

Each run creates a fresh temporary directory under `$env:TEMP` (e.g.
`%TEMP%\zigstory_functional_test_<8 hex chars>`), overrides `$env:USERPROFILE`,
`$env:HOME`, and `$env:APPDATA` for the duration of the run, then deletes the
directory on exit.  No existing user data is touched.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All tests passed |
| `1` | One or more tests failed |
