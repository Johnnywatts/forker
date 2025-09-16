# File Contention Resilience Test Scenarios

## Overview

This document defines exhaustive test scenarios for validating the File Copier Service's resilience under various file contention conditions. These tests are critical for production deployment where multiple processes may compete for the same files simultaneously.

## Test Categories

### 1. **File Locking Contention Tests**

#### 1.1 Read-During-Write Scenarios
- **RDW-001**: Reader attempts to open file while streaming copy is actively writing
  - **Setup**: Start streaming copy of large file (278MB), immediately attempt read from another process
  - **Expected**: Reader blocks until write completes OR gets exclusive access error
  - **Validation**: No partial/corrupted data read, proper error handling

- **RDW-002**: Multiple readers attempt access during active write
  - **Setup**: Streaming copy in progress, 3-5 concurrent read attempts
  - **Expected**: All readers either block or fail gracefully, no corruption
  - **Validation**: Consistent behavior across all readers

- **RDW-003**: Reader holds long-duration lock while write attempts to start
  - **Setup**: Background process opens file for extended read (10+ seconds), main copy starts
  - **Expected**: Write operation blocks or fails with clear error message
  - **Validation**: No data corruption, proper timeout handling

#### 1.2 Write-During-Read Scenarios
- **WDR-001**: Streaming copy attempts to write while file is being read
  - **Setup**: Background process reading file, main copy tries to overwrite same file
  - **Expected**: Write blocks until read completes OR fails with exclusive access error
  - **Validation**: Reader completes successfully, writer handles conflict appropriately

- **WDR-002**: Multiple writes competing for same destination
  - **Setup**: Two streaming copy operations targeting same destination file simultaneously
  - **Expected**: One succeeds, one fails with clear error; no interleaved data
  - **Validation**: Final file is complete copy from one source, not corrupted mix

#### 1.3 Delete-During-Operation Scenarios
- **DDO-001**: File deletion attempted during active streaming copy write
  - **Setup**: Start streaming copy, immediately attempt to delete destination from another process
  - **Expected**: Delete blocks until copy completes OR copy fails gracefully
  - **Validation**: Either complete file exists OR no file exists, no partial files

- **DDO-002**: File deletion attempted during active read operation
  - **Setup**: Background process reading file, another process attempts deletion
  - **Expected**: Delete waits for read completion OR fails with "file in use" error
  - **Validation**: Read operation completes successfully or fails cleanly

- **DDO-003**: Source file deletion during streaming copy
  - **Setup**: Start streaming copy of large file, delete source file mid-operation
  - **Expected**: Copy operation detects source loss and fails gracefully
  - **Validation**: Partial destination file is cleaned up, clear error reported

### 2. **Race Condition Tests**

#### 2.1 Simultaneous Access Patterns
- **SAP-001**: Multiple processes attempt to create same file simultaneously
  - **Setup**: 3-5 processes all try to create same destination file at exact same time
  - **Expected**: One succeeds, others fail with appropriate errors
  - **Validation**: Exactly one complete file exists, no corruption

- **SAP-002**: File rename race conditions
  - **Setup**: Multiple processes attempting to rename files in same directory
  - **Expected**: Operations succeed in some order, no lost files or corruption
  - **Validation**: All expected files exist with correct names and content

- **SAP-003**: Directory operations during file operations
  - **Setup**: File copy in progress while another process creates/deletes parent directory
  - **Expected**: Operations succeed in logical order or fail with clear errors
  - **Validation**: No orphaned files, consistent directory state

#### 2.2 Atomic Operation Validation
- **AOV-001**: Temporary file atomicity under contention
  - **Setup**: Monitor .tmp files during copy operations with competing processes
  - **Expected**: .tmp files never visible to other processes until atomic move
  - **Validation**: Other processes never see incomplete .tmp files

- **AOV-002**: Multi-destination atomicity with interference
  - **Setup**: Multi-destination copy with processes interfering with each target
  - **Expected**: All destinations succeed atomically or entire operation fails
  - **Validation**: No partial success states (all targets complete or none)

### 3. **Resource Exhaustion Tests**

#### 3.1 File Handle Limits
- **FHL-001**: Maximum concurrent file operations
  - **Setup**: Start maximum number of streaming copies system allows
  - **Expected**: System gracefully handles limit, new operations queue or fail cleanly
  - **Validation**: No system instability, proper error messages

- **FHL-002**: File handle leaks under contention
  - **Setup**: Rapid start/stop of operations with interference
  - **Expected**: All file handles properly released, no resource leaks
  - **Validation**: System file handle count remains stable

#### 3.2 Disk Space Contention
- **DSC-001**: Insufficient space during multi-destination copy
  - **Setup**: Start copy when one target has insufficient space
  - **Expected**: Operation fails cleanly, successful targets cleaned up
  - **Validation**: No partial files left, clear error reporting

- **DSC-002**: Space exhaustion during streaming copy
  - **Setup**: Large file copy when destination runs out of space mid-operation
  - **Expected**: Operation detects space issue and fails gracefully
  - **Validation**: Partial files cleaned up, space is released

### 4. **Network/Remote File System Tests**

