# Test script for PowerShell profile integration
# This script tests the zigstory hook functionality

# Test configuration
$zigstoryBin = ".\zig-out\bin\zigstory.exe"
$testDbPath = "$env:USERPROFILE\.zigstory\history.db"

Write-Host "=== zigstory Profile Integration Test ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: Verify zigstory binary exists
Write-Host "[1/6] Checking zigstory binary..." -ForegroundColor Yellow
if (Test-Path $zigstoryBin) {
    Write-Host "  ✓ zigstory binary found at: $zigstoryBin" -ForegroundColor Green
}
else {
    Write-Host "  ✗ zigstory binary NOT found at: $zigstoryBin" -ForegroundColor Red
    exit 1
}

# Test 2: Verify database exists
Write-Host "[2/6] Checking database file..." -ForegroundColor Yellow
if (Test-Path $testDbPath) {
    Write-Host "  ✓ Database found at: $testDbPath" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Database NOT found at: $testDbPath" -ForegroundColor Red
    exit 1
}

# Test 3: Verify zsprofile.ps1 exists
Write-Host "[3/6] Checking zsprofile.ps1 script..." -ForegroundColor Yellow
$profileScript = ".\scripts\zsprofile.ps1"
if (Test-Path $profileScript) {
    Write-Host "  ✓ Profile script found at: $profileScript" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Profile script NOT found at: $profileScript" -ForegroundColor Red
    exit 1
}

# Test 4: Test direct add command
Write-Host "[4/6] Testing direct add command..." -ForegroundColor Yellow
$testCmd = "zigstory test command"
$testCwd = "f:\sandbox\zigstory"
$testExit = 0
$testDuration = 250

$testResult = & $zigstoryBin add --cmd $testCmd --cwd $testCwd --exit $testExit --duration $testDuration 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Add command executed successfully" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Add command failed: $testResult" -ForegroundColor Red
    exit 1
}

# Test 5: Verify data was stored
Write-Host "[5/6] Verifying data storage..." -ForegroundColor Yellow
$query = "SELECT COUNT(*) FROM history WHERE cmd = '$testCmd'"
$countResult = sqlite3 $testDbPath $query 2>&1
if ($countResult -match "^\d+$") {
    $count = [int]$countResult
    if ($count -gt 0) {
        Write-Host "  ✓ Data stored successfully (found $count matching records)" -ForegroundColor Green
    }
    else {
        Write-Host "  ✗ Data NOT found in database" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "  ✗ Query failed: $countResult" -ForegroundColor Red
    exit 1
}

# Test 6: Verify all required fields
Write-Host "[6/6] Verifying required fields..." -ForegroundColor Yellow
$query = "SELECT cmd, cwd, exit_code, duration_ms FROM history WHERE cmd = '$testCmd' ORDER BY id DESC LIMIT 1"
$result = sqlite3 $testDbPath $query 2>&1
if ($result) {
    $fields = $result -split '\|'
    if ($fields.Count -eq 4) {
        $storedCmd = $fields[0]
        $storedCwd = $fields[1]
        $storedExit = $fields[2]
        $storedDuration = $fields[3]
        
        Write-Host "  ✓ All fields present:" -ForegroundColor Green
        Write-Host "    - cmd: $storedCmd" -ForegroundColor Gray
        Write-Host "    - cwd: $storedCwd" -ForegroundColor Gray
        Write-Host "    - exit_code: $storedExit" -ForegroundColor Gray
        Write-Host "    - duration_ms: $storedDuration" -ForegroundColor Gray
    }
    else {
        Write-Host "  ✗ Invalid field count: $($fields.Count) (expected 4)" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "  ✗ Query failed: $result" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== All tests passed! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Profile.ps1 is ready to be integrated into your PowerShell profile." -ForegroundColor Cyan
Write-Host "To install, add this line to your PowerShell profile:" -ForegroundColor Cyan
Write-Host "  . $PSScriptRoot\scripts\zsprofile.ps1" -ForegroundColor White
Write-Host ""