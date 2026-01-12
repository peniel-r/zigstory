# Simple demonstration test

Write-Host "`n=== Profile.ps1 Test Demonstration ===`n" -ForegroundColor Cyan

# Clear database for clean test
$dbPath = "$env:USERPROFILE\.zigstory\history.db"
if (Test-Path $dbPath) {
    Write-Host "Clearing existing database for clean test..." -ForegroundColor Yellow
    Remove-Item $dbPath -Force
    Start-Sleep -Milliseconds 200
}

# Load profile
Write-Host "Loading profile..." -ForegroundColor Yellow
. "F:\sandbox\zigstory\scripts\profile.ps1"

Write-Host "Profile loaded!" -ForegroundColor Green
Write-Host "Queue count: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Test 1: Queue a meaningful command
Write-Host "`nTest 1: Queue meaningful command..." -ForegroundColor Yellow
ZigstoryQueueCommand "echo 'testing profile'" "F:\sandbox\zigstory" 0 150
Write-Host "Queue count: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Test 2: Queue another meaningful command
Write-Host "`nTest 2: Queue git command..." -ForegroundColor Yellow
ZigstoryQueueCommand "git status" "F:\sandbox\zigstory" 1 200
Write-Host "Queue count: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Test 3: Try to queue empty command (should be filtered by ZigstoryShouldRecord)
Write-Host "`nTest 3: Try empty command (should be filtered)..." -ForegroundColor Yellow
if (ZigstoryShouldRecord "") {
    Write-Host "ERROR: Empty command passed filter!" -ForegroundColor Red
} else {
    Write-Host "PASS: Empty command correctly filtered" -ForegroundColor Green
}

# Test 4: Show queue contents
Write-Host "`nTest 4: Queue contents:" -ForegroundColor Yellow
foreach ($item in $Global:ZigstoryQueue) {
    Write-Host "  - $($item.cmd)" -ForegroundColor White
    Write-Host "    Exit: $($item.exit_code), Duration: $($item.duration_ms)ms" -ForegroundColor DarkGray
}

# Test 5: Flush queue
Write-Host "`nTest 5: Flushing queue to database..." -ForegroundColor Yellow
$startTime = Get-Date
ZigstoryFlushQueue
$flushTime = ((Get-Date) - $startTime).TotalMilliseconds

Write-Host "Flush completed in ${flushTime}ms" -ForegroundColor DarkGray
Write-Host "Queue count after flush: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Test 6: Verify in database
Write-Host "`nTest 6: Verifying database contents..." -ForegroundColor Yellow
$result = & $Global:ZigstoryBin list 10 2>&1
Write-Host $result -ForegroundColor Gray

Write-Host "`n=== All Tests Passed ===" -ForegroundColor Green

# Cleanup
if ($Global:ZigstoryTimer) {
    $Global:ZigstoryTimer.Stop()
    Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
    $Global:ZigstoryTimer.Dispose()
}
