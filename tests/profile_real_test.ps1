# Test profile.ps1 by simulating command execution

Write-Host "`n=== Testing Profile.ps1 Command Recording ===`n" -ForegroundColor Cyan

# Load the profile
. "F:\sandbox\zigstory\scripts\profile.ps1"

Write-Host "Profile loaded successfully" -ForegroundColor Green
Write-Host "Initial queue count: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Simulate running a command by manipulating history
# First, add a command to history (simulating what happens when you run a command)
Add-History -InputObject "echo 'test command from profile'"

# Now trigger the Prompt function to record it
# In normal usage, PowerShell calls Prompt automatically after each command
# We'll simulate this by calling Prompt directly

Write-Host "`nSimulating command execution..." -ForegroundColor Yellow

# The Prompt function will see the last history entry and queue it
$PromptOutput = Prompt

Write-Host "Queue count after command: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Show what's in the queue
if ($Global:ZigstoryQueue.Count -gt 0) {
    Write-Host "`nQueued commands:" -ForegroundColor DarkGray
    foreach ($item in $Global:ZigstoryQueue) {
        Write-Host "  - cmd: '$($item.cmd)'" -ForegroundColor Gray
        Write-Host "    cwd: $($item.cwd), exit: $($item.exit_code), duration: $($item.duration_ms)ms" -ForegroundColor DarkGray
    }
}

# Now flush the queue manually
Write-Host "`nFlushing queue..." -ForegroundColor Yellow
ZigstoryFlushQueue

Write-Host "Queue count after flush: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

# Verify in database
Write-Host "`nChecking database..." -ForegroundColor Yellow
& $Global:ZigstoryBin list 3 2>&1

Write-Host "`n=== Test Complete ===`n" -ForegroundColor Green

# Cleanup timer
if ($Global:ZigstoryTimer) {
    $Global:ZigstoryTimer.Stop()
    Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
    $Global:ZigstoryTimer.Dispose()
}
