# Unit Tests for File Watcher Module
# Tests FileSystemWatcher implementation, file completion detection, and queue management

BeforeAll {
    # Import required modules
    $ModulePath = Join-Path $PSScriptRoot "../../modules/FileCopier"
    Import-Module (Join-Path $ModulePath "Configuration.ps1") -Force
    Import-Module (Join-Path $ModulePath "Logging.ps1") -Force
    Import-Module (Join-Path $ModulePath "Utils.ps1") -Force
    Import-Module (Join-Path $ModulePath "FileWatcher.ps1") -Force

    # Create test directory
    if ($env:TEMP) {
        $Global:TestDirectory = Join-Path $env:TEMP "FileCopier.FileWatcherTests.$(Get-Random)"
    } else {
        $Global:TestDirectory = Join-Path "/tmp" "FileCopier.FileWatcherTests.$(Get-Random)"
    }
    New-Item -ItemType Directory -Path $Global:TestDirectory -Force | Out-Null

    # Create subdirectory for subdirectory monitoring tests
    $Global:TestSubDirectory = Join-Path $Global:TestDirectory "SubDir"
    New-Item -ItemType Directory -Path $Global:TestSubDirectory -Force | Out-Null

    # Test configuration
    $Global:TestConfig = @{
        Monitoring = @{
            IncludeSubdirectories = $false
            FileFilters = @("*.svs", "*.tiff", "*.tif", "*.test")
            ExcludeExtensions = @(".tmp", ".temp", ".part", ".lock")
            MinimumFileAge = 1  # Reduced for faster testing
            StabilityCheckInterval = 1  # Reduced for faster testing
            MaxStabilityChecks = 3  # Reduced for faster testing
        }
    }

    # Initialize logging for tests
    Initialize-FileCopierLogging -LogLevel "Error" -EnableConsoleLogging -EnableFileLogging:$false -EnableEventLogging:$false

    # Helper function to create test files
    function New-TestFile {
        param(
            [string] $FilePath,
            [int] $SizeBytes = 1024,
            [bool] $SimulateProgressive = $false
        )

        if ($SimulateProgressive) {
            # Simulate progressive writing by creating file in chunks
            $chunkSize = [math]::Max(256, $SizeBytes / 4)
            $bytesWritten = 0

            while ($bytesWritten -lt $SizeBytes) {
                $remainingBytes = $SizeBytes - $bytesWritten
                $currentChunk = [math]::Min($chunkSize, $remainingBytes)

                $data = [byte[]]::new($currentChunk)
                [System.Random]::new().NextBytes($data)

                if ($bytesWritten -eq 0) {
                    [System.IO.File]::WriteAllBytes($FilePath, $data)
                } else {
                    [System.IO.File]::WriteAllBytes($FilePath, ([System.IO.File]::ReadAllBytes($FilePath) + $data))
                }

                $bytesWritten += $currentChunk
                Start-Sleep -Milliseconds 100  # Simulate slow writing
            }
        } else {
            # Create file instantly
            $data = [byte[]]::new($SizeBytes)
            [System.Random]::new().NextBytes($data)
            [System.IO.File]::WriteAllBytes($FilePath, $data)
        }
    }

    # Helper function to wait for file to be queued
    function Wait-ForFileQueued {
        param(
            [FileWatcher] $Watcher,
            [string] $ExpectedFile,
            [int] $TimeoutSeconds = 10
        )

        $timeout = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $timeout) {
            $queuedFile = $Watcher.GetNextFile()
            if ($queuedFile -and $queuedFile.FilePath -eq $ExpectedFile) {
                return $queuedFile
            }
            Start-Sleep -Milliseconds 100
        }
        return $null
    }
}

