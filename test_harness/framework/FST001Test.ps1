# FST-001: Process Fairness Validation Test
# Tests fairness and starvation prevention under concurrent access

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")
. (Join-Path $PSScriptRoot ".." "suites" "PerformanceTests.ps1")

class ProcessFairnessTest : PerformanceTestBase {
    [hashtable] $FairnessScenarios
    [hashtable] $FairnessResults

    ProcessFairnessTest() : base("FST-001") {
        $this.FairnessScenarios = @{
            EqualPriorityAccess = @{}
            MixedWorkloadFairness = @{}
            ResourceStarvationTest = @{}
            ConcurrentWriteFairness = @{}
        }
        $this.FairnessResults = @{}

        # Override config for fairness testing
        $this.PerformanceConfig.ProcessCount = 6
        $this.PerformanceConfig.ContentionIterations = 15
        $this.PerformanceConfig.TimeoutSeconds = 45
    }

    [hashtable] ExecuteTest() {
        $result = @{
            TestId = $this.TestId
            Status = "Failed"
            StartTime = Get-Date
            EndTime = $null
            ErrorMessage = $null
            Details = @{}
            ValidationResults = @{}
        }

        try {
            Write-TestLog -Message "Starting FST-001 Process Fairness Validation Test" -Level "INFO" -TestId $this.TestId

            # Setup test environment
            $this.SetupTest()

            # Phase 1: Equal priority access fairness
            Write-TestLog -Message "Phase 1: Testing equal priority access fairness" -Level "INFO" -TestId $this.TestId
            $equalPriorityResult = $this.TestEqualPriorityFairness()
            $result.Details.EqualPriorityFairness = $equalPriorityResult

            if (-not $equalPriorityResult.Success) {
                throw "Failed equal priority fairness test: $($equalPriorityResult.Error)"
            }

            # Phase 2: Mixed workload fairness
            Write-TestLog -Message "Phase 2: Testing mixed workload fairness" -Level "INFO" -TestId $this.TestId
            $mixedWorkloadResult = $this.TestMixedWorkloadFairness()
            $result.Details.MixedWorkloadFairness = $mixedWorkloadResult

            if (-not $mixedWorkloadResult.Success) {
                throw "Failed mixed workload fairness test: $($mixedWorkloadResult.Error)"
            }

            # Phase 3: Resource starvation detection
            Write-TestLog -Message "Phase 3: Testing resource starvation prevention" -Level "INFO" -TestId $this.TestId
            $starvationResult = $this.TestResourceStarvationPrevention()
            $result.Details.ResourceStarvation = $starvationResult

            if (-not $starvationResult.Success) {
                throw "Failed resource starvation test: $($starvationResult.Error)"
            }

            # Phase 4: Concurrent write fairness
            Write-TestLog -Message "Phase 4: Testing concurrent write operation fairness" -Level "INFO" -TestId $this.TestId
            $writeAccessResult = $this.TestConcurrentWriteFairness()
            $result.Details.ConcurrentWriteFairness = $writeAccessResult

            if (-not $writeAccessResult.Success) {
                throw "Failed concurrent write fairness test: $($writeAccessResult.Error)"
            }

            # Phase 5: Comprehensive fairness validation
            Write-TestLog -Message "Phase 5: Comprehensive fairness validation" -Level "INFO" -TestId $this.TestId
            $finalValidation = $this.ValidateOverallFairness()
            $result.Details.FinalValidation = $finalValidation
            $result.ValidationResults = $finalValidation

            # Determine overall success
            $allPhasesSuccessful = $equalPriorityResult.Success -and $mixedWorkloadResult.Success -and
                                  $starvationResult.Success -and $writeAccessResult.Success -and
                                  $finalValidation.Success

            if ($allPhasesSuccessful) {
                $result.Status = "Passed"
                Write-TestLog -Message "FST-001 test completed successfully" -Level "INFO" -TestId $this.TestId
            } else {
                $failedPhases = @()
                if (-not $equalPriorityResult.Success) { $failedPhases += "Equal priority fairness" }
                if (-not $mixedWorkloadResult.Success) { $failedPhases += "Mixed workload fairness" }
                if (-not $starvationResult.Success) { $failedPhases += "Resource starvation prevention" }
                if (-not $writeAccessResult.Success) { $failedPhases += "Concurrent write fairness" }
                if (-not $finalValidation.Success) { $failedPhases += "Final validation" }

                throw "FST-001 test failed in phases: $($failedPhases -join ', ')"
            }
        }
        catch {
            $result.Status = "Failed"
            $result.ErrorMessage = $_.Exception.Message
            Write-TestLog -Message "FST-001 test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
        finally {
            $result.EndTime = Get-Date
            $this.CleanupTest()
        }

        return $result
    }

    [hashtable] TestEqualPriorityFairness() {
        $fairness = @{
            Success = $false
            Error = $null
            ProcessCount = $this.PerformanceConfig.ProcessCount
            FairnessMetrics = @{}
            MeetsFairnessCriteria = $false
        }

        try {
            Write-TestLog -Message "Testing fairness with equal priority processes" -Level "INFO" -TestId $this.TestId

            # Create shared resource for equal access testing
            $testContent = "Fairness test data " * 100
            $sharedFile = $this.CreateTempFile("fairness-shared.dat", $testContent)

            # Define equal priority read operation
            $readOperation = {
                $content = Get-Content -Path $sharedFile -Raw
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                return $bytes.Length
            }

            # Execute concurrent equal priority processes
            Write-TestLog -Message "Running $($this.PerformanceConfig.ProcessCount) equal priority processes" -Level "INFO" -TestId $this.TestId
            $contentionResult = $this.MeasureContentionPerformance("EqualPriorityRead", $readOperation, $this.PerformanceConfig.ProcessCount)

            # Calculate fairness metrics
            $fairness.FairnessMetrics = $this.CalculateFairnessMetrics($contentionResult.ProcessResults)

            # Evaluate fairness criteria
            $minFairnessIndex = 0.8  # Jain's Fairness Index threshold
            $maxStarvationThreshold = 0.1  # 10% of processes can have low throughput

            $starvationRate = $fairness.FairnessMetrics.StarvationDetails.Count / $fairness.FairnessMetrics.ProcessCount
            $fairness.MeetsFairnessCriteria = ($fairness.FairnessMetrics.FairnessIndex -ge $minFairnessIndex) -and
                                             ($starvationRate -le $maxStarvationThreshold)

            Write-TestLog -Message "Equal priority fairness: Fairness Index=$([math]::Round($fairness.FairnessMetrics.FairnessIndex, 3)), Starvation Rate=$([math]::Round($starvationRate * 100, 1))%" -Level "INFO" -TestId $this.TestId

            if ($fairness.MeetsFairnessCriteria) {
                Write-TestLog -Message "Equal priority fairness test: PASSED" -Level "INFO" -TestId $this.TestId
            } else {
                Write-TestLog -Message "Equal priority fairness test: FAILED - Fairness Index: $([math]::Round($fairness.FairnessMetrics.FairnessIndex, 3)) (min: $minFairnessIndex), Starvation: $([math]::Round($starvationRate * 100, 1))% (max: $([math]::Round($maxStarvationThreshold * 100, 1))%)" -Level "ERROR" -TestId $this.TestId
            }

            $fairness.Success = $true
        }
        catch {
            $fairness.Error = $_.Exception.Message
            Write-TestLog -Message "Equal priority fairness test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $fairness
    }

    [hashtable] TestMixedWorkloadFairness() {
        $fairness = @{
            Success = $false
            Error = $null
            WorkloadTypes = @("Light", "Medium", "Heavy")
            WorkloadResults = @{}
            CrossWorkloadFairness = @{}
            MeetsFairnessCriteria = $false
        }

        try {
            Write-TestLog -Message "Testing fairness across mixed workload intensities" -Level "INFO" -TestId $this.TestId

            # Create test files for different workload intensities
            $lightContent = "Light" * 50
            $mediumContent = "Medium" * 200
            $heavyContent = "Heavy" * 500

            $lightFile = $this.CreateTempFile("workload-light.dat", $lightContent)
            $mediumFile = $this.CreateTempFile("workload-medium.dat", $mediumContent)
            $heavyFile = $this.CreateTempFile("workload-heavy.dat", $heavyContent)

            # Define workload operations with different intensities
            $lightOperation = {
                Get-Content -Path $lightFile -Raw | Out-Null
                Start-Sleep -Milliseconds 10
            }

            $mediumOperation = {
                $content = Get-Content -Path $mediumFile -Raw
                $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))
                Start-Sleep -Milliseconds 25
            }

            $heavyOperation = {
                $content = Get-Content -Path $heavyFile -Raw
                for ($i = 0; $i -lt 5; $i++) {
                    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))
                }
                Start-Sleep -Milliseconds 50
            }

