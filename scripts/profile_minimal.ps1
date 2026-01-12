# zigstory PowerShell Profile (MINIMAL - fixes freezing)

\$Global:ZigstoryBin = "\$PSScriptRoot\..\zig-out\bin\zigstory.exe"
\$Global:ZigstoryEnabled = \$true

\$Global:ZigstorySkipPatterns = @(
    '^\s*\$',
    '^[a-zA-Z]:\$',
    '^exit\$',
    '^cd\s+\$',
    '^cd \.\$',
    '^pwd\$',
    '^cls\$',
    '^clear\$',
    '^\$'
)

function Global:ZigstoryShouldRecord(\$cmd) {
    \$trimmedCmd = \$cmd.Trim()
    if ([string]::IsNullOrWhiteSpace(\$trimmedCmd)) { return \$false }
    foreach (\$pattern in \$Global:ZigstorySkipPatterns) {
        if (\$trimmedCmd -match \$pattern) { return \$false }
    }
    return \$true
}

function Global:ZigstoryRecordCommand(\$cmd, \$cwd, \$exitCode, \$duration) {
    if (-not \$Global:ZigstoryEnabled) { return }

    \$tempFile = [System.IO.Path]::GetTempFileName()
    try {
        \$cmdJson = \$cmd -replace '\\', '\\\\' -replace '"', '\\\"'
        \$cwdJson = \$cwd -replace '\\', '\\\\'
        \$json = "[{\`"cmd\`":\`"\$cmdJson\`",\`"cwd\`":\`"\$cwdJson\`",\`"exit_code\`":\$exitCode,\`"duration_ms\`":\$duration}]"

        \$utf8NoBom = New-Object System.Text.UTF8Encoding(\$false)
        [System.IO.File]::WriteAllText(\$tempFile, \$json, \$utf8NoBom)

        \$psi = New-Object System.Diagnostics.ProcessStartInfo
        \$psi.FileName = \$Global:ZigstoryBin
        \$psi.Arguments = "import --file \\"\$tempFile\\""
        \$psi.UseShellExecute = \$false
        \$psi.CreateNoWindow = \$true

        \$proc = New-Object System.Diagnostics.Process
        \$proc.StartInfo = \$psi
        \$proc.Start() | Out-Null
    }
    catch {
        # Ignore errors
    }
}

if (\$null -eq \$Global:ZigstoryOldPrompt) {
    if (Test-Path Function:\Prompt) {
        \$Global:ZigstoryOldPrompt = \$ExecutionContext.InvokeCommand.GetCommand('Prompt', 'Function')
    }
}

\$Global:ZigstoryLastHistoryId = -1

function Global:Prompt {
    if (-not \$Global:ZigstoryEnabled) {
        if (\$Global:ZigstoryOldPrompt) {
            & \$Global:ZigstoryOldPrompt
        } else {
            "PS \$PWD> "
        }
        return
    }

    \$lastHistory = Get-History -Count 1 -ErrorAction SilentlyContinue

    if (\$lastHistory -and \$lastHistory.Id -ne \$Global:ZigstoryLastHistoryId) {
        \$Global:ZigstoryLastHistoryId = \$lastHistory.Id

        try {
            if (ZigstoryShouldRecord \$lastHistory.CommandLine) {
                \$duration = [int]\$lastHistory.Duration.TotalMilliseconds
                \$exitCode = if (\$null -ne \$LASTEXITCODE) { \$LASTEXITCODE } else { 0 }
                \$cwd = \$PWD.ProviderPath

                ZigstoryRecordCommand \$lastHistory.CommandLine \$cwd \$exitCode \$duration
            }
        }
        catch {
            # Ignore
        }
    }

    if (\$Global:ZigstoryOldPrompt) {
        & \$Global:ZigstoryOldPrompt
    } else {
        "PS \$PWD> "
    }
}

function Global:Enable-Zigstory { \$Global:ZigstoryEnabled = \$true }
function Global:Disable-Zigstory { \$Global:ZigstoryEnabled = \$false }

Write-Host "zigstory ready (use Disable-Zigstory / Enable-Zigstory)" -ForegroundColor Green
