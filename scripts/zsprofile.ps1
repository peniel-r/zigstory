# ─────────────────────────────────────────────────────────────────────────────
# zigstory PowerShell Profile Integration
# ─────────────────────────────────────────────────────────────────────────────

# Auto-detect zigstory executable location
# Try APPDATA first (installed), then repository (dev)
$AppDataExe = Join-Path $env:APPDATA "zigstory\zigstory.exe"
if (Test-Path $AppDataExe) {
    $Global:ZigstoryBin = $AppDataExe
} else {
    # Try to find in repository (dev mode)
    $ScriptRepoRoot = Split-Path -Parent $PSScriptRoot
    $DevExe = Join-Path $ScriptRepoRoot "zig-out\bin\zigstory.exe"
    if (Test-Path $DevExe) {
        $Global:ZigstoryBin = $DevExe
    } else {
        # Last resort: assume it's in PATH
        $Global:ZigstoryBin = "zigstory.exe"
    }
}

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

foreach ($name in @('ZigstoryRecordingProcesses', 'ZigstorySessionId', 'ZigstoryAcceptedCommand',
    'ZigstoryHistoryCaptureInstalled', 'ZigstoryPreviousHistoryHandler',
    'ZigstoryOldPromptScriptBlock', 'ZigstoryLastHistoryId')) {
    if ($null -eq (Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue)) {
        Set-Variable -Name $name -Scope Global -Value $null
    }
}
if ($null -eq $Global:ZigstoryRecordingProcesses) {
    $Global:ZigstoryRecordingProcesses = [Collections.Generic.List[object]]::new()
}
if ($null -eq $Global:ZigstorySessionId) {
    $Global:ZigstorySessionId = [Guid]::NewGuid().ToString()
}
$Global:ZigstoryPromptDirectory = $PWD.ProviderPath

function Global:Get-ZigstoryRecordingDirectory {
    $homeDirectory = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if (-not $homeDirectory) { throw 'Cannot determine history recording directory' }
    return Join-Path $homeDirectory '.zigstory\pending'
}

function Global:Start-ZigstoryRecordingImport([string]$Path) {
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
        $process.StartInfo.FileName = $Global:ZigstoryBin
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardError = $true
        foreach ($argument in @('import', '--file', $Path, '--consume')) {
            $process.StartInfo.ArgumentList.Add($argument)
        }
        if (-not $process.Start()) { throw 'Importer did not start' }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $Global:ZigstoryRecordingProcesses.Add([pscustomobject]@{
            Process = $process
            ErrorTask = $errorTask
            Path = $Path
        })
    } catch {
        $process.Dispose()
        [IO.File]::WriteAllText("$Path.error", "Launch failed: $($_.Exception.Message)")
        throw
    }
}

function Global:Complete-ZigstoryRecordings {
    [CmdletBinding()]
    param()
    for ($i = $Global:ZigstoryRecordingProcesses.Count - 1; $i -ge 0; $i--) {
        $recording = $Global:ZigstoryRecordingProcesses[$i]
        if (-not $recording.Process.HasExited) { continue }
        try {
            $detail = $recording.ErrorTask.GetAwaiter().GetResult()
            if ($recording.Process.ExitCode -ne 0 -or [IO.File]::Exists($recording.Path)) {
                if (-not [IO.File]::Exists("$($recording.Path).error")) {
                    [IO.File]::WriteAllText("$($recording.Path).error",
                        "Importer exited with code $($recording.Process.ExitCode) without consuming the payload. Verify the installed executable supports --consume. $detail")
                }
                Write-Warning "zigstory recording failed. Payload: $($recording.Path); diagnostic: $($recording.Path).error. Run Retry-ZigstoryPendingRecordings after resolving the error."
            }
        } finally {
            $recording.Process.Dispose()
            $Global:ZigstoryRecordingProcesses.RemoveAt($i)
        }
    }
}

function Global:Retry-ZigstoryPendingRecordings {
    Complete-ZigstoryRecordings
    $directory = Get-ZigstoryRecordingDirectory
    if (-not [IO.Directory]::Exists($directory)) { return }
    foreach ($path in [IO.Directory]::EnumerateFiles($directory, '*.json')) {
        if (@($Global:ZigstoryRecordingProcesses | Where-Object Path -eq $path).Count -gt 0) { continue }
        try {
            Start-ZigstoryRecordingImport $path
        } catch {
            Write-Warning "zigstory could not retry $path; see $path.error. $($_.Exception.Message)"
        }
    }
}

