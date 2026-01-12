# zigstory Diagnostic Profile - logs everything

$script:logFile = "C:\temp\zigstory_debug.log"

function Write-Log($msg) {
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    Add-Content -Path $script:logFile -Value "[$timestamp] $msg" -Encoding utf8
}

Write-Log "Profile loaded"
Write-Log "Prompt function defined"

function Global:Prompt {
    Write-Log "Prompt called - START"

    try {
        $hist = Get-History -Count 1 -ErrorAction SilentlyContinue
        Write-Log "  Get-History completed, Id: $($hist?.Id)"

        if ($hist -and $hist.Id -ne $Global:LastId) {
            $Global:LastId = $hist.Id
            Write-Log "  New command detected: $($hist.CommandLine)"

            # Just queue - no write
            $cmd = $hist.CommandLine
            $cwd = $PWD.Path
            $exit = $LASTEXITCODE
            $dur = [int]$hist.Duration.TotalMilliseconds

            Write-Log "  Would record: cmd=$cmd, cwd=$cwd, exit=$exit, dur=$dur"
        } else {
            Write-Log "  No new command or duplicate"
        }
    } catch {
        Write-Log "  ERROR in Prompt: $_"
    }

    Write-Log "Prompt called - END"

    # Return prompt
    "PS $PWD> "
}

Write-Log "Ready to use - type 'ls' to test, then check log file"
Write-Host "zigstory diagnostic mode - logging to: $script:logFile" -ForegroundColor Yellow
