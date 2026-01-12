# Quick manual demonstration in pwsh

Write-Host "`n=== Manual Profile Test in pwsh ===`n" -ForegroundColor Cyan

# Load profile
. "F:\sandbox\zigstory\scripts\profile.ps1"

Write-Host "Profile loaded." -ForegroundColor Green
Write-Host "Queue: $($Global:ZigstoryQueue.Count) items" -ForegroundColor DarkGray

# Queue a test command
Write-Host "`nQueueing test command..." -ForegroundColor Yellow
ZigstoryQueueCommand "echo 'manual test from pwsh'" "F:\sandbox\zigstory" 0 88

Write-Host "Queue: $($Global:ZigstoryQueue.Count) items" -ForegroundColor DarkGray

# Flush immediately
Write-Host "`nFlushing queue..." -ForegroundColor Yellow
ZigstoryFlushQueue

Write-Host "Queue after flush: $($Global:ZigstoryQueue.Count) items" -ForegroundColor DarkGray

# Verify
Write-Host "`nLatest entry in database:" -ForegroundColor Yellow
& $Global:ZigstoryBin list 1 2>&1 | Select-Object -First 10

Write-Host "`n=== Test Complete ===" -ForegroundColor Green

# Cleanup
if ($Global:ZigstoryTimer) {
    $Global:ZigstoryTimer.Stop()
    Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
    $Global:ZigstoryTimer.Dispose()
}
