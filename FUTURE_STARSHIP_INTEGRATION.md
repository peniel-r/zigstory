# Future Improvements: Starship Prompt Engine Integration

> **Status**: Ideas Collection | **Created**: February 2, 2026 | **Last Updated**: February 2, 2026

This document outlines potential integrations between **zigstory** (PowerShell history manager) and **Starship** (cross-shell prompt) to enhance the shell experience with intelligent command history and context-aware prompts.

---

## Overview

**Why This Integration Matters:**
- Zigstory already tracks command frequency, exit codes, duration, and directory context
- Starship provides a powerful, customizable prompt engine
- Combining both enables intelligent, context-aware shell prompts that learn from your workflow

**Target Audience:**
- Developers using PowerShell on Windows with Starship
- Users who want predictive shell experiences
- Teams wanting to share and optimize common workflows

---

## Integration Options

### 1. Zigstory Starship Module ⭐ Recommended

Create a custom Starship module to display command history statistics directly in the prompt.

**Features:**
- Recent command count in current directory context
- Last command status indicator (✅/❌)
- Session statistics
- Frecency rank of predicted next command
- History health indicator (success rate visualization)

**Example Prompt:**
```
~/projects/zigstory on  main via 🦀 v1.85
❯ zigstory search          [💾 12,453 cmds] [🎯 top: git status] [✅ 94%]
```

**Implementation:**
```toml
# In starship.toml
[zigstory]
format = "[$symbol $status]($style) "
symbol = "💾"
detect_files = [".zigstory/history.db"]
disabled = false

# Alternative: custom command module
[custom.zigstory]
description = "Zigstory history info"
when = "zigstory stats --json"
shell = ["pwsh", "-c"]
symbol = "💾"
```

**Effort:** Medium | **Priority:** High | **Dependencies:** None (uses existing zigstory commands)

---

### 2. Pre-Execution Hook Integration

Add a Starship-aware hook before each command executes to provide predictive context.