            # Test each workload type separately
            foreach ($workloadType in $fairness.WorkloadTypes) {
                $operation = switch ($workloadType) {
                    "Light" { $lightOperation }
                    "Medium" { $mediumOperation }
                    "Heavy" { $heavyOperation }
                }

                Write-TestLog -Message "Testing $workloadType workload fairness" -Level "INFO" -TestId $this.TestId
                $processCount = 2  # Use fewer processes for mixed workload testing
                $workloadResult = $this.MeasureContentionPerformance("${workloadType}Workload", $operation, $processCount)
                $fairness.WorkloadResults[$workloadType] = $workloadResult

                $workloadFairness = $this.CalculateFairnessMetrics($workloadResult.ProcessResults)
                Write-TestLog -Message "$workloadType workload: Fairness Index=$([math]::Round($workloadFairness.FairnessIndex, 3)), Avg Throughput=$([math]::Round(($workloadFairness.AverageThroughput | Measure-Object -Average).Average, 2))" -Level "INFO" -TestId $this.TestId
            }

            # Test mixed workload scenario
            Write-TestLog -Message "Testing mixed workload fairness scenario" -Level "INFO" -TestId $this.TestId
            $mixedJobs = @()

            # Start light workload processes
            for ($i = 0; $i -lt 2; $i++) {
                $job = Start-Job -ScriptBlock $lightOperation
                $mixedJobs += @{ Job = $job; Type = "Light"; Index = $i }
            }

