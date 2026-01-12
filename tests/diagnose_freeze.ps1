# Diagnostic script to find what's causing the freeze

Write-Host "`n=== Zigstory Profile Diagnostics ===`n" -ForegroundColor Cyan

# Test 1: Test Get-History performance
Write-Host "Test 1: Get-History performance..." -ForegroundColor Yellow
$timer1 = Measure-Command {
    $lastHistory = Get-History -Count 1
}
Write-Host "  Get-History took: $($timer1.TotalMilliseconds)ms" -ForegroundColor DarkGray

# Test 2: Test queue operation
Write-Host "`nTest 2: Queue operation..." -ForegroundColor Yellow
if ($null -eq $Global:ZigstoryQueue) {
    $Global:ZigstoryQueue = [System.Collections.Generic.List[hashtable]]::new()
}

$timer2 = Measure-Command {
    $Global:ZigstoryQueue.Add(@{cmd='test'; cwd='F:\test'; exit_code=0; duration_ms=100})
}
Write-Host "  Queue add took: $($timer2.TotalMilliseconds)ms" -ForegroundColor DarkGray

# Test 3: Test filter function
Write-Host "`nTest 3: Filter function..." -ForegroundColor Yellow
$timer3 = Measure-Command {
    $result = $true
    if ($true) { $result = $false }
}
Write-Host "  Filter check took: $($timer3.TotalMilliseconds)ms" -ForegroundColor DarkGray

# Test 4: Load original profile and time Prompt
Write-Host "`nTest 4: Testing original profile Prompt..." -ForegroundColor Yellow

. "F:\sandbox\zigstory\scripts\profile.ps1"

# Add a dummy history entry
Add-Content -Path (Get-PSReadlineOption).HistorySavePath -Value "test diagnostic command" -Encoding utf8

$timer4 = Measure-Command {
    $promptOutput = Prompt
}
Write-Host "  Prompt function took: $($timer4.TotalMilliseconds)ms" -ForegroundColor DarkGray

# Cleanup
Remove-Content -Path (Get-PSReadlineOption).HistorySavePath -Force

Write-Host "`n=== Diagnostics Complete ===`n" -ForegroundColor Green
Write-Host "If Get-History took >100ms or Prompt took >10ms, that's the issue." -ForegroundColor Yellow
