# Test the batch import functionality for zigstory

Write-Host "`n=== Testing Batch Import Functionality ===`n" -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$zigstoryBin = Join-Path $scriptDir "..\zig-out\bin\zigstory.exe"

# Test 1: Create a JSON test file
Write-Host "Test 1: Creating JSON test file..." -ForegroundColor Yellow

$testJsonFile = [System.IO.Path]::GetTempFileName()
$testData = @(
    @{cmd = "echo 'hello'"; cwd = "C:\test"; exit_code = 0; duration_ms = 100},
    @{cmd = "ls -la"; cwd = "C:\test"; exit_code = 0; duration_ms = 50},
    @{cmd = "git status"; cwd = "C:\test"; exit_code = 1; duration_ms = 200}
)

$testData | ConvertTo-Json -Depth 3 | Out-File -FilePath $testJsonFile -Encoding utf8

Write-Host "  JSON file created: $testJsonFile" -ForegroundColor DarkGray

# Test 2: Import the JSON file
Write-Host "`nTest 2: Importing JSON file..." -ForegroundColor Yellow

$result = & $zigstoryBin import --file $testJsonFile 2>&1
Write-Host "  Result: $result" -ForegroundColor DarkGray

# Test 3: Verify entries were imported
Write-Host "`nTest 3: Listing imported entries..." -ForegroundColor Yellow

$listResult = & $zigstoryBin list 10 2>&1
Write-Host "  List result:" -ForegroundColor DarkGray
Write-Host "$listResult" -ForegroundColor Gray

# Test 4: Test with empty command (should be filtered by PowerShell, not Zig)
Write-Host "`nTest 4: Creating JSON with empty commands..." -ForegroundColor Yellow

$emptyTestJsonFile = [System.IO.Path]::GetTempFileName()
$emptyTestData = @(
    @{cmd = "test command"; cwd = "C:\test"; exit_code = 0; duration_ms = 100},
    @{cmd = "   "; cwd = "C:\test"; exit_code = 0; duration_ms = 50},
    @{cmd = "another command"; cwd = "C:\test"; exit_code = 0; duration_ms = 75}
)

$emptyTestData | ConvertTo-Json -Depth 3 | Out-File -FilePath $emptyTestJsonFile -Encoding utf8

$result2 = & $zigstoryBin import --file $emptyTestJsonFile 2>&1
Write-Host "  Result: $result2" -ForegroundColor DarkGray

# Cleanup
Remove-Item $testJsonFile -Force
Remove-Item $emptyTestJsonFile -Force

Write-Host "`n=== Tests Complete ===`n" -ForegroundColor Green
