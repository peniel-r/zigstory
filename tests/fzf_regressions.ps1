#Requires -Version 7.4
param([string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'))
$ErrorActionPreference = 'Stop'
$directory = Join-Path $env:LOCALAPPDATA ("Temp\opencode\fzf-regressions-" + [Guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($name in @('USERPROFILE', 'HOME', 'PATH', 'DOTNET_ROOT', 'DOTNET_ROOT_X64')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $null = New-Item -ItemType Directory -Path $directory
    $dotnet = Join-Path $env:USERPROFILE 'scoop\apps\dotnet-sdk\current\dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet.exe).Source }
    $env:DOTNET_ROOT = Split-Path $dotnet
    $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
    $fake = Join-Path $directory 'fake'
    & $dotnet publish (Join-Path $PSScriptRoot 'fzf\FzfHarness.csproj') -c Release -r win-x64 --self-contained false -o $fake | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fzf harness publish failed' }
    $env:PATH = "$fake;$env:PATH"
    $env:USERPROFILE = $directory
    $env:HOME = $directory
    $cmd = "  first `"quoted`"`nsecond`t`u{e9}`n"
    $json = Join-Path $directory 'input.json'
    ConvertTo-Json -InputObject @(@{ cmd = $cmd; cwd = 'local' }) -Compress | Set-Content -LiteralPath $json -Encoding utf8
    & $Exe import --file $json 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fzf fixture import failed' }
    $selection = Join-Path $directory 'selection.txt'
    & $Exe fzf --output $selection
    if ($LASTEXITCODE -ne 0 -or [IO.File]::ReadAllText($selection) -cne $cmd) { throw 'fzf truncated or changed multiline/Unicode/whitespace command text' }
    Write-Host '[PASS] fzf receives and returns complete commands with NUL record boundaries'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
