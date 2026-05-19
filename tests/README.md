# zigstory — Functional Tests

This folder contains the PowerShell 7 functional test suite for zigstory.

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
pwsh -NoProfile -File tests/run_tests.ps1

# Skip rebuild (use existing zig-out\bin\zigstory.exe)
pwsh -NoProfile -File tests/run_tests.ps1 -SkipBuild

# Show stdout/stderr for every command under test
pwsh -NoProfile -File tests/run_tests.ps1 -Verbose

# Keep the temporary test database after the run (for inspection)
pwsh -NoProfile -File tests/run_tests.ps1 -KeepDb
```

## Test Groups

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
