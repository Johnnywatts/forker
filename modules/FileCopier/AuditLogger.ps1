# AuditLogger.ps1 - Comprehensive audit logging and trail system
# Part of Phase 4B: Error Handling & Recovery

using namespace System.Collections.Concurrent
using namespace System.IO

# Audit event types for classification
enum AuditEventType {
    FileDetected = 1
    FileProcessingStarted = 2
    FileProcessingCompleted = 3
    FileProcessingFailed = 4
    FileCopyStarted = 5
    FileCopyCompleted = 6
    FileCopyFailed = 7
    FileVerificationStarted = 8
    FileVerificationCompleted = 9
    FileVerificationFailed = 10
    FileQuarantined = 11
    ServiceStarted = 12
    ServiceStopped = 13
    ServiceRestarted = 14
    ConfigurationReloaded = 15
    ErrorEscalated = 16
    RetryAttempt = 17
    HealthCheck = 18
    PerformanceAlert = 19
    SecurityEvent = 20
}

# Audit severity levels
enum AuditSeverity {
    Information = 1
    Success = 2
    Warning = 3
    Error = 4
    Critical = 5
    Security = 6
}

# Individual audit log entry
class AuditLogEntry {
    [string] $Id
    [DateTime] $Timestamp
    [AuditEventType] $EventType
    [AuditSeverity] $Severity
    [string] $Operation
    [string] $FilePath
    [string] $SourcePath
    [string] $TargetPath
    [string] $UserId
    [string] $ProcessId
    [string] $ThreadId
    [string] $SessionId
    [string] $Message
    [hashtable] $Details
    [hashtable] $PerformanceData
    [string] $CorrelationId
    [TimeSpan] $Duration
    [long] $FileSize
    [string] $FileHash
    [bool] $Success

    AuditLogEntry([AuditEventType] $eventType, [string] $operation, [string] $message) {
        $this.Id = [System.Guid]::NewGuid().ToString("N")
        $this.Timestamp = Get-Date
        $this.EventType = $eventType
        $this.Operation = $operation
        $this.Message = $message
        $this.Details = @{}
        $this.PerformanceData = @{}
        $this.Success = $true

        # Capture system context
        $this.ProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id.ToString()
        $this.ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId.ToString()

        # Try to get user context
        try {
            $this.UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        catch {
            $this.UserId = "Unknown"
        }

        # Set default severity based on event type
        $this.Severity = $this.GetDefaultSeverity($eventType)
    }

    [AuditSeverity] GetDefaultSeverity([AuditEventType] $eventType) {
        switch ($eventType) {
            { $_ -in @([AuditEventType]::FileDetected, [AuditEventType]::FileProcessingStarted, [AuditEventType]::FileCopyStarted, [AuditEventType]::FileVerificationStarted) } {
                return [AuditSeverity]::Information
            }
            { $_ -in @([AuditEventType]::FileProcessingCompleted, [AuditEventType]::FileCopyCompleted, [AuditEventType]::FileVerificationCompleted, [AuditEventType]::ServiceStarted) } {
                return [AuditSeverity]::Success
            }
            { $_ -in @([AuditEventType]::RetryAttempt, [AuditEventType]::ConfigurationReloaded, [AuditEventType]::HealthCheck) } {
                return [AuditSeverity]::Warning
            }
            { $_ -in @([AuditEventType]::FileProcessingFailed, [AuditEventType]::FileCopyFailed, [AuditEventType]::FileVerificationFailed) } {
                return [AuditSeverity]::Error
            }
            { $_ -in @([AuditEventType]::ErrorEscalated, [AuditEventType]::FileQuarantined, [AuditEventType]::ServiceStopped) } {
                return [AuditSeverity]::Critical
            }
            { $_ -in @([AuditEventType]::SecurityEvent) } {
                return [AuditSeverity]::Security
            }
            default {
                return [AuditSeverity]::Information
            }
        }
    }
}

# Comprehensive audit logging system
class AuditLogger {
    [string] $LogContext = "AuditLogger"
    [hashtable] $Config
    [string] $AuditLogPath
    [string] $SecurityLogPath
    [ConcurrentQueue[AuditLogEntry]] $AuditQueue
    [System.Threading.Timer] $FlushTimer
    [System.IO.FileStream] $AuditStream
    [System.IO.StreamWriter] $AuditWriter
    [System.IO.FileStream] $SecurityStream
    [System.IO.StreamWriter] $SecurityWriter
    [object] $WriteLock
    [hashtable] $AuditCounters
    [bool] $IsInitialized