**Features:**
- Prediction preview (ghost text of predicted next command)
- Context awareness (display current directory's command frequency)
- Frecency boost (highlight frequently-used commands)

**Implementation:**
```powershell
# Add to PowerShell profile (zsprofile.ps1)
function Invoke-StarshipPreCommand {
    $prediction = zigstory predict --cwd $PWD --json | ConvertFrom-Json
    if ($prediction) {
        $env:ZIGSTORY_PREDICTION = $prediction.command
        $env:ZIGSTORY_CONFIDENCE = $prediction.confidence
    }
}

# Hook into Starship
Invoke-Expression (&starship init powershell)
```

**Example Output:**
```
~/projects/zigstory on  main via 🦀 v1.85
❯ [🔮 87% confidence: git commit -m ]
```

**Effort:** Medium | **Priority:** High | **Dependencies:** Requires zigstory `predict` command (to be implemented)

---

### 3. Git Repository Intelligence

Leverage zigstory's directory filtering to enhance git-related prompts with history awareness.

**Features:**
- Show last git command executed in this repository
- Predict next git command based on repository history
- Display repository-specific command statistics
- Highlight most common git workflows per repository

**Example:**
```
~/projects/zigstory on  main via 🦀 v1.85
❯ [📊 git: 142 cmds] [🔄 next: git commit -m] [🔥 workflow: dev-hotfix]
```

**Implementation:**
```toml
[custom.zigstory_git]
description = "Repository-specific git history"
symbol = "📊"
when = '''
  if (git rev-parse --is-inside-work-tree 2>$null) { return $true }
  return $false
'''
shell = ["pwsh", "-NoProfile", "-Command"]
command = '''
  $repo = git rev-parse --show-toplevel
  zigstory stats --directory "$repo" --filter "^git " --format json | 
    ConvertFrom-Json
'''
```

**Effort:** Medium | **Priority:** Medium | **Dependencies:** Requires zigstory directory filtering

---

### 4. Context-Sensitive Prompt Segments

Use zigstory's context to dynamically adjust Starship segments based on user behavior.

**Features:**
- Segment visibility based on command frequency
- Dynamic color schemes based on project health
- Warning segments for risky commands (e.g., `rm -rf`, `git push --force`)
- Success indicators for recent test runs

**Conceptual Implementation:**
```rust
// Starship module in Rust (future approach)
pub struct ZigstoryModule {
    cwd: String,
    recent_commands: Vec<Command>,
    frecency: f64,
}

impl Module for ZigstoryModule {
    fn render(&self) -> Option<Segment> {
        let confidence = self.calculate_confidence();
        let top_cmd = self.most_frequent_command()?;

        Some(Segment::new(&format!(
            "{} {}",
            self.style(confidence),
            top_cmd.truncated(20)
        )))
    }

    fn style(&self, confidence: f64) -> Style {
        if confidence > 0.8 {
            Style::new().green().bold()
        } else if confidence > 0.5 {
            Style::new().yellow()
        } else {
            Style::new().dimmed()
        }
    }
}
```

**Example:**
```
~/projects/zigstory via ⚠️ [last test failed] via 🔥 [high-risk directory]
❯
```

**Effort:** Large | **Priority:** Medium | **Dependencies:** Rust Starship module development

---

### 5. Performance Monitoring

Add performance metrics to your prompt to track command execution patterns.

**Features:**
- Average command duration in current directory
- Slow command warnings (highlight if last command >5s)
- Session efficiency (success rate, average duration)
- Performance trend indicators

**Example:**
```
~/projects/zigstory via ⚡ 2.3s avg [📉 15% slower than yesterday]
❯
```

**Implementation:**
```toml
[custom.zigstory_perf]
description = "Command performance metrics"
symbol = "⚡"
when = "zigstory stats --cwd $PWD --duration --format json 2>$null"
shell = ["pwsh", "-NoProfile", "-Command"]
command = '''
  zigstory stats --cwd $PWD --duration --format json | 
    ConvertFrom-Json | 
    Select-Object -ExpandProperty avg_duration_ms
'''
```

**Effort:** Low | **Priority:** Low | **Dependencies:** None (uses existing zigstory duration tracking)

---

### 6. Search Integration Shortcut

Create a Starship command alias/shortcut for instant search access directly from prompt.

**Features:**
- One-key shortcut to launch zigstory search
- Visual indicator when search mode is active
- Recent search history in prompt
- Quick access to last 5 searches

**Implementation:**
```powershell
# Starship custom command module
[custom.zigsearch]
description = "Quick zigstory search"
symbol = "🔍"
style = "bold blue"
shell = ["pwsh", "-c"]
format = "via [$output]($style)"
when = '''
  if ($env:ZIGSTORY_MODE -eq "search") { return $true }
  return $false
'''
command = '''
  echo "search active"
'''
```

**Usage:**
```
~/projects/zigstory via 🔍 [search active]
❯ git stat[press Enter for search]
```

**Effort:** Low | **Priority:** Low | **Dependencies:** None (uses existing zigstory search)

---

### 7. Directory-Based Stats

Show directory-specific command history and patterns in the prompt.

**Features:**
- Commands executed in current directory (count)
- Top commands for this directory
- Project health (success rate, average duration)
- Activity heatmap (when this project is most used)

**Example:**
```
~/projects/zigstory [💼 847 cmds] [✨ active: 9am-12pm] [🎯 top: git status]
❯
```

**Implementation:**
```toml
[custom.zigstory_dir]
description = "Directory-specific statistics"
symbol = "💼"
when = '''
  if (Test-Path ~/.zigstory/history.db) { return $true }
  return $false
'''
shell = ["pwsh", "-NoProfile", "-Command"]
command = '''
  zigstory stats --cwd $PWD --top 1 --format json | 
    ConvertFrom-Json | 
    ForEach-Object { "$($_.total_cmds) cmds | top: $($_.top_cmd)" }
'''
```

**Effort:** Low | **Priority:** Medium | **Dependencies:** None (uses existing zigstory stats)

---

## Implementation Roadmap

### Phase 1: Simple Integration (1-2 days)

**Goals:**
- Add basic zigstory stats to Starship prompt
- Display last command exit code as indicator
- Show history count in prompt

**Tasks:**
1. [ ] Create `zigstory` custom module for Starship
2. [ ] Add command count display
3. [ ] Add exit code indicator (✅/❌)
4. [ ] Test with existing zigstory installation

**Effort Estimate:** 4-6 hours

---

### Phase 2: Interactive Features (3-5 days)

**Goals:**
- Implement prediction preview with Starship
- Add git repository intelligence
- Directory context awareness

**Tasks:**
1. [ ] Implement zigstory `predict` command (if not exists)
2. [ ] Create `Invoke-StarshipPreCommand` hook
3. [ ] Add git repository history module
4. [ ] Implement directory filtering for stats
5. [ ] Add confidence score display

**Effort Estimate:** 16-24 hours

---

### Phase 3: Advanced Analytics (1-2 weeks)

**Goals:**
- Build Rust Starship module for performance
- Real-time frecency tracking
- Heatmap and trend visualization

**Tasks:**
1. [ ] Set up Rust development environment
2. [ ] Create zigstory Starship module crate
3. [ ] Implement async database queries
4. [ ] Add frecency calculation in Rust
5. [ ] Implement visualization components
6. [ ] Performance testing and optimization

**Effort Estimate:** 40-80 hours

---

## Quick Start Example

**Add to `starship.toml`:**
```toml
[custom.zigstory]
description = "Zigstory history stats"
symbol = "💾"
format = " [$symbol$output]($style) "
style = "bold purple"
shell = ["pwsh", "-NoProfile", "-Command"]
when = "if (Test-Path ~/.zigstory/history.db) { $true }"
command = '''
  zigstory list 1 --json | ConvertFrom-Json | 
    ForEach-Object { $_.cmd.Substring(0, [Math]::Min(30, $_.cmd.Length)) }
'''
```

**Example Output:**
```
~/projects/zigstory via 💾 zigstory search
❯
```

---

## Design Considerations

### ✅ Benefits

- **Non-invasive**: Works with existing Starship configuration
- **Context-aware**: Provides directory-specific insights
- **Performance-focused**: Async queries, caching for sub-100ms render times
- **Customizable**: Show/hide modules based on user preference
- **Cross-platform**: PowerShell 7+ works on Linux/macOS/Windows

### ⚠️ Considerations

- **Performance impact**: Adds ~5-10ms to prompt render time (mitigate with caching)
- **Dependencies**: Requires zigstory binary in PATH
- **Database availability**: Depends on .zigstory/history.db accessibility
- **Privacy**: Local-only processing, no data leaves the system

---

## Additional Ideas

### Future Enhancements

1. **ML Integration**: Use machine learning to improve prediction accuracy
2. **Team Workflows**: Share common command patterns across team members
3. **Automated Profiles**: Suggest Starship configuration based on zigstory patterns
4. **Health Scoring**: Calculate a "shell health" score based on error rates, command efficiency
5. **Smart Aliases**: Suggest and create aliases based on frequently-used command patterns
6. **Multi-shell Support**: Extend support to zsh, bash, fish (already supported by Starship)

### Experimental Features

1. **Voice Integration**: "Hey zigstory, what was that git command?"
2. **Gesture-based Search**: Use mouse gestures to trigger search
3. **Time-based Context**: Show different prompt segments based on time of day
4. **Mood Detection**: Adjust prompt style based on error rates (e.g., encouraging messages after failures)

---

## Testing Strategy

### Unit Tests
- Test zigstory command parsing for Starship modules
- Test JSON output formatting for custom modules
- Test exit code detection and display

### Integration Tests
- Test Starship module with various zigstory database states
- Test performance with large databases (10,000+ commands)
- Test error handling when database is unavailable

### Performance Benchmarks
- Measure prompt render time with/without zigstory integration
- Test with concurrent access (multiple terminal sessions)
- Optimize query performance for real-time display

---

## Documentation Needs

### User Documentation
- Setup guide for zigstory + Starship integration
- Configuration examples for common use cases
- Troubleshooting common issues
- Performance tuning guide

### Developer Documentation
- API reference for zigstory Starship module (if implemented in Rust)
- Schema documentation for JSON outputs
- Contribution guidelines for new modules

---

## Related Resources

- **Starship Documentation**: https://starship.rs/config/
- **Zigstarship Project**: https://github.com/zigstarship/zigstarship (conceptual reference)
- **PowerShell Prompt Customization**: https://docs.microsoft.com/en-us/powershell/module/psreadline/about/about_psreadline

---

## Next Steps

**Immediate (Week 1):**
1. Evaluate Phase 1 implementation feasibility
2. Create basic custom module for Starship
3. Test with existing zigstory installation

**Short-term (Month 1):**
1. Implement Phase 2 features
2. Create PowerShell integration hooks
3. Document setup process

**Long-term (Quarter 1):**
1. Evaluate Rust module implementation
2. Consider ML integration for predictions
3. Gather user feedback and iterate

---

## Changelog

| Date | Version | Changes |
|------|---------|---------|
| 2026-02-02 | 1.0.0 | Initial documentation of Starship integration ideas |

---

## Questions & Open Issues

| Question | Priority | Status |
|----------|----------|--------|
| Should zigstory predictions be cached in memory? | Medium | Open |
| What's the acceptable prompt render time threshold? | High | Open |
| Should we support multiple shells beyond PowerShell? | Low | Open |
| Should zigstory predict commands outside of git context? | Medium | Open |

---

## Contributing

If you want to implement any of these improvements:

1. **Pick an integration** from the list above
2. **Create an issue** to track your progress
3. **Follow the roadmap** for your chosen phase
4. **Document your changes** in this file
5. **Add tests** for your implementation

---

## License

This integration documentation follows the same license as the zigstory project.

---

*Last updated: February 2, 2026*
