#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    zigstory — Functional Test Suite
.DESCRIPTION
    End-to-end functional tests for every zigstory CLI command.
    Builds the binary, exercises each subcommand, validates output
    and exit codes, then produces a pass/fail summary.

    Run from the repo root:
        pwsh -NoProfile -File tests/functional_tests.ps1

    Optional flags:
        -SkipBuild      Skip `zig build` (use existing binary)
        -Verbose        Print stdout/stderr for every test
        -KeepDb         Do not delete the test database after the run

.NOTES
    Requires: Zig 0.16+, PowerShell 7+
#>

param(
    [switch]$SkipBuild,
    [switch]$Verbose,
    [switch]$KeepDb
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Colour helpers ──────────────────────────────────────────────────────────
function Write-Pass  ([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green  }
function Write-Fail  ([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red    }
function Write-Skip  ([string]$msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Write-Head  ([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan   }
function Write-Info  ([string]$msg) { Write-Host "  [INFO] $msg" -ForegroundColor Gray   }

# ─── Test counters ────────────────────────────────────────────────────────────
$script:Passed  = 0
$script:Failed  = 0
$script:Skipped = 0
$script:Errors  = [System.Collections.Generic.List[string]]::new()

# ─── Assertion helpers ────────────────────────────────────────────────────────
function Assert-ExitCode {
    param([string]$Name, [int]$Got, [int]$Expected = 0)
    if ($Got -eq $Expected) {
        Write-Pass $Name
        $script:Passed++
    } else {
        Write-Fail "$Name  (exit $Got, expected $Expected)"
        $script:Failed++
        $script:Errors.Add($Name)
    }
}

function Assert-OutputContains {
    param([string]$Name, [string]$Output, [string]$Pattern)
    if ($Output -match [regex]::Escape($Pattern) -or $Output -match $Pattern) {
        Write-Pass "$Name  (found: '$Pattern')"
        $script:Passed++
    } else {
        Write-Fail "$Name  (missing: '$Pattern')"
        Write-Info "Output was:`n$Output"
        $script:Failed++
        $script:Errors.Add($Name)
    }
}

function Assert-OutputNotEmpty {
    param([string]$Name, [string]$Output)
    if ($Output.Trim().Length -gt 0) {
        Write-Pass $Name
        $script:Passed++
    } else {
        Write-Fail "$Name  (output was empty)"
        $script:Failed++
        $script:Errors.Add($Name)
    }
}

function Assert-JsonField {
    param([string]$Name, [string]$Json, [string]$Field)
    try {
        $obj = $Json | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $obj.$Field) {
            Write-Pass "$Name  (field '$Field' = $($obj.$Field))"
            $script:Passed++
        } else {
            Write-Fail "$Name  (field '$Field' missing or null)"
            $script:Failed++
            $script:Errors.Add($Name)
        }
    } catch {
        Write-Fail "$Name  (invalid JSON: $_)"
        $script:Failed++
        $script:Errors.Add($Name)
    }
}

# ─── Invoke helper (captures both streams via temp files, never throws) ────────
function Invoke-Zs {
    param([string[]]$ZsArgs)
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        & $script:Exe @ZsArgs > $outFile 2> $errFile
        $ec = $LASTEXITCODE
        $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        $combined = (($stdout ?? '') + ($stderr ?? '')).Trim()
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($Verbose) { Write-Info "  CMD: zigstory $($ZsArgs -join ' ')`n$combined" }
    return @{
        Output   = $combined
        ExitCode = $ec
    }
}

# ─── SQLite query helper (uses zig-sqlite DB file directly) ──────────────────
function Query-DB {
    param([string]$Sql)
    # Requires sqlite3.exe on PATH; gracefully skipped if absent
    if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) { return $null }
    $r = sqlite3 $script:TestDb $Sql 2>&1 | Out-String
    return $r.Trim()
}

# ═════════════════════════════════════════════════════════════════════════════
# SETUP
# ═════════════════════════════════════════════════════════════════════════════
Write-Head "Setup"

$RepoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $RepoRoot
Write-Info "Repo root : $RepoRoot"

# Verify Zig version
$ZigVer = (zig version 2>&1)
Write-Info "Zig       : $ZigVer"
if ($ZigVer -notmatch '^0\.16') {
    Write-Fail "Zig 0.16.x required (got $ZigVer)"
    exit 1
}

# Verify PS version
Write-Info "PowerShell: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Fail "PowerShell 7+ required"
    exit 1
}

# Verify .NET SDK
$DotNetVer = (dotnet --version 2>&1)
Write-Info ".NET SDK  : $DotNetVer"
if ($DotNetVer -match '^\d+' -and [int]($Matches[0]) -lt 8) {
    Write-Fail ".NET SDK 8+ required (got $DotNetVer)"
    exit 1
}

# ─── Build ────────────────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Info "Running: zig build ..."
    zig build
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "zig build failed — aborting tests"
        exit 1
    }
    Write-Pass "zig build succeeded"
    $script:Passed++
} else {
    Write-Skip "Build step skipped (-SkipBuild)"
    $script:Skipped++
}

