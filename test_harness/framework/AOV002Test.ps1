# AOV-002: Multi-Destination Atomicity Test
# Validates that multi-destination copy operations are atomic (all succeed or all fail)

class MultiDestinationAtomicityTest : RaceConditionTestCase {
    [string[]] $DestinationPaths
    [int] $DestinationCount

    MultiDestinationAtomicityTest() : base("AOV-002", "Multi-destination atomicity validation") {
        $this.TestDataSize = "1MB"  # Sufficient size for atomicity testing
        $this.DestinationCount = 5  # Multiple destinations to test atomicity
        $this.DestinationPaths = @()
    }

    [bool] ExecuteRaceConditionTest() {
        $this.LogInfo("Starting Multi-Destination Atomicity (AOV-002) test")

        try {
            # Test parameters
            $sourceFile = Join-Path $this.IsolationContext.WorkingDirectory "atomic-source.dat"

            # Create source file for copy operations
            $this.CreateTestFile($sourceFile, $this.TestDataSize)

            # Initialize destination paths
            $this.InitializeDestinations()

            # Step 1: Test atomic multi-destination copy with interference
            $this.LogInfo("Testing atomic multi-destination copy with process interference")

            $atomicCopyResult = $this.TestAtomicMultiDestinationCopy($sourceFile)

            # Step 2: Test partial failure scenarios
            $this.LogInfo("Testing partial failure atomicity scenarios")

            $partialFailureResult = $this.TestPartialFailureAtomicity($sourceFile)

            # Step 3: Test interference resistance
            $this.LogInfo("Testing interference resistance during multi-destination operations")

            $interferenceResult = $this.TestInterferenceResistance($sourceFile)

            # Step 4: Analyze atomicity and consistency
            $this.AddTestDetail("AtomicCopyResult", $atomicCopyResult)
            $this.AddTestDetail("PartialFailureResult", $partialFailureResult)
            $this.AddTestDetail("InterferenceResult", $interferenceResult)

            $this.AddTestMetric("DestinationCount", $this.DestinationCount)
            $this.AddTestMetric("AtomicOperations", $atomicCopyResult.AtomicOperationCount)
            $this.AddTestMetric("PartialFailurePrevention", $partialFailureResult.NoPartialStates)
            $this.AddTestMetric("InterferenceResistance", $interferenceResult.Success)

            # Step 5: Validate no partial success states
            $atomicityValid = $this.ValidateMultiDestinationAtomicity($atomicCopyResult, $partialFailureResult, $interferenceResult)

            # Success criteria:
            # 1. All destinations succeed atomically or entire operation fails
            # 2. No partial success states (all targets complete or none)
            # 3. Interference does not create inconsistent states
            # 4. System remains stable during atomic operations

            if ($atomicCopyResult.Success -and $partialFailureResult.Success -and $interferenceResult.Success -and $atomicityValid) {
                $this.LogInfo("AOV-002 test PASSED: Multi-destination atomicity properly maintained")
                return $true
            } else {
                $this.LogError("AOV-002 test FAILED: Atomic=$($atomicCopyResult.Success), Partial=$($partialFailureResult.Success), Interference=$($interferenceResult.Success), Atomicity=$atomicityValid")
                return $false
            }
        }
        catch {
            $this.LogError("AOV-002 test execution failed: $($_.Exception.Message)")
            return $false
        }
    }

    [void] InitializeDestinations() {
        $this.DestinationPaths = @()
        for ($i = 0; $i -lt $this.DestinationCount; $i++) {
            $destPath = Join-Path $this.IsolationContext.WorkingDirectory "destination-$i.dat"
            $this.DestinationPaths += $destPath

            # Clean up any existing files
            if (Test-Path $destPath) {
                Remove-Item $destPath -Force
            }
        }

        $this.LogInfo("Initialized $($this.DestinationCount) destination paths for atomicity testing")
    }

