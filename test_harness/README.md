# Contention Testing Harness

## Overview

This directory contains the enterprise-grade contention testing harness for validating the File Copier Service's resilience under multi-process file access scenarios.

## Directory Structure

```
test_harness/
├── README.md                       # This file
├── Contention-TestHarness.ps1      # Main orchestrator (Phase CT-1A)
├── framework/                      # Core testing framework
│   ├── TestCase.ps1               # Base test case class
│   ├── ProcessCoordinator.ps1     # Multi-process coordination
│   ├── ResourceMonitor.ps1        # System resource monitoring
│   ├── ResultValidator.ps1        # Test result validation
│   └── TestUtils.ps1              # Common utilities
├── suites/                        # Test suite implementations
│   ├── FileLockingTests.ps1       # File locking contention tests
│   ├── RaceConditionTests.ps1     # Race condition tests
│   ├── RecoveryTests.ps1          # Recovery and cleanup tests
│   └── PerformanceTests.ps1       # Performance under contention
├── config/                        # Configuration files
│   ├── ContentionTestConfig.json  # Main test configuration
│   └── platform-settings.json     # Platform-specific settings
├── reports/                       # Test execution reports
│   ├── latest/                    # Latest test run results
│   └── history/                   # Historical test results
└── temp/                          # Temporary files during testing
    ├── sync/                      # Process synchronization files
    └── test-data/                 # Temporary test data
```

## Development Phases

Based on `contention-harness-plan.md`:

### **Phase CT-1: Core Infrastructure** (Week 1)
- [ ] CT-1A: Test Orchestrator Framework
- [ ] CT-1B: Process Coordination System

### **Phase CT-2: Critical Contention Tests** (Week 2)
- [ ] CT-2A: File Locking Tests (RDW-001, DDO-001, WDR-001)
- [ ] CT-2B: Race Condition Tests (SAP-001, AOV-002)

### **Phase CT-3: Resource & Recovery Tests** (Week 3)
- [ ] CT-3A: Resource Monitoring System
- [ ] CT-3B: Recovery & Cleanup Tests (FRS-001, CV-001, CV-002)

### **Phase CT-4: Performance & Production Validation** (Week 4)
- [ ] CT-4A: Performance Under Contention (TDA-001, FST-001)
- [ ] CT-4B: Integration & Reporting

## Quick Start

```powershell
# Navigate to test harness directory
cd test_harness

# Run all contention tests
./Contention-TestHarness.ps1 -RunAll

# Run specific test category
./Contention-TestHarness.ps1 -Category "FileLocking"

# Run single test
./Contention-TestHarness.ps1 -TestId "RDW-001"

# Generate detailed report
./Contention-TestHarness.ps1 -RunAll -ReportFormat "Detailed"
```

## Integration with Main Test Suite

The contention harness integrates with the existing test suite:
- **Existing Tests**: 71/71 passing (unit and integration tests)
- **Contention Tests**: 10 priority tests validating multi-process scenarios
- **Combined Validation**: Complete enterprise readiness verification

## Test Priorities

| Priority | Test ID | Description | Business Impact |
|----------|---------|-------------|-----------------|
| P0 | RDW-001 | Read-during-write blocking | **CRITICAL** |
| P0 | DDO-001 | Delete-during-write conflict | **CRITICAL** |
| P0 | SAP-001 | Simultaneous file creation | **CRITICAL** |
| P0 | AOV-002 | Multi-destination atomicity | **CRITICAL** |
| P1 | WDR-001 | Write-during-read blocking | **HIGH** |

See `contention_resilience_tests.md` for complete test catalog (35 scenarios).

## Development Status

**Current Phase**: CT-1A (Test Orchestrator Framework)
**Next Milestone**: Infrastructure ready for basic test execution
**Target Completion**: 4 weeks focused development

---

This harness represents the difference between functional file copying and enterprise-ready service deployment under real-world contention scenarios.