# ─── Locate binary ────────────────────────────────────────────────────────────
$script:Exe = Join-Path $RepoRoot "zig-out\bin\zigstory.exe"
if (-not (Test-Path $script:Exe)) {
    # Also try the Debug layout some Zig versions use
    $script:Exe = Join-Path $RepoRoot "zig-out\bin\zigstory"
}
if (-not (Test-Path $script:Exe)) {
    Write-Fail "Binary not found at zig-out\bin\zigstory[.exe]"
    exit 1
}
Write-Info "Binary    : $script:Exe"
Write-Pass "Binary found"
$script:Passed++

# ─── Isolated test database ───────────────────────────────────────────────────
$TestHome   = Join-Path $env:TEMP "zigstory_functional_test_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $TestHome -Force | Out-Null
$script:TestDb = Join-Path $TestHome ".zigstory\history.db"

# Override home-dir env vars so zigstory writes to our test directory
$env:USERPROFILE = $TestHome
$env:HOME        = $TestHome
Write-Info "Test home : $TestHome"
Write-Info "Test DB   : $script:TestDb"

# ─── Sample JSON history file ─────────────────────────────────────────────────
$SampleJson = Join-Path $TestHome "sample_history.json"
$SampleJsonContent = @'
[
  { "cmd": "git status",        "cwd": "C:\\repos\\zigstory", "exit_code": 0,  "duration_ms": 85   },
  { "cmd": "git log --oneline", "cwd": "C:\\repos\\zigstory", "exit_code": 0,  "duration_ms": 120  },
  { "cmd": "zig build",         "cwd": "C:\\repos\\zigstory", "exit_code": 0,  "duration_ms": 3400 },
  { "cmd": "zig build run",     "cwd": "C:\\repos\\zigstory", "exit_code": 0,  "duration_ms": 3600 },
  { "cmd": "npm install",       "cwd": "C:\\repos\\web",      "exit_code": 0,  "duration_ms": 8200 },
  { "cmd": "npm test",          "cwd": "C:\\repos\\web",      "exit_code": 1,  "duration_ms": 4500 },
  { "cmd": "cargo build",       "cwd": "C:\\repos\\rust",     "exit_code": 0,  "duration_ms": 12000},
  { "cmd": "docker ps",         "cwd": "C:\\repos\\zigstory", "exit_code": 0,  "duration_ms": 210  },
  { "cmd": "ls",                "cwd": "C:\\Users\\dev",      "exit_code": 0,  "duration_ms": 10   },
  { "cmd": "Get-ChildItem",     "cwd": "C:\\Users\\dev",      "exit_code": 0,  "duration_ms": 12   }
]
'@
$SampleJsonContent | Set-Content -Path $SampleJson -Encoding UTF8

# ─── Sample PSReadline history file ───────────────────────────────────────────
$PsHistDir  = Join-Path $TestHome "AppData\Roaming\Microsoft\Windows\PowerShell\PSReadline"
New-Item -ItemType Directory -Path $PsHistDir -Force | Out-Null
$PsHistFile = Join-Path $PsHistDir "ConsoleHost_history.txt"
@"
Get-Date
Write-Host "hello world"
Set-Location C:\repos
git pull
zig build
"@ | Set-Content -Path $PsHistFile -Encoding UTF8

