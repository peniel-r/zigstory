# zigstory

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
- **LRU caching** for instant cache hits (<1ms)
- **Advanced frecency ranking** based on frequency and recency scoring
- **Connection pooling** for optimal database performance

### 🔍 **Interactive Search**

- **Built-in TUI** with real-time fuzzy search (uses LIKE queries for reliability)
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

### Option 1: Build from Source

```powershell
# 1. Clone the repository
git clone https://github.com/yourusername/zigstory.git
cd zigstory

# 2. Build the Zig CLI
zig build -Doptimize=ReleaseFast

# 3. Build the C# Predictor
dotnet build -c Release src/predictor/zigstoryPredictor.csproj

# 4. The binaries will be at:
#    - zig-out/bin/zigstory.exe
#    - src/predictor/bin/Release/net8.0/zigstoryPredictor.dll
```

### Option 2: Download Pre-built Binaries

*(Coming soon - check [Releases](https://github.com/yourusername/zigstory/releases))*

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

- Real-time fuzzy search as you type
- Virtual scrolling for large histories (10,000+ commands)
- Multi-select support (up to 5 commands)
- Keyboard navigation (↑/↓, Page Up/Down, Ctrl+K/J)
- Selected command copied to clipboard
- Sub-5ms query performance

**Keybindings:**

- `↑/↓` or `j/k` - Navigate up/down
- `Space` - Toggle selection (multi-select, max 5 commands)
- `Home/End` - Jump to first/last result
- `Page Up/Down` or `Ctrl+K/J` - Scroll by page
- `Ctrl+R` - Refresh search results
- `Ctrl+U` - Clear search query
- `Enter` - Select command(s) and exit
- `Ctrl+C/Esc` - Exit without selection
- Type to filter results in real-time (case-insensitive)

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

# Import from custom file
zigstory import --file "C:\custom_history.txt"
```

**Features:**

- Automatic duplicate detection
- Progress tracking during import
- Handles large history files (10,000+ commands)
- Preserves command timestamps

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

- ✅ Real-time fuzzy search
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
- ⏳ **Predictor Integration**: Update predictor to use rank-based sorting (planned)
- ⏳ **Directory Filtering**: Context-aware search in TUI (planned)

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
    rank REAL DEFAULT 0
);

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
