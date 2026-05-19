# Zig 0.15.2 to 0.16.0 Migration Plan

**Project:** zigstory
**Current Version:** Zig 0.15.2
**Target Version:** Zig 0.16.0 (released April 14, 2026)

---

## Phase 1: Update Dependencies

### 1.1 Update `build.zig.zon`
- [ ] Change `minimum_zig_version` from `"0.15.2"` to `"0.16.0"`
- [ ] Find and update `zig-sqlite` to a 0.16.0-compatible version
  - Current: `https://github.com/vrischmann/zig-sqlite/archive/master.tar.gz`
  - Check master branch or look for a 0.16.0 tag/branch
- [ ] Find and update `libvaxis` to a 0.16.0-compatible version
  - Current: pinned to commit `75035b169e91a51c` (v0.5.1)
  - vaxis heavily uses I/O — likely needs a major update for 0.16.0's I/O overhaul

### 1.2 Verify dependency APIs
- [ ] Confirm `sqlite_dep.module("sqlite")` still works
- [ ] Confirm `vaxis_dep.module("vaxis")` still works
- [ ] Check if vaxis API surface changed (TUI rendering, event loop)

---

## Phase 2: Build System (`build.zig`)

### 2.1 Review build API compatibility
- [ ] Verify `b.dependency()`, `b.createModule()`, `b.addModule()` APIs unchanged
- [ ] Verify `mod.addImport()` still exists
- [ ] Check if `target.result.os.tag` accessor changed
- [ ] Test `b.addExecutable()` with `.root_module` pattern

No `@cImport` is used in this project, so the deprecation doesn't directly affect us.

---

## Phase 3: Standard Library API Changes

### 3.1 `std.fs.cwd()` — Current Directory API Renamed (12 usages)

**Files affected:**
- `src/main.zig` (lines 55, 102, 158, 249, 289, 340, 376)
- `src/cli/import.zig` (lines 21, 36, 173, 305)
- `tests/ranking_perf_test.zig` (line 13)

**Action:** Replace `std.fs.cwd()` with the new API (likely `std.fs.cwd2()` or accessed through the new I/O interface — check 0.16.0 std docs).

### 3.2 `std.fs.File.stdout()` — File I/O Changes (1 usage)

**Files affected:**
- `src/main.zig` (line 311)

**Action:** Update to new stdout access pattern per 0.16.0 I/O interface.

### 3.3 Child Process API (fzf integration)

**Files affected:**
- `src/cli/fzf.zig` (lines 10-11, 38-39, 65-92)

**Action:** Check if `std.process.Child` (formerly `std.ChildProcess`) API changed:
- `.stdout_behavior` / `.stderr_behavior` field names
- `.stdout.?.read()` pattern for capturing output

### 3.4 `std.mem` Renames ("indexOf" → "find")

**Status:** No `mem.indexOf` usage found in project. **No action needed.**

### 3.5 Environment Variables / Process Arguments — Non-Global API

**Status:** No direct `getEnvMap` usage found. However, check if `std.process.ArgIterator` or argument parsing changed.

**Files to verify:**
- `src/cli/args.zig` — CLI argument parsing

### 3.6 `heap.ArenaAllocator` — Now Thread-Safe and Lock-Free

**Files affected:**
- `src/tui/main.zig` — uses ArenaAllocator for frame-scoped rendering

**Action:** Likely backwards-compatible, but verify:
- Constructor/init API unchanged
- `.reset()` method still exists
- `.allocator()` method still exists

### 3.7 Removed APIs Check

- [ ] `GenericReader` / `AnyReader` — not used directly, but dependencies may use them
- [ ] `FixedBufferStream` — not used
- [ ] `std.Thread.Pool` — removed in 0.16.0; check if used in dependencies

---

## Phase 4: Language Changes

### 4.1 Packed Struct/Union Changes
- [ ] Audit any `packed struct` or `packed union` in codebase for:
  - Pointers in packed structs (now forbidden)
  - Unused bits in packed unions (now forbidden)

### 4.2 `@Type` Replaced
- [ ] Not used directly in project code — check dependencies only

### 4.3 Other Language Changes (Low Risk)
- Switch statement changes — mostly additions, unlikely to break
- Vector/array coercion changes — check if any `@Vector` usage exists

---

## Phase 5: Iterative Build & Fix

### 5.1 First build attempt
- [ ] Run `zig build` with Zig 0.16.0
- [ ] Capture and categorize all errors

### 5.2 Fix errors by category
- [ ] API renames (mechanical fixes)
- [ ] Signature changes (may require logic adjustments)
- [ ] Removed APIs (need alternative implementations)

### 5.3 Verify functionality
- [ ] Run `zig build run` with basic commands
- [ ] Test TUI mode (vaxis)
- [ ] Test fzf integration
- [ ] Test database operations
- [ ] Run test suite

---

## Risk Assessment

| Area | Risk | Reason |
|------|------|--------|
| libvaxis dependency | **HIGH** | TUI library heavily affected by I/O overhaul |
| zig-sqlite dependency | **MEDIUM** | May need updated version for 0.16.0 |
| `std.fs.cwd()` migration | **MEDIUM** | 12 call sites, but likely mechanical rename |
| I/O interface changes | **MEDIUM** | stdout/file access patterns changed |
| Child process API | **LOW** | Likely minor field renames |
| ArenaAllocator | **LOW** | Now thread-safe but API likely compatible |
| Language changes | **LOW** | No packed pointers or `@Type` usage |

---

## Recommended Order of Execution

1. Check for 0.16.0-compatible versions of zig-sqlite and libvaxis
2. Update `build.zig.zon` with new dependency URLs/hashes
3. Run `zig build` — let compiler errors guide remaining fixes
4. Fix `std.fs.cwd()` calls (likely the bulk of changes)
5. Fix stdout/I/O patterns
6. Fix child process API if needed
7. Run full test suite
8. Manual testing of TUI and CLI modes
