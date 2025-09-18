# ErrorHandler.Tests.ps1 - Unit tests for error handling and recovery system

BeforeAll {
    # Load modules directly
    . "$PSScriptRoot/../../modules/FileCopier/Configuration.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/Logging.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/Utils.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/ErrorHandler.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/RetryHandler.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/AuditLogger.ps1"

    # Create test directories
    $script:TestQuarantineDir = Join-Path $env:TEMP "test-quarantine-$(Get-Random)"
    $script:TestAuditDir = Join-Path $env:TEMP "test-audit-$(Get-Random)"
    $script:TestSourceFile = Join-Path $env:TEMP "test-source-file-$(Get-Random).txt"

    New-Item -Path $script:TestQuarantineDir -ItemType Directory -Force | Out-Null
    New-Item -Path $script:TestAuditDir -ItemType Directory -Force | Out-Null

    # Create test configuration
    $script:TestConfig = @{
        Processing = @{
            QuarantineDirectory = $script:TestQuarantineDir
            MaxRetryAttempts = 3
        }
        Logging = @{
            Level = 'Information'
            FilePath = Join-Path $env:TEMP "test-error-handler-$(Get-Random).log"
            AuditDirectory = $script:TestAuditDir
            AuditFlushInterval = 1000
        }
        Retry = @{
            Strategies = @{
                FileSystem = @{
                    MaxAttempts = 3
                    BaseDelayMs = 100
                    MaxDelayMs = 1000
                    BackoffMultiplier = 2.0
                }
            }
        }
    }

    # Initialize logging
    Initialize-FileCopierLogging -Config $script:TestConfig

    # Create test source file
    "Test content for error handling" | Set-Content -Path $script:TestSourceFile -Encoding UTF8
}

