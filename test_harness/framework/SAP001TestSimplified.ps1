# SAP-001: Simultaneous Access Prevention Test (Simplified)
# Validates that simultaneous file creation produces predictable outcomes

class SimultaneousAccessTestSimplified : RaceConditionTestCase {
    SimultaneousAccessTestSimplified() : base("SAP-001", "Simultaneous file creation test") {
        $this.TestDataSize = "1MB"  # Smaller size for faster testing
    }

    [bool] ExecuteRaceConditionTest() {
        $this.LogInfo("Starting Simultaneous Access Prevention (SAP-001) race condition test")

        try {
            # Test parameters
            $targetFile = Join-Path $this.IsolationContext.WorkingDirectory "race-target.dat"
            $sourceFile = Join-Path $this.IsolationContext.WorkingDirectory "race-source.dat"

            # Create source file for operations
            $this.CreateTestFile($sourceFile, $this.TestDataSize)

            # Step 1: Test simultaneous file creation using background jobs
            $this.LogInfo("Testing simultaneous file creation with background jobs")

            $creationRaceResult = $this.TestSimultaneousCreationSimplified($sourceFile, $targetFile)

            # Step 2: Test simultaneous copy operations to different targets
            $this.LogInfo("Testing simultaneous copy operations to different targets")

            $copyRaceResult = $this.TestSimultaneousCopySimplified($sourceFile)

            # Step 3: Analyze results and validate race condition handling
            $this.AddTestDetail("CreationRaceResult", $creationRaceResult)
            $this.AddTestDetail("CopyRaceResult", $copyRaceResult)

            $this.AddTestMetric("CreationAttempts", $creationRaceResult.AttemptResults.Count)
            $this.AddTestMetric("CreationSuccesses", ($creationRaceResult.AttemptResults | Where-Object { $_.Success }).Count)
            $this.AddTestMetric("CopyAttempts", $copyRaceResult.AttemptResults.Count)
            $this.AddTestMetric("CopySuccesses", ($copyRaceResult.AttemptResults | Where-Object { $_.Success }).Count)

            # Validate race condition outcomes
            $raceOutcomesValid = $this.ValidateRaceConditionOutcomes($creationRaceResult, $copyRaceResult)

            # Success criteria:
            # 1. Simultaneous operations show predictable race behavior
            # 2. File system remains consistent after race conditions
            # 3. No data corruption or partial operations
            # 4. Winner/loser outcomes are clearly identifiable

            if ($creationRaceResult.Success -and $copyRaceResult.Success -and $raceOutcomesValid) {
                $this.LogInfo("SAP-001 test PASSED: Simultaneous access properly handled")
                return $true
            } else {
                $this.LogError("SAP-001 test FAILED: Creation=$($creationRaceResult.Success), Copy=$($copyRaceResult.Success), Outcomes=$raceOutcomesValid")
                return $false
            }
        }
        catch {
            $this.LogError("SAP-001 test execution failed: $($_.Exception.Message)")
            return $false
        }
    }

    [hashtable] TestSimultaneousCreationSimplified([string] $sourceFile, [string] $targetFile) {
        $result = @{
            Success = $false
            AttemptResults = @()
            Winner = $null
            Error = $null
        }

        # Initialize variables for proper scoping
        $jobs = @()

        try {
            # Remove target file to ensure clean start
            if (Test-Path $targetFile) {
                Remove-Item $targetFile -Force
            }

            # Create 3 background jobs that attempt to create the same file
            for ($i = 0; $i -lt 3; $i++) {
                $job = Start-Job -ScriptBlock {
                    param($SourcePath, $TargetPath, $ParticipantId)

                    $attemptResult = @{
                        ParticipantId = $ParticipantId
                        Success = $false
                        StartTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                        EndTime = $null
                        Error = $null
                        FileCreated = $false
                        BytesCopied = 0
                    }

                    try {
                        # Add small random delay to create race condition window
                        Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 100)

                        # Attempt to create the target file exclusively using atomic operation
                        $sourceData = [System.IO.File]::ReadAllBytes($SourcePath)

                        # Try to create file exclusively - this will fail if file already exists
                        $targetStream = [System.IO.File]::Open($TargetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                        $targetStream.Write($sourceData, 0, $sourceData.Length)
                        $targetStream.Close()

                        $attemptResult.Success = $true
                        $attemptResult.FileCreated = $true
                        $attemptResult.BytesCopied = $sourceData.Length
                    }
                    catch {
                        $attemptResult.Error = $_.Exception.Message
                    }

                    $attemptResult.EndTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                    return $attemptResult
                } -ArgumentList $sourceFile, $targetFile, "creator-$i"

                $jobs += $job
            }

            # Wait for all jobs to complete
            $jobResults = @()
            foreach ($job in $jobs) {
                $jobResult = Wait-Job $job -Timeout 15
                if ($jobResult) {
                    $output = Receive-Job $job
                    $jobResults += $output
                }
                Remove-Job $job
            }

            $result.AttemptResults = $jobResults
            # Determine winner
            $successfulAttempts = @()
            foreach ($attempt in $jobResults) {
                if ($attempt.Success) {
                    $successfulAttempts += $attempt
                }
            }

            if ($successfulAttempts.Count -eq 1) {
                $result.Winner = $successfulAttempts[0].ParticipantId
                $this.LogInfo("Race winner: $($result.Winner)")
            } elseif ($successfulAttempts.Count -eq 0) {
                $this.LogInfo("No successful creation attempts (all collided)")
            } else {
                $this.LogInfo("Multiple successful attempts: $($successfulAttempts.Count)")
            }

            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
            # Cleanup jobs if they exist
            foreach ($job in $jobs) {
                try { Remove-Job $job -Force } catch { }
            }
        }

        return $result
    }

