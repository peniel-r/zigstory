# zigstory

> **High-Performance SQLite-Backed Shell History Manager for PowerShell**

`zigstory` replaces the default PowerShell history with a persistent, context-aware SQLite database. It leverages **Zig** for high-performance write operations and TUI search, and a native **.NET** adapter for sub-5ms inline predictions.

## 🚀 Features

*   **Persistent Storage**: History is stored in a structured SQLite database (WAL mode), not a text file.
*   **Blazing Fast Predictions**: Custom C# `ICommandPredictor` provides "ghost text" suggestions in <5ms.
*   **Rich Context**: Captures execution duration, exit codes, current working directory, and session IDs.
*   **Interactive Search**: (In Progress) High-performance TUI built with `libvaxis` for searching history.
*   **Import**: Migration tool to import your existing PowerShell history.

## 🏗 Architecture

The system uses a **Split-Brain Architecture** to balance performance and safety:

1.  **Write Path (Zig)**: A standalone executable (`zigstory.exe`) hooks into the PowerShell prompt to sanitize and insert commands into SQLite asynchronously.
2.  **Read Path (.NET)**: A lightweight DLL (`zigstoryPredictor.dll`) loads into PowerShell to query the database for predictions. It uses connection pooling and LRU caching to ensure zero latency while typing.

## 🛠 Prerequisites

*   **OS**: Windows (win32)
*   **Shell**: PowerShell 7+
*   **Build Tools**:
    *   [Zig](https://ziglang.org/) (0.15.2+)
    *   [.NET 8 SDK](https://dotnet.microsoft.com/)

## 📦 Installation (From Source)

### 1. Build Components

```powershell
# 1. Build the Zig CLI (Manager & TUI)
zig build -Doptimize=ReleaseFast

# 2. Build the C# Predictor (Inline Suggestions)
dotnet build -c Release src/predictor/zigstoryPredictor.csproj
```

### 2. Configure PowerShell

Add the following to your PowerShell profile (`notepad $PROFILE`):

```powershell
# Adjust paths to where you cloned the repo
$RepoRoot = "C:\git\zigstory"

# Source the integration script
. "$RepoRoot\scripts\profile.ps1"
```

*Note: The `scripts/profile.ps1` expects the binaries to be in their standard build output locations (`zig-out/bin/zigstory.exe` and `src/predictor/bin/Release/net8.0/zigstoryPredictor.dll`). You may need to adjust paths in `profile.ps1` if you move files.*

## 📖 Usage

### Standard Operation
Just use your terminal as normal!
*   **Type**: You will see grey "ghost text" suggestions based on your history. Press `RightArrow` to accept.
*   **Run**: Every command is automatically saved with metadata (duration, exit code).

### Commands
*   `zigstory import`: Imports your existing `ConsoleHost_history.txt`.
*   `zigstory search`: Launches the interactive TUI (WIP).
*   `zigstory add ...`: (Internal) Used by the shell hook to record history.

### Keybindings
*   `Ctrl+R`: Launches the interactive search TUI (Requires configuration in profile).

## 🗺 Roadmap

See [docs/plan.md](docs/plan.md) for the detailed development roadmap.

- [x] **Phase 1**: Core Database & CLI
- [x] **Phase 2**: Write Path & Shell Integration
- [x] **Phase 3**: High-Performance Predictor
- [ ] **Phase 4**: TUI Search (In Progress)
- [ ] **Phase 5**: Frecency Ranking & Advanced Stats

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.