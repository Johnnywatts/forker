# File Copier Service - Development Plan

## Project Context: SVS File Handling

**SVS Files (Aperio ScanScope Virtual Slide):**
- Typical size: 500MB - 20GB+ (very large files)
- Format: Pyramidal TIFF with multiple resolution layers
- Usage: Digital pathology workflows with automated processing
- Critical: Cannot be corrupted - medical data integrity essential
- Polling patterns: External systems scan target directories every 30-60 seconds

**Key Constraints:**
- No file locking during verification (polling processes must access files)
- Large file copying must not block system resources
- Atomic operations essential (no partial/corrupt files visible to polling)
- Memory-efficient streaming for multi-GB files

## Development Phases

### Phase 1: Core Infrastructure (Week 1-2)
**Goal:** Establish foundational components and testing framework

#### Phase 1A: Project Structure & Configuration (Commit 1)
**Tasks:**
- Create PowerShell module structure
- Implement Configuration.psm1 with JSON schema validation
- Create default configuration for SVS workflow
- Set up Pester testing framework

**Deliverables:**
```
modules/FileCopier/
├── FileCopier.psd1
├── Configuration.ps1
└── Utils.ps1
config/
├── settings.json
├── settings.schema.json
└── settings-svs.json          # SVS-optimized config
tests/unit/
└── Configuration.Tests.ps1
```

**Unit Tests:**
- Configuration loading from JSON
- Schema validation (valid/invalid configs)
- Environment variable override functionality
- Default value handling

**Commit Message:** `feat: Add configuration management with JSON schema validation`

#### Phase 1B: Logging Infrastructure (Commit 2)
**Tasks:**
- Implement Logging.psm1 with structured logging
- Windows Event Log integration
- File-based logging with rotation
- Performance counter hooks

**Unit Tests:**
- Log message formatting
- Log level filtering
- File rotation logic
- Event log source creation

**Commit Message:** `feat: Implement comprehensive logging with Event Log integration`

### Phase 2: File Operations Core (Week 2-3)
**Goal:** Implement safe, streaming file operations for large files

#### Phase 2A: Streaming Copy Engine (Commit 3)
**Tasks:**
- Implement CopyEngine.ps1 with streaming support
- Chunked copying for large files (1MB chunks)
- Memory-efficient file handling
- Progress tracking for large files

**Unit Tests:**
- Small file copying accuracy
- Large file streaming (test with 100MB+ files)
- Copy progress calculation
- Memory usage validation (max 50MB for any file size)
- Timestamp/attribute preservation

**Commit Message:** `feat: Add streaming copy engine for large file support`

#### Phase 2B: Non-Locking Verification (Commit 4)
**Tasks:**
- Implement Verification.ps1 with SHA256 streaming hash
- Size + timestamp fallback verification
- Retry logic for temporarily locked files
- Performance optimization for large files

**Unit Tests:**
- Hash calculation accuracy vs .NET crypto
- Streaming hash for large files
- Verification retry mechanism
- Performance: <2% CPU overhead during verification

**Commit Message:** `feat: Implement non-locking file verification with streaming hash`

### Phase 3: Directory Monitoring (Week 3-4)
**Goal:** Reliable file system monitoring and queuing

#### Phase 3A: FileSystemWatcher Implementation (Commit 5)
**Tasks:**
- Implement FileWatcher.ps1 with FileSystemWatcher
- File completion detection (SVS files written progressively)
- Queue management for multiple files
- Subdirectory monitoring support

**Unit Tests:**
- File detection accuracy
- File completion detection (wait for file stability)
- Multiple file queuing
- Large file detection handling

**Commit Message:** `feat: Add directory monitoring with file completion detection`

#### Phase 3B: Processing Queue (Commit 6)
**Tasks:**
- Implement thread-safe processing queue
- FIFO processing with concurrent copy support
- Error handling and retry logic
- File state management

**Unit Tests:**
- Queue operations (add, remove, peek)
- Concurrent processing simulation
- Error recovery scenarios
- State persistence across restarts

**Commit Message:** `feat: Implement thread-safe file processing queue`

### Phase 4: Integration & Service Framework (Week 4-5)
**Goal:** Complete service integration and error handling

#### Phase 4A: Main Service Logic (Commit 7)
**Tasks:**
- Implement FileCopier.psm1 main orchestration
- Service lifecycle management
- Graceful shutdown handling
- Configuration hot-reload

**Integration Tests:**
- End-to-end single file processing
- Service start/stop/restart scenarios
- Configuration reload without service restart
- Graceful shutdown with active copies

**Commit Message:** `feat: Implement main service orchestration with lifecycle management`

