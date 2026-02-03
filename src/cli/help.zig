const std = @import("std");

pub fn printHelp() void {
    const help_text =
        \\
        \\===============================================================================
        \\                      ZIGSTORY - Shell History Manager
        \\===============================================================================
        \\
        \\A high-performance shell history manager with fuzzy search and AI-powered
        \\command prediction. Built in Zig for speed and reliability.
        \\
        \\USAGE:
        \\    zigstory <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    add         Add a command to history
        \\    search      Launch interactive TUI search interface
        \\    fzf         Launch fzf-based search (requires fzf installed)
        \\    import      Import existing PowerShell history
        \\    list        List recent commands
        \\    stats       Display history statistics
        \\    perf        Display performance metrics for directory
        \\    recalc-rank Recalculate frecency ranks for all commands
        \\    help        Display this help message
        \\
        \\===============================================================================
        \\
        \\COMMAND DETAILS:
        \\
        \\  zigstory add [OPTIONS]
        \\    Add a command to the history database.
        \\
        \\    OPTIONS:
        \\      -c, --cmd <TEXT>         Command text (required)
        \\      -w, --cwd <PATH>         Working directory (required)
        \\      -e, --exit <CODE>        Exit code (default: 0)
        \\      -d, --duration <MS>      Execution duration in milliseconds (default: 0)
        \\
        \\    EXAMPLE:
        \\      zigstory add --cmd "git status" --cwd "C:\projects" --exit 0 --duration 125
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory search
        \\    Launch an interactive TUI (Terminal User Interface) for searching and
        \\    selecting commands from your history.
        \\
        \\    FEATURES:
        \\      * Real-time fuzzy search as you type
        \\      * Virtual scrolling for large histories (10,000+ commands)
        \\      * Keyboard navigation (Up/Down, Page Up/Down, Ctrl+K/J)
        \\      * Selected command copied to clipboard
        \\
        \\    KEYBINDINGS:
        \\      Up/Down       Navigate up/down
        \\      Page Up/Down  Scroll by page
        \\      Ctrl+K/J      Page up/down (vim-style)
        \\      Enter         Select command and exit
        \\      Ctrl+C/Esc    Exit without selection
        \\      Type          Filter results in real-time
        \\
        \\    EXAMPLE:
        \\      zigstory search
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory fzf
        \\    Launch fzf-based search interface (requires fzf to be installed).
        \\    Provides a familiar fzf experience for users who prefer it.
        \\
        \\    FEATURES:
        \\      * Uses external fzf binary for search
        \\      * Full fzf keybindings and features
        \\      * Selected command copied to clipboard
        \\
        \\    REQUIREMENTS:
        \\      fzf must be installed and available in PATH
        \\
        \\    EXAMPLE:
        \\      zigstory fzf
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory import [OPTIONS]
        \\    Import existing PowerShell history into zigstory database.
        \\    Automatically detects PowerShell history file location.
        \\
        \\    OPTIONS:
        \\      -f, --file <PATH>        Import from specific file (optional)
        \\
        \\    FEATURES:
        \\      * Automatic duplicate detection
        \\      * Progress tracking during import
        \\      * Handles large history files (10,000+ commands)
        \\      * Preserves command timestamps
        \\
        \\    EXAMPLE:
        \\      zigstory import                           # Import from default location
        \\      zigstory import --file "C:\custom.txt"    # Import from custom file
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory list [COUNT]
        \\    List recent commands from history.
        \\
        \\    ARGUMENTS:
        \\      COUNT                    Number of commands to display (default: 5)
        \\
        \\    EXAMPLE:
        \\      zigstory list            # Show last 5 commands
        \\      zigstory list 20         # Show last 20 commands
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory perf [OPTIONS]
        \\    Display performance metrics for the current directory.
        \\
        \\    OPTIONS:
        \\      -c, --cwd <PATH>         Working directory (default: current)
        \\      -f, --format <text|json> Output format (default: text)
        \\      -t, --threshold <MS>     Warning threshold in ms (default: 5000)
        \\
        \\    FEATURES:
        \\      * Average command duration
        \\      * Last command duration with warning if slow
        \\      * Success rate (shown if < 100%)
        \\      * Total commands in directory
        \\
        \\    EXAMPLE:
        \\      zigstory perf            # Show performance for current directory
        \\      zigstory perf --cwd /path/to/project
        \\      zigstory perf --format json
        \\      zigstory perf --threshold 3000
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory stats
        \\    Display comprehensive statistics about your command history.
        \\
        \\    FEATURES:
        \\      * Total commands executed
        \\      * Unique commands count
        \\      * Success rate (exit code analysis)
        \\      * Top 10 most used commands
        \\      * Commands by hour (ASCII chart)
        \\      * Commands by day of week
        \\      * Top 5 directories by command count
        \\
        \\    EXAMPLE:
        \\      zigstory stats
        \\
        \\-------------------------------------------------------------------------------
        \\
        \\  zigstory recalc-rank
        \\    Recalculate frecency ranks for all commands in history.
        \\
        \\    DESCRIPTION:
        \\      Updates rank values for all commands based on frequency and recency.
        \\      Uses frecency algorithm: rank = (frequency * 2.0) + (100.0 / days_since_last_use)
        \\
        \\    FEATURES:
        \\      * Batch updates (100 rows per transaction)
        \\      * Progress tracking during recalculation
        \\      * Optimized for 10,000+ entries
        \\      * Completes in <1s for 10,000 entries
        \\
        \\    EXAMPLE:
        \\      zigstory recalc-rank
        \\
        \\===============================================================================
        \\
        \\POWERSHELL INTEGRATION:
        \\
        \\  To enable automatic command tracking in PowerShell, add this to your
        \\  PowerShell profile ($PROFILE):
        \\
        \\    . "C:\path\to\zigstory\scripts\zsprofile.ps1"
        \\
        \\  This will:
        \\    * Automatically track every command you run
        \\    * Record exit codes, duration, and working directory
        \\    * Enable the AI-powered predictor for command suggestions
        \\
        \\  To enable the predictor (ghost text suggestions):
        \\
        \\    Import-Module "C:\path\to\zigstoryPredictor.dll"
        \\    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        \\
        \\===============================================================================
        \\
        \\DATABASE LOCATION:
        \\
        \\  Default: %USERPROFILE%\.zigstory\history.db
        \\
        \\  The database uses SQLite with WAL mode for:
        \\    * Concurrent read/write operations
        \\    * Sub-5ms query performance
        \\    * Full-text search
        \\
        \\===============================================================================
        \\
        \\PERFORMANCE:
        \\
        \\  * Single command insert: <50ms
        \\  * Batch insert (100 commands): <1s
        \\  * Search query: <5ms
        \\  * TUI startup: <100ms
        \\  * Memory usage: <50MB with 10,000+ entries
        \\
        \\===============================================================================
        \\
        \\EXAMPLES:
        \\
        \\  # Quick start - import existing history
        \\  zigstory import
        \\
        \\  # Search your history interactively
        \\  zigstory search
        \\
        \\  # List recent commands
        \\  zigstory list 10
        \\
        \\  # Manually add a command
        \\  zigstory add --cmd "npm install" --cwd "C:\project" --exit 0
        \\
        \\  # View history statistics
        \\  zigstory stats
        \\
        \\  # Recalculate command ranks
        \\  zigstory recalc-rank
        \\
        \\===============================================================================
        \\
        \\For more information, visit: https://github.com/yourusername/zigstory
        \\Report bugs at: https://github.com/yourusername/zigstory/issues
        \\
        \\
    ;

    std.debug.print("{s}", .{help_text});
}