AfterAll {
    # Clean up test directories and files
    if (Test-Path $script:TestQuarantineDir) { Remove-Item -Path $script:TestQuarantineDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestAuditDir) { Remove-Item -Path $script:TestAuditDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestSourceFile) { Remove-Item -Path $script:TestSourceFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestConfig.Logging.FilePath) { Remove-Item -Path $script:TestConfig.Logging.FilePath -Force -ErrorAction SilentlyContinue }

    # Clean up any test log files
    Get-ChildItem -Path $env:TEMP -Filter "test-*handler*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $env:TEMP -Filter "test-source-file-*.txt" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe "ErrorHandler Class Tests" {

    Context "Error Classification" {
        BeforeEach {
            $script:ErrorHandler = [ErrorHandler]::new($script:TestConfig)
        }

        AfterEach {
            # Cleanup if needed
        }

        It "Should create ErrorHandler instance successfully" {
            $script:ErrorHandler | Should -Not -BeNullOrEmpty
            $script:ErrorHandler.QuarantinePath | Should -Exist
            $script:ErrorHandler.CategoryRules | Should -Not -BeNullOrEmpty
        }

        It "Should classify filesystem errors correctly" {
            $exception = [System.IO.FileNotFoundException]::new("The file 'test.txt' was not found")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "TestOperation", "C:\test.txt")

            $errorInfo.Category | Should -Be ([ErrorCategory]::FileSystem)
            $errorInfo.IsTransient | Should -Be $true
            $errorInfo.Strategy | Should -Be ([RecoveryStrategy]::DelayedRetry)
        }

        It "Should classify network errors correctly" {
            $exception = [System.Exception]::new("The network path was not found")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "NetworkOperation", "\\server\share\file.txt")

            $errorInfo.Category | Should -Be ([ErrorCategory]::Network)
            $errorInfo.IsTransient | Should -Be $true
            $errorInfo.Strategy | Should -Be ([RecoveryStrategy]::DelayedRetry)
        }

        It "Should classify permission errors correctly" {
            $exception = [System.UnauthorizedAccessException]::new("Access to the path is denied")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "PermissionTest", "C:\restricted\file.txt")

            $errorInfo.Category | Should -Be ([ErrorCategory]::Permission)
            $errorInfo.IsTransient | Should -Be $false
            $errorInfo.Strategy | Should -Be ([RecoveryStrategy]::Escalate)
        }

        It "Should classify verification errors correctly" {
            $exception = [System.Exception]::new("Hash mismatch detected - file corrupted")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "VerificationTest", "C:\data\file.txt")

            $errorInfo.Category | Should -Be ([ErrorCategory]::Verification)
            $errorInfo.IsTransient | Should -Be $false
            $errorInfo.Strategy | Should -Be ([RecoveryStrategy]::Quarantine)
        }

        It "Should track repeated errors and escalate" {
            $exception = [System.Exception]::new("Temporary file access error")

            # First error
            $errorInfo1 = $script:ErrorHandler.ClassifyError($exception, "RepeatedTest", $script:TestSourceFile)
            $errorInfo1.AttemptCount | Should -Be 1

            # Second error for same file
            $errorInfo2 = $script:ErrorHandler.ClassifyError($exception, "RepeatedTest", $script:TestSourceFile)
            $errorInfo2.AttemptCount | Should -Be 2
        }
    }

    Context "Error Recovery Execution" {
        BeforeEach {
            $script:ErrorHandler = [ErrorHandler]::new($script:TestConfig)
        }

        It "Should quarantine file successfully" {
            # Ensure test file exists
            if (-not (Test-Path $script:TestSourceFile)) {
                "Test content for quarantine" | Set-Content -Path $script:TestSourceFile -Encoding UTF8
            }

            $exception = [System.Exception]::new("File verification failed")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "QuarantineTest", $script:TestSourceFile)
            $errorInfo.Strategy = [RecoveryStrategy]::Quarantine

            $result = $script:ErrorHandler.ExecuteRecovery($errorInfo)

            $result | Should -Be $true
            $script:TestSourceFile | Should -Not -Exist

            # Check quarantine directory has the file
            $quarantineFiles = Get-ChildItem -Path $script:TestQuarantineDir -Filter "*$($errorInfo.ErrorId)*"
            $quarantineFiles | Should -Not -BeNullOrEmpty
            $quarantineFiles.Count | Should -BeGreaterThan 0
        }

        It "Should handle delayed retry strategy" {
            $exception = [System.Exception]::new("Temporary resource issue")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "DelayTest", "C:\temp\test.txt")
            $errorInfo.Strategy = [RecoveryStrategy]::DelayedRetry
            $errorInfo.Properties['RetryDelay'] = 1  # 1 second for testing

            $startTime = Get-Date
            $result = $script:ErrorHandler.ExecuteRecovery($errorInfo)
            $endTime = Get-Date

            $result | Should -Be $true
            $duration = ($endTime - $startTime).TotalMilliseconds
            $duration | Should -BeGreaterThan 900  # Should have delayed at least 900ms
        }

        It "Should escalate critical errors" {
            $exception = [System.Exception]::new("Critical system error")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "EscalationTest", "C:\critical\file.txt")
            $errorInfo.Strategy = [RecoveryStrategy]::Escalate

            $result = $script:ErrorHandler.ExecuteRecovery($errorInfo)

            $result | Should -Be $false  # Escalation should not retry
            $script:ErrorHandler.ErrorCounters.Escalated | Should -BeGreaterThan 0
        }
    }

    Context "Error Statistics and Monitoring" {
        BeforeEach {
            $script:ErrorHandler = [ErrorHandler]::new($script:TestConfig)
        }

        It "Should maintain accurate error statistics" {
            $exception1 = [System.Exception]::new("First error")
            $exception2 = [System.Exception]::new("Second error")

            $script:ErrorHandler.ClassifyError($exception1, "StatsTest1", "C:\file1.txt")
            $script:ErrorHandler.ClassifyError($exception2, "StatsTest2", "C:\file2.txt")

            $stats = $script:ErrorHandler.GetErrorStatistics()

            $stats.Total | Should -BeGreaterThan 0
            $stats.ByCategory | Should -Not -BeNullOrEmpty
            $stats.BySeverity | Should -Not -BeNullOrEmpty
            $stats.RecentErrorsCount | Should -BeGreaterThan 0
        }

        It "Should retrieve recent errors" {
            $exception = [System.Exception]::new("Recent error test")
            $script:ErrorHandler.ClassifyError($exception, "RecentTest", "C:\recent\file.txt")

            $recentErrors = $script:ErrorHandler.GetRecentErrors(10)

            $recentErrors | Should -Not -BeNullOrEmpty
            $recentErrors.Count | Should -BeGreaterThan 0
            $recentErrors[0].Message | Should -Be "Recent error test"
        }

        It "Should cleanup old error history" {
            # Add some errors
            $exception = [System.Exception]::new("Old error")
            $errorInfo = $script:ErrorHandler.ClassifyError($exception, "CleanupTest", "C:\old\file.txt")

            # Simulate old error by modifying timestamp
            $errorInfo.FirstOccurrence = (Get-Date).AddDays(-35)
            $historyKey = "$($errorInfo.OperationContext):$($errorInfo.FilePath)"
            $script:ErrorHandler.ErrorHistory[$historyKey] = $errorInfo

            # Cleanup errors older than 30 days
            $script:ErrorHandler.CleanupErrorHistory(30)

            # The old error should be removed
            $script:ErrorHandler.ErrorHistory.ContainsKey($historyKey) | Should -Be $false
        }
    }
}

