#Requires -Version 7.0
param([string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$directory = Join-Path ([IO.Path]::GetTempPath()) "zigstory upgrade & test's_$([Guid]::NewGuid().ToString('N'))"
$originalHome = $env:USERPROFILE
$originalUnixHome = $env:HOME
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\safe-upgrade.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-True ($null -ne $failure -and $failure.Exception.Message -match $Pattern) "Error reports $Pattern"
}

# Verify the real process guard with a deterministic process inventory.
function Get-CimInstance {
    param($ClassName)
    return $script:inventory
}
function Invoke-CimMethod {
    param($InputObject, $MethodName)
    return @{ ReturnValue = 0; Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
}
$script:inventory = @(
    [pscustomobject]@{ Name = 'pwsh.exe'; ProcessId = $PID; ParentProcessId = 987654; CommandLine = 'pwsh -NoProfile' },
    [pscustomobject]@{ Name = 'pwsh.exe'; ProcessId = 987654; ParentProcessId = 0; CommandLine = 'pwsh -NoProfile' }
)
Assert-ZigstoryUpgradeIdle
Assert-True $true 'Idle guard permits the NoProfile invocation chain'
$script:inventory[1].CommandLine = 'pwsh'
Assert-Throws { Assert-ZigstoryUpgradeIdle } 'Close process'
$script:inventory[1].CommandLine = 'pwsh -NoProfile'
$script:inventory += [pscustomobject]@{ Name = 'zigstory.exe'; ProcessId = 987653; ParentProcessId = 0; CommandLine = 'zigstory import' }
Assert-Throws { Assert-ZigstoryUpgradeIdle } 'Close process'
Remove-Item Function:\Get-CimInstance, Function:\Invoke-CimMethod

# Only the process inventory is bypassed for these isolated test installations.
function Assert-ZigstoryUpgradeIdle {
    if ($script:mode -eq 'blocked') { throw 'simulated active shell' }
    if ($script:mode -eq 'rollback-blocked' -and $script:validationFailed) {
        throw 'simulated newly opened shell'
    }
}
$realValidation = ${function:Test-ZigstoryUpgradeExecutable}
function Test-ZigstoryUpgradeExecutable {
    param([string]$Path, [switch]$Installed)
    & $script:realValidation $Path -Installed:$Installed
    if ($Installed -and $script:mode -in @('fail-validation', 'rollback-blocked')) {
        [IO.File]::WriteAllText((Join-Path $script:history 'history.db-wal'), 'failed upgrade WAL')
        $script:validationFailed = $true
        throw 'simulated post-migration failure'
    }
}
function Copy-Item {
    param($LiteralPath, $Destination, [switch]$Force, [switch]$Recurse)
    if ($script:mode -eq 'fail-backup' -and $LiteralPath -eq $script:history) {
        throw 'simulated backup copy failure'
    }
    if ($script:mode -eq 'fail-copy' -and $LiteralPath -eq $script:sourceProfile -and $Destination -eq $script:profile) {
        throw 'simulated profile replacement failure'
    }
    if ($script:mode -eq 'fail-restore' -and $LiteralPath -eq $script:sourceProfile -and $Destination -eq $script:profile) {
        throw 'simulated profile replacement failure'
    }
    if ($script:mode -eq 'fail-restore' -and (Split-Path $LiteralPath -Leaf) -eq 'zigstory.exe' -and
        $LiteralPath -like '*upgrade-*\zigstory.exe') {
        throw 'simulated locked executable during rollback'
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}

try {
    $null = New-Item -ItemType Directory -Path $directory
    $sourceRepo = Join-Path $directory 'repository'
    $null = New-Item -ItemType Directory -Path (Join-Path $sourceRepo 'zig-out\bin'), (Join-Path $sourceRepo 'scripts')
    $script:mode = 'success'
    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $Exe).Path -Destination (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe')
    $script:sourceProfile = Join-Path $sourceRepo 'scripts\zsprofile.ps1'
    Copy-Item -LiteralPath (Join-Path $repo 'scripts\zsprofile.ps1') -Destination $script:sourceProfile
    foreach ($case in @('success', 'fail-backup', 'fail-copy', 'fail-validation', 'bad-database', 'no-history', 'blocked', 'rollback-blocked', 'fail-restore')) {
        $script:mode = $case
        $script:validationFailed = $false
        $homeDirectory = Join-Path $directory $case
        $env:USERPROFILE = $homeDirectory
        $env:HOME = $homeDirectory
        $exePath = Join-Path $homeDirectory 'installed\zigstory.exe'
        $script:profile = Join-Path $homeDirectory 'profile\zsprofile.ps1'
        $script:history = Join-Path $homeDirectory '.zigstory'
        $backups = Join-Path $homeDirectory 'backups'
        $null = New-Item -ItemType Directory -Path (Split-Path $exePath), (Split-Path $script:profile)
        [IO.File]::WriteAllText($exePath, 'old executable')
        [IO.File]::WriteAllText($script:profile, '# old profile')
        if ($case -ne 'no-history') {
            $null = Invoke-ZigstoryUpgradeCommand (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe') @('list', '0')
            $null = New-Item -ItemType Directory -Path (Join-Path $script:history 'pending')
            [IO.File]::WriteAllText((Join-Path $script:history 'pending\retained.json'), 'private pending payload')
            if ($case -eq 'bad-database') {
                [IO.File]::WriteAllText((Join-Path $script:history 'history.db'), 'invalid database')
            }
            $dbHash = (Get-FileHash -LiteralPath (Join-Path $script:history 'history.db')).Hash
        } else {
            $script:mode = 'fail-validation'
        }
        $arguments = @{
            RepositoryRoot = $sourceRepo
            InstallExe = $exePath
            ProfileScript = $script:profile
            HistoryDirectory = $script:history
            BackupRoot = $backups
        }
        if ($case -eq 'success') {
            Invoke-ZigstorySafeUpgrade @arguments
            Assert-True ((Get-FileHash $exePath).Hash -eq (Get-FileHash (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe')).Hash) 'Success installs the new executable'
            Assert-True ((Get-FileHash $script:profile).Hash -eq (Get-FileHash $script:sourceProfile).Hash) 'Success installs the matching profile'
            $archive = @(Get-ChildItem -LiteralPath $backups -Directory)[0].FullName
            Assert-True ([IO.File]::ReadAllText((Join-Path $archive 'zigstory.exe')) -eq 'old executable') 'Backup preserves the previous executable'
            Assert-True ([IO.File]::ReadAllText((Join-Path $archive 'history\pending\retained.json')) -eq 'private pending payload') 'Backup includes nested pending history payloads'
            Assert-True ((Get-FileHash (Join-Path $archive 'history\history.db')).Hash -eq $dbHash) 'Backup preserves database bytes before validation'
        } elseif ($case -eq 'fail-backup') {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'simulated backup copy failure'
            Assert-True ([IO.File]::ReadAllText($exePath) -eq 'old executable') 'Failed backup leaves the installed executable untouched'
            Assert-True ([IO.File]::ReadAllText($script:profile) -eq '# old profile') 'Failed backup leaves the installed profile untouched'
            Assert-True ((Get-FileHash (Join-Path $script:history 'history.db')).Hash -eq $dbHash) 'Failed backup leaves history untouched'
        } elseif ($case -eq 'blocked') {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'simulated active shell'
            Assert-True (-not (Test-Path -LiteralPath $backups)) 'Busy-shell refusal makes no backups or installation changes'
        } elseif ($case -eq 'rollback-blocked') {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'ROLLBACK BLOCKED'
            Assert-True ((Get-FileHash $exePath).Hash -eq (Get-FileHash (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe')).Hash) 'Blocked rollback does not pair an old executable with a live upgraded database'
        } elseif ($case -eq 'fail-restore') {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'ROLLBACK INCOMPLETE'
        } else {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'Rollback completed'
            Assert-True ([IO.File]::ReadAllText($exePath) -eq 'old executable') "$case restores the original executable"
            Assert-True ([IO.File]::ReadAllText($script:profile) -eq '# old profile') "$case restores the original profile"
            if ($case -eq 'no-history') {
                Assert-True (-not (Test-Path -LiteralPath $script:history)) 'Rollback preserves absence of an original history directory'
            } else {
                Assert-True ((Get-FileHash (Join-Path $script:history 'history.db')).Hash -eq $dbHash) "$case restores exact database bytes"
                Assert-True ([IO.File]::Exists((Join-Path $script:history 'pending\retained.json'))) "$case restores pending recordings"
                Assert-True (-not [IO.File]::Exists((Join-Path $script:history 'history.db-wal'))) "$case does not mix failed-upgrade WAL with restored database"
            }
        }
        if ($case -notin @('blocked', 'fail-backup')) {
            $archive = @(Get-ChildItem -LiteralPath $backups -Directory)[0].FullName
            Assert-True ([IO.File]::Exists((Join-Path $archive 'result.txt'))) "$case retains a persistent upgrade result"
            if ($case -in @('fail-validation', 'no-history')) {
                $manifest = Get-Content -LiteralPath (Join-Path $archive 'manifest.json') -Raw | ConvertFrom-Json
                Assert-True ([IO.File]::Exists((Join-Path $manifest.failed_history 'history.db-wal'))) "$case preserves failed-upgrade files separately for recovery"
            }
        }
    }
    $script:mode = 'success'
    $arguments.BackupRoot = Join-Path $script:history 'unsafe-backups'
    Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'BackupRoot must be outside'
    $arguments.BackupRoot = Join-Path $directory 'preflight-backups'
    [IO.File]::WriteAllText($script:sourceProfile, 'function broken {')
    Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'Profile syntax validation failed'
    Assert-True (-not (Test-Path -LiteralPath $arguments.BackupRoot)) 'Invalid source profile fails before any backup or installation changes'
} finally {
    $env:USERPROFILE = $originalHome
    $env:HOME = $originalUnixHome
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
