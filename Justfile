set shell := ["pwsh.exe", "-NoProfile", "-Command"]

# Justfile for building zigstory and predictor plugin

# Build the zig application in release mode
build-zig:
    @zig build -Doptimize=ReleaseFast

# Build the predictor plugin in release mode (publish for win-x64)
build-plugin:
    @$env:DOTNET_ROOT = "$HOME\scoop\apps\dotnet-sdk\current"; & "$env:DOTNET_ROOT\dotnet.exe" publish src/predictor/zigstoryPredictor.csproj -c Release -r win-x64 --self-contained false -o src/predictor/bin/publish

# Build both zig application and predictor plugin in release mode
build: build-zig build-plugin

# Install zigstory (runs install.ps1)
install:
    @pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 || powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1

# Publish predictor; back up and upgrade executable/profile/module/history with rollback (CLI must be built)
safe-upgrade:
    @pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\safe-upgrade.ps1

# Upgrade from an extracted checksummed release, without Zig or a .NET SDK
safe-upgrade-package directory:
    @pwsh -NoProfile -File scripts\safe-upgrade.ps1 -PackageDirectory "{{directory}}"

# Build and validate a local Windows x64 release ZIP and SHA256 sidecar (no hosted CI)
release version:
    @pwsh -NoProfile -File scripts\release.ps1 -Version "{{version}}"

# Measure startup and actual terminal writes interactively; cancel the TUI to see results
terminal-profile:
    @pwsh -NoProfile -File scripts\terminal-profile.ps1

# Fetch pinned dependencies and apply the existing Zig 0.16 SQLite compatibility patch
prepare:
    @pwsh -NoProfile -File scripts\prepare-dependencies.ps1

# Run synthetic latency and bounded-memory budgets (requires Zig 0.16 and .NET 8+)
performance: build-zig
    @zig build profile-tools -Doptimize=ReleaseFast
    @$dotnet = (Get-Command dotnet.exe).Source; $scoop = Join-Path $env:USERPROFILE 'scoop\apps\dotnet-sdk\current\dotnet.exe'; if (Test-Path -LiteralPath $scoop) { $dotnet = $scoop }; $env:DOTNET_ROOT = Split-Path $dotnet; $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT; & $dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release -- --performance-check "{{justfile_directory()}}\zig-out\bin\zigstory.exe" "{{justfile_directory()}}\zig-out\bin\zigstory-tui-profile.exe" "{{justfile_directory()}}\zig-out\bin\zigstory-search-benchmark.exe"

# Build in debug mode
debug-zig:
    @zig build -Doptimize=Debug

# Build plugin in debug mode
debug-plugin:
    @$env:DOTNET_ROOT = "$HOME\scoop\apps\dotnet-sdk\current"; & "$env:DOTNET_ROOT\dotnet.exe" build src/predictor/zigstoryPredictor.csproj -c Debug

# Build everything in debug mode
debug: debug-zig debug-plugin

# Run zigstory
run:
    @zig build run

# Clean build artifacts
clean:
    @echo "Cleaning zig artifacts..."
    @rm -rf zig-out zig-cache
    @echo "Cleaning plugin artifacts..."
    @rm -rf src/predictor/bin src/predictor/obj

# Push with SSH key
push:
    @set GIT_SSH_COMMAND=ssh -i C:/Users/mfweax/.ssh/gitlab -o IdentitiesOnly=yes && git push

# Default recipe (show help)
default:
    @just --list
