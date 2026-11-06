# Future Improvements & Roadmap

> **Status**: Proposed ideas, not an approved implementation backlog | **Last Updated**: November 6, 2026

This document outlines potential future features, integrations, and architectural improvements for **zigstory**.

Implementation and deployment history belongs in [PLAN.md](PLAN.md); supported
commands and usage belong in [README.md](README.md). Priorities and effort labels
below are proposals, not authorization to implement or promises of delivery dates.

## Completed foundation — not remaining work

- Schema 3 stores exact command text and directory paths once, with stable event
  identities and preserved execution metadata. Versions 0/1/2 migrate atomically.
- Exponential frecency uses a 30-day half-life and indexed log-space keys; periodic
  per-event rank rewrites are no longer required.
- TUI substring search uses trigram candidates verified with literal LIKE matching,
  full match counts, bounded result strings and indexed cached pages.
- Immediate recording uses durable per-event payloads and background importer
  launch; normal exit drains pending launches, and failed events are retryable.
- PSReadLine sensitive/history-filtering decisions are respected. This is **not**
  active secret redaction or database encryption.
- Ctrl+R/Ctrl+F insert selections without touching the clipboard. Direct standalone
  selection still copies; fzf preserves multiline commands with NUL record framing.
- Predictor packaging, read-only warm-up, cache invalidation and schema checks,
  Unicode handling, Windows input-loop shutdown and safe upgrades are implemented.
- Windows x64 release bundles and local correctness/performance gates exist.

## Recommended next sequence

| Order | Proposed feature | Benefit | Rough effort |
| --- | --- | --- | --- |
| 1 | Ctrl+R initialized from the current command line | Search using what is already typed | Small |
| 2 | Full-command preview | Inspect multiline commands and execution metadata | Medium |
| 3 | Safe history deletion | Remove mistakes or sensitive entries consistently | Medium |
| 4 | Richer filters | Search by session, host, repository, status or date range | Medium |
| 5 | Context-aware predictions | Prefer commands relevant to the current project | Medium |

Sort options and multi-word search are useful adjacent TUI improvements. The
normalized catalog makes these features easier, but they are not implemented yet.

---

## 1. DevOps & Automation

The project currently uses local builds and validation, not GitHub Actions.

### Unified Release Pipeline
- **Implemented for Windows x64**: `just release <version>` builds, publishes,
  validates and packages a ZIP plus SHA256 sidecar. Extracted bundles support
  backup-aware upgrades without a local compiler or SDK.
- Cross-platform archives and public release publishing remain optional roadmap
  ideas, not requirements of the completed Windows optimization pass.

### Performance Regression Gating
- **Implemented locally**: `just performance` checks synthetic 100k-row
  correctness, latency and memory budgets; `just terminal-profile` measures actual
  terminal first-frame/output timings. See `tests\README.md` for scoped thresholds.
- No blanket sub-5ms startup/search guarantee or hosted CI gate is assumed.

### Cross-Platform Verification
- **Goal**: Ensure reliability across OSs.
- **Proposed work**: Linux/macOS builds, terminal/clipboard adapters, packaging and
  PowerShell Core verification. Windows support does not imply these already work.
- Bash/zsh/fish hooks are separate shell-integration work.

### Public Releases and Authenticity
- Publish versioned release artifacts and changelogs when requested.
- Consider signed executables/manifests and publisher verification.
- Existing SHA256 checks detect corruption; they are not signatures.

### Toolchain Maintenance
- Zig 0.16.0 remains the supported compiler. A Zig 0.17 migration requires updating
  build APIs and verifying pinned SQLite/libvaxis dependencies and patches.
- Keep hosted CI optional; local validation remains authoritative unless the
  project explicitly adopts a hosted service.

---

## 2. Security & Compliance

Ensure data hygiene and security for sensitive command history.

### Active Secret Redaction
- **Goal**: Prevent sensitive credentials entering persisted history and payloads.
- **Proposed work**: shared, configurable sanitization across shell recording,
  direct CLI input and imports. `src/db/write.zig` was retired; the current writer
  is `src/db/record.zig` and durable payloads originate in `scripts/zsprofile.ps1`.
- Sanitize **before the pending JSON file is written**, not merely before SQL
  insertion. Otherwise a failed recording still leaves plaintext credentials.
- Test token formats, quoting, multiline input, false positives and safe exclusions.
- Redacted commands must not be silently treated as executable originals.

### Leading-Space Privacy Mode
- Opt out of recording an individual command by prefixing it with a space.
- Preserve existing PSReadLine filtering decisions and make this behavior opt-in.

### Safe Deletion and Duplicate Cleanup
- Add deletion by execution ID or exact command, with confirmation/dry-run and
  backup or undo policy. Keep event IDs stable for unaffected entries.
- Update counts, decay keys, latest links, directory locations and FTS atomically.
- Offer **explicit** cleanup of duplicates created by old imports. Identical command
  text alone is not proof that two executions are duplicates; never prune silently.