    AuditLogger([hashtable] $config) {
        $this.Config = $config
        $this.AuditQueue = [ConcurrentQueue[AuditLogEntry]]::new()
        $this.WriteLock = [System.Object]::new()
        $this.IsInitialized = $false

        $this.InitializeCounters()
        $this.InitializeAuditFiles()
        $this.StartFlushTimer()

        $this.IsInitialized = $true

        # Log initialization
        $this.LogAuditEvent([AuditEventType]::ServiceStarted, "AuditLogger", "Audit logging system initialized", @{
            AuditLogPath = $this.AuditLogPath
            SecurityLogPath = $this.SecurityLogPath
            FlushIntervalMs = $this.Config.Logging.AuditFlushInterval
        })

        Write-FileCopierLog -Level "Information" -Message "AuditLogger initialized successfully" -Category $this.LogContext -Properties @{
            AuditLogPath = $this.AuditLogPath
            SecurityLogPath = $this.SecurityLogPath
        }
    }

    # Initialize audit counters
    [void] InitializeCounters() {
        $this.AuditCounters = @{
            TotalEvents = 0
            EventsByType = @{}
            EventsBySeverity = @{}
            QueueSize = 0
            FlushCount = 0
            ErrorCount = 0
            SecurityEventCount = 0
            LastFlushTime = Get-Date
        }

        # Initialize counters for each event type
        foreach ($eventType in [System.Enum]::GetValues([AuditEventType])) {
            $this.AuditCounters.EventsByType[$eventType.ToString()] = 0
        }

        # Initialize counters for each severity
        foreach ($severity in [System.Enum]::GetValues([AuditSeverity])) {
            $this.AuditCounters.EventsBySeverity[$severity.ToString()] = 0
        }
    }

