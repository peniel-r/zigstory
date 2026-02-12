set shell := ["cmd.exe", "/c"]

# Justfile for building zigstory and predictor plugin

# Build the zig application in release mode
build-zig:
    @zig build -Doptimize=ReleaseFast

# Build the predictor plugin in release mode (publish for win-x64)
build-plugin:
    @dotnet publish src/predictor/zigstoryPredictor.csproj -c Release -r win-x64 --self-contained false -o src/predictor/bin/publish

# Build both zig application and predictor plugin in release mode
build: build-zig build-plugin

# Install zigstory (runs install.ps1)
install:
    @pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 || powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1

# Build in debug mode
debug-zig:
    @zig build -Doptimize=Debug

# Build plugin in debug mode
debug-plugin:
    @dotnet build src/predictor/zigstoryPredictor.csproj -c Debug

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
