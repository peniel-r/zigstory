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

# Back up and upgrade existing executable/profile/history; roll back on failure (no rebuild)
safe-upgrade:
    @pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\safe-upgrade.ps1

# Fetch pinned dependencies and apply the existing Zig 0.16 SQLite compatibility patch
prepare:
    @pwsh -NoProfile -File scripts\prepare-dependencies.ps1

# Run synthetic latency and bounded-memory budgets (requires Zig 0.16 and .NET 8+)
performance: build-zig
    @zig build profile-tools -Doptimize=ReleaseFast
    @dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release -- --performance-check "{{justfile_directory()}}\zig-out\bin\zigstory.exe" "{{justfile_directory()}}\zig-out\bin\zigstory-tui-profile.exe" "{{justfile_directory()}}\zig-out\bin\zigstory-search-benchmark.exe"

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
