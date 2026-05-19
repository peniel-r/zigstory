# AI Agent Onboarding Guide — zigstory

**Version 1.0.0** | **Last Updated: 2026-05-19**

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Tech Stack](#2-tech-stack)
3. [Repository Layout](#3-repository-layout)
4. [Architecture & Data Flow](#4-architecture--data-flow)
5. [Database Schema](#5-database-schema)
6. [CLI Commands Reference](#6-cli-commands-reference)
7. [Zig 0.16 Patterns & Breaking Changes](#7-zig-016-patterns--breaking-changes)
8. [Zig Coding Standards](#8-zig-coding-standards)
9. [PowerShell 7+ Integration](#9-powershell-7-integration)
10. [Build, Run & Test](#10-build-run--test)
11. [ALM Workflow (Engram)](#11-alm-workflow-engram)
12. [Common Pitfalls](#12-common-pitfalls)
13. [Quick-Reference Cheatsheet](#13-quick-reference-cheatsheet)

---

## 1. Project Overview

**zigstory** is a cross-platform shell command history manager targeting PowerShell 7+ on Windows as its primary environment. It records every command executed in a shell session, stores it in a local SQLite database, and exposes a full-featured TUI (Terminal User Interface) and CLI for searching, filtering, and replaying historical commands using a frecency ranking algorithm (frequency + recency).

### Core Capabilities

| Capability | Description |
|---|---|
| **History recording** | Captures `cmd`, `cwd`, `exit_code`, `duration_ms`, `session_id`, `hostname` |
| **Frecency ranking** | Ranks commands by a combined frequency × recency score |
| **TUI search** | libvaxis-powered interactive search with fuzzy matching and directory filtering |
| **fzf integration** | Pipes history to external `fzf` for alternative fuzzy selection |
| **PowerShell import** | Bootstraps the DB from an existing PSReadline history file |
| **JSON batch import** | Bulk imports structured history from a JSON file (used by PS hooks) |
| **Stats & perf** | Aggregated usage statistics and per-directory performance metrics |
| **Clipboard** | Selected command is automatically copied to the Windows clipboard |

---

## 2. Tech Stack

### Core Languages & Runtimes

| Technology | Version | Role |
|---|---|---|
| **Zig** | **0.16.0** (minimum) | Application language — entire binary |
| **.NET SDK** | **> 8.0** | Tooling, scripting, and any auxiliary .NET utilities |
| **PowerShell** | **7+** (PS Core) | Primary target shell; history source and runtime hook |

### Zig Dependencies (declared in `build.zig.zon`)

| Package | Version / Commit | Role |
|---|---|---|
| `zig-sqlite` (`vrischmann`) | `3.48.0` · `fb73a6c` | SQLite bindings with FTS5 enabled |
| `libvaxis` (`rockorager`) | `0.6.0` · `60a507c` | TUI rendering, terminal I/O, keyboard events |

### System Libraries (Windows)

| Library | Usage |
|---|---|
| `user32.dll` | Clipboard API (`OpenClipboard`, `SetClipboardData`, …) |
| `kernel32.dll` | Global memory management (`GlobalAlloc`, `GlobalLock`, …) |

### Storage

| Layer | Technology |
|---|---|
| Persistent store | **SQLite** (WAL mode, `NORMAL` synchronous) |
| Full-text search | **FTS5** virtual table (`history_fts`) with auto-sync triggers |
| Hash index | SHA-256 command fingerprint stored in `cmd_hash` column |

### ALM

| Tool | Role |
|---|---|
| **Engram** | Issue tracking, requirements, test cases, impact analysis |

---

## 3. Repository Layout

```
zigstory/
├── build.zig              # Build script (Zig 0.16 API)
├── build.zig.zon          # Package manifest, dependency URLs + hashes
├── AGENTS.md              # AI agent workflow guide (Engram-centric)
├── AI_AGENT_ONBOARDING.md # ← this document
├── PLAN.md                # Implementation planning (create if missing)
└── src/
    ├── main.zig           # Binary entry point; CLI dispatch switch
    ├── root.zig           # Library root — re-exports db, cli, ranking
    ├── clipboard.zig      # Windows clipboard via user32/kernel32 FFI
    ├── cli/
    │   ├── args.zig       # Argument parser → Action union
    │   ├── add.zig        # `add` command — inserts one history entry
    │   ├── import.zig     # `import` — PS history file or JSON batch
    │   ├── list.zig       # `list [n]` — print last n entries
    │   ├── fzf.zig        # `fzf` — pipe to external fzf binary
    │   ├── stats.zig      # `stats` — aggregated usage report
    │   ├── perf.zig       # `perf` — per-directory performance metrics
    │   ├── recalc.zig     # `recalc-rank` — batch frecency recalculation
    │   └── help.zig       # `help` — usage text
    ├── db/
    │   ├── database.zig   # initDb, table/index/trigger creation, FTS rebuild
    │   └── ranking.zig    # Frecency math, cmd_hash, command_stats CRUD
    └── tui/
        ├── main.zig           # TuiApp struct, event loop, draw dispatch
        ├── search.zig         # SearchState, LIKE query, directory filter
        ├── render.zig         # Vaxis rendering, Dracula colour palette
        ├── scrolling.zig      # ScrollingState, DB pagination helpers
        ├── navigation.zig     # Key → NavigationAction mapping
        └── directory_filter.zig # CWD filter toggle (global ↔ local)
```

---

## 4. Architecture & Data Flow

### Command Recording (PowerShell hook → `add`)

```
PS Hook (in $PROFILE)
  └─ zigstory add --cmd <cmd> --cwd <cwd> --exit <code> --duration <ms>
       └─ cli/args.zig  →  Action.add
       └─ cli/add.zig
            ├─ validateCommand / validatePath
            ├─ generateSessionId (UUID v4 via std.Random.IoSource)
            ├─ getHostname ($COMPUTERNAME / $HOSTNAME)
            ├─ ranking.getCommandHash (SHA-256 hex)
            ├─ INSERT INTO history
            ├─ ranking.updateCommandStats  (upsert command_stats)
            └─ ranking.updateHistoryRank   (update rank column)
```

### Interactive Search (`search` → TUI)

```
zigstory search
  └─ tui/main.zig  TuiApp.init
       ├─ vaxis.Tty.init / vaxis.init / vaxis.Loop.init
       ├─ scrolling.getHistoryCount  →  total_count
       └─ scrolling.fetchHistoryPage →  initial results
  └─ TuiApp.run  (event loop)
       ├─ vaxis.enterAltScreen / queryTerminal
       ├─ loop.pollEvent / loop.tryEvent
       ├─ handleEvent
       │    ├─ Text input  →  SearchState.performSearch (LIKE query)
       │    ├─ Ctrl+F      →  directory_filter.toggleMode
       │    ├─ Ctrl+U      →  clear search query
       │    ├─ j/k / ↑↓    →  navigation.NavigationState.handleKey
       │    ├─ Shift+Space →  multi-select (max 5, piped on Enter)
       │    └─ Enter       →  select command → clipboard.copyToClipboard
       └─ draw  →  render.{fillScreen, renderTitleBar, renderStatusBar,
                           renderEntry, renderHelpBar}
```

### Frecency Ranking

```
rank = (frequency × frequency_weight)
     + (recency_weight / max(1, days_since_last_use))

Defaults:
  frequency_weight = 2.0
  recency_weight   = 100.0
  max_days         = 365
```

---

## 5. Database Schema

### `history` table

```sql
CREATE TABLE IF NOT EXISTS history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    cmd         TEXT    NOT NULL,
    cwd         TEXT    NOT NULL,
    exit_code   INTEGER,
    duration_ms INTEGER,
    session_id  TEXT,
    hostname    TEXT,
    timestamp   INTEGER DEFAULT (strftime('%s', 'now')),
    cmd_hash    TEXT,    -- SHA-256 hex of normalised command
    rank        REAL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_cmd_prefix ON history(cmd COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_rank       ON history(rank DESC, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_cmd_hash   ON history(cmd_hash);
```

### `command_stats` table

```sql
CREATE TABLE IF NOT EXISTS command_stats (
    cmd_hash  TEXT PRIMARY KEY,
    cmd       TEXT    NOT NULL,
    frequency INTEGER DEFAULT 1,
    last_used INTEGER NOT NULL
);
```

### `history_fts` virtual table (FTS5)

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS history_fts
    USING fts5(cmd, content='history', content_rowid='id');

-- Auto-sync triggers: history_ai, history_ad, history_au
```

### Database Location

```
Windows : %USERPROFILE%\.zigstory\history.db
Unix    : $HOME/.zigstory/history.db
```

### PRAGMA Settings (WAL mode)

| PRAGMA | Value | Reason |
|---|---|---|
| `journal_mode` | `WAL` | Concurrent reads during write |
| `synchronous` | `NORMAL` | Balance between safety and speed |
| `busy_timeout` | `1000` | Retry on locked DB for 1 s |

---

## 6. CLI Commands Reference

### `add` — Record a command

```powershell
zigstory add --cmd <string> --cwd <path> --exit <int> --duration <ms>
# Short flags: -c, -w, -e, -d
```

### `search` — Interactive TUI

```powershell
zigstory search
# Launches full-screen libvaxis TUI
```

**TUI Keybindings**

| Key | Action |
|---|---|
| Type text | Live fuzzy search (LIKE `%query%`) |
| `↑` / `k` | Move selection up |
| `↓` / `j` | Move selection down |
| `Enter` | Select command + copy to clipboard |
| `Shift+Space` | Toggle multi-select (max 5; Enter pipes them) |
| `Ctrl+F` | Toggle directory filter (global ↔ current dir) |
| `Ctrl+U` | Clear search query |
| `Backspace` | Delete last search character |
| `Esc` | Cancel command mode |
| `:q` `Enter` | Quit |

### `import` — Bootstrap from history file

```powershell
zigstory import                   # Auto-locate PSReadline history
zigstory import --file <path>     # Import from JSON batch file
```

**PowerShell history file lookup order:**
1. `$env:APPDATA\Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt`
2. `$env:USERPROFILE\.local\share\powershell\PSReadline\ConsoleHost_history.txt`

### `list` — Print recent history

```powershell
zigstory list          # Last 5 entries (default)
zigstory list 20       # Last 20 entries
```

### `fzf` — Pipe to fzf

```powershell
zigstory fzf           # Outputs selected command to stdout + clipboard
```

### `stats` — Usage statistics

```powershell
zigstory stats
# Prints: total/unique commands, sessions, history span,
#         success rate, top-10 commands, hourly distribution,
#         top-5 directories
```

### `perf` — Directory performance metrics

```powershell
zigstory perf
zigstory perf --cwd <path> --format json --threshold 5000
# Short flags: -c, -f, -t
# Formats: text (default), json
```

### `recalc-rank` — Batch frecency recalculation

```powershell
zigstory recalc-rank
# Populates command_stats, backfills cmd_hash, recalculates all rank values
```

### `help` / `-h` / `--help`

```powershell
zigstory help
zigstory --help
```

---

## 7. Zig 0.16 Patterns & Breaking Changes

This project targets **Zig 0.16.0** (minimum declared in `build.zig.zon`). Many standard library APIs changed significantly from 0.13/0.14. **Always use the patterns below — never revert to old APIs.**

### I/O and Filesystem

| ❌ Old (pre-0.16) | ✅ New (0.16) |
|---|---|
| `std.fs.cwd().openFile(...)` | `std.Io.Dir.cwd().openFile(io, ...)` |
| `std.fs.cwd().createDirPath(...)` | `std.Io.Dir.cwd().createDirPath(init.io, ...)` |
| `std.fs.File` | `std.Io.File` |
| `file.reader()` / `file.readAll(...)` | `file.readPositionalAll(io, buf, offset)` |
| `file.getPos()` / `file.getEndPos()` | `file.length(io)` |

### Process & Environment

| ❌ Old (pre-0.16) | ✅ New (0.16) |
|---|---|
| `std.process.argsWithAllocator(alloc)` | `process_args.iterateAllocator(allocator)` (args passed from `main(init)`) |
| `std.process.getEnvVarOwned(alloc, "KEY")` | `std.c.getenv("KEY")` → null-terminated C string |
| `std.process.getCwdAlloc(alloc)` | `std.process.currentPathAlloc(io, alloc)` |
| `main() !void` signature | `main(init: std.process.Init) !void` |

### Time

| ❌ Old (pre-0.16) | ✅ New (0.16) |
|---|---|
| `std.time.timestamp()` | `std.Io.Timestamp.now(io, .real).toSeconds()` |
| `std.time.nanoTimestamp()` | `std.Io.Timestamp.now(io, .real)` |

### Randomness

| ❌ Old (pre-0.16) | ✅ New (0.16) |
|---|---|
| `std.crypto.random.bytes(&buf)` | `var src = std.Random.IoSource{ .io = io }; src.interface().bytes(&buf)` |

### Windows Types

| ❌ Old (pre-0.16) | ✅ New (0.16) |
|---|---|
| `if (OpenClipboard(null) != 0)` | `if (OpenClipboard(null).toBool())` — `windows.BOOL` is now an enum |

### Build Script (`build.zig`)

| ❌ Old (pre-0.16) | ✅ New (0.16) |
|---|---|
| `exe.linkLibC()` | Link libc at the module level or via dependency |
| `exe.linkSystemLibrary("user32")` | `exe.root_module.linkSystemLibrary("user32", .{})` |

### libvaxis 0.6 (`vaxis`)

| ❌ Old | ✅ New (vaxis 0.6) |
|---|---|
| `loop.pollEvent()` → `Event` | `try loop.pollEvent()` — returns error union |
| `loop.tryEvent()` → `?Event` | `try loop.tryEvent()` — returns `!?Event` |
| `vx.queryTerminal(writer, ns_int)` | `vx.queryTerminal(writer, .{ .nanoseconds = … })` |
| `panic = vaxis.panic_handler` | `pub const panic = vaxis.panic_handler;` (in `main.zig` **and** `tui/main.zig`) |

---

## 8. Zig Coding Standards

These rules apply to **all** Zig code in this project:

### Memory Management

```zig
// ✅ Use ArenaAllocator for frame-scoped / request-scoped data
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

// ✅ Use per-iteration ArenaAllocator inside tight loops
while (try iter.nextAlloc(outer_allocator, .{})) |row| {
    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();
    // use row_arena.allocator() for row-local allocations
}

// ✅ Use ArrayListUnmanaged with explicit allocator
var list: std.ArrayListUnmanaged(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);

// ❌ Never use global variables for large structs
// ❌ Never use var GlobalConfig = Config{...};
```

### Allocator Selection

| Scenario | Allocator |
|---|---|
| Main function / command scope | `ArenaAllocator` wrapping `page_allocator` |
| TUI event loop frame | `ArenaAllocator.reset(.retain_capacity)` each frame |
| Per-row DB iteration | Inner `ArenaAllocator` per row |
| Background / long-lived tasks | `PoolAllocator` |
| Cross-scope string ownership | `allocator.dupe(u8, slice)` + explicit `defer free` |

### Error Handling

```zig
// ✅ Propagate errors with try
const result = try someOperation();

// ✅ Use errdefer for cleanup on error paths
const buf = try allocator.alloc(u8, size);
errdefer allocator.free(buf);

// ✅ Swallow expected errors explicitly
createTable(db) catch |err| {
    if (err != error.SQLiteError) return err;
    // otherwise: table already exists — ignore
};
```

### Naming & Style

- Types: `PascalCase` — `TuiApp`, `HistoryEntry`, `FrecencyConfig`
- Functions: `camelCase` — `initDb`, `addCommand`, `calculateFrecency`
- Constants / comptime: `SCREAMING_SNAKE_CASE` or `camelCase` depending on context
- File-private helpers: prefix with `_` or keep unexported
- Prefer `[]const u8` over `[:0]const u8` except where C interop requires sentinel

### SQLite Patterns

```zig
// ✅ Always deinit statements
var stmt = try db.prepare(query);
defer stmt.deinit();

// ✅ Reset prepared statements inside loops
try stmt.exec(.{}, .{ .field = value });
stmt.reset();  // <-- required before reuse

// ✅ Use transactions for batch writes
var begin = try db.prepare("BEGIN TRANSACTION");
defer begin.deinit();
try begin.exec(.{}, .{});
// ... batch work ...
var commit = try db.prepare("COMMIT");
defer commit.deinit();
try commit.exec(.{}, .{});
```

---

## 9. PowerShell 7+ Integration

### Why PowerShell 7+

PowerShell 7+ (PS Core) is the **primary host shell**. The project:
- Reads PSReadline's `ConsoleHost_history.txt` for bulk import
- Expects a `$PROFILE` hook to call `zigstory add` on `PSReadLine`'s `CommandValidateHandler` or similar
- Copies the selected command to the Windows clipboard so PS can paste it directly

### Setting Up the PS Profile Hook

Add the following to your `$PROFILE` (create it if absent: `New-Item -ItemType File $PROFILE -Force`):

```powershell
# ~/.config/powershell/Microsoft.PowerShell_profile.ps1
# (or $PROFILE path shown by: echo $PROFILE)

# Record every accepted command in zigstory
Set-PSReadLineOption -AddToHistoryHandler {
    param([string]$cmd)
    $cwd  = (Get-Location).Path
    $exit = $LASTEXITCODE
    $ms   = 0   # duration not available from this hook alone
    zigstory add --cmd $cmd --cwd $cwd --exit $exit --duration $ms
    return $true  # still add to PSReadLine's own history
}

# Bind Ctrl+R to zigstory TUI search
Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -ScriptBlock {
    $result = zigstory search
    if ($result) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
    }
}
```

> **Note:** The `.NET SDK > 8.0` is used for any companion scripts, test harnesses, or code-generation utilities that interact with the project from the .NET ecosystem. Ensure `dotnet --version` reports `8.x` or higher before running such tools.

### Importing Existing History

```powershell
# Auto-detect PSReadline history and import
zigstory import

# Import from a specific JSON batch file
zigstory import --file path\to\history.json
```

**JSON batch format** (array of objects):

```json
[
  {
    "cmd":         "git status",
    "cwd":         "C:\\Users\\user\\repos\\zigstory",
    "exit_code":   0,
    "duration_ms": 120
  }
]
```

---

## 10. Build, Run & Test

### Prerequisites

```powershell
# Verify Zig 0.16
zig version
# Expected output: 0.16.0 (or newer patch)

# Verify .NET SDK
dotnet --version
# Expected: 8.x.x or higher

# Verify PowerShell
$PSVersionTable.PSVersion
# Expected: Major >= 7
```

### Fetch Dependencies

```powershell
# Download and cache all declared dependencies
zig build --fetch
```

### Build

```powershell
zig build                    # Debug build (default)
zig build -Doptimize=ReleaseFast   # Optimised release build
```

### Run

```powershell
zig build run                          # Launch (prints help)
zig build run -- search                # Launch TUI search
zig build run -- stats                 # Show statistics
zig build run -- import                # Import PS history
zig build run -- add --cmd "ls" --cwd "C:\\" --exit 0 --duration 5
```

### Test

```powershell
zig build test
```

> **Work is NOT complete until `zig build run` succeeds without errors.**
> If the build fails, investigate, fix, and retry before marking any task done.

### Troubleshooting Build Failures

1. **SQLite FTS5 compile errors** — Ensure `fts5 = true` is set in the `sqlite` dependency options inside `build.zig`.
2. **`linkSystemLibrary` errors** — Use `exe.root_module.linkSystemLibrary("user32", .{})` not `exe.linkSystemLibrary(...)` (Zig 0.16 change).
3. **`std.fs.cwd()` not found** — Replace all `std.fs.cwd()` calls with `std.Io.Dir.cwd()` and pass `io`.
4. **`std.time.timestamp()` not found** — Replace with `std.Io.Timestamp.now(io, .real).toSeconds()`.
5. **`std.process.getEnvVarOwned` not found** — Use `std.c.getenv("KEY")` with `std.mem.sliceTo(ptr, 0)`.

---

## 11. ALM Workflow (Engram)

This project uses **Engram** as its Application Lifecycle Management tool. Always interact with project artifacts through Engram before modifying code.

### Standard Phase Sequence

#### Phase 1 — Initialise Context

```powershell
engram status --json | Out-File project_state.json
# Review PLAN.md (create it if absent, updating with current plan)
```

#### Phase 2 — Query Before Touching Code

```powershell
# Find open issues
engram query "type:issue AND state:open" --json

# Find untested requirements
engram query "type:requirement AND NOT link(validates, type:test_case)" --json

# Semantic search for concepts
engram query --mode vector "frecency ranking" --json
```

#### Phase 3 — Impact Analysis

```powershell
# Before modifying a source file, check what it affects
engram impact src/db/ranking.zig --json --up --down

# Find test cases that cover changed code
engram impact src/db/ranking.zig --json --down |
    ConvertFrom-Json |
    Select-Object -ExpandProperty affected_items |
    Where-Object { $_.type -eq "test_case" } |
    Select-Object -ExpandProperty id
```

#### Phase 4 — Create / Update Artifacts

```powershell
# New requirement
engram new requirement "Support frecency decay tuning via config file"

# Update status after implementation
engram update req.001 --set "context.status=implemented" --set "priority=1"

# Record a bug found during development
engram new issue "recalc-rank skips entries with NULL cmd_hash" --priority 1
```

#### Phase 5 — Validate

```powershell
zig build run   # Must succeed
engram metrics --json | ConvertFrom-Json | Select-Object test_coverage
engram release-status --json | ConvertFrom-Json | Select-Object ready
```

#### Phase 6 — Commit (only after human review)

```powershell
# Always ask for review before committing.
git add .
git commit -m "feat: add frecency config tuning (closes req.001)"
```

### EQL Quick Reference

```
# By type
type:requirement
type:issue
type:test_case

# By state
state:draft
state:open
state:implemented

# Logical
type:requirement AND state:approved
(type:issue OR type:bug) AND priority:1

# Link traversal
link(validates, req.001)
link(blocks, type:requirement)
type:requirement AND NOT link(validates, type:test_case)
```

---

## 12. Common Pitfalls

| Pitfall | Correct Approach |
|---|---|
| Using `std.fs.cwd()` | Use `std.Io.Dir.cwd()` and pass `io` |
| Forgetting `stmt.reset()` in a loop | Always call `stmt.reset()` after each `stmt.exec()` inside loops |
| Freeing DB-owned strings from `iter.next(.{})` | Use `iter.nextAlloc(allocator, .{})` to get owned copies, then free them |
| Using `std.time.timestamp()` | Use `std.Io.Timestamp.now(io, .real).toSeconds()` |
| Using `std.crypto.random` | Use `std.Random.IoSource{ .io = io }` |
| Casting `windows.BOOL` as integer | Call `.toBool()` — it is now a Zig enum |
| Using `std.process.getEnvVarOwned` | Use `std.c.getenv("KEY")` → null-term ptr → `std.mem.sliceTo(ptr, 0)` |
| Linking user32 at exe level | Link at module level: `exe.root_module.linkSystemLibrary("user32", .{})` |
| Writing global mutable state for structs | Use explicit allocator + arena/pool pattern |
| Calling `zig build run` before fixing errors | Fix all errors before claiming work is complete |
| Committing without review | Always request human review before `git commit` |

---

## 13. Quick-Reference Cheatsheet

```powershell
# ── Build & Run ──────────────────────────────────────────────
zig build                              # Compile debug
zig build -Doptimize=ReleaseFast       # Compile release
zig build run                          # Run (shows help)
zig build run -- search                # TUI search
zig build run -- import                # Import PS history
zig build run -- stats                 # Usage stats
zig build run -- recalc-rank           # Rebuild frecency ranks
zig build test                         # Run tests

# ── Database ─────────────────────────────────────────────────
# Location: %USERPROFILE%\.zigstory\history.db
# WAL mode, FTS5 enabled, frecency ranking columns

# ── Engram ALM ───────────────────────────────────────────────
engram status --json
engram query "type:issue AND state:open" --json
engram query "type:requirement AND state:approved" --json
engram impact src/db/ranking.zig --json --up --down
engram new requirement "Title" --description "..."
engram new issue "Bug description" --priority 1
engram update req.001 --set "context.status=implemented"
engram metrics --json
engram release-status --json

# ── Key Zig 0.16 Idioms ───────────────────────────────────────
# Filesystem
std.Io.Dir.cwd().openFile(io, path, .{})
std.Io.Dir.cwd().createDirPath(io, dir_path)

# Time
std.Io.Timestamp.now(io, .real).toSeconds()

# Random
var src = std.Random.IoSource{ .io = io };
src.interface().bytes(&buf);

# Environment
const val = std.c.getenv("USERPROFILE");
const slice = std.mem.sliceTo(val, 0);

# Process args (from main)
var iter = try init.minimal.args.iterateAllocator(allocator);
defer iter.deinit();
_ = iter.skip(); // skip binary name

# Windows BOOL
if (SomeWinApi().toBool()) { ... }
```

---

*For the Engram command workflow guide, see [`AGENTS.md`](./AGENTS.md).*
*For the build configuration, see [`build.zig`](./build.zig) and [`build.zig.zon`](./build.zig.zon).*
