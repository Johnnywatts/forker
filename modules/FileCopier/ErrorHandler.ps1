# ErrorHandler.ps1 - Comprehensive error handling and recovery system
# Part of Phase 4B: Error Handling & Recovery

using namespace System.Collections.Concurrent

# Error severity levels for classification
enum ErrorSeverity {
    Informational = 1
    Warning = 2
    Recoverable = 3
    Critical = 4
    Fatal = 5
}

# Error categories for systematic handling
enum ErrorCategory {
    Unknown = 0
    FileSystem = 1          # File not found, access denied, disk full
    Network = 2             # Network connectivity, SMB shares
    Permission = 3          # Security and access control
    Resource = 4            # Memory, disk space, handles
    Configuration = 5       # Invalid config, missing settings
    Verification = 6        # Hash mismatches, corruption
    Process = 7             # External process failures
    Service = 8             # Service lifecycle errors
    Quarantine = 9          # Quarantine system errors
}

# Error recovery strategies
enum RecoveryStrategy {
    None = 0
    Retry = 1               # Immediate retry
    DelayedRetry = 2        # Retry with delay
    Quarantine = 3          # Move to quarantine
    Skip = 4                # Skip and continue
    Escalate = 5            # Escalate to administrator
    Abort = 6               # Abort operation
}

# Error information structure
class ErrorInfo {
    [string] $ErrorId
    [DateTime] $Timestamp
    [string] $OperationContext
    [string] $FilePath
    [ErrorCategory] $Category
    [ErrorSeverity] $Severity
    [RecoveryStrategy] $Strategy
    [string] $Message
    [string] $Details
    [hashtable] $Properties
    [int] $AttemptCount
    [DateTime] $FirstOccurrence
    [DateTime] $LastAttempt
    [string] $StackTrace
    [bool] $IsTransient
    [string] $RecommendedAction

    ErrorInfo([string] $errorId, [string] $context, [string] $filePath) {
        $this.ErrorId = $errorId
        $this.Timestamp = Get-Date
        $this.OperationContext = $context
        $this.FilePath = $filePath
        $this.Properties = @{}
        $this.AttemptCount = 1
        $this.FirstOccurrence = $this.Timestamp
        $this.LastAttempt = $this.Timestamp
        $this.IsTransient = $false
    }
}

# Main error handling class
class ErrorHandler {
    [string] $LogContext = "ErrorHandler"
    [hashtable] $Config
    [ConcurrentDictionary[string, ErrorInfo]] $ErrorHistory
    [ConcurrentQueue[ErrorInfo]] $RecentErrors
    [hashtable] $ErrorCounters
    [hashtable] $CategoryRules
    [string] $QuarantinePath
    [int] $MaxRecentErrors = 1000

    ErrorHandler([hashtable] $config) {
        $this.Config = $config
        $this.ErrorHistory = [ConcurrentDictionary[string, ErrorInfo]]::new()
        $this.RecentErrors = [ConcurrentQueue[ErrorInfo]]::new()
        $this.ErrorCounters = @{
            Total = 0
            ByCategory = @{}
            BySeverity = @{}
            Recovered = 0
            Quarantined = 0
            Escalated = 0
        }

        $this.InitializeErrorRules()
        $this.InitializeQuarantine()

        Write-FileCopierLog -Level "Information" -Message "ErrorHandler initialized successfully" -Category $this.LogContext -Properties @{
            QuarantinePath = $this.QuarantinePath
            MaxRecentErrors = $this.MaxRecentErrors
        }
    }

