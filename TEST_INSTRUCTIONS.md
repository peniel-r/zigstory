# zigstory Diagnostic Test Instructions

## Current Status

I've identified that **`Get-History` is NOT the issue** (average ~5ms).

The problem is likely related to **PowerShell 7.6.0-preview.6 event handling** in the profile script.

## Please Test Diagnostic Profile

I've created a diagnostic version that logs everything:

```powershell
# 1. Backup your current profile if you're using it:
Copy-Item $PROFILE -Destination "$PROFILE.backup"

# 2. Load the diagnostic profile:
. "F:\sandbox\zigstory\scripts\profile_diagnostic.ps1"

# 3. Run a few commands:
ls
echo "test 1"
echo "test 2"
Get-Process

# 4. Check the log file:
notepad C:\temp\zigstory_debug.log
```

## What to Look For

The log file will show:

- When Prompt is called
- Get-History execution time
- Commands being detected
- Any errors occurring

**Key question**: Is there a long pause between "Prompt called - START" and "Prompt called - END"?

If YES → Problem is inside the Prompt function (Get-History or related)
If NO → Problem is elsewhere (PSReadline, host, etc.)

## Current zsprofile.ps1 Status

The current profile uses:

- `cmd /c start /b` for detached writes (experimental)
- No timer
- No event registration
- Immediate writes (no batching)

**This should work but may have reliability issues** with `cmd /c start /b` in PowerShell 7.6 preview.

## Alternative: Disable Profile Entirely

If you want to confirm zigstory is the issue:

```powershell
# Just create a new profile without zigstory:
notepad $PROFILE

# Add only this to test:
Write-Host "Test profile - no zigstory"
```

Then run commands and see if freeze still happens.

## What I Need From You

Please:

1. **Test the diagnostic profile** and share the log contents
2. **Confirm if freeze still happens** with diagnostic profile
3. **Share the log file content** from `C:\temp\zigstory_debug.log`

This will help me pinpoint the exact cause of the "several minutes" freeze.
