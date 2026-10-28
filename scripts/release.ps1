#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'safe-upgrade.ps1')

function New-ZigstoryReleaseBundle {
    param([string]$RepositoryRoot, [string]$PublishedPredictor, [string]$OutputDirectory, [string]$Version)
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Version must be major.minor.patch with an optional prerelease suffix.' }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $archive = Join-Path $OutputDirectory "zigstory-$Version-win-x64.zip"
    if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath "$archive.sha256")) {
        throw "Release output already exists: $archive"
    }
    $stage = Join-Path ([IO.Path]::GetTempPath()) "zigstory-release-$([Guid]::NewGuid().ToString('N'))"
    $temporaryArchive = "$archive.$([Guid]::NewGuid().ToString('N')).tmp.zip"
    $temporaryChecksum = "$temporaryArchive.sha256"
    $createdArchive = $false
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $stage 'zig-out\bin'), (Join-Path $stage 'scripts')
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'zig-out\bin\zigstory.exe') -Destination (Join-Path $stage 'zig-out\bin\zigstory.exe')
        foreach ($name in @('zsprofile.ps1', 'safe-upgrade.ps1')) {
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot "scripts\$name") -Destination (Join-Path $stage "scripts\$name")
        }
        Copy-Item -LiteralPath $PublishedPredictor -Destination (Join-Path $stage 'predictor') -Recurse
        foreach ($name in @('LICENSE', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $RepositoryRoot $name) -Destination (Join-Path $stage $name)
        }
        $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
            @{ path = [IO.Path]::GetRelativePath($stage, $_.FullName); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        @{ schema = 1; version = $Version; platform = 'win-x64'; files = $files } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'release-manifest.json') -Encoding utf8
        Test-ZigstoryReleaseBundle $stage
        Test-ZigstoryUpgradeExecutable (Join-Path $stage 'zig-out\bin\zigstory.exe')
        Test-ZigstoryUpgradePredictor (Join-Path $stage 'predictor')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $temporaryArchive)
        "$((Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash)  $([IO.Path]::GetFileName($archive))" |
            Set-Content -LiteralPath $temporaryChecksum -Encoding ascii
        Move-Item -LiteralPath $temporaryArchive -Destination $archive
        $createdArchive = $true
        Move-Item -LiteralPath $temporaryChecksum -Destination "$archive.sha256"
        Write-Host "Release: $archive"
        return $archive
    } catch {
        if ($createdArchive) { Remove-Item -LiteralPath $archive -Force }
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        foreach ($path in @($temporaryArchive, $temporaryChecksum)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $repo = Split-Path $PSScriptRoot -Parent
    $published = Join-Path ([IO.Path]::GetTempPath()) "zigstory-release-predictor-$([Guid]::NewGuid().ToString('N'))"
    Push-Location $repo
    try {
        & (Join-Path $PSScriptRoot 'prepare-dependencies.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Dependency preparation failed.' }
        & zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
        if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
        Publish-ZigstoryUpgradePredictor $repo $published
        $null = New-ZigstoryReleaseBundle $repo $published ([IO.Path]::GetFullPath($OutputDirectory)) $Version
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $published) { Remove-Item -LiteralPath $published -Recurse -Force }
    }
}