#### Phase 4B: Error Handling & Recovery (Commit 8)
**Tasks:**
- Comprehensive error categorization
- Exponential backoff retry logic
- Failed file quarantine system
- Audit logging

**Integration Tests:**
- Transient error recovery (locked files, network issues)
- Permanent error handling (permissions, disk space)
- Failed file quarantine workflow
- Error escalation scenarios

**Commit Message:** `feat: Add comprehensive error handling and recovery mechanisms`

### Phase 5: Service Deployment (Week 5-6)
**Goal:** NSSM service integration and deployment automation

#### Phase 5A: Service Scripts (Commit 9)
**Tasks:**
- Create Start-FileCopier.ps1 service entry point
- Implement Install-Service.ps1 NSSM installer
- Service configuration templates
- Health check endpoint

**Integration Tests:**
- NSSM service installation/removal
- Service auto-start functionality
- Service failure recovery
- Health check validation

**Commit Message:** `feat: Add NSSM service integration and deployment scripts`

#### Phase 5B: Monitoring & Diagnostics (Commit 10)
**Tasks:**
- Performance counters implementation
- Diagnostic commands and utilities
- Service monitoring dashboard
- Troubleshooting documentation

**Integration Tests:**
- Performance counter accuracy
- Diagnostic command functionality
- Monitoring data collection
- Long-running service stability

**Commit Message:** `feat: Implement service monitoring and diagnostic utilities`

## Testing Strategy

### Unit Tests (Pester Framework)
**Coverage Target:** >90% code coverage

**Test Categories:**
1. **Configuration Tests**
   - Valid/invalid JSON parsing
   - Schema validation
   - Environment variable overrides
   - Default value handling

2. **File Operation Tests**
   - Copy accuracy (binary comparison)
   - Hash calculation verification
   - Streaming operations memory usage
   - Error condition handling

3. **Logging Tests**
   - Log message formatting
   - Event log integration
   - File rotation functionality
   - Performance impact measurement

**Mock Strategy:**
- Mock file system operations for unit tests
- Use temporary directories for integration tests
- Mock Windows Event Log for unit tests

### Integration Tests
**Test Environment:**
- Dedicated test directories (Source, TargetA, TargetB, Error)
- Test SVS files (100MB, 1GB, 5GB samples)
- Simulated polling processes

**Test Scenarios:**

#### IT1: Basic File Processing
```powershell
# Test: Single 100MB SVS file end-to-end
- Copy test SVS file to source directory
- Verify file appears in both targets
- Verify source file removed
- Verify hash integrity
- Measure processing time (<2 minutes for 100MB)
```

#### IT2: Concurrent File Processing
```powershell
# Test: 5 files simultaneously (500MB each)
- Copy 5 test files to source at same time
- Verify all files processed correctly
- Verify no file corruption
- Verify memory usage <500MB during processing
```

#### IT3: Polling Conflict Simulation
```powershell
# Test: Simulate external polling during copy
- Start file copy process
- Run simulated poller every 5 seconds on targets
- Verify poller never gets locked files
- Verify copy completes successfully
- Measure poller response time consistency
```

#### IT4: Service Lifecycle
```powershell
# Test: Service restart during file processing
- Start large file copy (2GB+)
- Stop service mid-process
- Restart service
- Verify file reprocessed correctly
- Verify no partial files in targets
```

#### IT5: Error Recovery
```powershell
# Test: Target directory unavailable
- Start file processing
- Simulate network drive disconnection
- Verify retry attempts
- Restore network connection
- Verify successful completion
```

### Stress Tests
**Objective:** Prove non-blocking operation under heavy load

#### ST1: Large File Stress Test
**Setup:**
- 10 SVS files, 2-5GB each
- Process simultaneously
- Monitor for 2 hours continuous operation

**Success Criteria:**
- All files copied successfully
- No memory leaks (memory usage stable)
- System remains responsive
- No file corruption (hash verification passes)

#### ST2: Polling Conflict Stress Test
**Setup:**
- Continuous file processing (new 1GB file every 5 minutes)
- Aggressive polling simulation (every 10 seconds)
- Run for 24 hours

**Polling Simulator:**
```powershell
# Simulate pathology system polling
while ($true) {
    $start = Get-Date
    $files = Get-ChildItem $TargetA -Filter "*.svs"
    foreach ($file in $files) {
        # Simulate file processing attempt
        try {
            $stream = [System.IO.File]::OpenRead($file.FullName)
            $buffer = New-Object byte[] 1024
            $bytesRead = $stream.Read($buffer, 0, 1024)
            $stream.Close()

            # Simulate processing decision
            if ($bytesRead -gt 0) {
                Remove-Item $file.FullName -Force
                Write-Host "Processed: $($file.Name)"
            }
        }
        catch {
            Write-Warning "File locked: $($file.Name)"
        }
    }
    $elapsed = (Get-Date) - $start
    Write-Host "Poll cycle: $($elapsed.TotalMilliseconds)ms"
    Start-Sleep -Seconds 10
}
```

