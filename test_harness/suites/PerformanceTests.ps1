# Performance Test Suite for Contention Testing
# Tests performance impact and fairness under contention conditions

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")

# Base class for performance tests
class PerformanceTestBase {
    [string] $TestId
    [string] $TestTempDirectory
    [array] $ManagedProcesses
    [array] $TempFiles
    [hashtable] $PerformanceMetrics
    [hashtable] $BaselineMetrics
    [hashtable] $PerformanceConfig

    PerformanceTestBase([string] $testId) {
        $this.TestId = $testId
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.TestTempDirectory = Join-Path $tempBase "PerformanceTest-$testId-$(Get-Random)"
        $this.ManagedProcesses = @()
        $this.TempFiles = @()
        $this.PerformanceMetrics = @{}
        $this.BaselineMetrics = @{}
        $this.PerformanceConfig = @{
            BaselineIterations = 10
            ContentionIterations = 10
            WarmupIterations = 3
            TimeoutSeconds = 30
            MaxAcceptableDegradation = 0.20  # 20%
            ProcessCount = 4
            FileSize = 1048576  # 1MB
            IterationDelay = 100  # 100ms between operations
        }
    }

    [void] SetupTest() {
        try {
            # Create test directory
            if (-not (Test-Path $this.TestTempDirectory)) {
                New-Item -ItemType Directory -Path $this.TestTempDirectory -Force | Out-Null
                Write-TestLog -Message "Created test directory: $($this.TestTempDirectory)" -Level "INFO" -TestId $this.TestId
            }

            Write-TestLog -Message "Performance test framework initialized" -Level "INFO" -TestId $this.TestId
        }
        catch {
            throw "Failed to setup performance test: $($_.Exception.Message)"
        }
    }