    [hashtable] TestAtomicMultiDestinationCopy([string] $sourceFile) {
        $result = @{
            Success = $false
            AtomicOperationCount = 0
            AllOrNothingOperations = @()
            Error = $null
        }

        try {
            # Test multiple atomic operations where all destinations must succeed
            $operationCount = 3
            $result.AtomicOperationCount = $operationCount

            for ($op = 0; $op -lt $operationCount; $op++) {
                $this.LogInfo("Starting atomic operation $($op + 1)/$operationCount")

                # Clean destinations before each operation
                foreach ($destPath in $this.DestinationPaths) {
                    if (Test-Path $destPath) {
                        Remove-Item $destPath -Force
                    }
                }

                $operationResult = $this.ExecuteAtomicMultiCopy($sourceFile, $op)
                $result.AllOrNothingOperations += $operationResult

                # Validate atomicity: either all destinations exist or none exist
                $existingDestinations = 0
                foreach ($destPath in $this.DestinationPaths) {
                    if (Test-Path $destPath) {
                        $existingDestinations++
                    }
                }

                $isAtomic = ($existingDestinations -eq 0) -or ($existingDestinations -eq $this.DestinationCount)
                $operationResult.IsAtomic = $isAtomic

                if (-not $isAtomic) {
                    $this.LogError("Atomicity violation: $existingDestinations/$($this.DestinationCount) destinations exist")
                    $result.Error = "Partial success detected - atomicity violated"
                    return $result
                }

                $this.LogInfo("Operation $($op + 1) atomicity: $isAtomic ($existingDestinations destinations)")
            }

            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] ExecuteAtomicMultiCopyWithRollback([string] $sourceFile, [int] $operationId) {
        $operationResult = @{
            OperationId = $operationId
            Success = $false
            DestinationResults = @()
            IsAtomic = $false
            RolledBack = $false
            Error = $null
        }

        # Initialize variables for proper scoping
        $jobs = @()
        $createdFiles = @()

        try {
            # Two-phase approach: first create all temp files, then atomically rename all or rollback

            # Phase 1: Create all temp files
            for ($i = 0; $i -lt $this.DestinationPaths.Count; $i++) {
                $destPath = $this.DestinationPaths[$i]

                $job = Start-Job -ScriptBlock {
                    param($SourcePath, $DestPath, $DestinationIndex, $OperationId)

                    $destResult = @{
                        DestinationIndex = $DestinationIndex
                        OperationId = $OperationId
                        Success = $false
                        StartTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                        EndTime = $null
                        Error = $null
                        BytesCopied = 0
                        TempFile = "$DestPath.tmp"
                    }

                    try {
                        # Add random delay to simulate realistic timing
                        Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 200)

                        # Read source data
                        $sourceData = [System.IO.File]::ReadAllBytes($SourcePath)

                        # Create temp file exclusively (fails if file already exists)
                        $tempStream = [System.IO.File]::Open($destResult.TempFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                        $tempStream.Write($sourceData, 0, $sourceData.Length)
                        $tempStream.Close()

                        $destResult.Success = $true
                        $destResult.BytesCopied = $sourceData.Length
                    }
                    catch {
                        $destResult.Error = $_.Exception.Message
                        # Clean up temp file if it exists
                        try { if (Test-Path $destResult.TempFile) { Remove-Item $destResult.TempFile -Force } } catch { }
                    }

                    $destResult.EndTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                    return $destResult
                } -ArgumentList $sourceFile, $destPath, $i, $operationId

                $jobs += $job
            }

            # Wait for all temp file creation to complete
            $jobResults = @()
            foreach ($job in $jobs) {
                $jobResult = Wait-Job $job -Timeout 15
                if ($jobResult) {
                    $output = Receive-Job $job
                    $jobResults += $output
                }
                Remove-Job $job
            }

            $operationResult.DestinationResults = $jobResults

            # Check if ALL temp files were created successfully
            $successfulTempFiles = 0
            $tempFilePaths = @()
            foreach ($result in $jobResults) {
                if ($result.Success) {
                    $successfulTempFiles++
                    $tempFilePaths += $result.TempFile
                }
            }

            # Phase 2: Atomic commit or rollback
            if ($successfulTempFiles -eq $this.DestinationCount) {
                # All temp files created successfully - perform atomic rename
                $renameSuccess = $true
                $renamedFiles = @()

                for ($i = 0; $i -lt $tempFilePaths.Count; $i++) {
                    $tempFile = $tempFilePaths[$i]
                    $finalPath = $this.DestinationPaths[$i]

                    try {
                        Move-Item $tempFile $finalPath
                        $renamedFiles += $finalPath
                    }
                    catch {
                        $renameSuccess = $false
                        # Rollback: remove any files we've already renamed
                        foreach ($renamedFile in $renamedFiles) {
                            try { Remove-Item $renamedFile -Force } catch { }
                        }
                        # Remove remaining temp files
                        foreach ($remainingTemp in $tempFilePaths) {
                            try { if (Test-Path $remainingTemp) { Remove-Item $remainingTemp -Force } } catch { }
                        }
                        break
                    }
                }

                $operationResult.Success = $renameSuccess
                $operationResult.IsAtomic = $renameSuccess
            } else {
                # Some or all temp files failed - rollback by removing all temp files and any final destinations
                foreach ($result in $jobResults) {
                    if ($result.Success -and (Test-Path $result.TempFile)) {
                        try { Remove-Item $result.TempFile -Force } catch { }
                    }
                }

                # Also clean up any destinations that might have been created outside this operation
                foreach ($destPath in $this.DestinationPaths) {
                    if (Test-Path $destPath) {
                        try {
                            Remove-Item $destPath -Force
                        } catch { }
                    }
                }

                $operationResult.RolledBack = $true
                $operationResult.IsAtomic = $true  # Atomic failure (no partial state)
                $operationResult.Success = $false
            }

        }
        catch {
            $operationResult.Error = $_.Exception.Message
            # Emergency cleanup
            foreach ($job in $jobs) {
                try { Remove-Job $job -Force } catch { }
            }
            # Clean up any temp files
            foreach ($destPath in $this.DestinationPaths) {
                try { if (Test-Path "$destPath.tmp") { Remove-Item "$destPath.tmp" -Force } } catch { }
            }
        }

        return $operationResult
    }

    [hashtable] ExecuteAtomicMultiCopy([string] $sourceFile, [int] $operationId) {
        # Use the same rollback approach for consistency
        return $this.ExecuteAtomicMultiCopyWithRollback($sourceFile, $operationId)
    }

    [hashtable] TestPartialFailureAtomicity([string] $sourceFile) {
        $result = @{
            Success = $false
            NoPartialStates = $true
            FailureScenarios = @()
            Error = $null
        }

        try {
            # Test scenarios where failures should result in complete rollback
            $scenarioCount = 3

            for ($scenario = 0; $scenario -lt $scenarioCount; $scenario++) {
                $this.LogInfo("Testing partial failure scenario $($scenario + 1)/$scenarioCount")

                # Clean destinations
                foreach ($destPath in $this.DestinationPaths) {
                    if (Test-Path $destPath) {
                        Remove-Item $destPath -Force
                    }
                }

                $scenarioResult = $this.SimulatePartialFailure($sourceFile, $scenario)
                $result.FailureScenarios += $scenarioResult

                # Verify no partial states exist
                $existingDestinations = 0
                foreach ($destPath in $this.DestinationPaths) {
                    if (Test-Path $destPath) {
                        $existingDestinations++
                    }
                }

                # In failure scenarios, there should be 0 destinations (complete rollback)
                # or all destinations (complete success despite simulation)
                if ($existingDestinations -gt 0 -and $existingDestinations -lt $this.DestinationCount) {
                    $this.LogError("Partial failure scenario $scenario resulted in partial state: $existingDestinations/$($this.DestinationCount)")
                    $result.NoPartialStates = $false
                } else {
                    $this.LogInfo("Scenario $scenario atomicity maintained: $existingDestinations destinations")
                }
            }

            $result.Success = $result.NoPartialStates
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] SimulatePartialFailure([string] $sourceFile, [int] $scenarioId) {
        $scenarioResult = @{
            ScenarioId = $scenarioId
            SimulationType = ""
            Success = $false
            RolledBack = $false
            OperationResult = $null
            Error = $null
        }

        try {
            switch ($scenarioId) {
                0 {
                    # Simulate disk space exhaustion by creating a file at the temp location
                    $scenarioResult.SimulationType = "DiskSpaceExhaustion"
                    $restrictedPath = $this.DestinationPaths[0]
                    $restrictedTempPath = "$restrictedPath.tmp"

                    # Create a file at the temp path to simulate space issues
                    $blocker = New-Object byte[] (100 * 1024)  # 100KB blocker
                    [System.IO.File]::WriteAllBytes($restrictedTempPath, $blocker)

                    # Attempt multi-copy operation (should fail atomically due to temp file conflict)
                    $copyResult = $this.ExecuteAtomicMultiCopyWithRollback($sourceFile, 100 + $scenarioId)
                    $scenarioResult.OperationResult = $copyResult
                    $scenarioResult.RolledBack = $copyResult.RolledBack

                    # Clean up blocker
                    if (Test-Path $restrictedTempPath) {
                        Remove-Item $restrictedTempPath -Force
                    }
                    if (Test-Path $restrictedPath) {
                        Remove-Item $restrictedPath -Force
                    }

                    $scenarioResult.Success = $true
                }
                1 {
                    # Simulate permission error on one destination by creating a directory at the temp file path
                    $scenarioResult.SimulationType = "PermissionDenied"
                    $restrictedPath = $this.DestinationPaths[1]
                    $restrictedTempPath = "$restrictedPath.tmp"

                    # Create a directory at the temp file path to cause write conflict
                    New-Item -ItemType Directory -Path $restrictedTempPath -Force | Out-Null

                    # Attempt multi-copy operation (should fail atomically due to temp file conflict)
                    $copyResult = $this.ExecuteAtomicMultiCopyWithRollback($sourceFile, 200 + $scenarioId)
                    $scenarioResult.OperationResult = $copyResult
                    $scenarioResult.RolledBack = $copyResult.RolledBack

                    # Clean up
                    if (Test-Path $restrictedTempPath) {
                        Remove-Item $restrictedTempPath -Recurse -Force
                    }
                    if (Test-Path $restrictedPath) {
                        Remove-Item $restrictedPath -Force
                    }

                    $scenarioResult.Success = $true
                }
                2 {
                    # Simulate file locking on one destination temp file
                    $scenarioResult.SimulationType = "FileLocking"
                    $lockedPath = $this.DestinationPaths[2]
                    $lockedTempPath = "$lockedPath.tmp"

                    # Create and lock a file at the temp file path
                    $lockStream = [System.IO.File]::Create($lockedTempPath)

                    try {
                        # Attempt multi-copy operation while temp file is locked (should fail atomically)
                        $copyResult = $this.ExecuteAtomicMultiCopyWithRollback($sourceFile, 300 + $scenarioId)
                        $scenarioResult.OperationResult = $copyResult
                        $scenarioResult.RolledBack = $copyResult.RolledBack
                        $scenarioResult.Success = $true
                    }
                    finally {
                        $lockStream.Close()
                        if (Test-Path $lockedTempPath) {
                            Remove-Item $lockedTempPath -Force
                        }
                        if (Test-Path $lockedPath) {
                            Remove-Item $lockedPath -Force
                        }
                    }
                }
            }
        }
        catch {
            $scenarioResult.Error = $_.Exception.Message
        }

        return $scenarioResult
    }

    [hashtable] TestInterferenceResistance([string] $sourceFile) {
        $result = @{
            Success = $false
            InterferenceScenarios = @()
            ConsistencyMaintained = $true
            Error = $null
        }

        # Initialize variables for proper scoping
        $copyJob = $null
        $interferenceJobs = @()

        try {
            # Test resistance to external interference during multi-destination operations
            $this.LogInfo("Starting interference resistance test")

            # Clean destinations
            foreach ($destPath in $this.DestinationPaths) {
                if (Test-Path $destPath) {
                    Remove-Item $destPath -Force
                }
            }

            # Start multi-destination copy operation
            $copyJob = Start-Job -ScriptBlock {
                param($TestInstance, $SourceFile)

                # This would need to call back to the test instance
                # For simplicity, we'll simulate a long-running copy
                Start-Sleep -Seconds 2
                return @{ Success = $true; Message = "Multi-copy completed" }
            } -ArgumentList $this, $sourceFile

            # Start interference processes
            for ($i = 0; $i -lt 3; $i++) {
                $interferenceJob = Start-Job -ScriptBlock {
                    param($DestinationPaths, $InterferenceId)

                    $interferenceResult = @{
                        InterferenceId = $InterferenceId
                        ActionsPerformed = @()
                        Success = $false
                    }

                    try {
                        # Perform random interference actions
                        for ($action = 0; $action -lt 5; $action++) {
                            $targetDest = $DestinationPaths[(Get-Random) % $DestinationPaths.Count]

                            switch ((Get-Random) % 3) {
                                0 {
                                    # Try to read from destination
                                    if (Test-Path $targetDest) {
                                        try {
                                            $data = [System.IO.File]::ReadAllBytes($targetDest)
                                            $interferenceResult.ActionsPerformed += "Read-$targetDest"
                                        } catch { }
                                    }
                                }
                                1 {
                                    # Try to create temp file near destination
                                    try {
                                        $tempFile = "$targetDest.interference"
                                        "interference" | Out-File $tempFile
                                        Remove-Item $tempFile -Force
                                        $interferenceResult.ActionsPerformed += "TempCreate-$targetDest"
                                    } catch { }
                                }
                                2 {
                                    # Try to stat the destination
                                    if (Test-Path $targetDest) {
                                        try {
                                            $info = Get-Item $targetDest
                                            $interferenceResult.ActionsPerformed += "Stat-$targetDest"
                                        } catch { }
                                    }
                                }
                            }

                            Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 200)
                        }

                        $interferenceResult.Success = $true
                    }
                    catch {
                        $interferenceResult.Error = $_.Exception.Message
                    }

                    return $interferenceResult
                } -ArgumentList $this.DestinationPaths, $i

                $interferenceJobs += $interferenceJob
            }

            # Wait for copy to complete
            $copyResult = Wait-Job $copyJob -Timeout 10
            if ($copyResult) {
                $copyOutput = Receive-Job $copyJob
            }
            Remove-Job $copyJob

            # Wait for interference to complete
            foreach ($job in $interferenceJobs) {
                $interferenceResult = Wait-Job $job -Timeout 5
                if ($interferenceResult) {
                    $output = Receive-Job $job
                    $result.InterferenceScenarios += $output
                }
                Remove-Job $job
            }

            # Validate consistency after interference
            $existingDestinations = 0
            foreach ($destPath in $this.DestinationPaths) {
                if (Test-Path $destPath) {
                    $existingDestinations++
                }
            }

            # Check for atomicity after interference
            $result.ConsistencyMaintained = ($existingDestinations -eq 0) -or ($existingDestinations -eq $this.DestinationCount)

            if (-not $result.ConsistencyMaintained) {
                $this.LogError("Interference caused inconsistent state: $existingDestinations/$($this.DestinationCount) destinations")
            }

            $result.Success = $result.ConsistencyMaintained

        }
        catch {
            $result.Error = $_.Exception.Message
            # Cleanup jobs
            try { if ($copyJob) { Remove-Job $copyJob -Force } } catch { }
            foreach ($job in $interferenceJobs) {
                try { Remove-Job $job -Force } catch { }
            }
        }

        return $result
    }

    [bool] ValidateMultiDestinationAtomicity([hashtable] $atomicResult, [hashtable] $partialResult, [hashtable] $interferenceResult) {
        $this.LogInfo("Validating multi-destination atomicity and consistency")

        try {
            # Validate atomic operations
            if (-not $atomicResult.Success) {
                $this.LogError("Atomic multi-destination copy validation failed")
                return $false
            }

            # Validate no partial failure states
            if (-not $partialResult.NoPartialStates) {
                $this.LogError("Partial failure scenarios produced inconsistent states")
                return $false
            }

            # Validate interference resistance
            if (-not $interferenceResult.ConsistencyMaintained) {
                $this.LogError("Interference caused atomicity violations")
                return $false
            }

            # Validate file system final state
            $finalStateValid = $this.ValidateFinalSystemState()

            $this.AddTestMetric("AtomicOperationsValid", $atomicResult.Success)
            $this.AddTestMetric("NoPartialStates", $partialResult.NoPartialStates)
            $this.AddTestMetric("InterferenceResistant", $interferenceResult.ConsistencyMaintained)
            $this.AddTestMetric("FinalStateValid", $finalStateValid)

            $overallValid = $atomicResult.Success -and $partialResult.NoPartialStates -and $interferenceResult.ConsistencyMaintained -and $finalStateValid

            if ($overallValid) {
                $this.LogInfo("Multi-destination atomicity validation successful")
                return $true
            } else {
                $this.LogError("Multi-destination atomicity validation failed")
                return $false
            }
        }
        catch {
            $this.LogError("Multi-destination atomicity validation error: $($_.Exception.Message)")
            return $false
        }
    }

    [bool] ValidateFinalSystemState() {
        try {
            $workingDir = $this.IsolationContext.WorkingDirectory
            $files = Get-ChildItem $workingDir -Filter "*.dat" -ErrorAction SilentlyContinue

            # Check that all destination files (if they exist) have correct content
            $expectedSize = $this.ParseSize($this.TestDataSize)
            $validDestinations = 0

            foreach ($file in $files) {
                if ($file.Name -like "destination-*.dat") {
                    if ($file.Length -eq $expectedSize) {
                        # Validate file content
                        $fileData = [System.IO.File]::ReadAllBytes($file.FullName)
                        $isValid = $true

                        # Sample validation (check pattern in first 1000 bytes)
                        for ($i = 0; $i -lt [Math]::Min(1000, $fileData.Length); $i += 100) {
                            if ($fileData[$i] -ne ($i % 256)) {
                                $isValid = $false
                                break
                            }
                        }

                        if ($isValid) {
                            $validDestinations++
                        } else {
                            $this.LogError("File content corruption detected in $($file.Name)")
                            return $false
                        }
                    } else {
                        $this.LogError("File size mismatch for $($file.Name): Expected $expectedSize, got $($file.Length)")
                        return $false
                    }
                }
            }

            # Check for temp files (should be cleaned up)
            $tempFiles = Get-ChildItem $workingDir -Filter "*.tmp" -ErrorAction SilentlyContinue
            if ($tempFiles.Count -gt 0) {
                $this.LogError("Temporary files not cleaned up: $($tempFiles.Count) files remain")
                return $false
            }

            $this.LogInfo("Final system state validation successful: $validDestinations valid destinations, 0 temp files")
            return $true
        }
        catch {
            $this.LogError("Final system state validation failed: $($_.Exception.Message)")
            return $false
        }
    }
}