# Ranking Bug Analysis

## Problem Description

The `zigstory recalc-rank` command fails with an SQLite error:

```
Error recalculating ranks: error.SQLiteError
```

## Root Cause Analysis

### Affected Code

**File:** `src/db/ranking.zig`
**Function:** `recalculateAllRanks` (lines 156-211)

### The Bug

The rank recalculation SQL query in `recalculateAllRanks` contains:

```sql
UPDATE history h
SET rank = (
    SELECT COALESCE(
        (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0)),
        0
    )
    FROM command_stats s
    WHERE s.cmd_hash = (
        SELECT sub.cmd_hash FROM history sub WHERE sub.id = h.id
    )
)
WHERE id BETWEEN ? AND ?;
```

The inner query tries to select `sub.cmd_hash` from the `history` table, but this column **does not exist**.

### Database Schema

**history** table schema:
```sql
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cmd TEXT NOT NULL,
    cwd TEXT NOT NULL,
    exit_code INTEGER,
    duration_ms INTEGER,
    session_id TEXT,
    hostname TEXT,
    timestamp INTEGER DEFAULT (strftime('%s', 'now')),
    rank REAL DEFAULT 0  -- Added by ranking system
);
```

**command_stats** table schema:
```sql
CREATE TABLE command_stats (
    cmd_hash TEXT PRIMARY KEY,
    cmd TEXT NOT NULL,
    frequency INTEGER DEFAULT 1,
    last_used INTEGER NOT NULL
);
```

The `cmd_hash` column only exists in `command_stats`, not in `history`.

## Impact

- Commands are **still recorded** correctly to the database
- **Frecency ranks are not calculated** - they remain at 0
- Search and ranking features won't use frecency optimization
- Commands are ordered by timestamp instead of rank

## Potential Solutions

### Solution 1: Add cmd_hash Column to History Table

Modify `ranking.zig` to add the column:

```zig
pub fn addCmdHashColumn(db: *sqlite.Db) !void {
    try db.exec(
        \\ALTER TABLE history ADD COLUMN cmd_hash TEXT;
    , .{}, .{});
}

pub fn initRanking(db: *sqlite.Db) !void {
    // ... existing code ...
    
    // Add cmd_hash column
    addCmdHashColumn(db) catch |err| {
        if (err != error.SQLiteError) return err;
    };
    
    // ... rest of initRanking ...
}
```

Update `addCommand` in `cli/add.zig` to store the hash:
```zig
const cmd_hash = try ranking.getCommandHash(params.cmd, allocator);
defer allocator.free(cmd_hash);

try stmt.exec(.{}, .{
    .cmd = params.cmd,
    .cwd = params.cwd,
    .exit_code = params.exit_code,
    .duration_ms = params.duration_ms,
    .session_id = session_id,
    .hostname = hostname,
    .timestamp = std.time.timestamp(),
    .cmd_hash = cmd_hash,  // Add this
});
```

### Solution 2: Compute Hash Inline in SQL

Modify the recalculation query to compute the hash on the fly:

```sql
UPDATE history h
SET rank = (
    SELECT COALESCE(
        (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0)),
        0
    )
    FROM command_stats s
    WHERE s.cmd_hash = lower(hex(sha256(h.cmd)))
)
WHERE id BETWEEN ? AND ?;
```

**Drawback:** This requires SQLite to support the `sha256` extension, which may not be available by default on all systems.

### Solution 3: Use Subquery with JOIN

Use a different query approach:

```sql
UPDATE history h
SET rank = (
    SELECT COALESCE(
        (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0)),
        0
    )
    FROM command_stats s
    WHERE s.cmd = h.cmd
)
WHERE id BETWEEN ? AND ?;
```

This joins on the `cmd` text directly instead of using hash.

**Advantages:**
- No schema changes needed
- Simpler query
- Works immediately

**Drawbacks:**
- Text comparison is slower than hash comparison
- Case sensitivity issues (though can be mitigated with COLLATE NOCASE)

## Recommended Fix

**Solution 3** (Subquery with JOIN) is recommended because:

1. No database migration required
2. Simple to implement
3. Works immediately without schema changes
4. Performance impact is minimal for 21,000 entries

### Implementation

In `src/db/ranking.zig`, modify `recalculateAllRanks`:

```zig
const update_query =
    \\UPDATE history h
    \\SET rank = (
    \\    SELECT COALESCE(
    \\        (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0)),
    \\        0
    \\    )
    \\    FROM command_stats s
    \\    WHERE s.cmd = h.cmd
    \\)
    \\WHERE id BETWEEN ? AND ?;
;
```

Similarly update `updateHistoryRank`:

```zig
const query =
    \\UPDATE history h
    \\SET rank = (
    \\    SELECT (s.frequency * ?) + (? / MAX(1, (? - s.last_used) / 86400.0))
    \\    FROM command_stats s
    \\    WHERE s.cmd = ?
    \\)
    \\WHERE h.id = ?;
;
```

And update the exec call:
```zig
try stmt.exec(.{}, .{
    config.frequency_weight,
    config.recency_weight,
    current_time,
    row.cmd,  // Changed from cmd_hash
    history_id,
});
```

## Testing

After implementing the fix, test with:

```bash
zigstory recalc-rank
```

Expected output:
```
Initializing ranking system...
Recalculating ranks with batch size: 100
Populating command_stats table from history...
command_stats already has 4292 entries. Skipping population.

Recalculating ranks for all history entries...
Progress: 100/21084 (0.5%)...
...
Progress: 21084/21084 (100.0%)

Recalculation complete!
```

Then verify ranks are set:
```bash
sqlite3 ~/.zigstory/history.db "SELECT COUNT(*) FROM history WHERE rank > 0"
```

Should return `21084` (or however many entries exist).

## References

- **File:** `C:\git\zigstory\src\db\ranking.zig`
- **Function:** `recalculateAllRanks` (line 156)
- **Function:** `updateHistoryRank` (line 123)
- **Table schema:** `src/db/database.zig` (lines 52-63)
