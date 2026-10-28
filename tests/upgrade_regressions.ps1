#Requires -Version 7.0
param([string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$directory = Join-Path ([IO.Path]::GetTempPath()) "zigstory upgrade & test's_$([Guid]::NewGuid().ToString('N'))"
$publishedFixture = Join-Path ([IO.Path]::GetTempPath()) "zigstory-upgrade-published-$([Guid]::NewGuid().ToString('N'))"
$originalHome = $env:USERPROFILE
$originalUnixHome = $env:HOME
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\safe-upgrade.ps1')
. (Join-Path $repo 'scripts\release.ps1') -Version '0.0.0-test'
$realPublish = ${function:Publish-ZigstoryUpgradePredictor}
$realPredictorValidation = ${function:Test-ZigstoryUpgradePredictor}

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
    if ($Installed -and $script:mode -in @('fail-validation', 'rollback-blocked', 'no-predictor-failure')) {
        [IO.File]::WriteAllText((Join-Path $script:history 'history.db-wal'), 'failed upgrade WAL')
        $script:validationFailed = $true
        throw 'simulated post-migration failure'
    }
}
function Publish-ZigstoryUpgradePredictor {
    param($RepositoryRoot, $Destination)
    $script:lastStage = $Destination
    if ($script:mode -eq 'fail-publish') { throw 'simulated predictor publish failure' }
    foreach ($item in Get-ChildItem -LiteralPath $script:published -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
    if ($script:mode -eq 'fail-stage-validation') {
        [IO.File]::WriteAllText((Join-Path $Destination 'zigstoryPredictor.dll'), 'invalid assembly')
    }
}
function Test-ZigstoryUpgradePredictor {
    param($Directory)
    & $script:realPredictorValidation $Directory
    if ($script:mode -in @('fail-predictor-validation', 'fail-predictor-restore') -and $Directory -eq $script:predictor) {
        throw 'simulated installed predictor validation failure'
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
    if ($script:mode -eq 'fail-predictor-copy' -and $Destination -eq $script:predictor -and
        (Split-Path $LiteralPath -Leaf) -ne 'predictor') {
        $null = New-Item -ItemType Directory -Path $Destination
        [IO.File]::WriteAllText((Join-Path $Destination 'partial.dll'), 'partial replacement')
        throw 'simulated predictor replacement failure'
    }
    if ($script:mode -eq 'fail-predictor-restore' -and $Destination -eq $script:predictor -and
        (Split-Path $LiteralPath -Leaf) -eq 'predictor') {
        throw 'simulated locked predictor during rollback'
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}

try {
    $null = New-Item -ItemType Directory -Path $directory
    $script:mode = 'success'
    $script:published = $publishedFixture
    & $realPublish $repo $script:published
    & $realPredictorValidation $script:published
    Assert-True $true 'Fresh publish loads and registers predictor with working native SQLite in a clean process'
    $sourceRepo = Join-Path $directory 'repository'
    $null = New-Item -ItemType Directory -Path (Join-Path $sourceRepo 'zig-out\bin'), (Join-Path $sourceRepo 'scripts')
    $script:mode = 'success'
    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $Exe).Path -Destination (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe')
    $script:sourceProfile = Join-Path $sourceRepo 'scripts\zsprofile.ps1'
    Copy-Item -LiteralPath (Join-Path $repo 'scripts\zsprofile.ps1') -Destination $script:sourceProfile
    foreach ($case in @('success', 'no-predictor', 'no-predictor-failure', 'fail-publish', 'fail-stage-validation', 'fail-predictor-copy', 'fail-predictor-validation', 'fail-predictor-restore', 'fail-backup', 'fail-copy', 'fail-validation', 'bad-database', 'no-history', 'blocked', 'rollback-blocked', 'fail-restore')) {
        $script:mode = $case
        $script:validationFailed = $false
        $script:lastStage = $null
        $homeDirectory = Join-Path $directory $case
        $env:USERPROFILE = $homeDirectory
        $env:HOME = $homeDirectory
        $exePath = Join-Path $homeDirectory 'installed\zigstory.exe'
        $script:profile = Join-Path $homeDirectory 'profile\zsprofile.ps1'
        $script:history = Join-Path $homeDirectory '.zigstory'
        $script:predictor = Join-Path $homeDirectory 'modules\zigstoryPredictor'
        $backups = Join-Path $homeDirectory 'backups'
        $null = New-Item -ItemType Directory -Path (Split-Path $exePath), (Split-Path $script:profile)
        [IO.File]::WriteAllText($exePath, 'old executable')
        [IO.File]::WriteAllText($script:profile, '# old profile')
        if ($case -notin @('no-predictor', 'no-predictor-failure')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:predictor 'runtimes\win-x64\native')
            [IO.File]::WriteAllText((Join-Path $script:predictor 'zigstoryPredictor.dll'), 'old predictor')
            [IO.File]::WriteAllText((Join-Path $script:predictor 'obsolete.dll'), 'obsolete dependency')
            [IO.File]::WriteAllText((Join-Path $script:predictor 'runtimes\win-x64\native\e_sqlite3.dll'), 'old native dependency')
        }
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
            PredictorDirectory = $script:predictor
        }
        if ($case -in @('success', 'no-predictor')) {
            Invoke-ZigstorySafeUpgrade @arguments
            Assert-True ((Get-FileHash $exePath).Hash -eq (Get-FileHash (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe')).Hash) 'Success installs the new executable'
            Assert-True ((Get-FileHash $script:profile).Hash -eq (Get-FileHash $script:sourceProfile).Hash) 'Success installs the matching profile'
            Assert-True ((Get-FileHash (Join-Path $script:predictor 'zigstoryPredictor.dll')).Hash -eq
                (Get-FileHash (Join-Path $script:published 'zigstoryPredictor.dll')).Hash) 'Success installs the published predictor'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:predictor 'obsolete.dll'))) 'Replacement removes stale predictor dependencies'
            if ($case -eq 'success') {
                Assert-True ([IO.File]::ReadAllText((Join-Path (@(Get-ChildItem -LiteralPath $backups -Directory)[0].FullName) 'predictor\obsolete.dll')) -eq 'obsolete dependency') 'Backup preserves the entire previous predictor directory'
            }
            $archive = @(Get-ChildItem -LiteralPath $backups -Directory)[0].FullName
            Assert-True ([IO.File]::ReadAllText((Join-Path $archive 'zigstory.exe')) -eq 'old executable') 'Backup preserves the previous executable'
            Assert-True ([IO.File]::ReadAllText((Join-Path $archive 'history\pending\retained.json')) -eq 'private pending payload') 'Backup includes nested pending history payloads'
            Assert-True ((Get-FileHash (Join-Path $archive 'history\history.db')).Hash -eq $dbHash) 'Backup preserves database bytes before validation'
        } elseif ($case -in @('fail-backup', 'fail-publish', 'fail-stage-validation')) {
            $pattern = switch ($case) {
                'fail-backup' { 'simulated backup copy failure' }
                'fail-publish' { 'simulated predictor publish failure' }
                'fail-stage-validation' { 'Predictor validation failed' }
            }
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } $pattern
            Assert-True ([IO.File]::ReadAllText($exePath) -eq 'old executable') 'Failed backup leaves the installed executable untouched'
            Assert-True ([IO.File]::ReadAllText($script:profile) -eq '# old profile') 'Failed backup leaves the installed profile untouched'
            Assert-True ((Get-FileHash (Join-Path $script:history 'history.db')).Hash -eq $dbHash) 'Failed backup leaves history untouched'
            Assert-True ([IO.File]::ReadAllText((Join-Path $script:predictor 'zigstoryPredictor.dll')) -eq 'old predictor') 'Pre-install failure leaves predictor untouched'
            if ($case -in @('fail-publish', 'fail-stage-validation')) {
                Assert-True (-not (Test-Path -LiteralPath $backups)) 'Publish failure makes no installation backups or changes'
            }
        } elseif ($case -eq 'blocked') {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'simulated active shell'
            Assert-True (-not (Test-Path -LiteralPath $backups)) 'Busy-shell refusal makes no backups or installation changes'
        } elseif ($case -eq 'rollback-blocked') {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'ROLLBACK BLOCKED'
            Assert-True ((Get-FileHash $exePath).Hash -eq (Get-FileHash (Join-Path $sourceRepo 'zig-out\bin\zigstory.exe')).Hash) 'Blocked rollback does not pair an old executable with a live upgraded database'
        } elseif ($case -in @('fail-restore', 'fail-predictor-restore')) {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'ROLLBACK INCOMPLETE'
        } else {
            Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'Rollback completed'
            Assert-True ([IO.File]::ReadAllText($exePath) -eq 'old executable') "$case restores the original executable"
            Assert-True ([IO.File]::ReadAllText($script:profile) -eq '# old profile') "$case restores the original profile"
            if ($case -eq 'no-predictor-failure') {
                Assert-True (-not (Test-Path -LiteralPath $script:predictor)) 'Rollback preserves absence of an original predictor'
            } else {
                Assert-True ([IO.File]::ReadAllText((Join-Path $script:predictor 'zigstoryPredictor.dll')) -eq 'old predictor') "$case restores the original predictor"
                Assert-True ([IO.File]::ReadAllText((Join-Path $script:predictor 'runtimes\win-x64\native\e_sqlite3.dll')) -eq 'old native dependency') "$case restores nested predictor dependencies"
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:predictor 'Microsoft.Data.Sqlite.dll'))) "$case removes new predictor files during rollback"
            }
            if ($case -eq 'no-history') {
                Assert-True (-not (Test-Path -LiteralPath $script:history)) 'Rollback preserves absence of an original history directory'
            } else {
                Assert-True ((Get-FileHash (Join-Path $script:history 'history.db')).Hash -eq $dbHash) "$case restores exact database bytes"
                Assert-True ([IO.File]::Exists((Join-Path $script:history 'pending\retained.json'))) "$case restores pending recordings"
                Assert-True (-not [IO.File]::Exists((Join-Path $script:history 'history.db-wal'))) "$case does not mix failed-upgrade WAL with restored database"
            }
        }
        if ($case -notin @('blocked', 'fail-backup', 'fail-publish', 'fail-stage-validation')) {
            $archive = @(Get-ChildItem -LiteralPath $backups -Directory)[0].FullName
            Assert-True ([IO.File]::Exists((Join-Path $archive 'result.txt'))) "$case retains a persistent upgrade result"
            $manifest = Get-Content -LiteralPath (Join-Path $archive 'manifest.json') -Raw | ConvertFrom-Json
            Assert-True ($manifest.predictor -eq $script:predictor) "$case records predictor recovery destinations"
            if ($case -in @('success', 'no-predictor')) {
                Assert-True (-not (Test-Path -LiteralPath $manifest.previous_predictor)) 'Successful upgrade cleans the displaced predictor directory'
            }
            if ($case -in @('fail-validation', 'no-history')) {
                $manifest = Get-Content -LiteralPath (Join-Path $archive 'manifest.json') -Raw | ConvertFrom-Json
                Assert-True ([IO.File]::Exists((Join-Path $manifest.failed_history 'history.db-wal'))) "$case preserves failed-upgrade files separately for recovery"
            }
        }
        if ($null -ne $script:lastStage) {
            Assert-True (-not (Test-Path -LiteralPath $script:lastStage)) "$case cleans temporary publish staging"
        }
    }
    $script:mode = 'success'
    $arguments.BackupRoot = Join-Path $script:history 'unsafe-backups'
    Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'BackupRoot must be outside'
    $arguments.BackupRoot = Join-Path $script:predictor 'unsafe-backups'
    Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'BackupRoot must be outside'
    $arguments.BackupRoot = Join-Path $directory 'preflight-backups'
    [IO.File]::WriteAllText($script:sourceProfile, 'function broken {')
    Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'Profile syntax validation failed'
    Assert-True (-not (Test-Path -LiteralPath $arguments.BackupRoot)) 'Invalid source profile fails before any backup or installation changes'

    $script:mode = 'success'
    $archive = New-ZigstoryReleaseBundle $repo $script:published (Join-Path $directory 'releases') '0.0.0-test'
    Assert-True ((Get-Content -LiteralPath "$archive.sha256" -Raw).StartsWith((Get-FileHash -LiteralPath $archive).Hash)) 'Release ZIP has a matching SHA256 sidecar'
    Assert-Throws { New-ZigstoryReleaseBundle $repo $script:published (Split-Path $archive) '0.0.0-test' } 'already exists'
    $bundle = Join-Path $directory 'extracted release'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $bundle)
    Test-ZigstoryReleaseBundle $bundle
    $unexpected = Join-Path $bundle 'unexpected.txt'
    [IO.File]::WriteAllText($unexpected, 'unexpected release file')
    Assert-Throws { Test-ZigstoryReleaseBundle $bundle } 'Unlisted file'
    Remove-Item -LiteralPath $unexpected
    $releaseManifest = Join-Path $bundle 'release-manifest.json'
    $originalManifest = [IO.File]::ReadAllText($releaseManifest)
    $invalidManifest = $originalManifest | ConvertFrom-Json
    $invalidManifest.files[0].path = '..\outside.dll'
    $invalidManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $releaseManifest
    Assert-Throws { Test-ZigstoryReleaseBundle $bundle } 'Invalid or duplicate'
    [IO.File]::WriteAllText($releaseManifest, $originalManifest)
    $arguments.PackageDirectory = $bundle
    $arguments.BackupRoot = Join-Path $directory 'bundle-upgrade-backups'
    $script:mode = 'fail-publish'
    Invoke-ZigstorySafeUpgrade @arguments
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $script:predictor 'zigstoryPredictor.dll')).Hash -eq
        (Get-FileHash -LiteralPath (Join-Path $bundle 'predictor\zigstoryPredictor.dll')).Hash) 'Prebuilt release upgrades without invoking dotnet publish'
    [IO.File]::AppendAllText((Join-Path $bundle 'scripts\zsprofile.ps1'), '# tampered')
    Assert-Throws { Invoke-ZigstorySafeUpgrade @arguments } 'checksum mismatch'
    Assert-True (@(Get-ChildItem -LiteralPath $arguments.BackupRoot -Directory).Count -eq 1) 'Tampered release fails before making another backup'
} finally {
    $env:USERPROFILE = $originalHome
    $env:HOME = $originalUnixHome
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    if (Test-Path -LiteralPath $publishedFixture) { Remove-Item -LiteralPath $publishedFixture -Recurse -Force }
}
