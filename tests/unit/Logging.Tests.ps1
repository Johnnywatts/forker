# Logging.Tests.ps1 - Unit tests for File Copier Logging functionality

BeforeAll {
    # Set up test environment
    . "$PSScriptRoot\..\TestSetup.ps1"

    # Import the module under test
    Import-Module "$ModuleRoot\FileCopier.psd1" -Force

    # Initialize test environment
    Initialize-TestEnvironment
}

Describe "Logging Module" {

    BeforeEach {
        # Reset logging state before each test
        if (Get-Module FileCopier) {
            Remove-Module FileCopier -Force
        }
        Import-Module "$ModuleRoot\FileCopier.psd1" -Force
    }

    Context "Initialize-FileCopierLogging" {
        It "Should initialize with default configuration" {
            # Act
            { Initialize-FileCopierLogging } | Should -Not -Throw

            # Assert
            Get-FileCopierLogLevel | Should -Be "Information"
        }

        It "Should initialize with specified log level" {
            # Act
            Initialize-FileCopierLogging -LogLevel "Debug" -EnableFileLogging -EnableConsoleLogging

            # Assert
            Get-FileCopierLogLevel | Should -Be "Debug"
        }

        It "Should create log directory if it doesn't exist" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "test-logs"
            if (Test-Path $testLogDir) {
                Remove-Item $testLogDir -Recurse -Force
            }

            # Act
            Initialize-FileCopierLogging -LogDirectory $testLogDir -EnableFileLogging

            # Assert
            Test-Path $testLogDir | Should -Be $true
        }

        It "Should handle configuration loading gracefully" {
            # Arrange - Initialize configuration first
            Initialize-FileCopierConfig

            # Act
            { Initialize-FileCopierLogging } | Should -Not -Throw

            # Assert
            Get-FileCopierLogLevel | Should -Not -BeNullOrEmpty
        }
    }

    Context "Write-FileCopierLog" {
        It "Should write log message with correct level filtering" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-test-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Warning" -EnableFileLogging

            # Act - These should be written
            Write-FileCopierLog -Message "Warning message" -Level "Warning"
            Write-FileCopierLog -Message "Error message" -Level "Error"
            Write-FileCopierLog -Message "Critical message" -Level "Critical"

            # Act - These should be filtered out
            Write-FileCopierLog -Message "Debug message" -Level "Debug"
            Write-FileCopierLog -Message "Info message" -Level "Information"

            # Assert - Check that log file contains only appropriate messages
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logFile | Should -Not -BeNullOrEmpty

            $logContent = Get-Content $logFile.FullName -Raw
            $logContent | Should -Match "Warning message"
            $logContent | Should -Match "Error message"
            $logContent | Should -Match "Critical message"
            $logContent | Should -Not -Match "Debug message"
            $logContent | Should -Not -Match "Info message"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }

        It "Should include structured properties in log message" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-props-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Information" -EnableFileLogging

            # Act
            Write-FileCopierLog -Message "Test with properties" -Level "Information" -Properties @{
                SourceFile = "test.svs"
                TargetFile = "backup.svs"
                FileSize = 1024
            }

            # Assert
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logContent = Get-Content $logFile.FullName -Raw
            $logContent | Should -Match "SourceFile=test\.svs"
            $logContent | Should -Match "TargetFile=backup\.svs"
            $logContent | Should -Match "FileSize=1024"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }

        It "Should handle exceptions in log messages" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-exception-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Information" -EnableFileLogging

            try {
                throw "Test exception"
            }
            catch {
                $testException = $_.Exception
            }

            # Act
            Write-FileCopierLog -Message "Error occurred" -Level "Error" -Exception $testException

            # Assert
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logContent = Get-Content $logFile.FullName -Raw
            $logContent | Should -Match "Error occurred"
            $logContent | Should -Match "Test exception"
            $logContent | Should -Match "Exception:"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }

        It "Should include operation ID in log messages" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-opid-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Information" -EnableFileLogging

            # Act
            Write-FileCopierLog -Message "Operation started" -Level "Information" -OperationId "OP123"

            # Assert
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logContent = Get-Content $logFile.FullName -Raw
            $logContent | Should -Match "OP123"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }

        It "Should categorize log messages correctly" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-category-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Information" -EnableFileLogging

            # Act
            Write-FileCopierLog -Message "Config loaded" -Level "Information" -Category "Configuration"
            Write-FileCopierLog -Message "File copied" -Level "Information" -Category "FileOperation"

            # Assert
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logContent = Get-Content $logFile.FullName -Raw
            $logContent | Should -Match "\[Configuration\]"
            $logContent | Should -Match "\[FileOperation\]"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }

        It "Should work without initialization (fallback mode)" {
            # Arrange - Stop logging to test fallback
            Stop-FileCopierLogging

            # Act & Assert - Should not throw
            { Write-FileCopierLog -Message "Fallback message" -Level "Information" } | Should -Not -Throw
        }
    }

    Context "Log Level Management" {
        It "Should get current log level" {
            # Arrange
            Initialize-FileCopierLogging -LogLevel "Information"

            # Act & Assert
            Get-FileCopierLogLevel | Should -Be "Information"
        }

        It "Should set new log level" {
            # Arrange
            Initialize-FileCopierLogging -LogLevel "Information"

            # Act
            Set-FileCopierLogLevel -Level "Debug"

            # Assert
            Get-FileCopierLogLevel | Should -Be "Debug"
        }

        It "Should handle invalid log level gracefully" {
            # This should be caught by parameter validation
            { Set-FileCopierLogLevel -Level "InvalidLevel" } | Should -Throw
        }
    }

    Context "Performance Counters" {
        It "Should track message counts by level" {
            # Arrange
            Initialize-FileCopierLogging -LogLevel "Trace"

            # Act
            Write-FileCopierLog -Message "Debug msg" -Level "Debug"
            Write-FileCopierLog -Message "Info msg" -Level "Information"
            Write-FileCopierLog -Message "Warning msg" -Level "Warning"
            Write-FileCopierLog -Message "Error msg" -Level "Error"

            # Assert
            $counters = Get-LoggingPerformanceCounters
            $counters.MessagesLogged.Total | Should -BeGreaterOrEqual 4
            $counters.MessagesLogged.Debug | Should -BeGreaterOrEqual 1
            $counters.MessagesLogged.Information | Should -BeGreaterOrEqual 1
            $counters.MessagesLogged.Warning | Should -BeGreaterOrEqual 1
            $counters.MessagesLogged.Error | Should -BeGreaterOrEqual 1
        }

        It "Should reset performance counters" {
            # Arrange
            Initialize-FileCopierLogging -LogLevel "Information"
            Write-FileCopierLog -Message "Test message" -Level "Information"
            $initialCounters = Get-LoggingPerformanceCounters
            $initialCounters.MessagesLogged.Total | Should -BeGreaterThan 0

            # Act
            Reset-LoggingPerformanceCounters

            # Assert
            $resetCounters = Get-LoggingPerformanceCounters
            $resetCounters.MessagesLogged.Total | Should -Be 1  # The reset message itself
        }
    }

    Context "Message Formatting" {
        It "Should format timestamp correctly" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-timestamp-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Information" -EnableFileLogging

            # Act
            Write-FileCopierLog -Message "Timestamp test" -Level "Information"

            # Assert
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logContent = Get-Content $logFile.FullName -Raw
            # Should match format: yyyy-MM-dd HH:mm:ss.fff
            $logContent | Should -Match "\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }

        It "Should include level information correctly" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-level-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -LogLevel "Information" -EnableFileLogging

            # Act
            Write-FileCopierLog -Message "Level test" -Level "Information"

            # Assert
            Start-Sleep -Milliseconds 200
            $logFile = Get-ChildItem -Path $testLogDir -Filter "*.log" | Select-Object -First 1
            $logContent = Get-Content $logFile.FullName -Raw
            $logContent | Should -Match "Level test"
            $logContent | Should -Match "\[INFORMATION\s*\]"

            # Cleanup
            Remove-Item $testLogDir -Recurse -Force
        }
    }

    Context "Cleanup" {
        It "Should clean up resources on stop" {
            # Arrange
            $testLogDir = Join-Path $TestDataRoot "logging-cleanup-$(Get-Random)"
            Initialize-FileCopierLogging -LogDirectory $testLogDir -EnableFileLogging
            Write-FileCopierLog -Message "Before stop" -Level "Information"

            # Act
            { Stop-FileCopierLogging } | Should -Not -Throw

            # Assert - Should handle being called again without error
            { Stop-FileCopierLogging } | Should -Not -Throw

            # Cleanup
            if (Test-Path $testLogDir) {
                Remove-Item $testLogDir -Recurse -Force
            }
        }
    }

    Context "Cross-Platform Compatibility" {
        It "Should handle platform differences gracefully" {
            # Act & Assert - Should not throw regardless of platform
            { Initialize-FileCopierLogging -EnableEventLogging } | Should -Not -Throw
            { Write-FileCopierLog -Message "Cross-platform test" -Level "Information" } | Should -Not -Throw
        }

        It "Should use appropriate default paths" {
            # Act
            Initialize-FileCopierLogging

            # Assert - Should initialize without throwing
            Get-FileCopierLogLevel | Should -Not -BeNullOrEmpty
        }
    }
}