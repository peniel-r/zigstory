#Requires -Version 7.0
param([string]$BackupRoot = (Join-Path $env:USERPROFILE '.zigstory-backups'))

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
        if ($process.Name -notmatch '^(pwsh|powershell|zigstory|zigstory-tui-profile)\.exe$' -or
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

function Invoke-ZigstoryUpgradeCommand([string]$Path, [string[]]$Arguments) {
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo.FileName = $Path
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
        if (-not $process.Start()) { throw "Failed to start $Path" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            throw "Validation timed out after 30 seconds: $Path"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.GetAwaiter().GetResult()
            ErrorOutput = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
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
        [string]$BackupRoot
    )
    $sourceExe = Join-Path $RepositoryRoot 'zig-out\bin\zigstory.exe'
    $sourceProfile = Join-Path $RepositoryRoot 'scripts\zsprofile.ps1'
    foreach ($path in @($sourceExe, $sourceProfile, $InstallExe, $ProfileScript)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required file not found: $path. This recipe upgrades an existing installation; build the executable first."
        }
    }
    # Keep recovery copies outside every directory that rollback can move.
    $backupPath = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
    foreach ($path in @($HistoryDirectory, (Split-Path $InstallExe), (Split-Path $ProfileScript))) {
        $fullPath = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($backupPath.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase) -or
            $backupPath.StartsWith("$fullPath\", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'BackupRoot must be outside the history, executable and profile directories.'
        }
    }
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($sourceProfile, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Profile syntax validation failed: $parseErrors" }
    Test-ZigstoryUpgradeExecutable $sourceExe
    Assert-ZigstoryUpgradeIdle

    $backup = Join-Path $backupPath ("upgrade-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N'))
    $failedHistory = "$HistoryDirectory.failed-$(Split-Path $backup -Leaf)"
    $null = New-Item -ItemType Directory -Path $backup
    Copy-Item -LiteralPath $InstallExe -Destination (Join-Path $backup 'zigstory.exe')
    Copy-Item -LiteralPath $ProfileScript -Destination (Join-Path $backup 'zsprofile.ps1')
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
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding utf8
    Write-Host "Backup: $backup"

    # Recheck after copying the backup, before changing any installed files.
    Assert-ZigstoryUpgradeIdle
    try {
        Copy-Item -LiteralPath $sourceExe -Destination $InstallExe -Force
        Copy-Item -LiteralPath $sourceProfile -Destination $ProfileScript -Force
        foreach ($pair in @(@($sourceExe, $InstallExe), @($sourceProfile, $ProfileScript))) {
            if ((Get-FileHash -LiteralPath $pair[0]).Hash -ne (Get-FileHash -LiteralPath $pair[1]).Hash) {
                throw "Installed file verification failed: $($pair[1])"
            }
        }
        Test-ZigstoryUpgradeExecutable $InstallExe -Installed
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
        $result = "Upgrade failed: $($upgradeError.Exception.Message)"
        if ($rollbackErrors.Count -gt 0) {
            $result += "`nROLLBACK INCOMPLETE: $($rollbackErrors -join '; ')"
        } else {
            $result += "`nRollback completed; previous files and history restored."
        }
        $result | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
        throw "$result`nRecovery backup: $backup"
    }
    Write-Host 'Upgrade succeeded. Restart PowerShell. Predictor DLLs were not changed.'
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ZigstorySafeUpgrade -RepositoryRoot (Split-Path $PSScriptRoot -Parent) `
        -InstallExe (Join-Path $env:APPDATA 'zigstory\zigstory.exe') `
        -ProfileScript (Join-Path (Split-Path $PROFILE.CurrentUserCurrentHost) 'zsprofile.ps1') `
        -HistoryDirectory (Join-Path $env:USERPROFILE '.zigstory') -BackupRoot $BackupRoot
}
