# Enterprise Contention Test Harness - Architectural Design

## Overview

This document defines the architecture for a comprehensive test harness capable of executing the 35 enterprise-grade file contention resilience tests defined in `contention_resilience_tests.md`. The harness must reliably reproduce race conditions, validate atomic operations, and provide deterministic results across different platforms.

## Design Principles

### 1. **Deterministic Race Conditions**
- Use synchronization primitives to create reproducible "simultaneous" operations
- Implement precise timing control for contention scenarios
- Handle platform-specific timing variations gracefully

### 2. **Process Isolation & Safety**
- Each test runs in isolated process contexts to simulate real-world contention
- Graceful handling of process failures and cleanup
- No test should affect system stability or other tests

### 3. **Comprehensive Validation**
- Validate not just success/failure, but the quality of failure handling
- Monitor system resources throughout test execution
- Verify atomic operation guarantees under stress

### 4. **Cross-Platform Consistency**
- Abstract platform differences while testing platform-specific behaviors
- Consistent test results across Windows and Linux
- Platform-aware expected outcomes where behaviors legitimately differ

## Architecture Components

### **1. Test Orchestrator (`Contention-TestHarness.ps1`)**

**Purpose**: Central coordinator for all contention tests
**Responsibilities**:
- Load test definitions from configuration files
- Initialize test environment and cleanup
- Execute tests in isolation with proper sequencing
- Aggregate results and generate comprehensive reports
- Handle global error conditions and cleanup

```powershell
# Core Interface
Start-ContentionTestSuite -TestCategories @("FileBlocking", "RaceConditions")
                         -Platform "Linux"
                         -ReportFormat "Detailed"
                         -ParallelExecution $false
```

**Key Features**:
- Test isolation with separate PowerShell runspaces/processes
- Resource monitoring and leak detection
- Configurable test execution (sequential vs parallel)
- Comprehensive logging with timing data
- Emergency cleanup procedures

### **2. Process Coordinator (`ProcessCoordinator.ps1`)**

**Purpose**: Manages multi-process synchronization and communication
**Responsibilities**:
- Spawn and manage competing processes for each test
- Provide synchronization primitives (barriers, semaphores)
- Coordinate precise timing for race condition tests
- Collect results from multiple processes
- Handle process failures and cleanup

**Synchronization Mechanisms**:
```powershell
# Barrier synchronization for "simultaneous" operations
$barrier = New-ProcessBarrier -ProcessCount 3 -TimeoutSeconds 30
Wait-ProcessBarrier $barrier  # All processes wait here
# Now all processes execute "simultaneously"

# Shared state for coordination
$sharedState = New-SharedMemoryRegion -Size 4KB
Set-SharedValue $sharedState "test_phase" "ready_to_start"
```

**Process Management**:
- Process spawning with inherited environment
- Inter-process communication via named pipes/shared memory
- Process lifecycle management (start, monitor, cleanup)
- Timeout handling and forced termination

### **3. Resource Monitor (`ResourceMonitor.ps1`)**

**Purpose**: Monitor system resources and validate state during tests
**Responsibilities**:
- Track file handles, locks, and memory usage
- Monitor filesystem state (partial files, temporary files)
- Detect resource leaks and cleanup failures
- Validate atomic operation properties

**Resource Tracking**:
```powershell
# File handle monitoring
$handleTracker = Start-FileHandleMonitor -ProcessIds $testProcesses
$initialHandles = Get-ProcessFileHandles $pid

# Lock state monitoring (platform-specific)
$lockMonitor = Start-FileLockMonitor -Path $testDirectory
$activeLocks = Get-FileLocks -Path $testFile

# Memory usage tracking
$memoryBaseline = Get-ProcessMemoryUsage $pid
```

**Validation Features**:
- Atomic operation verification (no partial files visible)
- Lock coordination validation
- Resource leak detection
- Performance impact measurement

### **4. Test Case Framework (`TestCase.ps1`)**

**Purpose**: Base framework for implementing individual contention tests
**Responsibilities**:
- Standardized test case interface and lifecycle
- Common test utilities and helper functions
- Result reporting and validation framework
- Error handling and cleanup procedures

**Test Case Interface**:
```powershell
class ContentionTestCase {
    [string] $TestId
    [string] $Category
    [string] $Description
    [hashtable] $Configuration

    [TestResult] Execute() {
        # Standardized execution pattern
        $this.Initialize()
        $result = $this.RunTest()
        $this.Cleanup()
        return $result
    }

    # Override in specific test implementations
    [void] Initialize() { }
    [TestResult] RunTest() { }
    [void] Cleanup() { }
}
```

**Built-in Test Utilities**:
- File contention simulation helpers
- Timing and synchronization utilities
- Data integrity verification functions
- Platform-specific operation wrappers

### **5. Result Validator (`ResultValidator.ps1`)**

**Purpose**: Validate test outcomes and data integrity
**Responsibilities**:
- Verify file data integrity after operations
- Validate expected vs actual outcomes
- Check system state consistency
- Generate detailed failure diagnostics

