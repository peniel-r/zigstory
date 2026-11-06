#Requires -Version 7.4
param([string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory-catalog-benchmark.exe'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\safe-upgrade.ps1')
$directory = Join-Path $env:LOCALAPPDATA ("Temp\opencode\catalog-regressions-" + [Guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}
try {
    $null = New-Item -ItemType Directory -Path $directory
    $existing = Join-Path $directory 'existing.db'
    [IO.File]::WriteAllText($existing, 'do not alter existing input')
    $refusal = Invoke-ZigstoryUpgradeCommand $Exe @('--disk-fixture', $existing)
    Assert-True ($refusal.ExitCode -ne 0 -and [IO.File]::ReadAllText($existing) -ceq 'do not alter existing input') 'Prototype refuses existing database paths without changing or deleting them'
    $fixture = Join-Path $directory "new fixture & test's.db"
    $result = Invoke-ZigstoryUpgradeCommand $Exe @('--disk-fixture', $fixture) -TimeoutSeconds 120
    Assert-True ($result.ExitCode -eq 0) 'File-backed synthetic catalog migration and comparisons succeed'
    if ($result.ExitCode -ne 0) { throw $result.ErrorOutput }
    $report = $result.Output | ConvertFrom-Json
    Assert-True ($report.history_events -eq 100000 -and $report.distinct_commands -eq 25000 -and $report.cases.Count -eq 5) 'Catalog benchmark verifies counts and first/deep-page identities against production'
    Assert-True ($report.prototype_used_bytes -lt $report.baseline_used_bytes) 'Normalized synthetic storage uses fewer pages'
    Assert-True ($report.sqlite_peak_bytes -lt 64MB) 'File-backed prototype SQLite peak stays below 64 MiB'
    Assert-True (-not (Test-Path -LiteralPath $fixture) -and -not (Test-Path -LiteralPath "$fixture-wal") -and -not (Test-Path -LiteralPath "$fixture-shm")) 'Prototype cleans its newly created database and WAL companions'
    Write-Host ('Catalog fixture: migration {0:N1} ms; used storage {1:N1} -> {2:N1} MiB' -f $report.migration_ms, ($report.baseline_used_bytes/1MB), ($report.prototype_used_bytes/1MB))
    $wide = Join-Path $directory 'mostly-unique-long-paths.db'
    $wideResult = Invoke-ZigstoryUpgradeCommand $Exe @('--disk-fixture', $wide, '--mostly-unique', '--long-directories') -TimeoutSeconds 120
    Assert-True ($wideResult.ExitCode -eq 0) 'Mostly-unique long-directory fixture preserves search results'
    $wideReport = $wideResult.Output | ConvertFrom-Json
    Assert-True ($wideReport.distinct_commands -eq 100000 -and $wideReport.prototype_used_bytes -lt $wideReport.baseline_used_bytes) 'Directory normalization avoids storage growth for mostly-unique commands with long paths'
    Assert-True (-not (Test-Path -LiteralPath $wide)) 'Wide catalog fixture is removed after benchmarking'
    Write-Host ('Wide fixture: used storage {0:N1} -> {1:N1} MiB' -f ($wideReport.baseline_used_bytes/1MB), ($wideReport.prototype_used_bytes/1MB))
} finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
