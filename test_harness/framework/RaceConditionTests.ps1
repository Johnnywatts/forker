# Race Condition Test Framework for Multi-Process Contention Testing

# Base class for race condition contention tests
class RaceConditionTestCase : IsolatedContentionTestCase {
    [object] $ProcessCoordinator  # ProcessCoordinator instance
    [object] $SharedState        # SharedStateManager instance
    [string] $TestDataSize
    [hashtable] $ConcurrentResults

    RaceConditionTestCase([string] $testId, [string] $description) : base($testId, "RaceConditions", $description) {
        $this.TestDataSize = "1MB"  # Default test data size
        $this.ProcessCoordinator = $null
        $this.SharedState = $null
        $this.ConcurrentResults = @{}
    }

    [void] InitializeRaceConditionTesting() {
        # Create process coordinator for simultaneous operations
        $coordinatorId = "$($this.TestId)-race-coordinator"
        $this.ProcessCoordinator = New-ProcessCoordinator -CoordinatorId $coordinatorId
        $this.RegisterCleanupResource("ProcessCoordinator", $this.ProcessCoordinator)

        # Create shared state for race condition tracking
        $stateId = "$($this.TestId)-race-state"
        $this.SharedState = New-SharedStateManager -StateId $stateId
        $this.RegisterCleanupResource("SharedStateManager", $this.SharedState)

        # Initialize race condition tracking state
        $this.SharedState.SetValue("race-results", @{})
        $this.SharedState.SetValue("participant-count", 0)
        $this.SharedState.SetValue("race-completed", $false)

        $this.LogInfo("Race condition test initialized with simultaneous operation triggers")
        $this.AddTestDetail("CoordinatorId", $coordinatorId)
        $this.AddTestDetail("StateId", $stateId)
    }

