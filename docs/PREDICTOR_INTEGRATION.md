# ZigstoryPredictor - PowerShell Integration Guide

## Overview

ZigstoryPredictor is a PSReadLine predictor plugin that provides intelligent command suggestions based on your shell history. It delivers ghost text predictions with sub-5ms latency using an optimized SQLite database and LRU caching.

## Requirements

- **PowerShell 7.2+** (PowerShell 7.4+ recommended)
- **.NET 8.0 Runtime**
- **PSReadLine 2.2.0+** with predictive IntelliSense support

## Installation

### Step 1: Build the Predictor

```powershell
# Navigate to predictor directory
cd src/predictor

# Build and publish (includes all dependencies)
dotnet publish -c Release -o bin/publish
```

### Step 2: Register the Predictor

Add the following to your PowerShell profile (`$PROFILE`):

```powershell
# Load zigstory predictor assembly
# (Update this path to your actual installation location)
$zigstoryPath = "f:\sandbox\zigstory\src\predictor\bin\publish"
if (Test-Path "$zigstoryPath\zigstoryPredictor.dll") {
    Add-Type -Path "$zigstoryPath\zigstoryPredictor.dll"

    # Only register if not already registered (prevents error if profile is re-sourced)
    $predictorId = "a8c5e3f1-2b4d-4e9a-8f1c-3d5e7b9a1c2f"
    $existing = Get-PSSubsystem -Kind CommandPredictor | Where-Object { $_.Id -eq $predictorId }

    if (-not $existing) {
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            [zigstoryPredictor.ZigstoryPredictor]::new()
        )
    }

    # Enable predictive IntelliSense
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle ListView
}
```

### Step 3: Verify Installation

```powershell
# Check registered predictors
Get-PSSubsystem -Kind CommandPredictor

# Expected output should include:
# Id                                   Name               Description
# --                                   ----               -----------
# a8c5e3f1-2b4d-4e9a-8f1c-3d5e7b9a1c2f ZigstoryPredictor  Zig-based shell history predictor...
```

## Configuration Options

### Prediction View Styles

```powershell
# Inline ghost text (default)
Set-PSReadLineOption -PredictionViewStyle InlineView

# List view (shows multiple suggestions)
Set-PSReadLineOption -PredictionViewStyle ListView
```

### Prediction Sources

```powershell
# Use only plugin (zigstory)
Set-PSReadLineOption -PredictionSource Plugin

# Use both history and plugin
Set-PSReadLineOption -PredictionSource HistoryAndPlugin

# Disable predictions
Set-PSReadLineOption -PredictionSource None
```

### Key Bindings for ListView

```powershell
# Navigate predictions in list view
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Key UpArrow -Function PreviousSuggestion
Set-PSReadLineKeyHandler -Key DownArrow -Function NextSuggestion

# Accept prediction
Set-PSReadLineKeyHandler -Key RightArrow -Function ForwardChar
Set-PSReadLineKeyHandler -Key End -Function AcceptSuggestion
```

## Database Configuration

The predictor reads from the zigstory database located at:

```
%USERPROFILE%\.zigstory\history.db
```

Ensure the database exists and has been populated by the zigstory hook (`scripts/profile.ps1`).

## Troubleshooting

### Predictor Not Loading

```powershell
# Check if assembly is loaded
[System.AppDomain]::CurrentDomain.GetAssemblies() | 
    Where-Object { $_.FullName -match "zigstoryPredictor" }
```

### No Predictions Appearing

1. **Check minimum input length**: Predictor requires 2+ characters
2. **Verify database exists**: `Test-Path "$env:USERPROFILE\.zigstory\history.db"`
3. **Check predictor registration**: `Get-PSSubsystem -Kind CommandPredictor`

### Performance Issues

The predictor is optimized for sub-5ms response time:

- **Cache hit**: <1ms (LRU cache with 100 entries)
- **Cache miss**: <5ms (indexed SQLite query)
- **Startup impact**: <0.1ms (type resolution only)

## Uninstallation

Remove the predictor registration from your `$PROFILE`:

```powershell
# Remove the Add-Type and SubsystemManager lines from $PROFILE
notepad $PROFILE
```

## Integration with zigstory Hook

For the predictor to have suggestions, you need the zigstory hook recording your commands:

```powershell
# Add to $PROFILE before the predictor registration
. "C:\path\to\zigstory\scripts\profile.ps1"
```

This captures every command with:

- Command text
- Working directory
- Exit code
- Execution duration

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PowerShell Session                        │
├─────────────────────────────────────────────────────────────┤
│  PSReadLine                                                  │
│  ├── PredictionSource: HistoryAndPlugin                     │
│  └── CommandPredictor Subsystem                             │
│       └── ZigstoryPredictor                                 │
│            ├── LruCache (100 entries, <1ms hit)             │
│            ├── DatabaseManager (connection pool, 5 conns)   │
│            └── SQLite Query (indexed, <5ms)                 │
├─────────────────────────────────────────────────────────────┤
│  Database: ~/.zigstory/history.db                           │
│  ├── Table: history (cmd, cwd, exit_code, duration, ...)   │
│  ├── Index: idx_cmd_prefix (prefix search optimization)    │
│  └── FTS5: history_fts (full-text search)                  │
└─────────────────────────────────────────────────────────────┘
```

## API Reference

### ZigstoryPredictor Class

| Property | Type | Description |
|----------|------|-------------|
| `Id` | `Guid` | Unique predictor identifier |
| `Name` | `string` | "ZigstoryPredictor" |
| `Description` | `string` | Predictor description |

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `GetSuggestion` | `PredictionClient`, `PredictionContext`, `CancellationToken` | `SuggestionPackage` | Returns top 5 matching commands |

### DatabaseManager Class

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `GetConnection` | none | `SqliteConnection` | Gets pooled connection |
| `ReturnConnection` | `SqliteConnection` | void | Returns connection to pool |
| `Dispose` | none | void | Cleans up all connections |

### LruCache<TKey, TValue> Class

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `TryGet` | `TKey key`, `out TValue value` | `bool` | Gets cached value if exists |
| `Set` | `TKey key`, `TValue value` | void | Adds/updates cache entry |
| `Clear` | none | void | Removes all entries |
| `Count` | (property) | `int` | Number of cached entries |