Describe "RetryHandler Class Tests" {

    Context "Retry Strategy Configuration" {
        It "Should create RetryStrategy with default values" {
            $strategy = [RetryStrategy]::new()

            $strategy.MaxAttempts | Should -Be 3
            $strategy.BaseDelayMs | Should -Be 1000
            $strategy.BackoffMultiplier | Should -Be 2.0
            $strategy.UseJitter | Should -Be $true
        }

        It "Should create RetryStrategy with custom configuration" {
            $config = @{
                MaxAttempts = 5
                BaseDelayMs = 2000
                BackoffMultiplier = 1.5
                UseJitter = $false
            }

            $strategy = [RetryStrategy]::new($config)

            $strategy.MaxAttempts | Should -Be 5
            $strategy.BaseDelayMs | Should -Be 2000
            $strategy.BackoffMultiplier | Should -Be 1.5
            $strategy.UseJitter | Should -Be $false
        }
    }

    Context "Retry Execution" {
        BeforeEach {
            $script:RetryHandler = [RetryHandler]::new($script:TestConfig)
        }

        It "Should succeed on first attempt" {
            $attemptCount = 0
            $operation = {
                $attemptCount++
                return "Success on attempt $attemptCount"
            }

            $result = $script:RetryHandler.ExecuteWithRetry($operation, "FileSystem")

            $result.Success | Should -Be $true
            $result.TotalAttempts | Should -Be 1
            $result.Result | Should -Be "Success on attempt 1"
        }

        It "Should retry on transient failures and eventually succeed" {
            $attemptCount = 0
            $operation = {
                $attemptCount++
                if ($attemptCount -lt 3) {
                    throw [System.Exception]::new("sharing violation")
                }
                return "Success after retries"
            }

            $result = $script:RetryHandler.ExecuteWithRetry($operation, "FileSystem")

            $result.Success | Should -Be $true
            $result.TotalAttempts | Should -Be 3
            $result.Result | Should -Be "Success after retries"
            $result.Attempts.Count | Should -Be 3
        }

        It "Should fail after max attempts exceeded" {
            $operation = {
                throw [System.Exception]::new("persistent sharing violation")
            }

            $result = $script:RetryHandler.ExecuteWithRetry($operation, "FileSystem")

            $result.Success | Should -Be $false
            $result.TotalAttempts | Should -Be 3  # Default for FileSystem strategy
            $result.FinalError | Should -Match "sharing violation"
            $result.WasRetriable | Should -Be $true
        }

        It "Should not retry non-retriable errors" {
            $operation = {
                throw [System.Exception]::new("file not found")
            }

            $result = $script:RetryHandler.ExecuteWithRetry($operation, "FileSystem")

            $result.Success | Should -Be $false
            $result.TotalAttempts | Should -Be 1  # Should not retry
            $result.WasRetriable | Should -Be $false
        }

        It "Should calculate exponential backoff delay correctly" {
            $strategy = [RetryStrategy]@{
                BaseDelayMs = 1000
                BackoffMultiplier = 2.0
                UseJitter = $false
                MaxDelayMs = 10000
            }

            $delay1 = $script:RetryHandler.CalculateDelay(1, $strategy)
            $delay2 = $script:RetryHandler.CalculateDelay(2, $strategy)
            $delay3 = $script:RetryHandler.CalculateDelay(3, $strategy)

            $delay1 | Should -Be 1000  # 1000 * 2^(1-1) = 1000
            $delay2 | Should -Be 2000  # 1000 * 2^(2-1) = 2000
            $delay3 | Should -Be 4000  # 1000 * 2^(3-1) = 4000
        }
    }

    Context "Circuit Breaker Pattern" {
        BeforeEach {
            $script:RetryHandler = [RetryHandler]::new($script:TestConfig)
            $script:RetryHandler.CircuitBreakerThreshold = 3  # Lower threshold for testing
        }

        It "Should open circuit breaker after repeated failures" {
            $operation = {
                throw [System.Exception]::new("persistent network error")
            }

            # Trigger multiple failures to open circuit breaker
            for ($i = 1; $i -le 4; $i++) {
                $result = $script:RetryHandler.ExecuteWithRetry($operation, "TestOperation")
                $result.Success | Should -Be $false
            }

            # Circuit breaker should now be open
            $isOpen = $script:RetryHandler.IsCircuitBreakerOpen("TestOperation")
            $isOpen | Should -Be $true

            # Next operation should fail immediately due to open circuit
            $result = $script:RetryHandler.ExecuteWithRetry($operation, "TestOperation")
            $result.WasRetriable | Should -Be $false
            $result.FailureReason | Should -Match "Circuit breaker is open"
        }

        It "Should provide circuit breaker statistics" {
            # Trigger some failures
            $operation = { throw [System.Exception]::new("test error") }
            $script:RetryHandler.ExecuteWithRetry($operation, "TestStats")
            $script:RetryHandler.ExecuteWithRetry($operation, "TestStats")

            $stats = $script:RetryHandler.GetRetryStatistics()

            $stats.FailureCounts | Should -Not -BeNullOrEmpty
            $stats.Thresholds | Should -Not -BeNullOrEmpty
            $stats.Thresholds.CircuitBreakerThreshold | Should -Be 3
        }
    }

    Context "Specialized Retry Methods" {
        BeforeEach {
            $script:RetryHandler = [RetryHandler]::new($script:TestConfig)
        }

        It "Should execute file operation retry" {
            $operation = { return "File operation successful" }

            $result = $script:RetryHandler.RetryFileOperation($operation, $script:TestSourceFile)

            $result.Success | Should -Be $true
            $result.Result | Should -Be "File operation successful"
        }

        It "Should execute network operation retry" {
            $operation = { return "Network operation successful" }

            $result = $script:RetryHandler.RetryNetworkOperation($operation, "\\server\share")

            $result.Success | Should -Be $true
            $result.Result | Should -Be "Network operation successful"
        }

        It "Should execute verification operation retry" {
            $operation = { return "Verification successful" }

            $result = $script:RetryHandler.RetryVerificationOperation($operation, $script:TestSourceFile)

            $result.Success | Should -Be $true
            $result.Result | Should -Be "Verification successful"
        }
    }
}

