#Requires -Version 7.0
param([string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$directory = Join-Path ([IO.Path]::GetTempPath()) "zigstory_logs_$([Guid]::NewGuid().ToString('N'))"
$saved = @{}
foreach ($key in @('USERPROFILE', 'HOME', 'ZIGSTORY_LOG_DIR', 'ZIGSTORY_LOG_LEVEL')) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
}
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}
try {
    $null = New-Item -ItemType Directory -Path $directory
    $env:USERPROFILE = $directory
    $env:HOME = $directory
    $env:ZIGSTORY_LOG_DIR = Join-Path $directory 'logs'
    $env:ZIGSTORY_LOG_LEVEL = $null
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\zsprofile.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($function in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Global:Write-ZigstoryLog', 'Global:Get-ZigstoryRecordingDirectory')
    }, $true)) { Invoke-Expression $function.Extent.Text }
    Write-ZigstoryLog -Level Warning -Event 'not_persisted'
    Check (-not (Test-Path -LiteralPath $env:ZIGSTORY_LOG_DIR)) 'Default Error logging does not create files for warnings'
    Write-ZigstoryLog -Event 'test_failure' -Code 'TestError'
    $path = Join-Path $env:ZIGSTORY_LOG_DIR 'powershell.log'
    $entry = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Check ($entry.level -eq 'Error' -and $entry.code -eq 'TestError') 'PowerShell persists structured Error events by default'
    $env:ZIGSTORY_LOG_LEVEL = 'debug'
    Write-ZigstoryLog -Level Info -Event 'test_info'
    Check (@(Get-Content -LiteralPath $path).Count -eq 2) 'Log level override is case insensitive'
    [IO.File]::WriteAllText($path, ('x' * 1MB))
    Write-ZigstoryLog -Event 'rotated'
    Check ([IO.File]::Exists("$path.1") -and [IO.FileInfo]::new($path).Length -lt 1MB) 'PowerShell rotates at one MiB'
    $env:ZIGSTORY_LOG_LEVEL = 'Off'
    $before = [IO.File]::ReadAllText($path)
    Write-ZigstoryLog -Event 'disabled'
    Check ([IO.File]::ReadAllText($path) -eq $before) 'Off suppresses persistent logging'
    $env:ZIGSTORY_LOG_LEVEL = $null
    & $Exe add --cmd 'private_secret_never_logged' 2>&1 | Out-Null
    Check ($LASTEXITCODE -ne 0) 'Invalid CLI command still fails'
    $cliPath = Join-Path $env:ZIGSTORY_LOG_DIR 'cli.log'
    $cliEntry = Get-Content -LiteralPath $cliPath -Raw | ConvertFrom-Json
    Check ($cliEntry.level -eq 'Error' -and $cliEntry.code) 'CLI persists errors with an error identifier'
    Check (-not [IO.File]::ReadAllText($cliPath).Contains('private_secret_never_logged')) 'CLI logs exclude argument values'
    [IO.File]::WriteAllText($cliPath, ('x' * 1MB))
    & $Exe add 2>&1 | Out-Null
    Check ([IO.File]::Exists("$cliPath.1") -and [IO.FileInfo]::new($cliPath).Length -lt 1MB) 'CLI rotates at one MiB'
    $env:ZIGSTORY_LOG_LEVEL = 'Off'
    $before = [IO.File]::ReadAllText($cliPath)
    & $Exe add 2>&1 | Out-Null
    Check ([IO.File]::ReadAllText($cliPath) -eq $before) 'CLI honors Off'
    $env:ZIGSTORY_LOG_LEVEL = 'Error'
    $env:ZIGSTORY_LOG_DIR = Join-Path $directory 'blocked'
    [IO.File]::WriteAllText($env:ZIGSTORY_LOG_DIR, 'not a directory')
    $output = (& $Exe add 2>&1 | Out-String)
    Check ($output.Contains('logging failed') -and $LASTEXITCODE -ne 0) 'Unwritable CLI logs report failure without hiding the original error'
    Write-ZigstoryLog -Event 'blocked' -WarningVariable warnings 3>$null
    Check ($warnings.Count -gt 0) 'Unwritable PowerShell logs surface a warning'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