**Validation Features**:
```powershell
# Data integrity validation
Test-FileIntegrity -SourceFile $source -DestinationFiles $destinations
Assert-NoPartialFiles -Directory $testDir
Assert-NoTemporaryFiles -Directory $testDir

# System state validation
Assert-NoFileLeaks -InitialHandles $baseline -CurrentHandles $current
Assert-NoLockLeaks -ProcessId $pid
Assert-CleanFilesystem -TestDirectory $testDir
```

### **6. Configuration Management (`TestConfiguration.json`)**

**Purpose**: Centralized test configuration and parameters
**Structure**:
```json
{
  "testEnvironment": {
    "baseDirectory": "./tests/TestData/contention",
    "tempDirectory": "./tests/TestData/temp",
    "maxFileSize": "100MB",
    "defaultTimeout": 30,
    "cleanupTimeout": 10
  },
  "testCategories": {
    "FileBlocking": {
      "enabled": true,
      "tests": ["RDW-001", "RDW-002", "WDR-001"],
      "defaultRetries": 3,
      "isolationLevel": "Process"
    }
  },
  "platformSettings": {
    "Linux": {
      "lockMonitorCommand": "lsof",
      "fileHandleCommand": "ls -la /proc/{pid}/fd/"
    },
    "Windows": {
      "lockMonitorCommand": "handle.exe",
      "fileHandleCommand": "handle.exe -p {pid}"
    }
  }
}
```

## Test Execution Flow

### **Phase 1: Environment Setup**
1. Load configuration and validate environment
2. Initialize test directories and cleanup any previous runs
3. Establish resource monitoring baselines
4. Prepare test data files of various sizes

### **Phase 2: Test Execution**
```
For each test category:
  For each test in category:
    1. Initialize test-specific environment
    2. Start resource monitoring
    3. Spawn competing processes with coordination
    4. Execute synchronized operations
    5. Collect results from all processes
    6. Validate outcomes and system state
    7. Cleanup test-specific resources
    8. Record detailed results
```

### **Phase 3: Results Analysis**
1. Aggregate results across all tests
2. Generate comprehensive report with metrics
3. Identify patterns in failures or performance issues
4. Validate overall system stability
5. Cleanup global environment

## Detailed Test Implementation Examples

### **RDW-001: Read-During-Write Test**
```powershell
class ReadDuringWriteTest : ContentionTestCase {
    [TestResult] RunTest() {
        $sourceFile = $this.Configuration.SourceFile
        $testFile = $this.Configuration.TestFile

        # Create coordination barrier
        $barrier = New-ProcessBarrier -ProcessCount 2

        # Start writer process
        $writer = Start-Process {
            param($barrier, $source, $dest)
            Wait-ProcessBarrier $barrier
            Copy-FileStreaming -SourcePath $source -DestinationPath $dest
        } -Arguments $barrier, $sourceFile, $testFile

        # Start reader process
        $reader = Start-Process {
            param($barrier, $file)
            Wait-ProcessBarrier $barrier
            Start-Sleep -Milliseconds 50  # Let write begin
            try {
                Get-Content $file -ErrorAction Stop
                return @{ Success = $true; Data = "ReadSucceeded" }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        } -Arguments $barrier, $testFile

        # Collect results
        $writerResult = Wait-Process $writer
        $readerResult = Wait-Process $reader

        # Validate outcomes
        return $this.ValidateReadDuringWrite($writerResult, $readerResult)
    }
}
```

### **SAP-001: Simultaneous Access Test**
```powershell
class SimultaneousAccessTest : ContentionTestCase {
    [TestResult] RunTest() {
        $processCount = 5
        $barrier = New-ProcessBarrier -ProcessCount $processCount
        $processes = @()

        # Start multiple processes trying to create same file
        1..$processCount | ForEach-Object {
            $processes += Start-Process {
                param($barrier, $file, $processId)
                Wait-ProcessBarrier $barrier
                try {
                    Copy-Item "source.dat" $file -ErrorAction Stop
                    return @{ ProcessId = $processId; Success = $true }
                } catch {
                    return @{ ProcessId = $processId; Success = $false; Error = $_ }
                }
            } -Arguments $barrier, $this.Configuration.TestFile, $_
        }

        # Collect all results
        $results = $processes | ForEach-Object { Wait-Process $_ }

        # Validate exactly one succeeded
        return $this.ValidateSimultaneousAccess($results)
    }
}
```

## Platform-Specific Considerations

### **Windows Implementation**
- Use `handle.exe` for lock monitoring
- PowerShell jobs for process isolation
- NTFS-specific file attribute handling
- Windows service vs interactive process testing

### **Linux Implementation**
- Use `lsof` and `/proc` filesystem for monitoring
- Fork/exec process model
- ext4/xfs filesystem behavior differences
- Signal handling for process coordination

