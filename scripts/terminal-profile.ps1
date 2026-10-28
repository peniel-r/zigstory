#Requires -Version 7.0
param([string]$Executable = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\zigstory.exe'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    throw 'Run this measurement directly in Windows Terminal or WezTerm, without redirected input/output.'
}
$report = Join-Path ([IO.Path]::GetTempPath()) "zigstory-terminal-$([Guid]::NewGuid().ToString('N')).json"
$process = [Diagnostics.Process]::new()
try {
    $process.StartInfo.FileName = (Resolve-Path -LiteralPath $Executable).Path
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.ArgumentList.Add('search')
    $process.StartInfo.Environment['ZIGSTORY_TUI_PROFILE'] = $report
    Write-Host 'Type/search/scroll, then cancel with Ctrl+C. Timing includes real terminal writes, not display composition.'
    $process.StartInfo.Environment['ZIGSTORY_TUI_LAUNCH_NS'] = [string][decimal]::Truncate(
        [decimal][Diagnostics.Stopwatch]::GetTimestamp() * 1000000000 / [Diagnostics.Stopwatch]::Frequency)
    if (-not $process.Start()) { throw 'Could not start TUI measurement.' }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "TUI exited with code $($process.ExitCode)." }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($null -eq $result.launch_to_first_frame_ms) { throw 'No first frame was measured.' }
    $result | ConvertTo-Json
} finally {
    $process.Dispose()
    if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Force }
}
