# libvaxis Windows input shutdown patch

The pinned libvaxis revision is unchanged. `scripts/patches/vaxis-windows-stop.patch`
patches only `src/Loop.zig` and `src/tty.zig` after fetching that revision.
`just prepare` applies it once, accepts an already-patched copy, and refuses
divergent target-file changes. It does not overwrite the package directory.

## Confirmed failure

ConPTY cancellation/selection tests intermittently reached `Loop.stop()` but never
returned. Instrumented failures contained a stop-begin marker, not stop-end.
The old method set a plain cross-thread boolean, sent a device-status query and
waited for the reader. `WindowsTty.nextEvent()` discards ordinary DSR responses
inside its blocking loop, so a status reply cannot reliably wake that reader.
Shutdown accidentally depended on another real event arriving.

## Fix

- Use release/acquire atomic reads/writes for the stop flag.
- On Windows, open `CONIN$` for writing and enqueue a non-text focus event. The
  blocking reader returns without a user key or emulator status response.
- Check the stop flag before publishing that wake event to the application.
- Cancel/join the input future, also releasing a producer blocked on a full
  cancellable event queue. Leave the POSIX status-report wake path intact.

Temporary application instrumentation was removed. Only the dependency patch
changes runtime behavior; no database schema or recording policy is involved.

## Regression and reproduction

```powershell
just prepare
zig build terminal-stop-probe -Doptimize=ReleaseFast
dotnet run --project tests\predictor\PredictorRegressionTests.csproj -c Release -- --terminal-stop-check "$PWD\zig-out\bin\zigstory-input-stop-probe.exe"
```

The isolated ConPTY harness starts a real input reader, waits for it to become
idle, calls stop without any key input, and verifies return. A second case fills
the event queue before stopping. This also runs through `just performance` on
Windows; ordinary Ctrl+C/Enter, rendering and code-page tests remain separate.

Before the patch, the idle probe timed out with begin but no end marker. After
restoring the patch with `just prepare`, it returned normally. Six consecutive
full ConPTY runs (24 scenarios) also passed. These tests cover Windows console
I/O, not physical key latency or terminal display composition.