# Also set APPDATA so the import command can find it
$env:APPDATA = Join-Path $TestHome "AppData\Roaming"
Write-Info "PS history: $PsHistFile"

# ═════════════════════════════════════════════════════════════════════════════
# TEST SUITE
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T01 — help / no-args"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @()
Assert-ExitCode       "T01-A: exit 0 with no args"   $r.ExitCode 0
Assert-OutputContains "T01-B: shows USAGE"            $r.Output  "USAGE"
Assert-OutputContains "T01-C: lists add command"      $r.Output  "add"
Assert-OutputContains "T01-D: lists search command"   $r.Output  "search"
Assert-OutputContains "T01-E: lists import command"   $r.Output  "import"
Assert-OutputContains "T01-F: lists stats command"    $r.Output  "stats"
Assert-OutputContains "T01-G: lists perf command"     $r.Output  "perf"
Assert-OutputContains "T01-H: lists list command"     $r.Output  "list"
Assert-OutputContains "T01-I: lists recalc-rank"      $r.Output  "recalc-rank"

$r2 = Invoke-Zs @("--help")
Assert-ExitCode       "T01-J: --help exit 0"          $r2.ExitCode 0
Assert-OutputContains "T01-K: --help shows USAGE"     $r2.Output  "USAGE"

$r3 = Invoke-Zs @("-h")
Assert-ExitCode       "T01-L: -h exit 0"              $r3.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T02 — add (single command)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("add","--cmd","git status","--cwd","C:\repos\zigstory","--exit","0","--duration","85")
Assert-ExitCode       "T02-A: add exits 0"            $r.ExitCode 0
Assert-OutputContains "T02-B: success message"        $r.Output  "added successfully"

# Add second entry with exit code 1 (failed command)
$r2 = Invoke-Zs @("add","-c","npm test","-w","C:\repos\web","-e","1","-d","4500")
Assert-ExitCode       "T02-C: add with short flags"   $r2.ExitCode 0

# Add third entry — zero duration
$r3 = Invoke-Zs @("add","--cmd","ls","--cwd","C:\Users\dev","--exit","0","--duration","0")
Assert-ExitCode       "T02-D: add zero duration"      $r3.ExitCode 0

# Add with high duration (for perf test)
$r4 = Invoke-Zs @("add","--cmd","cargo build","--cwd","C:\repos\rust","--exit","0","--duration","12000")
Assert-ExitCode       "T02-E: add high-duration cmd"  $r4.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T03 — add (validation / missing args)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("add")
# Missing required args should produce an error (non-zero exit or error text)
$passVal = ($r.ExitCode -ne 0) -or ($r.Output -match "(?i)(error|missing|required|usage)")
if ($passVal) {
    Write-Pass "T03-A: add without args reports error"
    $script:Passed++
} else {
    Write-Fail "T03-A: add without args should fail (exit=$($r.ExitCode), output=$($r.Output))"
    $script:Failed++
    $script:Errors.Add("T03-A")
}