**Success Criteria:**
- Polling process never blocked >100ms
- No "file in use" errors from poller
- Copy service maintains throughput
- No data corruption or loss

#### ST3: Resource Exhaustion Test
**Setup:**
- Fill source directory with 100+ SVS files
- Limited system resources (4GB RAM limit)
- Simulate low disk space conditions

**Success Criteria:**
- Graceful handling of resource constraints
- Appropriate error logging
- Service recovery when resources available
- No system crashes or hangs

#### ST4: Network Stability Test
**Setup:**
- Target directories on network shares
- Simulate network interruptions
- Varying network latency (50-500ms)

**Success Criteria:**
- Automatic retry on network failures
- Complete file transfers despite interruptions
- No partial files visible to polling processes
- Accurate error reporting and recovery

## Performance Benchmarks

### Target Performance Metrics
- **Throughput:** 1GB per minute per target (2GB/min total)
- **Memory Usage:** <100MB regardless of file size
- **CPU Usage:** <20% during normal operations
- **Verification Overhead:** <5% additional time
- **Polling Impact:** Zero blocking, <10ms additional latency

### Benchmark Tests
```powershell
# Performance measurement script
function Measure-CopyPerformance {
    param($TestFiles, $Iterations = 3)

    foreach ($file in $TestFiles) {
        $measurements = @()
        for ($i = 0; $i -lt $Iterations; $i++) {
            $start = Get-Date
            # Trigger file copy
            Copy-Item $file $SourceDirectory
            # Wait for completion
            while (Test-Path (Join-Path $SourceDirectory (Split-Path $file -Leaf))) {
                Start-Sleep -Milliseconds 100
            }
            $end = Get-Date
            $measurements += ($end - $start).TotalSeconds
        }

        $avgTime = ($measurements | Measure-Object -Average).Average
        $throughput = (Get-Item $file).Length / 1MB / $avgTime

        Write-Host "File: $(Split-Path $file -Leaf)"
        Write-Host "  Average Time: $([math]::Round($avgTime, 2))s"
        Write-Host "  Throughput: $([math]::Round($throughput, 2)) MB/s"
    }
}
```

## Commit Strategy

### Commit Message Format
```
<type>: <description>

<body describing what and why>

Tests: <test coverage added>
Breaking: <any breaking changes>
```

### Branch Strategy
- `main` - Production ready code
- `develop` - Integration branch
- `feature/phase-X` - Feature development branches
- `test/stress-testing` - Dedicated testing branch

### Pre-commit Hooks
1. **Pester Tests:** All unit tests must pass
2. **Code Analysis:** PSScriptAnalyzer with strict rules
3. **Documentation:** All public functions documented
4. **Configuration:** Validate all JSON schemas

### Release Milestones

#### v0.1.0 - Core Infrastructure
- Configuration management
- Logging framework
- Basic testing setup

#### v0.2.0 - File Operations
- Streaming copy engine
- Non-locking verification
- Memory-efficient processing

#### v0.3.0 - Directory Monitoring
- File system monitoring
- Processing queue
- File completion detection

#### v0.4.0 - Service Integration
- Main orchestration logic
- Error handling and recovery
- Integration test suite

#### v1.0.0 - Production Release
- NSSM service integration
- Complete documentation
- Stress test validation
- SVS file compatibility certified

## Risk Mitigation

### Technical Risks
1. **Large File Memory Usage**
   - Mitigation: Streaming operations, chunked processing
   - Validation: Memory usage tests with 10GB+ files

2. **Polling Process Conflicts**
   - Mitigation: Non-locking verification, atomic operations
   - Validation: Continuous stress testing with simulated polling

3. **SVS File Corruption**
   - Mitigation: SHA256 verification, atomic visibility
   - Validation: Byte-by-byte comparison tests

4. **Service Reliability**
   - Mitigation: NSSM automatic restart, comprehensive error handling
   - Validation: 24-hour stability tests

### Operational Risks
1. **Configuration Complexity**
   - Mitigation: JSON schema validation, sensible defaults
   - Validation: Configuration error handling tests

2. **Troubleshooting Difficulty**
   - Mitigation: Comprehensive logging, diagnostic utilities
   - Validation: Troubleshooting scenario documentation

This development plan ensures robust handling of large SVS files while maintaining non-blocking operation for external polling processes through careful testing and validation at each phase.