# zigstory PowerShell Profile Integration

# Resolve paths relative to this script
$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$Global:ZigstoryBin = Join-Path $RepoRoot "zig-out\bin\zigstory.exe"

# Commands to skip
$Global:ZigstorySkipPatterns = @(
    '^\s*$', '^[a-zA-Z]:$', '^exit$', '^cd\s+$',
    '^cd \.$', '^pwd$', '^cls$', '^clear$', '^$'
)

function Global:ZigstoryShouldRecord($cmd) {
    $trimmedCmd = $cmd.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedCmd)) { return $false }
    foreach ($pattern in $Global:ZigstorySkipPatterns) {
        if ($trimmedCmd -match $pattern) { return $false }
    }
    return $true
}

# Write command asynchronously (truly detached)
function Global:ZigstoryRecordCommand($cmd, $cwd, $exitCode, $duration) {
    if (-not (Test-Path $Global:ZigstoryBin)) { return }

    # Build temp JSON
    $tempFile = [System.IO.Path]::GetTempFileName()
    $cmdEsc = $cmd -replace '\\', '\\' -replace '"', '\"'
    $cwdEsc = $cwd -replace '\\', '\\'
    $json = "[{`"cmd`":`"$cmdEsc`",`"cwd`":`"$cwdEsc`",`"exit_code`":$exitCode,`"duration_ms`":$duration}]"

    # Write to temp file
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempFile, $json, $utf8)

    # Detached execution - no waiting at all
    # NOTE: The empty "" after /min is the window title - required when exe path is quoted
    Start-Process cmd.exe -ArgumentList "/c", "start /b /min `"`" `"$Global:ZigstoryBin`" import --file `"$tempFile`"" -WindowStyle Hidden -ErrorAction SilentlyContinue
}

# IMPORTANT: Capture old prompt BEFORE we define ours, and only once
if ($null -eq $Global:ZigstoryOldPromptScriptBlock) {
    # Get the script block of the current prompt function, not a reference
    $currentPrompt = Get-Command Prompt -ErrorAction SilentlyContinue
    if ($currentPrompt -and $currentPrompt.ScriptBlock) {
        $Global:ZigstoryOldPromptScriptBlock = $currentPrompt.ScriptBlock
    }
}

if ($null -eq $Global:ZigstoryLastHistoryId) {
    $Global:ZigstoryLastHistoryId = -1
}

function Global:Prompt {
    # Get history silently - no output
    $lastHistory = Get-History -Count 1 -ErrorAction SilentlyContinue
    
    if ($lastHistory -and $lastHistory.Id -ne $Global:ZigstoryLastHistoryId) {
        $Global:ZigstoryLastHistoryId = $lastHistory.Id
        try {
            if (ZigstoryShouldRecord $lastHistory.CommandLine) {
                $duration = [int]$lastHistory.Duration.TotalMilliseconds
                $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
                $cwd = $PWD.ProviderPath
                ZigstoryRecordCommand $lastHistory.CommandLine $cwd $exitCode $duration
            }
        }
        catch {
            # Silently ignore errors to prevent prompt issues
        }
    }

    # Return prompt string - don't invoke old prompt to avoid recursion
    # Just return a simple prompt
    "PS $PWD> "
}

Write-Host "zigstory enabled (detached writes)" -ForegroundColor Green

# Load zigstory predictor assembly
# Check both Release (dev) and publish (release) locations
$possibleDllPaths = @(
    (Join-Path $RepoRoot "src\predictor\bin\Release\net8.0\zigstoryPredictor.dll"),
    (Join-Path $RepoRoot "src\predictor\bin\publish\zigstoryPredictor.dll")
)

$dllLoaded = $false
foreach ($dllPath in $possibleDllPaths) {
    if (Test-Path $dllPath) {
        try {
            Add-Type -Path $dllPath
            $dllLoaded = $true
            break
        } catch {
            Write-Warning "Failed to load zigstory predictor from $dllPath"
        }
    }
}

if ($dllLoaded) {
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
    Set-PSReadLineOption -PredictionSource Plugin
    Set-PSReadLineOption -PredictionViewStyle ListView
}

# ─────────────────────────────────────────────────────────────────────────────
# Interactive History Search (TUI)
# ─────────────────────────────────────────────────────────────────────────────

if (Test-Path $Global:ZigstoryBin) {
    # Create a simple function to launch TUI search
    function Global:Search-ZigstoryHistory {
        # Launch TUI directly
        & $Global:ZigstoryBin search
    }
    
    # Create short alias
    Set-Alias -Name zs -Value Search-ZigstoryHistory -Scope Global
    
    Write-Host "Type 'zs' for interactive history search" -ForegroundColor Cyan
}