function Global:ZigstoryRecordCommand($cmd, $cwd, $exitCode, $duration,
    [long]$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
    $directory = Get-ZigstoryRecordingDirectory
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $eventId = [Guid]::NewGuid().ToString()
    $path = Join-Path $directory "$eventId.json"
    $payload = @{
        cmd = $cmd
        cwd = $cwd
        exit_code = $exitCode
        duration_ms = $duration
        timestamp = $timestamp
        session_id = $Global:ZigstorySessionId
        hostname = [Environment]::MachineName
        event_id = $eventId
    }
    $json = ConvertTo-Json -InputObject @($payload) -Compress
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    Start-ZigstoryRecordingImport $path
}

function Global:Initialize-ZigstoryHistoryCapture {
    if ($Global:ZigstoryHistoryCaptureInstalled) { return }
    $Global:ZigstoryPreviousHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler
    Set-PSReadLineOption -AddToHistoryHandler {
        param($line)
        $Global:ZigstoryAcceptedCommand = [pscustomobject]@{
            Command = $line
            Directory = $PWD.ProviderPath
        }
        if ($null -ne $Global:ZigstoryPreviousHistoryHandler) {
            return $Global:ZigstoryPreviousHistoryHandler.Invoke($line)
        }
        return $true
    }
    $Global:ZigstoryHistoryCaptureInstalled = $true
}

function Global:Get-ZigstoryExitCode([bool]$Succeeded, $NativeExitCode, [string]$Command) {
    if ($Succeeded) { return 0 }
    if ($null -eq $NativeExitCode -or $NativeExitCode -eq 0) { return 1 }
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -eq 0 -and $ast.EndBlock.Statements.Count -gt 0) {
        $statement = $ast.EndBlock.Statements[-1]
        if ($statement -is [Management.Automation.Language.PipelineAst]) {
            $lastCommand = $statement.PipelineElements[-1]
            if ($lastCommand -is [Management.Automation.Language.CommandAst]) {
                $name = $lastCommand.GetCommandName()
                if ($name) {
                    $resolved = Get-Command $name -ErrorAction SilentlyContinue
                    while ($resolved -is [Management.Automation.AliasInfo]) { $resolved = $resolved.ResolvedCommand }
                    if ($null -ne $resolved -and $resolved.CommandType -eq 'Application') {
                        return [int]$NativeExitCode
                    }
                }
            }
        }
    }
    return 1
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
    # Capture status before any PowerShell statement can overwrite $?.
    $commandSucceeded = $?
    $nativeExitCode = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $completedDirectory = $PWD.ProviderPath
    # Get history silently - no output
    $lastHistory = Get-History -Count 1 -ErrorAction SilentlyContinue
    
    if ($lastHistory -and $lastHistory.Id -ne $Global:ZigstoryLastHistoryId) {
        $Global:ZigstoryLastHistoryId = $lastHistory.Id
        try {
            if (ZigstoryShouldRecord $lastHistory.CommandLine) {
                $duration = [long][Math]::Max(0, $lastHistory.Duration.TotalMilliseconds)
                $exitCode = Get-ZigstoryExitCode $commandSucceeded $nativeExitCode $lastHistory.CommandLine
                $cwd = $Global:ZigstoryPromptDirectory
                if ($null -ne $Global:ZigstoryAcceptedCommand -and
                    $Global:ZigstoryAcceptedCommand.Command -ceq $lastHistory.CommandLine) {
                    $cwd = $Global:ZigstoryAcceptedCommand.Directory
                }
                $timestamp = ([DateTimeOffset]$lastHistory.StartExecutionTime).ToUnixTimeSeconds()
                ZigstoryRecordCommand $lastHistory.CommandLine $cwd $exitCode $duration $timestamp
            }
        }
        catch {
            Write-Warning "zigstory could not record the last command: $($_.Exception.Message)"
        }
    }
    $Global:ZigstoryAcceptedCommand = $null
    $Global:ZigstoryPromptDirectory = $completedDirectory
    try { Complete-ZigstoryRecordings }
    catch { Write-Warning "zigstory recording status check failed: $($_.Exception.Message)" }

    # Invoke the old prompt if it exists, otherwise return simple prompt
    if ($null -ne $Global:ZigstoryOldPromptScriptBlock) {
        & $Global:ZigstoryOldPromptScriptBlock
    } else {
        "PS $PWD> "
    }
}

