# Interactive test - run real commands in PowerShell

Write-Host "`n=== Interactive Profile Test ===`n" -ForegroundColor Cyan
Write-Host "Loading profile..." -ForegroundColor Yellow

# Load profile
. "F:\sandbox\zigstory\scripts\profile.ps1"

Write-Host "`nProfile loaded! Queue initialized." -ForegroundColor Green
Write-Host "Now run some commands and they will be queued in memory." -ForegroundColor DarkGray
Write-Host "Commands will be flushed to database every 5 seconds automatically.`n" -ForegroundColor DarkGray

Write-Host "Example commands to try:" -ForegroundColor Yellow
Write-Host "  echo 'hello world'" -ForegroundColor White
Write-Host "  ls" -ForegroundColor White
Write-Host "  Get-Process" -ForegroundColor White
Write-Host "  (empty line - should be filtered)" -ForegroundColor Gray
Write-Host "  cd" -ForegroundColor Gray
Write-Host "`nType 'quit' to exit and flush pending commands.`n" -ForegroundColor Cyan

# Interactive loop
while ($true) {
    $input = Read-Host "PS>"

    if ($input -eq 'quit') {
        Write-Host "`nFlushing queue before exit..." -ForegroundColor Yellow
        ZigstoryFlushQueue
        Write-Host "Queue count after flush: $($Global:ZigstoryQueue.Count)" -ForegroundColor DarkGray

        Write-Host "`nFinal database contents (last 5):" -ForegroundColor Yellow
        & $Global:ZigstoryBin list 5 2>&1

        Write-Host "`nExiting..." -ForegroundColor Green

        # Cleanup
        if ($Global:ZigstoryTimer) {
            $Global:ZigstoryTimer.Stop()
            Unregister-Event -SourceIdentifier ZigstoryFlushTimer -ErrorAction SilentlyContinue
            $Global:ZigstoryTimer.Dispose()
        }

        break
    }

    # Simulate command execution by adding to history
    # In real PowerShell, this happens automatically
    $mockHistory = @{
        Id = $null
        CommandLine = $input
        Duration = [TimeSpan]::FromMilliseconds((Get-Random -Minimum 10 -Maximum 200))
    }

    $lastHistory = [PSCustomObject]$mockHistory

    # Check if command should be recorded
    if (ZigstoryShouldRecord $lastHistory.CommandLine) {
        $cmd = $lastHistory.CommandLine
        $cwd = $PWD.ProviderPath
        $exitCode = 0
        $duration = [int]$lastHistory.Duration.TotalMilliseconds

        ZigstoryQueueCommand $cmd $cwd $exitCode $duration

        Write-Host "  → Queued: '$cmd' (exit: $exitCode, duration: ${duration}ms)" -ForegroundColor DarkGray
    } else {
        Write-Host "  → Filtered: '$($lastHistory.CommandLine)'" -ForegroundColor Gray
    }

    Write-Host "  Queue size: $($Global:ZigstoryQueue.Count) / $Global:ZigstoryMaxQueueSize`n" -ForegroundColor DarkGray
}
