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

# Extract only the recording function: do not install profile hooks or predictors.
$profilePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\zsprofile.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$recordFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Global:ZigstoryRecordCommand'
}, $true)
if (-not $recordFunction) { throw 'Recording function not found' }
Invoke-Expression $recordFunction.Extent.Text

# Capture the generated file instead of launching a detached background importer.
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, $ErrorAction)
    if ($ArgumentList[-1] -notmatch '--file "([^"]+)"$') { throw 'Import file argument missing' }
    $script:payloadFile = $Matches[1]
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
} finally {
    $env:USERPROFILE = $originalHome
    $env:HOME = $originalUnixHome
    $env:APPDATA = $originalAppData
    if ($script:payloadFile -and (Test-Path -LiteralPath $script:payloadFile)) {
        Remove-Item -LiteralPath $script:payloadFile -Force
    }
    Remove-Item -LiteralPath $testHome -Recurse -Force
}