    # Initialize error classification rules
    [void] InitializeErrorRules() {
        $this.CategoryRules = @{
            [ErrorCategory]::FileSystem = @{
                Patterns = @(
                    'file.*not.*found',
                    'access.*denied',
                    'disk.*full',
                    'path.*too.*long',
                    'directory.*not.*empty',
                    'sharing.*violation',
                    'file.*in.*use',
                    'invalid.*drive'
                )
                DefaultSeverity = [ErrorSeverity]::Recoverable
                DefaultStrategy = [RecoveryStrategy]::DelayedRetry
                IsTransient = $true
            }
            [ErrorCategory]::Network = @{
                Patterns = @(
                    'network.*path.*not.*found',
                    'network.*name.*deleted',
                    'connection.*timed.*out',
                    'remote.*procedure.*call.*failed',
                    'network.*unreachable'
                )
                DefaultSeverity = [ErrorSeverity]::Warning
                DefaultStrategy = [RecoveryStrategy]::DelayedRetry
                IsTransient = $true
            }
            [ErrorCategory]::Permission = @{
                Patterns = @(
                    'access.*denied',
                    'unauthorized',
                    'permission.*denied',
                    'privilege.*not.*held',
                    'security.*policy'
                )
                DefaultSeverity = [ErrorSeverity]::Critical
                DefaultStrategy = [RecoveryStrategy]::Escalate
                IsTransient = $false
            }
            [ErrorCategory]::Resource = @{
                Patterns = @(
                    'out.*of.*memory',
                    'insufficient.*disk.*space',
                    'too.*many.*open.*files',
                    'handle.*invalid',
                    'resource.*exhausted'
                )
                DefaultSeverity = [ErrorSeverity]::Critical
                DefaultStrategy = [RecoveryStrategy]::DelayedRetry
                IsTransient = $true
            }
            [ErrorCategory]::Configuration = @{
                Patterns = @(
                    'configuration.*invalid',
                    'setting.*not.*found',
                    'invalid.*parameter',
                    'malformed.*config'
                )
                DefaultSeverity = [ErrorSeverity]::Fatal
                DefaultStrategy = [RecoveryStrategy]::Abort
                IsTransient = $false
            }
            [ErrorCategory]::Verification = @{
                Patterns = @(
                    'hash.*mismatch',
                    'checksum.*failed',
                    'file.*corrupted',
                    'verification.*failed'
                )
                DefaultSeverity = [ErrorSeverity]::Critical
                DefaultStrategy = [RecoveryStrategy]::Quarantine
                IsTransient = $false
            }
        }

        # Initialize counters for each category
        foreach ($category in [System.Enum]::GetValues([ErrorCategory])) {
            $this.ErrorCounters.ByCategory[$category.ToString()] = 0
        }

        # Initialize counters for each severity
        foreach ($severity in [System.Enum]::GetValues([ErrorSeverity])) {
            $this.ErrorCounters.BySeverity[$severity.ToString()] = 0
        }
    }

    # Initialize quarantine directory
    [void] InitializeQuarantine() {
        $this.QuarantinePath = Join-Path $this.Config.Processing.QuarantineDirectory "$(Get-Date -Format 'yyyy-MM')"

        if (-not (Test-Path $this.QuarantinePath)) {
            try {
                New-Item -Path $this.QuarantinePath -ItemType Directory -Force | Out-Null
                Write-FileCopierLog -Level "Information" -Message "Quarantine directory created" -Category $this.LogContext -Properties @{
                    QuarantinePath = $this.QuarantinePath
                }
            }
            catch {
                Write-FileCopierLog -Level "Error" -Message "Failed to create quarantine directory: $($_.Exception.Message)" -Category $this.LogContext -Properties @{
                    QuarantinePath = $this.QuarantinePath
                    Exception = $_.Exception.GetType().Name
                }
                throw
            }
        }
    }

    # Classify error and determine handling strategy
    [ErrorInfo] ClassifyError([System.Exception] $exception, [string] $context, [string] $filePath) {
        $errorId = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
        $errorInfo = [ErrorInfo]::new($errorId, $context, $filePath)

        $errorInfo.Message = $exception.Message
        $errorInfo.StackTrace = $exception.StackTrace
        $errorInfo.Details = $exception.ToString()

        # Classify error category based on message patterns
        $errorInfo.Category = $this.DetermineErrorCategory($exception.Message)

        # Get rule for this category
        $rule = $this.CategoryRules[$errorInfo.Category]
        if ($rule) {
            $errorInfo.Severity = $rule.DefaultSeverity
            $errorInfo.Strategy = $rule.DefaultStrategy
            $errorInfo.IsTransient = $rule.IsTransient
        } else {
            $errorInfo.Category = [ErrorCategory]::Unknown
            $errorInfo.Severity = [ErrorSeverity]::Warning
            $errorInfo.Strategy = [RecoveryStrategy]::Retry
            $errorInfo.IsTransient = $true
        }

        # Override based on specific conditions
        $this.ApplySpecificRules($errorInfo, $exception)

        # Set recommended action
        $errorInfo.RecommendedAction = $this.GetRecommendedAction($errorInfo)

        # Add to history and recent errors
        $this.RecordError($errorInfo)

        Write-FileCopierLog -Level $this.SeverityToLogLevel($errorInfo.Severity) -Message "Error classified" -Category $this.LogContext -Properties @{
            ErrorId = $errorInfo.ErrorId
            Category = $errorInfo.Category.ToString()
            Severity = $errorInfo.Severity.ToString()
            Strategy = $errorInfo.Strategy.ToString()
            FilePath = $filePath
            Context = $context
            IsTransient = $errorInfo.IsTransient
            Message = $exception.Message
        }

        return $errorInfo
    }

