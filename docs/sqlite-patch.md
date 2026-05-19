SQLite vendored patch for Zig 0.16 — Documentation

Overview
--------
This document records the vendored changes applied to the sqlite package shipped in zig-pkg/
for the zigstory project. The changes are narrowly targeted to work around two interrelated
issues observed when building/running on Zig 0.16.0 for Windows x64:

1. Comptime string materialization bug: ParsedQuery(...).getQuery() (used by the typed
   statement machinery) could materialize to an empty slice at runtime under Zig 0.16, causing
   prepared statements to be created with empty SQL text and leading to runtime SQLite errors
   such as error.EmptyQuery.

2. Preparation path fragility: Relying on the internal typed StatementType.prepare() path
   that depends on comptime-transformed query data made the library fragile on this compiler
   version. To avoid runtime failures we route the SQL text directly to DynamicStatement.prepare()
   which accepts a runtime string.

This patch is intentionally minimal and localized to sqlite.zig in the vendored copy under
zig-pkg/. It does not modify system-wide SQLite installs or anything outside this repository.

Files modified
--------------
- zig-pkg/sqlite-3.48.0-*/sqlite.zig
  (path in this repo: zig-pkg/sqlite-3.48.0-F2R_.../sqlite.zig)

What changed (high level)
-------------------------
We changed the implementation of Db.prepareWithDiags(...) and Db.prepare(...) so that the
original comptime `query` string literal is forwarded directly to DynamicStatement.prepare() at
runtime instead of routing through StatementType(...).prepare(...) that depended on
ParsedQuery(...).getQuery(). The former path was producing empty SQL text at runtime.

- prepareWithDiags: previously returned StatementType(.{}, query).prepare(self, options, 0);
  Now it prepares a DynamicStatement from the original query string and returns it wrapped
  so existing call sites continue to receive a StatementType-like value.

- prepare: same approach as prepareWithDiags but with default options.

Representative code snippets
----------------------------
NOTE: The following snippets are representative and reflect the committed change. They are
intended to make the modification intent explicit for reviewers.

Old (simplified):

    pub fn prepareWithDiags(self: *Self, comptime query: []const u8, options: QueryOptions) DynamicStatement.PrepareError!blk: {
        @setEvalBranchQuota(100000);
        break :blk StatementType(.{}, query);
    } {
        @setEvalBranchQuota(100000);
        return StatementType(.{}, query).prepare(self, options, 0);
    }

New (simplified):

    pub fn prepareWithDiags(self: *Self, comptime query: []const u8, options: QueryOptions) DynamicStatement.PrepareError!blk: {
        @setEvalBranchQuota(100000);
        break :blk StatementType(.{}, query);
    } {
        @setEvalBranchQuota(100000);
        // Pass the original comptime literal directly to the dynamic prepare path so the
        // SQL text is read from the binary data section rather than from an intermediate
        // buffer that Zig 0.16 may fail to materialize.
        const dynamic = try DynamicStatement.prepare(self, query, options, 0);
        return StatementType(.{}, query){ .dynamic_stmt = dynamic };
    }

And likewise for `pub fn prepare(self: *Self, comptime query: []const u8)` — it now obtains a
`dynamic` statement using DynamicStatement.prepare(self, query, .{}, 0) and returns a
StatementType that references the dynamic statement.

Why this fix
------------
- Practical: it avoids the runtime failure caused by Zig 0.16's comptime materialization issue
  and lets the application operate normally without requiring immediate upstream changes to
  zig-sqlite or the compiler.
- Minimal scope: only the vendored sqlite.zig was changed; we did not rewrite the public API
  or the higher-level application code.

Upstream considerations
-----------------------
- This is a compatibility workaround for a Zig compiler/backend problem. It would be best to
  propose the change upstream as a carefully-worded patch, explaining the Zig 0.16
  codegen/materialization problem and the reason for forwarding the literal to the dynamic
  prepare path.
- Upstream reviewers may prefer a different approach (a noinline wrapper around the C call,
  changes to how ParsedQuery materializes the query, or a conditional compilation guard for
  affected Zig versions). The patch below is intentionally a small, easily-reviewed change.

Patch format suggestion (for PR body)
------------------------------------
Title: sqlite: avoid comptime query materialization bug on Zig 0.16 (compat workaround)

Body:
- Problem: under Zig 0.16 the ParsedQuery -> getQuery() path can yield an empty runtime
  slice for the SQL text, causing prepared statements to be created with empty SQL.
- Change: forward the original comptime query literal directly to DynamicStatement.prepare()
  in Db.prepareWithDiags and Db.prepare, ensuring the SQL bytes are read from the binary
  data section and not from a transient buffer.
- Tests: Verified locally on Windows x64, Zig 0.16.0: full functional test suite passes.
- Rationale: minimal compatibility patch; suggests review for a more general fix upstream.

Testing performed
-----------------
- Local environment (Windows):
  - Zig 0.16.0
  - PowerShell 7.7.0-preview.1 (used by functional tests)
  - dotnet-sdk installed via Scoop (10.0.300)

Commands run (representative):
  - just build
  - zig build
  - pwsh -NoProfile -File tests/run_tests.ps1

Result: Functional test suite passed (74/74). The `add`, `list`, `stats`, `perf`, and
recalc-rank flows were exercised and verified.

Risks & limitations
-------------------
- This change routes typed statement preparation through the dynamic path. The typed
  StatementType wrapper is still returned in order to preserve call-site compatibility, but
  callers that relied on the specific compile-time-checked binding behavior could see
  differences: the runtime binding remains correct, but some compile-time protections may be
  relaxed depending on the exact StatementType implementation.
- The fix is a workaround targeted at Zig 0.16; upstream changes to zig-sqlite or Zig may
  obviate the need for this change in future compiler versions.

Reverting the change
--------------------
- To revert the change locally, checkout the commit that modified the vendored sqlite.zig and
  reset it, or use git restore:

    git checkout zig016-migration
    git restore --staged zig-pkg/sqlite-3.48.0-*/sqlite.zig
    git checkout -- zig-pkg/sqlite-3.48.0-*/sqlite.zig

- Or revert the commit that introduced the patch and re-run tests.

Notes about licensing
---------------------
- The sqlite sources included under zig-pkg/ are a vendored copy. Keep license notices
  intact when proposing patches upstream and when publishing this repository.

Contact / history
-----------------
- Patch applied in branch: zig016-migration (commit d19bcbc)
- If you want me to generate a formal git-format-patch or PR-ready patch file for upstream,
  I can produce it (diff + commit message) and include suggested testing steps for reviewers.

Appendix: Suggested git commands to produce a patch file
-------------------------------------------------------

    git format-patch -1 d19bcbc -- zig-pkg/sqlite-3.48.0-*/sqlite.zig -o /tmp

This creates a patch file under /tmp which can be attached to an upstream issue/PR.

End of document.
