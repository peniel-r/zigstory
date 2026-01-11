# zigstory PowerShell Profile Integration
# This script hooks into PowerShell's Prompt function to track command history

# Configuration
$zigstoryBin = "zigstory"  # Path to zigstory binary (assumes it's in PATH)

# Global variable to track command execution time
$Global:ZigstoryStartTime = $null

# Hook into the Prompt function to capture command execution
function Global:Prompt {
    # Record the start time for the next command
    $Global:ZigstoryStartTime = Get-Date
    
    # If this is not the first prompt, we have a previous command to record
    if ($Global:ZigstoryLastHistoryItem) {
        try {
            # Calculate execution duration
            $duration = if ($Global:ZigstoryLastStartTime) {
                [int](($Global:ZigstoryStartTime - $Global:ZigstoryLastStartTime).TotalMilliseconds)
            } else {
                0
            }
            
            # Get exit code (default to 0 if not set)
            $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
            
            # Build zigstory add command arguments
            $zigstoryArgs = @(
                "add",
                "--cmd", "`"$($Global:ZigstoryLastHistoryItem -replace '"', '`"')`"",
                "--cwd", "`"$PWD`"",
                "--exit", "$exitCode",
                "--duration", "$duration"
            )
            
            # Execute zigstory add asynchronously to avoid blocking the prompt
            # Using Start-Process in a job-like fashion with no window
            Start-Process -FilePath $zigstoryBin `
                -ArgumentList $zigstoryArgs `
                -NoNewWindow `
                -UseNewEnvironment `
                -RedirectStandardOutput $null `
                -RedirectStandardError $null `
                -WindowStyle Hidden | Out-Null
        }
        catch {
            # Silently log errors to avoid breaking the prompt
            # In production, you might want to log to a file:
            # Write-Error "zigstory hook error: $_" 2>&1 | Out-File "$env:USERPROFILE\.zigstory\errors.log" -Append
        }
    }
    
    # Store the current history item for next prompt
    $Global:ZigstoryLastHistoryItem = Get-History -Count 1 | Select-Object -ExpandProperty CommandLine
    $Global:ZigstoryLastStartTime = $Global:ZigstoryStartTime
    
    # Return the default PowerShell prompt
    "PS $PWD> "
}

# Optional: Add Ctrl+R handler for TUI search (will be useful in Phase 4)
# Uncomment when zigstory search is implemented:
# Set-PSReadLineKeyHandler -Key Ctrl+r -ScriptBlock {
#     $result = & $zigstoryBin search 2>&1
#     if ($LASTEXITCODE -eq 0 -and $result) {
#         [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
#         [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
#     }
# }

# Display initialization message
Write-Host "zigstory history tracking enabled" -ForegroundColor Green
Write-Host "Your commands are now being recorded to: $env:USERPROFILE\.zigstory\history.db" -ForegroundColor DarkGray