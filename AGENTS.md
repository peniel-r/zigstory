# AI Agent Workflow Guide

**Version 0.1.0** | **Last Updated: January 31, 2026**

---

## Overview

This guide provides AI agents with a structured workflow for integrating with Engram, an ALM tool designed for AI automation.

---

## Core Rules for AI Agents

### Development Rules
- Review and update PLAN.md for implementation planning
- Always ask for review before making commits
- Work is NOT complete until `zig build run` succeeds
- If `zig build run` fails, resolve and retry until success

### Zig Coding Standards
- Use explicit allocator patterns
- Never use global variables for large structs
- Use `ArenaAllocator` for frame-scoped data
- Use `PoolAllocator` for background tasks
- Target Zig version 0.15.2+
- Prefer `ArrayListUnmanaged` for array list implementation

---

## AI Agent Workflow

### Phase 1: Initialization & Context Loading

```bash
# 1. Initialize or verify ALM project
engram init my_project --type alm

# 2. Get project structure (always use JSON)
engram status --json > project_state.json

# 3. Review PLAN.md for implementation context
```

### Phase 2: Query & Analysis

```bash
# Query for relevant artifacts using EQL syntax
# Filter mode - fastest for structured queries
engram query --type requirement --state draft --json

# Semantic search for understanding
engram query --mode vector "authentication issues" --json

# Find untested requirements
engram query "type:requirement AND NOT link(validates, type:test_case)" --json

# Get blocked items
engram query "type:issue AND state:open" --json
```

### Phase 3: Impact Analysis (Before Changes)

```bash
# Always analyze impact before modifications
# Analyze code changes
git diff HEAD~1 --name-only | while read file; do
  engram impact "$file" --json --up --down
done

# Get affected tests for CI/CD
engram impact src/auth/login.zig --json --down | \
  jq -r '.affected_items[] | select(.type == "test_case") | .id'
```

### Phase 4: Decision Making

```bash
# Check release readiness before deployment
engram release-status --json | jq '.ready'

# Get metrics for informed decisions
engram metrics --json

# Trace dependencies
engram trace req.auth.oauth2 --json --depth 3
```

### Phase 5: Execution

```bash
# Create new artifacts
engram new requirement "Feature Title" --description "Description"

# Update artifacts with batch operations
engram update req.auth --set "context.status=implemented" \
  --set "context.assignee=alice" --set "priority=1"

# Generate tests from requirements
engram query "type:requirement AND state:approved" --json | \
  jq -r '.[] | "engram new test_case \"\(.title)\" --validates \(.id)"' | bash
```

### Phase 6: Validation & Sync

```bash
# Sync after any manual edits
engram sync

# Verify with build
zig build run

# Verify test coverage
engram metrics --json | jq '.test_coverage'

# If build fails, analyze impact and create issues
if [ $? -ne 0 ]; then
  engram new issue "Build failure" --priority 1 --blocks req.001
fi
```

### Phase 7: Commit (After Review)

```bash
# Ask for review before committing
# If approved:
git add .
git commit -m "Implement feature with full test coverage"
```

---

## EQL Syntax Reference

### Basic Queries
```
type:requirement
state:implemented
priority:1
tag:security
```

### Logical Operators
```
type:requirement AND state:approved
(type:issue OR type:bug) AND priority:1
type:requirement AND NOT link(validates, type:test_case)
```

### Connection Queries
```
link(validates, req.auth.oauth2)
link(blocks, type:requirement)
```

---

## Search Modes

1. **Filter** - Structured queries (fastest)
2. **Text** - BM25 keyword search
3. **Vector** - Semantic understanding
4. **Hybrid** - Combined search
5. **Activation** - Neural propagation

---

## State Transitions

### Issues: open → in_progress → resolved → closed
### Tests: not_run → running → passing/failing
### Requirements: draft → approved → implemented

---

## Best Practices

1. **Always use `--json` flag** for programmatic access
2. **Cache data** for frequently accessed queries
3. **Use semantic search** for understanding concepts
4. **Chain commands** for complex workflows
5. **Analyze impact** before making changes
6. **Sync after edits** to maintain consistency
7. **Handle errors gracefully** with proper checks
8. **Follow Zig standards** for all code generation
9. **Use explicit allocators** - no globals for large structs
10. **Verify builds** - work incomplete until `zig build run` succeeds

---

## Key Commands Summary

| Command | Purpose | JSON Flag |
|---------|---------|-----------|
| `status` | Project overview | `--json` |
| `query` | Search/filter | `--json` |
| `show <id>` | Get details | `--json` |
| `trace <id>` | Dependency analysis | `--json` |
| `impact <artifact>` | Change impact | `--json` |
| `release-status` | Release readiness | `--json` |
| `metrics` | Statistics | `--json` |
| `new <type>` | Create artifact | N/A |
| `update <id>` | Update artifact | N/A |
| `sync` | Sync data | N/A |

---

*For comprehensive command reference, see docs/AI_AGENTS_GUIDE.md*
