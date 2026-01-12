# Test LASTEXITCODE with import

Write-Host "=== Testing LASTEXITCODE ===" -ForegroundColor Cyan

$zigstoryBin = "F:\sandbox\zigstory\zig-out\bin\zigstory.exe"

Write-Host "Before running import - LASTEXITCODE: $LASTEXITCODE" -ForegroundColor Yellow

$result = & $zigstoryBin import --file tests/test_batch.json 2>&1

Write-Host "After running import - LASTEXITCODE: $LASTEXITCODE" -ForegroundColor Green
Write-Host "Result: $result" -ForegroundColor Gray
