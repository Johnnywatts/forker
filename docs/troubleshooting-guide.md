# FileCopier Service - Troubleshooting Guide

## Table of Contents
1. [Quick Diagnostics](#quick-diagnostics)
2. [Common Issues](#common-issues)
3. [Service Won't Start](#service-wont-start)
4. [File Processing Issues](#file-processing-issues)
5. [Performance Problems](#performance-problems)
6. [Network and Connectivity Issues](#network-and-connectivity-issues)
7. [Configuration Problems](#configuration-problems)
8. [Monitoring and Alerting](#monitoring-and-alerting)
9. [Log Analysis](#log-analysis)
10. [Advanced Troubleshooting](#advanced-troubleshooting)

## Quick Diagnostics

### Health Check Commands
```powershell
# Basic health check
Get-FileCopierHealth -Config $config -Logger $logger

# Detailed health report
Get-FileCopierReport -Config $config -Logger $logger -Detailed

# Test connectivity to all directories
Test-FileCopierConnectivity -Config $config -Logger $logger

# Check recent errors
Get-FileCopierErrors -Config $config -Logger $logger -Hours 24
```

### Monitoring Dashboard
Access the web-based monitoring dashboard:
```powershell
Start-FileCopierDashboard -Config $config -Logger $logger -Port 8080
# Open http://localhost:8080 in your browser
```

## Common Issues

### Issue: Service Status Shows as Critical
**Symptoms:**
- Dashboard shows "Critical" status
- Multiple components failing
- Service may be unresponsive

**Diagnosis:**
```powershell
$health = Get-FileCopierHealth -Config $config -Logger $logger
$health.Components | ForEach-Object {
    Write-Host "$($_.Key): $($_.Value.Status)"
    if ($_.Value.Issues) {
        $_.Value.Issues | ForEach-Object { Write-Host "  - $_" }
    }
}
```

**Resolution:**
1. Check if source/target directories are accessible
2. Verify sufficient disk space (>1GB recommended)
3. Check file permissions
4. Review configuration file for errors
5. Restart the service if connectivity is restored

### Issue: High Memory Usage
**Symptoms:**
- Memory usage exceeds 90% of configured limit
- Performance degradation
- Possible service restarts

**Diagnosis:**
```powershell
$performance = Get-FileCopierPerformance -Config $config -Logger $logger
$memoryPercent = $performance.Summary.MemoryUsagePercent
Write-Host "Current memory usage: $memoryPercent%"
```

**Resolution:**
1. Reduce `MaxConcurrentCopies` in configuration
2. Increase `MaxMemoryMB` limit if system has available RAM
3. Check for memory leaks by monitoring over time
4. Consider processing smaller batches of files

## Service Won't Start

### Windows Service Issues
**Check Service Status:**
```cmd
sc query "FileCopier Service"
nssm status "FileCopier Service"
```

**Check Event Logs:**
```powershell
Get-WinEvent -LogName Application -Source "FileCopier Service" -MaxEvents 10
```

**Common Causes:**
1. **Configuration file not found or invalid**
   - Verify config file path in NSSM parameters
   - Validate JSON syntax using online validator

2. **PowerShell execution policy**
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
   ```

3. **Missing dependencies**
   - Ensure PowerShell 7+ is installed
   - Verify all module files are present

4. **Permission issues**
   - Service account must have access to all configured directories
   - Grant "Log on as a service" right to service account

### PowerShell Script Issues
**Manual Testing:**
```powershell
# Test configuration loading
$config = Get-Content "config/service-config.json" | ConvertFrom-Json -AsHashtable

# Test module loading
Import-Module "./modules/FileCopier/FileCopier.psm1" -Force

# Test service creation
$service = [FileCopierService]::new($config, "./")
```

## File Processing Issues

### Files Not Being Detected
**Diagnosis:**
```powershell
# Check file watcher configuration
$config.FileWatcher

# Test file patterns
$sourceDir = $config.SourceDirectory
$includePatterns = $config.FileWatcher.IncludePatterns
$excludePatterns = $config.FileWatcher.ExcludePatterns

# List files that should be detected
Get-ChildItem $sourceDir -Recurse | Where-Object {
    $file = $_
    $included = $includePatterns | Where-Object { $file.Name -like $_ }
    $excluded = $excludePatterns | Where-Object { $file.Name -like $_ }
    $included -and -not $excluded
}
```

**Common Solutions:**
1. Verify include/exclude patterns are correct
2. Check file size limits (`MinFileSizeBytes`, `MaxFileSizeBytes`)
3. Ensure files are stable (not being written to)
4. Check source directory accessibility

### Files Stuck in Processing Queue
**Diagnosis:**
```powershell
# Check for files in temp directory
$tempDir = $config.Processing.TempDirectory
Get-ChildItem $tempDir -ErrorAction SilentlyContinue

# Check quarantine directory
$quarantineDir = $config.Processing.QuarantineDirectory
Get-ChildItem $quarantineDir -ErrorAction SilentlyContinue

# Review recent processing logs
Get-FileCopierErrors -Config $config -Logger $logger -Hours 6
```

**Common Solutions:**
1. Clear temp directory of orphaned files
2. Review quarantined files for recurring errors
3. Increase retry attempts if network issues
4. Check target directory disk space

### Hash Verification Failures
**Symptoms:**
- Files copied but verification fails
- Files moved to quarantine
- "Hash mismatch" errors in logs

**Diagnosis:**
```powershell
# Check verification settings
$config.Verification

# Manually verify a problematic file
$sourceFile = "path/to/source/file.svs"
$targetFile = "path/to/target/file.svs"

$sourceHash = Get-FileHash $sourceFile -Algorithm SHA256
$targetHash = Get-FileHash $targetFile -Algorithm SHA256

Write-Host "Source: $($sourceHash.Hash)"
Write-Host "Target: $($targetHash.Hash)"
Write-Host "Match: $($sourceHash.Hash -eq $targetHash.Hash)"
```

**Solutions:**
1. Check if files are still being written during copy
2. Verify disk integrity (run `chkdsk`)
3. Test with smaller files to isolate issue
4. Temporarily disable verification to test copy process

## Performance Problems

### Slow File Processing
**Performance Metrics:**
```powershell
$perf = Get-FileCopierPerformance -Config $config -Logger $logger
Write-Host "Average processing time: $($perf.Summary.AverageProcessingTimeSeconds) seconds"
Write-Host "Average copy speed: $($perf.Summary.AverageCopySpeedMBps) MB/s"
Write-Host "Queue depth: $($perf.Summary.CurrentQueueDepth)"
```

**Optimization:**
1. **Increase concurrent operations** (if CPU/RAM allow):
   ```json
   "Processing": {
     "MaxConcurrentCopies": 6
   }
   ```

2. **Optimize buffer sizes** for large files:
   ```json
   "Performance": {
     "Optimization": {
       "LargeFileBufferMB": 8,
       "ConcurrentIOOperations": 6
     }
   }
   ```

3. **Reduce verification overhead**:
   ```json
   "Verification": {
     "VerifySourceBeforeCopy": false,
     "ParallelHashingEnabled": true
   }
   ```

### High CPU Usage
**Diagnosis:**
```powershell
# Monitor CPU usage
Get-Counter "\Process(powershell*)\% Processor Time" -Continuous
```

**Solutions:**
1. Reduce `MaxConcurrentCopies`
2. Increase `PollingInterval` to reduce file system scanning
3. Disable detailed performance logging in production
4. Consider processing during off-peak hours

### Disk I/O Bottlenecks
**Check Disk Performance:**
```powershell
# Monitor disk queue length
Get-Counter "\PhysicalDisk(*)\Current Disk Queue Length" -MaxSamples 5

# Check disk transfer rates
Get-Counter "\PhysicalDisk(*)\Disk Bytes/sec" -MaxSamples 5
```

**Solutions:**
1. Use SSDs for temp directories
2. Distribute targets across multiple drives
3. Reduce concurrent operations if disks are saturated
4. Consider network storage optimization

## Network and Connectivity Issues

### Network Drive Access Problems
**Test Connectivity:**
```powershell
# Test UNC path access
Test-Path "\\server\share\folder"

# Test with credentials
$cred = Get-Credential
New-PSDrive -Name "TestDrive" -PSProvider FileSystem -Root "\\server\share" -Credential $cred
Test-Path "TestDrive:\folder"
Remove-PSDrive -Name "TestDrive"
```

**Solutions:**
1. Verify network credentials
2. Check firewall rules
3. Test with UNC paths vs. mapped drives
4. Increase network timeout values
5. Use persistent connections for network drives

### Intermittent Connection Failures
**Configuration:**
```json
"Retry": {
  "Strategies": {
    "Network": {
      "MaxAttempts": 5,
      "BaseDelayMs": 10000,
      "MaxDelayMs": 300000,
      "UseJitter": true
    }
  }
}
```

**Monitoring:**
```powershell
# Check connectivity status periodically
while ($true) {
    $connectivity = Test-FileCopierConnectivity -Config $config -Logger $logger
    Write-Host "$(Get-Date): Overall status = $($connectivity.Status)"
    Start-Sleep 60
}
```

## Configuration Problems

### Invalid Configuration Syntax
**Validation:**
```powershell
# Test JSON syntax
try {
    $config = Get-Content "config/service-config.json" | ConvertFrom-Json -AsHashtable
    Write-Host "Configuration is valid JSON"
} catch {
    Write-Error "Invalid JSON: $($_.Exception.Message)"
}

# Validate configuration structure
$health = Get-FileCopierHealth -Config $config -Logger $logger
if ($health.Components.Configuration.Status -eq 'Critical') {
    $health.Components.Configuration.Issues
}
```

### Environment-Specific Settings
**Development vs. Production:**
```powershell
# Use appropriate config file
$environment = "Production"  # or "Development"
$configFile = "config/service-config-$(environment.ToLower()).json"
$config = Get-Content $configFile | ConvertFrom-Json -AsHashtable
```

## Monitoring and Alerting

### Setting Up Alerts
**Memory Threshold Alert:**
```powershell
# Check if memory usage exceeds threshold
$perf = Get-FileCopierPerformance -Config $config -Logger $logger
$memoryThreshold = $config.Performance.Alerting.MemoryThresholdMB
$currentMemory = $perf.SystemResources.MemoryMB

if ($currentMemory -gt $memoryThreshold) {
    # Send alert (email, event log, etc.)
    Write-EventLog -LogName Application -Source "FileCopier Service" -EventId 2001 -EntryType Warning -Message "Memory usage threshold exceeded: $currentMemory MB"
}
```

**Queue Depth Monitoring:**
```powershell
# Monitor processing queue
$queueThreshold = $config.Performance.Alerting.QueueDepthThreshold
$currentDepth = $perf.Summary.CurrentQueueDepth

if ($currentDepth -gt $queueThreshold) {
    Write-Warning "Processing queue depth high: $currentDepth items"
}
```

### Performance Counter Integration
**View Windows Performance Counters:**
```powershell
# List FileCopier performance counters
Get-Counter -ListSet "FileCopier Service" | Select-Object -ExpandProperty Counter

# Monitor specific counter
Get-Counter "\FileCopier Service\Files Processed/sec" -Continuous
```

## Log Analysis

### Finding Specific Issues
**Search for Errors:**
```powershell
# Find hash verification failures
Get-Content $config.Logging.FilePath | Select-String "hash.*mismatch|verification.*failed" -Context 2

# Find network-related errors
Get-Content $config.Logging.FilePath | Select-String "network.*not found|connection.*timeout|sharing violation" -Context 2

# Find permission errors
Get-Content $config.Logging.FilePath | Select-String "access.*denied|unauthorized|permission" -Context 2
```

### Performance Analysis
**Processing Time Trends:**
```powershell
# Extract processing times from logs
Get-Content $config.Logging.FilePath | Select-String "Processing completed.*(\d+\.?\d*)\s*seconds" | ForEach-Object {
    if ($_.Line -match "(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Processing completed.*?(\d+\.?\d*)\s*seconds") {
        [PSCustomObject]@{
            Timestamp = [DateTime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss", $null)
            ProcessingTime = [double]$matches[2]
        }
    }
} | Sort-Object Timestamp | Select-Object -Last 50
```

### Audit Trail Analysis
**Review File Operations:**
```powershell
# Check audit logs for specific file
$auditDir = $config.Logging.AuditDirectory
$fileName = "example.svs"

Get-ChildItem $auditDir -Filter "*.jsonl" | ForEach-Object {
    Get-Content $_.FullName | ConvertFrom-Json | Where-Object { $_.FileName -like "*$fileName*" }
}
```

## Advanced Troubleshooting

### Memory Leak Detection
**Monitor Memory Over Time:**
```powershell
# Create memory monitoring script
$logFile = "memory-monitor.csv"
"Timestamp,WorkingSetMB,PrivateMemoryMB" | Out-File $logFile

while ($true) {
    $process = Get-Process -Id $PID
    $workingSet = [math]::Round($process.WorkingSet64 / 1MB, 2)
    $privateMemory = [math]::Round($process.PrivateMemorySize64 / 1MB, 2)

    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$workingSet,$privateMemory" | Out-File $logFile -Append
    Start-Sleep 300  # Every 5 minutes
}
```

### Performance Profiling
**Detailed Timing Analysis:**
```powershell
# Enable detailed timing in configuration
$config.Performance.Monitoring.DetailedTimings = $true
$config.Performance.Monitoring.MemoryProfiling = $true

# Restart service with profiling enabled
Restart-Service "FileCopier Service"
```

### Database Debugging (if applicable)
**Check Integration Points:**
```powershell
# Test external system connectivity
$integrationInterval = $config.Service.IntegrationInterval
Write-Host "Integration interval: $integrationInterval ms"

# Manual integration test
# (Implementation depends on external system requirements)
```

### Circuit Breaker Analysis
**Check Circuit Breaker Status:**
```powershell
# Review circuit breaker events in logs
Get-Content $config.Logging.FilePath | Select-String "circuit.*breaker|breaker.*open|breaker.*closed" -Context 3
```

## Emergency Procedures

### Service Recovery
**Complete Service Reset:**
```powershell
# Stop service
Stop-Service "FileCopier Service" -Force

# Clear temp files
Remove-Item "$($config.Processing.TempDirectory)\*" -Force -ErrorAction SilentlyContinue

# Reset performance counters
# Reset-FileCopierCounters  # Custom function if implemented

# Start service
Start-Service "FileCopier Service"
```

### Data Recovery
**Recover Files from Quarantine:**
```powershell
# List quarantined files
$quarantineDir = $config.Processing.QuarantineDirectory
$quarantinedFiles = Get-ChildItem $quarantineDir -Recurse

# Manual file verification and recovery
foreach ($file in $quarantinedFiles) {
    Write-Host "Quarantined: $($file.FullName)"
    # Manual inspection and potential recovery
}
```

### Contact Information
For additional support:
- **Internal IT**: Check configuration contact information
- **System Administrator**: Review service account and permissions
- **Development Team**: For configuration and performance optimization

---

**Last Updated**: Phase 5B Implementation
**Version**: 1.0