#Requires -Version 7.0
param(
    [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'),
    [switch]$LaunchAndExit,
    [string]$RecordingHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$directory = Join-Path ([IO.Path]::GetTempPath()) "zigstory recording & test's_$([Guid]::NewGuid().ToString('N'))"
$originalHome = $env:USERPROFILE
$originalUnixHome = $env:HOME
$originalAppData = $env:APPDATA
$Global:ZigstoryBin = (Resolve-Path -LiteralPath $Exe).Path
$Global:ZigstorySessionId = [Guid]::NewGuid().ToString()
$Global:ZigstoryRecordingProcesses = [Collections.Generic.List[object]]::new()
$Global:ZigstoryHistoryCaptureInstalled = $false
$Global:ZigstoryPreviousHistoryHandler = $null
$Global:ZigstoryAcceptedCommand = $null
$Global:ZigstoryOldPromptScriptBlock = {}
$Global:ZigstoryLastHistoryId = -1
$Global:ZigstorySkipPatterns = @()
$Global:LASTEXITCODE = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}

$tokens = $null
$parseErrors = $null
$profilePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\zsprofile.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ne 'Global:Search-ZigstoryHistory'
}, $true)) {
    Invoke-Expression $function.Extent.Text
}

function Wait-Recording {
    foreach ($recording in $Global:ZigstoryRecordingProcesses) {
        if (-not $recording.Process.WaitForExit(15000)) { throw 'Recording process did not finish in 15 seconds' }
    }
    Complete-ZigstoryRecordings
}

if ($LaunchAndExit) {
    $env:USERPROFILE = $RecordingHome
    ZigstoryRecordCommand 'echo shell exited' 'shell-exited' 0 1
    Write-Output $Global:ZigstoryRecordingProcesses[0].Path
    exit 0
}

