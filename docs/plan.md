# `zigstory` Development Roadmap

**Project:** Zig History Manager  
**Reference:** docs/architecture.md  
**Status:** Implementation Plan  
**Format:** AI Agent Friendly

---

## Document Structure

This roadmap is organized into sequential phases. Each phase contains:

- **Objective:** Clear goal statement
- **Tasks:** Atomic, actionable development items
- **Dependencies:** Prerequisites that must be completed first
- **Acceptance Criteria:** Measurable validation criteria
- **Deliverables:** Concrete artifacts produced

---

## Phase 1: Foundation & Database Setup

### Objective

Establish the project structure, configure SQLite with WAL mode, and create the foundational CLI interface.

### Tasks

#### Task 1.1: Project Structure Initialization

**Action:** Create base project structure with Zig and .NET components  
**Steps:**

1. Initialize Zig project: `zig init` in project root
2. Initialize .NET 8 class library: `dotnet new classlib -n zigstoryPredictor`
3. Create directory structure:
   - `src/` - Zig source code
   - `src/predictor/` - C# predictor source
   - `src/db/` - Database layer (Zig)
   - `src/cli/` - CLI argument parsing (Zig)
   - `src/tui/` - TUI implementation (Zig)
   - `tests/` - Test files
   - `scripts/` - PowerShell integration scripts