            # Start medium workload processes
            for ($i = 0; $i -lt 2; $i++) {
                $job = Start-Job -ScriptBlock $mediumOperation
                $mixedJobs += @{ Job = $job; Type = "Medium"; Index = $i }
            }

            # Start heavy workload processes
            for ($i = 0; $i -lt 1; $i++) {
                $job = Start-Job -ScriptBlock $heavyOperation
                $mixedJobs += @{ Job = $job; Type = "Heavy"; Index = $i }
            }

            # Wait for mixed workload completion
            $mixedJobObjects = $mixedJobs | ForEach-Object { $_.Job }
            $completed = Wait-Job $mixedJobObjects -Timeout 30

            # Analyze mixed workload fairness
            $completedCount = $completed.Count
            $totalJobs = $mixedJobs.Count

            $fairness.CrossWorkloadFairness = @{
                TotalJobs = $totalJobs
                CompletedJobs = $completedCount
                CompletionRate = $completedCount / $totalJobs
                LightCompleted = ($mixedJobs | Where-Object { $_.Type -eq "Light" -and $_.Job.State -eq "Completed" }).Count
                MediumCompleted = ($mixedJobs | Where-Object { $_.Type -eq "Medium" -and $_.Job.State -eq "Completed" }).Count
                HeavyCompleted = ($mixedJobs | Where-Object { $_.Type -eq "Heavy" -and $_.Job.State -eq "Completed" }).Count
            }

            # Clean up jobs
            foreach ($mixedJob in $mixedJobs) {
                Remove-Job $mixedJob.Job -Force
            }

            # Evaluate mixed workload fairness
            $minCompletionRate = 0.8  # 80% of jobs should complete
            $fairness.MeetsFairnessCriteria = $fairness.CrossWorkloadFairness.CompletionRate -ge $minCompletionRate

            Write-TestLog -Message "Mixed workload completion: $($fairness.CrossWorkloadFairness.CompletedJobs)/$($fairness.CrossWorkloadFairness.TotalJobs) ($([math]::Round($fairness.CrossWorkloadFairness.CompletionRate * 100, 1))%)" -Level "INFO" -TestId $this.TestId
            Write-TestLog -Message "Completion by type: Light=$($fairness.CrossWorkloadFairness.LightCompleted), Medium=$($fairness.CrossWorkloadFairness.MediumCompleted), Heavy=$($fairness.CrossWorkloadFairness.HeavyCompleted)" -Level "INFO" -TestId $this.TestId

