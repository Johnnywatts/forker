# Test Result Structures for Contention Testing Harness

class TestResult {
    [string] $TestId
    [string] $TestCategory
    [bool] $Success
    [string] $Message
    [hashtable] $Details
    [datetime] $StartTime
    [datetime] $EndTime
    [double] $DurationSeconds
    [hashtable] $Metrics

    TestResult([string] $testId, [string] $category) {
        $this.TestId = $testId
        $this.TestCategory = $category
        $this.Details = @{}
        $this.Metrics = @{}
        $this.StartTime = Get-Date
    }

    [void] Complete([bool] $success, [string] $message) {
        $this.Success = $success
        $this.Message = $message
        $this.EndTime = Get-Date
        $this.DurationSeconds = ($this.EndTime - $this.StartTime).TotalSeconds
    }

    [void] AddDetail([string] $key, [object] $value) {
        $this.Details[$key] = $value
    }

    [void] AddMetric([string] $key, [object] $value) {
        $this.Metrics[$key] = $value
    }

    [hashtable] ToHashtable() {
        return @{
            TestId = $this.TestId
            TestCategory = $this.TestCategory
            Success = $this.Success
            Message = $this.Message
            Details = $this.Details
            StartTime = $this.StartTime
            EndTime = $this.EndTime
            DurationSeconds = $this.DurationSeconds
            Metrics = $this.Metrics
        }
    }
}

class TestSuiteResult {
    [string] $SuiteName
    [bool] $Success
    [int] $TotalTests
    [int] $PassedTests
    [int] $FailedTests
    [TestResult[]] $TestResults
    [datetime] $StartTime
    [datetime] $EndTime
    [double] $DurationSeconds

    TestSuiteResult([string] $suiteName) {
        $this.SuiteName = $suiteName
        $this.TestResults = @()
        $this.StartTime = Get-Date
    }

    [void] AddTestResult([TestResult] $result) {
        $this.TestResults += $result
        $this.TotalTests = $this.TestResults.Count
        $this.PassedTests = ($this.TestResults | Where-Object { $_.Success }).Count
        $this.FailedTests = $this.TotalTests - $this.PassedTests
        $this.Success = ($this.FailedTests -eq 0)
    }

    [void] Complete() {
        $this.EndTime = Get-Date
        $this.DurationSeconds = ($this.EndTime - $this.StartTime).TotalSeconds
    }

    [hashtable] ToHashtable() {
        return @{
            SuiteName = $this.SuiteName
            Success = $this.Success
            TotalTests = $this.TotalTests
            PassedTests = $this.PassedTests
            FailedTests = $this.FailedTests
            TestResults = $this.TestResults | ForEach-Object { $_.ToHashtable() }
            StartTime = $this.StartTime
            EndTime = $this.EndTime
            DurationSeconds = $this.DurationSeconds
        }
    }
}

class ContentionHarnessResult {
    [string] $ExecutionId
    [bool] $Success
    [int] $TotalSuites
    [int] $TotalTests
    [int] $PassedTests
    [int] $FailedTests
    [TestSuiteResult[]] $SuiteResults
    [datetime] $StartTime
    [datetime] $EndTime
    [double] $DurationSeconds
    [hashtable] $SystemMetrics

    ContentionHarnessResult() {
        $this.ExecutionId = [System.Guid]::NewGuid().ToString()
        $this.SuiteResults = @()
        $this.SystemMetrics = @{}
        $this.StartTime = Get-Date
    }

    [void] AddSuiteResult([TestSuiteResult] $suiteResult) {
        $this.SuiteResults += $suiteResult
        $this.TotalSuites = $this.SuiteResults.Count
        $this.TotalTests = ($this.SuiteResults | Measure-Object -Property TotalTests -Sum).Sum
        $this.PassedTests = ($this.SuiteResults | Measure-Object -Property PassedTests -Sum).Sum
        $this.FailedTests = ($this.SuiteResults | Measure-Object -Property FailedTests -Sum).Sum
        $this.Success = ($this.FailedTests -eq 0)
    }

    [void] Complete() {
        $this.EndTime = Get-Date
        $this.DurationSeconds = ($this.EndTime - $this.StartTime).TotalSeconds
    }

    [void] AddSystemMetric([string] $key, [object] $value) {
        $this.SystemMetrics[$key] = $value
    }

    [hashtable] ToHashtable() {
        return @{
            ExecutionId = $this.ExecutionId
            Success = $this.Success
            TotalSuites = $this.TotalSuites
            TotalTests = $this.TotalTests
            PassedTests = $this.PassedTests
            FailedTests = $this.FailedTests
            SuiteResults = $this.SuiteResults | ForEach-Object { $_.ToHashtable() }
            StartTime = $this.StartTime
            EndTime = $this.EndTime
            DurationSeconds = $this.DurationSeconds
            SystemMetrics = $this.SystemMetrics
        }
    }
}