# Test profile.ps1 by manually queuing a command

Write-Host "`n=== Testing Profile.ps1 Command Recording ===`n" -ForegroundColor Cyan

# Load profile
. "F:\sandbox\zigstory\scripts\profile.ps1"

Write-Host "Profile loaded successfully" -ForegroundColor Green
Write-Host "Initial queue count: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Manually simulate what Prompt does
# Create a mock history entry object
$mockHistory = @{
    Id = 1
    CommandLine = "echo 'test command from profile'"
    Duration = [TimeSpan]::FromMilliseconds(125)
}

# Simulate setting the history
$Global:ZigstoryLastHistoryId = 0
$lastHistory = [PSCustomObject]$mockHistory

Write-Host "`nSimulating command execution..." -ForegroundColor Yellow

# Manually queue the command (what Prompt function does)
$cmd = $lastHistory.CommandLine
$cwd = "F:\sandbox\zigstory"
$exitCode = 0
$duration = [int]$lastHistory.Duration.TotalMilliseconds

# Check if command should be recorded
if (ZigstoryShouldRecord $cmd) {
    Write-Host "Command '$cmd' passed filter" -ForegroundColor Green
    ZigstoryQueueCommand $cmd $cwd $exitCode $duration
} else {
    Write-Host "Command '$cmd' was filtered out" -ForegroundColor Yellow
}

Write-Host "Queue count after command: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Test with a filtered command
Write-Host "`nTesting filtered command (empty line)..." -ForegroundColor Yellow
ZigstoryQueueCommand "" "F:\sandbox\zigstory" 0 50
Write-Host "Queue count after empty command: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Show queued items
if ($Global:ZigstoryQueue.Count -gt 0) {
    Write-Host "`nQueued commands:" -ForegroundColor DarkGray
    $idx = 1
    foreach ($item in $Global:ZigstoryQueue) {
        Write-Host "  [$idx] cmd: '$($item.cmd)'" -ForegroundColor Gray
        Write-Host "      cwd: $($item.cwd), exit: $($item.exit_code), duration: $($item.duration_ms)ms" -ForegroundColor DarkGray
        $idx++
    }
}

# Flush queue
Write-Host "`nFlushing queue to database..." -ForegroundColor Yellow
ZigstoryFlushQueue

Write-Host "Queue count after flush: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Verify in database
Write-Host "`nVerifying in database (last 3 entries)..." -ForegroundColor Yellow
& $Global:ZigstoryBin list 3 2>&1 | Select-Object -First 20

Write-Host "`n=== Test Complete ===`n" -ForegroundColor Green

# Cleanup timer
if ($Global:ZigstoryTimer) {
    $Global:ZigstoryTimer.Stop()
    Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
    $Global:ZigstoryTimer.Dispose()
}