    [object] CreateSimultaneousOperation([scriptblock] $operationScript, [hashtable] $parameters, [string] $participantId, [string] $barrierName) {
        $simultaneousScript = {
            param($OriginalScript, $Params, $ParticipantId, $StateId, $BarrierName, $WorkingDir)

            try {
                # Initialize timing and result tracking
                $result = @{
                    ParticipantId = $ParticipantId
                    StartTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                    Success = $false
                    TimingEvents = @()
                    OperationResult = $null
                    Error = $null
                }

                $result.TimingEvents += @{Event = "ProcessStarted"; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')}

                # Wait for barrier synchronization
                $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
                $barrierDir = Join-Path $tempBase "barrier-$BarrierName"
                $statusFile = Join-Path $barrierDir "status.json"

                $barrierStart = Get-Date
                $barrierTimeout = 20
                $barrierReleased = $false

                while (((Get-Date) - $barrierStart).TotalSeconds -lt $barrierTimeout -and -not $barrierReleased) {
                    if (Test-Path $statusFile) {
                        try {
                            $status = Get-Content $statusFile | ConvertFrom-Json
                            if ($status.IsReleased -and $ParticipantId -in $status.ReleasedProcesses) {
                                $barrierReleased = $true
                                $result.TimingEvents += @{Event = "BarrierReleased"; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')}
                                break
                            }
                        } catch {
                            # Continue waiting
                        }
                    }
                    Start-Sleep -Milliseconds 50
                }

                if (-not $barrierReleased) {
                    $result.Error = "Barrier timeout"
                    return $result
                }

                # Execute the operation immediately after barrier release
                $result.TimingEvents += @{Event = "OperationStarted"; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')}

                # Set current working directory for operation
                if ($WorkingDir -and (Test-Path $WorkingDir)) {
                    Set-Location $WorkingDir
                }

                # Execute the actual operation
                $operationResult = & $OriginalScript @Params

                $result.TimingEvents += @{Event = "OperationCompleted"; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')}
                $result.OperationResult = $operationResult
                $result.Success = $true

                return $result
            }
            catch {
                $result.Error = $_.Exception.Message
                $result.TimingEvents += @{Event = "OperationFailed"; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')}
                return $result
            }
        }

        $stateId = $this.SharedState.StateId
        $workingDir = $this.IsolationContext.WorkingDirectory
        return $this.ProcessCoordinator.StartCoordinatedProcess($simultaneousScript, @($operationScript, $parameters, $participantId, $stateId, $barrierName, $workingDir), $barrierName)
    }

    [hashtable] ExecuteSimultaneousOperations([array] $operations, [int] $participantCount, [int] $timeoutSeconds = 30) {
        $result = @{
            Success = $false
            ParticipantResults = @()
            RaceWinner = $null
            TimingAnalysis = @{}
            Error = $null
        }

        try {
            # Create barrier for simultaneous execution
            $barrierName = "race-barrier-$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
            $barrier = $this.ProcessCoordinator.CreateBarrier($barrierName, $participantCount, $timeoutSeconds)

            $this.LogInfo("Created race condition barrier for $participantCount participants")

            # Start all operations
            $processInfos = @()
            for ($i = 0; $i -lt $operations.Count; $i++) {
                $operation = $operations[$i]
                $participantId = "participant-$($i + 1)"

                $processInfo = $this.CreateSimultaneousOperation(
                    $operation.Script,
                    $operation.Parameters,
                    $participantId,
                    $barrierName
                )

                $processInfos += $processInfo
                $this.LogInfo("Started participant: $participantId")
            }

            # Trigger simultaneous execution by satisfying barrier
            $participantIds = 1..$participantCount | ForEach-Object { "participant-$_" }
            foreach ($participantId in $participantIds) {
                $barrier.WaitForBarrier($participantId)
            }

            $this.LogInfo("Barrier released - simultaneous operations executing")

            # Wait for all operations to complete
            foreach ($processInfo in $processInfos) {
                $processResult = $this.ProcessCoordinator.WaitForProcess($processInfo.ProcessId, $timeoutSeconds)

                if ($processResult.Success -and $processResult.Output -ne $null) {
                    $result.ParticipantResults += $processResult.Output
                } else {
                    $this.LogError("Participant $($processInfo.ProcessId) failed: TimedOut=$($processResult.TimedOut)")
                }
            }

            # Analyze race condition results
            $result.TimingAnalysis = $this.AnalyzeRaceTiming($result.ParticipantResults)
            $result.RaceWinner = $this.DetermineRaceWinner($result.ParticipantResults)
            $result.Success = $result.ParticipantResults.Count -eq $participantCount

            $this.LogInfo("Race condition execution completed: $($result.ParticipantResults.Count)/$participantCount participants")

        }
        catch {
            $result.Error = $_.Exception.Message
            $this.LogError("Simultaneous operations execution failed: $($_.Exception.Message)")
        }

        return $result
    }

    [hashtable] AnalyzeRaceTiming([array] $participantResults) {
        $analysis = @{
            TotalParticipants = $participantResults.Count
            SuccessfulParticipants = 0
            TimingSpread = @{}
            ConcurrencyLevel = 0
        }

        if ($participantResults.Count -eq 0) {
            return $analysis
        }

        # Count successful participants
        $analysis.SuccessfulParticipants = ($participantResults | Where-Object { $_.Success }).Count

        # Analyze timing events
        $allTimes = @()
        foreach ($participant in $participantResults) {
            if ($participant.TimingEvents) {
                foreach ($event in $participant.TimingEvents) {
                    if ($event.Event -eq "OperationStarted") {
                        $allTimes += [DateTime]::ParseExact($event.Time, 'yyyy-MM-dd HH:mm:ss.fff', $null)
                    }
                }
            }
        }

        if ($allTimes.Count -gt 1) {
            $minTime = ($allTimes | Measure-Object -Minimum).Minimum
            $maxTime = ($allTimes | Measure-Object -Maximum).Maximum
            $timingSpreadMs = ($maxTime - $minTime).TotalMilliseconds

            $analysis.TimingSpread = @{
                MinTime = $minTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                MaxTime = $maxTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                SpreadMs = $timingSpreadMs
            }

            # Determine concurrency level (operations within 100ms considered simultaneous)
            $analysis.ConcurrencyLevel = ($allTimes | Where-Object { ($_ - $minTime).TotalMilliseconds -le 100 }).Count
        }

        return $analysis
    }

    [string] DetermineRaceWinner([array] $participantResults) {
        if ($participantResults.Count -eq 0) {
            return $null
        }

        # Find the participant who completed their operation first
        $winner = $null
        $earliestTime = $null

        foreach ($participant in $participantResults) {
            if ($participant.Success -and $participant.TimingEvents) {
                $completedEvent = $participant.TimingEvents | Where-Object { $_.Event -eq "OperationCompleted" } | Select-Object -First 1
                if ($completedEvent) {
                    $completedTime = [DateTime]::ParseExact($completedEvent.Time, 'yyyy-MM-dd HH:mm:ss.fff', $null)
                    if ($earliestTime -eq $null -or $completedTime -lt $earliestTime) {
                        $earliestTime = $completedTime
                        $winner = $participant.ParticipantId
                    }
                }
            }
        }

        return $winner
    }

    [bool] ValidateAtomicity([array] $participantResults, [hashtable] $expectedOutcomes) {
        $this.LogInfo("Validating atomicity of concurrent operations")

        try {
            # Check that only one participant succeeded in exclusive operations
            if ($expectedOutcomes.ContainsKey("ExclusiveWinner") -and $expectedOutcomes.ExclusiveWinner) {
                $successfulCount = ($participantResults | Where-Object { $_.Success -and $_.OperationResult.Success }).Count

                if ($successfulCount -ne 1) {
                    $this.LogError("Atomicity violation: Expected 1 exclusive winner, got $successfulCount")
                    return $false
                }

                $this.LogInfo("Atomicity validated: Exactly 1 exclusive winner")
            }

            # Check for data consistency
            if ($expectedOutcomes.ContainsKey("DataConsistency") -and $expectedOutcomes.DataConsistency) {
                $dataConsistent = $this.ValidateDataConsistency($participantResults)
                if (-not $dataConsistent) {
                    $this.LogError("Atomicity violation: Data consistency check failed")
                    return $false
                }

                $this.LogInfo("Atomicity validated: Data consistency maintained")
            }

            # Check for proper error handling in losers
            if ($expectedOutcomes.ContainsKey("ProperErrorHandling") -and $expectedOutcomes.ProperErrorHandling) {
                $errorHandlingValid = $this.ValidateErrorHandling($participantResults)
                if (-not $errorHandlingValid) {
                    $this.LogError("Atomicity violation: Improper error handling detected")
                    return $false
                }

                $this.LogInfo("Atomicity validated: Proper error handling for non-winners")
            }

            return $true
        }
        catch {
            $this.LogError("Atomicity validation failed: $($_.Exception.Message)")
            return $false
        }
    }

    [bool] ValidateDataConsistency([array] $participantResults) {
        # This is a base implementation - specific tests should override
        # Check that all successful operations produced consistent results

        $successfulResults = $participantResults | Where-Object { $_.Success -and $_.OperationResult.Success }

        if ($successfulResults.Count -eq 0) {
            return $true  # No successful operations to validate
        }

        # Basic consistency check - all successful operations should have similar data patterns
        $firstResult = $successfulResults[0].OperationResult
        foreach ($result in $successfulResults[1..($successfulResults.Count-1)]) {
            if ($result.OperationResult.DataPattern -ne $firstResult.DataPattern) {
                return $false
            }
        }

        return $true
    }

    [bool] ValidateErrorHandling([array] $participantResults) {
        # Check that failed operations have appropriate error messages
        $failedResults = $participantResults | Where-Object { -not $_.Success -or -not $_.OperationResult.Success }

        foreach ($failed in $failedResults) {
            if (-not $failed.Error -and -not $failed.OperationResult.Error) {
                # Failed operation should have error information
                return $false
            }
        }

        return $true
    }

    [void] CreateTestFile([string] $filePath, [string] $size) {
        $sizeBytes = $this.ParseSize($size)
        $data = New-Object byte[] $sizeBytes

        # Fill with recognizable pattern for consistency validation
        for ($i = 0; $i -lt $sizeBytes; $i++) {
            $data[$i] = ($i % 256)
        }

        [System.IO.File]::WriteAllBytes($filePath, $data)
        $this.LogInfo("Created test file: $filePath ($sizeBytes bytes)")
    }

    [int] ParseSize([string] $size) {
        if ($size -match "(\d+)(KB|MB|GB)") {
            $number = [int]$Matches[1]
            $unit = $Matches[2]

            switch ($unit) {
                "KB" { return $number * 1024 }
                "MB" { return $number * 1024 * 1024 }
                "GB" { return $number * 1024 * 1024 * 1024 }
                default { return $number }
            }
        }
        return [int]$size
    }

    # Override base RunTest method to include race condition initialization
    [bool] RunTest() {
        try {
            # Ensure working directory is available before operations
            if (-not $this.IsolationContext.WorkingDirectory) {
                $this.LogError("Working directory not initialized")
                return $false
            }

            $this.InitializeRaceConditionTesting()
            return $this.ExecuteRaceConditionTest()
        }
        catch {
            $this.LogError("Race condition test setup failed: $($_.Exception.Message)")
            return $false
        }
    }

    # Abstract method that must be implemented by specific tests
    [bool] ExecuteRaceConditionTest() {
        throw "ExecuteRaceConditionTest must be implemented by derived classes"
    }
}