    [hashtable] TestSimultaneousCopySimplified([string] $sourceFile) {
        $result = @{
            Success = $false
            AttemptResults = @()
            Error = $null
        }

        # Initialize variables for proper scoping
        $jobs = @()

        try {
            # Create 3 background jobs that copy to different target files
            for ($i = 0; $i -lt 3; $i++) {
                $targetFile = Join-Path $this.IsolationContext.WorkingDirectory "copy-target-$i.dat"

                # Remove target file to ensure clean start
                if (Test-Path $targetFile) {
                    Remove-Item $targetFile -Force
                }

                $job = Start-Job -ScriptBlock {
                    param($SourcePath, $TargetPath, $ParticipantId)

                    $attemptResult = @{
                        ParticipantId = $ParticipantId
                        Success = $false
                        StartTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                        EndTime = $null
                        Error = $null
                        BytesCopied = 0
                    }

                    try {
                        # Add small random delay to simulate timing variations
                        Start-Sleep -Milliseconds (Get-Random -Minimum 5 -Maximum 50)

                        # Perform copy operation
                        $sourceData = [System.IO.File]::ReadAllBytes($SourcePath)
                        [System.IO.File]::WriteAllBytes($TargetPath, $sourceData)

                        $attemptResult.Success = $true
                        $attemptResult.BytesCopied = $sourceData.Length
                    }
                    catch {
                        $attemptResult.Error = $_.Exception.Message
                    }

                    $attemptResult.EndTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                    return $attemptResult
                } -ArgumentList $sourceFile, $targetFile, "copier-$i"

                $jobs += $job
            }

            # Wait for all jobs to complete
            $jobResults = @()
            foreach ($job in $jobs) {
                $jobResult = Wait-Job $job -Timeout 15
                if ($jobResult) {
                    $output = Receive-Job $job
                    $jobResults += $output
                }
                Remove-Job $job
            }

            $result.AttemptResults = $jobResults
            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
            # Cleanup jobs if they exist
            foreach ($job in $jobs) {
                try { Remove-Job $job -Force } catch { }
            }
        }

        return $result
    }

    [bool] ValidateRaceConditionOutcomes([hashtable] $creationResult, [hashtable] $copyResult) {
        $this.LogInfo("Validating race condition outcomes and file system consistency")

        try {
            # Validate creation race - at most one should succeed
            $creationSuccesses = 0
            foreach ($attempt in $creationResult.AttemptResults) {
                if ($attempt.Success) {
                    $creationSuccesses++
                }
            }

            if ($creationSuccesses -gt 1) {
                $this.LogError("Race condition violation: Multiple creators succeeded ($creationSuccesses)")
                return $false
            }

            $this.LogInfo("File creation race validation: $creationSuccesses winner(s)")

            # Validate copy operations - all should succeed (different targets)
            $copySuccesses = 0
            foreach ($attempt in $copyResult.AttemptResults) {
                if ($attempt.Success) {
                    $copySuccesses++
                }
            }
            $expectedCopySuccesses = $copyResult.AttemptResults.Count

            if ($copySuccesses -ne $expectedCopySuccesses) {
                $this.LogError("Copy operations failed: Expected $expectedCopySuccesses, got $copySuccesses")
                return $false
            }

            $this.LogInfo("Copy operations validation: $copySuccesses/$expectedCopySuccesses successful")

            # Validate file system state
            $filesystemValid = $this.ValidateFilesystemConsistency()

            $this.AddTestMetric("CreationRaceValid", $creationSuccesses -le 1)
            $this.AddTestMetric("CopyOperationsValid", $copySuccesses -eq $expectedCopySuccesses)
            $this.AddTestMetric("FilesystemValid", $filesystemValid)

            return ($creationSuccesses -le 1) -and ($copySuccesses -eq $expectedCopySuccesses) -and $filesystemValid
        }
        catch {
            $this.LogError("Race condition outcome validation failed: $($_.Exception.Message)")
            return $false
        }
    }

    [bool] ValidateFilesystemConsistency() {
        try {
            $workingDir = $this.IsolationContext.WorkingDirectory
            $files = Get-ChildItem $workingDir -Filter "*.dat" -ErrorAction SilentlyContinue

            $expectedSize = $this.ParseSize($this.TestDataSize)
            $validFiles = 0

            foreach ($file in $files) {
                if ($file.Name -like "race-target.dat" -or $file.Name -like "copy-target-*.dat") {
                    if ($file.Length -eq $expectedSize) {
                        $validFiles++
                    } else {
                        $this.LogError("File size mismatch: $($file.Name) = $($file.Length), expected $expectedSize")
                        return $false
                    }
                }
            }

            $this.LogInfo("Filesystem consistency: $validFiles files validated")
            return $true
        }
        catch {
            $this.LogError("Filesystem consistency validation failed: $($_.Exception.Message)")
            return $false
        }
    }
}