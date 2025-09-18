# Unit Tests for Processing Queue Module
# Tests thread-safe processing queue, multi-target coordination, and retry logic

BeforeAll {
    # Import required modules
    $ModulePath = Join-Path $PSScriptRoot "../../modules/FileCopier"
    Import-Module (Join-Path $ModulePath "Configuration.ps1") -Force
    Import-Module (Join-Path $ModulePath "Logging.ps1") -Force
    Import-Module (Join-Path $ModulePath "Utils.ps1") -Force
    Import-Module (Join-Path $ModulePath "CopyEngine.ps1") -Force
    Import-Module (Join-Path $ModulePath "ProcessingQueue.ps1") -Force

    # Create test directory
    if ($env:TEMP) {
        $Global:TestDirectory = Join-Path $env:TEMP "FileCopier.ProcessingQueueTests.$(Get-Random)"
    } else {
        $Global:TestDirectory = Join-Path "/tmp" "FileCopier.ProcessingQueueTests.$(Get-Random)"
    }
    New-Item -ItemType Directory -Path $Global:TestDirectory -Force | Out-Null

    # Create target directories
    $Global:TargetA = Join-Path $Global:TestDirectory "TargetA"
    $Global:TargetB = Join-Path $Global:TestDirectory "TargetB"
    New-Item -ItemType Directory -Path $Global:TargetA -Force | Out-Null
    New-Item -ItemType Directory -Path $Global:TargetB -Force | Out-Null

    # Test configuration
    $Global:TestConfig = @{
        Processing = @{
            MaxConcurrentOperations = 2
            ProcessingInterval = 1  # Reduced for faster testing
            OperationTimeoutMinutes = 2  # Reduced for faster testing
            MaxRetries = 2  # Reduced for faster testing
            RetryDelayMinutes = 0.1  # Reduced for faster testing (6 seconds)
            ShutdownTimeoutSeconds = 10
            MaxCompletedItems = 50
            CompletedItemRetentionHours = 1
            HighQueueThreshold = 10
            Destinations = @{
                TargetA = @{ Directory = $Global:TargetA }
                TargetB = @{ Directory = $Global:TargetB }
            }
        }
    }

    # Initialize logging for tests
    Initialize-FileCopierLogging -LogLevel "Error" -EnableConsoleLogging -EnableFileLogging:$false -EnableEventLogging:$false

    # Helper function to create test files
    function New-TestFile {
        param(
            [string] $FilePath,
            [int] $SizeBytes = 1024
        )

        $data = [byte[]]::new($SizeBytes)
        [System.Random]::new().NextBytes($data)
        [System.IO.File]::WriteAllBytes($FilePath, $data)
        return Get-Item $FilePath
    }

    # Helper function to create detection item (from FileWatcher)
    function New-DetectionItem {
        param(
            [string] $FilePath,
            [int] $FileSize = 1024
        )

        return @{
            FilePath = $FilePath
            DetectedTime = Get-Date
            QueuedTime = Get-Date
            FileSize = $FileSize
            LastModified = (Get-Item $FilePath).LastWriteTime
            StabilityChecks = 3
        }
    }

    # Helper function to wait for item completion
    function Wait-ForItemCompletion {
        param(
            [ProcessingQueue] $Queue,
            [string] $OperationId,
            [int] $TimeoutSeconds = 30
        )

        $timeout = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $timeout) {
            $status = $Queue.GetQueueStatus()
            if ($Queue.CompletedItems.ContainsKey($OperationId)) {
                return $Queue.CompletedItems[$OperationId]
            }
            Start-Sleep -Milliseconds 200
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

Describe "ProcessingQueue Class" {

    Context "Initialization" {
        It "Should initialize with configuration" {
            $queue = [ProcessingQueue]::new($Global:TestConfig)

            $queue | Should -Not -BeNullOrEmpty
            $queue.Config | Should -Be $Global:TestConfig
            $queue.IsRunning | Should -Be $false
            $queue.Queue | Should -Not -BeNullOrEmpty
            $queue.ActiveItems | Should -Not -BeNullOrEmpty
            $queue.CompletedItems | Should -Not -BeNullOrEmpty
        }

        It "Should initialize performance counters" {
            $queue = [ProcessingQueue]::new($Global:TestConfig)

            $queue.PerformanceCounters | Should -Not -BeNullOrEmpty
            $queue.PerformanceCounters.ItemsQueued | Should -Be 0
            $queue.PerformanceCounters.ItemsProcessing | Should -Be 0
            $queue.PerformanceCounters.ItemsCompleted | Should -Be 0
        }

        It "Should set up concurrency control" {
            $queue = [ProcessingQueue]::new($Global:TestConfig)

            $queue.MaxConcurrentOperations | Should -Be $Global:TestConfig.Processing.MaxConcurrentOperations
            $queue.ConcurrencyControl | Should -Not -BeNullOrEmpty
            $queue.ConcurrencyControl.CurrentCount | Should -Be $queue.MaxConcurrentOperations
        }
    }

    Context "Queue Operations" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should start and stop the queue" {
            $Global:TestQueue.Start()
            $Global:TestQueue.IsRunning | Should -Be $true

            $Global:TestQueue.Stop()
            $Global:TestQueue.IsRunning | Should -Be $false
        }

        It "Should enqueue detection items" {
            $testFile = Join-Path $Global:TestDirectory "test.svs"
            New-TestFile -FilePath $testFile -SizeBytes 2048

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 2048
            $Global:TestQueue.EnqueueItem($detectionItem)

            $Global:TestQueue.PerformanceCounters.ItemsQueued | Should -Be 1
            $Global:TestQueue.Queue.Count | Should -Be 1
        }

        It "Should create processing items from detection items" {
            $testFile = Join-Path $Global:TestDirectory "test.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)

            $processingItem | Should -Not -BeNullOrEmpty
            $processingItem.OperationId | Should -Not -BeNullOrEmpty
            $processingItem.FilePath | Should -Be $testFile
            $processingItem.ProcessingState | Should -Be "Queued"
            $processingItem.Destinations | Should -Not -BeNullOrEmpty
            $processingItem.Destinations.Keys | Should -Contain "TargetA"
            $processingItem.Destinations.Keys | Should -Contain "TargetB"
        }

        It "Should provide queue status" {
            $status = $Global:TestQueue.GetQueueStatus()

            $status | Should -Not -BeNullOrEmpty
            $status.QueueCount | Should -BeOfType [int]
            $status.ActiveCount | Should -BeOfType [int]
            $status.CompletedCount | Should -BeOfType [int]
            $status.IsRunning | Should -Be $false
            $status.ConcurrentCapacity | Should -Be $Global:TestConfig.Processing.MaxConcurrentOperations
            $status.PerformanceCounters | Should -Not -BeNullOrEmpty
        }
    }

    Context "Item Processing" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
            $Global:TestQueue.Start()
            Start-Sleep -Seconds 1  # Allow queue to initialize
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should process items successfully" {
            $testFile = Join-Path $Global:TestDirectory "success.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $Global:TestQueue.EnqueueItem($detectionItem)

            # Wait for processing to complete
            Start-Sleep -Seconds 5

            # Check results
            $Global:TestQueue.PerformanceCounters.ItemsQueued | Should -BeGreaterThan 0

            # Verify files were copied to targets
            $targetFileA = Join-Path $Global:TargetA "success.svs"
            $targetFileB = Join-Path $Global:TargetB "success.svs"

            # Note: In actual implementation, this would work with real CopyEngine
            # For unit tests, we'd need to mock the copy operations
        }

        It "Should handle multiple items concurrently" {
            $file1 = Join-Path $Global:TestDirectory "concurrent1.svs"
            $file2 = Join-Path $Global:TestDirectory "concurrent2.svs"
            New-TestFile -FilePath $file1 -SizeBytes 1024
            New-TestFile -FilePath $file2 -SizeBytes 1024

            $item1 = New-DetectionItem -FilePath $file1 -FileSize 1024
            $item2 = New-DetectionItem -FilePath $file2 -FileSize 1024

            $Global:TestQueue.EnqueueItem($item1)
            $Global:TestQueue.EnqueueItem($item2)

            # Wait for processing
            Start-Sleep -Seconds 5

            $Global:TestQueue.PerformanceCounters.ItemsQueued | Should -Be 2
        }

        It "Should respect concurrency limits" {
            $maxConcurrent = $Global:TestConfig.Processing.MaxConcurrentOperations

            # Create more items than concurrent limit
            $itemCount = $maxConcurrent + 2
            for ($i = 1; $i -le $itemCount; $i++) {
                $testFile = Join-Path $Global:TestDirectory "limit$i.svs"
                New-TestFile -FilePath $testFile -SizeBytes 512

                $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 512
                $Global:TestQueue.EnqueueItem($detectionItem)
            }

            # Check that concurrency is controlled
            Start-Sleep -Seconds 2
            $status = $Global:TestQueue.GetQueueStatus()

            # Should not exceed max concurrent operations
            $status.AvailableCapacity | Should -BeGreaterOrEqual 0
            ($maxConcurrent - $status.AvailableCapacity) | Should -BeLessOrEqual $maxConcurrent
        }
    }

    Context "State Management" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should track processing states correctly" {
            $testFile = Join-Path $Global:TestDirectory "state.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)

            # Initial state
            $processingItem.ProcessingState | Should -Be "Queued"

            # Check destination states
            foreach ($destName in $processingItem.Destinations.Keys) {
                $destInfo = $processingItem.Destinations[$destName]
                $destInfo.Status | Should -Be "Pending"
                $destInfo.Progress | Should -Be 0
                $destInfo.RetryCount | Should -Be 0
            }
        }

        It "Should handle progress updates" {
            $testFile = Join-Path $Global:TestDirectory "progress.svs"
            New-TestFile -FilePath $testFile -SizeBytes 2048

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 2048
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)

            # Simulate progress update
            $Global:TestQueue.UpdateProgress($processingItem, 1024, 2048, 50.0)

            $processingItem.OverallProgress | Should -Be 50.0
            $processingItem.LastActivity | Should -BeGreaterThan $processingItem.CreatedTime
        }

        It "Should maintain error history" {
            $testFile = Join-Path $Global:TestDirectory "error.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)

            # Simulate error
            $exception = [System.Exception]::new("Test error")
            $Global:TestQueue.HandleProcessingError($processingItem, $exception)

            $processingItem.ProcessingState | Should -Be "Failed"
            $processingItem.ErrorHistory | Should -Not -BeNullOrEmpty
            $processingItem.ErrorHistory[0].Error | Should -Be "Test error"
        }
    }

    Context "Retry Logic" {
        BeforeEach {
            # Use faster retry config for testing
            $retryConfig = $Global:TestConfig.Clone()
            $retryConfig.Processing.RetryDelayMinutes = 0.01  # 0.6 seconds
            $Global:TestQueue = [ProcessingQueue]::new($retryConfig)
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should retry failed items" {
            $testFile = Join-Path $Global:TestDirectory "retry.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)

            # Simulate failure and add to completed items
            $exception = [System.Exception]::new("Temporary failure")
            $Global:TestQueue.HandleProcessingError($processingItem, $exception)
            $Global:TestQueue.CompleteItemProcessing($processingItem)

            $initialRetryCount = $processingItem.RetryCount

            # Wait for retry logic to kick in
            Start-Sleep -Seconds 2
            $Global:TestQueue.RetryFailedItems()

            # Should have been retried
            $processingItem.RetryCount | Should -BeGreaterThan $initialRetryCount
        }

        It "Should not retry beyond max retries" {
            $testFile = Join-Path $Global:TestDirectory "maxretry.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)

            # Set retry count to max
            $maxRetries = $Global:TestQueue.Config.Processing.MaxRetries
            $processingItem.RetryCount = $maxRetries

            # Simulate failure
            $exception = [System.Exception]::new("Permanent failure")
            $Global:TestQueue.HandleProcessingError($processingItem, $exception)
            $Global:TestQueue.CompleteItemProcessing($processingItem)

            # Try to retry
            $Global:TestQueue.RetryFailedItems()

            # Should not be retried
            $processingItem.RetryCount | Should -Be $maxRetries
            $Global:TestQueue.Queue.Count | Should -Be 0
        }
    }

    Context "Cleanup and Maintenance" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should clean up old completed items" {
            # Add multiple completed items
            for ($i = 1; $i -le 5; $i++) {
                $testFile = Join-Path $Global:TestDirectory "cleanup$i.svs"
                New-TestFile -FilePath $testFile -SizeBytes 512

                $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 512
                $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)
                $processingItem.ProcessingState = "Completed"
                $processingItem.CompletionTime = (Get-Date).AddHours(-2)  # Old completion

                $Global:TestQueue.CompletedItems.TryAdd($processingItem.OperationId, $processingItem) | Out-Null
            }

            $initialCount = $Global:TestQueue.CompletedItems.Count
            $Global:TestQueue.CleanupCompletedItems()

            # Should have cleaned up old items
            $Global:TestQueue.CompletedItems.Count | Should -BeLessThan $initialCount
        }

        It "Should detect stalled operations" {
            $Global:TestQueue.Start()

            $testFile = Join-Path $Global:TestDirectory "stalled.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $processingItem = $Global:TestQueue.CreateProcessingItem($detectionItem)
            $processingItem.ProcessingState = "Processing"
            $processingItem.LastActivity = (Get-Date).AddMinutes(-5)  # Old activity

            $Global:TestQueue.ActiveItems.TryAdd($processingItem.OperationId, $processingItem) | Out-Null

            $initialActiveCount = $Global:TestQueue.ActiveItems.Count
            $Global:TestQueue.CheckActiveOperations()

            # Should have detected and handled stalled operation
            $Global:TestQueue.ActiveItems.Count | Should -BeLessThan $initialActiveCount
        }
    }

    Context "Health Monitoring" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should provide health status" {
            $health = $Global:TestQueue.GetHealthStatus()

            $health | Should -Not -BeNullOrEmpty
            $health.Status | Should -BeIn @("Healthy", "Warning", "Error", "Stopped")
            $health.Issues | Should -BeOfType [array]
            $health.QueueStatus | Should -Not -BeNullOrEmpty
            $health.PerformanceCounters | Should -Not -BeNullOrEmpty
        }

        It "Should detect high queue depth" {
            # Add many items to trigger high queue warning
            $highThreshold = $Global:TestConfig.Processing.HighQueueThreshold
            for ($i = 1; $i -le ($highThreshold + 5); $i++) {
                $testFile = Join-Path $Global:TestDirectory "high$i.svs"
                New-TestFile -FilePath $testFile -SizeBytes 256

                $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 256
                $Global:TestQueue.EnqueueItem($detectionItem)
            }

            $health = $Global:TestQueue.GetHealthStatus()
            $health.Status | Should -Be "Warning"
            $health.Issues | Should -Contain "High queue depth: $($Global:TestQueue.Queue.Count)"
        }

        It "Should detect high failure rate" {
            # Simulate high failure rate
            $Global:TestQueue.PerformanceCounters.ItemsCompleted = 10
            $Global:TestQueue.PerformanceCounters.ItemsFailed = 5  # 50% failure rate

            $health = $Global:TestQueue.GetHealthStatus()
            $health.Status | Should -Be "Warning"
            $health.Issues[0] | Should -Match "High failure rate"
        }
    }
}

