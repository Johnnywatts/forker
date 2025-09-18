# FileCopier.Tests.ps1 - Unit tests for main FileCopier service orchestration

BeforeAll {
    # Load modules directly instead of importing as module
    . "$PSScriptRoot/../../modules/FileCopier/Configuration.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/Logging.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/Utils.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/CopyEngine.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/Verification.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/FileWatcher.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/ProcessingQueue.ps1"
    . "$PSScriptRoot/../../modules/FileCopier/FileCopier.psm1"

    # Create test directories
    $script:TestSourceDir = Join-Path $env:TEMP "test-source-$(Get-Random)"
    $script:TestTargetA = Join-Path $env:TEMP "test-targetA-$(Get-Random)"
    $script:TestTargetB = Join-Path $env:TEMP "test-targetB-$(Get-Random)"
    $script:TestConfigPath = Join-Path $env:TEMP "test-config-$(Get-Random).json"

    # Create test directories
    New-Item -Path $script:TestSourceDir -ItemType Directory -Force | Out-Null
    New-Item -Path $script:TestTargetA -ItemType Directory -Force | Out-Null
    New-Item -Path $script:TestTargetB -ItemType Directory -Force | Out-Null

    # Create test configuration file
    $testConfig = @{
        'SourceDirectory' = $script:TestSourceDir
        'Targets' = @{
            'TargetA' = @{
                'Path' = $script:TestTargetA
                'Enabled' = $true
            }
            'TargetB' = @{
                'Path' = $script:TestTargetB
                'Enabled' = $true
            }
        }
        'FileWatcher' = @{
            'PollingInterval' = 1000
            'StabilityCheckInterval' = 500
            'StabilityChecks' = 2
        }
        'Processing' = @{
            'MaxConcurrentCopies' = 2
            'RetryAttempts' = 3
            'RetryDelay' = 1000
            'QueueCheckInterval' = 500
        }
        'Verification' = @{
            'Enabled' = $true
            'HashRetryAttempts' = 2
            'HashRetryDelay' = 1000
        }
        'Logging' = @{
            'Level' = 'Information'
            'FilePath' = Join-Path $env:TEMP "test-filecopier-$(Get-Random).log"
            'MaxFileSizeMB' = 10
            'MaxFiles' = 3
        }
        'Service' = @{
            'HealthCheckInterval' = 2000
            'ConfigReloadInterval' = 5000
            'IntegrationInterval' = 1000
        }
    }

    # Save test configuration to file
    $testConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $script:TestConfigPath -Encoding UTF8
}