### At-Rest Encryption
- **Goal**: Protect history database if file is exfiltrated.
- **Proposed work**:
  - Evaluate SQLCipher-compatible readers/writers and migration/key recovery.
  - Prefer evaluating whole-database encryption, including the search index.
  - Include WAL, backups, pending payloads, key storage/recovery and upgrade behavior.
  - Column encryption alone conflicts with indexed substring search and can still
    leak secrets through plaintext FTS or other indexes; it is not a drop-in fix.

---

## 3. Advanced Intelligence (AI)

Current suggestions come from local history and exponential frecency, not an LLM.
The following prediction policies and AI integrations remain optional ideas.

### Directory/Repository-Aware Predictions
- Prefer current-directory or repository history, with a configurable global fallback.
- Cache keys/invalidation must include context, not just the input prefix.
- Define repository boundaries and path/case semantics; do not accidentally match
  unrelated directories with a naive string prefix.

### Failure-Aware Suggestions
- Optionally suppress or down-rank known typos and consistently failing commands.
- Distinguish known failures from unknown legacy/imported status; absence of a
  recorded success is not sufficient evidence that a command is invalid.
- Schema 3 has success counts; failure policy is **not** currently applied.

### Configurable Ranking
- Expose supported tuning for the half-life, context and suggestion limits.
- A half-life change requires an atomic score-key rebuild and matching policy
  metadata. Changing only a configuration value would mix incompatible score units.

### Local LLM Integration
- **Goal**: Natural language command suggestions.
- **Proposed API, not available**: `zigstory suggest "<intent>"`.
- Consider an optional local Ollama-compatible backend; model choice is not fixed.
- Network/history access must be explicit and privacy-preserving. Return suggestions
  for inspection, never automatically execute generated commands.
- Explain assumptions and potentially destructive effects; do not present model
  output or frecency as a calibrated confidence percentage.

### Workflow Graphing
- **Goal**: Predict sequences of commands.
- **Proposed work**:
  - Analyze `session_id` sequences.
  - Build Markov chain or simple graph.
  - Suggest next logical command (e.g., `git push` after `git commit`).

---

## 4. Deep Shell Integrations

### Terminal Multiplexer Context (Tmux / Zellij)
- **Goal**: Context-aware history per session/pane.
- **Proposed work**:
  - Capture **Session Name** or **Window Title**.
  - Store as new column in DB.
  - Filter history by "Project Context" (e.g., Backend vs Frontend tabs).

### SSH / Remote Aggregation
- **Goal**: Unified history across servers.
- **Proposed work**:
  - "Headless" agent mode for remote servers.
  - Forward history back to local machine via secure channel.
- Define authentication, permissions, stable event identities and conflict handling.
- Sharing/export must be opt-in and sanitized; local-only operation remains the default.

### Multi-Shell Hooks
- Add bash/zsh/fish integrations with accurate exit status, execution time, starting
  directory and session capture, plus durable retry behavior.
- Starship supports multiple shells; zigstory does not inherit that support automatically.

---

## 5. TUI Power Features

### Search the Current Command Line
- Capture the PSReadLine buffer when Ctrl+R is pressed and supply it as the initial query.
- Define whether selection replaces the full line or a selected range; cancellation
  must preserve the existing line and cursor position.
- A search-query CLI option and hook changes are still needed.

### Full-Command Preview
- Show full multiline text, directory, exact timestamp, duration, exit status,
  execution count and session/host information without executing anything.
- Keep memory bounded and sanitize terminal control sequences in display output.

### Richer Filters
- Add session, hostname, success/failure and date-range filters using recorded metadata.
- Repository and recursive-directory filters require explicit boundary semantics.
- Preserve accurate counts, latest matching execution, paging and selections.

### Sort Options and Multi-Word Search
- Toggle recent, frecency and frequency ordering with deterministic ties.
- Support noncontiguous multi-word queries, such as `status git` matching `git status`.
- Define quoting, AND/OR and highlighting rules; do not silently replace existing
  literal substring semantics. Keep indexed candidate lookup and cache invalidation.

### Macro/Script Generator
- **Goal**: Turn history into reusable scripts.
- **Proposed work**:
  - Multi-select commands in TUI.
  - Hotkey (e.g., `Ctrl+S`) to "Save as Script".
  - Generate a `.ps1` script/function for review and explicit saving/export.
- Multi-select exists, but currently joins selections with a pipe. Offer newline
  or `;` joins, order editing and feedback when the five-selection limit is reached.
- Never auto-execute generated scripts or change command order without confirmation.

### "tldr" Preview Integration
- **Goal**: Instant command documentation.
- **Proposed work**:
  - Prefer local/cached `tldr` pages for the selected command; network fetches are opt-in.
  - Display in side panel/popup in TUI.

## 6. CLI and Data Management

### Machine-Readable Reports
- Add structured JSON output to `list` and `stats`, including documented fields,
  filtering and timezone semantics. These commands currently produce text only.
- `zigstory perf --cwd <path> --format json` already exists.

### Installation and History Diagnostics
- Proposed `zigstory doctor`: verify installed components, schema/policy versions,
  native SQLite, predictor registration, pending recordings and index health.
- Default output must not expose command text or secrets. Repairs must be explicit.

