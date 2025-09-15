# CopyEngine.Tests.ps1 - Unit tests for File Copier streaming copy functionality

BeforeAll {
    # Set up test environment
    . "$PSScriptRoot\..\TestSetup.ps1"

    # Import the module under test
    Import-Module "$ModuleRoot\FileCopier.psd1" -Force

    # Initialize test environment
    Initialize-TestEnvironment
}

Describe "Copy Engine Module" {

    BeforeEach {
        # Reset module state before each test
        if (Get-Module FileCopier) {
            Remove-Module FileCopier -Force
        }
        Import-Module "$ModuleRoot\FileCopier.psd1" -Force

        # Initialize logging and configuration
        Initialize-FileCopierLogging -LogLevel "Debug" -EnableConsoleLogging
        Initialize-FileCopierConfig
    }

    Context "Copy-FileStreaming" {
        It "Should copy small files accurately" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-small-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-small-$(Get-Random).txt"
            $testContent = "This is a small test file for copy validation."
            Set-Content -Path $sourceFile -Value $testContent -NoNewline

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

                # Assert
                $result.Success | Should -Be $true
                Test-Path $destFile | Should -Be $true
                $copiedContent = Get-Content -Path $destFile -Raw
                $copiedContent | Should -Be $testContent
                $result.BytesCopied | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($testContent))
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should copy large files with chunked processing" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-large-$(Get-Random).dat"
            $destFile = Join-Path $TestDataRoot "copy-large-$(Get-Random).dat"
            $testSize = 5MB  # 5MB test file
            $chunkSize = 64KB

            # Create test file with known pattern
            $buffer = New-Object byte[] $testSize
            for ($i = 0; $i -lt $testSize; $i++) {
                $buffer[$i] = $i % 256
            }
            [System.IO.File]::WriteAllBytes($sourceFile, $buffer)

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile -ChunkSizeBytes $chunkSize

                # Assert
                $result.Success | Should -Be $true
                Test-Path $destFile | Should -Be $true
                $result.BytesCopied | Should -Be $testSize

                # Verify binary content matches
                $sourceBytes = [System.IO.File]::ReadAllBytes($sourceFile)
                $destBytes = [System.IO.File]::ReadAllBytes($destFile)
                $sourceBytes.Length | Should -Be $destBytes.Length

                # Compare first and last chunks to verify integrity
                for ($i = 0; $i -lt 1000; $i++) {
                    $sourceBytes[$i] | Should -Be $destBytes[$i]
                }
                for ($i = ($testSize - 1000); $i -lt $testSize; $i++) {
                    $sourceBytes[$i] | Should -Be $destBytes[$i]
                }
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should preserve timestamps when requested" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-timestamp-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-timestamp-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Timestamp test"

            # Set specific timestamps
            $testTime = (Get-Date).AddDays(-10)
            $sourceItem = Get-Item $sourceFile
            $sourceItem.CreationTime = $testTime
            $sourceItem.LastWriteTime = $testTime.AddHours(1)
            $sourceItem.LastAccessTime = $testTime.AddHours(2)

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile -PreserveTimestamps $true

                # Assert
                $result.Success | Should -Be $true
                $destItem = Get-Item $destFile
                $destItem.CreationTime | Should -Be $sourceItem.CreationTime
                $destItem.LastWriteTime | Should -Be $sourceItem.LastWriteTime
                # LastAccessTime can be inconsistent on Linux filesystems (relatime/noatime), so only test on Windows
                if ($IsWindows) {
                    $destItem.LastAccessTime | Should -Be $sourceItem.LastAccessTime
                } else {
                    # On Linux, many filesystems have relatime/noatime which makes LastAccessTime unreliable
                    # Just verify that LastAccessTime exists and is a valid DateTime
                    $destItem.LastAccessTime | Should -Not -BeNullOrEmpty
                    $destItem.LastAccessTime | Should -BeOfType [DateTime]
                }
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should handle progress callback correctly" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-progress-$(Get-Random).dat"
            $destFile = Join-Path $TestDataRoot "copy-progress-$(Get-Random).dat"
            $testSize = 1MB
            $buffer = New-Object byte[] $testSize
            [System.IO.File]::WriteAllBytes($sourceFile, $buffer)

            $script:progressCalls = @()
            $progressCallback = {
                param($BytesCopied, $TotalBytes, $PercentComplete, $OperationId)
                $script:progressCalls += @{
                    BytesCopied = $BytesCopied
                    TotalBytes = $TotalBytes
                    PercentComplete = $PercentComplete
                    OperationId = $OperationId
                }
            }

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile -ProgressCallback $progressCallback

                # Assert
                $result.Success | Should -Be $true
                $script:progressCalls.Count | Should -BeGreaterThan 0
                $script:progressCalls[-1].BytesCopied | Should -Be $testSize
                $script:progressCalls[-1].PercentComplete | Should -Be 100
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should create destination directory if it doesn't exist" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-newdir-$(Get-Random).txt"
            $destDir = Join-Path $TestDataRoot "newdir-$(Get-Random)"
            $destFile = Join-Path $destDir "copy-newdir.txt"
            Set-Content -Path $sourceFile -Value "Directory creation test"

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

                # Assert
                $result.Success | Should -Be $true
                Test-Path $destDir | Should -Be $true
                Test-Path $destFile | Should -Be $true
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }
            }
        }

        It "Should handle source file not found error" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "nonexistent-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-error-$(Get-Random).txt"

            # Act
            $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

            # Assert
            $result.Success | Should -Be $false
            $result.Error | Should -Match "Source file not found"
            Test-Path $destFile | Should -Be $false
        }

        It "Should cleanup temporary files on failure" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-cleanup-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-cleanup-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Cleanup test"

            # Create a scenario that will fail during copy (use invalid path)
            $invalidDestFile = if ($IsWindows) {
                "Z:\invalid\path\copy-cleanup.txt"
            } else {
                "/proc/invalid/path/copy-cleanup.txt"  # /proc is read-only
            }

            # Act
            $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $invalidDestFile

            # Assert
            $result.Success | Should -Be $false
            # Verify no .tmp files are left behind
            $tempFiles = Get-ChildItem -Path $TestDataRoot -Filter "*.tmp" -ErrorAction SilentlyContinue
            $tempFiles | Should -BeNullOrEmpty

            # Cleanup
            if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
        }

        It "Should return operation information" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-opinfo-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-opinfo-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Operation info test"

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

                # Assert
                $result.Success | Should -Be $true
                $result.OperationId | Should -Not -BeNullOrEmpty
                $result.BytesCopied | Should -BeGreaterThan 0
                $result.Duration | Should -BeGreaterOrEqual 0
                $result.AverageSpeed | Should -BeGreaterOrEqual 0
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }
    }

    Context "Copy-FileToMultipleDestinations" {
        It "Should copy file to multiple destinations efficiently" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-multi-$(Get-Random).txt"
            $dest1 = Join-Path $TestDataRoot "copy-multi1-$(Get-Random).txt"
            $dest2 = Join-Path $TestDataRoot "copy-multi2-$(Get-Random).txt"
            $dest3 = Join-Path $TestDataRoot "copy-multi3-$(Get-Random).txt"
            $testContent = "Multi-destination copy test with longer content to verify streaming."
            Set-Content -Path $sourceFile -Value $testContent -NoNewline

            try {
                # Act
                $result = Copy-FileToMultipleDestinations -SourcePath $sourceFile -DestinationPaths @($dest1, $dest2, $dest3)

                # Assert
                $result.Success | Should -Be $true
                $result.DestinationsCompleted | Should -Be 3

                Test-Path $dest1 | Should -Be $true
                Test-Path $dest2 | Should -Be $true
                Test-Path $dest3 | Should -Be $true

                # Verify content matches
                Get-Content -Path $dest1 -Raw | Should -Be $testContent
                Get-Content -Path $dest2 -Raw | Should -Be $testContent
                Get-Content -Path $dest3 -Raw | Should -Be $testContent
            }
            finally {
                # Cleanup
                @($sourceFile, $dest1, $dest2, $dest3) | ForEach-Object {
                    if (Test-Path $_) { Remove-Item $_ -Force }
                }
            }
        }

        It "Should preserve timestamps for all destinations" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-multitime-$(Get-Random).txt"
            $dest1 = Join-Path $TestDataRoot "copy-multitime1-$(Get-Random).txt"
            $dest2 = Join-Path $TestDataRoot "copy-multitime2-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Multi timestamp test"

            $testTime = (Get-Date).AddDays(-5)
            $sourceItem = Get-Item $sourceFile
            $sourceItem.CreationTime = $testTime
            $sourceItem.LastWriteTime = $testTime.AddHours(1)

            try {
                # Act
                $result = Copy-FileToMultipleDestinations -SourcePath $sourceFile -DestinationPaths @($dest1, $dest2) -PreserveTimestamps $true

                # Assert
                $result.Success | Should -Be $true

                $dest1Item = Get-Item $dest1
                $dest2Item = Get-Item $dest2

                $dest1Item.CreationTime | Should -Be $sourceItem.CreationTime
                $dest1Item.LastWriteTime | Should -Be $sourceItem.LastWriteTime
                $dest2Item.CreationTime | Should -Be $sourceItem.CreationTime
                $dest2Item.LastWriteTime | Should -Be $sourceItem.LastWriteTime
            }
            finally {
                # Cleanup
                @($sourceFile, $dest1, $dest2) | ForEach-Object {
                    if (Test-Path $_) { Remove-Item $_ -Force }
                }
            }
        }

        It "Should handle multi-destination failure gracefully" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-multifail-$(Get-Random).txt"
            $dest1 = Join-Path $TestDataRoot "copy-multifail1-$(Get-Random).txt"
            $invalidDest = if ($IsWindows) {
                "Z:\invalid\path\copy-multifail2.txt"
            } else {
                "/proc/invalid/path/copy-multifail2.txt"
            }
            Set-Content -Path $sourceFile -Value "Multi fail test"

            try {
                # Act
                $result = Copy-FileToMultipleDestinations -SourcePath $sourceFile -DestinationPaths @($dest1, $invalidDest)

                # Assert
                $result.Success | Should -Be $false
                $result.Error | Should -Not -BeNullOrEmpty

                # Verify no partial files are left
                Test-Path $dest1 | Should -Be $false
                Test-Path ($dest1 + ".tmp") | Should -Be $false
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $dest1) { Remove-Item $dest1 -Force }
            }
        }
    }

    Context "Copy Operation Monitoring" {
        It "Should track active operations" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-monitor-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-monitor-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Operation monitoring test"

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile
                $opInfo = Get-CopyOperationInfo -OperationId $result.OperationId

                # Assert
                $result.Success | Should -Be $true
                if ($opInfo) {  # Operation might be cleaned up quickly
                    $opInfo.SourcePath | Should -Be $sourceFile
                    $opInfo.DestinationPath | Should -Be $destFile
                    $opInfo.Status | Should -Be "Completed"
                }
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should provide statistics" {
            # Arrange
            Reset-CopyEngineStatistics
            $initialStats = Get-CopyEngineStatistics

            $sourceFile = Join-Path $TestDataRoot "test-stats-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-stats-$(Get-Random).txt"
            $testContent = "Statistics test content"
            Set-Content -Path $sourceFile -Value $testContent -NoNewline

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile
                $finalStats = Get-CopyEngineStatistics

                # Assert
                $result.Success | Should -Be $true
                $finalStats.TotalFilesCopied | Should -BeGreaterThan $initialStats.TotalFilesCopied
                $finalStats.TotalBytesCopied | Should -BeGreaterThan $initialStats.TotalBytesCopied
                $finalStats.LastCopyDuration | Should -BeGreaterOrEqual 0
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should reset statistics correctly" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-reset-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-reset-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Reset test"

            try {
                # Act
                Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile
                Reset-CopyEngineStatistics
                $stats = Get-CopyEngineStatistics

                # Assert
                $stats.TotalFilesCopied | Should -Be 0
                $stats.TotalBytesCopied | Should -Be 0
                $stats.AverageSpeed | Should -Be 0
                $stats.LastCopyDuration | Should -Be 0
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }
    }

    Context "Memory Efficiency" {
        It "Should maintain low memory usage for large files" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-memory-$(Get-Random).dat"
            $destFile = Join-Path $TestDataRoot "copy-memory-$(Get-Random).dat"
            $testSize = 10MB  # Reasonable size for testing
            $chunkSize = 64KB

            # Create test file
            $buffer = New-Object byte[] $testSize
            [System.IO.File]::WriteAllBytes($sourceFile, $buffer)

            try {
                # Measure memory before copy
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                $memoryBefore = Get-MemoryUsage

                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile -ChunkSizeBytes $chunkSize

                # Measure memory after copy
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                $memoryAfter = Get-MemoryUsage

                # Assert
                $result.Success | Should -Be $true
                $memoryIncrease = $memoryAfter.WorkingSetMB - $memoryBefore.WorkingSetMB

                # Memory increase should be minimal (less than 5MB for 10MB file)
                $memoryIncrease | Should -BeLessThan 5
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }
    }

    Context "Configuration Integration" {
        It "Should use configuration values when parameters not specified" {
            # Arrange
            Set-FileCopierConfig -Section "copying" -Property "chunkSizeBytes" -Value 32768  # 32KB
            Set-FileCopierConfig -Section "copying" -Property "preserveTimestamps" -Value $true

            $sourceFile = Join-Path $TestDataRoot "test-config-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-config-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Configuration test"

            $testTime = (Get-Date).AddDays(-1)
            $sourceItem = Get-Item $sourceFile
            $sourceItem.LastWriteTime = $testTime

            try {
                # Act - Don't specify chunk size or preserve timestamps parameters
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

                # Assert
                $result.Success | Should -Be $true

                # Should have preserved timestamps (from config)
                $destItem = Get-Item $destFile
                $destItem.LastWriteTime | Should -Be $sourceItem.LastWriteTime
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }
    }

    Context "Error Handling and Edge Cases" {
        It "Should handle zero-byte files correctly" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-empty-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-empty-$(Get-Random).txt"
            New-Item -Path $sourceFile -ItemType File  # Creates empty file

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

                # Assert
                $result.Success | Should -Be $true
                $result.BytesCopied | Should -Be 0
                Test-Path $destFile | Should -Be $true
                (Get-Item $destFile).Length | Should -Be 0
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }

        It "Should handle file already exists scenario" {
            # Arrange
            $sourceFile = Join-Path $TestDataRoot "test-exists-$(Get-Random).txt"
            $destFile = Join-Path $TestDataRoot "copy-exists-$(Get-Random).txt"
            Set-Content -Path $sourceFile -Value "Original content" -NoNewline
            Set-Content -Path $destFile -Value "Existing content"

            try {
                # Act
                $result = Copy-FileStreaming -SourcePath $sourceFile -DestinationPath $destFile

                # Assert
                $result.Success | Should -Be $true
                Get-Content -Path $destFile -Raw | Should -Be "Original content"
            }
            finally {
                # Cleanup
                if (Test-Path $sourceFile) { Remove-Item $sourceFile -Force }
                if (Test-Path $destFile) { Remove-Item $destFile -Force }
            }
        }
    }
}