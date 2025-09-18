# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**File Copier Service for SVS Medical Imaging Files**

This is a PowerShell-based service designed to handle large SVS (Aperio ScanScope Virtual Slide) files in medical pathology workflows. Key characteristics:
- File sizes: 500MB - 20GB+ (very large files)
- Critical requirement: No file locking during verification (external polling systems)
- Memory-efficient streaming operations for multi-GB files
- Cross-platform compatibility (Windows/Linux)

## Project Structure

```
forker/
├── development-plan.md          # Master development plan (ALWAYS keep current)
├── modules/FileCopier/          # PowerShell module implementation
│   ├── Configuration.ps1        # JSON config with schema validation
│   ├── Logging.ps1             # Structured logging system
│   ├── Utils.ps1               # Utility functions
│   ├── StreamingCopy.ps1       # Phase 2A: Streaming copy engine
│   └── Verification.ps1        # Phase 2B: Non-locking verification
├── config/                     # Configuration files
├── tests/unit/                 # Pester unit tests
└── forker.code-workspace       # VS Code workspace
```

## Current Status

**Progress:** 4/10 commits completed (40%)
**Completed Phases:** 1A (Configuration), 1B (Logging), 2A (Streaming Copy), 2B (Verification)
**Next Phase:** 3A (FileSystemWatcher Implementation)

See `development-plan.md` for detailed status and phase breakdown.

## CRITICAL WORKFLOW REQUIREMENTS

### Before ANY Significant Commit

**MANDATORY STEPS - NO EXCEPTIONS:**

1. **Use TodoWrite to create task list including:**
   ```
   - [ ] Complete implementation work
   - [ ] Update development-plan.md with completion status
   - [ ] Commit changes with proper message
   - [ ] Push to remote
   ```

2. **ALWAYS update development-plan.md BEFORE committing:**
   - Mark completed phases with ✅
   - Update "Current Status" section with new progress percentage
   - Document actual deliverables and commit hashes
   - Identify next phase
   - Update "Last Updated" date

3. **Commit documentation updates separately** for clean history

### Development Standards

When developing in this repository:
- Follow PowerShell Core 7+ cross-platform approach
- Use class-based architecture for complex modules
- Implement non-locking file operations (FileShare.ReadWrite)
- Memory-efficient streaming for large files (chunked processing)
- Comprehensive unit testing with Pester framework
- Cross-platform compatibility testing

### Key Architectural Constraints

- **No file locking**: External polling processes must access files during operations
- **Atomic operations**: No partial/corrupt files visible to external systems
- **Streaming operations**: Handle 20GB+ files without loading into memory
- **Medical data integrity**: SHA256 verification for critical medical imaging files