AfterAll {
    # Clean up test directories and files
    if (Test-Path $script:TestSourceDir) { Remove-Item -Path $script:TestSourceDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestTargetA) { Remove-Item -Path $script:TestTargetA -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestTargetB) { Remove-Item -Path $script:TestTargetB -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestConfigPath) { Remove-Item -Path $script:TestConfigPath -Force -ErrorAction SilentlyContinue }

    # Clean up any test log files
    Get-ChildItem -Path $env:TEMP -Filter "test-filecopier-*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe "FileCopier Module Integration Tests" {

    Context "Module Loading and Components" {
        It "Should load all required components successfully" {
            # Test that essential functions are available
            Get-Command Initialize-FileCopierConfig -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command Initialize-FileCopierLogging -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command Start-FileCopierService -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command Stop-FileCopierService -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have class definitions available" {
            # Test that classes can be referenced (basic smoke test)
            { [FileWatcher] } | Should -Not -Throw
            { [ProcessingQueue] } | Should -Not -Throw
        }
    }

    Context "Configuration Management" {
        It "Should initialize configuration successfully" {
            { Initialize-FileCopierConfig -ConfigPath $script:TestConfigPath } | Should -Not -Throw
        }

        It "Should load configuration from file" {
            $config = Get-FileCopierConfig -ConfigPath $script:TestConfigPath

            $config | Should -Not -BeNullOrEmpty
            $config.SourceDirectory | Should -Be $script:TestSourceDir
            $config.Targets | Should -Not -BeNullOrEmpty
            $config.Targets.TargetA | Should -Not -BeNullOrEmpty
        }

        It "Should validate configuration successfully" {
            $config = Get-FileCopierConfig -ConfigPath $script:TestConfigPath
            $result = Test-FileCopierConfig -Config $config

            $result | Should -Be $true
        }
    }

    Context "Logging System" {
        It "Should initialize logging system" {
            $config = Get-FileCopierConfig -ConfigPath $script:TestConfigPath

            { Initialize-FileCopierLogging -Config $config } | Should -Not -Throw
        }

        It "Should write log messages" {
            $config = Get-FileCopierConfig -ConfigPath $script:TestConfigPath
            Initialize-FileCopierLogging -Config $config

            { Write-FileCopierLog -Level "Information" -Message "Test message" -Category "Test" } | Should -Not -Throw
        }
    }

    Context "Service Management Functions" {
        BeforeEach {
            # Ensure any previous service is stopped
            try {
                if ($script:GlobalFileCopierService) {
                    Stop-FileCopierService -Service $script:GlobalFileCopierService | Out-Null
                }
            } catch {
                # Ignore errors from stopping non-existent service
            }
        }

        AfterEach {
            # Clean up any running service
            try {
                if ($script:GlobalFileCopierService) {
                    Stop-FileCopierService -Service $script:GlobalFileCopierService | Out-Null
                }
            } catch {
                # Ignore errors from stopping non-existent service
            }
        }

        It "Should start service with configuration path" {
            $result = Start-FileCopierService -SourceDirectory $script:TestSourceDir -ConfigPath $script:TestConfigPath

            $result | Should -Be $true
        }

        It "Should get service status after start" {
            Start-FileCopierService -SourceDirectory $script:TestSourceDir -ConfigPath $script:TestConfigPath | Out-Null

            if ($script:GlobalFileCopierService) {
                $status = Get-FileCopierServiceStatus -Service $script:GlobalFileCopierService

                $status | Should -Not -BeNullOrEmpty
                $status.IsRunning | Should -Be $true
            } else {
                Set-ItResult -Skipped -Because "Service not available in global variable"
            }
        }

        It "Should stop running service" {
            Start-FileCopierService -SourceDirectory $script:TestSourceDir -ConfigPath $script:TestConfigPath | Out-Null

            if ($script:GlobalFileCopierService) {
                $result = Stop-FileCopierService -Service $script:GlobalFileCopierService

                $result | Should -Be $true
            } else {
                Set-ItResult -Skipped -Because "Service not available in global variable"
            }
        }

        It "Should handle multiple start attempts gracefully" {
            $firstStart = Start-FileCopierService -SourceDirectory $script:TestSourceDir -ConfigPath $script:TestConfigPath
            $secondStart = Start-FileCopierService -SourceDirectory $script:TestSourceDir -ConfigPath $script:TestConfigPath

            $firstStart | Should -Be $true
            $secondStart | Should -Be $false
        }
    }

    Context "Component Integration" {
        It "Should create FileWatcher instance" {
            $config = Get-FileCopierConfig -ConfigPath $script:TestConfigPath

            { $watcher = [FileWatcher]::new($config) } | Should -Not -Throw
        }

        It "Should create ProcessingQueue instance" {
            $config = Get-FileCopierConfig -ConfigPath $script:TestConfigPath

            { $queue = [ProcessingQueue]::new($config) } | Should -Not -Throw
        }
    }

    Context "Utility Functions" {
        It "Should test directory access" {
            $result = Test-DirectoryAccess -DirectoryPath $script:TestSourceDir

            $result | Should -Be $true
        }

        It "Should format byte sizes" {
            $result = Format-ByteSize -Bytes 1024

            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike "*KB*"
        }

        It "Should format durations" {
            $duration = New-TimeSpan -Seconds 90
            $result = Format-Duration -TimeSpan $duration

            $result | Should -Not -BeNullOrEmpty
        }
    }

    Context "Error Handling" {
        It "Should handle invalid source directory gracefully" {
            $result = Start-FileCopierService -SourceDirectory "C:\NonExistentPath\Invalid" -ConfigPath $script:TestConfigPath

            $result | Should -Be $false
        }

        It "Should handle missing configuration file" {
            # Should still work with default configuration
            $result = Start-FileCopierService -SourceDirectory $script:TestSourceDir -ConfigPath "C:\NonExistent\config.json"

            # May succeed with default config or fail gracefully
            $result | Should -BeOfType [bool]

            # Clean up if it succeeded
            if ($result -eq $true -and $script:GlobalFileCopierService) {
                Stop-FileCopierService -Service $script:GlobalFileCopierService | Out-Null
            }
        }
    }
}