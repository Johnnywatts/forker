# TDA-001: Performance Impact Measurement Test
# Tests performance degradation under file contention scenarios

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")
. (Join-Path $PSScriptRoot ".." "suites" "PerformanceTests.ps1")

class PerformanceImpactTest : PerformanceTestBase {
    [hashtable] $TestScenarios
    [hashtable] $PerformanceResults

    PerformanceImpactTest() : base("TDA-001") {
        $this.TestScenarios = @{
            FileRead = @{}
            FileWrite = @{}
            FileCopy = @{}
            FileDelete = @{}
        }
        $this.PerformanceResults = @{}
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
            Write-TestLog -Message "Starting TDA-001 Performance Impact Measurement Test" -Level "INFO" -TestId $this.TestId

            # Setup test environment
            $this.SetupTest()

            # Phase 1: Baseline performance measurement
            Write-TestLog -Message "Phase 1: Measuring baseline performance" -Level "INFO" -TestId $this.TestId
            $baselineResult = $this.MeasureBaselinePerformance()
            $result.Details.Baseline = $baselineResult

            if (-not $baselineResult.Success) {
                throw "Failed to measure baseline performance: $($baselineResult.Error)"
            }

            # Phase 2: Contention performance measurement
            Write-TestLog -Message "Phase 2: Measuring performance under contention" -Level "INFO" -TestId $this.TestId
            $contentionResult = $this.MeasureContentionPerformance()
            $result.Details.Contention = $contentionResult

            if (-not $contentionResult.Success) {
                throw "Failed to measure contention performance: $($contentionResult.Error)"
            }

            # Phase 3: Performance impact analysis
            Write-TestLog -Message "Phase 3: Analyzing performance impact" -Level "INFO" -TestId $this.TestId
            $impactAnalysis = $this.AnalyzePerformanceImpact()
            $result.Details.ImpactAnalysis = $impactAnalysis
            $result.ValidationResults = $impactAnalysis

            # Phase 4: Regression detection
            Write-TestLog -Message "Phase 4: Performance regression detection" -Level "INFO" -TestId $this.TestId
            $regressionResult = $this.DetectPerformanceRegression()
            $result.Details.RegressionDetection = $regressionResult

            # Determine overall success
            $allPhasesSuccessful = $baselineResult.Success -and $contentionResult.Success -and
                                  $impactAnalysis.Success -and $regressionResult.Success

            if ($allPhasesSuccessful) {
                $result.Status = "Passed"
                Write-TestLog -Message "TDA-001 test completed successfully" -Level "INFO" -TestId $this.TestId
            } else {
                $failedPhases = @()
                if (-not $baselineResult.Success) { $failedPhases += "Baseline measurement" }
                if (-not $contentionResult.Success) { $failedPhases += "Contention measurement" }
                if (-not $impactAnalysis.Success) { $failedPhases += "Impact analysis" }
                if (-not $regressionResult.Success) { $failedPhases += "Regression detection" }

                throw "TDA-001 test failed in phases: $($failedPhases -join ', ')"
            }
        }
        catch {
            $result.Status = "Failed"
            $result.ErrorMessage = $_.Exception.Message
            Write-TestLog -Message "TDA-001 test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
        finally {
            $result.EndTime = Get-Date
            $this.CleanupTest()
        }

        return $result
    }

