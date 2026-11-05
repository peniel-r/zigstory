#Requires -Version 7.4
param(
    [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'),
    [switch]$LaunchAndExit,
    [string]$RecordingHome,
    [string]$Dll
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$directory = Join-Path ([IO.Path]::GetTempPath()) ("zigstory-async-recording-" + [Guid]::NewGuid().ToString('N'))
$savedHome = $env:USERPROFILE
$savedUnixHome = $env:HOME
$savedLogs = $env:ZIGSTORY_LOG_DIR
$published = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}

function Wait-Recordings {
    foreach ($item in $Global:ZigstoryRecordingProcesses) {
        if ($null -ne $item.PSObject.Properties['Operation']) {
            if (-not $item.Operation.Completion.Wait(15000)) { throw 'Worker importer did not finish in 15 seconds' }
        } elseif (-not $item.Process.WaitForExit(15000)) { throw 'Legacy importer did not finish in 15 seconds' }
    }
    Complete-ZigstoryRecordings
}

try {
    if (-not $Dll) {
        . (Join-Path $repo 'scripts\safe-upgrade.ps1')
        $published = Join-Path $directory 'published'
        Publish-ZigstoryUpgradePredictor $repo $published
        $Dll = Join-Path $published 'zigstoryPredictor.dll'
        # Load the fresh DLL in a separate shell, so it can be deleted after that
        # shell exits (Windows locks loaded assemblies).
        & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Exe $Exe -Dll $Dll
        exit $LASTEXITCODE
    }
    Add-Type -Path $Dll
    $Global:ZigstoryBin = (Resolve-Path -LiteralPath $Exe).Path
    $Global:ZigstorySessionId = [Guid]::NewGuid().ToString()
    $Global:ZigstoryRecordingProcesses = [Collections.Generic.List[object]]::new()
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\zsprofile.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    foreach ($function in $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Global:Get-ZigstoryRecordingDirectory', 'Global:Start-ZigstoryRecordingImport',
            'Global:Initialize-ZigstoryRecordingExit', 'Global:Complete-ZigstoryRecordings',
            'Global:Retry-ZigstoryPendingRecordings', 'Global:ZigstoryRecordCommand', 'Global:Write-ZigstoryLog')
    }, $true)) { Invoke-Expression $function.Extent.Text }

    if ($LaunchAndExit) {
        $env:USERPROFILE = $RecordingHome
        $env:HOME = $RecordingHome
        ZigstoryRecordCommand 'echo worker shell exited' 'worker-exited' 0 5
        Write-Output $Global:ZigstoryRecordingProcesses[0].Path
        exit 0
    }

    $testHome = Join-Path $directory "home & test's"
    $env:USERPROFILE = $testHome
    $env:HOME = $testHome
    $env:ZIGSTORY_LOG_DIR = Join-Path $testHome '.zigstory\logs'
    ZigstoryRecordCommand 'echo worker recorded' 'async' 0 3000000000 1234567890
    Assert-True ($null -ne $Global:ZigstoryRecordingProcesses[0].PSObject.Properties['Operation']) 'Profile delegates process creation to the background helper'
    Initialize-ZigstoryRecordingExit
    Assert-True (@(Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -Force).Count -eq 1) 'Exit drain registers exactly once when the profile is reinitialized'
    Wait-Recordings
    $metrics = & $Global:ZigstoryBin perf --cwd async --format json | ConvertFrom-Json
    Assert-True ($metrics.total_commands -eq 1 -and $metrics.last_duration_ms -eq 3000000000) 'Worker recording commits exact metadata'
    $pending = Get-ZigstoryRecordingDirectory
    Assert-True (@([IO.Directory]::EnumerateFiles($pending)).Count -eq 0) 'Successful workers clean payloads without another prompt'

    $validExe = $Global:ZigstoryBin
    $Global:ZigstoryBin = Join-Path $testHome 'missing.exe'
    ZigstoryRecordCommand 'echo retry worker' 'async' 7 15
    $operation = $Global:ZigstoryRecordingProcesses[0].Operation
    $payload = $Global:ZigstoryRecordingProcesses[0].Path
    Assert-True ($operation.Completion.Wait(15000)) 'Asynchronous launch failure completes'
    Assert-True ([IO.File]::Exists($payload) -and [IO.File]::Exists("$payload.error")) 'Worker launch failure persists a retryable payload and diagnostic'
    Complete-ZigstoryRecordings -WarningVariable warning 3>$null
    Assert-True ($warning.Count -gt 0 -and $Global:ZigstoryRecordingProcesses.Count -eq 0) 'Completed worker failures notify the prompt and release tracking'
    $Global:ZigstoryBin = $validExe
    Retry-ZigstoryPendingRecordings
    Wait-Recordings
    Assert-True (-not [IO.File]::Exists($payload) -and -not [IO.File]::Exists("$payload.error")) 'Worker retries consume payloads and old diagnostics'

    $invalid = Join-Path $pending 'invalid.json'
    [IO.File]::WriteAllText($invalid, '[{"cmd":"","event_id":"invalid-worker"}]')
    Start-ZigstoryRecordingImport $invalid
    $null = $Global:ZigstoryRecordingProcesses[0].Operation.Completion.Wait(15000)
    Complete-ZigstoryRecordings -WarningVariable invalidWarning 3>$null
    Assert-True ($invalidWarning.Count -gt 0 -and [IO.File]::ReadAllText("$invalid.error").Contains('EmptyCommand')) 'Worker import failures preserve the Zig importers specific diagnostic'

    # Re-sourcing a profile may leave previously launched direct Process entries.
    $legacyPath = Join-Path $pending 'legacy.json'
    [IO.File]::WriteAllText($legacyPath, '[{"cmd":"legacy launch","cwd":"mixed","event_id":"legacy-mixed"}]')
    $legacy = [Diagnostics.Process]::new()
    $legacy.StartInfo.FileName = $validExe
    $legacy.StartInfo.UseShellExecute = $false
    $legacy.StartInfo.CreateNoWindow = $true
    $legacy.StartInfo.RedirectStandardError = $true
    foreach ($arg in @('import', '--file', $legacyPath, '--consume')) { $legacy.StartInfo.ArgumentList.Add($arg) }
    $null = $legacy.Start()
    $Global:ZigstoryRecordingProcesses.Add([pscustomobject]@{ Process = $legacy; ErrorTask = $legacy.StandardError.ReadToEndAsync(); Path = $legacyPath })
    ZigstoryRecordCommand 'new worker' 'mixed' 0 1
    Wait-Recordings
    $mixed = & $validExe perf --cwd mixed --format json | ConvertFrom-Json
    Assert-True ($mixed.total_commands -eq 2 -and $Global:ZigstoryRecordingProcesses.Count -eq 0) 'Prompt completion supports mixed legacy and worker imports'

    # Measure the actual PowerShell recording helper as well as the .NET-only
    # benchmark. Serialization, payload writing and exit-drain checks are included.
    $submissionTimes = [Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt 22; $i++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        ZigstoryRecordCommand 'echo prompt submission benchmark' 'ps-submission-benchmark' 0 1
        if ($i -gt 0) { $submissionTimes.Add($clock.Elapsed.TotalMilliseconds) }
        Wait-Recordings
    }
    $sorted = @($submissionTimes | Sort-Object)
    Write-Host ('Recording helper including JSON/payload write: median {0:N3} ms; p95 {1:N3} ms (21 warm samples)' -f $sorted[10], $sorted[19])
    $submitted = & $validExe perf --cwd ps-submission-benchmark --format json | ConvertFrom-Json
    Assert-True ($submitted.total_commands -eq 22) 'Every measured submission imports one event without batching'

    # Launch and immediately exit a real independent PowerShell process. The exit
    # drain waits for process creation, but never waits for the importer to finish.
    $childPayload = & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Exe $validExe -Dll $Dll -LaunchAndExit -RecordingHome $testHome
    Assert-True ($LASTEXITCODE -eq 0) 'Recording shell exits cleanly with a pending worker launch'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([IO.File]::Exists($childPayload) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    Assert-True (-not [IO.File]::Exists($childPayload)) 'Worker-launched importer consumes its payload after the shell exits'
    $exited = & $validExe perf --cwd worker-exited --format json | ConvertFrom-Json
    Assert-True ($exited.total_commands -eq 1) 'Normal exit drain preserves the launched recording'
} finally {
    # The exit-only child must rely on the actual PowerShell.Exiting drain, not
    # this test cleanup (which intentionally waits for complete imports).
    if (-not $LaunchAndExit) {
        if ('zigstoryPredictor.RecordingImporter' -as [type]) { $null = [zigstoryPredictor.RecordingImporter]::WaitForPendingLaunches(15000) }
        if (Get-Variable -Name ZigstoryRecordingProcesses -Scope Global -ErrorAction SilentlyContinue) {
            foreach ($item in $Global:ZigstoryRecordingProcesses) {
                if ($null -ne $item.PSObject.Properties['Operation']) { $null = $item.Operation.Completion.Wait(15000) }
                else { $null = $item.Process.WaitForExit(15000); $item.Process.Dispose() }
            }
        }
        $subscription = Get-Variable -Name ZigstoryRecordingExitSubscription -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $subscription) {
            Unregister-Event -SubscriptionId $subscription -Force -ErrorAction SilentlyContinue
        }
        $env:USERPROFILE = $savedHome
        $env:HOME = $savedUnixHome
        $env:ZIGSTORY_LOG_DIR = $savedLogs
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}