Describe "AuditLogger Class Tests" {

    Context "Audit Logging Initialization" {
        It "Should create AuditLogger instance successfully" {
            $auditLogger = [AuditLogger]::new($script:TestConfig)

            $auditLogger | Should -Not -BeNullOrEmpty
            $auditLogger.AuditLogPath | Should -Not -BeNullOrEmpty
            $auditLogger.SecurityLogPath | Should -Not -BeNullOrEmpty
            $auditLogger.IsInitialized | Should -Be $true

            # Cleanup
            $auditLogger.Dispose()
        }

        It "Should create audit directories if they don't exist" {
            $auditLogger = [AuditLogger]::new($script:TestConfig)

            Test-Path $script:TestAuditDir | Should -Be $true
            Test-Path $auditLogger.AuditLogPath | Should -Be $true

            # Cleanup
            $auditLogger.Dispose()
        }
    }

    Context "Audit Event Logging" {
        BeforeEach {
            $script:AuditLogger = [AuditLogger]::new($script:TestConfig)
        }

        AfterEach {
            $script:AuditLogger.Dispose()
        }

        It "Should log audit events successfully" {
            $script:AuditLogger.LogAuditEvent([AuditEventType]::FileDetected, "TestOperation", "Test audit message", @{
                FilePath = $script:TestSourceFile
                FileSize = 1024
            })

            $stats = $script:AuditLogger.GetAuditStatistics()
            $stats.TotalEvents | Should -BeGreaterThan 0
        }

        It "Should log file operations with correct context" {
            $script:AuditLogger.LogFileOperation([AuditEventType]::FileCopyStarted, $script:TestSourceFile, "File copy started", @{
                TargetPath = "C:\destination\file.txt"
                FileSize = 2048
            })

            $recentEvents = $script:AuditLogger.SearchAuditLogs(@{ EventType = [AuditEventType]::FileCopyStarted })
            $recentEvents.Count | Should -BeGreaterThan 0
            $recentEvents[0].FilePath | Should -Be $script:TestSourceFile
        }

        It "Should log security events separately" {
            $script:AuditLogger.LogSecurityEvent("Unauthorized access attempt", @{
                UserId = "TestUser"
                ResourcePath = "C:\sensitive\data.txt"
                AttemptedAction = "Read"
            })

            $stats = $script:AuditLogger.GetAuditStatistics()
            $stats.SecurityEventCount | Should -BeGreaterThan 0
        }

        It "Should log performance alerts" {
            $script:AuditLogger.LogPerformanceAlert("CopySpeed", "1.5 MB/s", "10 MB/s", @{
                FilePath = $script:TestSourceFile
                Duration = "00:05:30"
            })

            $perfEvents = $script:AuditLogger.SearchAuditLogs(@{ EventType = [AuditEventType]::PerformanceAlert })
            $perfEvents.Count | Should -BeGreaterThan 0
        }
    }

    Context "Audit Search and Statistics" {
        BeforeEach {
            $script:AuditLogger = [AuditLogger]::new($script:TestConfig)

            # Add some test events
            $script:AuditLogger.LogAuditEvent([AuditEventType]::FileDetected, "TestOp1", "File 1 detected", @{ FilePath = "C:\test1.txt" })
            $script:AuditLogger.LogAuditEvent([AuditEventType]::FileCopyStarted, "TestOp2", "File 2 copy started", @{ FilePath = "C:\test2.txt" })
            $script:AuditLogger.LogAuditEvent([AuditEventType]::FileCopyCompleted, "TestOp3", "File 3 copy completed", @{ FilePath = "C:\test3.txt"; Success = $true })
        }

        AfterEach {
            $script:AuditLogger.Dispose()
        }

        It "Should provide accurate audit statistics" {
            $stats = $script:AuditLogger.GetAuditStatistics()

            $stats.TotalEvents | Should -BeGreaterThan 0
            $stats.EventsByType | Should -Not -BeNullOrEmpty
            $stats.EventsBySeverity | Should -Not -BeNullOrEmpty
            $stats.IsInitialized | Should -Be $true
        }

        It "Should search audit logs by criteria" {
            $copyEvents = $script:AuditLogger.SearchAuditLogs(@{ EventType = [AuditEventType]::FileCopyStarted })
            $copyEvents.Count | Should -BeGreaterThan 0
            $copyEvents[0].EventType | Should -Be ([AuditEventType]::FileCopyStarted)

            $successfulEvents = $script:AuditLogger.SearchAuditLogs(@{ Success = $true })
            $successfulEvents.Count | Should -BeGreaterThan 0
        }

        It "Should flush audit entries to disk" {
            # Wait for auto-flush or trigger manual flush
            $script:AuditLogger.FlushPendingEntries()

            # Verify audit log file has content
            Test-Path $script:AuditLogger.AuditLogPath | Should -Be $true
            $logContent = Get-Content -Path $script:AuditLogger.AuditLogPath -Raw
            $logContent | Should -Not -BeNullOrEmpty
        }
    }
}