    # Determine error category based on message content
    [ErrorCategory] DetermineErrorCategory([string] $message) {
        $lowerMessage = $message.ToLowerInvariant()

        foreach ($category in $this.CategoryRules.Keys) {
            $rule = $this.CategoryRules[$category]
            foreach ($pattern in $rule.Patterns) {
                if ($lowerMessage -match $pattern) {
                    return $category
                }
            }
        }

        return [ErrorCategory]::Unknown
    }

    # Apply specific rules based on error details
    [void] ApplySpecificRules([ErrorInfo] $errorInfo, [System.Exception] $exception) {
        # File size specific rules
        if ($errorInfo.FilePath -and (Test-Path $errorInfo.FilePath -ErrorAction SilentlyContinue)) {
            try {
                $fileSize = (Get-Item $errorInfo.FilePath).Length
                $errorInfo.Properties['FileSize'] = $fileSize

                # Large files get different treatment
                if ($fileSize -gt 1GB) {
                    if ($errorInfo.Category -eq [ErrorCategory]::Resource) {
                        $errorInfo.Severity = [ErrorSeverity]::Critical
                        $errorInfo.Strategy = [RecoveryStrategy]::DelayedRetry
                        $errorInfo.Properties['RetryDelay'] = 300  # 5 minutes for large files
                    }
                }
            }
            catch {
                # File access error - record but continue
                $errorInfo.Properties['FileAccessError'] = $_.Exception.Message
            }
        }

        # Network drive specific rules
        if ($errorInfo.FilePath -match '^\\\\' -or $errorInfo.FilePath -match '^[A-Z]:' -and $errorInfo.FilePath.Length -gt 3) {
            if ($errorInfo.Category -eq [ErrorCategory]::Network) {
                $errorInfo.Properties['NetworkPath'] = $true
                $errorInfo.Properties['RetryDelay'] = 60  # 1 minute for network issues
            }
        }

        # Repeated error handling
        $historyKey = "$($errorInfo.OperationContext):$($errorInfo.FilePath)"
        if ($this.ErrorHistory.ContainsKey($historyKey)) {
            $existing = $this.ErrorHistory[$historyKey]
            $existing.AttemptCount++
            $existing.LastAttempt = Get-Date

            # Escalate after multiple failures
            if ($existing.AttemptCount -ge $this.Config.Processing.MaxRetryAttempts) {
                $errorInfo.Strategy = [RecoveryStrategy]::Quarantine
                $errorInfo.Severity = [ErrorSeverity]::Critical
                $errorInfo.RecommendedAction = "File has failed multiple times - quarantine recommended"
            }
            elseif ($existing.AttemptCount -ge 2 -and $errorInfo.IsTransient) {
                # Increase delay for repeated transient errors
                $delay = [Math]::Min(300, 30 * [Math]::Pow(2, $existing.AttemptCount - 1))
                $errorInfo.Properties['RetryDelay'] = $delay
            }

            # Update the existing entry
            $this.ErrorHistory[$historyKey] = $existing
            $errorInfo.AttemptCount = $existing.AttemptCount
            $errorInfo.FirstOccurrence = $existing.FirstOccurrence
        }
    }

    # Get recommended action for error
    [string] GetRecommendedAction([ErrorInfo] $errorInfo) {
        switch ($errorInfo.Strategy) {
            ([RecoveryStrategy]::Retry) {
                return "Retry operation immediately"
            }
            ([RecoveryStrategy]::DelayedRetry) {
                $delay = $errorInfo.Properties['RetryDelay']
                if ($delay) {
                    return "Retry operation after $delay seconds"
                } else {
                    return "Retry operation after standard delay"
                }
            }
            ([RecoveryStrategy]::Quarantine) {
                return "Move file to quarantine directory for manual review"
            }
            ([RecoveryStrategy]::Skip) {
                return "Skip file and continue with next operation"
            }
            ([RecoveryStrategy]::Escalate) {
                return "Escalate to administrator for manual intervention"
            }
            ([RecoveryStrategy]::Abort) {
                return "Abort current operation - requires configuration fix"
            }
            default {
                return "No specific action recommended"
            }
        }

        return "No specific action recommended"
    }

