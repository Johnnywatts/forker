# FileCopier Service - Comprehensive Testing Guide

## Overview

This guide provides complete testing procedures for the FileCopier Service on your Windows laptop. The service is designed to monitor directories for large medical imaging files (SVS format) and reliably copy them to multiple target locations with verification.

## Prerequisites

### System Requirements
- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1 or PowerShell 7+
- Minimum 8GB RAM (16GB recommended for stress testing)
- 50GB+ free disk space for testing
- Administrator privileges (for full service testing)

### Setup Instructions

1. **Clone or Download Repository**
   ```powershell
   # If using Git
   git clone <repository-url>
   cd forker

   # Or download and extract ZIP file
   ```

2. **Set Up Testing Environment**
   ```powershell
   # Run as Administrator for full testing
   .\Setup-TestingEnvironment.ps1 -CreateSampleFiles -SampleFileCount 20
   ```

   This creates:
   - `C:\FileCopierTest\` - Complete testing directory structure
   - Source and target directories
   - Sample test files
   - Test configuration optimized for laptop
   - Test runner scripts

## Testing Phases

### Phase 1: Quick Validation (5 minutes)

Validates basic functionality and component loading.

```powershell
cd C:\FileCopierTest
.\Run-Tests.ps1 -Quick
```

**What it tests:**
- Configuration file loading
- PowerShell module syntax validation
- Component initialization
- Basic health checks
- File system permissions

**Expected Results:**
- 25+ tests should pass
- Success rate > 80%
- No critical errors

### Phase 2: Integration Testing (10-15 minutes)

Tests component interaction and workflow integration.

```powershell
.\Run-Tests.ps1 -Integration
```

**What it tests:**
- Cross-component communication
- Performance counter operations
- Alerting system functionality
- Diagnostic command execution
- Monitoring data collection
- Configuration validation

**Expected Results:**
- All components initialize successfully
- Monitoring systems operational
- Health checks return valid data
- Alerts can be generated and acknowledged

### Phase 3: Performance Validation (15-20 minutes)

Benchmarks performance and resource usage.

```powershell
.\Run-Tests.ps1 -Performance
```

**What it tests:**
- Memory usage under load
- Performance counter throughput
- File processing simulation
- System resource monitoring
- Large file handling

**Expected Results:**
- Memory growth < 300MB during testing
- Performance counters update at >100 ops/second
- System resources remain stable

### Phase 4: Stress Testing (20-30 minutes)

Validates production readiness under load.

```powershell
# Comprehensive stress test
.\Test-StressTest.ps1 -FileCount 100 -LargeFileCount 20 -TestDurationMinutes 15

# Quick stress test
.\Test-StressTest.ps1 -FileCount 50 -LargeFileCount 10 -TestDurationMinutes 5
```

**What it tests:**
- Concurrent file operations
- Memory leak detection
- Error recovery mechanisms
- Resource utilization limits
- Long-running stability

**Expected Results:**
- Process 50+ files concurrently
- Error rate < 5%
- Memory usage stable over time
- Graceful error handling

### Phase 5: Service Lifecycle Testing (10-15 minutes)

Tests complete service deployment and operations.

```powershell
# Run as Administrator
.\Test-ServiceLifecycle.ps1 -TestFileProcessing -MonitoringDurationMinutes 5
```

**What it tests:**
- Service installation procedures
- Component startup sequence
- Real-time monitoring
- File processing workflow
- Graceful shutdown

**Expected Results:**
- All components start successfully
- Monitoring dashboard accessible
- File processing workflow operational
- Clean shutdown procedures

## Interactive Testing

### Start Monitoring Dashboard

```powershell
cd C:\FileCopierTest
.\Start-Monitoring.ps1
```

Then open: **http://localhost:8080**

**Dashboard Features:**
- Real-time system health status
- Performance metrics visualization
- Processing queue monitoring
- Error log display
- Connectivity status checks

### Manual File Processing Test

1. **Start monitoring dashboard** (above)

2. **Copy test files to source directory:**
   ```powershell
   # Copy sample files to trigger processing
   Copy-Item "TestData\Small\*.txt" "Source\"
   Copy-Item "TestData\Large\*.svs" "Source\"
   ```

3. **Monitor processing:**
   - Watch dashboard for file detection
   - Check target directories for copied files
   - Monitor performance metrics
   - Review logs for processing details

4. **Verify results:**
   ```powershell
   # Check target directories
   Get-ChildItem TargetA\
   Get-ChildItem TargetB\

   # Check logs
   Get-Content "Logs\service.log" -Tail 20
   ```

## Diagnostic Commands

### Health Checks
```powershell
# Load modules first
. .\modules\FileCopier\DiagnosticCommands.ps1

$config = Get-Content "Config\test-config.json" | ConvertFrom-Json -AsHashtable
$logger = [PSCustomObject]@{
    LogInformation = { param($msg) Write-Host $msg }
    LogWarning = { param($msg) Write-Warning $msg }
    LogError = { param($msg) Write-Error $msg }
}

