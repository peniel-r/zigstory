#Requires -Version 7.0
param(
    [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testHome = Join-Path ([IO.Path]::GetTempPath()) "zigstory_json_$([Guid]::NewGuid().ToString('N'))"
$originalHome = $env:USERPROFILE
$originalUnixHome = $env:HOME
$originalAppData = $env:APPDATA
$script:payloadFile = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "[PASS] $Message"
}

# Extract recording helpers only: do not install profile hooks or predictors.
$profilePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\zsprofile.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$recordFunctions = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Global:ZigstoryRecordCommand', 'Global:Get-ZigstoryRecordingDirectory')
}, $true)
if ($recordFunctions.Count -ne 2) { throw 'Recording helpers not found' }
foreach ($function in $recordFunctions) { Invoke-Expression $function.Extent.Text }
$Global:ZigstorySessionId = [Guid]::NewGuid().ToString()

# Capture the generated file instead of launching a detached background importer.
function Global:Start-ZigstoryRecordingImport([string]$Path) {
    $script:payloadFile = $Path
}

try {
    New-Item -ItemType Directory -Path $testHome | Out-Null
    $env:USERPROFILE = $testHome
    $env:HOME = $testHome
    $env:APPDATA = Join-Path $testHome 'AppData'
    $Global:ZigstoryBin = (Resolve-Path -LiteralPath $Exe).Path
    $command = "echo `"quoted`"`nnext`tC:\path\with\backslashes " + ('x' * 3000) + ' こんにちは'
    $cwd = 'C:\repo\with spaces'
    ZigstoryRecordCommand $command $cwd 7 1250
    $payload = Get-Content -LiteralPath $script:payloadFile -Raw | ConvertFrom-Json
    Assert-True ($payload.Count -eq 1) 'Hook writes a JSON array with one entry'
    Assert-True ($payload[0].cmd -ceq $command) 'Hook preserves multiline, quoted, long, and Unicode commands'
    Assert-True ($payload[0].cwd -ceq $cwd) 'Hook preserves Windows paths'

    & $Global:ZigstoryBin import --file $script:payloadFile 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Serialized hook payload imports successfully'
    $stderr = Join-Path $testHome 'stderr.txt'
    $json = & $Global:ZigstoryBin perf --cwd $cwd --format json 2> $stderr
    Assert-True ($LASTEXITCODE -eq 0) 'Long-command perf JSON exits successfully'
    Assert-True ((Get-Item -LiteralPath $stderr).Length -eq 0) 'Perf JSON uses stdout, not stderr'
    $metrics = ($json | Out-String) | ConvertFrom-Json
    Assert-True ($metrics.last_cmd -ceq $command) 'Perf JSON round-trips the complete command'
    Assert-True (($json | Out-String) -notmatch '[^\x00-\x7F]') 'Perf JSON escapes non-ASCII text, so any console code page decodes it'
    Assert-True ($metrics.last_exit_code -eq 7 -and $metrics.total_commands -eq 1) 'Perf metrics preserve recorded values'
    $tieFile = Join-Path $testHome 'tie.json'
    '[{"cmd":"first","cwd":"tie"},{"cmd":"last","cwd":"tie","exit_code":2}]' |
        Set-Content -LiteralPath $tieFile -Encoding utf8
    & $Global:ZigstoryBin import --file $tieFile 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Same-timestamp batch imports successfully'
    $latest = & $Global:ZigstoryBin perf --cwd 'tie' --format json | ConvertFrom-Json
    Assert-True ($latest.last_cmd -ceq 'last' -and $latest.last_exit_code -eq 2) 'Latest metrics break timestamp ties by entry ID'
    $empty = & $Global:ZigstoryBin perf --cwd 'unknown' --format json | ConvertFrom-Json
    Assert-True ($empty.total_commands -eq 0) 'Unknown directory produces valid empty metrics'
    $maintenance = & $Global:ZigstoryBin maintenance 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'Explicit maintenance exits successfully'
    Assert-True ($maintenance.Contains('rebuilt and validated')) 'Maintenance reports FTS rebuilding and validation'
    $afterMaintenance = & $Global:ZigstoryBin perf --cwd $cwd --format json | ConvertFrom-Json
    Assert-True ($afterMaintenance.last_cmd -ceq $command -and $afterMaintenance.total_commands -eq 1) 'Maintenance preserves recorded history'

    # Reports are UTF-8 on stdout, and the hourly chart uses local time.
    $reportHome = Join-Path $testHome 'report-home'
    New-Item -ItemType Directory -Path $reportHome | Out-Null
    $env:USERPROFILE = $reportHome
    $env:HOME = $reportHome
    $timestamp = 1700000000
    $reportCommand = "echo r`u{e9}port"
    $reportJson = Join-Path $reportHome 'report.json'
    ConvertTo-Json -InputObject @(@{ cmd = $reportCommand; cwd = 'report'; timestamp = $timestamp }) -Compress |
        Set-Content -LiteralPath $reportJson -Encoding utf8
    & $Global:ZigstoryBin import --file $reportJson 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Report fixture imports successfully'
    $reportOut = Join-Path $reportHome 'out.txt'
    $reportErr = Join-Path $reportHome 'err.txt'
    & $Global:ZigstoryBin stats > $reportOut 2> $reportErr
    $statsText = [IO.File]::ReadAllText($reportOut, [Text.UTF8Encoding]::new($false))
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $reportErr).Length -eq 0 -and $statsText.Contains('OVERVIEW')) 'Stats writes its report to stdout'
    $localHour = [DateTimeOffset]::FromUnixTimeSeconds($timestamp).ToLocalTime().Hour
    Assert-True ($statsText -match ('(?m)^{0:D2} \| \u2588+ 1$' -f $localHour)) 'Stats buckets activity by local hour with UTF-8 bars'
    Assert-True ($statsText.Contains($reportCommand)) 'Stats preserves non-ASCII command text'
    & $Global:ZigstoryBin list 1 > $reportOut 2> $reportErr
    $listText = [IO.File]::ReadAllText($reportOut, [Text.UTF8Encoding]::new($false))
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $reportErr).Length -eq 0 -and $listText.Contains("1. $reportCommand")) 'List writes UTF-8 entries to stdout'
} finally {
    $env:USERPROFILE = $originalHome
    $env:HOME = $originalUnixHome
    $env:APPDATA = $originalAppData
    if ($script:payloadFile -and (Test-Path -LiteralPath $script:payloadFile)) {
        Remove-Item -LiteralPath $script:payloadFile -Force
    }
    Remove-Item -LiteralPath $testHome -Recurse -Force
}