    [void] CleanupTest() {
        try {
            # Terminate any remaining processes
            $this.TerminateAllManagedProcesses()

            # Clean up temporary files
            $this.CleanupTempFiles()

            # Clean up test directory
            if (Test-Path $this.TestTempDirectory) {
                Remove-Item -Path $this.TestTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-TestLog -Message "Performance test cleanup completed" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Performance test cleanup failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
    }

    # Performance measurement methods
    [hashtable] MeasureBaselinePerformance([string] $operationType, [scriptblock] $operation) {
        $measurements = @{
            OperationType = $operationType
            Iterations = @()
            Statistics = @{}
        }

        Write-TestLog -Message "Measuring baseline performance for $operationType" -Level "INFO" -TestId $this.TestId

        # Warmup runs
        for ($i = 0; $i -lt $this.PerformanceConfig.WarmupIterations; $i++) {
            try {
                & $operation | Out-Null
            } catch {
                Write-TestLog -Message "Warmup iteration $i failed: $($_.Exception.Message)" -Level "WARN" -TestId $this.TestId
            }
        }

        # Actual measurements
        for ($i = 0; $i -lt $this.PerformanceConfig.BaselineIterations; $i++) {
            $startTime = Get-Date
            $startMemory = [System.GC]::GetTotalMemory($false)

            try {
                $result = & $operation
                $success = $true
                $error = $null
            }
            catch {
                $success = $false
                $error = $_.Exception.Message
            }

            $endTime = Get-Date
            $endMemory = [System.GC]::GetTotalMemory($false)

            $iteration = @{
                Index = $i
                StartTime = $startTime
                EndTime = $endTime
                Duration = ($endTime - $startTime).TotalMilliseconds
                MemoryBefore = $startMemory
                MemoryAfter = $endMemory
                MemoryDelta = $endMemory - $startMemory
                Success = $success
                Error = $error
                Result = $result
            }

            $measurements.Iterations += $iteration

            if ($success) {
                Write-TestLog -Message "Baseline iteration $i: $([math]::Round($iteration.Duration, 2))ms" -Level "DEBUG" -TestId $this.TestId
            } else {
                Write-TestLog -Message "Baseline iteration $i failed: $error" -Level "WARN" -TestId $this.TestId
            }

            Start-Sleep -Milliseconds $this.PerformanceConfig.IterationDelay
        }

        # Calculate statistics
        $successfulIterations = $measurements.Iterations | Where-Object { $_.Success }
        if ($successfulIterations.Count -gt 0) {
            $durations = $successfulIterations | ForEach-Object { $_.Duration }
            $memoryDeltas = $successfulIterations | ForEach-Object { $_.MemoryDelta }

            $measurements.Statistics = @{
                SuccessfulIterations = $successfulIterations.Count
                TotalIterations = $measurements.Iterations.Count
                SuccessRate = $successfulIterations.Count / $measurements.Iterations.Count
                AverageDuration = ($durations | Measure-Object -Average).Average
                MinDuration = ($durations | Measure-Object -Minimum).Minimum
                MaxDuration = ($durations | Measure-Object -Maximum).Maximum
                MedianDuration = $this.CalculateMedian($durations)
                StandardDeviation = $this.CalculateStandardDeviation($durations)
                AverageMemoryDelta = ($memoryDeltas | Measure-Object -Average).Average
                TotalMemoryDelta = ($memoryDeltas | Measure-Object -Sum).Sum
            }

            Write-TestLog -Message "Baseline performance: Avg=$([math]::Round($measurements.Statistics.AverageDuration, 2))ms, Min=$([math]::Round($measurements.Statistics.MinDuration, 2))ms, Max=$([math]::Round($measurements.Statistics.MaxDuration, 2))ms" -Level "INFO" -TestId $this.TestId
        } else {
            Write-TestLog -Message "No successful baseline iterations for $operationType" -Level "ERROR" -TestId $this.TestId
        }

        return $measurements
    }

    [hashtable] MeasureContentionPerformance([string] $operationType, [scriptblock] $operation, [int] $processCount) {
        $measurements = @{
            OperationType = $operationType
            ProcessCount = $processCount
            ProcessResults = @()
            AggregateStatistics = @{}
        }

        Write-TestLog -Message "Measuring contention performance for $operationType with $processCount processes" -Level "INFO" -TestId $this.TestId

        # Create and start multiple processes
        $jobs = @()
        for ($p = 0; $p -lt $processCount; $p++) {
            $jobScript = {
                param($TestId, $OperationType, $Operation, $Iterations, $Delay, $ProcessIndex)

                $results = @{
                    ProcessIndex = $ProcessIndex
                    Iterations = @()
                    Statistics = @{}
                }

                for ($i = 0; $i -lt $Iterations; $i++) {
                    $startTime = Get-Date
                    $startMemory = [System.GC]::GetTotalMemory($false)

                    try {
                        $result = & $Operation
                        $success = $true
                        $error = $null
                    }
                    catch {
                        $success = $false
                        $error = $_.Exception.Message
                    }

                    $endTime = Get-Date
                    $endMemory = [System.GC]::GetTotalMemory($false)

                    $iteration = @{
                        Index = $i
                        StartTime = $startTime
                        EndTime = $endTime
                        Duration = ($endTime - $startTime).TotalMilliseconds
                        MemoryBefore = $startMemory
                        MemoryAfter = $endMemory
                        MemoryDelta = $endMemory - $startMemory
                        Success = $success
                        Error = $error
                        Result = $result
                    }

                    $results.Iterations += $iteration
                    Start-Sleep -Milliseconds $Delay
                }

                # Calculate statistics for this process
                $successfulIterations = $results.Iterations | Where-Object { $_.Success }
                if ($successfulIterations.Count -gt 0) {
                    $durations = $successfulIterations | ForEach-Object { $_.Duration }
                    $results.Statistics = @{
                        SuccessfulIterations = $successfulIterations.Count
                        TotalIterations = $results.Iterations.Count
                        SuccessRate = $successfulIterations.Count / $results.Iterations.Count
                        AverageDuration = ($durations | Measure-Object -Average).Average
                        MinDuration = ($durations | Measure-Object -Minimum).Minimum
                        MaxDuration = ($durations | Measure-Object -Maximum).Maximum
                    }
                }

                return $results
            }

            $job = Start-Job -ScriptBlock $jobScript -ArgumentList @(
                $this.TestId,
                $operationType,
                $operation,
                $this.PerformanceConfig.ContentionIterations,
                $this.PerformanceConfig.IterationDelay,
                $p
            )
            $jobs += $job
        }

        # Wait for all jobs to complete
        Write-TestLog -Message "Waiting for $processCount contention processes to complete..." -Level "INFO" -TestId $this.TestId
        $completed = Wait-Job $jobs -Timeout $this.PerformanceConfig.TimeoutSeconds

        if ($completed.Count -ne $jobs.Count) {
            Write-TestLog -Message "Some contention processes timed out: $($completed.Count)/$($jobs.Count) completed" -Level "WARN" -TestId $this.TestId
        }

        # Collect results
        foreach ($job in $jobs) {
            try {
                $processResult = Receive-Job $job -ErrorAction Stop
                $measurements.ProcessResults += $processResult
                Write-TestLog -Message "Process $($processResult.ProcessIndex): Avg=$([math]::Round($processResult.Statistics.AverageDuration, 2))ms, Success=$($processResult.Statistics.SuccessRate * 100)%" -Level "INFO" -TestId $this.TestId
            }
            catch {
                Write-TestLog -Message "Failed to receive job result: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
            }
            Remove-Job $job -Force
        }

        # Calculate aggregate statistics
        $allSuccessfulIterations = $measurements.ProcessResults | ForEach-Object { $_.Iterations | Where-Object { $_.Success } }
        if ($allSuccessfulIterations.Count -gt 0) {
            $allDurations = $allSuccessfulIterations | ForEach-Object { $_.Duration }
            $measurements.AggregateStatistics = @{
                TotalSuccessfulIterations = $allSuccessfulIterations.Count
                TotalIterations = ($measurements.ProcessResults | ForEach-Object { $_.Iterations.Count } | Measure-Object -Sum).Sum
                OverallSuccessRate = $allSuccessfulIterations.Count / ($measurements.ProcessResults | ForEach-Object { $_.Iterations.Count } | Measure-Object -Sum).Sum
                AverageDuration = ($allDurations | Measure-Object -Average).Average
                MinDuration = ($allDurations | Measure-Object -Minimum).Minimum
                MaxDuration = ($allDurations | Measure-Object -Maximum).Maximum
                MedianDuration = $this.CalculateMedian($allDurations)
                StandardDeviation = $this.CalculateStandardDeviation($allDurations)
            }

            Write-TestLog -Message "Contention performance: Avg=$([math]::Round($measurements.AggregateStatistics.AverageDuration, 2))ms, Success=$([math]::Round($measurements.AggregateStatistics.OverallSuccessRate * 100, 1))%" -Level "INFO" -TestId $this.TestId
        }

        return $measurements
    }

    [hashtable] ComparePerformance([hashtable] $baseline, [hashtable] $contention) {
        $comparison = @{
            BaselineAverage = $baseline.Statistics.AverageDuration
            ContentionAverage = $contention.AggregateStatistics.AverageDuration
            PerformanceDegradation = 0.0
            DegradationPercentage = 0.0
            AcceptableDegradation = $this.PerformanceConfig.MaxAcceptableDegradation
            MeetsPerformanceCriteria = $false
            Summary = ""
        }

        if ($baseline.Statistics.AverageDuration -gt 0) {
            $comparison.PerformanceDegradation = ($contention.AggregateStatistics.AverageDuration - $baseline.Statistics.AverageDuration) / $baseline.Statistics.AverageDuration
            $comparison.DegradationPercentage = $comparison.PerformanceDegradation * 100
            $comparison.MeetsPerformanceCriteria = $comparison.PerformanceDegradation -le $this.PerformanceConfig.MaxAcceptableDegradation

            $comparison.Summary = if ($comparison.MeetsPerformanceCriteria) {
                "Performance meets criteria: $([math]::Round($comparison.DegradationPercentage, 1))% degradation (≤$([math]::Round($this.PerformanceConfig.MaxAcceptableDegradation * 100, 1))%)"
            } else {
                "Performance fails criteria: $([math]::Round($comparison.DegradationPercentage, 1))% degradation (>$([math]::Round($this.PerformanceConfig.MaxAcceptableDegradation * 100, 1))%)"
            }

            Write-TestLog -Message $comparison.Summary -Level $(if ($comparison.MeetsPerformanceCriteria) { "INFO" } else { "WARN" }) -TestId $this.TestId
        } else {
            $comparison.Summary = "Cannot compare performance: baseline average is zero"
            Write-TestLog -Message $comparison.Summary -Level "ERROR" -TestId $this.TestId
        }

        return $comparison
    }

    # Process management methods (similar to RecoveryTestBase)
    [object] CreateManagedProcess([string] $processName, [string] $command, [array] $arguments = @()) {
        $processInfo = @{
            Name = $processName
            Command = $command
            Arguments = $arguments
            Process = $null
            ProcessId = $null
            StartTime = $null
            IsRunning = $false
        }

        $this.ManagedProcesses += $processInfo
        Write-TestLog -Message "Created managed process: $processName" -Level "INFO" -TestId $this.TestId
        return $processInfo
    }

    [void] StartManagedProcess([object] $processInfo) {
        try {
            # Start process
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = $processInfo.Command
            $processStartInfo.Arguments = $processInfo.Arguments -join " "
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true
            $processStartInfo.RedirectStandardOutput = $true
            $processStartInfo.RedirectStandardError = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processStartInfo

            $success = $process.Start()
            if (-not $success) {
                throw "Failed to start process $($processInfo.Name)"
            }

            $processInfo.Process = $process
            $processInfo.ProcessId = $process.Id
            $processInfo.StartTime = Get-Date
            $processInfo.IsRunning = $true

            Write-TestLog -Message "Started managed process: $($processInfo.Name) (PID: $($process.Id))" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Failed to start managed process $($processInfo.Name): $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
            throw
        }
    }

    [void] TerminateManagedProcess([object] $processInfo) {
        try {
            if ($processInfo.Process -and -not $processInfo.Process.HasExited) {
                $processInfo.Process.Kill()
                $processInfo.Process.WaitForExit(2000)
            }
            $processInfo.IsRunning = $false
            Write-TestLog -Message "Terminated managed process: $($processInfo.Name)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Failed to terminate process $($processInfo.Name): $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
    }

    [void] TerminateAllManagedProcesses() {
        foreach ($processInfo in $this.ManagedProcesses) {
            if ($processInfo.IsRunning) {
                $this.TerminateManagedProcess($processInfo)
            }
        }
    }

    # File management methods
    [string] CreateTempFile([string] $fileName, [string] $content = "") {
        $filePath = Join-Path $this.TestTempDirectory $fileName

        try {
            Set-Content -Path $filePath -Value $content -Encoding UTF8
            $this.TempFiles += $filePath
            Write-TestLog -Message "Created temp file: $filePath" -Level "DEBUG" -TestId $this.TestId
            return $filePath
        }
        catch {
            Write-TestLog -Message "Failed to create temp file ${filePath}: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
            throw
        }
    }

    [void] CleanupTempFiles() {
        foreach ($filePath in $this.TempFiles) {
            try {
                if (Test-Path $filePath) {
                    Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-TestLog -Message "Failed to cleanup temp file ${filePath}" -Level "WARN" -TestId $this.TestId
            }
        }
    }

    # Utility methods
    [double] CalculateMedian([array] $values) {
        if ($values.Count -eq 0) { return 0.0 }
        $sorted = $values | Sort-Object
        $middle = [int]($sorted.Count / 2)
        if ($sorted.Count % 2 -eq 0) {
            return ($sorted[$middle - 1] + $sorted[$middle]) / 2
        } else {
            return $sorted[$middle]
        }
    }

    [double] CalculateStandardDeviation([array] $values) {
        if ($values.Count -lt 2) { return 0.0 }
        $mean = ($values | Measure-Object -Average).Average
        $squaredDifferences = $values | ForEach-Object { [math]::Pow($_ - $mean, 2) }
        $variance = ($squaredDifferences | Measure-Object -Average).Average
        return [math]::Sqrt($variance)
    }

    [hashtable] CalculateFairnessMetrics([array] $processResults) {
        $fairness = @{
            ProcessCount = $processResults.Count
            AverageThroughput = @()
            ThroughputVariance = 0.0
            ThroughputStandardDeviation = 0.0
            FairnessIndex = 0.0  # Jain's Fairness Index
            StarvationDetected = $false
            StarvationDetails = @()
        }

        if ($processResults.Count -eq 0) {
            return $fairness
        }

        # Calculate throughput for each process (successful operations per second)
        foreach ($processResult in $processResults) {
            if ($processResult.Statistics.SuccessfulIterations -gt 0) {
                $totalTime = ($processResult.Iterations | ForEach-Object { $_.Duration } | Measure-Object -Sum).Sum / 1000  # Convert to seconds
                $throughput = if ($totalTime -gt 0) { $processResult.Statistics.SuccessfulIterations / $totalTime } else { 0 }
                $fairness.AverageThroughput += $throughput
            } else {
                $fairness.AverageThroughput += 0
                $fairness.StarvationDetected = $true
                $fairness.StarvationDetails += "Process $($processResult.ProcessIndex) had no successful operations"
            }
        }

        # Calculate fairness metrics
        if ($fairness.AverageThroughput.Count -gt 0) {
            $mean = ($fairness.AverageThroughput | Measure-Object -Average).Average
            $fairness.ThroughputVariance = $this.CalculateStandardDeviation($fairness.AverageThroughput)
            $fairness.ThroughputStandardDeviation = [math]::Sqrt($fairness.ThroughputVariance)

            # Jain's Fairness Index: (sum of xi)^2 / (n * sum of xi^2)
            $sumThroughput = ($fairness.AverageThroughput | Measure-Object -Sum).Sum
            $sumSquaredThroughput = ($fairness.AverageThroughput | ForEach-Object { $_ * $_ } | Measure-Object -Sum).Sum

            if ($sumSquaredThroughput -gt 0) {
                $fairness.FairnessIndex = ($sumThroughput * $sumThroughput) / ($fairness.ProcessCount * $sumSquaredThroughput)
            }

            # Check for starvation (any process with significantly lower throughput)
            $threshold = $mean * 0.1  # 10% of average
            for ($i = 0; $i -lt $fairness.AverageThroughput.Count; $i++) {
                if ($fairness.AverageThroughput[$i] -lt $threshold) {
                    $fairness.StarvationDetected = $true
                    $fairness.StarvationDetails += "Process $i has low throughput: $([math]::Round($fairness.AverageThroughput[$i], 2)) (threshold: $([math]::Round($threshold, 2)))"
                }
            }
        }

        return $fairness
    }
}

Write-TestLog -Message "Performance test framework loaded successfully" -Level "INFO" -TestId "PERFORMANCE"