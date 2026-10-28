#Requires -Version 7.4
param(
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.zigstory-backups'),
    [string]$PackageDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ZigstoryUpgradeIdle {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $processes = @(Get-CimInstance Win32_Process)
    $ancestors = [Collections.Generic.HashSet[int]]::new()
    $parentId = $PID
    while ($ancestors.Add($parentId)) {
        $parent = $processes | Where-Object ProcessId -eq $parentId | Select-Object -First 1
        if ($null -eq $parent) { break }
        $parentId = [int]$parent.ParentProcessId
    }
    foreach ($process in $processes) {
        if ($process.Name -notmatch '^(pwsh|powershell|zigstory|zigstory-tui-profile|zigstory-startup-profile|zigstory-startup-probe|zigstory-search-benchmark)\.exe$' -or
            $process.ProcessId -eq $PID) { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0) {
            throw "Cannot verify ownership of process $($process.ProcessId). Retry after it exits."
        }
        if ($owner.Sid -ne $currentSid) { continue }
        if ($process.Name -match '^(pwsh|powershell)\.exe$' -and
            $ancestors.Contains([int]$process.ProcessId) -and
            $process.CommandLine -match '(?i)(?:^|\s)-(?:NoProfile|nop)(?:\s|$)') { continue }
        throw "Close process $($process.ProcessId) ($($process.Name)) before upgrading. Run just safe-upgrade from pwsh -NoProfile."
    }
}

function Invoke-ZigstoryUpgradeCommand([string]$Path, [string[]]$Arguments, [int]$TimeoutSeconds = 30, [hashtable]$Environment = @{}) {
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo.FileName = $Path
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
        foreach ($name in $Environment.Keys) { $process.StartInfo.Environment[$name] = $Environment[$name] }
        if (-not $process.Start()) { throw "Failed to start $Path" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Command timed out after $TimeoutSeconds seconds: $Path"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.GetAwaiter().GetResult()
            ErrorOutput = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Publish-ZigstoryUpgradePredictor([string]$RepositoryRoot, [string]$Destination) {
    $dotnet = Join-Path $env:USERPROFILE 'scoop\apps\dotnet-sdk\current\dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
        $dotnet = (Get-Command dotnet.exe -ErrorAction Stop).Source
    }
    $root = Split-Path $dotnet
    $result = Invoke-ZigstoryUpgradeCommand $dotnet @(
        'publish', (Join-Path $RepositoryRoot 'src\predictor\zigstoryPredictor.csproj'),
        '-c', 'Release', '-r', 'win-x64', '--self-contained', 'false', '-o', $Destination
    ) -TimeoutSeconds 180 -Environment @{ DOTNET_ROOT = $root; DOTNET_ROOT_X64 = $root }
    if ($result.ExitCode -ne 0) { throw "Predictor publish failed:`n$($result.Output)`n$($result.ErrorOutput)" }
    foreach ($name in @('zigstoryPredictor.dll', 'Microsoft.Data.Sqlite.dll', 'e_sqlite3.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $name) -PathType Leaf)) {
            throw "Predictor publish is missing required file: $name"
        }
    }
}

function Test-ZigstoryUpgradePredictor([string]$Directory) {
    $dll = (Join-Path $Directory 'zigstoryPredictor.dll').Replace("'", "''")
    $script = @"
`$ErrorActionPreference = 'Stop'
Add-Type -Path '$dll'
`$predictor = [zigstoryPredictor.ZigstoryPredictor]::new()
try {
    `$connection = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=:memory:')
    try {
        `$connection.Open()
        `$command = `$connection.CreateCommand()
        try {
            `$command.CommandText = 'SELECT 1'
            if (`$command.ExecuteScalar() -ne 1) { throw 'SQLite smoke test failed.' }
        } finally { `$command.Dispose() }
    } finally { `$connection.Dispose() }
    [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
        [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor, `$predictor)
} finally { `$predictor.Dispose() }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $result = Invoke-ZigstoryUpgradeCommand (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
    if ($result.ExitCode -ne 0) { throw "Predictor validation failed: $($result.ErrorOutput)" }
}

function Test-ZigstoryReleaseBundle([string]$Directory) {
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $manifestPath = Join-Path $root 'release-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.platform -ne 'win-x64' -or
        $manifest.version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
        throw 'Unsupported release manifest.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest.files) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $entry.path))
        if (-not $path.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase) -or
            -not $seen.Add($path) -or $entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Invalid or duplicate release manifest path/hash.'
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Release checksum mismatch: $($entry.path)"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force) {
        if ($file.FullName -ne $manifestPath -and -not $seen.Contains($file.FullName)) {
            throw "Unlisted file in release: $($file.FullName)"
        }
    }
    foreach ($required in @('zig-out\bin\zigstory.exe', 'scripts\zsprofile.ps1', 'scripts\safe-upgrade.ps1',
        'predictor\zigstoryPredictor.dll', 'predictor\Microsoft.Data.Sqlite.dll', 'predictor\e_sqlite3.dll')) {
        if (-not $seen.Contains((Join-Path $root $required))) { throw "Release is missing required file: $required" }
    }
}

function Test-ZigstoryUpgradeExecutable([string]$Path, [switch]$Installed) {
    $result = Invoke-ZigstoryUpgradeCommand $Path @('help')
    if ($result.ExitCode -ne 0 -or ($result.Output + $result.ErrorOutput) -notmatch '--consume') {
        throw "Executable validation failed: $Path must support import --consume."
    }
    if ($Installed) {
        $result = Invoke-ZigstoryUpgradeCommand $Path @('perf', '--cwd', '__zigstory_upgrade_validation__', '--format', 'json')
        if ($result.ExitCode -ne 0) { throw "Database validation failed: $($result.ErrorOutput)" }
        $metrics = $result.Output | ConvertFrom-Json
        if ($null -eq $metrics.PSObject.Properties['total_commands']) {
            throw 'Database validation returned unexpected JSON.'
        }
    }
}

function Invoke-ZigstorySafeUpgrade {
    param(
        [string]$RepositoryRoot,
        [string]$InstallExe,
        [string]$ProfileScript,
        [string]$HistoryDirectory,
        [string]$BackupRoot,
        [string]$PredictorDirectory = (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\zigstoryPredictor'),
        [string]$PackageDirectory
    )
    if ($PackageDirectory) {
        Test-ZigstoryReleaseBundle $PackageDirectory
        $RepositoryRoot = [IO.Path]::GetFullPath($PackageDirectory)
    }
    $sourceExe = Join-Path $RepositoryRoot 'zig-out\bin\zigstory.exe'
    $sourceProfile = Join-Path $RepositoryRoot 'scripts\zsprofile.ps1'
    foreach ($path in @($sourceExe, $sourceProfile, $InstallExe, $ProfileScript)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required file not found: $path. This recipe upgrades an existing installation; build the executable first."
        }
    }
    # Keep recovery copies outside every directory that rollback can move.
    $backupPath = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
    foreach ($path in @($HistoryDirectory, (Split-Path $InstallExe), (Split-Path $ProfileScript), $PredictorDirectory)) {
        $fullPath = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($backupPath.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase) -or
            $backupPath.StartsWith("$fullPath\", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'BackupRoot must be outside the history, executable, profile and predictor directories.'
        }
    }
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($sourceProfile, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Profile syntax validation failed: $parseErrors" }
    Test-ZigstoryUpgradeExecutable $sourceExe
    Assert-ZigstoryUpgradeIdle

    if ([AppDomain]::CurrentDomain.GetAssemblies().GetName().Name -contains 'zigstoryPredictor') {
        throw 'Predictor is loaded in this process. Run safe-upgrade from pwsh -NoProfile.'
    }
    if ($PackageDirectory) {
        $published = Join-Path $PackageDirectory 'predictor'
        Test-ZigstoryUpgradePredictor $published
        Invoke-ZigstoryUpgradeReplacement -SourceExe $sourceExe -SourceProfile $sourceProfile `
            -InstallExe $InstallExe -ProfileScript $ProfileScript -HistoryDirectory $HistoryDirectory `
            -BackupPath $backupPath -PredictorDirectory $PredictorDirectory -PublishedPredictor $published
        return
    }
    $stage = Join-Path ([IO.Path]::GetTempPath()) "zigstory-predictor-upgrade-$([Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $stage
    try {
        Write-Host 'Publishing and validating the predictor (Release, win-x64)...'
        Publish-ZigstoryUpgradePredictor $RepositoryRoot $stage
        Test-ZigstoryUpgradePredictor $stage
        Invoke-ZigstoryUpgradeReplacement -SourceExe $sourceExe -SourceProfile $sourceProfile `
            -InstallExe $InstallExe -ProfileScript $ProfileScript -HistoryDirectory $HistoryDirectory `
            -BackupPath $backupPath -PredictorDirectory $PredictorDirectory -PublishedPredictor $stage
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force }
}

function Invoke-ZigstoryUpgradeReplacement {
    param($SourceExe, $SourceProfile, $InstallExe, $ProfileScript, $HistoryDirectory, $BackupPath, $PredictorDirectory, $PublishedPredictor)
    $backup = Join-Path $backupPath ("upgrade-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N'))
    $failedHistory = "$HistoryDirectory.failed-$(Split-Path $backup -Leaf)"
    $previousPredictor = "$PredictorDirectory.previous-$(Split-Path $backup -Leaf)"
    $failedPredictor = "$PredictorDirectory.failed-$(Split-Path $backup -Leaf)"
    $hadPredictor = Test-Path -LiteralPath $PredictorDirectory
    if ($hadPredictor -and -not (Test-Path -LiteralPath $PredictorDirectory -PathType Container)) {
        throw "Predictor location is not a directory: $PredictorDirectory"
    }
    $null = New-Item -ItemType Directory -Path $backup
    Copy-Item -LiteralPath $InstallExe -Destination (Join-Path $backup 'zigstory.exe')
    Copy-Item -LiteralPath $ProfileScript -Destination (Join-Path $backup 'zsprofile.ps1')
    if ($hadPredictor) {
        Copy-Item -LiteralPath $PredictorDirectory -Destination (Join-Path $backup 'predictor') -Recurse -Force
    }
    $hadHistory = Test-Path -LiteralPath $HistoryDirectory
    if ($hadHistory) {
        if (-not (Test-Path -LiteralPath $HistoryDirectory -PathType Container)) {
            throw "History location is not a directory: $HistoryDirectory"
        }
        Copy-Item -LiteralPath $HistoryDirectory -Destination (Join-Path $backup 'history') -Recurse -Force
    }
    @{
        executable = $InstallExe
        profile = $ProfileScript
        history = $HistoryDirectory
        had_history = $hadHistory
        failed_history = $failedHistory
        predictor = $PredictorDirectory
        had_predictor = $hadPredictor
        previous_predictor = $previousPredictor
        failed_predictor = $failedPredictor
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding utf8
    Write-Host "Backup: $backup"

    # Recheck after copying the backup, before changing any installed files.
    Assert-ZigstoryUpgradeIdle
    $predictorTouched = $false
    try {
        Copy-Item -LiteralPath $sourceExe -Destination $InstallExe -Force
        Copy-Item -LiteralPath $sourceProfile -Destination $ProfileScript -Force
        if ($hadPredictor) {
            Move-Item -LiteralPath $PredictorDirectory -Destination $previousPredictor
        } else {
            $null = New-Item -ItemType Directory -Path (Split-Path $PredictorDirectory) -Force
        }
        $predictorTouched = $true
        Copy-Item -LiteralPath $PublishedPredictor -Destination $PredictorDirectory -Recurse -Force
        foreach ($file in Get-ChildItem -LiteralPath $PublishedPredictor -File -Recurse -Force) {
            $relative = [IO.Path]::GetRelativePath($PublishedPredictor, $file.FullName)
            if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne
                (Get-FileHash -LiteralPath (Join-Path $PredictorDirectory $relative)).Hash) {
                throw "Installed predictor verification failed: $relative"
            }
        }
        foreach ($pair in @(@($sourceExe, $InstallExe), @($sourceProfile, $ProfileScript))) {
            if ((Get-FileHash -LiteralPath $pair[0]).Hash -ne (Get-FileHash -LiteralPath $pair[1]).Hash) {
                throw "Installed file verification failed: $($pair[1])"
            }
        }
        Test-ZigstoryUpgradeExecutable $InstallExe -Installed
        Test-ZigstoryUpgradePredictor $PredictorDirectory
        if ($hadPredictor) { Remove-Item -LiteralPath $previousPredictor -Recurse -Force }
        'Upgrade succeeded.' | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
    } catch {
        $upgradeError = $_
        Write-Warning "Upgrade failed; restoring files and database from $backup"
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        # Never restore a live database. Keep backup and failed state for recovery.
        try {
            Assert-ZigstoryUpgradeIdle
        } catch {
            $result = "Upgrade failed: $($upgradeError.Exception.Message)`nROLLBACK BLOCKED: $($_.Exception.Message)"
            $result | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
            throw "$result`nClose all recording processes before manual recovery from: $backup"
        }
        try {
            if (Test-Path -LiteralPath $HistoryDirectory) {
                Move-Item -LiteralPath $HistoryDirectory -Destination $failedHistory -Force
            }
            if ($hadHistory) {
                Copy-Item -LiteralPath (Join-Path $backup 'history') -Destination $HistoryDirectory -Recurse -Force
            }
        } catch {
            $result = "Upgrade failed: $($upgradeError.Exception.Message)`nROLLBACK INCOMPLETE: History restore: $($_.Exception.Message)"
            $result | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
            throw "$result`nInstalled binaries were not rolled back against an unrestored database. Recovery backup: $backup"
        }
        foreach ($pair in @(@('zigstory.exe', $InstallExe), @('zsprofile.ps1', $ProfileScript))) {
            try {
                Copy-Item -LiteralPath (Join-Path $backup $pair[0]) -Destination $pair[1] -Force
            } catch { $rollbackErrors.Add("Restore $($pair[1]): $($_.Exception.Message)") }
        }
        if ($predictorTouched) {
            try {
                if (Test-Path -LiteralPath $PredictorDirectory) {
                    Move-Item -LiteralPath $PredictorDirectory -Destination $failedPredictor
                }
                if ($hadPredictor) {
                    Copy-Item -LiteralPath (Join-Path $backup 'predictor') -Destination $PredictorDirectory -Recurse -Force
                }
            } catch { $rollbackErrors.Add("Restore predictor: $($_.Exception.Message)") }
        }
        $result = "Upgrade failed: $($upgradeError.Exception.Message)"
        if ($rollbackErrors.Count -gt 0) {
            $result += "`nROLLBACK INCOMPLETE: $($rollbackErrors -join '; ')"
        } else {
            $result += "`nRollback completed; previous files and history restored."
        }
        $result | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
        throw "$result`nRecovery backup: $backup"
    }
    Write-Host 'Upgrade succeeded. Executable, profile and predictor updated. Restart PowerShell.'
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ZigstorySafeUpgrade -RepositoryRoot (Split-Path $PSScriptRoot -Parent) `
        -InstallExe (Join-Path $env:APPDATA 'zigstory\zigstory.exe') `
        -ProfileScript (Join-Path (Split-Path $PROFILE.CurrentUserCurrentHost) 'zsprofile.ps1') `
        -HistoryDirectory (Join-Path $env:USERPROFILE '.zigstory') -BackupRoot $BackupRoot -PackageDirectory $PackageDirectory
}
