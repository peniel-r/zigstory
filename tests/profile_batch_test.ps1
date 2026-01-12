# Test the PowerShell profile batching system

Write-Host "`n=== Testing PowerShell Profile Batching ===`n" -ForegroundColor Cyan

# Source the profile
. "$PSScriptRoot\..\scripts\profile.ps1"

# Test 1: Verify queue initialization
Write-Host "Test 1: Verifying queue initialization..." -ForegroundColor Yellow
if ($Global:ZigstoryQueue -ne $null) {
    Write-Host "  ✓ Queue initialized" -ForegroundColor Green
    Write-Host "  Queue type: $($Global:ZigstoryQueue.GetType().Name)" -ForegroundColor DarkGray
} else {
    Write-Host "  ✗ Queue not initialized" -ForegroundColor Red
}

# Test 2: Verify filter function
Write-Host "`nTest 2: Testing command filter function..." -ForegroundColor Yellow

$testCommands = @(
    @{cmd = "echo 'hello'"; should_record = $true}
    @{cmd = ""; should_record = $false}
    @{cmd = "   "; should_record = $false}
    @{cmd = "C:"; should_record = $false}
    @{cmd = "exit"; should_record = $false}
    @{cmd = "git status"; should_record = $true}
    @{cmd = "ls -la"; should_record = $true}
    @{cmd = "cls"; should_record = $false}
    @{cmd = "clear"; should_record = $false}
    @{cmd = "cd"; should_record = $false}
    @{cmd = "cd ."; should_record = $false}
    @{cmd = "pwd"; should_record = $false}
)

$passCount = 0
$failCount = 0

foreach ($test in $testCommands) {
    $result = ZigstoryShouldRecord $test.cmd
    if ($result -eq $test.should_record) {
        $passCount++
        Write-Host "  ✓ '$($test.cmd)' -> $($result)" -ForegroundColor Green
    } else {
        $failCount++
        Write-Host "  ✗ '$($test.cmd)' -> $($result) (expected: $($test.should_record))" -ForegroundColor Red
    }
}

Write-Host "`n  Filter tests: $passCount passed, $failCount failed" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })

# Test 3: Queue operations
Write-Host "`nTest 3: Testing queue operations..." -ForegroundColor Yellow

$initialCount = $Global:ZigstoryQueue.Count
Write-Host "  Initial queue size: $initialCount" -ForegroundColor DarkGray

# Add some commands to queue
ZigstoryQueueCommand "echo 'test1'" "C:\test" 0 100
ZigstoryQueueCommand "git status" "C:\test" 1 200
ZigstoryQueueCommand "ls -la" "C:\test" 0 50

$afterCount = $Global:ZigstoryQueue.Count
Write-Host "  After adding 3 commands: $afterCount" -ForegroundColor DarkGray

if ($afterCount -eq ($initialCount + 3)) {
    Write-Host "  ✓ Queue operations working correctly" -ForegroundColor Green
} else {
    Write-Host "  ✗ Queue operations failed" -ForegroundColor Red
}

# Test 4: Manual flush
Write-Host "`nTest 4: Testing manual queue flush..." -ForegroundColor Yellow
$beforeFlush = $Global:ZigstoryQueue.Count
Write-Host "  Queue size before flush: $beforeFlush" -ForegroundColor DarkGray

ZigstoryFlushQueue

$afterFlush = $Global:ZigstoryQueue.Count
Write-Host "  Queue size after flush: $afterFlush" -ForegroundColor DarkGray

if ($afterFlush -eq 0 -and $beforeFlush -gt 0) {
    Write-Host "  ✓ Flush completed successfully" -ForegroundColor Green

    # Verify in database
    $listResult = & $Global:ZigstoryBin list 5 2>&1
    Write-Host "  Recent entries:" -ForegroundColor DarkGray
    Write-Host "$listResult" -ForegroundColor Gray
} else {
    Write-Host "  ✗ Flush failed" -ForegroundColor Red
}

# Test 5: Verify timer is running
Write-Host "`nTest 5: Verifying auto-flush timer..." -ForegroundColor Yellow
if ($Global:ZigstoryTimer -ne $null) {
    if ($Global:ZigstoryTimer.Enabled) {
        Write-Host "  ✓ Timer is running (interval: $($Global:ZigstoryTimer.Interval)ms = $([math]::Round($Global:ZigstoryTimer.Interval / 1000, 1))s)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Timer is not enabled" -ForegroundColor Red
    }
} else {
    Write-Host "  ✗ Timer not initialized" -ForegroundColor Red
}

Write-Host "`n=== All Tests Complete ===`n" -ForegroundColor Green

# Cleanup
if ($Global:ZigstoryTimer) {
    $Global:ZigstoryTimer.Stop()
    Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
    $Global:ZigstoryTimer.Dispose()
}