#### 4.1 Network Interruption Scenarios
- **NIS-001**: Network disconnection during remote file copy
  - **Setup**: Copy to network destination, simulate network failure
  - **Expected**: Operation detects network loss and fails with clear error
  - **Validation**: Local state cleaned up, retry mechanisms work correctly

- **NIS-002**: Intermittent network issues
  - **Setup**: Copy with simulated packet loss/high latency
  - **Expected**: Operation handles network issues with retries or graceful failure
  - **Validation**: Data integrity maintained despite network problems

#### 4.2 Remote Lock Behavior
- **RLB-001**: Remote file locking semantics
  - **Setup**: Copy to remote filesystem with local process accessing same file
  - **Expected**: Locking behavior consistent with local filesystem tests
  - **Validation**: No corruption, proper lock coordination across network

### 5. **Error Recovery and Cleanup Tests**

#### 5.1 Failure Recovery Scenarios
- **FRS-001**: Process termination during copy operation
  - **Setup**: Kill copy process mid-operation, check cleanup
  - **Expected**: Temporary files cleaned up, no corrupted destinations
  - **Validation**: System state clean after process termination

- **FRS-002**: System shutdown during operations
  - **Setup**: Simulate system shutdown with active copy operations
  - **Expected**: Operations terminate cleanly, resumable state if possible
  - **Validation**: No corrupted files, consistent system state on restart

#### 5.2 Cleanup Validation
- **CV-001**: Temporary file cleanup under all failure scenarios
  - **Setup**: Trigger each type of failure, verify cleanup
  - **Expected**: No .tmp files left behind in any failure case
  - **Validation**: Clean filesystem state after all failures

- **CV-002**: Lock release under abnormal termination
  - **Setup**: Force-terminate processes holding file locks
  - **Expected**: Locks released, other processes can access files
  - **Validation**: No permanently locked files

### 6. **Performance Under Contention Tests**

#### 6.1 Throughput Degradation Analysis
- **TDA-001**: Performance impact of concurrent access
  - **Setup**: Measure throughput with 0, 1, 3, 5, 10 competing processes
  - **Expected**: Graceful performance degradation, no thrashing
  - **Validation**: Predictable performance characteristics

- **TDA-002**: Memory usage under contention
  - **Setup**: Monitor memory usage during high-contention scenarios
  - **Expected**: Memory usage remains bounded, no leaks
  - **Validation**: Memory returns to baseline after operations complete

#### 6.2 Fairness and Starvation Tests
- **FST-001**: Process fairness under heavy contention
  - **Setup**: Multiple processes competing for resources over extended period
  - **Expected**: No process starved indefinitely, fair resource allocation
  - **Validation**: All processes make progress eventually

### 7. **Platform-Specific Contention Tests**

#### 7.1 Windows-Specific Scenarios
- **WSS-001**: NTFS file stream locking behavior
- **WSS-002**: Windows service vs. interactive process contention
- **WSS-003**: UNC path contention scenarios

#### 7.2 Linux-Specific Scenarios
- **LSS-001**: ext4/xfs filesystem locking differences
- **LSS-002**: NFS mount contention behavior
- **LSS-003**: Process signal handling during file operations

#### 7.3 Cross-Platform Scenarios
- **CPS-001**: Windows client copying to Linux server
- **CPS-002**: Mixed filesystem type operations (NTFS <-> ext4)

## Test Implementation Strategy

### Phase 1: Core Contention Tests
- Implement RDW-001 through DDO-003 (fundamental locking scenarios)
- Focus on local filesystem operations first
- Establish baseline contention handling behavior

### Phase 2: Race Condition Validation
- Implement SAP-001 through AOV-002 (race conditions and atomicity)
- Validate multi-destination operation robustness
- Ensure atomic operation guarantees

### Phase 3: Resource and Recovery Tests
- Implement FHL-001 through CV-002 (resource limits and cleanup)
- Validate system stability under stress
- Ensure proper cleanup in all failure scenarios

### Phase 4: Production Scenarios
- Implement NIS-001 through FST-001 (network and performance)
- Test real-world deployment scenarios
- Validate production readiness

### Phase 5: Platform Validation
- Implement platform-specific tests (WSS, LSS, CPS series)
- Ensure cross-platform consistency
- Validate deployment across different environments

## Success Criteria

For each test scenario, success is defined as:

1. **Data Integrity**: No corrupted files under any contention scenario
2. **Predictable Behavior**: Consistent outcomes for same inputs
3. **Graceful Failure**: Clear error messages, no system instability
4. **Resource Cleanup**: No leaked resources (handles, locks, temp files)
5. **Performance Bounds**: Measurable and acceptable performance characteristics
6. **Recovery Capability**: System returns to clean state after failures

## Automation Requirements

- All tests must be automated and repeatable
- Test results must be quantifiable and trackable
- Tests must run across all supported platforms
- Integration with existing test suite (current 71 tests)
- Performance baseline establishment and regression detection

---

**Note**: These tests represent the difference between a "working" file copier and a **production-ready enterprise service**. Real-world file contention is inevitable, and handling it correctly is not optional for enterprise deployment.