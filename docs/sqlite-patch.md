# SQLite compatibility patch for Zig 0.16

The pinned zig-sqlite 3.48.0 dependency needs local compatibility changes for
Zig 0.16.0. Dependencies under `zig-pkg` are ignored, so fetching upstream alone
does not reproduce a working build. The complete patch is checked in as
`scripts\patches\sqlite-zig016.patch`.

## Preparing a checkout

From the repository root, with Zig 0.16.0, Git and PowerShell 7 available:

```powershell
just prepare
# Equivalent, including an explicit compiler override:
pwsh -NoProfile -File scripts\prepare-dependencies.ps1 -Zig 'C:\tools\zig\zig.exe'
zig build test
zig build run -Doptimize=ReleaseFast
```

The script fetches pinned packages using a repository-local download cache and
applies the patch only when all hunks match the pristine package. An already
patched package is accepted using a reverse check. Divergent sources are rejected
without overwriting local edits. It requires exactly Zig 0.16.0; newer compiler
versions need separate compatibility validation.

Windows CI uses this same preparation step. A pristine fetch plus patch has
also been verified locally with the ReleaseFast core/TUI regressions.

## Scope and rationale

The patch modifies four upstream files:

| File | Purpose |
| --- | --- |
| `build.zig` | Update build APIs and generated include handling |
| `build\Preprocessor.zig` | Adapt preprocessing and I/O to Zig 0.16 |
| `query.zig` | Update compile-time query parsing compatibility |
| `sqlite.zig` | Adapt allocator/type APIs and statement preparation |

Typed preparation forwards the original SQL literal to the dynamic preparation
path while preserving the typed statement wrapper. This avoids observed empty
runtime SQL from the compile-time transformed-query path on the affected
compiler/backend. The C preparation call uses a sentinel-terminated SQL string:
**dynamically constructed SQL must also be NUL-terminated**, for example with
`std.fmt.allocPrintSentinel(..., 0)`.

These are repository-local dependency changes, not modifications to system-wide
SQLite. They include compatibility work originally developed on
`zig016-migration`; the checked-in patch makes that previously ignored state
reproducible. It is not a claim that upstream supports Zig 0.16 unchanged.

## Maintenance

Keep the package hash in `build.zig.zon`, the preparation script and the patch
aligned. For a dependency/compiler upgrade, preserve any local edits, compare a
fresh pinned source against the compatibility changes, regenerate the patch, and
run both core/TUI and functional/predictor regressions. Do not silently drop the
statement-preparation workaround without runtime tests.

The patch is specific to the pinned source/compiler combination. Upstream or
compiler fixes may eventually remove its necessity. Keep original dependency
license notices intact.