Import-Module PSReadLine
$originalHandler = (Get-PSReadLineOption).AddToHistoryHandler
try {
    New-Item -ItemType Directory -Path $directory | Out-Null
    $env:USERPROFILE = $directory
    $env:HOME = $directory
    $env:APPDATA = Join-Path $directory 'AppData'
    $cwd = 'C:\recording tests\quotes & spaces'
    ZigstoryRecordCommand 'echo recorded' $cwd 0 3000000000 1234567890
    Assert-True ($Global:ZigstoryRecordingProcesses.Count -eq 1) 'Recording immediately launches one asynchronous importer'
    Wait-Recording
    $pending = Get-ZigstoryRecordingDirectory
    Assert-True (@([IO.Directory]::EnumerateFiles($pending)).Count -eq 0) 'Successful import cleans its payload without waiting for another prompt'
    $metrics = & $Global:ZigstoryBin perf --cwd $cwd --format json | ConvertFrom-Json
    Assert-True ($metrics.total_commands -eq 1 -and $metrics.last_duration_ms -eq 3000000000) 'Recording preserves 64-bit duration'

    $validBin = $Global:ZigstoryBin
    $Global:ZigstoryBin = Join-Path $directory 'not-installed.exe'
    $launchFailed = $false
    try { ZigstoryRecordCommand 'echo retry' $cwd 7 125 1234567891 } catch { $launchFailed = $true }
    Assert-True $launchFailed 'Launch errors are surfaced rather than silently discarded'
    $payloadPath = @([IO.Directory]::EnumerateFiles($pending, '*.json'))[0]
    Assert-True ([IO.File]::Exists("$payloadPath.error")) 'Failed launch retains a payload and persistent diagnostic'
    $payload = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json
    Assert-True ($payload[0].timestamp -eq 1234567891 -and $payload[0].session_id -eq $Global:ZigstorySessionId) 'Payload preserves execution timestamp and shell session ID'
    $retryCopy = Join-Path $directory 'retry.json'
    Copy-Item -LiteralPath $payloadPath -Destination $retryCopy
    $Global:ZigstoryBin = $validBin
    Retry-ZigstoryPendingRecordings
    Wait-Recording
    Assert-True (-not [IO.File]::Exists($payloadPath) -and -not [IO.File]::Exists("$payloadPath.error")) 'Retry cleans payload and old diagnostic after success'
    & $Global:ZigstoryBin import --file $retryCopy --consume 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and -not [IO.File]::Exists($retryCopy)) 'Already committed events can be consumed again safely'
    $metrics = & $Global:ZigstoryBin perf --cwd $cwd --format json | ConvertFrom-Json
    Assert-True ($metrics.total_commands -eq 2) 'Retry does not duplicate history'

    $cleanupPath = Join-Path $directory 'locked.json'
    [IO.File]::WriteAllText($cleanupPath,
        '[{"cmd":"committed before cleanup","cwd":"locked","event_id":"cleanup-retry"}]')
    $lock = [IO.File]::Open($cleanupPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        & $Global:ZigstoryBin import --file $cleanupPath --consume 2>&1 | Out-Null
        Assert-True ($LASTEXITCODE -ne 0) 'Payload cleanup failures return an error after commit'
        Assert-True ([IO.File]::Exists($cleanupPath) -and [IO.File]::Exists("$cleanupPath.error")) 'Cleanup failure retains a retryable payload and diagnostic'
    } finally { $lock.Dispose() }
    & $Global:ZigstoryBin import --file $cleanupPath --consume 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and -not [IO.File]::Exists($cleanupPath)) 'Cleanup-failure retry succeeds'
    $metrics = & $Global:ZigstoryBin perf --cwd 'locked' --format json | ConvertFrom-Json
    Assert-True ($metrics.total_commands -eq 1) 'Cleanup-failure retry does not duplicate already committed history'
    & $Global:ZigstoryBin import --consume 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) 'Consume mode requires an explicit file'

    $childPayload = & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Exe $validBin -LaunchAndExit -RecordingHome $directory
    Assert-True ($LASTEXITCODE -eq 0) 'Recording shell can exit without waiting for the importer'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([IO.File]::Exists($childPayload) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 20
    }
    Assert-True (-not [IO.File]::Exists($childPayload)) 'Importer cleans its payload after the recording shell exits'
    $metrics = & $Global:ZigstoryBin perf --cwd 'shell-exited' --format json | ConvertFrom-Json
    Assert-True ($metrics.total_commands -eq 1) 'History commits even when the recording shell exits immediately'

    $invalidPath = Join-Path $pending 'invalid.json'
    [IO.File]::WriteAllText($invalidPath, '[{"cmd":""}]')
    Start-ZigstoryRecordingImport $invalidPath
    foreach ($recording in $Global:ZigstoryRecordingProcesses) { $recording.Process.WaitForExit() }
    Complete-ZigstoryRecordings -WarningVariable failureWarning 3>$null
    Assert-True ($failureWarning.Count -gt 0) 'Background import failures notify the next prompt'
    Assert-True ([IO.File]::Exists($invalidPath) -and [IO.File]::Exists("$invalidPath.error")) 'Import failures retain the payload and diagnostic'

    $startupFailurePath = Join-Path $directory 'startup-failure.json'
    [IO.File]::WriteAllText($startupFailurePath, '[{"cmd":"retained","event_id":"startup-failure"}]')
    $blockedHome = Join-Path $directory 'blocked-home'
    New-Item -ItemType Directory -Path $blockedHome | Out-Null
    [IO.File]::WriteAllText((Join-Path $blockedHome '.zigstory'), 'not a directory')
    $env:USERPROFILE = $blockedHome
    try {
        & $Global:ZigstoryBin import --file $startupFailurePath --consume 2>&1 | Out-Null
        Assert-True ($LASTEXITCODE -ne 0) 'Database startup failures return an error'
        Assert-True ([IO.File]::Exists($startupFailurePath) -and [IO.File]::Exists("$startupFailurePath.error")) 'Database startup failures retain the payload and diagnostic'
    } finally { $env:USERPROFILE = $directory }

    Assert-True ((Get-ZigstoryExitCode $true 7 'Write-Output ok') -eq 0) 'Successful PowerShell commands ignore stale native exit codes'
    Assert-True ((Get-ZigstoryExitCode $false 7 'Write-Error failure') -eq 1) 'Failed PowerShell commands do not inherit stale native exit codes'
    Assert-True ((Get-ZigstoryExitCode $false 7 'cmd.exe /c exit 7') -eq 7) 'Simple native failures preserve their exit code'
    Assert-True ((Get-ZigstoryExitCode $false 7 'if ($true) { Write-Error failure }') -eq 1) 'Compound PowerShell failures use generic failure status'

    Set-PSReadLineOption -AddToHistoryHandler { param($line) return $false }
    Initialize-ZigstoryHistoryCapture
    $installedHandler = (Get-PSReadLineOption).AddToHistoryHandler
    Assert-True (-not $installedHandler.Invoke('Set-Location C:\elsewhere')) 'Directory capture preserves a pre-existing history filtering handler'
    Assert-True ($Global:ZigstoryAcceptedCommand.Directory -ceq $PWD.ProviderPath) 'Directory capture happens before execution changes location'
    Initialize-ZigstoryHistoryCapture
    Assert-True ([object]::ReferenceEquals($installedHandler, (Get-PSReadLineOption).AddToHistoryHandler)) 'Reinitialization does not recursively wrap the history handler'

    function Global:Get-History {
        param($Count, $ErrorAction)
        return $script:testHistory
    }
    function Global:ZigstoryRecordCommand($cmd, $cwd, $exitCode, $duration, $timestamp) {
        $script:captured = @{ cmd = $cmd; cwd = $cwd; exit_code = $exitCode; duration = $duration; timestamp = $timestamp }
    }
    $script:testHistory = [pscustomobject]@{
        Id = 42
        CommandLine = 'Set-Location C:\elsewhere'
        Duration = [TimeSpan]::FromMilliseconds(123)
        StartExecutionTime = [DateTime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
    }
    $Global:ZigstoryAcceptedCommand = [pscustomobject]@{ Command = $script:testHistory.CommandLine; Directory = 'C:\before' }
    $Global:ZigstoryPromptDirectory = 'C:\fallback'
    $global:LASTEXITCODE = 7
    $null = 'success'
    $null = Prompt
    Assert-True ($script:captured.exit_code -eq 0) 'Prompt snapshots command success before invoking helpers'
    Assert-True ($script:captured.cwd -ceq 'C:\before') 'Directory-changing commands retain their starting directory'
    Assert-True ($script:captured.timestamp -eq 1577934245) 'Prompt uses execution time rather than background import time'
    $Global:ZigstoryLastHistoryId = -1
    $script:testHistory.CommandLine = 'Write-Error failure'
    Write-Error 'expected test error' -ErrorAction Continue 2>$null
    $null = Prompt
    Assert-True ($script:captured.exit_code -eq 1) 'Prompt preserves failed PowerShell status despite a stale LASTEXITCODE'
} finally {
    Set-PSReadLineOption -AddToHistoryHandler $originalHandler
    foreach ($recording in $Global:ZigstoryRecordingProcesses) {
        if (-not $recording.Process.WaitForExit(15000)) { $recording.Process.Kill() }
        $recording.Process.Dispose()
    }
    $env:USERPROFILE = $originalHome
    $env:HOME = $originalUnixHome
    $env:APPDATA = $originalAppData
    Remove-Item -LiteralPath $directory -Recurse -Force
}