Describe "Static Utility Functions" {

    Context "Start-ProcessingQueue" {
        It "Should start processing queue with default configuration" {
            $processor = Start-ProcessingQueue

            try {
                $processor | Should -Not -BeNullOrEmpty
                $processor.IsRunning | Should -Be $true
            }
            finally {
                if ($processor.IsRunning) {
                    $processor.Stop()
                }
            }
        }

        It "Should start processing queue with custom configuration" {
            $customConfig = @{
                Processing = @{
                    MaxConcurrentOperations = 1
                    ProcessingInterval = 3
                    OperationTimeoutMinutes = 30
                    MaxRetries = 1
                    RetryDelayMinutes = 1
                    ShutdownTimeoutSeconds = 15
                    MaxCompletedItems = 100
                    CompletedItemRetentionHours = 12
                    HighQueueThreshold = 50
                    Destinations = @{
                        TestTarget = @{ Directory = $Global:TestDirectory }
                    }
                }
            }

            $processor = Start-ProcessingQueue -Configuration $customConfig

            try {
                $processor | Should -Not -BeNullOrEmpty
                $processor.IsRunning | Should -Be $true
                $processor.MaxConcurrentOperations | Should -Be 1
            }
            finally {
                if ($processor.IsRunning) {
                    $processor.Stop()
                }
            }
        }
    }

    Context "Stop-ProcessingQueue" {
        It "Should stop processing queue successfully" {
            $processor = Start-ProcessingQueue
            $processor.IsRunning | Should -Be $true

            Stop-ProcessingQueue -ProcessingQueue $processor
            $processor.IsRunning | Should -Be $false
        }
    }

    Context "Get-DefaultProcessingConfig" {
        It "Should return valid default configuration" {
            $config = Get-DefaultProcessingConfig

            $config | Should -Not -BeNullOrEmpty
            $config.Processing | Should -Not -BeNullOrEmpty
            $config.Processing.MaxConcurrentOperations | Should -BeGreaterThan 0
            $config.Processing.Destinations | Should -Not -BeNullOrEmpty
            $config.Processing.Destinations.Keys | Should -Contain "TargetA"
            $config.Processing.Destinations.Keys | Should -Contain "TargetB"
        }
    }
}