# System health check
Get-FileCopierHealth -Config $config -Logger $logger

# Connectivity test
Test-FileCopierConnectivity -Config $config -Logger $logger

# Performance metrics
Get-FileCopierPerformance -Config $config -Logger $logger
```

### Log Analysis
```powershell
# Recent errors
Get-FileCopierErrors -Config $config -Logger $logger -Hours 24

# Generate health report
Get-FileCopierReport -Config $config -Logger $logger -Detailed
```

## Troubleshooting Common Issues

### Issue: Tests Fail with "Unable to find type" Errors

**Cause:** PowerShell module loading order issues

**Solution:**
```powershell
# Load modules in correct order
. .\modules\FileCopier\PerformanceCounters.ps1
. .\modules\FileCopier\DiagnosticCommands.ps1
. .\modules\FileCopier\AlertingSystem.ps1
# Then run tests
```

### Issue: Dashboard Not Accessible

**Cause:** Port conflicts or firewall blocking

**Solution:**
```powershell
# Try different port
.\Start-Monitoring.ps1 -Port 8081

# Check firewall
netsh advfirewall firewall add rule name="FileCopier Dashboard" dir=in action=allow protocol=TCP localport=8080
```

### Issue: Permission Denied Errors

**Cause:** Insufficient permissions for file operations

**Solution:**
```powershell
# Run PowerShell as Administrator
Start-Process PowerShell -Verb RunAs

# Or modify test directories to user profile
.\Setup-TestingEnvironment.ps1 -TestRoot "$env:USERPROFILE\FileCopierTest"
```

### Issue: High Memory Usage During Testing

**Cause:** Normal for stress testing with large files

**Solution:**
```powershell
# Reduce test file sizes
.\Test-StressTest.ps1 -FileCount 25 -LargeFileCount 5

# Monitor memory usage
Get-Process powershell | Select-Object ProcessName, WorkingSet64
```

### Issue: Files Not Processing

**Cause:** Service components not running

**Solution:**
1. Ensure test environment is set up correctly
2. Check source and target directory accessibility
3. Verify configuration file is valid
4. For full processing, actual service must be running

## Performance Benchmarks

### Expected Performance (Windows Laptop)

| Metric | Minimum | Target | Excellent |
|--------|---------|---------|-----------|
| Test Success Rate | 75% | 85% | 95%+ |
| Memory Usage | <500MB | <300MB | <200MB |
| Performance Counter Ops/sec | 50 | 100 | 200+ |
| File Processing Rate | 5 files/min | 15 files/min | 30+ files/min |
| Error Rate | <10% | <5% | <1% |
| Startup Time | <60s | <30s | <15s |

### Laptop-Specific Optimizations

The test configuration is optimized for laptop testing:

```json
{
  "Processing": {
    "MaxConcurrentCopies": 2,        // Reduced for laptop
    "MaxMemoryMB": 512               // Conservative limit
  },
  "FileWatcher": {
    "PollingInterval": 2000,         // Faster for testing
    "MaxFileSizeBytes": 1073741824   // 1GB limit for laptop
  },
  "Performance": {
    "Optimization": {
      "LargeFileThresholdMB": 10,    // Lower threshold
      "ConcurrentIOOperations": 2    // Reduced for laptop
    }
  }
}
```

## Test Results Interpretation

### Success Criteria

✅ **Ready for Production:**
- All test phases pass with >90% success rate
- Memory usage stable under load
- No critical errors in any phase
- Monitoring dashboard fully functional

⚠️ **Needs Attention:**
- 80-90% success rate
- Minor performance issues
- Non-critical component failures
- Some monitoring features limited

❌ **Not Ready:**
- <80% success rate
- Critical component failures
- Memory leaks or resource issues
- Configuration or connectivity problems

### Result Files

Test results are saved to:
- `C:\FileCopierTest\Logs\` - Test execution logs
- `C:\FileCopierTest\Logs\Audit\Reports\` - Analysis reports
- Console output with detailed metrics

## Next Steps After Testing

### Development Environment
If tests pass successfully:
1. Proceed with development environment deployment
2. Test with real SVS files
3. Configure production settings

### Production Deployment
For production readiness:
1. Deploy to Windows Server
2. Install as Windows Service
3. Configure enterprise monitoring
4. Set up automated backups
5. Implement security policies

## Support and Documentation

### Additional Resources
- `docs/troubleshooting-guide.md` - Comprehensive troubleshooting
- `development-plan.md` - Complete development roadmap
- `config/` - Sample configurations for different environments

### Getting Help
1. Review test output and error messages
2. Check troubleshooting guide for solutions
3. Verify system requirements and permissions
4. Test with minimal configuration first

---

**Testing Environment:** `C:\FileCopierTest\`
**Dashboard URL:** `http://localhost:8080`
**Configuration:** `C:\FileCopierTest\Config\test-config.json`

**Happy Testing! 🚀**