# Test Get-History performance
Write-Host "`n=== Get-History Performance Test ===`n" -ForegroundColor Cyan

$iterations = 10
$totalTime = 0

for ($i = 1; $i -le $iterations; $i++) {
    $timer = Measure-Command {
        $hist = Get-History -Count 1
    }
    $totalTime += $timer.TotalMilliseconds
    Write-Host "  Iteration $i: $($timer.TotalMilliseconds)ms" -ForegroundColor DarkGray
}

$average = $totalTime / $iterations
Write-Host "`nAverage Get-History time: $([math]::Round($average, 2))ms" -ForegroundColor Yellow

if ($average -gt 1000) {
    Write-Host "WARNING: Get-History is very slow (>1s average)" -ForegroundColor Red
    Write-Host "This could be causing your prompt delays!" -ForegroundColor Red
} elseif ($average -gt 100) {
    Write-Host "NOTICE: Get-History is slow (>100ms average)" -ForegroundColor Yellow
} else {
    Write-Host "OK: Get-History is fast (<100ms average)" -ForegroundColor Green
}