    # Record error in history and update counters
    [void] RecordError([ErrorInfo] $errorInfo) {
        # Update counters
        $this.ErrorCounters.Total++
        $this.ErrorCounters.ByCategory[$errorInfo.Category.ToString()]++
        $this.ErrorCounters.BySeverity[$errorInfo.Severity.ToString()]++

        # Add to recent errors queue
        $this.RecentErrors.Enqueue($errorInfo)

        # Maintain queue size
        while ($this.RecentErrors.Count -gt $this.MaxRecentErrors) {
            $oldError = $null
            $this.RecentErrors.TryDequeue([ref] $oldError) | Out-Null
        }

        # Add to history
        $historyKey = "$($errorInfo.OperationContext):$($errorInfo.FilePath)"
        $this.ErrorHistory[$historyKey] = $errorInfo
    }

    # Execute recovery strategy
    [bool] ExecuteRecovery([ErrorInfo] $errorInfo) {
        try {
            switch ($errorInfo.Strategy) {
                ([RecoveryStrategy]::Quarantine) {
                    return $this.QuarantineFile($errorInfo)
                }
                ([RecoveryStrategy]::DelayedRetry) {
                    $delay = $errorInfo.Properties['RetryDelay']
                    if ($delay -gt 0) {
                        Write-FileCopierLog -Level "Information" -Message "Delaying retry for error recovery" -Category $this.LogContext -Properties @{
                            ErrorId = $errorInfo.ErrorId
                            DelaySeconds = $delay
                            FilePath = $errorInfo.FilePath
                        }
                        Start-Sleep -Seconds $delay
                    }
                    return $true
                }
                ([RecoveryStrategy]::Escalate) {
                    $this.EscalateError($errorInfo)
                    $this.ErrorCounters.Escalated++
                    return $false  # Don't retry after escalation
                }
                ([RecoveryStrategy]::Skip) {
                    Write-FileCopierLog -Level "Warning" -Message "Skipping file due to error" -Category $this.LogContext -Properties @{
                        ErrorId = $errorInfo.ErrorId
                        FilePath = $errorInfo.FilePath
                        Reason = $errorInfo.Message
                    }
                    return $false  # Don't retry
                }
                ([RecoveryStrategy]::Abort) {
                    Write-FileCopierLog -Level "Error" -Message "Aborting operation due to fatal error" -Category $this.LogContext -Properties @{
                        ErrorId = $errorInfo.ErrorId
                        FilePath = $errorInfo.FilePath
                        Reason = $errorInfo.Message
                    }
                    return $false  # Don't retry
                }
                default {
                    return $true  # Allow retry for other strategies
                }
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error during recovery execution: $($_.Exception.Message)" -Category $this.LogContext -Properties @{
                ErrorId = $errorInfo.ErrorId
                RecoveryStrategy = $errorInfo.Strategy.ToString()
                RecoveryException = $_.Exception.GetType().Name
            }
            return $false
        }

        return $true
    }