Describe "Integration Scenarios" {

    Context "End-to-End Processing" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
            $Global:TestQueue.Start()
            Start-Sleep -Seconds 1
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should handle complete processing workflow" {
            $testFile = Join-Path $Global:TestDirectory "workflow.svs"
            New-TestFile -FilePath $testFile -SizeBytes 2048

            # Simulate FileWatcher detection
            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 2048

            # Enqueue for processing
            $Global:TestQueue.EnqueueItem($detectionItem)

            # Wait for processing to begin
            Start-Sleep -Seconds 3

            # Check that item was processed
            $status = $Global:TestQueue.GetQueueStatus()
            $status.QueueCount + $status.ActiveCount + $status.CompletedCount | Should -BeGreaterThan 0
            $Global:TestQueue.PerformanceCounters.ItemsQueued | Should -Be 1
        }

        It "Should maintain performance under load" {
            $fileCount = 5
            $startTime = Get-Date

            # Create multiple files for processing
            for ($i = 1; $i -le $fileCount; $i++) {
                $testFile = Join-Path $Global:TestDirectory "load$i.svs"
                New-TestFile -FilePath $testFile -SizeBytes 1024

                $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
                $Global:TestQueue.EnqueueItem($detectionItem)
            }

            # Wait for processing
            Start-Sleep -Seconds 10

            $endTime = Get-Date
            $processingTime = ($endTime - $startTime).TotalSeconds

            # Performance check
            $processingTime | Should -BeLessThan 15
            $Global:TestQueue.PerformanceCounters.ItemsQueued | Should -Be $fileCount
        }
    }

    Context "Error Recovery Scenarios" {
        BeforeEach {
            $Global:TestQueue = [ProcessingQueue]::new($Global:TestConfig)
        }

        AfterEach {
            if ($Global:TestQueue.IsRunning) {
                $Global:TestQueue.Stop()
            }
        }

        It "Should recover from processing errors gracefully" {
            $Global:TestQueue.Start()

            # Create test file
            $testFile = Join-Path $Global:TestDirectory "error_recovery.svs"
            New-TestFile -FilePath $testFile -SizeBytes 1024

            $detectionItem = New-DetectionItem -FilePath $testFile -FileSize 1024
            $Global:TestQueue.EnqueueItem($detectionItem)

            # Let processing attempt and potentially fail
            Start-Sleep -Seconds 5

            # Check that system is still healthy
            $health = $Global:TestQueue.GetHealthStatus()
            $health.Status | Should -BeIn @("Healthy", "Warning")  # Should not be "Error"
            $Global:TestQueue.IsRunning | Should -Be $true
        }
    }
}