# zigstory PowerShell Profile Integration
# This script hooks into PowerShell's Prompt function to track command history
# Optimized with batching and command filtering to minimize overhead

# Configuration - Set the path to your zigstory binary
# Option 1: Use full path to the built binary
$Global:ZigstoryBin = "$PSScriptRoot\..\zig-out\bin\zigstory.exe"

# Option 2: If you've added zigstory to your PATH, use this instead:
# $Global:ZigstoryBin = "zigstory"

# Batch configuration
$Global:ZigstoryBatchInterval = 5  # seconds between batch writes
$Global:ZigstoryMaxQueueSize = 100  # max commands before forcing a flush

# Initialize queue if not exists
if ($null -eq $Global:ZigstoryQueue) {
    $Global:ZigstoryQueue = [System.Collections.Generic.List[hashtable]]::new()
}

# Initialize timer if not exists
if ($null -eq $Global:ZigstoryTimer) {
    $Global:ZigstoryTimer = New-Object System.Timers.Timer
    $Global:ZigstoryTimer.Interval = $Global:ZigstoryBatchInterval * 1000
    $Global:ZigstoryTimer.AutoReset = $true
    Register-ObjectEvent -InputObject $Global:ZigstoryTimer -EventName Elapsed -SourceIdentifier ZigstoryFlushTimer -Action {
        & $Global:ZigstoryFlushFunction
    } | Out-Null
    $Global:ZigstoryTimer.Start()
}

# Verify the binary exists
if (-not (Test-Path $Global:ZigstoryBin)) {
    Write-Host "Warning: zigstory binary not found at: $Global:ZigstoryBin" -ForegroundColor Yellow
    Write-Host "Run 'zig build' first or update `$Global:ZigstoryBin path" -ForegroundColor Yellow
    return
}

# Commands to skip (patterns)
$Global:ZigstorySkipPatterns = @(
    '^\s*$'                    # Empty or whitespace only
    '^[a-zA-Z]:$'              # Drive letter (e.g., "C:")
    '^exit$'                   # exit command
    '^cd\s+$'                  # cd with no args
    '^cd \.$'                  # cd to current dir
    '^pwd$'                    # pwd command
    '^cls$'                    # cls command
    '^clear$'                  # clear command
    '^$'                       # Empty line
)

# Determine if a command should be recorded
function Global:ZigstoryShouldRecord($cmd) {
    $trimmedCmd = $cmd.Trim()

    # Skip empty commands
    if ([string]::IsNullOrWhiteSpace($trimmedCmd)) {
        return $false
    }

    # Skip matching patterns
    foreach ($pattern in $Global:ZigstorySkipPatterns) {
        if ($trimmedCmd -match $pattern) {
            return $false
        }
    }

    return $true
}

# Flush queued commands to zigstory in batch
function Global:ZigstoryFlushQueue {
    if ($Global:ZigstoryQueue.Count -eq 0) {
        return
    }

    # Create temp file for batch import
    $tempFile = [System.IO.Path]::GetTempFileName()

    try {
        # Write queued commands to temp file (JSON format for easy parsing)
        # Build JSON manually to avoid escaping issues with ConvertTo-Json
        $json = "["
        $first = $true

        foreach ($item in $Global:ZigstoryQueue) {
            if (-not $first) {
                $json += ","
            }
            $first = $false

            # Escape cmd string properly (escape quotes and backslashes)
            $escapedCmd = $item.cmd -replace '\\', '\\' -replace '"', '\"'

            $json += "{"
            $json += "`"cmd`":`"$escapedCmd`","
            $json += "`"cwd`":`"$($item.cwd -replace '\\', '\\' )`","
            $json += "`"exit_code`":$($item.exit_code),"
            $json += "`"duration_ms`":$($item.duration_ms)"
            $json += "}"
        }

        $json += "]"

        # Write JSON to temp file (UTF8 without BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile, $json, $utf8NoBom)

        # Call zigstory to process batch (we'll use the import command for this)
        $result = & $Global:ZigstoryBin import --file $tempFile 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            $count = $Global:ZigstoryQueue.Count
            $Global:ZigstoryQueue.Clear()
            # Uncomment for debugging:
            # Write-Host "Flushed $count commands to zigstory" -ForegroundColor DarkGray
        }
    }
    catch {
        # Silently ignore errors during flush
    }
    finally {
        # Cleanup temp file
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# Make the flush function accessible to timer
$Global:ZigstoryFlushFunction = ${function:ZigstoryFlushQueue}

# Queue a command for batch writing
function Global:ZigstoryQueueCommand($cmd, $cwd, $exitCode, $duration) {
    $Global:ZigstoryQueue.Add(@{
        cmd = $cmd
        cwd = $cwd
        exit_code = $exitCode
        duration_ms = $duration
    })

    # Force flush if queue is too large
    if ($Global:ZigstoryQueue.Count -ge $Global:ZigstoryMaxQueueSize) {
        ZigstoryFlushQueue
    }
}

# Save the existing prompt function if it exists to avoid breaking other tools
if (Test-Path Function:\Prompt) {
    if ($null -eq $Global:ZigstoryOldPrompt) {
        $Global:ZigstoryOldPrompt = $ExecutionContext.InvokeCommand.GetCommand('Prompt', 'Function')
    }
}

function Global:Prompt {
    # Get the last executed command
    $lastHistory = Get-History -Count 1

    # Only record if it's a new command we haven't seen before
    if ($lastHistory -and $lastHistory.Id -ne $Global:ZigstoryLastHistoryId) {
        $Global:ZigstoryLastHistoryId = $lastHistory.Id

        try {
            # Filter out trivial commands
            if (ZigstoryShouldRecord $lastHistory.CommandLine) {
                # Use actual execution duration from history
                $duration = [int]$lastHistory.Duration.TotalMilliseconds

                # Get exit code of the last command
                $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }

                # Get current working directory
                $cwd = $PWD.ProviderPath

                # Queue command for batch write (this is fast!)
                ZigstoryQueueCommand $lastHistory.CommandLine $cwd $exitCode $duration
            }
        }
        catch {
            # Silently ignore errors
        }
    }

    # Call original prompt or return default
    if ($Global:ZigstoryOldPrompt) {
        & $Global:ZigstoryOldPrompt
    }
    else {
        "PS $PWD> "
    }
}

# Cleanup handler - flush pending writes on exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    ZigstoryFlushQueue

    # Stop and cleanup timer
    if ($Global:ZigstoryTimer) {
        $Global:ZigstoryTimer.Stop()
        Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
        $Global:ZigstoryTimer.Dispose()
    }
} | Out-Null

# Ctrl+R handler placeholder for Phase 4
# Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock {
#     $result = & $Global:ZigstoryBin search 2>&1
#     if ($LASTEXITCODE -eq 0 -and $result) {
#         [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
#         [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
#     }
# }

Write-Host "zigstory history tracking enabled (batch mode: $Global:ZigstoryBatchInterval second intervals)" -ForegroundColor Green
Write-Host "Your commands are now being recorded to: $env:USERPROFILE\.zigstory\history.db" -ForegroundColor DarkGray
Write-Host "Commands are batched for optimal performance - no prompt delays!" -ForegroundColor DarkGray
