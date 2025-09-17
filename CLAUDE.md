# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Structure

This is a minimal repository currently containing:
- `basic-spec.md` - Project specification file (currently empty)
- `forker.code-workspace` - VS Code workspace configuration

## Development Notes

This project has evolved into a comprehensive File Copier Service with enterprise-grade contention testing harness. The main development focus is on implementing the 4-phase contention testing plan outlined in `contention-harness-plan.md`.

### Current Status
- **Phase CT-1A**: Base Framework Structure ✅ COMPLETED (Commits 1-6)
- **Phase CT-2A**: File Contention Tests ✅ COMPLETED (Commits 7-10)
- **Phase CT-2B**: Race Condition Tests ✅ COMPLETED (Commits 11-13)
- **Phase CT-3A**: Resource Monitoring ✅ COMPLETED (Commits 14-16)
- **Phase CT-3B**: Recovery & Cleanup Tests ✅ COMPLETED (Commits 17-19)
- **Phase CT-4**: Performance & Production Validation ⏳ NEXT

### Development Workflow

**IMPORTANT**: Before any commit, always update `contention-harness-plan.md` to reflect completion status:
1. Mark completed tasks with `[x]` checkboxes
2. Update section status indicators (⏳ → ✅)
3. Update success criteria status
4. Commit the plan update along with code changes

When developing in this repository:
- Follow the PowerShell Core 7+ cross-platform approach
- Use class-based test architecture with inheritance from base test classes
- Implement genuine validation with real resource leak detection
- Ensure all tests provide 100% real validation (no faking)
- Cross-platform compatibility for Windows/Linux/macOS