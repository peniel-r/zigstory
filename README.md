# Zigstory

> **High-Performance Shell History Manager with AI-Powered Predictions**

`zigstory` is a blazing-fast shell history manager for PowerShell that replaces the default text-file history with a powerful SQLite database. Built in Zig for maximum performance, it provides intelligent command suggestions, full-text search, and rich context tracking.

[![Built with Zig](https://img.shields.io/badge/Built%20with-Zig-orange?logo=zig)](https://ziglang.org/)
[![.NET 8](https://img.shields.io/badge/.NET-8-512BD4?logo=dotnet)](https://dotnet.microsoft.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## ✨ Features

### 🚀 **Blazing Fast Performance**

- **Sub-5ms query performance** with optimized SQLite indexes
- **<50ms command insertion** with WAL mode and async writes
- **<100ms TUI startup** with virtual scrolling for 10,000+ entries
- **Zero PowerShell startup impact** (<10ms overhead measured)

### 🧠 **AI-Powered Predictions**

- **Ghost text suggestions** as you type (powered by custom C# `ICommandPredictor`)
- **LRU caching** invalidated after committed history or rank changes
- **Cancellable SQLite queries** avoid finishing obsolete predictions
- **Adaptive prefix queries** favor text indexes for selective prefixes and ranking for broad prefixes
- **Advanced frecency ranking** based on frequency and recency scoring
- **Connection pooling** for optimal database performance

### 🔍 **Interactive Search**

- **Built-in TUI** with real-time substring search (uses LIKE queries for reliability)
- **Virtual scrolling** handles massive histories efficiently
- **Multi-select** commands for piped execution (up to 5 commands)
- **Vim-style keybindings** (j/k for navigation, Ctrl+K/J for page navigation)
- **fzf integration** for users who prefer external tools
- **Clipboard integration** - selected commands auto-copy
- **Search highlighting** - matched terms highlighted in results

### 📊 **Rich Context Tracking**

- **Execution duration** (millisecond precision)
- **Exit codes** (success/failure tracking)
- **Working directory** (context-aware suggestions)
- **Session IDs** (track command sequences)
- **Timestamps** (full history timeline)

### 🔒 **Production Ready**

- **SQLite WAL mode** for concurrent read/write operations
- **Automatic duplicate detection** during imports
- **SQL injection protection** with parameterized queries
- **Graceful error handling** prevents shell disruption
- **FTS5 support** maintained for future enhancements (current TUI uses LIKE queries)

## 🏗️ Architecture

The system uses a **Split-Brain Architecture** optimized for both write and read performance:

```text
┌─────────────────────────────────────────────────────────────┐
│                      PowerShell Session                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐              ┌──────────────────┐     │
│  │  Write Path      │              │  Read Path       │     │
│  │  (Zig)           │              │  (.NET 8)        │     │
│  │                  │              │                  │     │
│  │  • Async writes  │              │  • LRU cache     │     │
│  │  • Sanitization  │              │  • Conn pooling  │     │
│  │  • Batch insert  │              │  • <5ms queries  │     │
│  └────────┬─────────┘              └────────┬─────────┘     │
│           │                                 │               │
│           └────────────────┬────────────────┘               │
│                            │                                │
│                            ▼                                │
│                  ┌──────────────────┐                       │
│                  │  SQLite (WAL)    │                       │
│                  │  ~/.zigstory/    │                       │
│                  │  history.db      │                       │
│                  └──────────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

### Components

1. **zigstory.exe** (Zig)
   - Command-line interface for history management
   - High-performance write operations
   - Interactive TUI search interface
   - Import/export utilities

2. **zigstoryPredictor.dll** (.NET 8)
   - PowerShell `ICommandPredictor` implementation
   - Real-time ghost text suggestions
   - Optimized read-only database access
   - Thread-safe connection pooling

3. **SQLite Database**
   - WAL mode for concurrent access
   - FTS5 virtual table for full-text search
   - Optimized indexes for prefix matching
   - Automatic schema migrations

## 🛠️ Prerequisites

- **OS**: Windows (win32)
- **Shell**: PowerShell 7+
- **Build Tools**:
  - [Zig](https://ziglang.org/) 0.15.2+
  - [.NET 8 SDK](https://dotnet.microsoft.com/)
- **Optional**: [fzf](https://github.com/junegunn/fzf) for fzf-based search

## 📦 Installation

### Automated Installation (Recommended)

The easiest way to install `zigstory` is using the provided installation script. This script handles building the binaries, setting up the PowerShell profile integration, and installing the predictor module.

```powershell
# 1. Clone the repository
git clone https://github.com/yourusername/zigstory.git
cd zigstory

# 2. Build and install automatically
just install
```

The script will:

- ✅ Build the Zig CLI and C# Predictor
- ✅ Copy binaries to `%APPDATA%\zigstory`
- ✅ Add `zigstory` to your User PATH
- ✅ Install the `zigstoryPredictor` module to your PowerShell Modules directory
- ✅ Add the necessary integration to your PowerShell `$PROFILE`

### Manual Installation

If you prefer to install manually:

1. **Build the Zig CLI**:

   ```powershell
   zig build -Doptimize=ReleaseFast
   ```

2. **Build the C# Predictor**:

   ```powershell
   dotnet publish src/predictor/zigstoryPredictor.csproj -c Release -r win-x64 --self-contained false -o src/predictor/bin/publish
   ```

3. **Register the module**:
   Copy the contents of `src/predictor/bin/publish` to your PowerShell modules directory (e.g., `Documents\PowerShell\Modules\zigstoryPredictor`).

## ⚙️ Configuration

### 1. Enable Command Tracking

Add to your PowerShell profile (`notepad $PROFILE`):

```powershell
# Adjust path to where you cloned/installed zigstory
$ZigstoryPath = "C:\git\zigstory"

# Source the integration script
. "$ZigstoryPath\scripts\zsprofile.ps1"
```

This enables:

- ✅ Automatic command tracking on every execution
- ✅ Exit code and duration capture
- ✅ Working directory context
- ✅ Async writes (non-blocking prompt)

### 2. Automatic Configuration

The `zsprofile.ps1` script automatically configures:

- ✅ Predictor module loading
- ✅ Ghost text predictions enabled with `Set-PSReadLineOption -PredictionSource Plugin`
- ✅ Prediction view style set to `ListView`
- ✅ Ctrl+R keybinding for TUI search
- ✅ Ctrl+F keybinding for fzf search

The TUI reads the terminal size and draws its first frame without waiting for a
resize event. This avoids a blank alternate screen on terminals that do not emit
an initial resize event, including Windows Terminal configurations.

After updating the TUI binary, rebuild with Zig 0.16 and copy
`zig-out\bin\zigstory.exe` to `%APPDATA%\zigstory\zigstory.exe` if installed there;
the profile integration prefers that installed copy over the development binary.

For an existing installation, use the backup-aware automation instead of
`just install`. Close all other PowerShell sessions and zigstory processes, open
`pwsh -NoProfile` directly (not nested inside a still-running normal shell), and
keep other shells closed until the upgrade finishes:

```powershell
Set-Location C:\git\zigstory
# If needed, build first with Zig 0.16.0 on PATH:
just build-zig
just safe-upgrade
```

`safe-upgrade` uses the already-built executable; it does not rebuild or touch
predictor DLLs, PATH, your main PowerShell profile, or import old PSReadLine history.
It requires an existing installed executable and `zsprofile.ps1`. It checks for
active shells/importers, validates the candidate executable and profile syntax,
and creates a timestamped backup under `%USERPROFILE%\.zigstory-backups`.
Backups include the installed executable, profile script, and **entire** history
directory, including pending payloads and any WAL/SHM files.

The executable is replaced before the script, file hashes are checked, and a
database/JSON smoke check performs any schema migration. Validation commands time
out after 30 seconds. A failed upgrade returns a nonzero exit status and restores
both installed files and the original history directory. Failed-upgrade history
is moved to a separate `.zigstory.failed-upgrade-*` sibling directory, not mixed
with the restored database. Backups are retained after success or failure.

If a new recording process appears or a restore fails, rollback stops or reports
**ROLLBACK INCOMPLETE/BLOCKED**, rather than claiming success. Close all shells and
inspect the printed backup's `result.txt` and `manifest.json`: they identify the
original destinations and failed-history location. For manual recovery, preserve
the current history directory separately, restore the backup's `history`
directory in its place (or leave it absent if `had_history` is false), then restore
`zigstory.exe` and `zsprofile.ps1` to the manifest destinations. Do not copy old
database files on top of a newer WAL/SHM set. Restart PowerShell after success.
To choose a different backup root, invoke
`pwsh -NoProfile -File .\scripts\safe-upgrade.ps1 -BackupRoot 'D:\zigstory-backups'`;
it must be outside the history, executable, and profile directories.

For a manual durable-recording upgrade instead, close existing PowerShell sessions and wait for
background imports to finish. From `pwsh -NoProfile`, back up your installed
executable, `zsprofile.ps1`, and the entire `%USERPROFILE%\.zigstory` directory
(including WAL files, while no zigstory process is running). Then:

```powershell
Set-Location C:\git\zigstory
# Build with Zig 0.16.0
zig build -Doptimize=ReleaseFast
Copy-Item .\zig-out\bin\zigstory.exe "$env:APPDATA\zigstory\zigstory.exe" -Force
$profileScript = Join-Path (Split-Path $PROFILE.CurrentUserCurrentHost) 'zsprofile.ps1'
Copy-Item .\scripts\zsprofile.ps1 $profileScript -Force
```

Open a normal PowerShell session afterward. Install the executable **before** the
script: the updated hook requires `import --consume`. Schema version 2 adds an
event identity for safe retries; older version-1 binaries cannot open it. Restore
the database backup as well as the old executable if rolling back. This update
does not change predictor DLLs.

**Note:** If you prefer inline view instead of list view, add this to your profile after sourcing `zsprofile.ps1`:

```powershell
Set-PSReadLineOption -PredictionViewStyle InlineView
```

## 📖 Usage

### Quick Start

```powershell
# Import your existing PowerShell history
zigstory import

# Search your history interactively
zigstory search

# List recent commands
zigstory list 10

# Use fzf for search (requires fzf installed)
zigstory fzf
```

### Commands

#### `zigstory add`

Add a command to history (typically called by the shell hook).

```powershell
zigstory add --cmd "git status" --cwd "C:\projects" --exit 0 --duration 125
```

**Options:**

- `-c, --cmd <TEXT>` - Command text (required)
- `-w, --cwd <PATH>` - Working directory (required)
- `-e, --exit <CODE>` - Exit code (default: 0)
- `-d, --duration <MS>` - Execution duration in milliseconds (default: 0)

#### `zigstory search`

Launch the interactive TUI search interface.

**Features:**

- Real-time substring search as you type
- Paged results with full match counts and no fixed result limit
- Reusable result memory and coalesced queued edits
- Directory filtering that applies to browsing and survives clearing the query
- Unicode-aware backspace removes complete graphemes, including combined emoji
- Colons within search queries remain literal, so Windows paths are searchable
- Multi-select support (up to 5 commands)
- Keyboard navigation (↑/↓, Page Up/Down, Ctrl+K/J)
- Selected command copied to clipboard
- Indexed timestamp ordering for recent-history browsing

**Keybindings:**

- Type to filter results in real-time (case-insensitive)
- `:q` enters quit-command mode only when the search query is empty

### ⌨️ Keyboard Shortcuts

| Key | Action |
|-----|--------|
| **F2** | **Toggle predictive IntelliSense on/off** (Ghost text/ListView) |
| **Right Arrow** | Accept current prediction suggestion |
| **Ctrl+F** (in terminal) | Cycle through predictions (if multiple) |
| **Ctrl+R** | Open Interactive TUI search |
| **Ctrl+F** (in TUI) | Toggle global/current-directory filtering |
| **j/k** or **↑/↓** (in TUI)| Navigate search results |
| **Enter** (in TUI) | Accept selection and copy to clipboard |
| **Ctrl+C** (in TUI) | Close search without selection |
| **Esc** (in TUI) | Clear query; close when the query is empty |

#### `zigstory fzf`

Launch fzf-based search (requires fzf installed).

```powershell
zigstory fzf
```

#### `zigstory import`

Import existing PowerShell history.

```powershell
# Import from default PowerShell history location
zigstory import

# Import a JSON batch
zigstory import --file "C:\history.json"
```

**Features:**

- Duplicate detection for PSReadLine history
- Progress tracking during import
- Handles large history files (10,000+ commands)
- Estimates timestamps for PSReadLine history; JSON batches can supply execution time

Single-command recording and both import paths update history, command statistics,
and new-entry ranks in one transaction. JSON imports require a nonempty `cmd`;
`cwd`, `exit_code`, and `duration_ms` default to the current directory, 0, and 0.
Malformed or out-of-range fields reject the batch rather than skipping entries.
Optional `timestamp` (Unix seconds), `session_id`, `hostname`, and `event_id` retain
recorded execution metadata. Without them, the existing import-time/default
behavior is preserved. Durations and timestamps must be nonnegative. Reimporting
an `event_id` is a no-op for history, frequency, and rank; JSON without event IDs
continues allowing repeated imports.

### Diagnostic logging

CLI/TUI, PowerShell hooks and the predictor write local JSON-lines logs under
`%USERPROFILE%\.zigstory\logs`: `cli.log`, `powershell.log`, and `predictor.log`.
The default level is **Error**. Each component rotates at 1 MiB and retains one
previous file (`.log.1`); process locks serialize concurrent writes. Files are
created only when an enabled event occurs, not for successful commands.
Logs contain timestamps, component/severity, static event identifiers/templates
and error codes, never command text, input prefixes, history rows or exception
messages. Logging failures remain visible on stderr/PowerShell warnings or the
predictor's Trace error listener; they do not prevent recording.

Set environment variables before starting the application or in your profile:

```powershell
$env:ZIGSTORY_LOG_LEVEL = 'Error' # Error (default), Warning, Info, Debug, Off
# Optional custom location:
$env:ZIGSTORY_LOG_DIR = 'C:\local-logs\zigstory'
```

Level names are case insensitive. Invalid levels report a diagnostic and use Error.
Existing recording `.error` files remain independent recovery diagnostics.
Updating all logging components requires the executable, hook and rebuilt
predictor DLLs; `just safe-upgrade` updates only executable/hook, not predictor DLLs.

### Recording recovery

The hook immediately writes one JSON event to `%USERPROFILE%\.zigstory\pending`
and starts the importer directly, without `cmd.exe` or a batching delay. Successful
imports delete their own payload, even if the shell exits. Failures retain the
payload and a neighboring `.error` diagnostic; the next prompt reports failed
children, and a new session warns about outstanding payloads.

After resolving a missing executable, database lock, or other reported issue:

```powershell
Retry-ZigstoryPendingRecordings
```

Only explicitly requested retries are launched. Events are idempotent even if the
database committed but file cleanup failed. Manual recovery is also available:

```powershell
zigstory import --file "C:\path\event.json" --consume
```

`--consume` requires event IDs and deletes the source only after a successful
transaction. It preserves failed input and writes `<file>.error`. Ordinary JSON
imports never delete the source. Pending payloads contain command text: keep them
private and remove obsolete ones only after inspecting the failure.

PSReadLine captures the directory when a command is accepted, without replacing
an existing history-filtering decision. The prompt records the history entry's
start time, a shell-wide session ID, and a 64-bit duration. Successful commands
record exit 0; failed simple native invocations retain their exit code.
PowerShell/compound/dynamic failures use status 1 when an exact native code cannot
be identified. A stale `$LASTEXITCODE` is never assigned to a successful cmdlet.
Without PSReadLine, directory capture falls back to the preceding prompt's
directory; noninteractive commands without a subsequent prompt are not recorded.

### Local performance profiling

```powershell
zig build profile-tools -Doptimize=ReleaseFast
dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release -- --profile "$env:USERPROFILE\.zigstory\history.db" "$PWD\zig-out\bin\zigstory.exe" "$PWD\zig-out\bin\zigstory-tui-profile.exe"
```

The profiler makes a consistent read-only backup and migrates only the disposable
copy. It prints counts and aggregate CLI/prediction timings, plus TUI paging arena
usage and sampled process working set, including headless rendering on a
160-column/240-row stress viewport; no commands or prefixes are printed. CLI
timings include process startup and empty-directory metrics with warm OS caches.
TUI measurements exercise real search/browsing and rendering code using a discard
sink; terminal I/O, the input thread, and interactive first-frame latency are excluded.

#### `zigstory perf`

Display duration and success-rate metrics for a directory. JSON is written to
stdout with complete, correctly escaped commands, including multiline text.

```powershell
zigstory perf --cwd "C:\repo" --format json | ConvertFrom-Json
```

#### `zigstory list`

List recent commands from history.

```powershell
# Show last 5 commands (default)
zigstory list

# Show last 20 commands
zigstory list 20
```

#### `zigstory stats`

Display usage statistics and insights with ASCII visualizations.

```powershell
zigstory stats
```

**Output:**

- **Overview**: Total commands, unique commands, history span
- **Top Commands**: Most used commands ranked by frequency with last used time
- **Success Rate**: Percentage of commands that succeeded (exit_code = 0)
- **Activity**: Hourly usage distribution (ASCII bar chart)
- **Directories**: Top 5 working directories by command count

#### `zigstory recalc-rank`

Recalculate frecency ranks for all commands in history.

```powershell
zigstory recalc-rank
```

**Features:**

- Updates rank values based on current frequency and recency
- Uses formula: `rank = (frequency * 2.0) + (100.0 / days_since_last_use)`
- Progress tracking for large histories
- Batch execution for performance
- Rebuilds incomplete command statistics and handles gaps in history IDs

#### `zigstory maintenance`

Rebuild and validate the FTS index, then run SQLite's `PRAGMA optimize`. Normal
startup checks the schema version rather than scanning history or retrying ALTERs.
Existing databases receive a transactional, one-time migration; newer unsupported
schema versions are rejected without downgrading.

```powershell
zigstory maintenance
```

FTS triggers continue maintaining inserts, command edits, ID changes, and deletes.
Rank/hash-only updates no longer rewrite FTS entries. Use this explicit command
after suspected FTS inconsistency; rank/statistics repair remains `recalc-rank`.
PowerShell recording remains immediate, without a new batching delay.

#### `zigstory help`

Display comprehensive help documentation.

```powershell
zigstory help
# or
zigstory --help
```

## 🎯 Performance Benchmarks

Measured on Windows 11, AMD Ryzen 7 5800X, NVMe SSD:

| Operation | Target | Actual | Status |
|-----------|--------|--------|--------|
| Single command insert | <50ms | ~0ms | ✅ Exceeds |
| Batch insert (100 commands) | <1s | ~3ms | ✅ Exceeds |
| Search query (p95) | <5ms | <5ms | ✅ Meets |
| TUI startup | <100ms | <100ms | ✅ Meets |
| Memory usage (10K entries) | <50MB | <50MB | ✅ Meets |
| PowerShell startup overhead | <10ms | ~0.022ms | ✅ Exceeds |

## 🗺️ Roadmap

See [docs/plan.md](docs/plan.md) for the detailed development roadmap.

- [x] **Phase 1**: Core Database & CLI ✅
- [x] **Phase 2**: Write Path & Shell Integration ✅
- [x] **Phase 3**: High-Performance Predictor ✅
- [x] **Phase 4**: TUI Search Implementation ✅
- [/] **Phase 5**: Frecency Ranking & Advanced Stats (Nearly Complete)

### Current Status

**Phase 4 Complete** - The TUI search interface is fully functional with:

- ✅ Real-time substring search
- ✅ Virtual scrolling for large datasets
- ✅ Keyboard navigation with vim-style bindings
- ✅ Clipboard integration
- ✅ Performance targets met

**Phase 5 In Progress** - Advanced ranking and statistics are being implemented:

- ✅ **Frecency Algorithm**: Hybrid frequency/recency scoring implemented
- ✅ **Real-time Ranking**: Ranks calculated on every command execution
- ✅ **Batch Recalculation**: `zigstory recalc-rank` command for re-ranking history
- ✅ **Detailed Stats**: `zigstory stats` command with ASCII visualizations
- ✅ **fzf Integration**: `zigstory fzf` command with Ctrl+F binding
- ✅ **Performance**: Recalculation of 10k entries in <1s
- ✅ **Predictor Integration**: Rank-based sorting with committed-write cache invalidation
- ✅ **Directory Filtering**: Context-aware browsing and search in TUI

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

```powershell
# Clone the repository
git clone https://github.com/yourusername/zigstory.git
cd zigstory

# Build in debug mode
zig build

# Run tests
zig build test

# Build predictor in debug mode
dotnet build src/predictor/zigstoryPredictor.csproj
```

### Code Style

- **Zig**: Follow standard Zig formatting (`zig fmt`)
- **C#**: Follow .NET conventions
- **No hidden allocations** in Zig code
- **Always handle errors** with `try` or `catch`
- **Prefer `GeneralPurposeAllocator`** for debug builds

## 📊 Database Schema

The SQLite database uses the following schema:

```sql
-- Main history table
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cmd TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER,
    duration_ms INTEGER,
    session_id TEXT,
    hostname TEXT,
    timestamp INTEGER DEFAULT (strftime('%s', 'now')),
    event_id TEXT,
    rank REAL DEFAULT 0
);

CREATE UNIQUE INDEX idx_history_event ON history(event_id);

-- Command statistics for frecency
CREATE TABLE command_stats (
    cmd_hash TEXT PRIMARY KEY,
    cmd TEXT NOT NULL,
    frequency INTEGER DEFAULT 1,
    last_used INTEGER NOT NULL
);

-- Index for prefix matching
CREATE INDEX idx_cmd_prefix ON history(cmd COLLATE NOCASE);

-- Index for rank-based sorting
CREATE INDEX idx_rank ON history(rank DESC, timestamp DESC);

-- Indexes for recent history and directory-scoped browsing/metrics
CREATE INDEX idx_history_time ON history(timestamp DESC, id DESC);
CREATE INDEX idx_history_cwd_time ON history(cwd, timestamp DESC, id DESC);

-- FTS5 virtual table for full-text search
CREATE VIRTUAL TABLE history_fts USING fts5(cmd, content='history', content_rowid='id');
```

**Database Location:** `%USERPROFILE%\.zigstory\history.db`

## 🐛 Troubleshooting

### Predictor not showing suggestions

1. Verify the module is loaded:

   ```powershell
   Get-Module zigstoryPredictor
   ```

2. Check prediction source:

   ```powershell
   Get-PSReadLineOption | Select-Object PredictionSource
   ```

3. Ensure database has entries:

   ```powershell
   zigstory list 5
   ```

### TUI not launching

1. Verify binary exists:

   ```powershell
   Test-Path "C:\git\zigstory\zig-out\bin\zigstory.exe"
   ```

2. Check database location:

   ```powershell
   Test-Path "$env:USERPROFILE\.zigstory\history.db"
   ```

3. Run with verbose output:

   ```powershell
   zigstory search
   ```

### Import not finding history

PowerShell history location varies by version. Check:

```powershell
(Get-PSReadlineOption).HistorySavePath
```

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- [Zig](https://ziglang.org/) - Amazing systems programming language
- [libvaxis](https://github.com/rockorager/libvaxis) - Excellent TUI library
- [SQLite](https://www.sqlite.org/) - Rock-solid embedded database
- [PSReadLine](https://github.com/PowerShell/PSReadLine) - PowerShell readline implementation
- [fzf](https://github.com/junegunn/fzf) - Blazing fast fuzzy finder

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/zigstory/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/zigstory/discussions)
- **Documentation**: [docs/](docs/)

---

**Made with ❤️ and Zig**