Write-Host "zigstory enabled!" -ForegroundColor Green

# Load zigstory predictor assembly
# Auto-detect predictor DLL location
$PredictorModuleDir = Join-Path $env:USERPROFILE "Documents\PowerShell\Modules\zigstoryPredictor"
$ModulesDll = Join-Path $PredictorModuleDir "zigstoryPredictor.dll"

# Try modules directory first (installed), then repository (dev)
$possibleDllPaths = @()
if (Test-Path $ModulesDll) {
    $possibleDllPaths += $ModulesDll
} else {
    # Dev mode: check repository
    $ScriptRepoRoot = Split-Path -Parent $PSScriptRoot
    $possibleDllPaths += Join-Path $ScriptRepoRoot "src\predictor\bin\publish\zigstoryPredictor.dll"
    $possibleDllPaths += Join-Path $ScriptRepoRoot "src\predictor\bin\Release\net8.0\zigstoryPredictor.dll"
    $possibleDllPaths += Join-Path $ScriptRepoRoot "src\predictor\bin\Debug\net8.0\zigstoryPredictor.dll"
}

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
    # IMPORTANT: Use ONLY Plugin to avoid [History] tag showing up
    Set-PSReadLineOption -PredictionSource Plugin -ErrorAction SilentlyContinue
    Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
    
    Write-Host "Predictive IntelliSense enabled (Plugin mode)" -ForegroundColor Green
} else {
    Write-Host "Warning: zigstory predictor DLL not loaded - history recording only" -ForegroundColor Yellow
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
    
    # Bind Ctrl+R to interactive search
    if (Get-Module -ListAvailable PSReadLine) {
        Import-Module PSReadLine
        Initialize-ZigstoryHistoryCapture
        Set-PSReadLineKeyHandler -Key "Ctrl+r" -ScriptBlock {
            $oldClip = Get-Clipboard -Raw
            # Mark clipboard so we know if selection happened
            Set-Clipboard -Value "__ZS_CANCEL__"
            
            # Start-Process -NoNewWindow is more reliable for TUIs from key handlers
            $p = Start-Process -FilePath $Global:ZigstoryBin -ArgumentList "search" -Wait -NoNewWindow -PassThru
            
            $selected = Get-Clipboard -Raw
            if ($selected -and $selected -ne "__ZS_CANCEL__") {
                [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected)
            } elseif ($oldClip) {
                Set-Clipboard -Value $oldClip
            }
        }

        # Bind Ctrl+F to fzf search
        Set-PSReadLineKeyHandler -Key "Ctrl+f" -ScriptBlock {
            $oldClip = Get-Clipboard -Raw
            # Mark clipboard so we know if selection happened
            Set-Clipboard -Value "__ZS_FZF_CANCEL__"
            
            # Start-Process -NoNewWindow is more reliable for TUIs from key handlers
            $p = Start-Process -FilePath $Global:ZigstoryBin -ArgumentList "fzf" -Wait -NoNewWindow -PassThru
            
            $selected = Get-Clipboard -Raw
            if ($selected -and $selected -ne "__ZS_FZF_CANCEL__") {
                [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selected)
            } elseif ($oldClip) {
                Set-Clipboard -Value $oldClip
            }
        }
    }

    Write-Host "Type 'zs' or press 'Ctrl+R' for TUI search, 'Ctrl+F' for fzf search" -ForegroundColor Cyan
}

$pendingDirectory = Get-ZigstoryRecordingDirectory
if ([IO.Directory]::Exists($pendingDirectory) -and
    [IO.Directory]::EnumerateFiles($pendingDirectory, '*.json').GetEnumerator().MoveNext()) {
    Write-Warning "zigstory has pending recordings in $pendingDirectory. Inspect any .error files, then run Retry-ZigstoryPendingRecordings to retry safely."
}
