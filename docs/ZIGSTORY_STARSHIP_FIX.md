# Zigstory Starship Integration Fix

## Problem
Commands stopped being recorded on February 5, 2026. The database shows:
- Feb 12, 2026: 1 command (test)
- Feb 5, 2026: 33 commands
- Feb 4, 2026: 680 commands
- Feb 3, 2026: 4009 commands

### Root Cause
The original `zsprofile.ps1` defined a custom `Prompt` function that was being
overridden by starship's `prompt` function because starship was loaded AFTER
zigstory in the profile.

## Solution
Created `zsprofile-starship.ps1` that uses starship's `Invoke-Starship-PreCommand`
hook instead of overriding the prompt function.

## Files Changed

### New File: `zsprofile-starship.ps1`
- Uses `Invoke-Starship-PreCommand` for recording (called by starship)
- Does NOT define a custom `Prompt` function
- Compatible with starship prompts
- Location: `C:\Users\mfweax\Documents\PowerShell\zsprofile-starship.ps1`

### Updated: `Microsoft.PowerShell_profile.ps1`
Changed from:
```powershell
# ----------------------------------------------------------------------------
# zigstory Integration
# ----------------------------------------------------------------------------
. "C:\Users\mfweax\Documents\PowerShell\zsprofile.ps1"

if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    # ... zoxide init ...
}

Invoke-Expression (&starship init powershell)
```

To:
```powershell
# ----------------------------------------------------------------------------
# zigstory Integration (Starship Compatible)
# ----------------------------------------------------------------------------
# IMPORTANT: Load zigstarship BEFORE starship init
. "C:\Users\mfweax\Documents\PowerShell\zsprofile-starship.ps1"

# Initialize starship prompt
Invoke-Expression (&starship init powershell)

if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    # ... zoxide init ...
}
```

## How It Works

1. **zsprofile-starship.ps1** is loaded first
2. It defines `Invoke-Starship-PreCommand` function (used by starship)
3. **starship init** is called, which defines the `prompt` function
4. When starship's `prompt` runs, it calls `Invoke-Starship-PreCommand` before each command
5. The pre-command function records the command to zigstory database

## Testing the Fix

### 1. Restart PowerShell
Open a new PowerShell session to load the updated profile.

### 2. Verify Profile Loaded
Look for these messages:
```
zigstory enabled!
Predictive IntelliSense enabled (Plugin mode)
Type 'zs' or press 'Ctrl+R' for TUI search, 'Ctrl+F' for fzf search
```

### 3. Run Some Commands
```powershell
Get-Process
Get-Service
Write-Host "test"
```

### 4. Check if Commands Were Recorded
```powershell
zigstory list 10
```

You should see the commands you just ran at the top of the list.

### 5. Verify Recording is Working
Run a command and immediately check:
```powershell
# Run a command
hostname

# Check database
sqlite3 $env:USERPROFILE\.zigstory\history.db "SELECT datetime(timestamp, 'unixepoch'), cmd FROM history ORDER BY id DESC LIMIT 5"
```

## Backup Files

Your original profile has been backed up to:
- `C:\Users\mfweax\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.bak2`

## Reverting if Needed

If you need to revert to the old profile:

```powershell
# Restore old profile
Copy-Item C:\Users\mfweax\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.bak2 `
           C:\Users\mfweax\Documents\PowerShell\Microsoft.PowerShell_profile.ps1 -Force

# Restart PowerShell
```

## Troubleshooting

### Commands Still Not Recording

1. Check that `Invoke-Starship-PreCommand` is defined:
   ```powershell
   Get-Command Invoke-Starship-PreCommand
   ```

2. Check zigstory binary path:
   ```powershell
   $Global:ZigstoryBin
   ```

3. Test recording manually:
   ```powershell
   ZigstoryRecordCommand "test" $PWD 0 100
   zigstory list 5
   ```

### Profile Errors

1. Check profile syntax:
   ```powershell
   . $PROFILE.CurrentUserCurrentHost
   ```

2. Check for execution policy issues (if using Windows PowerShell vs PowerShell Core)

## Key Differences Between Old and New

| Feature | zsprofile.ps1 (Old) | zsprofile-starship.ps1 (New) |
|---------|---------------------|------------------------------|
| Prompt Function | Custom `Prompt` | Uses starship's `prompt` |
| Recording Hook | In `Prompt` function | In `Invoke-Starship-PreCommand` |
| Starship Compatible | ❌ Overrides starship | ✅ Works with starship |
| Loading Order | Must be AFTER starship | Must be BEFORE starship |