    [hashtable] MeasureBaselinePerformance() {
        $baseline = @{
            Success = $false
            Error = $null
            Operations = @{}
        }

        try {
            Write-TestLog -Message "Measuring baseline performance for file operations" -Level "INFO" -TestId $this.TestId

            # Create test files for baseline measurements
            $testContent = "A" * $this.PerformanceConfig.FileSize
            $baselineFile = $this.CreateTempFile("baseline-test.dat", $testContent)
            $copyTargetDir = Join-Path $this.TestTempDirectory "baseline-targets"
            New-Item -ItemType Directory -Path $copyTargetDir -Force | Out-Null

            # Test 1: File Read Performance
            Write-TestLog -Message "Measuring baseline file read performance" -Level "INFO" -TestId $this.TestId
            $readOperation = {
                Get-Content -Path $baselineFile -Raw | Out-Null
            }
            $baseline.Operations.FileRead = $this.MeasureBaselinePerformance("FileRead", $readOperation)

            # Test 2: File Write Performance
            Write-TestLog -Message "Measuring baseline file write performance" -Level "INFO" -TestId $this.TestId
            $writeOperation = {
                $writeFile = Join-Path $this.TestTempDirectory "baseline-write-$(Get-Random).dat"
                Set-Content -Path $writeFile -Value $testContent
                Remove-Item -Path $writeFile -Force -ErrorAction SilentlyContinue
            }
            $baseline.Operations.FileWrite = $this.MeasureBaselinePerformance("FileWrite", $writeOperation)

            # Test 3: File Copy Performance
            Write-TestLog -Message "Measuring baseline file copy performance" -Level "INFO" -TestId $this.TestId
            $copyOperation = {
                $copyTarget = Join-Path $copyTargetDir "baseline-copy-$(Get-Random).dat"
                Copy-Item -Path $baselineFile -Destination $copyTarget
                Remove-Item -Path $copyTarget -Force -ErrorAction SilentlyContinue
            }
            $baseline.Operations.FileCopy = $this.MeasureBaselinePerformance("FileCopy", $copyOperation)

            # Test 4: File Delete Performance
            Write-TestLog -Message "Measuring baseline file delete performance" -Level "INFO" -TestId $this.TestId
            $deleteOperation = {
                $deleteFile = Join-Path $this.TestTempDirectory "baseline-delete-$(Get-Random).dat"
                Set-Content -Path $deleteFile -Value $testContent
                Remove-Item -Path $deleteFile -Force
            }
            $baseline.Operations.FileDelete = $this.MeasureBaselinePerformance("FileDelete", $deleteOperation)

            $baseline.Success = $true
            Write-TestLog -Message "Baseline performance measurement completed successfully" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $baseline.Error = $_.Exception.Message
            Write-TestLog -Message "Baseline performance measurement failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $baseline
    }

    [hashtable] MeasureContentionPerformance() {
        $contention = @{
            Success = $false
            Error = $null
            Operations = @{}
        }

        try {
            Write-TestLog -Message "Measuring performance under contention for file operations" -Level "INFO" -TestId $this.TestId

            # Create shared test files for contention measurements
            $testContent = "B" * $this.PerformanceConfig.FileSize
            $sharedFile = $this.CreateTempFile("contention-shared.dat", $testContent)
            $contentionTargetDir = Join-Path $this.TestTempDirectory "contention-targets"
            New-Item -ItemType Directory -Path $contentionTargetDir -Force | Out-Null

            # Test 1: Concurrent File Read Performance
            Write-TestLog -Message "Measuring concurrent file read performance" -Level "INFO" -TestId $this.TestId
            $readOperation = {
                Get-Content -Path $sharedFile -Raw | Out-Null
            }
            $contention.Operations.FileRead = $this.MeasureContentionPerformance("FileRead", $readOperation, $this.PerformanceConfig.ProcessCount)

            # Test 2: Concurrent File Write Performance
            Write-TestLog -Message "Measuring concurrent file write performance" -Level "INFO" -TestId $this.TestId
            $writeOperation = {
                $writeFile = Join-Path $this.TestTempDirectory "contention-write-$(Get-Random).dat"
                Set-Content -Path $writeFile -Value $testContent
                Remove-Item -Path $writeFile -Force -ErrorAction SilentlyContinue
            }
            $contention.Operations.FileWrite = $this.MeasureContentionPerformance("FileWrite", $writeOperation, $this.PerformanceConfig.ProcessCount)

            # Test 3: Concurrent File Copy Performance
            Write-TestLog -Message "Measuring concurrent file copy performance" -Level "INFO" -TestId $this.TestId
            $copyOperation = {
                $copyTarget = Join-Path $contentionTargetDir "contention-copy-$(Get-Random).dat"
                Copy-Item -Path $sharedFile -Destination $copyTarget
                Remove-Item -Path $copyTarget -Force -ErrorAction SilentlyContinue
            }
            $contention.Operations.FileCopy = $this.MeasureContentionPerformance("FileCopy", $copyOperation, $this.PerformanceConfig.ProcessCount)

            # Test 4: Concurrent File Delete Performance
            Write-TestLog -Message "Measuring concurrent file delete performance" -Level "INFO" -TestId $this.TestId
            $deleteOperation = {
                $deleteFile = Join-Path $this.TestTempDirectory "contention-delete-$(Get-Random).dat"
                Set-Content -Path $deleteFile -Value $testContent
                Remove-Item -Path $deleteFile -Force
            }
            $contention.Operations.FileDelete = $this.MeasureContentionPerformance("FileDelete", $deleteOperation, $this.PerformanceConfig.ProcessCount)

            $contention.Success = $true
            Write-TestLog -Message "Contention performance measurement completed successfully" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $contention.Error = $_.Exception.Message
            Write-TestLog -Message "Contention performance measurement failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $contention
    }

    [hashtable] AnalyzePerformanceImpact() {
        $analysis = @{
            Success = $false
            Error = $null
            OperationAnalysis = @{}
            OverallImpact = @{}
            MeetsPerformanceCriteria = $false
            Summary = ""
        }

        try {
            Write-TestLog -Message "Analyzing performance impact across operations" -Level "INFO" -TestId $this.TestId

            # Analyze impact for each operation type
            $operationTypes = @("FileRead", "FileWrite", "FileCopy", "FileDelete")
            $allOperationsMeetCriteria = $true
            $totalDegradation = 0.0

            foreach ($opType in $operationTypes) {
                $baselineOp = $this.PerformanceResults.Baseline.Operations[$opType]
                $contentionOp = $this.PerformanceResults.Contention.Operations[$opType]

                if ($baselineOp -and $contentionOp) {
                    $comparison = $this.ComparePerformance($baselineOp, $contentionOp)
                    $analysis.OperationAnalysis[$opType] = $comparison

                    if (-not $comparison.MeetsPerformanceCriteria) {
                        $allOperationsMeetCriteria = $false
                    }

                    $totalDegradation += $comparison.PerformanceDegradation
                    Write-TestLog -Message "$opType performance impact: $($comparison.Summary)" -Level "INFO" -TestId $this.TestId
                } else {
                    Write-TestLog -Message "Missing performance data for $opType" -Level "WARN" -TestId $this.TestId
                    $allOperationsMeetCriteria = $false
                }
            }

            # Calculate overall impact
            $averageDegradation = $totalDegradation / $operationTypes.Count
            $analysis.OverallImpact = @{
                AverageDegradation = $averageDegradation
                AverageDegradationPercentage = $averageDegradation * 100
                MeetsOverallCriteria = $averageDegradation -le $this.PerformanceConfig.MaxAcceptableDegradation
                WorstCaseOperation = ""
                WorstCaseDegradation = 0.0
            }

            # Find worst-case performance degradation
            $worstDegradation = 0.0
            $worstOperation = ""
            foreach ($opType in $operationTypes) {
                if ($analysis.OperationAnalysis.ContainsKey($opType)) {
                    $degradation = $analysis.OperationAnalysis[$opType].PerformanceDegradation
                    if ($degradation -gt $worstDegradation) {
                        $worstDegradation = $degradation
                        $worstOperation = $opType
                    }
                }
            }

            $analysis.OverallImpact.WorstCaseOperation = $worstOperation
            $analysis.OverallImpact.WorstCaseDegradation = $worstDegradation

            # Determine overall success
            $analysis.MeetsPerformanceCriteria = $allOperationsMeetCriteria -and $analysis.OverallImpact.MeetsOverallCriteria

            if ($analysis.MeetsPerformanceCriteria) {
                $analysis.Summary = "Performance impact meets all criteria: Average $([math]::Round($analysis.OverallImpact.AverageDegradationPercentage, 1))% degradation, Worst case: $worstOperation ($([math]::Round($worstDegradation * 100, 1))%)"
                Write-TestLog -Message "Performance impact analysis: PASSED - $($analysis.Summary)" -Level "INFO" -TestId $this.TestId
            } else {
                $failedOps = @()
                foreach ($opType in $operationTypes) {
                    if ($analysis.OperationAnalysis.ContainsKey($opType) -and -not $analysis.OperationAnalysis[$opType].MeetsPerformanceCriteria) {
                        $failedOps += "$opType ($([math]::Round($analysis.OperationAnalysis[$opType].DegradationPercentage, 1))%)"
                    }
                }

                $analysis.Summary = "Performance impact exceeds criteria: Failed operations: $($failedOps -join ', ')"
                Write-TestLog -Message "Performance impact analysis: FAILED - $($analysis.Summary)" -Level "ERROR" -TestId $this.TestId
            }

            $analysis.Success = $true
        }
        catch {
            $analysis.Error = $_.Exception.Message
            $analysis.Summary = "Performance impact analysis error: $($_.Exception.Message)"
            Write-TestLog -Message "Performance impact analysis failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $analysis
    }

    [hashtable] DetectPerformanceRegression() {
        $regression = @{
            Success = $false
            Error = $null
            RegressionDetected = $false
            RegressionDetails = @()
            PerformanceHistory = @{}
            Recommendations = @()
        }

        try {
            Write-TestLog -Message "Detecting performance regressions" -Level "INFO" -TestId $this.TestId

            # Check for obvious performance regressions
            $operationTypes = @("FileRead", "FileWrite", "FileCopy", "FileDelete")

            foreach ($opType in $operationTypes) {
                if ($this.PerformanceResults.Baseline.Operations.ContainsKey($opType) -and
                    $this.PerformanceResults.Contention.Operations.ContainsKey($opType)) {

                    $baseline = $this.PerformanceResults.Baseline.Operations[$opType]
                    $contention = $this.PerformanceResults.Contention.Operations[$opType]

                    # Check for extreme degradation (>50%)
                    if ($baseline.Statistics.AverageDuration -gt 0) {
                        $degradation = ($contention.AggregateStatistics.AverageDuration - $baseline.Statistics.AverageDuration) / $baseline.Statistics.AverageDuration

                        if ($degradation -gt 0.5) {  # 50% degradation threshold
                            $regression.RegressionDetected = $true
                            $regression.RegressionDetails += "Severe performance regression in $opType: $([math]::Round($degradation * 100, 1))% degradation"
                        }

                        # Check for high variance indicating instability
                        if ($contention.AggregateStatistics.StandardDeviation -gt ($contention.AggregateStatistics.AverageDuration * 0.3)) {
                            $regression.RegressionDetected = $true
                            $regression.RegressionDetails += "Performance instability in $opType: High variance (CV = $([math]::Round(($contention.AggregateStatistics.StandardDeviation / $contention.AggregateStatistics.AverageDuration) * 100, 1))%)"
                        }
                    }
                }
            }

            # Generate recommendations based on findings
            if ($regression.RegressionDetected) {
                $regression.Recommendations += "Investigate file I/O bottlenecks and contention hotspots"
                $regression.Recommendations += "Consider implementing file operation queuing or throttling"
                $regression.Recommendations += "Review file locking strategies and granularity"
                $regression.Recommendations += "Monitor system resource utilization during contention"
            } else {
                $regression.Recommendations += "Performance is within acceptable ranges"
                $regression.Recommendations += "Continue monitoring for gradual degradation trends"
                $regression.Recommendations += "Consider establishing performance baselines for production workloads"
            }

            # Save performance history for future comparisons
            $regression.PerformanceHistory = @{
                Timestamp = Get-Date
                TestId = $this.TestId
                BaselineMetrics = $this.PerformanceResults.Baseline
                ContentionMetrics = $this.PerformanceResults.Contention
                OverallDegradation = if ($this.PerformanceResults.ImpactAnalysis) { $this.PerformanceResults.ImpactAnalysis.OverallImpact.AverageDegradation } else { 0.0 }
            }

            $regression.Success = $true

            if ($regression.RegressionDetected) {
                Write-TestLog -Message "Performance regression detected: $($regression.RegressionDetails.Count) issues found" -Level "WARN" -TestId $this.TestId
                foreach ($detail in $regression.RegressionDetails) {
                    Write-TestLog -Message "Regression: $detail" -Level "WARN" -TestId $this.TestId
                }
            } else {
                Write-TestLog -Message "No significant performance regressions detected" -Level "INFO" -TestId $this.TestId
            }
        }
        catch {
            $regression.Error = $_.Exception.Message
            Write-TestLog -Message "Performance regression detection failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $regression
    }
}

# Factory function for creating TDA-001 test
function New-PerformanceImpactTest {
    return [PerformanceImpactTest]::new()
}

Write-TestLog -Message "TDA-001 Performance Impact Test loaded successfully" -Level "INFO" -TestId "TDA-001"