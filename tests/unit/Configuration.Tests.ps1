# Configuration.Tests.ps1 - Unit tests for Configuration module

BeforeAll {
    # Import test setup
    . "$PSScriptRoot\..\TestSetup.ps1"

    # Import the module under test
    Import-Module "$ModuleRoot\FileCopier.psd1" -Force

    # Initialize test environment
    Initialize-TestEnvironment
}

AfterAll {
    # Clean up test environment
    Cleanup-TestEnvironment
}

Describe "Configuration Module" {
    BeforeEach {
        # Reset configuration state before each test
        if (Get-Module FileCopier) {
            Remove-Module FileCopier -Force
        }
        Import-Module "$ModuleRoot\FileCopier.psd1" -Force
    }

    Context "Initialize-FileCopierConfig" {
        It "Should initialize with default configuration when no file exists" {
            # Arrange
            $nonExistentPath = Join-Path $TestDataRoot "nonexistent-config.json"

            # Act
            $config = Initialize-FileCopierConfig -ConfigPath $nonExistentPath

            # Assert
            $config | Should -Not -BeNullOrEmpty
            $config.directories | Should -Not -BeNullOrEmpty
            $config.directories.source | Should -Be "/tmp/Source"
            $config.monitoring | Should -Not -BeNullOrEmpty
            $config.copying | Should -Not -BeNullOrEmpty
            $config.verification | Should -Not -BeNullOrEmpty
            $config.logging | Should -Not -BeNullOrEmpty
            $config.service | Should -Not -BeNullOrEmpty
        }

        It "Should load configuration from valid JSON file" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "valid-config.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath

            # Act
            $config = Initialize-FileCopierConfig -ConfigPath $configPath

            # Assert
            $config | Should -Not -BeNullOrEmpty
            $config.directories.source | Should -Be $ValidTestConfig.directories.source
            $config.monitoring.fileFilters | Should -Contain "*.svs"
            $config.copying.maxRetries | Should -Be $ValidTestConfig.copying.maxRetries
        }

        It "Should validate configuration against schema when schema exists" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "config-with-schema.json"
            $schemaPath = "$ConfigRoot\settings.schema.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath

            # Act & Assert - should not throw
            { Initialize-FileCopierConfig -ConfigPath $configPath -SchemaPath $schemaPath } | Should -Not -Throw
        }

        It "Should throw error for invalid configuration against schema" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "invalid-config.json"
            $schemaPath = "$ConfigRoot\settings.schema.json"
            $invalidConfig = @{
                directories = @{
                    source = "invalid-path-format"
                }
                # Missing required sections
            }
            $invalidConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath

            # Act & Assert
            { Initialize-FileCopierConfig -ConfigPath $configPath -SchemaPath $schemaPath } | Should -Throw
        }

        It "Should apply environment variable overrides" {
            # Arrange
            $originalValue = [Environment]::GetEnvironmentVariable("FC_SOURCE_DIR")
            $testSourceDir = Join-Path $TestDataRoot "env-override-source"
            [Environment]::SetEnvironmentVariable("FC_SOURCE_DIR", $testSourceDir)

            try {
                # Act
                $config = Initialize-FileCopierConfig

                # Assert
                $config.directories.source | Should -Be $testSourceDir
            }
            finally {
                # Cleanup
                [Environment]::SetEnvironmentVariable("FC_SOURCE_DIR", $originalValue)
            }
        }

        It "Should handle numeric environment variable overrides" {
            # Arrange
            $originalValue = [Environment]::GetEnvironmentVariable("FC_MAX_CONCURRENT")
            [Environment]::SetEnvironmentVariable("FC_MAX_CONCURRENT", "7")

            try {
                # Act
                $config = Initialize-FileCopierConfig

                # Assert
                $config.copying.maxConcurrentCopies | Should -Be 7
                $config.copying.maxConcurrentCopies | Should -BeOfType [int]
            }
            finally {
                # Cleanup
                [Environment]::SetEnvironmentVariable("FC_MAX_CONCURRENT", $originalValue)
            }
        }
    }

    Context "Get-FileCopierConfig" {
        BeforeEach {
            # Initialize with test config
            $configPath = Join-Path $TestDataRoot "test-config.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            Initialize-FileCopierConfig -ConfigPath $configPath
        }

        It "Should return complete configuration when no section specified" {
            # Act
            $config = Get-FileCopierConfig

            # Assert
            $config | Should -Not -BeNullOrEmpty
            $config.directories | Should -Not -BeNullOrEmpty
            $config.monitoring | Should -Not -BeNullOrEmpty
            $config.copying | Should -Not -BeNullOrEmpty
            $config.verification | Should -Not -BeNullOrEmpty
            $config.logging | Should -Not -BeNullOrEmpty
            $config.service | Should -Not -BeNullOrEmpty
        }

        It "Should return specific section when requested" {
            # Act
            $dirs = Get-FileCopierConfig -Section "directories"

            # Assert
            $dirs | Should -Not -BeNullOrEmpty
            $dirs.source | Should -Be $ValidTestConfig.directories.source
            $dirs.targetA | Should -Be $ValidTestConfig.directories.targetA
            $dirs.targetB | Should -Be $ValidTestConfig.directories.targetB
        }

        It "Should throw error for non-existent section" {
            # Act & Assert
            { Get-FileCopierConfig -Section "nonexistent" } | Should -Throw "*section*not found*"
        }

        It "Should auto-initialize if config not loaded" {
            # Arrange - Remove any loaded configuration by reimporting module
            Remove-Module -Name "FileCopier" -Force -ErrorAction SilentlyContinue
            Import-Module "$ModuleRoot\FileCopier.psd1" -Force

            # Act
            $config = Get-FileCopierConfig

            # Assert - should return default config
            $config | Should -Not -BeNullOrEmpty
            $config.directories.source | Should -Be "/tmp/Source"
        }
    }

    Context "Set-FileCopierConfig" {
        BeforeEach {
            # Initialize with test config
            $configPath = Join-Path $TestDataRoot "test-config-modify.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            Initialize-FileCopierConfig -ConfigPath $configPath
        }

        It "Should update configuration property" {
            # Act
            Set-FileCopierConfig -Section "copying" -Property "maxConcurrentCopies" -Value 8

            # Assert
            $config = Get-FileCopierConfig
            $config.copying.maxConcurrentCopies | Should -Be 8
        }

        It "Should save configuration to file when Save switch is used" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "save-test-config.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            Initialize-FileCopierConfig -ConfigPath $configPath

            # Act
            Set-FileCopierConfig -Section "logging" -Property "level" -Value "Debug" -Save

            # Assert
            $savedConfig = Get-Content $configPath | ConvertFrom-Json
            $savedConfig.logging.level | Should -Be "Debug"
        }

        It "Should throw error for non-existent section" {
            # Act & Assert
            { Set-FileCopierConfig -Section "nonexistent" -Property "test" -Value "value" } | Should -Throw "*section*not found*"
        }

        It "Should throw error for non-existent property" {
            # Act & Assert
            { Set-FileCopierConfig -Section "copying" -Property "nonexistent" -Value "value" } | Should -Throw "*property*not found*"
        }

        It "Should throw error if configuration not initialized" {
            # Arrange - Reset configuration
            Remove-Module -Name "FileCopier" -Force -ErrorAction SilentlyContinue
            Import-Module "$ModuleRoot\FileCopier.psd1" -Force

            # Act & Assert
            { Set-FileCopierConfig -Section "copying" -Property "maxRetries" -Value 5 } | Should -Throw "*not initialized*"
        }
    }

    Context "Test-FileCopierConfig" {
        BeforeEach {
            # Initialize with test config
            $configPath = Join-Path $TestDataRoot "validation-test-config.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            Initialize-FileCopierConfig -ConfigPath $configPath
        }

        It "Should validate configuration successfully" {
            # Act
            $result = Test-FileCopierConfig

            # Assert
            $result | Should -Not -BeNullOrEmpty
            $result.IsValid | Should -Be $true
            $result.Errors | Should -BeNullOrEmpty
        }

        It "Should detect directory accessibility issues" {
            # Arrange
            Set-FileCopierConfig -Section "directories" -Property "source" -Value "Z:\NonExistentDrive\InvalidPath"

            # Act
            $result = Test-FileCopierConfig

            # Assert
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Not -BeNullOrEmpty
            ($result.Errors -join " ") | Should -Match "not accessible"
        }

        It "Should validate retry configuration consistency" {
            # Arrange - Set fewer retry delays than max retries
            Set-FileCopierConfig -Section "copying" -Property "maxRetries" -Value 5
            Set-FileCopierConfig -Section "copying" -Property "retryDelaySeconds" -Value @(1, 2)

            # Act
            $result = Test-FileCopierConfig

            # Assert
            $result.Warnings | Should -Not -BeNullOrEmpty
            ($result.Warnings -join " ") | Should -Match "retry"
        }

        It "Should validate hash verification configuration" {
            # Arrange - Set hash method without algorithm
            Set-FileCopierConfig -Section "verification" -Property "method" -Value "hash"
            Set-FileCopierConfig -Section "verification" -Property "hashAlgorithm" -Value ""

            # Act
            $result = Test-FileCopierConfig

            # Assert
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Not -BeNullOrEmpty
            ($result.Errors -join " ") | Should -Match "hash algorithm"
        }

        It "Should show detailed results when ShowDetails switch is used" {
            # This test verifies the function executes without error when ShowDetails is used
            # Act & Assert
            { Test-FileCopierConfig -ShowDetails } | Should -Not -Throw
        }

        It "Should throw error if configuration not initialized" {
            # Arrange - Reset configuration
            Remove-Module -Name "FileCopier" -Force -ErrorAction SilentlyContinue
            Import-Module "$ModuleRoot\FileCopier.psd1" -Force

            # Act & Assert
            { Test-FileCopierConfig } | Should -Throw "*not initialized*"
        }
    }

    Context "Reload-FileCopierConfig" {
        It "Should reload configuration from file" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "reload-test-config.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            Initialize-FileCopierConfig -ConfigPath $configPath

            # Modify the file
            $modifiedConfig = $ValidTestConfig.Clone()
            $modifiedConfig.copying.maxRetries = 10
            $modifiedConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath

            # Act
            Reload-FileCopierConfig

            # Assert
            $config = Get-FileCopierConfig
            $config.copying.maxRetries | Should -Be 10
        }

        It "Should throw error if no config file path is set" {
            # Arrange - Reset configuration without file path
            Remove-Module -Name "FileCopier" -Force -ErrorAction SilentlyContinue
            Import-Module "$ModuleRoot\FileCopier.psd1" -Force

            # Act & Assert
            { Reload-FileCopierConfig } | Should -Throw "*No configuration file path*"
        }
    }

    Context "Schema Validation" {
        It "Should validate required properties" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "missing-required.json"
            $incompleteConfig = @{
                directories = @{
                    source = "C:\Source"
                    # Missing required targetA, targetB, etc.
                }
                # Missing other required sections
            }
            $incompleteConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $schemaPath = "$ConfigRoot\settings.schema.json"

            # Act & Assert
            { Initialize-FileCopierConfig -ConfigPath $configPath -SchemaPath $schemaPath } | Should -Throw
        }

        It "Should validate numeric ranges" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "invalid-ranges.json"
            $invalidConfig = $ValidTestConfig.Clone()
            $invalidConfig.copying.maxRetries = 15  # Outside valid range (0-10)
            $invalidConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $schemaPath = "$ConfigRoot\settings.schema.json"

            # Act & Assert
            { Initialize-FileCopierConfig -ConfigPath $configPath -SchemaPath $schemaPath } | Should -Throw
        }

        It "Should validate path formats" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "invalid-paths.json"
            $invalidConfig = $ValidTestConfig.Clone()
            $invalidConfig.directories.source = "invalid-path-format"  # Should match Windows path pattern
            $invalidConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $schemaPath = "$ConfigRoot\settings.schema.json"

            # Act & Assert
            { Initialize-FileCopierConfig -ConfigPath $configPath -SchemaPath $schemaPath } | Should -Throw
        }
    }

    Context "Environment Variable Overrides" {
        BeforeEach {
            # Store original values
            $script:OriginalEnvVars = @{
                'FC_SOURCE_DIR' = [Environment]::GetEnvironmentVariable("FC_SOURCE_DIR")
                'FC_TARGETA_DIR' = [Environment]::GetEnvironmentVariable("FC_TARGETA_DIR")
                'FC_TARGETB_DIR' = [Environment]::GetEnvironmentVariable("FC_TARGETB_DIR")
                'FC_LOG_LEVEL' = [Environment]::GetEnvironmentVariable("FC_LOG_LEVEL")
                'FC_MAX_CONCURRENT' = [Environment]::GetEnvironmentVariable("FC_MAX_CONCURRENT")
                'FC_POLLING_INTERVAL' = [Environment]::GetEnvironmentVariable("FC_POLLING_INTERVAL")
            }
        }

        AfterEach {
            # Restore original values
            foreach ($var in $script:OriginalEnvVars.Keys) {
                [Environment]::SetEnvironmentVariable($var, $script:OriginalEnvVars[$var])
            }
        }

        It "Should override directory paths from environment variables" {
            # Arrange
            [Environment]::SetEnvironmentVariable("FC_SOURCE_DIR", "/tmp/EnvSource")
            [Environment]::SetEnvironmentVariable("FC_TARGETA_DIR", "/tmp/EnvTargetA")
            [Environment]::SetEnvironmentVariable("FC_TARGETB_DIR", "/tmp/EnvTargetB")

            # Act
            $config = Initialize-FileCopierConfig

            # Assert
            $config.directories.source | Should -Be "/tmp/EnvSource"
            $config.directories.targetA | Should -Be "/tmp/EnvTargetA"
            $config.directories.targetB | Should -Be "/tmp/EnvTargetB"
        }

        It "Should override logging level from environment variable" {
            # Arrange
            [Environment]::SetEnvironmentVariable("FC_LOG_LEVEL", "Debug")

            # Act
            $config = Initialize-FileCopierConfig

            # Assert
            $config.logging.level | Should -Be "Debug"
        }

        It "Should override numeric settings from environment variables" {
            # Arrange
            [Environment]::SetEnvironmentVariable("FC_MAX_CONCURRENT", "8")
            [Environment]::SetEnvironmentVariable("FC_POLLING_INTERVAL", "3")

            # Act
            $config = Initialize-FileCopierConfig

            # Assert
            $config.copying.maxConcurrentCopies | Should -Be 8
            $config.service.pollingIntervalSeconds | Should -Be 3
        }

        It "Should ignore empty environment variables" {
            # Arrange
            [Environment]::SetEnvironmentVariable("FC_SOURCE_DIR", "")
            [Environment]::SetEnvironmentVariable("FC_LOG_LEVEL", " ")

            # Act
            $config = Initialize-FileCopierConfig

            # Assert - should use default values
            $config.directories.source | Should -Be "/tmp/Source"
            $config.logging.level | Should -Be "Information"
        }
    }

    Context "Error Handling" {
        It "Should handle JSON parsing errors gracefully" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "malformed.json"
            "{ invalid json content" | Set-Content $configPath

            # Act & Assert
            { Initialize-FileCopierConfig -ConfigPath $configPath } | Should -Throw
        }

        It "Should handle file access errors gracefully" {
            # Arrange - Create a directory where we expect a file
            $configPath = Join-Path $TestDataRoot "directory-not-file"
            New-Item -Path $configPath -ItemType Directory -Force | Out-Null

            # Act & Assert
            { Initialize-FileCopierConfig -ConfigPath $configPath } | Should -Throw
        }

        It "Should handle schema file not found gracefully" {
            # Arrange
            $configPath = Join-Path $TestDataRoot "test-config.json"
            $ValidTestConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $nonExistentSchemaPath = Join-Path $TestDataRoot "nonexistent-schema.json"

            # Act & Assert - should not throw, but should warn
            { Initialize-FileCopierConfig -ConfigPath $configPath -SchemaPath $nonExistentSchemaPath } | Should -Not -Throw
        }
    }
}