pub fn printCommandHelp(command: []const u8) void {
    if (std.mem.eql(u8, command, "add")) {
        printAddHelp();
    } else if (std.mem.eql(u8, command, "search")) {
        printSearchHelp();
    } else if (std.mem.eql(u8, command, "fzf")) {
        printFzfHelp();
    } else if (std.mem.eql(u8, command, "import")) {
        printImportHelp();
    } else if (std.mem.eql(u8, command, "list")) {
        printListHelp();
    } else if (std.mem.eql(u8, command, "stats")) {
        printStatsHelp();
    } else if (std.mem.eql(u8, command, "perf")) {
        printPerfHelp();
    } else if (std.mem.eql(u8, command, "recalc-rank")) {
        printRecalcRankHelp();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printHelp();
    }
}

fn printAddHelp() void {
    const help_text =
        \\
        \\zigstory add - Add a command to history
        \\
        \\USAGE:
        \\    zigstory add [OPTIONS]
        \\
        \\OPTIONS:
        \\    -c, --cmd <TEXT>         Command text (required)
        \\    -w, --cwd <PATH>         Working directory (required)
        \\    -e, --exit <CODE>        Exit code (default: 0)
        \\    -d, --duration <MS>      Execution duration in milliseconds (default: 0)
        \\
        \\DESCRIPTION:
        \\    Adds a command to the zigstory history database. This is typically called
        \\    automatically by the PowerShell profile hook, but can be used manually.
        \\
        \\EXAMPLES:
        \\    zigstory add --cmd "git status" --cwd "C:\projects"
        \\    zigstory add --cmd "npm test" --cwd "C:\app" --exit 1 --duration 5432
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printSearchHelp() void {
    const help_text =
        \\
        \\zigstory search - Interactive TUI search
        \\
        \\USAGE:
        \\    zigstory search
        \\
        \\DESCRIPTION:
        \\    Launches an interactive Terminal User Interface for searching and selecting
        \\    commands from your history. Features real-time fuzzy search, virtual scrolling,
        \\    and keyboard navigation.
        \\
        \\KEYBINDINGS:
        \\    ↑/↓                      Navigate up/down
        \\    Page Up/Down             Scroll by page
        \\    Ctrl+K/J                 Page up/down (vim-style)
        \\    Enter                    Select command and exit
        \\    Ctrl+C/Esc               Exit without selection
        \\    Type                     Filter results in real-time
        \\
        \\FEATURES:
        \\    • Real-time fuzzy search as you type
        \\    • Virtual scrolling for large histories (10,000+ commands)
        \\    • Sub-5ms query performance
        \\    • Selected command copied to clipboard
        \\
        \\EXAMPLES:
        \\    zigstory search
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printFzfHelp() void {
    const help_text =
        \\
        \\zigstory fzf - fzf-based search
        \\
        \\USAGE:
        \\    zigstory fzf
        \\
        \\DESCRIPTION:
        \\    Launches fzf-based search interface. Requires fzf to be installed and
        \\    available in PATH. Provides a familiar fzf experience for users who
        \\    prefer it over the built-in TUI.
        \\
        \\REQUIREMENTS:
        \\    fzf must be installed and available in PATH
        \\    Download from: https://github.com/junegunn/fzf
        \\
        \\FEATURES:
        \\    • Uses external fzf binary for search
        \\    • Full fzf keybindings and features
        \\    • Selected command copied to clipboard
        \\
        \\EXAMPLES:
        \\    zigstory fzf
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printImportHelp() void {
    const help_text =
        \\
        \\zigstory import - Import PowerShell history
        \\
        \\USAGE:
        \\    zigstory import [OPTIONS]
        \\
        \\OPTIONS:
        \\    -f, --file <PATH>        Import from specific file (optional)
        \\
        \\DESCRIPTION:
        \\    Imports existing PowerShell history into the zigstory database.
        \\    Automatically detects the PowerShell history file location if no
        \\    file is specified. Includes duplicate detection to prevent importing
        \\    the same commands multiple times.
        \\
        \\FEATURES:
        \\    • Automatic duplicate detection
        \\    • Progress tracking during import
        \\    • Handles large history files (10,000+ commands)
        \\    • Preserves command timestamps
        \\
        \\EXAMPLES:
        \\    zigstory import                           # Import from default location
        \\    zigstory import --file "C:\custom.txt"    # Import from custom file
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printListHelp() void {
    const help_text =
        \\
        \\zigstory list - List recent commands
        \\
        \\USAGE:
        \\    zigstory list [COUNT]
        \\
        \\ARGUMENTS:
        \\      COUNT                    Number of commands to display (default: 5)
        \\
        \\DESCRIPTION:
        \\      Lists most recent commands from your history. Displays command text,
        \\      working directory, exit code, and execution time.
        \\
        \\EXAMPLES:
        \\      zigstory list            # Show last 5 commands
        \\      zigstory list 20         # Show last 20 commands
        \\      zigstory list 100        # Show last 100 commands
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printStatsHelp() void {
    const help_text =
        \\
        \\zigstory stats - Display history statistics
        \\
        \\USAGE:
        \\    zigstory stats
        \\
        \\DESCRIPTION:
        \\      Displays comprehensive statistics about your command history,
        \\      including total commands, unique commands, success rate, and
        \\      command distribution by time and directory.
        \\
        \\OUTPUT:
        \\      • Total commands executed
        \\      • Unique commands count
        \\      • Success rate (exit code analysis)
        \\      • Top 10 most used commands
        \\      • Commands by hour (ASCII chart)
        \\      • Commands by day of week
        \\      • Top 5 directories by command count
        \\
        \\EXAMPLES:
        \\      zigstory stats
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printRecalcRankHelp() void {
    const help_text =
        \\
        \\zigstory recalc-rank - Recalculate command ranks
        \\
        \\USAGE:
        \\    zigstory recalc-rank
        \\
        \\DESCRIPTION:
        \\      Recalculates frecency ranks for all commands in history.
        \\      The frecency algorithm combines frequency and recency to rank
        \\      commands based on usage patterns.
        \\
        \\ALGORITHM:
        \\      rank = (frequency * 2.0) + (100.0 / days_since_last_use)
        \\
        \\      where:
        \\        • frequency = number of times command executed
        \\        • days_since_last_use = days since most recent execution
        \\
        \\FEATURES:
        \\      • Batch updates (100 rows per transaction)
        \\      • Progress tracking during recalculation
        \\      • Optimized for 10,000+ entries
        \\      • Completes in <1s for 10,000 entries
        \\
        \\EXAMPLES:
        \\    zigstory recalc-rank
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printPerfHelp() void {
    const help_text =
        \\
        \\zigstory perf - Display performance metrics
        \\
        \\USAGE:
        \\    zigstory perf [OPTIONS]
        \\
        \\OPTIONS:
        \\    -c, --cwd <PATH>         Working directory (default: current)
        \\    -f, --format <text|json> Output format (default: text)
        \\    -t, --threshold <MS>     Warning threshold in ms (default: 5000)
        \\
        \\DESCRIPTION:
        \\      Displays performance metrics for commands executed in the specified
        \\      directory. Useful for identifying slow commands and monitoring
        \\      command execution patterns.
        \\
        \\METRICS:
        \\      • Average command duration
        \\      • Last command duration with warning if slow
        \\      • Success rate (shown if < 100%)
        \\      • Total commands in directory
        \\
        \\OUTPUT (text format):
        \\      Displays human-readable duration with warnings:
        \\      - [⚠️] warning if last command exceeds threshold
        \\      - [✅] success rate indicator if < 100%
        \\
        \\OUTPUT (json format):
        \\      Returns JSON with all metrics for custom processing:
        \\      {
        \\        "avg_duration_ms": 1250.5,
        \\        "last_duration_ms": 3420,
        \\        "last_cmd": "npm test",
        \\        "success_rate": 95.2,
        \\        "total_commands": 847,
        \\        "last_exit_code": 0
        \\      }
        \\
        \\STARSHIP INTEGRATION:
        \\      Add to starship.toml for prompt integration:
        \\
        \\      [custom.zigstory_perf]
        \\      description = "Zigstory performance metrics"
        \\      symbol = "⚡"
        \\      when = "if (Test-Path ~/.zigstory/history.db) { $true }"
        \\      shell = ["pwsh", "-NoProfile", "-Command"]
        \\      format = "via [$symbol$output]($style)"
        \\      command = "zigstory perf --format text"
        \\
        \\EXAMPLES:
        \\    zigstory perf                          # Current directory
        \\    zigstory perf --cwd /path/to/project    # Specific directory
        \\    zigstory perf --format json            # JSON output
        \\    zigstory perf --threshold 3000          # Custom threshold
        \\
        \\EXAMPLE OUTPUT:
        \\    1.2s avg [⚠️ last: 5420ms] [✅ 94.5%]
        \\    2.3s avg
        \\    850ms avg [✅ 92.3%]
        \\
        \\
    ;
    std.debug.print("{s}", .{help_text});
}