    # Quarantine a problematic file
    [bool] QuarantineFile([ErrorInfo] $errorInfo) {
        if (-not $errorInfo.FilePath -or -not (Test-Path $errorInfo.FilePath)) {
            Write-FileCopierLog -Level "Warning" -Message "Cannot quarantine - file not found" -Category $this.LogContext -Properties @{
                ErrorId = $errorInfo.ErrorId
                FilePath = $errorInfo.FilePath
            }
            return $false
        }

        try {
            $fileName = [System.IO.Path]::GetFileName($errorInfo.FilePath)
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $quarantineFileName = "$timestamp-$($errorInfo.ErrorId)-$fileName"
            $quarantineFullPath = Join-Path $this.QuarantinePath $quarantineFileName

            # Move file to quarantine
            Move-Item -Path $errorInfo.FilePath -Destination $quarantineFullPath -Force

            # Create error report
            $reportPath = "$quarantineFullPath.error-report.json"
            $report = @{
                ErrorId = $errorInfo.ErrorId
                OriginalPath = $errorInfo.FilePath
                QuarantineTime = Get-Date
                ErrorDetails = @{
                    Category = $errorInfo.Category.ToString()
                    Severity = $errorInfo.Severity.ToString()
                    Message = $errorInfo.Message
                    AttemptCount = $errorInfo.AttemptCount
                    FirstOccurrence = $errorInfo.FirstOccurrence
                    Context = $errorInfo.OperationContext
                    Properties = $errorInfo.Properties
                    StackTrace = $errorInfo.StackTrace
                }
            }

            $report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8

            $this.ErrorCounters.Quarantined++

            Write-FileCopierLog -Level "Warning" -Message "File quarantined successfully" -Category $this.LogContext -Properties @{
                ErrorId = $errorInfo.ErrorId
                OriginalPath = $errorInfo.FilePath
                QuarantinePath = $quarantineFullPath
                ReportPath = $reportPath
                AttemptCount = $errorInfo.AttemptCount
            }

            return $true
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to quarantine file: $($_.Exception.Message)" -Category $this.LogContext -Properties @{
                ErrorId = $errorInfo.ErrorId
                FilePath = $errorInfo.FilePath
                QuarantinePath = $this.QuarantinePath
                Exception = $_.Exception.GetType().Name
            }
            return $false
        }
    }

    # Escalate error to administrator
    [void] EscalateError([ErrorInfo] $errorInfo) {
        Write-FileCopierLog -Level "Error" -Message "ERROR ESCALATION REQUIRED" -Category "ESCALATION" -Properties @{
            ErrorId = $errorInfo.ErrorId
            FilePath = $errorInfo.FilePath
            Category = $errorInfo.Category.ToString()
            Severity = $errorInfo.Severity.ToString()
            Message = $errorInfo.Message
            AttemptCount = $errorInfo.AttemptCount
            FirstOccurrence = $errorInfo.FirstOccurrence
            Context = $errorInfo.OperationContext
            RecommendedAction = $errorInfo.RecommendedAction
        }

        # TODO: Add email notification, service desk integration, etc.
        # For now, we log with high visibility
    }

    # Convert error severity to log level
    [string] SeverityToLogLevel([ErrorSeverity] $severity) {
        switch ($severity) {
            ([ErrorSeverity]::Informational) { return "Information" }
            ([ErrorSeverity]::Warning) { return "Warning" }
            ([ErrorSeverity]::Recoverable) { return "Warning" }
            ([ErrorSeverity]::Critical) { return "Error" }
            ([ErrorSeverity]::Fatal) { return "Error" }
            default { return "Warning" }
        }

        return "Warning"
    }

    # Get error statistics
    [hashtable] GetErrorStatistics() {
        $stats = $this.ErrorCounters.Clone()
        $stats['RecentErrorsCount'] = $this.RecentErrors.Count
        $stats['HistoryCount'] = $this.ErrorHistory.Count
        $stats['QuarantinePath'] = $this.QuarantinePath

        # Calculate error rates
        $recentErrorsList = @($this.RecentErrors.ToArray())
        $last24Hours = $recentErrorsList | Where-Object { $_.Timestamp -gt (Get-Date).AddHours(-24) }
        $stats['ErrorsLast24Hours'] = $last24Hours.Count

        return $stats
    }

    # Get recent errors for monitoring
    [ErrorInfo[]] GetRecentErrors([int] $count = 50) {
        $recentList = @($this.RecentErrors.ToArray())
        return $recentList | Select-Object -Last $count
    }

    # Clear old error history
    [void] CleanupErrorHistory([int] $daysToKeep = 30) {
        $cutoffDate = (Get-Date).AddDays(-$daysToKeep)
        $keysToRemove = @()

        foreach ($key in $this.ErrorHistory.Keys) {
            $errorInfo = $this.ErrorHistory[$key]
            if ($errorInfo.FirstOccurrence -lt $cutoffDate) {
                $keysToRemove += $key
            }
        }

        foreach ($key in $keysToRemove) {
            $removed = $null
            $this.ErrorHistory.TryRemove($key, [ref] $removed) | Out-Null
        }

        Write-FileCopierLog -Level "Information" -Message "Error history cleanup completed" -Category $this.LogContext -Properties @{
            RemovedEntries = $keysToRemove.Count
            DaysKept = $daysToKeep
        }
    }
}