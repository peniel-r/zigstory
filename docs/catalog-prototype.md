# Experimental distinct-command catalog

**Status:** disposable schema-3 prototype, November 5, 2026. Production remains
schema 2. Neither normal startup nor safe-upgrade calls this migration.

The reviewed prompt-launch work is committed as `cb51319`. This prototype is a
separate, uncommitted validation step before rewriting production SQL.

## Data model

- `commands`: one row per **exact** command text, with integer identity, lifetime
  execution/success counts, latest timestamp/event and exponential frecency key.
  Case differences are not silently merged.
- `directories`: one row per exact path, referenced by integer ID. No case-folding
  or path canonicalization is introduced. This avoids duplicating long path text
  in every event and location index.
- `history_events`: original event IDs and row IDs, command/directory identities,
  exit status, duration, session, hostname and timestamp. Command text and SHA-256
  hashes are not repeated in every event; per-event rank values are removed.
- `command_locations`: latest event/timestamp per command and exact directory.
  A local search selects the latest local execution, not the command's global
  latest execution. Ordering is timestamp then event ID, including ties and
  out-of-order imports. Nullable legacy metadata is preserved.
- `commands_fts`: external-content **trigram** FTS over distinct text, maintained
  by command insert/edit/delete triggers.
- `catalog_metadata`: experimental layout version, ranking policy version and
  half-life. Writers/repair refuse incompatible metadata rather than mixing
  layouts or score units.

The migration rebuilds counts from actual events, not possibly incomplete legacy
`command_stats`. It preserves the history ID high-water mark, including when all
events were deleted, and rejects duplicate event identities or malformed timestamp
metadata instead of discarding/changing events. All schema changes commit together.

## Proposed ranking policy — review required

Every execution contributes weight 1 that decays with a **30-day half-life**:

```text
current_score = sum(2 ** ((execution_timestamp - now) / half_life_seconds))
stored_key    = log2(sum(2 ** (execution_timestamp / half_life_seconds)))
```

The current-time term is common to all commands, so the stored keys sort in the
same order as current decayed scores. No periodic history-row updates are needed.
Incremental log-sum-exp avoids overflow when constructing keys; display conversion
caps extreme future values. Unknown legacy timestamps do not contribute to the
decay score. Actual event metadata and lifetime counts remain intact.

This replaces `frequency*2 + 100/days_since_last_use`. It is a behavioral change,
not merely a faster way to compute the old formula. Relative order stays constant
as time passes without new events because all scores decay at the same rate.
Recent events change that order; old high-frequency commands no longer retain a
permanent lifetime-frequency advantage. Success counts are stored but do not yet
penalize failures; that would be a separate prediction-policy feature.

## Literal search and bounded pages

Trigram FTS supplies candidates for valid UTF-8 queries with at least three
codepoints and no embedded NUL. Every candidate still passes the existing escaped
`LIKE` predicate. This preserves current literal `%`, `_`, backslash, quoting and
ASCII case-folding behavior even if FTS's Unicode matching is broader.
Short/unsupported queries scan the **catalog**, not every execution.

The benchmark materializes only event IDs in a SQLite TEMP table, then fetches
100-row pages with indexed position seeks. Command-string memory stays bounded;
TEMP ID storage still grows with matches. The prototype cache is one slot per
connection, deliberately **not** a replacement for production's multiple search
states and committed-write invalidation.

## Repeatable validation

With Zig 0.16.0 on PATH:

```powershell
zig build test
zig build test -Doptimize=ReleaseFast
zig build catalog-prototype -Doptimize=ReleaseFast
& .\zig-out\bin\zigstory-catalog-benchmark.exe
pwsh -NoProfile -File tests\catalog_regressions.ps1
```

The executable's default fixture is in memory. `--disk-fixture <new-path>` is
optional: it **exclusively creates** a new file, seeds only synthetic rows, compares
both schemas, then deletes its file/WAL/SHM companions. Existing files are refused
without alteration or deletion. It cannot be used to migrate an input database.

Tests cover atomic failure, version refusal, exact grouping, nullable timestamps,
integer extremes, ties, sparse/high-water IDs, event retry, recording rollback,
literal/Unicode/global/local search equivalence, page bounds, indexed query plans,
FTS edits/deletes, policy mismatch, repair and on-disk reopen.

Warm 100k-event / 25k-command synthetic examples (not universal latency promises):

| First page, including materialization | Schema 2 | Prototype |
| --- | ---: | ---: |
| Broad global, memory fixture | 32.6 ms | 7.77 ms |
| Selective global, memory fixture | 5.63 ms | 0.34 ms |
| Broad global, file fixture | 41.4 ms | 7.70 ms |
| Selective global, file fixture | 13.8 ms | 0.31 ms |
| Broad local, file fixture | 25.8 ms | 12.2 ms |

Deep file-backed pages remained about 0.04–0.06 ms. Used storage was about
40.3 -> 23.4 MiB. Deleting old tables releases pages to SQLite's freelist; actual
file shrink requires separate, explicit compaction. The benchmark's `VACUUM` is
only on its disposable fixture, not part of migration.

One file-backed migration took roughly 0.6–0.7 seconds; its SQLite allocation peak
was about 7 MiB, versus about 94 MiB for the all-in-memory comparison holding the
complete old/new fixture. These exclude process/OS memory and are not deployment
budgets. Prototype recording took about 0.19 ms median on that file fixture,
excluding shell launch. The summary benchmark covers catalog aggregates, **not**
the complete `stats` dashboard.

The extra `--mostly-unique --long-directories` fixture covers 100k distinct
commands and long repeated paths. It exposed a regression in the first design
that repeated directory text: 78.4 -> 100.7 MiB. Directory normalization fixed
that case to 78.4 -> 37.2 MiB, with unchanged query results; the file-backed
allocation peak was about 8 MiB. The separate regression script exercises both
fixtures. Storage savings still depend on real text/path lengths and repetition,
not a universal fixed percentage.

## Before enabling schema 3

1. Review the 30-day exponential ranking policy and migration storage tradeoff.
2. Integrate normalized reads/writes into CLI, TUI, imports and predictor; retain
   immediate recording and reusable statements for batch imports.
3. Implement atomic version-0/1 migration paths and schema checks in every reader.
4. Preserve browsing (individual executions), multi-state caches, local/external
   write invalidation and stable selection behavior.
5. Update `maintenance`/`recalc-rank` compatibility and full upgrade, rollback,
   package and performance gates. Older executables must refuse schema 3.
6. Require a quiet backup-aware deployment; rollback restores the entire original
   database directory, never just an old executable over a newer WAL/database.

No installed history has been migrated, and no production schema change is active.
