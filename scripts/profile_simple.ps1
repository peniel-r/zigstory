# zigstory PowerShell Profile Integration (SIMPLIFIED - NO ASYNC)
# This version removes all async operations to avoid freezing

# Configuration
$Global:ZigstoryBin = "$PSScriptRoot\..\zig-out\bin\zigstory.exe"

# Initialize queue
if ($null -eq $Global:ZigstoryQueue) {
    $Global:ZigstoryQueue = [System.Collections.Generic.List[hashtable]]::new()
}

# Skip patterns
$Global:ZigstorySkipPatterns = @(
    '^\s*$'
    '^[a-zA-Z]:$'
    '^exit$'
    '^cd\s+$'
    '^cd \.$'
    '^pwd$'
    '^cls$'
    '^clear$'
    '^$'
)

# Should record function
function Global:ZigstoryShouldRecord($cmd) {
    $trimmedCmd = $cmd.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedCmd)) {
        return $false
    }
    foreach ($pattern in $Global:ZigstorySkipPatterns) {
        if ($trimmedCmd -match $pattern) {
            return $false
        }
    }
    return $true
}

# Flush function
function Global:ZigstoryFlushQueue {
    if ($Global:ZigstoryQueue.Count -eq 0) {
        return
    }

    $tempFile = [System.IO.Path]::GetTempFileName()

    try {
        $json = "["
        $first = $true

        foreach ($item in $Global:ZigstoryQueue) {
            if (-not $first) {
                $json += ","
            }
            $first = $false
            $escapedCmd = $item.cmd -replace '\\', '\\' -replace '"', '\"'
            $json += "{"
            $json += "`"cmd`":`"$escapedCmd`","
            $json += "`"cwd`":`"$($item.cwd -replace '\\', '\\' )`","
            $json += "`"exit_code`":$($item.exit_code),"
            $json += "`"duration_ms`":$($item.duration_ms)"
            $json += "}"
        }

        $json += "]"

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile, $json, $utf8NoBom)

        # Direct call - will block but that's OK for now
        & $Global:ZigstoryBin import --file $tempFile 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            $Global:ZigstoryQueue.Clear()
        }
    }
    catch {
        # Silently ignore
    }
    finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# Queue command
function Global:ZigstoryQueueCommand($cmd, $cwd, $exitCode, $duration) {
    $Global:ZigstoryQueue.Add(@{
        cmd = $cmd
        cwd = $cwd
        exit_code = $exitCode
        duration_ms = $duration
    })
}

# Prompt hook - MINIMAL
if ($null -eq $Global:ZigstoryOldPrompt) {
    if (Test-Path Function:\Prompt) {
        $Global:ZigstoryOldPrompt = $ExecutionContext.InvokeCommand.GetCommand('Prompt', 'Function')
    }
}

$Global:ZigstoryLastHistoryId = -1

function Global:Prompt {
    $lastHistory = Get-History -Count 1 -ErrorAction SilentlyContinue

    if ($lastHistory -and $lastHistory.Id -ne $Global:ZigstoryLastHistoryId) {
        $Global:ZigstoryLastHistoryId = $lastHistory.Id

        try {
            if (ZigstoryShouldRecord $lastHistory.CommandLine) {
                $duration = [int]$lastHistory.Duration.TotalMilliseconds
                $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
                $cwd = $PWD.ProviderPath

                ZigstoryQueueCommand $lastHistory.CommandLine $cwd $exitCode $duration
            }
        }
        catch {
            # Silently ignore
        }
    }

    if ($Global:ZigstoryOldPrompt) {
        & $Global:ZigstoryOldPrompt
    } else {
        "PS $PWD> "
    }
}

# Manual flush function available to user
function Global:Flush-Zigstory {
    ZigstoryFlushQueue
    Write-Host "Flushed zigstory queue" -ForegroundColor DarkGray
}

Write-Host "zigstory enabled (manual flush with Flush-Zigstory)" -ForegroundColor Green
