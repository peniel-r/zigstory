. "F:\sandbox\zigstory\scripts\profile.ps1"

Write-Host "Queue exists: $($null -ne $Global:ZigstoryQueue)"
Write-Host "Queue value: $Global:ZigstoryQueue"
Write-Host "Queue type: $($Global:ZigstoryQueue.GetType().Name)"
Write-Host "Queue count: $($Global:ZigstoryQueue.Count)"