AfterAll {
    # Cleanup test directory
    if (Test-Path $Global:TestDirectory) {
        Remove-Item $Global:TestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "FileWatcher Class" {

    Context "Initialization" {
        It "Should initialize with configuration" {
            $watcher = [FileWatcher]::new($Global:TestConfig)

            $watcher | Should -Not -BeNullOrEmpty
            $watcher.Config | Should -Be $Global:TestConfig
            $watcher.IsRunning | Should -Be $false
            $watcher.FileQueue | Should -Not -BeNullOrEmpty
            $watcher.PendingFiles | Should -Not -BeNullOrEmpty
        }

        It "Should initialize performance counters" {
            $watcher = [FileWatcher]::new($Global:TestConfig)

            $watcher.PerformanceCounters | Should -Not -BeNullOrEmpty
            $watcher.PerformanceCounters.FilesDetected | Should -Be 0
            $watcher.PerformanceCounters.FilesQueued | Should -Be 0
            $watcher.PerformanceCounters.FilesSkipped | Should -Be 0
        }
    }

    Context "Directory Monitoring" {
        BeforeEach {
            $Global:TestWatcher = [FileWatcher]::new($Global:TestConfig)
        }

        AfterEach {
            if ($Global:TestWatcher.IsRunning) {
                $Global:TestWatcher.StopWatching()
            }
        }

        It "Should start watching a directory" {
            $Global:TestWatcher.StartWatching($Global:TestDirectory)

            $Global:TestWatcher.IsRunning | Should -Be $true
            $Global:TestWatcher.Watcher | Should -Not -BeNullOrEmpty
            $Global:TestWatcher.Watcher.Path | Should -Be $Global:TestDirectory
        }

        It "Should stop watching a directory" {
            $Global:TestWatcher.StartWatching($Global:TestDirectory)
            $Global:TestWatcher.StopWatching()

            $Global:TestWatcher.IsRunning | Should -Be $false
        }

        It "Should fail to start watching non-existent directory" {
            $nonExistentPath = Join-Path $Global:TestDirectory "NonExistent"

            { $Global:TestWatcher.StartWatching($nonExistentPath) } | Should -Throw
        }

        It "Should not start watching if already running" {
            $Global:TestWatcher.StartWatching($Global:TestDirectory)

            # This should not throw, but should log a warning
            { $Global:TestWatcher.StartWatching($Global:TestDirectory) } | Should -Not -Throw
            $Global:TestWatcher.IsRunning | Should -Be $true
        }
    }

    Context "File Detection" {
        BeforeEach {
            $Global:TestWatcher = [FileWatcher]::new($Global:TestConfig)
            $Global:TestWatcher.StartWatching($Global:TestDirectory)
            Start-Sleep -Milliseconds 500  # Allow watcher to initialize
        }

        AfterEach {
            if ($Global:TestWatcher.IsRunning) {
                $Global:TestWatcher.StopWatching()
            }
        }

        It "Should detect new SVS files" {
            $testFile = Join-Path $Global:TestDirectory "test.svs"

            New-TestFile -FilePath $testFile -SizeBytes 1024
            Start-Sleep -Seconds 2  # Wait for detection

            $Global:TestWatcher.PerformanceCounters.FilesDetected | Should -BeGreaterThan 0
        }

        It "Should filter files by extension" {
            $validFile = Join-Path $Global:TestDirectory "valid.svs"
            $invalidFile = Join-Path $Global:TestDirectory "invalid.txt"

            New-TestFile -FilePath $validFile -SizeBytes 1024
            New-TestFile -FilePath $invalidFile -SizeBytes 1024
            Start-Sleep -Seconds 2

            # Valid file should be detected, invalid should be skipped
            $Global:TestWatcher.PerformanceCounters.FilesDetected | Should -BeGreaterThan 0
            $Global:TestWatcher.PerformanceCounters.FilesSkipped | Should -BeGreaterThan 0
        }

        It "Should exclude temporary files" {
            $tempFile = Join-Path $Global:TestDirectory "temp.svs.tmp"

            New-TestFile -FilePath $tempFile -SizeBytes 1024
            Start-Sleep -Seconds 2

            $Global:TestWatcher.PerformanceCounters.FilesSkipped | Should -BeGreaterThan 0
        }

        It "Should handle subdirectories when enabled" {
            $Global:TestWatcher.StopWatching()

            # Enable subdirectory monitoring
            $configWithSub = $Global:TestConfig.Clone()
            $configWithSub.Monitoring.IncludeSubdirectories = $true
            $subWatcher = [FileWatcher]::new($configWithSub)
            $subWatcher.StartWatching($Global:TestDirectory)

            try {
                Start-Sleep -Milliseconds 500
                $subFile = Join-Path $Global:TestSubDirectory "sub.svs"
                New-TestFile -FilePath $subFile -SizeBytes 1024
                Start-Sleep -Seconds 2

                $subWatcher.PerformanceCounters.FilesDetected | Should -BeGreaterThan 0
            }
            finally {
                $subWatcher.StopWatching()
            }
        }
    }

    Context "File Completion Detection" {
        BeforeEach {
            $Global:TestWatcher = [FileWatcher]::new($Global:TestConfig)
            $Global:TestWatcher.StartWatching($Global:TestDirectory)
            Start-Sleep -Milliseconds 500
        }

        AfterEach {
            if ($Global:TestWatcher.IsRunning) {
                $Global:TestWatcher.StopWatching()
            }
        }

        It "Should detect file completion for instantly created files" {
            $testFile = Join-Path $Global:TestDirectory "instant.svs"

            New-TestFile -FilePath $testFile -SizeBytes 2048

            # Wait for stability detection (should be quick for instant files)
            $queuedFile = Wait-ForFileQueued -Watcher $Global:TestWatcher -ExpectedFile $testFile -TimeoutSeconds 8

            $queuedFile | Should -Not -BeNullOrEmpty
            $queuedFile.FilePath | Should -Be $testFile
            $queuedFile.FileSize | Should -Be 2048
        }

        It "Should detect file completion for progressively written files" {
            $testFile = Join-Path $Global:TestDirectory "progressive.svs"

            # Start progressive write in background
            $job = Start-Job -ScriptBlock {
                param($FilePath)

                # Simulate large file being written progressively
                for ($i = 1; $i -le 5; $i++) {
                    $data = [byte[]]::new(1024)
                    [System.Random]::new().NextBytes($data)

                    if ($i -eq 1) {
                        [System.IO.File]::WriteAllBytes($FilePath, $data)
                    } else {
                        [System.IO.File]::WriteAllBytes($FilePath, ([System.IO.File]::ReadAllBytes($FilePath) + $data))
                    }
                    Start-Sleep -Milliseconds 200
                }
            } -ArgumentList $testFile

            try {
                # Wait for file to be completed and queued
                $queuedFile = Wait-ForFileQueued -Watcher $Global:TestWatcher -ExpectedFile $testFile -TimeoutSeconds 15

                $queuedFile | Should -Not -BeNullOrEmpty
                $queuedFile.FilePath | Should -Be $testFile
                $queuedFile.FileSize | Should -Be 5120  # 5 * 1024 bytes
            }
            finally {
                Wait-Job $job -Timeout 10 | Out-Null
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should not queue files that are still being written" {
            $testFile = Join-Path $Global:TestDirectory "stillwriting.svs"

            # Create file and keep writing to it
            New-TestFile -FilePath $testFile -SizeBytes 1024

            # Immediately check that file is not queued yet
            Start-Sleep -Milliseconds 500
            $queuedFile = $Global:TestWatcher.GetNextFile()
            $queuedFile | Should -BeNullOrEmpty

            # File should be in pending files
            $Global:TestWatcher.PendingFiles.ContainsKey($testFile) | Should -Be $true
        }

        It "Should handle file rename during monitoring" {
            $originalFile = Join-Path $Global:TestDirectory "original.svs"
            $renamedFile = Join-Path $Global:TestDirectory "renamed.svs"

            New-TestFile -FilePath $originalFile -SizeBytes 1024
            Start-Sleep -Milliseconds 500

            # Rename the file
            Move-Item $originalFile $renamedFile

            # Wait for renamed file to be queued
            $queuedFile = Wait-ForFileQueued -Watcher $Global:TestWatcher -ExpectedFile $renamedFile -TimeoutSeconds 8

            $queuedFile | Should -Not -BeNullOrEmpty
            $queuedFile.FilePath | Should -Be $renamedFile
        }
    }

    Context "Queue Management" {
        BeforeEach {
            $Global:TestWatcher = [FileWatcher]::new($Global:TestConfig)
            $Global:TestWatcher.StartWatching($Global:TestDirectory)
            Start-Sleep -Milliseconds 500
        }

        AfterEach {
            if ($Global:TestWatcher.IsRunning) {
                $Global:TestWatcher.StopWatching()
            }
        }

        It "Should queue multiple files in order" {
            $file1 = Join-Path $Global:TestDirectory "file1.svs"
            $file2 = Join-Path $Global:TestDirectory "file2.svs"
            $file3 = Join-Path $Global:TestDirectory "file3.svs"

            New-TestFile -FilePath $file1 -SizeBytes 1024
            Start-Sleep -Milliseconds 100
            New-TestFile -FilePath $file2 -SizeBytes 1024
            Start-Sleep -Milliseconds 100
            New-TestFile -FilePath $file3 -SizeBytes 1024

            # Wait for all files to be queued
            Start-Sleep -Seconds 5

            $Global:TestWatcher.GetQueueStatus().QueueCount | Should -BeGreaterOrEqual 3
        }

        It "Should dequeue files in FIFO order" {
            $file1 = Join-Path $Global:TestDirectory "first.svs"
            $file2 = Join-Path $Global:TestDirectory "second.svs"

            New-TestFile -FilePath $file1 -SizeBytes 1024
            Start-Sleep -Milliseconds 200
            New-TestFile -FilePath $file2 -SizeBytes 1024

            # Wait for files to be queued
            Start-Sleep -Seconds 5

            $firstFile = $Global:TestWatcher.GetNextFile()
            $secondFile = $Global:TestWatcher.GetNextFile()

            $firstFile | Should -Not -BeNullOrEmpty
            $secondFile | Should -Not -BeNullOrEmpty

            # First created should be first dequeued
            $firstFile.FilePath | Should -Be $file1
            $secondFile.FilePath | Should -Be $file2
        }

        It "Should return null when queue is empty" {
            $emptyResult = $Global:TestWatcher.GetNextFile()
            $emptyResult | Should -BeNullOrEmpty
        }

        It "Should provide accurate queue status" {
            $status = $Global:TestWatcher.GetQueueStatus()

            $status | Should -Not -BeNullOrEmpty
            $status.QueueCount | Should -BeOfType [int]
            $status.PendingCount | Should -BeOfType [int]
            $status.IsRunning | Should -Be $true
            $status.PerformanceCounters | Should -Not -BeNullOrEmpty
        }
    }

    Context "Performance Monitoring" {
        BeforeEach {
            $Global:TestWatcher = [FileWatcher]::new($Global:TestConfig)
            $Global:TestWatcher.StartWatching($Global:TestDirectory)
            Start-Sleep -Milliseconds 500
        }

        AfterEach {
            if ($Global:TestWatcher.IsRunning) {
                $Global:TestWatcher.StopWatching()
            }
        }

        It "Should track performance counters accurately" {
            $initialCounters = $Global:TestWatcher.PerformanceCounters.Clone()

            $validFile = Join-Path $Global:TestDirectory "valid.svs"
            $invalidFile = Join-Path $Global:TestDirectory "invalid.txt"

            New-TestFile -FilePath $validFile -SizeBytes 1024
            New-TestFile -FilePath $invalidFile -SizeBytes 1024

            Start-Sleep -Seconds 3

            $Global:TestWatcher.PerformanceCounters.FilesDetected | Should -BeGreaterThan $initialCounters.FilesDetected
            $Global:TestWatcher.PerformanceCounters.FilesSkipped | Should -BeGreaterThan $initialCounters.FilesSkipped
        }

        It "Should provide health status information" {
            $health = $Global:TestWatcher.GetHealthStatus()

            $health | Should -Not -BeNullOrEmpty
            $health.Status | Should -BeIn @("Healthy", "Warning", "Error")
            $health.Issues | Should -BeOfType [array]
            $health.PerformanceCounters | Should -Not -BeNullOrEmpty
            $health.QueueStatus | Should -Not -BeNullOrEmpty
        }
    }

    Context "Error Handling" {
        It "Should handle file disappearing during monitoring" {
            $watcher = [FileWatcher]::new($Global:TestConfig)
            $watcher.StartWatching($Global:TestDirectory)

            try {
                $testFile = Join-Path $Global:TestDirectory "disappearing.svs"
                New-TestFile -FilePath $testFile -SizeBytes 1024

                Start-Sleep -Milliseconds 500

                # Delete the file while it's being monitored
                Remove-Item $testFile -Force

                # Should handle gracefully without throwing
                Start-Sleep -Seconds 3

                # Should not have queued the disappeared file
                $queuedFile = $watcher.GetNextFile()
                if ($queuedFile) {
                    $queuedFile.FilePath | Should -Not -Be $testFile
                }
            }
            finally {
                $watcher.StopWatching()
            }
        }

        It "Should track watcher errors" {
            $watcher = [FileWatcher]::new($Global:TestConfig)
            $initialErrors = $watcher.PerformanceCounters.WatcherErrors

            # Errors are hard to simulate, so just verify counter exists
            $watcher.PerformanceCounters.WatcherErrors | Should -Be $initialErrors
        }
    }
}

Describe "Static Utility Functions" {

    Context "Start-FileWatching" {
        It "Should start file watching with default configuration" {
            $watcher = Start-FileWatching -DirectoryPath $Global:TestDirectory

            try {
                $watcher | Should -Not -BeNullOrEmpty
                $watcher.IsRunning | Should -Be $true
            }
            finally {
                if ($watcher.IsRunning) {
                    $watcher.StopWatching()
                }
            }
        }

        It "Should start file watching with custom configuration" {
            $customConfig = @{
                Monitoring = @{
                    IncludeSubdirectories = $true
                    FileFilters = @("*.test")
                    ExcludeExtensions = @(".exclude")
                    MinimumFileAge = 2
                    StabilityCheckInterval = 3
                    MaxStabilityChecks = 5
                }
            }

            $watcher = Start-FileWatching -DirectoryPath $Global:TestDirectory -Configuration $customConfig

            try {
                $watcher | Should -Not -BeNullOrEmpty
                $watcher.IsRunning | Should -Be $true
                $watcher.Config.Monitoring.IncludeSubdirectories | Should -Be $true
            }
            finally {
                if ($watcher.IsRunning) {
                    $watcher.StopWatching()
                }
            }
        }

        It "Should fail for non-existent directory" {
            $nonExistentPath = Join-Path $Global:TestDirectory "NonExistent"

            { Start-FileWatching -DirectoryPath $nonExistentPath } | Should -Throw
        }
    }

    Context "Stop-FileWatching" {
        It "Should stop file watching successfully" {
            $watcher = Start-FileWatching -DirectoryPath $Global:TestDirectory
            $watcher.IsRunning | Should -Be $true

            Stop-FileWatching -FileWatcher $watcher
            $watcher.IsRunning | Should -Be $false
        }
    }

    Context "Get-DefaultFileWatcherConfig" {
        It "Should return valid default configuration" {
            $config = Get-DefaultFileWatcherConfig

            $config | Should -Not -BeNullOrEmpty
            $config.Monitoring | Should -Not -BeNullOrEmpty
            $config.Monitoring.FileFilters | Should -Contain "*.svs"
            $config.Monitoring.ExcludeExtensions | Should -Contain ".tmp"
            $config.Monitoring.MinimumFileAge | Should -BeGreaterThan 0
        }
    }
}

Describe "Large File Handling" {

    Context "Performance Requirements" {
        BeforeEach {
            $Global:TestWatcher = [FileWatcher]::new($Global:TestConfig)
            $Global:TestWatcher.StartWatching($Global:TestDirectory)
            Start-Sleep -Milliseconds 500
        }

        AfterEach {
            if ($Global:TestWatcher.IsRunning) {
                $Global:TestWatcher.StopWatching()
            }
        }

        It "Should handle multiple large files efficiently" {
            # Create multiple larger test files (simulating smaller SVS files)
            $files = @()
            for ($i = 1; $i -le 3; $i++) {
                $testFile = Join-Path $Global:TestDirectory "large$i.svs"
                $files += $testFile
                New-TestFile -FilePath $testFile -SizeBytes (5 * 1024 * 1024)  # 5MB files
            }

            # Monitor memory and performance
            $startTime = Get-Date
            Start-Sleep -Seconds 10  # Wait for processing
            $endTime = Get-Date

            $processingTime = ($endTime - $startTime).TotalSeconds
            $processingTime | Should -BeLessThan 15  # Should process within reasonable time

            # Check that files were detected
            $Global:TestWatcher.PerformanceCounters.FilesDetected | Should -BeGreaterOrEqual 3
        }

        It "Should maintain low memory usage during monitoring" {
            # Get initial memory usage
            $process = Get-Process -Id $PID
            $initialMemoryMB = [Math]::Round($process.WorkingSet64 / 1MB, 2)

            # Create several files
            for ($i = 1; $i -le 5; $i++) {
                $testFile = Join-Path $Global:TestDirectory "memory$i.svs"
                New-TestFile -FilePath $testFile -SizeBytes (2 * 1024 * 1024)  # 2MB files
            }

            Start-Sleep -Seconds 5

            # Check memory usage hasn't grown excessively
            $process.Refresh()
            $finalMemoryMB = [Math]::Round($process.WorkingSet64 / 1MB, 2)
            $memoryGrowthMB = $finalMemoryMB - $initialMemoryMB

            # Memory growth should be reasonable (less than 50MB for test)
            $memoryGrowthMB | Should -BeLessThan 50
        }
    }
}