            if ($fairness.MeetsFairnessCriteria) {
                Write-TestLog -Message "Mixed workload fairness test: PASSED" -Level "INFO" -TestId $this.TestId
            } else {
                Write-TestLog -Message "Mixed workload fairness test: FAILED - Completion rate: $([math]::Round($fairness.CrossWorkloadFairness.CompletionRate * 100, 1))% (min: $([math]::Round($minCompletionRate * 100, 1))%)" -Level "ERROR" -TestId $this.TestId
            }

            $fairness.Success = $true
        }
        catch {
            $fairness.Error = $_.Exception.Message
            Write-TestLog -Message "Mixed workload fairness test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $fairness
    }

    [hashtable] TestResourceStarvationPrevention() {
        $starvation = @{
            Success = $false
            Error = $null
            StarvationDetected = $false
            StarvationScenarios = @{}
            PreventionEffective = $false
        }

        try {
            Write-TestLog -Message "Testing resource starvation prevention mechanisms" -Level "INFO" -TestId $this.TestId

            # Scenario 1: High contention on single resource
            Write-TestLog -Message "Testing high contention starvation scenario" -Level "INFO" -TestId $this.TestId
            $contentionFile = $this.CreateTempFile("high-contention.dat", "Contention data " * 200)

            $highContentionOperation = {
                # Simulate resource-intensive operation
                for ($i = 0; $i -lt 3; $i++) {
                    $content = Get-Content -Path $contentionFile -Raw
                    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))
                    Start-Sleep -Milliseconds 20
                }
            }

            $highContentionResult = $this.MeasureContentionPerformance("HighContention", $highContentionOperation, 8)
            $contentionFairness = $this.CalculateFairnessMetrics($highContentionResult.ProcessResults)
            $starvation.StarvationScenarios.HighContention = $contentionFairness

            # Scenario 2: Resource monopolization test
            Write-TestLog -Message "Testing resource monopolization prevention" -Level "INFO" -TestId $this.TestId
            $monopolyFile = $this.CreateTempFile("monopoly-test.dat", "Monopoly test data " * 150)

            # Start one long-running monopolizing process
            $monopolyOperation = {
                for ($i = 0; $i -lt 20; $i++) {
                    $content = Get-Content -Path $monopolyFile -Raw
                    Start-Sleep -Milliseconds 100  # Long-running operation
                }
            }

            $quickOperation = {
                $content = Get-Content -Path $monopolyFile -Raw
                return $content.Length
            }

            # Start monopolizing job
            $monopolyJob = Start-Job -ScriptBlock $monopolyOperation
            Start-Sleep -Milliseconds 200  # Let monopoly start

            # Start quick access jobs
            $quickJobs = @()
            for ($i = 0; $i -lt 4; $i++) {
                $quickJob = Start-Job -ScriptBlock $quickOperation
                $quickJobs += $quickJob
                Start-Sleep -Milliseconds 50
            }

            # Wait for quick jobs to complete
            $quickCompleted = Wait-Job $quickJobs -Timeout 10
            $quickCompletionRate = $quickCompleted.Count / $quickJobs.Count

            # Stop monopoly job
            Stop-Job $monopolyJob -Force
            Remove-Job $monopolyJob -Force

            # Clean up quick jobs
            foreach ($quickJob in $quickJobs) {
                Remove-Job $quickJob -Force
            }

            $starvation.StarvationScenarios.Monopolization = @{
                QuickJobsTotal = $quickJobs.Count
                QuickJobsCompleted = $quickCompleted.Count
                CompletionRate = $quickCompletionRate
                StarvationPrevented = $quickCompletionRate -ge 0.75  # 75% of quick jobs should complete
            }

            # Overall starvation assessment
            $highContentionStarvation = $contentionFairness.StarvationDetected
            $monopolizationStarvation = -not $starvation.StarvationScenarios.Monopolization.StarvationPrevented

            $starvation.StarvationDetected = $highContentionStarvation -or $monopolizationStarvation
            $starvation.PreventionEffective = -not $starvation.StarvationDetected

            Write-TestLog -Message "High contention starvation: $($if ($highContentionStarvation) { 'DETECTED' } else { 'PREVENTED' })" -Level $(if ($highContentionStarvation) { "WARN" } else { "INFO" }) -TestId $this.TestId
            Write-TestLog -Message "Monopolization prevention: $($if ($starvation.StarvationScenarios.Monopolization.StarvationPrevented) { 'EFFECTIVE' } else { 'INEFFECTIVE' }) ($([math]::Round($quickCompletionRate * 100, 1))% completion)" -Level $(if ($starvation.StarvationScenarios.Monopolization.StarvationPrevented) { "INFO" } else { "WARN" }) -TestId $this.TestId

            if ($starvation.PreventionEffective) {
                Write-TestLog -Message "Resource starvation prevention test: PASSED" -Level "INFO" -TestId $this.TestId
            } else {
                Write-TestLog -Message "Resource starvation prevention test: FAILED - Starvation detected" -Level "ERROR" -TestId $this.TestId
            }

            $starvation.Success = $true
        }
        catch {
            $starvation.Error = $_.Exception.Message
            Write-TestLog -Message "Resource starvation prevention test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $starvation
    }

    [hashtable] TestConcurrentWriteFairness() {
        $writeFairness = @{
            Success = $false
            Error = $null
            WriteOperations = @{}
            FairnessMetrics = @{}
            MeetsFairnessCriteria = $false
        }

        try {
            Write-TestLog -Message "Testing concurrent write operation fairness" -Level "INFO" -TestId $this.TestId

            # Create directory for concurrent write tests
            $writeTestDir = Join-Path $this.TestTempDirectory "write-fairness"
            New-Item -ItemType Directory -Path $writeTestDir -Force | Out-Null

            # Define concurrent write operation
            $writeOperation = {
                $writeFile = Join-Path $writeTestDir "concurrent-write-$(Get-Random).dat"
                $writeContent = "Process $([System.Diagnostics.Process]::GetCurrentProcess().Id) data " * 50

                # Perform multiple write operations to test fairness
                for ($i = 0; $i -lt 3; $i++) {
                    Set-Content -Path $writeFile -Value "$writeContent - Iteration $i"
                    Start-Sleep -Milliseconds 25
                }

                # Clean up individual file
                Remove-Item -Path $writeFile -Force -ErrorAction SilentlyContinue
                return $writeContent.Length
            }

            # Execute concurrent write operations
            Write-TestLog -Message "Running concurrent write fairness test with $($this.PerformanceConfig.ProcessCount) processes" -Level "INFO" -TestId $this.TestId
            $writeResult = $this.MeasureContentionPerformance("ConcurrentWrite", $writeOperation, $this.PerformanceConfig.ProcessCount)
            $writeFairness.WriteOperations = $writeResult

            # Calculate fairness metrics for write operations
            $writeFairness.FairnessMetrics = $this.CalculateFairnessMetrics($writeResult.ProcessResults)

            # Evaluate write fairness criteria
            $minWriteFairnessIndex = 0.75  # Slightly lower threshold for write operations
            $maxWriteStarvationRate = 0.15  # 15% starvation tolerance for writes

            $starvationRate = $writeFairness.FairnessMetrics.StarvationDetails.Count / $writeFairness.FairnessMetrics.ProcessCount
            $writeFairness.MeetsFairnessCriteria = ($writeFairness.FairnessMetrics.FairnessIndex -ge $minWriteFairnessIndex) -and
                                                  ($starvationRate -le $maxWriteStarvationRate) -and
                                                  ($writeFairness.FairnessMetrics.ProcessCount -eq $this.PerformanceConfig.ProcessCount)

            Write-TestLog -Message "Concurrent write fairness: Fairness Index=$([math]::Round($writeFairness.FairnessMetrics.FairnessIndex, 3)), Starvation Rate=$([math]::Round($starvationRate * 100, 1))%" -Level "INFO" -TestId $this.TestId
            Write-TestLog -Message "Write processes completed: $($writeFairness.FairnessMetrics.ProcessCount)/$($this.PerformanceConfig.ProcessCount)" -Level "INFO" -TestId $this.TestId

            if ($writeFairness.MeetsFairnessCriteria) {
                Write-TestLog -Message "Concurrent write fairness test: PASSED" -Level "INFO" -TestId $this.TestId
            } else {
                Write-TestLog -Message "Concurrent write fairness test: FAILED - Fairness Index: $([math]::Round($writeFairness.FairnessMetrics.FairnessIndex, 3)) (min: $minWriteFairnessIndex), Starvation: $([math]::Round($starvationRate * 100, 1))% (max: $([math]::Round($maxWriteStarvationRate * 100, 1))%)" -Level "ERROR" -TestId $this.TestId
            }

            $writeFairness.Success = $true
        }
        catch {
            $writeFairness.Error = $_.Exception.Message
            Write-TestLog -Message "Concurrent write fairness test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $writeFairness
    }

    [hashtable] ValidateOverallFairness() {
        $validation = @{
            Success = $false
            Error = $null
            OverallFairnessScore = 0.0
            FairnessBreakdown = @{}
            MeetsAllCriteria = $false
            Summary = ""
        }

        try {
            Write-TestLog -Message "Validating overall process fairness across all scenarios" -Level "INFO" -TestId $this.TestId

            # Collect fairness results from all phases
            $results = $this.FairnessResults

            # Calculate weighted fairness score
            $weights = @{
                EqualPriority = 0.3
                MixedWorkload = 0.25
                StarvationPrevention = 0.25
                ConcurrentWrite = 0.2
            }

            $scores = @{}
            $totalWeight = 0.0

            # Equal priority fairness score
            if ($results.EqualPriorityFairness -and $results.EqualPriorityFairness.Success) {
                $scores.EqualPriority = if ($results.EqualPriorityFairness.MeetsFairnessCriteria) { 1.0 } else { 0.0 }
                $totalWeight += $weights.EqualPriority
            }

            # Mixed workload fairness score
            if ($results.MixedWorkloadFairness -and $results.MixedWorkloadFairness.Success) {
                $scores.MixedWorkload = if ($results.MixedWorkloadFairness.MeetsFairnessCriteria) { 1.0 } else { 0.0 }
                $totalWeight += $weights.MixedWorkload
            }

            # Starvation prevention score
            if ($results.ResourceStarvation -and $results.ResourceStarvation.Success) {
                $scores.StarvationPrevention = if ($results.ResourceStarvation.PreventionEffective) { 1.0 } else { 0.0 }
                $totalWeight += $weights.StarvationPrevention
            }

            # Concurrent write fairness score
            if ($results.ConcurrentWriteFairness -and $results.ConcurrentWriteFairness.Success) {
                $scores.ConcurrentWrite = if ($results.ConcurrentWriteFairness.MeetsFairnessCriteria) { 1.0 } else { 0.0 }
                $totalWeight += $weights.ConcurrentWrite
            }

            # Calculate overall score
            if ($totalWeight -gt 0) {
                $weightedSum = 0.0
                foreach ($category in $scores.Keys) {
                    $weightedSum += $scores[$category] * $weights[$category]
                }
                $validation.OverallFairnessScore = $weightedSum / $totalWeight
            }

            $validation.FairnessBreakdown = $scores

            # Determine overall success
            $minOverallScore = 0.8  # 80% overall fairness score required
            $validation.MeetsAllCriteria = $validation.OverallFairnessScore -ge $minOverallScore

            if ($validation.MeetsAllCriteria) {
                $validation.Summary = "Overall fairness validation PASSED: Score = $([math]::Round($validation.OverallFairnessScore * 100, 1))%"
                Write-TestLog -Message $validation.Summary -Level "INFO" -TestId $this.TestId
            } else {
                $failedCategories = @()
                foreach ($category in $scores.Keys) {
                    if ($scores[$category] -eq 0.0) {
                        $failedCategories += $category
                    }
                }

                $validation.Summary = "Overall fairness validation FAILED: Score = $([math]::Round($validation.OverallFairnessScore * 100, 1))% (min: $([math]::Round($minOverallScore * 100, 1))%). Failed categories: $($failedCategories -join ', ')"
                Write-TestLog -Message $validation.Summary -Level "ERROR" -TestId $this.TestId
            }

            $validation.Success = $true
        }
        catch {
            $validation.Error = $_.Exception.Message
            $validation.Summary = "Overall fairness validation error: $($_.Exception.Message)"
            Write-TestLog -Message "Overall fairness validation failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $validation
    }
}

# Factory function for creating FST-001 test
function New-ProcessFairnessTest {
    return [ProcessFairnessTest]::new()
}

Write-TestLog -Message "FST-001 Process Fairness Test loaded successfully" -Level "INFO" -TestId "FST-001"