### **Cross-Platform Abstractions**
```powershell
# Platform-agnostic file lock detection
function Get-FileLocks {
    param($FilePath)
    if ($IsWindows) {
        return Get-WindowsFileLocks $FilePath
    } else {
        return Get-LinuxFileLocks $FilePath
    }
}

# Platform-specific timeout handling
function Wait-ProcessWithTimeout {
    param($Process, $TimeoutSeconds)
    if ($IsWindows) {
        return Wait-WindowsProcess $Process $TimeoutSeconds
    } else {
        return Wait-LinuxProcess $Process $TimeoutSeconds
    }
}
```

## Resource Management Strategy

### **Memory Management**
- Track PowerShell runspace memory usage
- Monitor test data file memory footprint
- Detect memory leaks in long-running test suites
- Automatic cleanup of abandoned processes

### **File System Management**
- Dedicated test directory with automatic cleanup
- Temporary file naming conventions to avoid conflicts
- Disk space monitoring and management
- Cross-platform path handling

### **Process Management**
- Process hierarchy tracking for cleanup
- Timeout-based process termination
- Resource limit enforcement
- Orphan process detection and cleanup

## Error Handling and Recovery

### **Test Failure Categories**
1. **Expected Failures**: Contention scenarios that should fail gracefully
2. **Implementation Failures**: Bugs in the file copier service
3. **Test Infrastructure Failures**: Problems with the test harness itself
4. **System Failures**: Resource exhaustion, permission issues, etc.

### **Recovery Strategies**
```powershell
# Automatic retry for flaky tests
$maxRetries = 3
$retryCount = 0
do {
    $result = Invoke-ContentionTest $testCase
    $retryCount++
} while (-not $result.Success -and $retryCount -lt $maxRetries)

# Cleanup after failures
if (-not $result.Success) {
    Invoke-EmergencyCleanup -TestCase $testCase
    Write-TestFailure $result
}
```

### **Cleanup Procedures**
- Kill all spawned processes
- Remove all temporary files
- Release any held resources
- Reset system state to baseline

## Performance and Scalability

### **Test Execution Performance**
- Parallel test execution where safe
- Resource-aware scheduling
- Progress reporting for long-running suites
- Early termination of failed test categories

### **Resource Scaling**
- Configurable resource limits per test
- Dynamic adjustment based on available resources
- Graceful degradation for resource-constrained systems
- Test prioritization under resource pressure

## Reporting and Analytics

### **Test Results Format**
```json
{
  "testSuite": "Enterprise Contention Resilience",
  "executionStart": "2025-09-16T12:00:00Z",
  "executionEnd": "2025-09-16T12:30:00Z",
  "platform": "Linux",
  "summary": {
    "totalTests": 35,
    "passed": 32,
    "failed": 2,
    "skipped": 1,
    "successRate": "91.4%"
  },
  "categoryResults": {
    "FileBlocking": {
      "tests": 12,
      "passed": 11,
      "failed": 1,
      "details": [...]
    }
  },
  "failureAnalysis": {
    "criticalFailures": 1,
    "infrastructureFailures": 0,
    "flakyTests": 1
  },
  "systemMetrics": {
    "peakMemoryUsage": "256MB",
    "maxFileHandles": 145,
    "averageTestDuration": "12.3s"
  }
}
```

### **Failure Diagnostics**
- Detailed error messages with context
- System state snapshots at failure time
- Process execution logs
- Resource usage graphs
- Suggested remediation steps

## Implementation Roadmap

### **Phase 1: Core Infrastructure** (Week 1)
- Test Orchestrator basic framework
- Process Coordinator with simple synchronization
- Basic Resource Monitor
- Configuration management system

### **Phase 2: Critical Tests** (Week 2)
- Implement RDW-001 through DDO-003 (9 tests)
- Validate core file locking behavior
- Establish baseline test reliability

### **Phase 3: Race Conditions** (Week 3)
- Implement SAP-001 through AOV-002 (6 tests)
- Multi-process synchronization refinement
- Atomic operation validation

### **Phase 4: Resource & Recovery** (Week 4)
- Implement FHL-001 through CV-002 (8 tests)
- System stability and cleanup validation
- Resource leak detection

### **Phase 5: Production Scenarios** (Week 5)
- Implement NIS-001 through FST-001 (7 tests)
- Network and performance testing
- Cross-platform validation

### **Phase 6: Platform Validation** (Week 6)
- Implement WSS, LSS, CPS series (5 tests)
- Platform-specific behavior validation
- Final integration and optimization

## Success Metrics

### **Reliability Metrics**
- Test reproducibility: >95% consistent results across runs
- Infrastructure stability: <1% test harness failures
- Platform consistency: <5% variation in results between platforms

### **Coverage Metrics**
- All 35 contention scenarios implemented and passing
- Cross-platform validation on Windows and Linux
- Integration with existing 71-test suite

### **Performance Metrics**
- Complete test suite execution: <30 minutes
- Individual test execution: <60 seconds average
- Resource usage: <500MB peak memory, <1000 file handles

### **Quality Metrics**
- Clear pass/fail criteria for each test
- Detailed failure diagnostics and remediation guidance
- Automated reporting with actionable insights

---

**This test harness represents the difference between a functional file copier and an enterprise-ready service capable of handling real-world contention scenarios with confidence and reliability.**