### Export and Cross-Machine Merge
- Add export/import schemas that preserve execution identities and metadata.
- Use event identities for idempotent merging; local integer command/directory IDs
  are not portable identifiers, and old events without event IDs need a stable policy.
- Include schema/version compatibility, privacy controls and recoverable failure paths.

## 7. Remaining Performance Experiments

- Draw before terminal capability negotiation only after lifecycle and Unicode-width
  correctness are verified across supported terminals.
- Narrow prior candidate sets during incremental typing while preserving exact query,
  directory, backspace and committed-write invalidation semantics.
- Benchmark cold assembly/JIT loading and full input-to-display latency separately
  from warm SQL/renderer timings. Do not assume existing gates measure physical pixels.
- Immediate per-event recording remains required. Timer batching and a persistent
  writer/daemon are not part of the current agreed direction.

---

# Starship Prompt Engine Integration

> **Status**: Optional integration ideas; no Starship module or prediction CLI is implemented.

The existing PowerShell hook preserves custom prompts. Adding zigstory output to
Starship is separate work and must not replace the user's prompt, duplicate
prediction handlers, or overwrite existing key bindings without permission.

## Recommended approach: cached, opt-in summaries

Refresh a per-directory/session summary outside prompt rendering, then display it
through an optional `[custom.zigstory]` module. Define private cache location,
expiry, atomic replacement, committed-write invalidation and stale/missing-data
behavior. Command text should be excluded unless the user explicitly opts in.

Do **not** run `zigstory` or start a PowerShell process synchronously for every
prompt and assume it costs only 5–10 ms. Local profiling has demonstrated material
process-launch overhead. Even a cached custom module may still spawn its configured
shell; measure that cost. A native Starship integration is a larger optional
alternative if measurements justify it, not a prerequisite for the first version.

## Candidate prompt features

| Idea | Available foundation | Work still needed |
| --- | --- | --- |
| Directory count and last status | Recorded directory/exit metadata | Cached report formatting and an opt-in custom module |
| Duration/slow-command indicator | Existing directory `perf` JSON | Background refresh and cache expiry; no synchronous query per prompt |
| Session statistics/activity heatmap | Session IDs and timestamps | Session/time filters, aggregate output and cache policy |
| Repository intelligence | Directory identities and history | Repository boundaries, repository-scoped reports and optional prediction |
| Context-sensitive segments | Recorded status/duration | Explicit rules for visibility and warnings; avoid unsupported health claims |
| Prediction preview | Existing PowerShell predictor | A supported CLI/IPC API if needed; no invented confidence percentages |
| Search-mode/recent-query indicator | Ctrl+R/Ctrl+F already exist | Optional mode state and privacy-preserving search-history capture |

### Current API facts

- `zigstory perf --cwd <path> --format json` is supported.
- `stats` and `list` currently produce text, not JSON.
- `predict`, `suggest`, `doctor`, `export` and `delete` are proposed commands, not
  available APIs. Any future options/output schema must be implemented and tested
  before documentation presents them as working examples.
- `[custom.zigstory]` names a possible Starship custom module. No native
  `[zigstory]` configuration section is supplied by this project.
- Directory filtering currently exists in the TUI; that does not establish
  repository/session filters or the previously sketched `stats` flags.

### Proposed milestones

1. Define a minimal cached summary and benchmark prompt rendering with/without it.
2. Add documented machine-readable reports and directory/session/repository scope.
3. Test optional prediction/workflow or native-Starship integration only after
   the basic module is useful and measured.

No fixed schedule or latency guarantee is attached to these proposals.

## Longer-term and exploratory ideas

- Local ML, opt-in sanitized team workflows and reusable workflow graphs.
- Smart alias suggestions or assisted Starship configuration, always reviewed
  before changing shell configuration.
- Descriptive activity/error/duration trends; a "shell health" score needs defined
  semantics and should not imply a calibrated measure of productivity.
- Voice or mouse/gesture search, time-based segments and user-selected adaptive
  themes. These are low-priority experiments, not planned features; mood must not
  be inferred as a factual diagnosis from error rates.

## Validation required for future work

- Use isolated fixtures, never alter installed history/configuration during tests.
- Test stable IDs, transactional score/count/FTS repair, Unicode, multiline input,
  literal matching, metadata filters, cache invalidation and bounded memory.
- Verify privacy across payloads, database/FTS, exports, backups and prompt output.
- Include missing/corrupt/locked database and unavailable-cache behavior, concurrent
  shells, migration failures, package compatibility and rollback.
- Benchmark full feature costs, including process/shell startup, cold JIT and
  terminal I/O where applicable. Keep current local gates without replacing them
  with universal latency claims or assuming hosted CI is enabled.
- Update supported CLI schemas, setup/troubleshooting instructions and `PLAN.md`
  only when a proposal is approved and implemented. Configuration examples must
  use actual commands and preserve existing prompts.

## Related resources

- [Starship configuration](https://starship.rs/config/)
- [PSReadLine documentation](https://learn.microsoft.com/powershell/module/psreadline/about/about_psreadline)
