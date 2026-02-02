# ----------------------------------------------------------------------------
# zigstory Installation Script for Windows
# ----------------------------------------------------------------------------

param(
    [switch]$Force,
    [switch]$SkipProfile
)

# Script root
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot

Write-Host "=== zigstory Installation ===" -ForegroundColor Cyan
Write-Host "Repository root: $RepoRoot" -ForegroundColor Gray
Write-Host ""

# ----------------------------------------------------------------------------
# Step 1: Determine PowerShell 7 profile locations
# ----------------------------------------------------------------------------

Write-Host "[Step 1/7] Locating PowerShell 7 profile directories..." -ForegroundColor Yellow

# PowerShell 7 (pwsh) uses different paths than Windows PowerShell (powershell)
# The profile for PowerShell 7 is typically:
# $PROFILE.CurrentUserCurrentHost for current user
# Common locations:
# - $env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1

# Check if we're running in PowerShell 7
$IsPwsh = $PSVersionTable.PSVersion.Major -ge 7

if ($IsPwsh) {
    Write-Host "  Running in PowerShell 7+" -ForegroundColor Green
    $ProfilePath = $PROFILE.CurrentUserCurrentHost
} else {
    Write-Host "  ! Not running in PowerShell 7, installing for PowerShell 7 profile location" -ForegroundColor Yellow
    # Manually construct the PowerShell 7 profile path
    $ProfilePath = Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
}

$ProfileDir = Split-Path -Parent $ProfilePath
Write-Host "  Profile directory: $ProfileDir" -ForegroundColor Gray
Write-Host "  Profile file:      $ProfilePath" -ForegroundColor Gray

# Create profile directory if it doesn't exist
if (-not (Test-Path $ProfileDir)) {
    Write-Host "  Creating profile directory..." -ForegroundColor Gray
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    Write-Host "  Profile directory created" -ForegroundColor Green
} else {
    Write-Host "  Profile directory exists" -ForegroundColor Green
}

Write-Host ""

# ----------------------------------------------------------------------------
# Step 2: Copy zigstory executable to APPDATA
# ----------------------------------------------------------------------------

Write-Host "[Step 2/7] Copying zigstory executable to APPDATA..." -ForegroundColor Yellow

# APPDATA installation directory
$AppDataDir = Join-Path $env:APPDATA "zigstory"
$AppDataExe = Join-Path $AppDataDir "zigstory.exe"

# Find the zigstory executable in the repository
$PossibleExePaths = @(
    (Join-Path $RepoRoot "zig-out\bin\zigstory.exe"),
    (Join-Path $RepoRoot "zig-out\bin\zigstory")
)

$FoundExe = $null
foreach ($exePath in $PossibleExePaths) {
    if (Test-Path $exePath) {
        $FoundExe = $exePath
        break
    }
}

if ($FoundExe) {
    Write-Host "  Found zigstory executable: $FoundExe" -ForegroundColor Gray
    
    # Create APPDATA directory if it doesn't exist
    if (-not (Test-Path $AppDataDir)) {
        New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
        Write-Host "  Created APPDATA directory: $AppDataDir" -ForegroundColor Gray
    }
    
    # Copy the executable
    Copy-Item -Path $FoundExe -Destination $AppDataExe -Force
    Write-Host "  Copied zigstory.exe to: $AppDataExe" -ForegroundColor Green
} else {
    Write-Host "  ! zigstory executable not found in expected locations" -ForegroundColor Yellow
    Write-Host "    Searched in:" -ForegroundColor Gray
    foreach ($path in $PossibleExePaths) {
        Write-Host "      - $path" -ForegroundColor Gray
    }
    Write-Host "  Run 'zig build' to build zigstory" -ForegroundColor Yellow
}

Write-Host ""

# ----------------------------------------------------------------------------
# Step 3: Add zigstory to PATH environment variable
# ----------------------------------------------------------------------------

Write-Host "[Step 3/7] Checking PATH environment variable..." -ForegroundColor Yellow

# Get current PATH for both current process and user
$CurrentPath = [Environment]::GetEnvironmentVariable("Path", "User")
$ProcessPath = [Environment]::GetEnvironmentVariable("Path", "Process")

# Check if APPDATA zigstory directory is in PATH
$PathAdded = $false

