#Requires -Version 7.4
param(
    [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'),
    [string]$LegacyRevision = 'cb51319'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $env:LOCALAPPDATA ("Temp\opencode\schema-upgrade-" + [Guid]::NewGuid().ToString('N'))
$savedHome = $env:USERPROFILE
$savedUnixHome = $env:HOME
. (Join-Path $repo 'scripts\safe-upgrade.ps1')
$realValidation = ${function:Test-ZigstoryUpgradeExecutable}
$realPublish = ${function:Publish-ZigstoryUpgradePredictor}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}

function Legacy-Record([string]$HomeDirectory) {
    $result = Invoke-ZigstoryUpgradeCommand $script:oldExe @('add', '--cmd', 'echo before upgrade', '--cwd', 'legacy') -Environment @{
        USERPROFILE = $HomeDirectory; HOME = $HomeDirectory; ZIGSTORY_LOG_LEVEL = 'Off'
    }
    Assert-True ($result.ExitCode -eq 0) 'Real legacy binary creates a schema-2 recording'
}

try {
    $null = New-Item -ItemType Directory -Path $directory
    $archive = Join-Path $directory 'legacy.zip'
    $source = Join-Path $directory 'legacy-source'
    & git -C $repo archive --format=zip "--output=$archive" $LegacyRevision
    if ($LASTEXITCODE -ne 0) { throw 'Could not archive the known schema-2 revision.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $source
    # Dependencies are copied, never changed/discarded in the working repository.
    Copy-Item -LiteralPath (Join-Path $repo 'zig-pkg') -Destination (Join-Path $source 'zig-pkg') -Recurse
    Push-Location $source
    try {
        & zig build -Doptimize=ReleaseFast
        if ($LASTEXITCODE -ne 0) { throw 'Legacy CLI build failed.' }
    } finally { Pop-Location }
    $script:oldExe = Join-Path $source 'zig-out\bin\zigstory.exe'
    $published = Join-Path $directory 'published'
    & $realPublish $repo $published
    function Publish-ZigstoryUpgradePredictor {
        param($RepositoryRoot, $Destination)
        foreach ($item in Get-ChildItem -LiteralPath $script:published -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
        }
    }
    function Assert-ZigstoryUpgradeIdle { } # Only isolated fixture paths below are ever upgraded.
    function Test-ZigstoryUpgradeExecutable {
        param([string]$Path, [switch]$Installed)
        & $script:realValidation $Path -Installed:$Installed
        if ($Installed -and $script:forceFailure) { throw 'injected failure after real schema-3 migration' }
    }
    foreach ($mode in @('success', 'rollback')) {
        $testHome = Join-Path $directory $mode
        $null = New-Item -ItemType Directory -Path $testHome
        Legacy-Record $testHome
        Legacy-Record $testHome
        $historyDirectory = Join-Path $testHome '.zigstory'
        $originalHash = (Get-FileHash -LiteralPath (Join-Path $historyDirectory 'history.db')).Hash
        $install = Join-Path $testHome 'installation'
        $null = New-Item -ItemType Directory -Path $install
        $installedExe = Join-Path $install 'zigstory.exe'
        $hook = Join-Path $install 'zsprofile.ps1'
        Copy-Item -LiteralPath $script:oldExe -Destination $installedExe
        Copy-Item -LiteralPath (Join-Path $source 'scripts\zsprofile.ps1') -Destination $hook
        $env:USERPROFILE = $testHome
        $env:HOME = $testHome
        $script:forceFailure = $mode -eq 'rollback'
        $failed = $null
        try {
            Invoke-ZigstorySafeUpgrade -RepositoryRoot $repo -InstallExe $installedExe -ProfileScript $hook `
                -HistoryDirectory $historyDirectory -BackupRoot (Join-Path $testHome 'backups') `
                -PredictorDirectory (Join-Path $testHome 'module')
        } catch { $failed = $_ }
        if ($mode -eq 'success') {
            if ($null -ne $failed) { throw $failed }
            $oldRead = Invoke-ZigstoryUpgradeCommand $script:oldExe @('perf', '--cwd', 'legacy', '--format', 'json')
            Assert-True ($oldRead.ExitCode -ne 0 -and $oldRead.ErrorOutput.Contains('UnsupportedSchemaVersion')) 'Actual schema-2 binary refuses the migrated database instead of downgrading it'
            $newRead = Invoke-ZigstoryUpgradeCommand $installedExe @('perf', '--cwd', 'legacy', '--format', 'json')
            Assert-True ($newRead.ExitCode -eq 0 -and ($newRead.Output | ConvertFrom-Json).total_commands -eq 2) 'Successful real migration preserves both executions and current CLI reads'
        } else {
            Assert-True ($null -ne $failed -and $failed.Exception.Message.Contains('Rollback completed')) 'Failure after actual schema-3 migration completes rollback'
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $historyDirectory 'history.db')).Hash -eq $originalHash) 'Rollback restores byte-identical schema-2 database data'
            Assert-True ((Get-FileHash -LiteralPath $installedExe).Hash -eq (Get-FileHash -LiteralPath $script:oldExe).Hash) 'Rollback restores the real legacy executable'
            $restored = Invoke-ZigstoryUpgradeCommand $installedExe @('perf', '--cwd', 'legacy', '--format', 'json')
            Assert-True ($restored.ExitCode -eq 0 -and ($restored.Output | ConvertFrom-Json).total_commands -eq 2) 'Restored legacy binary reads the restored schema-2 database'
        }
    }
} finally {
    $env:USERPROFILE = $savedHome
    $env:HOME = $savedUnixHome
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