4. Update `.gitignore` to exclude:
   - `*.exe` (Zig binaries)
   - `*.dll` (C# assemblies)
   - `*.db` (SQLite databases)
   - `zig-cache/`, `zig-out/`
   - `bin/`, `obj/` (.NET build artifacts)

**Verification:** Project structure matches defined layout, all `.gitignore` entries present.

---

#### Task 1.2: Database Layer Implementation

**Action:** Implement SQLite database initialization with WAL mode and schema  
**File:** `src/db/database.zig`  
**Requirements:**

```zig
pub fn initDb(path: []const u8) !sqlite.Db {
    // Initialize database with WAL mode
    // Set synchronous=NORMAL
    // Set busy_timeout=1000
    // Create tables and indices
    // Return database handle
}
```

**Schema Components:**

1. `history` table with columns:
   - `id INTEGER PRIMARY KEY AUTOINCREMENT`
   - `cmd TEXT NOT NULL`
   - `cwd TEXT NOT NULL`
   - `exit_code INTEGER`
   - `duration_ms INTEGER`
   - `session_id TEXT`
   - `hostname TEXT`
   - `timestamp INTEGER DEFAULT (strftime('%s', 'now'))`
2. Index `idx_cmd_prefix` on `cmd COLLATE NOCASE`
3. Virtual table `history_fts` using FTS5 on `cmd` column

**Verification:**

- Database file created successfully
- PRAGMA queries confirm: journal_mode=WAL, synchronous=NORMAL, busy_timeout=1000
- All tables and indices exist
- FTS5 virtual table functional

---

#### Task 1.3: CLI Argument Parsing Skeleton

**Action:** Implement command routing and argument parsing  
**File:** `src/cli/args.zig`  
**Subcommands to support:**

- `add` - Insert command into history
- `search` - Launch TUI search interface
- `import` - Migrate existing PowerShell history
- `stats` - Display history statistics (future phase)

**Implementation:**

- Parse command-line arguments
- Route to appropriate handler function
- Provide usage/help message on invalid input
- Return structured command data type

**Verification:**

- All subcommands recognized
- Invalid arguments trigger help message
- `--help` flag displays usage information

---

#### Task 1.4: Unit Testing Infrastructure

**Action:** Set up testing framework and write initial tests  
**File:** `tests/db_test.zig`  
**Test cases:**

1. `testInitDb()` - Verify WAL mode configuration
2. `testCreateTables()` - Verify schema creation
3. `testInsertCommand()` - Verify INSERT operation
4. `testConcurrentAccess()` - Verify WAL mode allows concurrent reads/writes

**Coverage Target:** ≥80% for database layer

**Verification:**

- All tests pass with `zig test`

---

### Dependencies

None (foundation phase)

### Acceptance Criteria

- [x] Database initializes successfully in WAL mode
- [x] PRAGMA settings verified: journal_mode=WAL, synchronous=NORMAL, busy_timeout=1000
- [x] All tables and indices created successfully
- [x] FTS5 virtual table functional
- [x] CLI accepts all three subcommands (add, search, import)
- [x] Unit tests pass with ≥80% coverage on database layer
- [ ] Concurrent read/write operations execute without blocking

### Deliverables

- Zig project structure with organized source directories
- `src/db/database.zig` - Database initialization code
- `src/cli/args.zig` - Argument parsing logic
- `tests/db_test.zig` - Database unit tests
- Updated `.gitignore` file

---

## Phase 2: Write Path Implementation

### Objective

Implement command history ingestion pipeline with metadata collection and PowerShell integration.

### Tasks

#### Task 2.1: Command Ingestion Logic

**Action:** Implement `add` command handler with sanitization  
**File:** `src/cli/add.zig`  
**Requirements:**

- Accept parameters: `--cmd`, `--cwd`, `--exit`, `--duration` (optional)
- Sanitize input strings (escape SQL injection attempts)
- Generate unique `session_id` (UUID v4)
- Capture `hostname` from system
- Insert record into `history` table
- Return success/error status

**Input Validation:**

- `cmd` must not be empty
- `cwd` must be valid path
- `exit_code` must be integer

**Verification:**

- Valid commands insert successfully
- Empty commands rejected
- SQL injection attempts fail safely
- Session ID is unique per session

---

#### Task 2.2: Performance Optimization

**Action:** Optimize write operations for performance  
**File:** `src/db/write.zig`  
**Optimizations:**

1. Implement connection pooling (reuse DB handles)
2. Add batch INSERT support for multiple commands
3. Implement retry logic on `SQLITE_BUSY` errors (max 3 retries)
4. Use prepared statements for INSERT operations

**Performance Targets:**

- Single INSERT: <50ms average
- Batch INSERT (100 commands): <1s

**Verification:**

- Benchmark confirms targets met

---

#### Task 2.3: PowerShell Hook Integration

**Action:** Create PowerShell profile integration script  
**File:** `scripts/profile.ps1`  
**Components:**

1. **Prompt Function Hook:**

```powershell
function Global:Prompt {
    $lastExit = $LASTEXITCODE
    $startTime = Get-Date
    
    # Async write to avoid blocking prompt
    Start-Process -FilePath $zigstoryBin `
        -ArgumentList "add", "--exit", $lastExit, "--cwd", "$PWD", "--cmd", "$LastHistoryItem" `
        -NoNewWindow -UseNewEnvironment
    
    return "PS $PWD> "
}
```

1. **Execution Time Tracking:**
   - Modify Prompt to capture start time
   - Calculate duration and pass to `add` command
   - Store in `duration_ms` field

2. **Error Handling:**
   - Catch and log write failures
   - Prevent hook failures from breaking prompt

**Verification:**

- Every command executes Prompt function
- Exit code captured accurately (including 0 for success)
- Duration measured in milliseconds
- Async writes don't block prompt appearance

---

#### Task 2.4: History Import Functionality

**Action:** Implement migration from existing PowerShell history  
**File:** `src/cli/import.zig`  
**Requirements:**

1. Read PowerShell history file (`(Get-PSReadlineOption).HistorySavePath`)
2. Parse each command line
3. Skip duplicate commands (same cmd, cwd, timestamp)
4. Insert into database
5. Display progress (commands imported / total)

**Duplicate Detection Logic:**

- Check for existing records with identical `cmd`, `cwd`, `timestamp`
- Only insert if no duplicate found

**Verification:**

- All unique commands from history file imported
- No duplicate records created
- Progress bar updates during import
- Handles large history files (10,000+ commands)

---

### Dependencies

- Phase 1 complete (Database schema, CLI skeleton)

### Acceptance Criteria

- [ ] `zigstory add --cmd "..." --cwd "..." --exit 0` inserts successfully
- [ ] PowerShell Prompt hook triggers on every command execution
- [ ] Exit code captured accurately (including success/failure states)
- [ ] Duration measured and recorded in milliseconds
- [ ] Import migrates existing PowerShell history without duplicates
- [ ] Write operations complete in <50ms average (single), <1s (batch 100)
- [ ] Async writes don't block PowerShell prompt
- [ ] SQL injection attempts fail safely

### Deliverables

- `src/cli/add.zig` - Command ingestion logic
- `src/db/write.zig` - Optimized write operations
- `scripts/profile.ps1` - PowerShell integration script
- `src/cli/import.zig` - History import utility
- Performance benchmark results
- Unit tests for write operations

---

## Phase 3: Predictor Implementation

### Objective

Build the C# predictor adapter for inline ghost text suggestions with sub-5ms query performance.

### Tasks

#### Task 3.1: C# Project Setup

**Action:** Initialize .NET 8 class library project  
**File:** `src/predictor/zigstoryPredictor.csproj`  
**Dependencies:**

- `Microsoft.PowerShell.PSReadLine` (from NuGet)
- `System.Data.SQLite` or `Microsoft.Data.Sqlite` (from NuGet)

**Configuration:**

- Target Framework: `net8.0`
- Output Type: `Library`
- Root Namespace: `zigstoryPredictor`

**Verification:** Project builds successfully with `dotnet build`

---

#### Task 3.2: ICommandPredictor Implementation

**Action:** Implement predictor class with PSReadLine interface  
**File:** `src/predictor/zigstoryPredictor.cs`  
**Requirements:**

```csharp
public class zigstoryPredictor : ICommandPredictor
{
    public Guid Id { get; } = new Guid("DEFINE-GUID-HERE");
    public string Name { get; } = "zigstoryPredictor";
    public string Description { get; } = "Zig-based shell history predictor";
    
    public SuggestionPackage GetSuggestion(
        PredictionClient client, 
        PredictionContext context, 
        CancellationToken token)
    {
        string input = context.InputAst.Extent.Text;
        
        // Optimization: Don't query on 1 character
        if (string.IsNullOrWhiteSpace(input) || input.Length < 2)
            return default;
        
        // Query optimized for idx_cmd_prefix index
        // "SELECT cmd FROM history WHERE cmd LIKE @p || '%' 
        //  ORDER BY timestamp DESC LIMIT 5"
    }
}
```

**Query Optimization:**

- Use parameterized queries
- Leverage `idx_cmd_prefix` index
- Limit results to 5
- Order by `timestamp DESC`

**Verification:**

- Class compiles and implements `ICommandPredictor`
- GUID is unique
- Query returns top 5 most recent matching commands

---

#### Task 3.3: Database Connection Management

**Action:** Implement connection pooling and read-only access  
**File:** `src/predictor/DatabaseManager.cs`  
**Requirements:**

1. Open connection in read-only mode
2. Implement connection pooling (max 5 connections)
3. Configure busy timeout (1000ms)
4. Handle connection failures gracefully
5. Reuse connections for multiple queries

**Connection String:**

```sqlite
Data Source=[path_to_db];Mode=ReadOnly;Pooling=True;Journal Mode=WAL;
```

**Verification:**

- Connections open in read-only mode
- Pooling reduces connection overhead
- No database lock errors during concurrent access

---

#### Task 3.4: Performance Optimization

**Action:** Optimize query performance to meet <5ms target  
**File:** `src/predictor/zigstoryPredictor.cs` (update)  
**Optimizations:**

1. Add result caching (LRU cache, max 100 entries)
2. Pre-compile SQL queries
3. Minimize allocations in hot path
4. Use `VALUE` function for SQLite (if available)

**Performance Targets:**

- Query execution: <5ms (p95)
- Cache hit: <1ms
- Cache miss: <5ms

**Verification:** Benchmark confirms targets met

---

#### Task 3.5: Integration Testing

**Action:** Test predictor in PowerShell environment  
**File:** `tests/predictor_test.ps1`  
**Test Cases:**

1. Load predictor DLL: `Import-Module zigstoryPredictor.dll`
2. Enable plugin: `Set-PSReadLineOption -PredictionSource Plugin`
3. Test ghost text appears on typing
4. Verify suggestions are relevant (timestamp-sorted)
5. Test with various input lengths (2+ characters)
6. Test concurrent database access (read during write)

**Verification:**

- Predictor loads without errors
- Ghost text appears within 5ms
- Suggestions are accurate and relevant
- No database lock issues during concurrent access

---

### Dependencies

- Phase 2 complete (Database populated with test data)

### Acceptance Criteria

- [ ] `zigstoryPredictor.dll` compiles successfully
- [ ] DLL loads successfully in PowerShell 7+
- [ ] Implements `ICommandPredictor` interface correctly
- [ ] Ghost text appears within 5ms of typing
- [ ] Minimum input length check prevents queries on 1 character
- [ ] Suggestions are top 5 most recent matching commands
- [ ] Query leverages `idx_cmd_prefix` index
- [ ] Zero PowerShell startup time impact (<10ms overhead)
- [ ] No database lock issues during concurrent read/write
- [ ] Result caching reduces latency for repeated queries

### Deliverables

- `src/predictor/zigstoryPredictor.csproj` - Project file
- `src/predictor/zigstoryPredictor.cs` - Predictor implementation
- `src/predictor/DatabaseManager.cs` - Connection manager
- `zigstoryPredictor.dll` - Compiled assembly (release build)
- `tests/predictor_test.ps1` - Integration tests
- Performance benchmark report
- PowerShell integration commands documentation

---

## Phase 4: TUI Search Implementation

### Objective

Build interactive search interface using `libvaxis` with virtual scrolling and fuzzy search.

### Tasks

#### Task 4.1: libvaxis Integration

**Action:** Set up TUI framework and event loop  
**File:** `src/tui/main.zig`  
**Dependencies:**

- Add `libvaxis` to `build.zig`
- Implement event loop for keyboard handling
- Initialize terminal control

**Requirements:**

1. Initialize `vaxis.Vaxis` instance
2. Set up terminal with proper dimensions
3. Start event loop
4. Handle terminal cleanup on exit
5. Support terminal resize events

**Verification:** TUI launches and responds to keyboard input

---

#### Task 4.2: Virtual Scrolling System

**Action:** Implement pagination-based row fetching  
**File:** `src/tui/scrolling.zig`  
**Requirements:**

1. **Viewport Calculation:**
   - Calculate number of visible rows based on terminal height
   - Determine start/end row indices for current viewport

2. **Pagination Logic:**
   - Fetch only visible rows from SQLite
   - Use `LIMIT [rows] OFFSET [start]` queries
   - Cache fetched rows (page size: 100 rows)

3. **Scroll Position Tracking:**
   - Track current scroll index
   - Handle scroll up/down with boundary checks
   - Update viewport on scroll

4. **Row Caching:**
   - Maintain LRU cache of fetched pages
   - Prefetch adjacent pages (next/previous)
   - Evict least recently used pages

**SQL Queries:**

```sql
-- Get total count
SELECT COUNT(*) FROM history;

-- Get page of results
SELECT id, cmd, cwd, exit_code, duration_ms, timestamp 
FROM history 
ORDER BY timestamp DESC 
LIMIT ? OFFSET ?;
```

**Verification:**

- Only visible rows fetched from database
- Scrolling is smooth with 1000+ entries
- Memory usage remains <50MB with 10,000 entries
- Terminal resize updates viewport correctly

---

#### Task 4.3: Fuzzy Search Implementation

**Action:** Implement FTS5-based real-time search  
**File:** `src/tui/search.zig`  
**Requirements:**

1. **FTS5 Query Building:**
   - Construct `MATCH` query from user input
   - Support prefix matching with `*` operator
   - Escape special characters (`"`, `*`, `(`, `)`)

2. **Search Modes:**
   - Empty search: Show recent commands (ORDER BY timestamp DESC)
   - With query: Show FTS5 matches (ORDER BY rank, timestamp DESC)

3. **Real-time Filtering:**
   - Update results on each keystroke
   - Debounce rapid typing (100ms delay)
   - Display result count

4. **Search Highlighting:**
   - Highlight matched terms in results
   - Use different color for matches

**SQL Queries:**

```sql
-- FTS5 search
SELECT h.id, h.cmd, h.cwd, h.exit_code, h.duration_ms, h.timestamp,
       rank
FROM history_fts fts
JOIN history h ON fts.rowid = h.id
WHERE history_fts MATCH ?
ORDER BY rank, h.timestamp DESC
LIMIT ? OFFSET ?;

-- Recent (empty search)
SELECT id, cmd, cwd, exit_code, duration_ms, timestamp
FROM history
ORDER BY timestamp DESC
LIMIT ? OFFSET ?;
```

**Verification:**

- Fuzzy search returns relevant results
- Search updates on each keystroke
- Result count displays correctly
- Highlighting matches search terms
- Empty search shows recent commands

---

#### Task 4.4: UI Rendering

**Action:** Implement column layout and styling  
**File:** `src/tui/render.zig`  
**Column Layout:**

| Column | Position | Style | Condition |
|--------|----------|-------|-----------|
| Timestamp | Left | Dimmed | Always |
| Duration | Left (after timestamp) | Normal | If > 1s |
| Command | Center | Syntax highlighted | Always |
| Directory | Right-aligned | Normal | Always |

**Styling Rules:**

- Failed commands (`exit_code != 0`): Render in **Red**
- Successful commands: Normal color
- Selected row: Highlighted (reverse video)
- Timestamp: Dimmed (reduced brightness)
- Duration: Only show if > 1000ms (1 second)
- Directory: Right-aligned, truncate if too long

**Timestamp Formatting:**

- Convert Unix timestamp to readable format
- Relative time (e.g., "2h ago", "5m ago") or absolute

**Command Highlighting:**

- Basic syntax highlighting (optional)
- Highlight common commands (git, npm, dotnet)

**Verification:**

- All columns render correctly
- Failed commands displayed in red
- Duration hides when <1s
- Directory truncates on overflow
- Selection indicator visible
- Terminal resize reflows layout

---

#### Task 4.5: Keyboard Navigation

**Action:** Implement keyboard shortcuts and navigation  
**File:** `src/tui/navigation.zig`  
**Key Bindings:**

| Key | Action |
|-----|--------|
| `↑` / `Ctrl+P` | Move selection up |
| `↓` / `Ctrl+N` | Move selection down |
| `Home` | Jump to first result |
| `End` | Jump to last result |
| `Page Up` | Scroll up one page |
| `Page Down` | Scroll down one page |
| `Ctrl+R` | Refresh search results |
| `Enter` | Select command and exit |
| `Ctrl+C` / `Escape` | Exit without selection |
| `Ctrl+F` | Toggle directory filter (future phase) |

**Navigation Logic:**

- Handle boundary conditions (top/bottom of list)
- Scroll viewport when selection moves off-screen
- Maintain focus on visible items

**Command Selection:**

- Print selected command to `stdout`
- Exit TUI cleanly
- Return exit code 0 on selection, 1 on cancel

**Verification:**

- All keyboard shortcuts work correctly
- Selection stays within bounds
- Viewport scrolls with selection
- Command prints to stdout
- Clean exit on Ctrl+C/Escape

---

#### Task 4.6: Command Execution Integration

**Action:** Integrate with PowerShell for command execution  
**File:** `scripts/profile.ps1` (update)  
**Add to existing profile:**

```powershell
# Hook: Ctrl+R for Search
Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock {
    $result = & $zigstoryBin search
    if ($result) {
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
    }
}
```

**Requirements:**

1. TUI launches on Ctrl+R
2. User selects command in TUI
3. TUI prints command to stdout and exits
4. PowerShell receives output and replaces current line
5. Command executes on Enter

**Verification:**

- Ctrl+R launches TUI
- Selected command appears in PowerShell line
- Command executes successfully
- Handles commands with special characters

---

### Dependencies

- Phase 2 complete (Database populated with diverse test data)
- Phase 1 complete (CLI skeleton)

### Acceptance Criteria

- [ ] TUI launches successfully on `zigstory search`
- [ ] `libvaxis` integrated with proper event loop
- [ ] Virtual scrolling loads only visible rows (50-100 per viewport)
- [ ] Row caching maintains smooth scrolling with 1000+ entries
- [ ] Fuzzy search uses FTS5 with real-time filtering
- [ ] Search updates on each keystroke (debounced)
- [ ] Result count displays correctly
- [ ] All columns render correctly (Timestamp, Duration, Command, Directory)
- [ ] Failed commands (`exit_code != 0`) displayed in red
- [ ] Duration only shows when > 1s
- [ ] Directory column right-aligned
- [ ] All keyboard shortcuts work (arrows, Home/End, Page Up/Down, Ctrl+R)
- [ ] Selection indicator visible
- [ ] Terminal resize updates viewport correctly
- [ ] Selected command prints to stdout and exits
- [ ] Ctrl+R in PowerShell launches TUI and executes selected command
- [ ] Memory usage <50MB with 10,000 history entries
- [ ] Fuzzy search returns relevant results in <10ms

### Deliverables

- `src/tui/main.zig` - TUI entry point
- `src/tui/scrolling.zig` - Virtual scrolling system
- `src/tui/search.zig` - Fuzzy search implementation
- `src/tui/render.zig` - UI rendering engine
- `src/tui/navigation.zig` - Keyboard navigation
- `src/tui/` - Complete TUI module
- `zigstory.exe` (with search functionality)
- `scripts/profile.ps1` (updated with Ctrl+R handler)
- Performance benchmarks (scrolling, search)

---

## Phase 5: Advanced Features

### Objective

Implement frecency ranking algorithms and context-aware directory filtering.

### Tasks

#### Task 5.1: Frecency Ranking System

**Action:** Add rank-based command scoring  
**Database Schema Update:**

```sql
ALTER TABLE history ADD COLUMN rank REAL DEFAULT 0;
CREATE INDEX idx_rank ON history(rank DESC, timestamp DESC);
```

**File:** `src/db/ranking.zig`  
**Frecency Formula:**

```text
rank = (frequency * weight) + (recency_weight / days_since_last_use)
```

Where:

- `frequency`: Number of times command executed
- `weight`: Constant (e.g., 2.0)
- `recency_weight`: Constant (e.g., 100.0)
- `days_since_last_use`: Days since most recent execution

**Implementation:**

1. Track frequency in new `command_stats` table:

```sql
CREATE TABLE command_stats (
    cmd_hash TEXT PRIMARY KEY,  -- SHA256 of normalized command
    frequency INTEGER DEFAULT 0,
    last_used INTEGER
);
```

1. On each `add`:
   - Calculate command hash
   - Update `frequency` in `command_stats`
   - Calculate and update `rank` in `history`

2. Batch recalculation command:
   - Update all ranks based on current stats

**Verification:**

- Rank column added to history table
- Frequency tracking functional
- Rank calculated correctly
- Index on rank created

---

#### Task 5.2: Rank Calculation Background Job

**Action:** Implement periodic rank recalculation  
**File:** `src/cli/recalc.zig`  
**Requirements:**

1. **Manual Recalculation:**
   - Command: `zigstory recalc-rank`
   - Recalculate all ranks based on current stats
   - Display progress
   - Optimize with batch updates

2. **Automatic Recalculation:**
   - Trigger after large imports
   - Consider scheduling (optional, future)

**Optimizations:**

- Use batch UPDATE statements (100 rows per batch)
- Skip if rank difference < threshold
- Display progress bar

**SQL:**

```sql
UPDATE history h
SET rank = (
    SELECT (s.frequency * 2.0) + (100.0 / MAX(1, (strftime('%s', 'now') - s.last_used) / 86400.0))
    FROM command_stats s
    WHERE s.cmd_hash = h.cmd_hash
)
WHERE id BETWEEN ? AND ?;
```

**Verification:**

- Recalculation completes in <1s for 10,000 entries
- Progress updates during execution
- Ranks updated correctly

---

#### Task 5.3: Context-Aware Directory Filtering

**Action:** Add directory filter toggle in TUI  
**File:** `src/tui/directory_filter.zig`  
**Requirements:**

1. **Toggle Implementation:**
   - Key: `Ctrl+F` toggles filter mode
   - Modes: Global History ↔ Current Directory
   - Visual indicator: [FILTER: Global] or [FILTER: Current Dir]

2. **Query Modification:**
   - Global: No WHERE clause on `cwd`
   - Current Directory: `WHERE cwd = @current_dir`

3. **Directory Tracking:**
   - Capture current directory from environment
   - Pass to TUI as startup parameter
   - Update if directory changes (optional, complex)

**SQL Queries:**

```sql
-- Global mode
SELECT ... FROM history WHERE [fts_condition] ORDER BY ...;

-- Current directory mode
SELECT ... FROM history 
WHERE cwd = ? AND [fts_condition] 
ORDER BY ...;
```

**Implementation Steps:**

1. Add `filter_mode` enum to TUI state
2. Toggle mode on Ctrl+F
3. Update queries based on mode
4. Update status line with filter indicator

**Verification:**

- Ctrl+F toggles between Global and Current Directory modes
- Status line displays current filter mode
- Results filter correctly by directory
- Search respects filter mode

---

#### Task 5.4: Statistics Dashboard

**Action:** Implement command to display history statistics  
**File:** `src/cli/stats.zig`  
**Command:** `zigstory stats`  
**Output Sections:**

1. **Overview:**
   - Total commands executed
   - Unique commands
   - Total sessions
   - Date range (first command → last command)

2. **Most Used Commands (Top 10):**

   ```text
   TOP COMMANDS
   ─────────────────────────────
   #  Command                 Count  Last Used
   1  git commit              234    2h ago
   2  npm install             187    5m ago
   ...
   ```

3. **Execution Distribution:**
   - Commands by hour (ASCII bar chart)
   - Commands by day of week
   - Success rate (exit_code == 0)

4. **Directory Breakdown:**
   - Top 5 directories by command count

**SQL Queries:**

```sql
-- Total commands
SELECT COUNT(*) FROM history;

-- Unique commands
SELECT COUNT(DISTINCT cmd) FROM history;

-- Most used
SELECT cmd, COUNT(*) as count, MAX(timestamp) as last_used
FROM history
GROUP BY cmd
ORDER BY count DESC
LIMIT 10;

-- Success rate
SELECT 
    COUNT(*) as total,
    SUM(CASE WHEN exit_code = 0 THEN 1 ELSE 0 END) as success
FROM history;

-- Commands by hour
SELECT strftime('%H', datetime(timestamp, 'unixepoch')) as hour, COUNT(*)
FROM history
GROUP BY hour
ORDER BY hour;
```

**Visualization:**

- Use ASCII characters for bar charts (█, ▌, ▎)
- Color coding for success/failure (optional)

**Verification:**

- `zigstory stats` executes successfully
- All statistics display correctly
- ASCII charts render properly
- Data is accurate

---

### Dependencies

- Phase 3 complete (Predictor with current ordering)
- Phase 4 complete (TUI with search)

### Acceptance Criteria

- [ ] `rank` column added to history table
- [ ] Frequency tracking in `command_stats` table functional
- [ ] Frecency algorithm implemented correctly
- [ ] Rank calculated on each command insertion
- [ ] `zigstory recalc-rank` command works
- [ ] Recalculation completes in <1s for 10,000 entries
- [ ] Ctrl+F toggles directory filter in TUI
- [ ] Status line shows current filter mode
- [ ] Current directory mode filters by `cwd` column
- [ ] `zigstory stats` command displays all statistics
- [ ] Top 10 commands shown with count and last used
- [ ] ASCII bar charts render for time distribution
- [ ] Success rate calculated and displayed
- [ ] Predictor updated to use `ORDER BY rank DESC, timestamp DESC`

### Deliverables

- `src/db/ranking.zig` - Frecency ranking algorithm
- `src/cli/recalc.zig` - Rank recalculation tool
- `src/tui/directory_filter.zig` - Directory filtering
- `src/cli/stats.zig` - Statistics dashboard
- Updated database schema (rank column, command_stats table)
- Updated predictor with rank-based sorting
- Database migration script (schema updates)
- Unit tests for ranking algorithm

---

## Phase 6: Testing & Quality Assurance

### Objective

Comprehensive testing, performance optimization, and bug fixes across all components.

### Tasks

#### Task 6.1: Integration Testing

**Action:** Test end-to-end workflows  
**File:** `tests/integration_test.ps1`  
**Test Scenarios:**

1. **Write → Read Path:**
   - Execute command in PowerShell
   - Verify command appears in database
   - Verify predictor shows suggestion
   - Verify TUI finds command

2. **Concurrent Operations:**
   - Type in PowerShell (triggering predictor)
   - Simultaneously execute command (triggering write)
   - Verify no database lock errors
   - Verify predictor still responds

3. **Edge Cases:**
   - Empty database (no history)
   - Very long commands (>1000 characters)
   - Special characters (quotes, pipes, redirects)
   - Unicode characters in commands
   - Commands with newlines

4. **Error Handling:**
   - Database file locked (external process)
   - Corrupted database
   - Disk full scenario
   - Predictor DLL missing

**Verification:** All integration tests pass

---

#### Task 6.2: Performance Testing

**Action:** Benchmark all operations  
**File:** `tests/benchmark.zig` and `tests/benchmark.ps1`  
**Performance Targets:**

| Operation | Target | Metric |
|-----------|--------|--------|
| Single INSERT | <50ms | Average |
| Batch INSERT (100) | <1s | Average |
| Predictor query | <5ms | p95 |
| Predictor (cache hit) | <1ms | Average |
| TUI search | <10ms | Average |
| TUI scroll | <16ms | (60fps) |
| Rank recalculation (10k) | <1s | Total |
| PowerShell startup overhead | <10ms | Additional |

**Benchmarking:**

- Use `std.time.Timer` in Zig
- Use `Measure-Command` in PowerShell
- Run each benchmark 100 times, calculate p50, p95, p99
- Profile with `perf` or equivalent

**Verification:** All targets met

---

#### Task 6.3: Cross-Platform Validation

**Action:** Test on supported platforms  
**Platforms:**

- Windows 10
- Windows 11

**PowerShell Versions:**

- 7.2 LTS
- 7.3
- 7.4

**Terminal Emulators:**

- Windows Terminal
- PowerShell (legacy console)
- VS Code integrated terminal

**Test Matrix:**

1. Install and configure zigstory on each platform
2. Test all features (add, predict, search)
3. Verify performance meets targets
4. Check for platform-specific bugs

**Verification:** Works consistently across all platforms

---

#### Task 6.4: Documentation

**Action:** Create comprehensive user and developer documentation  
**Files:**

- `README.md` - Project overview and quick start
- `docs/USER_GUIDE.md` - Detailed user guide
- `docs/INSTALLATION.md` - Installation instructions
- `docs/DEVELOPER_GUIDE.md` - Contributing guide
- `docs/TROUBLESHOOTING.md` - Common issues and solutions

**User Guide Sections:**

- Introduction and features
- Installation step-by-step
- Configuration (PowerShell profile)
- Usage examples
- Keyboard shortcuts reference
- FAQ

**Installation Guide Sections:**

- Prerequisites (Zig, .NET 8, PowerShell 7+)
- Building from source
- Installing binaries
- Configuring PowerShell profile
- Upgrading

**Troubleshooting Sections:**

- Database lock errors
- Predictor not loading
- TUI not launching
- Performance issues
- PowerShell compatibility

**Verification:** Documentation is clear, complete, and tested

---

#### Task 6.5: Bug Fixes

**Action:** Address issues found during testing  
**Process:**

1. Log all bugs in issue tracker
2. Prioritize by severity (Critical, High, Medium, Low)
3. Fix critical bugs first
4. Regression test after each fix
5. Update documentation as needed

**Critical Bugs Definition:**

- Data loss or corruption
- Security vulnerabilities
- Application crashes
- Broken core functionality

**Verification:** Zero critical bugs remaining

---

### Dependencies

- All previous phases (1-5) complete
- All features implemented

### Acceptance Criteria

- [ ] All integration tests pass
- [ ] End-to-end workflow tested and verified
- [ ] Concurrent operations tested without errors
- [ ] Edge cases handled gracefully
- [ ] Error handling works for all failure modes
- [ ] All performance targets met on all platforms
- [ ] Benchmark report generated and documented
- [ ] Works on Windows 10 and Windows 11
- [ ] Works on PowerShell 7.2, 7.3, 7.4
- [ ] Works with all supported terminal emulators
- [ ] User documentation complete and clear
- [ ] Installation guide tested step-by-step
- [ ] Troubleshooting guide covers common issues
- [ ] Zero critical bugs remaining
- [ ] All high-priority bugs fixed

### Deliverables

- `tests/integration_test.ps1` - Integration test suite
- `tests/benchmark.zig` - Zig benchmarking tool
- `tests/benchmark.ps1` - PowerShell benchmarking tool
- Performance benchmark report (all operations)
- Cross-platform test results
- `README.md` - Project overview
- `docs/USER_GUIDE.md` - User documentation
- `docs/INSTALLATION.md` - Installation guide
- `docs/DEVELOPER_GUIDE.md` - Developer documentation
- `docs/TROUBLESHOOTING.md` - Troubleshooting guide
- Bug fix patches
- Release notes (bug fixes and improvements)

---

## Phase 7: Release Preparation

### Objective

Prepare artifacts and documentation for public release.

### Tasks

#### Task 7.1: Version Tagging

**Action:** Implement semantic versioning  
**Version:** v1.0.0  
**Components:**

- Zig binary: `zigstory.exe` (embedded version info)
- C# assembly: `zigstoryPredictor.dll` (AssemblyVersion)
- Git tag: `v1.0.0`

**Implementation:**

1. Add `build.zig` options for version
2. Embed version in Zig binary
3. Set version in `.csproj` file
4. Create git annotated tag

**Verification:** Version information accessible in both binaries

---

#### Task 7.2: Binary Distribution

**Action:** Build release binaries for distribution  
**Build Configurations:**

**Zig:**

```bash
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
```

**C#:**

```bash
dotnet build -c Release
```

**Distribution Package Contents:**

```text
zigstory-v1.0.0/
├── zigstory.exe              # Zig binary
├── zigstoryPredictor.dll     # C# predictor
├── README.md                 # Quick start guide
├── INSTALLATION.md           # Installation instructions
├── LICENSE                   # License file
└── scripts/
    └── profile.ps1           # PowerShell integration script
```

**Verification:** Package contains all necessary files

---

#### Task 7.3: GitHub Release

**Action:** Create GitHub release with assets  
**Steps:**

1. Create GitHub release `v1.0.0`
2. Upload binary distribution package
3. Write release notes:
   - Overview of features
   - Installation instructions
   - Known limitations
   - Breaking changes (none for v1.0)
   - Acknowledgments

**Release Notes Template:**

```markdown
# zigstory v1.0.0

## Overview
First stable release of zigstory, a high-performance shell history manager for PowerShell.

## Features
- Persistent command history with SQLite database
- Inline ghost text predictions (<5ms latency)
- Interactive TUI search with fuzzy matching
- Context-aware directory filtering
- Frecency-based command ranking

## Installation
[Link to INSTALLATION.md]

## Known Issues
[List any known issues]

## System Requirements
- Windows 10/11
- PowerShell 7.2+
- Zig 0.15.2+ (if building from source)
- .NET 8 Runtime

## What's Changed
[Link to full changelog]
```

**Verification:** Release published and accessible

---

#### Task 7.4: Installation Script

**Action:** Create automated installation script  
**File:** `scripts/install.ps1`  
**Features:**

1. Download latest release
2. Install binaries to user bin directory
3. Configure PowerShell profile
4. Validate installation
5. Rollback on failure

**Usage:**

```powershell
# Install
irm https://raw.githubusercontent.com/pruiz/zigstory/main/scripts/install.ps1 | iex

# Install to custom location
irm https://raw.githubusercontent.com/pruiz/zigstory/main/scripts/install.ps1 | iex -BinPath C:\my\bin
```

**Verification:** Installation script works end-to-end

---

### Dependencies

- Phase 6 complete (Testing and bug fixes)

### Acceptance Criteria

- [ ] Version v1.0.0 tagged in git
- [ ] Zig binary contains version information
- [ ] C# assembly has correct version
- [ ] Release binaries built with optimizations
- [ ] Distribution package contains all required files
- [ ] GitHub release created with proper version
- [ ] Release notes complete and accurate
- [ ] Installation script works end-to-end
- [ ] Installation can be rolled back on failure

### Deliverables

- Git tag `v1.0.0`
- Release binaries (zigstory.exe, zigstoryPredictor.dll)
- Distribution package (zigstory-v1.0.0.zip)
- GitHub release page
- Release notes
- `scripts/install.ps1` - Installation script
- `docs/CHANGELOG.md` - Changelog

---

## Future Enhancements (Post-Release)

### Enhancement 1: End-to-End Encryption

**Priority:** Medium  
**Description:** Use SQLCipher to encrypt database for safe synchronization  
**Implementation:**

- Replace SQLite with SQLCipher
- Add key derivation from user password
- Implement database unlocking on startup
- Add encryption/decryption commands

### Enhancement 2: History Synchronization

**Priority:** Medium  
**Description:** Sync history across multiple machines  
**Implementation:**

- Add `zigstory sync` command
- Use Git or cloud storage backend
- Handle merge conflicts
- Implement conflict resolution UI

### Enhancement 3: Command Tags and Labels

**Priority:** Low  
**Description:** Add metadata tags to commands  
**Implementation:**

- Add `tags` column to history table
- Implement tagging commands
- Add tag filtering in TUI
- Auto-tag based on patterns

### Enhancement 4: Custom TUI Themes

**Priority:** Low  
**Description:** Allow users to customize TUI colors and styles  
**Implementation:**

- Add theme configuration file
- Implement color schemes
- Add `zigstory theme` command
- Provide default themes

### Enhancement 5: Machine Learning Ranking

**Priority:** Low  
**Description:** Use ML to improve suggestion relevance  
**Implementation:**

- Collect user interaction data
- Train model on usage patterns
- Predict next command based on context
- Replace frecency with ML-based ranking

---

## Implementation Order Summary

1. **Phase 1:** Foundation (Database, CLI skeleton)
2. **Phase 2:** Write Path (Ingestion, PowerShell hooks)
3. **Phase 3:** Predictor (C# adapter, Ghost text)
4. **Phase 4:** TUI Search (libvaxis interface)
5. **Phase 5:** Advanced Features (Ranking, Filtering, Stats)
6. **Phase 6:** Testing & QA (Integration, Performance, Documentation)
7. **Phase 7:** Release (Packaging, Distribution)

---

## Quick Reference for AI Agents

### Phase Dependencies Graph

```text
Phase 1 (Foundation)
    ├─> Phase 2 (Write Path)
    │       ├─> Phase 3 (Predictor)
    │       └─> Phase 4 (TUI Search)
    │               └─> Phase 5 (Advanced Features)
    │                       └─> Phase 6 (Testing & QA)
    │                               └─> Phase 7 (Release)
```

### Key Performance Metrics

- **Write Operations:** <50ms (single), <1s (batch 100)
- **Predictor Query:** <5ms (p95), <1ms (cache hit)
- **TUI Search:** <10ms average
- **TUI Scroll:** <16ms (60fps)
- **Rank Recalculation:** <1s for 10,000 entries
- **PowerShell Startup Overhead:** <10ms additional

### Critical Database Settings

- **Journal Mode:** WAL (required for concurrency)
- **Synchronous:** NORMAL
- **Busy Timeout:** 1000ms
- **Indices:** idx_cmd_prefix, idx_rank (future)

### Critical File Locations

- Database: `$HOME/.zigstory/history.db` (or configured path)
- Zig Binary: `zigstory.exe`
- C# Predictor: `zigstoryPredictor.dll`
- PowerShell Profile: `$PROFILE` (updated by install script)

### Essential Commands

```powershell
# Add command to history
zigstory add --cmd "git status" --cwd "/path/to/dir" --exit 0

# Search history (TUI)
zigstory search

# Import existing PowerShell history
zigstory import

# Show statistics
zigstory stats

# Recalculate ranks
zigstory recalc-rank
```

### Architecture References

- Database Schema: See `docs/architecture.md` Section 3
- Component 1 (Zig): See `docs/architecture.md` Section 4
- Component 2 (C#): See `docs/architecture.md` Section 5
- PowerShell Integration: See `docs/architecture.md` Section 6

---

**End of Roadmap**