# Normalize paths for comparison
$NormalizedAppDataDir = $AppDataDir.TrimEnd('\')
$NormalizedCurrentPath = $CurrentPath -split ';' | ForEach-Object { $_.TrimEnd('\') }
$NormalizedProcessPath = $ProcessPath -split ';' | ForEach-Object { $_.TrimEnd('\') }

# Check user PATH
if ($NormalizedCurrentPath -contains $NormalizedAppDataDir) {
    Write-Host "  zigstory already in user PATH" -ForegroundColor Green
    $PathAdded = $true
} else {
    # Check process PATH
    if ($NormalizedProcessPath -contains $NormalizedAppDataDir) {
        Write-Host "  zigstory already in current process PATH" -ForegroundColor Green
        $PathAdded = $true
    }
}

# Add to PATH if not present
if (-not $PathAdded) {
    try {
        # Add to user PATH (persistent)
        $NewPath = $CurrentPath + ";" + $AppDataDir
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        
        # Add to current process PATH (immediate effect)
        $ProcessNewPath = $ProcessPath + ";" + $AppDataDir
        [Environment]::SetEnvironmentVariable("Path", $ProcessNewPath, "Process")
        
        Write-Host "  Added $AppDataDir to PATH" -ForegroundColor Green
        Write-Host "  ! Note: PATH changes will take effect in new terminal sessions" -ForegroundColor Yellow
    } catch {
        Write-Host "  ! Failed to add to PATH" -ForegroundColor Yellow
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    You may need administrator privileges" -ForegroundColor Yellow
    }
}

Write-Host ""

# ----------------------------------------------------------------------------
# Step 4: Copy zsprofile.ps1 to profile directory
# ----------------------------------------------------------------------------

Write-Host "[Step 4/7] Copying zsprofile.ps1 to profile directory..." -ForegroundColor Yellow

$ZsProfileSource = Join-Path $ScriptRoot "zsprofile.ps1"
$ZsProfileDest = Join-Path $ProfileDir "zsprofile.ps1"

if (Test-Path $ZsProfileSource) {
    # Just copy the profile - it now auto-detects paths
    Copy-Item -Path $ZsProfileSource -Destination $ZsProfileDest -Force
    Write-Host "  Copied zsprofile.ps1 (auto-detects paths)" -ForegroundColor Green
} else {
    Write-Host "  Source file not found: $ZsProfileSource" -ForegroundColor Red
    exit 1
}

Write-Host ""

# ----------------------------------------------------------------------------
# Step 5: Copy predictor DLL to Modules directory
# ----------------------------------------------------------------------------

Write-Host "[Step 5/7] Installing predictor module..." -ForegroundColor Yellow

# PowerShell 7 modules directory
$ModulesDir = Join-Path $env:USERPROFILE "Documents\PowerShell\Modules"
$PredictorModuleDir = Join-Path $ModulesDir "zigstoryPredictor"

# Find the predictor DLL
$PossibleDllPaths = @(
    (Join-Path $RepoRoot "src\predictor\bin\publish\zigstoryPredictor.dll"),
    (Join-Path $RepoRoot "src\predictor\bin\Release\net8.0\zigstoryPredictor.dll"),
    (Join-Path $RepoRoot "src\predictor\bin\Debug\net8.0\zigstoryPredictor.dll")
)

$FoundDll = $null
foreach ($dllPath in $PossibleDllPaths) {
    if (Test-Path $dllPath) {
        $FoundDll = $dllPath
        break
    }
}

if ($FoundDll) {
    Write-Host "  Found predictor DLL: $FoundDll" -ForegroundColor Gray
    
    # Get the source directory
    $SourceDir = Split-Path -Parent $FoundDll
    
    # Create module directory
    if (-not (Test-Path $PredictorModuleDir)) {
        New-Item -ItemType Directory -Path $PredictorModuleDir -Force | Out-Null
        Write-Host "  Created module directory: $PredictorModuleDir" -ForegroundColor Gray
    }
    
    # Copy all DLLs from source directory
    $DllFiles = Get-ChildItem -Path $SourceDir -Filter "*.dll" -ErrorAction SilentlyContinue
    $CopiedCount = 0
    $FailedCount = 0
    $NeedsRestart = $false
    foreach ($dllFile in $DllFiles) {
        $destFile = Join-Path $PredictorModuleDir $dllFile.Name
        try {
            # Try to copy directly first
            Copy-Item -Path $dllFile.FullName -Destination $PredictorModuleDir -Force -ErrorAction Stop
            $CopiedCount++
        } catch {
            # If it fails (likely due to file lock), try the rename trick
            if ($_.Exception.Message -match "used by another process" -and (Test-Path $destFile)) {
                try {
                    $oldFile = "$destFile.old"
                    if (Test-Path $oldFile) { Remove-Item $oldFile -Force -ErrorAction SilentlyContinue }
                    Rename-Item -Path $destFile -NewName "$($dllFile.Name).old" -Force -ErrorAction Stop
                    Copy-Item -Path $dllFile.FullName -Destination $PredictorModuleDir -Force -ErrorAction Stop
                    $CopiedCount++
                    $NeedsRestart = $true
                } catch {
                    Write-Host "  ! Error: Cannot update $($dllFile.Name) even with rename. File is heavily locked." -ForegroundColor Red
                    $FailedCount++
                }
            } else {
                Write-Host "  ! Error copying $($dllFile.Name): $($_.Exception.Message)" -ForegroundColor Red
                $FailedCount++
            }
        }
    }

    if ($FailedCount -gt 0) {
        Write-Host "  ! Some files could not be updated. Please close all other PowerShell windows and try again." -ForegroundColor Yellow
    }
    
    if ($CopiedCount -gt 0) {
        Write-Host "  Successfully copied $CopiedCount DLL(s) to: $PredictorModuleDir" -ForegroundColor Green
        if ($NeedsRestart) {
            Write-Host "  ! Note: Some files were updated using the rename trick. A restart of PowerShell is REQUIRED for changes to take effect." -ForegroundColor Yellow
        }
    }

    if ($CopiedCount -eq 0 -and $DllFiles.Count -gt 0) {
        Write-Host "  ! Failed to copy any DLLs. Installation may be incomplete." -ForegroundColor Red
    }
} else {
    Write-Host "  ! Predictor DLL not found in expected locations" -ForegroundColor Yellow
    Write-Host "    Searched in:" -ForegroundColor Gray
    foreach ($path in $PossibleDllPaths) {
        Write-Host "      - $path" -ForegroundColor Gray
    }
    Write-Host "  Run 'dotnet publish' in src\predictor to build the predictor" -ForegroundColor Yellow
}

Write-Host ""

# ----------------------------------------------------------------------------
# Step 6: Add zsprofile import to PowerShell profile
# ----------------------------------------------------------------------------

if ($SkipProfile) {
    Write-Host "[Step 6/7] Skipping profile modification (--SkipProfile specified)" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "[Step 6/7] Adding zsprofile to PowerShell profile..." -ForegroundColor Yellow

    $ImportLine = ". `"$ZsProfileDest`""
    $ProfileExists = Test-Path $ProfilePath
    $ProfileContent = ""

    if ($ProfileExists) {
        $ProfileContent = Get-Content $ProfilePath -Raw
    }

    # Check if import line already exists
    $ImportExists = $ProfileContent -match [regex]::Escape($ImportLine)

    if ($ImportExists) {
        Write-Host "  zsprofile already imported in profile" -ForegroundColor Green
    } else {
        # Append the import line
        $NewContent = ""
        if ($ProfileExists -and $ProfileContent -ne "") {
            # Check if there's a newline at the end
            if (-not $ProfileContent.EndsWith("`n")) {
                $NewContent = $ProfileContent + "`n`n"
            } else {
                $NewContent = $ProfileContent + "`n"
            }
        }
        
        $NewContent += "# ----------------------------------------------------------------------------`n"
        $NewContent += "# zigstory Integration`n"
        $NewContent += "# ----------------------------------------------------------------------------`n"
        $NewContent += $ImportLine + "`n"
        
        Set-Content -Path $ProfilePath -Value $NewContent -Encoding UTF8
        Write-Host "  Added import to: $ProfilePath" -ForegroundColor Green
    }

    Write-Host ""
}

# ----------------------------------------------------------------------------
# Step 7: Register predictor module (first-time setup)
# ----------------------------------------------------------------------------

Write-Host "[Step 7/7] Registering predictor module..." -ForegroundColor Yellow

# Check if the predictor DLL was copied successfully
$PredictorDll = Join-Path $PredictorModuleDir "zigstoryPredictor.dll"
if (-not (Test-Path $PredictorDll)) {
    Write-Host "  ! Predictor DLL not available, skipping registration" -ForegroundColor Yellow
    Write-Host "    Run 'dotnet publish' in src\predictor and re-run this script" -ForegroundColor Yellow
} else {
    try {
        # Load the predictor assembly
        # Use -ErrorAction Stop to catch assembly loading issues
        Add-Type -Path $PredictorDll -ErrorAction Stop
        Write-Host "  Loaded predictor assembly" -ForegroundColor Green

        # Check if already registered
        $predictorId = "a8c5e3f1-2b4d-4e9a-8f1c-3d5e7b9a1c2f"
        
        # We try to find it in the subsystem manager directly to be more robust
        $isRegistered = $false
        try {
            $subsystems = [System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystems([System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor)
            foreach ($sub in $subsystems) {
                if ($sub.Id.ToString() -eq $predictorId) {
                    $isRegistered = $true
                    break
                }
            }
        } catch {
            # Fallback to Get-PSSubsystem if the above fails
            $existing = Get-PSSubsystem -Kind CommandPredictor -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $predictorId }
            if ($existing) { $isRegistered = $true }
        }

        if ($isRegistered) {
            Write-Host "  Predictor already registered" -ForegroundColor Green
        } else {
            # Register the predictor subsystem
            [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
                [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
                [zigstoryPredictor.ZigstoryPredictor]::new()
            )
            Write-Host "  Registered predictor subsystem" -ForegroundColor Green
        }

        # Enable predictive IntelliSense
        Set-PSReadLineOption -PredictionSource Plugin -ErrorAction SilentlyContinue
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
        Write-Host "  Enabled predictive IntelliSense" -ForegroundColor Green

    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "already registered") {
            Write-Host "  Predictor already registered (caught exception)" -ForegroundColor Green
        } else {
            Write-Host "  ! Failed to register predictor module" -ForegroundColor Yellow
            Write-Host "    Error: $msg" -ForegroundColor Red
            
            if ($msg -match "Unable to load one or more of the requested types") {
                Write-Host "    Hint: This often means a dependency is missing. Make sure all DLLs are in the module directory." -ForegroundColor Cyan
                if ($_.Exception.LoaderExceptions) {
                    foreach ($loaderEx in $_.Exception.LoaderExceptions) {
                        Write-Host "    Loader Error: $($loaderEx.Message)" -ForegroundColor Gray
                    }
                }
            }
            Write-Host "    This is expected if not running in PowerShell 7+ or if the DLL is locked." -ForegroundColor Gray
        }
    }
}

Write-Host ""

# ----------------------------------------------------------------------------
# Installation Complete
# ----------------------------------------------------------------------------

Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "For optimal performance, build in release mode first:" -ForegroundColor Yellow
Write-Host "  just build          # Build both zig app and plugin in release" -ForegroundColor White
Write-Host "  just install         # Reinstall after building" -ForegroundColor White
Write-Host ""

Write-Host "To enable zigstory:" -ForegroundColor Yellow
if ($IsPwsh) {
    Write-Host "  1. Close and reopen this PowerShell window" -ForegroundColor White
    Write-Host "  2. Or run: . $ProfilePath" -ForegroundColor White
} else {
    Write-Host "  1. Open PowerShell 7 (pwsh)" -ForegroundColor White
    Write-Host "  2. zigstory will be automatically loaded" -ForegroundColor White
}
Write-Host ""
Write-Host "Features enabled:" -ForegroundColor Green
Write-Host "  - Command history recording" -ForegroundColor White
Write-Host "  - Predictive IntelliSense (if predictor DLL is available)" -ForegroundColor White
Write-Host "  - TUI search (press Ctrl+R)" -ForegroundColor White
Write-Host "  - Fzf search (press Ctrl+F)" -ForegroundColor White
Write-Host "  - 'zs' command for search" -ForegroundColor White
Write-Host ""
Write-Host "For troubleshooting, see: .\$ZsProfileDest" -ForegroundColor Gray