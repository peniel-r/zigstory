#Requires -Version 7.0
param([string]$Zig = 'zig')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $version = & $Zig version
    if ($LASTEXITCODE -ne 0 -or $version -ne '0.16.0') { throw 'Dependency preparation requires Zig 0.16.0.' }
    $cache = Join-Path $root '.zig-cache\dependency-fetch'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $cache 'tmp'), (Join-Path $root '.zig-cache\tmp')
    & $Zig build --fetch=all --global-cache-dir $cache
    if ($LASTEXITCODE -ne 0) { throw 'Dependency fetch failed.' }
    $package = 'zig-pkg\sqlite-3.48.0-F2R_a8WODgDamFQx1fOrpgY7IdluD4Sr_P7G0UPxUUMr'
    $patch = Join-Path $PSScriptRoot 'patches\sqlite-zig016.patch'
    & git apply --check "--directory=$package" $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git apply "--directory=$package" $patch
        if ($LASTEXITCODE -ne 0) { throw 'SQLite compatibility patch failed.' }
        Write-Host 'Applied pinned SQLite Zig 0.16 compatibility patch.'
    } else {
        & git apply --reverse --check "--directory=$package" $patch 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'SQLite sources match neither the pristine nor patched revision. Refusing to overwrite local changes.'
        }
        Write-Host 'SQLite compatibility patch is already applied.'
    }
    $package = 'zig-pkg\vaxis-0.6.0-BWNV_HHwCQCy33z_jb0RHLjoinqQ8tgQVZI9z2e5Yqdd'
    $patch = Join-Path $PSScriptRoot 'patches\vaxis-windows-stop.patch'
    & git apply --check "--directory=$package" $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git apply "--directory=$package" $patch
        if ($LASTEXITCODE -ne 0) { throw 'Vaxis Windows shutdown patch failed.' }
        Write-Host 'Applied pinned Vaxis Windows shutdown patch.'
    } else {
        & git apply --reverse --check "--directory=$package" $patch 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Vaxis sources match neither the pristine nor patched revision. Refusing to overwrite local changes.' }
        Write-Host 'Vaxis Windows shutdown patch is already applied.'
    }
} finally { Pop-Location }