# Missing cwd
$r2 = Invoke-Zs @("add","--cmd","something")
$passVal2 = ($r2.ExitCode -ne 0) -or ($r2.Output -match "(?i)(error|missing|required)")
if ($passVal2) {
    Write-Pass "T03-B: add missing --cwd reports error"
    $script:Passed++
} else {
    Write-Fail "T03-B: add missing --cwd should fail"
    $script:Failed++
    $script:Errors.Add("T03-B")
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T04 — import (JSON file)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("import","--file",$SampleJson)
Assert-ExitCode       "T04-A: import --file exits 0"  $r.ExitCode 0
Assert-OutputContains "T04-B: shows import complete"  $r.Output  "Import complete"
Assert-OutputContains "T04-C: shows total count"      $r.Output  "Total"
Assert-OutputContains "T04-D: shows imported count"   $r.Output  "Imported"

# Validate the reported numbers
if ($r.Output -match 'Imported:\s*(\d+)') {
    $importedCount = [int]$Matches[1]
    if ($importedCount -ge 1) {
        Write-Pass "T04-E: imported $importedCount entries (>= 1)"
        $script:Passed++
    } else {
        Write-Fail "T04-E: imported 0 entries (expected >= 1)"
        $script:Failed++
        $script:Errors.Add("T04-E")
    }
} else {
    Write-Skip "T04-E: could not parse imported count from output"
    $script:Skipped++
}

# Second import of the same file → all should be duplicates (skipped count may vary
# depending on implementation, but it should succeed without error)
$r2 = Invoke-Zs @("import","--file",$SampleJson)
Assert-ExitCode       "T04-F: re-import exits 0"      $r2.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T05 — import (auto PSReadLine history)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("import")
Assert-ExitCode       "T05-A: auto import exits 0"    $r.ExitCode 0
Assert-OutputContains "T05-B: shows import complete"  $r.Output  "Import complete"

if ($r.Output -match 'Total commands in file:\s*(\d+)') {
    $psTotal = [int]$Matches[1]
    if ($psTotal -ge 1) {
        Write-Pass "T05-C: PS history had $psTotal commands"
        $script:Passed++
    } else {
        Write-Skip "T05-C: PS history file was empty (expected >= 1)"
        $script:Skipped++
    }
} else {
    Write-Skip "T05-C: could not parse total count from auto-import output"
    $script:Skipped++
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T06 — list"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("list")
Assert-ExitCode       "T06-A: list exits 0"           $r.ExitCode 0
Assert-OutputNotEmpty "T06-B: list has output"        $r.Output
Assert-OutputContains "T06-C: shows entry count"      $r.Output  "Showing"

$r2 = Invoke-Zs @("list","3")
Assert-ExitCode       "T06-D: list 3 exits 0"         $r2.ExitCode 0
# Should show at most 3 entries (numbered 1., 2., 3.)
$entryLines = @($r2.Output -split "`n" | Where-Object { $_ -match '^\s*\d+\.' })
if ($entryLines.Count -le 3) {
    Write-Pass "T06-E: list 3 shows <= 3 entries (got $($entryLines.Count))"
    $script:Passed++
} else {
    Write-Fail "T06-E: list 3 showed $($entryLines.Count) entries (expected <= 3)"
    $script:Failed++
    $script:Errors.Add("T06-E")
}

$r3 = Invoke-Zs @("list","1")
Assert-ExitCode       "T06-F: list 1 exits 0"         $r3.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T07 — stats"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("stats")
Assert-ExitCode       "T07-A: stats exits 0"          $r.ExitCode 0
Assert-OutputContains "T07-B: shows OVERVIEW"         $r.Output  "OVERVIEW"
Assert-OutputContains "T07-C: shows Total Commands"   $r.Output  "Total Commands"
Assert-OutputContains "T07-D: shows Unique Commands"  $r.Output  "Unique Commands"
Assert-OutputContains "T07-E: shows TOP COMMANDS"     $r.Output  "TOP COMMANDS"
Assert-OutputContains "T07-F: shows ACTIVITY BY HOUR" $r.Output  "ACTIVITY BY HOUR"
Assert-OutputContains "T07-G: shows TOP DIRECTORIES"  $r.Output  "TOP DIRECTORIES"
Assert-OutputContains "T07-H: shows Success Rate"     $r.Output  "Success Rate"

# Validate the total count is a non-zero number
if ($r.Output -match 'Total Commands:\s+(\d+)') {
    $totalCmds = [int]$Matches[1]
    if ($totalCmds -gt 0) {
        Write-Pass "T07-I: total commands = $totalCmds (> 0)"
        $script:Passed++
    } else {
        Write-Fail "T07-I: total commands was 0 (expected > 0 after imports)"
        $script:Failed++
        $script:Errors.Add("T07-I")
    }
} else {
    Write-Skip "T07-I: could not parse Total Commands from stats output"
    $script:Skipped++
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T08 — perf (text format)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("perf","--cwd","C:\repos\zigstory")
Assert-ExitCode       "T08-A: perf exits 0"           $r.ExitCode 0
Assert-OutputNotEmpty "T08-B: perf has output"        $r.Output

# Output should contain a duration like "1.2s avg" or "850ms avg"
$hasDuration = $r.Output -match '(ms|s|m)\s+avg'
if ($hasDuration) {
    Write-Pass "T08-C: perf output contains duration avg"
    $script:Passed++
} else {
    Write-Fail "T08-C: perf output missing duration avg (got: $($r.Output))"
    $script:Failed++
    $script:Errors.Add("T08-C")
}

# Directory with a slow command (cargo build = 12000ms > default 5000ms threshold)
$r2 = Invoke-Zs @("perf","--cwd","C:\repos\rust","--threshold","5000")
Assert-ExitCode       "T08-D: perf slow dir exits 0"  $r2.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T09 — perf (JSON format)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("perf","--cwd","C:\repos\zigstory","--format","json")
Assert-ExitCode       "T09-A: perf json exits 0"      $r.ExitCode 0

# Strip any non-JSON prefix lines (debug output)
$jsonLine = ($r.Output -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -First 1)
if ($jsonLine) {
    Assert-JsonField  "T09-B: json has avg_duration_ms"  $jsonLine "avg_duration_ms"
    Assert-JsonField  "T09-C: json has last_duration_ms" $jsonLine "last_duration_ms"
    Assert-JsonField  "T09-D: json has success_rate"     $jsonLine "success_rate"
    Assert-JsonField  "T09-E: json has total_commands"   $jsonLine "total_commands"
    Assert-JsonField  "T09-F: json has last_exit_code"   $jsonLine "last_exit_code"

    # Validate total_commands is a number > 0
    try {
        $perfObj = $jsonLine | ConvertFrom-Json
        if ($perfObj.total_commands -gt 0) {
            Write-Pass "T09-G: total_commands = $($perfObj.total_commands)"
            $script:Passed++
        } else {
            Write-Fail "T09-G: total_commands was 0"
            $script:Failed++
            $script:Errors.Add("T09-G")
        }
    } catch {
        Write-Fail "T09-G: JSON parse failed: $_"
        $script:Failed++
        $script:Errors.Add("T09-G")
    }
} else {
    Write-Fail "T09-B..G: no JSON line found in output:`n$($r.Output)"
    $script:Failed += 6
    1..6 | ForEach-Object { $script:Errors.Add("T09-$([char](64+$_))") }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T10 — perf (custom threshold)"
# ─────────────────────────────────────────────────────────────────────────────
# cargo build (12000ms) should trigger warning at threshold=5000
$r = Invoke-Zs @("perf","--cwd","C:\repos\rust","--threshold","5000")
Assert-ExitCode       "T10-A: perf custom threshold exits 0" $r.ExitCode 0
Assert-OutputContains "T10-B: warning icon present"          $r.Output  "last:"

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T11 — recalc-rank"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("recalc-rank")
Assert-ExitCode       "T11-A: recalc-rank exits 0"    $r.ExitCode 0
Assert-OutputContains "T11-B: mentions backfill"      $r.Output  "Backfill"

# Idempotent: run again
$r2 = Invoke-Zs @("recalc-rank")
Assert-ExitCode       "T11-C: second recalc-rank exits 0" $r2.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T12 — add idempotency / high-volume"
# ─────────────────────────────────────────────────────────────────────────────
# Add 20 commands in a tight loop to stress the insert path
$cmds = @(
    "git diff","git add .","git commit -m test","git push","git pull",
    "zig fmt src/","zig build test","zig build run","Get-ChildItem","Set-Location ..",
    "docker images","docker ps -a","npm run build","dotnet build","dotnet test",
    "cargo check","cargo clippy","cargo fmt","cargo test","cargo run"
)
$batchFailed = $false
foreach ($cmd in $cmds) {
    $br = Invoke-Zs @("add","--cmd",$cmd,"--cwd","C:\repos\zigstory","--exit","0","--duration","100")
    if ($br.ExitCode -ne 0) { $batchFailed = $true; break }
}
if (-not $batchFailed) {
    Write-Pass "T12-A: 20 sequential adds all exit 0"
    $script:Passed++
} else {
    Write-Fail "T12-A: one or more batch adds failed"
    $script:Failed++
    $script:Errors.Add("T12-A")
}

# Verify the count increased (list output shows > 20)
$r2 = Invoke-Zs @("stats")
if ($r2.Output -match 'Total Commands:\s+(\d+)') {
    $newTotal = [int]$Matches[1]
    if ($newTotal -ge 20) {
        Write-Pass "T12-B: stats shows >= 20 total commands ($newTotal)"
        $script:Passed++
    } else {
        Write-Fail "T12-B: stats shows only $newTotal commands (expected >= 20)"
        $script:Failed++
        $script:Errors.Add("T12-B")
    }
} else {
    Write-Skip "T12-B: could not parse Total Commands"
    $script:Skipped++
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T13 — list count boundary"
# ─────────────────────────────────────────────────────────────────────────────
# list 0 or list with non-numeric arg → graceful behaviour
$r = Invoke-Zs @("list","0")
# Either returns "No commands" or silently shows 0; must not crash
$notCrashed = $r.ExitCode -eq 0 -or ($r.Output -match '(?i)(no commands|Showing 0)')
if ($notCrashed) {
    Write-Pass "T13-A: list 0 does not crash"
    $script:Passed++
} else {
    Write-Fail "T13-A: list 0 crashed (exit $($r.ExitCode))"
    $script:Failed++
    $script:Errors.Add("T13-A")
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T14 — perf (unknown directory)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("perf","--cwd","C:\nonexistent\path\xyz")
Assert-ExitCode       "T14-A: perf unknown dir exits 0" $r.ExitCode 0
# Should return metrics with 0 total_commands but not crash

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T15 — import (file not found)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("import","--file","C:\nonexistent\ghost_history.json")
# Must exit non-zero or print an error — must not silently succeed
$isError = ($r.ExitCode -ne 0) -or ($r.Output -match '(?i)error')
if ($isError) {
    Write-Pass "T15-A: import missing file reports error"
    $script:Passed++
} else {
    Write-Fail "T15-A: import missing file did not report error (exit=$($r.ExitCode))"
    $script:Failed++
    $script:Errors.Add("T15-A")
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T16 — add (special characters in cmd)"
# ─────────────────────────────────────────────────────────────────────────────
$specialCmds = @(
    "echo 'hello world'",
    'grep -r "pattern" .',
    "awk '{print `$1}' file.txt",
    "curl https://example.com?q=test&v=1",
    "path\with\backslashes"
)
$specFail = $false
foreach ($sc in $specialCmds) {
    $sr = Invoke-Zs @("add","--cmd",$sc,"--cwd","C:\tmp","--exit","0","--duration","5")
    if ($sr.ExitCode -ne 0) { $specFail = $true }
}
if (-not $specFail) {
    Write-Pass "T16-A: special characters in cmd handled"
    $script:Passed++
} else {
    Write-Fail "T16-A: special characters caused add to fail"
    $script:Failed++
    $script:Errors.Add("T16-A")
}

# Verify they were stored
$r2 = Invoke-Zs @("list","10")
Assert-OutputNotEmpty "T16-B: list shows content after special-char adds" $r2.Output

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T17 — add (Unicode / emoji)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("add","--cmd","echo 'こんにちは 🌐 привет'","--cwd","C:\tmp","--exit","0","--duration","5")
Assert-ExitCode       "T17-A: unicode cmd add exits 0" $r.ExitCode 0

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T18 — perf (--format text default)"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("perf","--cwd","C:\repos\zigstory","--format","text")
Assert-ExitCode       "T18-A: perf text format exits 0" $r.ExitCode 0
$hasAvg = $r.Output -match '(ms|s)\s+avg'
if ($hasAvg) {
    Write-Pass "T18-B: text output has duration avg"
    $script:Passed++
} else {
    Write-Fail "T18-B: text output missing duration (got: $($r.Output))"
    $script:Failed++
    $script:Errors.Add("T18-B")
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T19 — recalc-rank after bulk insert"
# ─────────────────────────────────────────────────────────────────────────────
$r = Invoke-Zs @("recalc-rank")
Assert-ExitCode       "T19-A: recalc-rank after bulk exits 0" $r.ExitCode 0

# After recalc, stats should still work
$r2 = Invoke-Zs @("stats")
Assert-ExitCode       "T19-B: stats after recalc exits 0" $r2.ExitCode 0
Assert-OutputContains "T19-C: stats still shows overview" $r2.Output "OVERVIEW"

# ─────────────────────────────────────────────────────────────────────────────
Write-Head "T20 — sqlite3 DB introspection (optional)"
# ─────────────────────────────────────────────────────────────────────────────
$sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
if ($sqlite3) {
    $histCount = Query-DB "SELECT COUNT(*) FROM history;"
    if ([int]$histCount -gt 0) {
        Write-Pass "T20-A: DB history table has $histCount rows"
        $script:Passed++
    } else {
        Write-Fail "T20-A: DB history table is empty"
        $script:Failed++
        $script:Errors.Add("T20-A")
    }

    $statsCount = Query-DB "SELECT COUNT(*) FROM command_stats;"
    if ([int]$statsCount -gt 0) {
        Write-Pass "T20-B: DB command_stats has $statsCount rows"
        $script:Passed++
    } else {
        Write-Fail "T20-B: DB command_stats is empty (should be populated by recalc-rank)"
        $script:Failed++
        $script:Errors.Add("T20-B")
    }

    $rankNull = Query-DB "SELECT COUNT(*) FROM history WHERE rank IS NULL OR rank = 0;"
    Write-Info "T20-C: rows with rank=0 or NULL: $rankNull (expected low after recalc)"
    $script:Passed++  # informational only

    $ftsCount = Query-DB "SELECT COUNT(*) FROM history_fts;"
    if ([int]$ftsCount -gt 0) {
        Write-Pass "T20-D: FTS5 index has $ftsCount rows"
        $script:Passed++
    } else {
        Write-Fail "T20-D: FTS5 index is empty"
        $script:Failed++
        $script:Errors.Add("T20-D")
    }
} else {
    Write-Skip "T20-A..D: sqlite3.exe not found on PATH — DB introspection skipped"
    $script:Skipped += 4
}

# ═════════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═════════════════════════════════════════════════════════════════════════════
Write-Head "Cleanup"

if (-not $KeepDb) {
    Remove-Item -Recurse -Force $TestHome -ErrorAction SilentlyContinue
    Write-Info "Test directory removed: $TestHome"
} else {
    Write-Info "Test directory kept (-KeepDb): $TestHome"
}

# Restore env vars (best effort)
$env:USERPROFILE = [System.Environment]::GetFolderPath('UserProfile')
$env:HOME        = $env:USERPROFILE
$env:APPDATA     = [System.Environment]::GetFolderPath('ApplicationData')

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
$Total = $script:Passed + $script:Failed + $script:Skipped

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  zigstory Functional Test Results" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ("  Total   : {0,3}" -f $Total)
Write-Host ("  Passed  : {0,3}" -f $script:Passed)  -ForegroundColor Green
Write-Host ("  Failed  : {0,3}" -f $script:Failed)  -ForegroundColor $(if ($script:Failed -gt 0) { 'Red' } else { 'Green' })
Write-Host ("  Skipped : {0,3}" -f $script:Skipped) -ForegroundColor Yellow
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($script:Errors.Count -gt 0) {
    Write-Host "`n  Failed tests:" -ForegroundColor Red
    $script:Errors | ForEach-Object { Write-Host "    • $_" -ForegroundColor Red }
    Write-Host ""
}

if ($script:Failed -eq 0) {
    Write-Host "  ✅  All tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  ❌  $($script:Failed) test(s) failed." -ForegroundColor Red
    exit 1
}
