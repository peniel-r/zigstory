# zigstory PowerShell Profile Integration
# This script hooks into PowerShell's Prompt function to track command history
# Optimized with batching and command filtering to minimize overhead

# Configuration - Set the path to your zigstory binary
# Option 1: Use full path to the built binary
$Global:ZigstoryBin = "$PSScriptRoot\..\zig-out\bin\zigstory.exe"

# Option 2: If you've added zigstory to your PATH, use this instead:
# $Global:ZigstoryBin = "zigstory"

# Batch configuration
$Global:ZigstoryMaxQueueSize = 10  # max commands before forcing a flush

# Initialize queue if not exists
if ($null -eq $Global:ZigstoryQueue) {
    $Global:ZigstoryQueue = [System.Collections.Generic.List[hashtable]]::new()
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
        # Use Start-Process to avoid blocking
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $Global:ZigstoryBin
        $processInfo.Arguments = "import --file `"$tempFile`""
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null
        $process.WaitForExit() | Out-Null

        $exitCode = $process.ExitCode

        if ($exitCode -eq 0) {
            $count = $Global:ZigstoryQueue.Count
            $Global:ZigstoryQueue.Clear()
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
        # Flush in background to avoid blocking prompt
        Start-Job -ScriptBlock {
            . $using:ProfilePath
            $Global:ZigstoryBin = "$using:ProfilePath\..\zig-out\bin\zigstory.exe"
            $Global:ZigstoryQueue = $using:ZigstoryQueue
            ZigstoryFlushQueue
        } -ArgumentList $PSScriptRoot -Name ZigstoryFlush | Out-Null
    }
}

# Save the existing prompt function if it exists to avoid breaking other tools
if (Test-Path Function:\Prompt) {
    if ($null -eq $Global:ZigstoryOldPrompt) {
        $Global:ZigstoryOldPrompt = $ExecutionContext.InvokeCommand.GetCommand('Prompt', 'Function')
    }
}

# Track last history ID to avoid duplicates
if ($null -eq $Global:ZigstoryLastHistoryId) {
    $Global:ZigstoryLastHistoryId = -1
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
} | Out-Null

Write-Host "zigstory history tracking enabled (batch mode: flush every $Global:ZigstoryMaxQueueSize commands)" -ForegroundColor Green
Write-Host "Your commands are now being recorded to: $env:USERPROFILE\.zigstory\history.db" -ForegroundColor DarkGray
Write-Host "Commands are batched for optimal performance - no prompt delays!" -ForegroundColor DarkGray
