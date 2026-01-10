# Design Document: `zigstory` (Zig History Manager)

**Status:** Draft
**Target Shell:** PowerShell 7+
**Core Tech:** Zig 0.15.2+, SQLite 3, .NET 8 (Adapter only)

## 1. Abstract

`zigstory` is a shell history manager designed to replace the default PowerShell history with a persistent, context-aware SQLite database. It provides two primary interfaces:

1. **Interactive Search:** A rich, high-performance TUI (Text User Interface) built in Zig using `libvaxis`.
2. **Inline Predictions:** "Ghost text" suggestions as you type, integrated natively via a C# adapter.

## 2. System Architecture

The system follows a **Shared-Database** pattern. The SQLite database acts as the central source of truth, decoupled from the shell's runtime memory. This allows the heavy lifting (UI, indexing, writing) to happen in Zig, while the latency-sensitive read operations (predictive text) happen directly inside the PowerShell process via the C# adapter.

### Component Interaction Flow

1. **Write Path (Zig):**

* User types command `git commit -m "wip"`.
* PowerShell hook triggers `zigstory.exe add`.
* Zig binary sanitizes input, gathers stats (exit code, duration), and performs an `INSERT` into SQLite.

1. **Read Path A: Predictions (C#):**

* User types `gi`.
* PowerShell calls `zigstoryPredictor.dll` (loaded in memory).
* Adapter performs a sub-5ms `SELECT` query on SQLite.
* Ghost text `git commit ...` appears instantly.

1. **Read Path B: Search (Zig):**

* User presses `Ctrl+R`.
* `zigstory.exe search` launches, taking over the terminal via `libvaxis`.
* User selects a command.
* Zig prints the command to `stdout` and exits; PowerShell executes it.

---

## 3. Database Schema (SQLite)

The database must be initialized in **WAL (Write-Ahead Logging)** mode to allow simultaneous reads (by the C# adapter) and writes (by the Zig CLI).

### Configuration

* **Journal Mode:** `WAL` (Crucial for concurrency)
* **Synchronous:** `NORMAL` (Balance between safety and speed)

### Tables

```sql
-- Main history storage
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cmd TEXT NOT NULL,
    cwd TEXT NOT NULL,         -- Current Working Directory
    exit_code INTEGER,
    duration_ms INTEGER,
    session_id TEXT,           -- To correlate commands within one open terminal
    hostname TEXT,
    timestamp INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Optimization: Index for "starts with" queries (used by C# Predictor)
CREATE INDEX idx_cmd_prefix ON history(cmd COLLATE NOCASE);

-- Optimization: Full Text Search for TUI (used by Zig)
CREATE VIRTUAL TABLE history_fts USING fts5(cmd, content='history', content_rowid='id');

```

---

## 4. Component 1: The Core Application (Zig)

**Binary Name:** `zigstory.exe`
**Responsibilities:** Database management, Data ingestion, TUI Search.
**Libraries:** `libvaxis` (TUI), `zig-sqlite` (DB).

### CLI Arguments

* `add --cmd "..." --cwd "..." --exit 0`: Inserts a record.
* `search`: Launches the TUI.
* `import`: Imports existing PS history (one-time migration).

### TUI Implementation Details (`libvaxis`)

The TUI prioritizes performance. It does not load the entire history into memory.

1. **Virtual Scrolling:** Only fetches the 50-100 rows visible on screen from SQLite.

2. **Fuzzy Search:** Uses SQLite FTS5 queries (`MATCH 'query*'`) instead of client-side filtering.

3. **Rendering:**

* **Columns:** Timestamp (dimmed), Duration (if > 1s), Command (syntax highlighted if possible), Directory (right-aligned).
* **Styles:** Failed commands (`exit_code != 0`) rendered in Red.

### Sample Code: WAL Mode Initialization

```zig
pub fn initDb(path: []const u8) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = path },
        .open_flags = .{ .write = true, .create = true, .read = true },
        .threading_mode = .MultiThread,
    });
    
    // Critical for shared access with C# adapter
    try db.exec("PRAGMA journal_mode=WAL;", .{}, .{});
    try db.exec("PRAGMA synchronous=NORMAL;", .{}, .{});
    try db.exec("PRAGMA busy_timeout=1000;", .{}, .{}); // Wait 1s if locked
    
    return db;
}

```

---

## 5. Component 2: The Predictor (C# / .NET)

**Artifact Name:** `zigstoryPredictor.dll`
**Responsibilities:** Implement `ICommandPredictor` interface for `PSReadLine`.

This component is purely a "Reader". It never writes to the DB. It is designed to be as small as possible to minimize PowerShell startup time.

### Class Structure

```csharp
public class zigstoryPredictor : ICommandPredictor
{
    // ... GUID and metadata props ...

    public SuggestionPackage GetSuggestion(PredictionClient client, PredictionContext context, CancellationToken token)
    {
        string input = context.InputAst.Extent.Text;
        if (input.Length < 2) return default; // Optimization: Don't query on 1 char

        // Query optimized for the 'idx_cmd_prefix' index
        // "SELECT cmd FROM history WHERE cmd LIKE @p || '%' ORDER BY timestamp DESC LIMIT 5"
    }
}

```

---

## 6. Integration: PowerShell Profile

The "glue" script connects the user actions to the specific binary.

```powershell
$zigstoryBin = "C:\bin\zigstory.exe"
$zigstoryDll = "C:\bin\zigstoryPredictor.dll"

# 1. Load the Predictor (Ghost Text)
Import-Module $zigstoryDll
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Set-PSReadLineOption -PredictionViewStyle InlineView

# 2. Hook: After every command, write to DB
# We use a custom function to capture Exit Code accurately
function Global:Prompt {
    $lastExit = $LASTEXITCODE
    # Run asynchronously (-NoNewWindow) to avoid blocking the prompt
    Start-Process -FilePath $zigstoryBin -ArgumentList "add", "--exit", $lastExit, "--cwd", "$PWD", "--cmd", "$LastHistoryItem" -NoNewWindow
    
    return "PS $PWD> "
}

# 3. Hook: Ctrl+R for Search
Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock {
    $result = & $zigstoryBin search
    if ($result) {
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
    }
}

```

---

## 7. Future Considerations & Extensions

1. **Machine Learning Ranking:**

* Currently, we use `ORDER BY timestamp DESC`.
* *Upgrade:* Add a `rank` column in Zig. Calculate rank based on usage frequency + recency (similar to "Frecency" in tools like `zoxide`).

1. **Context-Aware Filtering:**

* When searching, add a toggle (e.g., `Ctrl+F` in the TUI) to switch between `Global History` and `Current Directory History`.

1. **End-to-End Encryption:**

* If you plan to sync the `.db` file across machines, consider using SQLCipher or encrypting the `cmd` column content in Zig before insertion to prevent leaking sensitive keys/tokens.