    # Initialize audit log files
    [void] InitializeAuditFiles() {
        $auditDir = $this.Config.Logging.AuditDirectory
        if (-not $auditDir) {
            $auditDir = Join-Path $this.Config.Logging.FilePath ".." "audit"
        }

        if (-not (Test-Path $auditDir)) {
            New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
        }

        $dateStamp = Get-Date -Format "yyyy-MM-dd"
        $this.AuditLogPath = Join-Path $auditDir "audit-$dateStamp.jsonl"
        $this.SecurityLogPath = Join-Path $auditDir "security-$dateStamp.jsonl"

        # Initialize audit log file
        try {
            $this.AuditStream = [FileStream]::new($this.AuditLogPath, [FileMode]::Append, [FileAccess]::Write, [FileShare]::Read)
            $this.AuditWriter = [StreamWriter]::new($this.AuditStream, [System.Text.Encoding]::UTF8)
            $this.AuditWriter.AutoFlush = $false
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to initialize audit log file: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }

        # Initialize security log file
        try {
            $this.SecurityStream = [FileStream]::new($this.SecurityLogPath, [FileMode]::Append, [FileAccess]::Write, [FileShare]::Read)
            $this.SecurityWriter = [StreamWriter]::new($this.SecurityStream, [System.Text.Encoding]::UTF8)
            $this.SecurityWriter.AutoFlush = $false
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to initialize security log file: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Start the flush timer
    [void] StartFlushTimer() {
        $flushInterval = $this.Config.Logging.AuditFlushInterval
        if (-not $flushInterval) {
            $flushInterval = 5000  # Default 5 seconds
        }

        $this.FlushTimer = [System.Threading.Timer]::new(
            { param($state) $state.FlushPendingEntries() },
            $this,
            $flushInterval,
            $flushInterval
        )
    }

    # Log an audit event
    [void] LogAuditEvent([AuditEventType] $eventType, [string] $operation, [string] $message, [hashtable] $details = @{}) {
        if (-not $this.IsInitialized) {
            return  # Skip logging during initialization
        }

        try {
            $entry = [AuditLogEntry]::new($eventType, $operation, $message)

            # Merge provided details
            foreach ($key in $details.Keys) {
                $entry.Details[$key] = $details[$key]
            }

            # Extract common properties from details
            if ($details.ContainsKey('FilePath')) { $entry.FilePath = $details.FilePath }
            if ($details.ContainsKey('SourcePath')) { $entry.SourcePath = $details.SourcePath }
            if ($details.ContainsKey('TargetPath')) { $entry.TargetPath = $details.TargetPath }
            if ($details.ContainsKey('CorrelationId')) { $entry.CorrelationId = $details.CorrelationId }
            if ($details.ContainsKey('Duration')) { $entry.Duration = $details.Duration }
            if ($details.ContainsKey('FileSize')) { $entry.FileSize = $details.FileSize }
            if ($details.ContainsKey('FileHash')) { $entry.FileHash = $details.FileHash }
            if ($details.ContainsKey('Success')) { $entry.Success = $details.Success }

            # Override severity if specified
            if ($details.ContainsKey('Severity')) {
                $entry.Severity = $details.Severity
            }

            # Add performance data if available
            if ($details.ContainsKey('PerformanceData')) {
                $entry.PerformanceData = $details.PerformanceData
            }

            # Queue the entry for async processing
            $this.AuditQueue.Enqueue($entry)

            # Update counters
            $this.UpdateCounters($entry)

            # For critical events, flush immediately
            if ($entry.Severity -in @([AuditSeverity]::Critical, [AuditSeverity]::Security)) {
                $this.FlushPendingEntries()
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error logging audit event: $($_.Exception.Message)" -Category $this.LogContext -Properties @{
                EventType = $eventType.ToString()
                Operation = $operation
                Exception = $_.Exception.GetType().Name
            }
        }
    }

    # Update audit counters
    [void] UpdateCounters([AuditLogEntry] $entry) {
        $this.AuditCounters.TotalEvents++
        $this.AuditCounters.EventsByType[$entry.EventType.ToString()]++
        $this.AuditCounters.EventsBySeverity[$entry.Severity.ToString()]++
        $this.AuditCounters.QueueSize = $this.AuditQueue.Count

        if ($entry.Severity -eq [AuditSeverity]::Security) {
            $this.AuditCounters.SecurityEventCount++
        }

        if (-not $entry.Success) {
            $this.AuditCounters.ErrorCount++
        }
    }

    # Flush pending audit entries to disk
    [void] FlushPendingEntries() {
        if ($this.AuditQueue.Count -eq 0) {
            return
        }

        lock ($this.WriteLock) {
            try {
                $entriesToFlush = @()
                $entry = $null

                # Dequeue all pending entries
                while ($this.AuditQueue.TryDequeue([ref] $entry)) {
                    $entriesToFlush += $entry
                }

                if ($entriesToFlush.Count -eq 0) {
                    return
                }

                # Write entries to appropriate log files
                foreach ($entry in $entriesToFlush) {
                    $jsonEntry = $this.ConvertToJson($entry)

                    # Write to main audit log
                    $this.AuditWriter.WriteLine($jsonEntry)

                    # Write security events to separate security log
                    if ($entry.Severity -eq [AuditSeverity]::Security) {
                        $this.SecurityWriter.WriteLine($jsonEntry)
                    }
                }

                # Flush streams
                $this.AuditWriter.Flush()
                $this.SecurityWriter.Flush()

                # Update counters
                $this.AuditCounters.FlushCount++
                $this.AuditCounters.LastFlushTime = Get-Date
                $this.AuditCounters.QueueSize = $this.AuditQueue.Count

                Write-FileCopierLog -Level "Debug" -Message "Audit entries flushed to disk" -Category $this.LogContext -Properties @{
                    EntriesFlushed = $entriesToFlush.Count
                    QueueSize = $this.AuditCounters.QueueSize
                }
            }
            catch {
                Write-FileCopierLog -Level "Error" -Message "Error flushing audit entries: $($_.Exception.Message)" -Category $this.LogContext -Properties @{
                    Exception = $_.Exception.GetType().Name
                    PendingEntries = $this.AuditQueue.Count
                }
            }
        }
    }

    # Convert audit entry to JSON format
    [string] ConvertToJson([AuditLogEntry] $entry) {
        $auditObject = @{
            id = $entry.Id
            timestamp = $entry.Timestamp.ToString("o")  # ISO 8601 format
            eventType = $entry.EventType.ToString()
            severity = $entry.Severity.ToString()
            operation = $entry.Operation
            message = $entry.Message
            success = $entry.Success
            userId = $entry.UserId
            processId = $entry.ProcessId
            threadId = $entry.ThreadId
            correlationId = $entry.CorrelationId
        }

        # Add optional fields if present
        if ($entry.FilePath) { $auditObject.filePath = $entry.FilePath }
        if ($entry.SourcePath) { $auditObject.sourcePath = $entry.SourcePath }
        if ($entry.TargetPath) { $auditObject.targetPath = $entry.TargetPath }
        if ($entry.SessionId) { $auditObject.sessionId = $entry.SessionId }
        if ($entry.Duration.TotalMilliseconds -gt 0) { $auditObject.durationMs = $entry.Duration.TotalMilliseconds }
        if ($entry.FileSize -gt 0) { $auditObject.fileSize = $entry.FileSize }
        if ($entry.FileHash) { $auditObject.fileHash = $entry.FileHash }

        # Add details and performance data
        if ($entry.Details.Count -gt 0) { $auditObject.details = $entry.Details }
        if ($entry.PerformanceData.Count -gt 0) { $auditObject.performanceData = $entry.PerformanceData }

        return ($auditObject | ConvertTo-Json -Compress -Depth 5)
    }

    # Specialized logging methods for common scenarios
    [void] LogFileOperation([AuditEventType] $eventType, [string] $filePath, [string] $message, [hashtable] $details = @{}) {
        $operationDetails = $details.Clone()
        $operationDetails['FilePath'] = $filePath
        $operationDetails['OperationType'] = 'FileOperation'

        $this.LogAuditEvent($eventType, "FileOperation", $message, $operationDetails)
    }

    [void] LogServiceEvent([AuditEventType] $eventType, [string] $serviceName, [string] $message, [hashtable] $details = @{}) {
        $serviceDetails = $details.Clone()
        $serviceDetails['ServiceName'] = $serviceName
        $serviceDetails['OperationType'] = 'ServiceManagement'

        $this.LogAuditEvent($eventType, "ServiceManagement", $message, $serviceDetails)
    }

    [void] LogSecurityEvent([string] $eventDescription, [hashtable] $details = @{}) {
        $securityDetails = $details.Clone()
        $securityDetails['Severity'] = [AuditSeverity]::Security
        $securityDetails['OperationType'] = 'Security'

        $this.LogAuditEvent([AuditEventType]::SecurityEvent, "Security", $eventDescription, $securityDetails)
    }

    [void] LogPerformanceAlert([string] $metric, [object] $value, [object] $threshold, [hashtable] $details = @{}) {
        $perfDetails = $details.Clone()
        $perfDetails['Metric'] = $metric
        $perfDetails['Value'] = $value
        $perfDetails['Threshold'] = $threshold
        $perfDetails['OperationType'] = 'Performance'

        $message = "Performance alert: $metric = $value (threshold: $threshold)"
        $this.LogAuditEvent([AuditEventType]::PerformanceAlert, "Performance", $message, $perfDetails)
    }

    # Get audit statistics
    [hashtable] GetAuditStatistics() {
        $stats = $this.AuditCounters.Clone()

        # Add runtime statistics
        $stats['IsInitialized'] = $this.IsInitialized
        $stats['AuditLogPath'] = $this.AuditLogPath
        $stats['SecurityLogPath'] = $this.SecurityLogPath
        $stats['PendingEntries'] = $this.AuditQueue.Count

        # Calculate rates
        $uptime = (Get-Date) - $this.AuditCounters.LastFlushTime
        if ($uptime.TotalMinutes -gt 0) {
            $stats['EventsPerMinute'] = [Math]::Round($this.AuditCounters.TotalEvents / $uptime.TotalMinutes, 2)
        }

        return $stats
    }

    # Search audit logs
    [AuditLogEntry[]] SearchAuditLogs([hashtable] $criteria, [int] $maxResults = 1000) {
        # This is a simplified implementation - in production you might want to use a database
        # or more sophisticated indexing for better performance

        $results = @()
        $count = 0

        try {
            # Read recent entries from memory queue first
            $recentEntries = @($this.AuditQueue.ToArray())
            foreach ($entry in $recentEntries) {
                if ($this.MatchesCriteria($entry, $criteria)) {
                    $results += $entry
                    $count++
                    if ($count -ge $maxResults) { break }
                }
            }

            # TODO: Search historical entries from log files if needed
            # This would involve parsing the JSONL files

        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error searching audit logs: $($_.Exception.Message)" -Category $this.LogContext
        }

        return $results
    }

    # Check if entry matches search criteria
    [bool] MatchesCriteria([AuditLogEntry] $entry, [hashtable] $criteria) {
        foreach ($key in $criteria.Keys) {
            $value = $criteria[$key]
            switch ($key) {
                'EventType' { if ($entry.EventType -ne $value) { return $false } }
                'Severity' { if ($entry.Severity -ne $value) { return $false } }
                'FilePath' { if ($entry.FilePath -notlike "*$value*") { return $false } }
                'Operation' { if ($entry.Operation -notlike "*$value*") { return $false } }
                'Success' { if ($entry.Success -ne $value) { return $false } }
                'FromDate' { if ($entry.Timestamp -lt $value) { return $false } }
                'ToDate' { if ($entry.Timestamp -gt $value) { return $false } }
            }
        }
        return $true
    }

    # Cleanup and disposal
    [void] Dispose() {
        try {
            # Flush any remaining entries
            $this.FlushPendingEntries()

            # Stop the flush timer
            if ($this.FlushTimer) {
                $this.FlushTimer.Dispose()
                $this.FlushTimer = $null
            }

            # Close file streams
            if ($this.AuditWriter) {
                $this.AuditWriter.Dispose()
                $this.AuditWriter = $null
            }
            if ($this.AuditStream) {
                $this.AuditStream.Dispose()
                $this.AuditStream = $null
            }
            if ($this.SecurityWriter) {
                $this.SecurityWriter.Dispose()
                $this.SecurityWriter = $null
            }
            if ($this.SecurityStream) {
                $this.SecurityStream.Dispose()
                $this.SecurityStream = $null
            }

            Write-FileCopierLog -Level "Information" -Message "AuditLogger disposed successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error during AuditLogger disposal: $($_.Exception.Message)" -Category $this.LogContext
        }
    }
}