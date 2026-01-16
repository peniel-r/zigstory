# Simple test for PowerShell profile batching

Write-Host "=== Simple PowerShell Profile Test ===" -ForegroundColor Cyan

# Source the profile
. "$PSScriptRoot\..\scripts\zsprofile.ps1"

# Check if queue exists
Write-Host "`nChecking queue..." -ForegroundColor Yellow
if ($null -ne $Global:ZigstoryQueue) {
    Write-Host "Queue exists. Type: $($Global:ZigstoryQueue.GetType().Name)" -ForegroundColor Green
    Write-Host "Initial count: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray
}
else {
    Write-Host "Queue NOT found!" -ForegroundColor Red
    exit 1
}

# Add some test commands
Write-Host "`nAdding commands to queue..." -ForegroundColor Yellow
ZigstoryQueueCommand "echo 'test1'" "C:\test" 0 100
ZigstoryQueueCommand "git status" "C:\test" 1 200
ZigstoryQueueCommand "ls -la" "C:\test" 0 50

Write-Host "Queue count after adding: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Flush the queue
Write-Host "`nFlushing queue..." -ForegroundColor Yellow
ZigstoryFlushQueue

Write-Host "Queue count after flush: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Verify in database (using PowerShell 2>&1 to handle stderr from zigstory)
Write-Host "`nVerifying in database..." -ForegroundColor Yellow
$result = & $Global:ZigstoryBin list 5 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host $result -ForegroundColor Gray
}

Write-Host "`nTest complete!" -ForegroundColor Green

# Cleanup
if ($Global:ZigstoryTimer) {
    $Global:ZigstoryTimer.Stop()
    Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
    $Global:ZigstoryTimer.Dispose()
}
