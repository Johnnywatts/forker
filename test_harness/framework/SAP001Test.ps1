# SAP-001: Simultaneous Access Prevention Test
# Validates that simultaneous file creation produces predictable outcomes

class SimultaneousAccessTest : RaceConditionTestCase {
    SimultaneousAccessTest() : base("SAP-001", "Simultaneous file creation test") {
        $this.TestDataSize = "2MB"  # Sufficient size for race condition testing
    }

    [bool] ExecuteRaceConditionTest() {
        $this.LogInfo("Starting Simultaneous Access Prevention (SAP-001) race condition test")

        try {
            # Test parameters
            $participantCount = 3
            $targetFile = Join-Path $this.IsolationContext.WorkingDirectory "race-target.dat"
            $sourceFile = Join-Path $this.IsolationContext.WorkingDirectory "race-source.dat"

            # Create source file for copy operations
            $this.CreateTestFile($sourceFile, $this.TestDataSize)

            # Step 1: Test simultaneous file creation
            $this.LogInfo("Testing simultaneous file creation with $participantCount participants")

            $creationRaceResult = $this.TestSimultaneousFileCreation($sourceFile, $targetFile, $participantCount)

            # Step 2: Test simultaneous copy operations
            $this.LogInfo("Testing simultaneous copy operations")

            $copyRaceResult = $this.TestSimultaneousCopyOperations($sourceFile, $participantCount)

            # Step 3: Analyze race condition results
            $this.AddTestDetail("CreationRaceResult", $creationRaceResult)
            $this.AddTestDetail("CopyRaceResult", $copyRaceResult)

            $this.AddTestMetric("CreationParticipants", $creationRaceResult.ParticipantResults.Count)
            $this.AddTestMetric("CreationWinner", $creationRaceResult.RaceWinner)
            $this.AddTestMetric("CopyParticipants", $copyRaceResult.ParticipantResults.Count)
            $this.AddTestMetric("CopyWinner", $copyRaceResult.RaceWinner)

            # Step 4: Validate atomicity and winner/loser outcomes
            $atomicityValid = $this.ValidateSimultaneousAccessAtomicity($creationRaceResult, $copyRaceResult)

            # Success criteria:
            # 1. Exactly one participant succeeds in exclusive operations
            # 2. Clear winner/loser outcomes with proper error handling
            # 3. No data corruption or partial operations
            # 4. File system remains in consistent state

            if ($creationRaceResult.Success -and $copyRaceResult.Success -and $atomicityValid) {
                $this.LogInfo("SAP-001 test PASSED: Simultaneous access properly handled")
                return $true
            } else {
                $this.LogError("SAP-001 test FAILED: Creation=$($creationRaceResult.Success), Copy=$($copyRaceResult.Success), Atomicity=$atomicityValid")
                return $false
            }
        }
        catch {
            $this.LogError("SAP-001 test execution failed: $($_.Exception.Message)")
            return $false
        }
    }

    [hashtable] TestSimultaneousFileCreation([string] $sourceFile, [string] $targetFile, [int] $participantCount) {
        # Remove target file to ensure clean start
        if (Test-Path $targetFile) {
            Remove-Item $targetFile -Force
        }

        # Create operations for simultaneous file creation
        $operations = @()
        for ($i = 0; $i -lt $participantCount; $i++) {
            $operations += @{
                Script = {
                    param($SourcePath, $TargetPath, $ParticipantId)

                    try {
                        $result = @{
                            ParticipantId = $ParticipantId
                            Success = $false
                            OperationResult = @{
                                Success = $false
                                BytesCopied = 0
                                FileCreated = $false
                                Error = $null
                                DataPattern = "creation-pattern"
                            }
                        }

                        # Attempt to create the target file exclusively
                        if (-not (Test-Path $TargetPath)) {
                            # Copy source to target (atomic operation)
                            $sourceData = [System.IO.File]::ReadAllBytes($SourcePath)

                            # Create file exclusively
                            $targetStream = [System.IO.File]::Create($TargetPath)
                            $targetStream.Write($sourceData, 0, $sourceData.Length)
                            $targetStream.Close()

                            $result.OperationResult.Success = $true
                            $result.OperationResult.BytesCopied = $sourceData.Length
                            $result.OperationResult.FileCreated = $true
                            $result.Success = $true
                        } else {
                            $result.OperationResult.Error = "File already exists"
                        }

                        return $result
                    }
                    catch {
                        return @{
                            ParticipantId = $ParticipantId
                            Success = $false
                            OperationResult = @{
                                Success = $false
                                Error = $_.Exception.Message
                                DataPattern = "creation-pattern"
                            }
                        }
                    }
                }
                Parameters = @{
                    SourcePath = $sourceFile
                    TargetPath = $targetFile
                    ParticipantId = "creator-$i"
                }
            }
        }

        return $this.ExecuteSimultaneousOperations($operations, $participantCount, 30)
    }

    [hashtable] TestSimultaneousCopyOperations([string] $sourceFile, [int] $participantCount) {
        # Create operations for simultaneous copy to different targets
        $operations = @()
        for ($i = 0; $i -lt $participantCount; $i++) {
            $copyTargetFile = Join-Path $this.IsolationContext.WorkingDirectory "copy-target-$i.dat"

            # Remove target file to ensure clean start
            if (Test-Path $copyTargetFile) {
                Remove-Item $copyTargetFile -Force
            }

            $operations += @{
                Script = {
                    param($SourcePath, $TargetPath, $ParticipantId)

                    try {
                        $result = @{
                            ParticipantId = $ParticipantId
                            Success = $false
                            OperationResult = @{
                                Success = $false
                                BytesCopied = 0
                                FileCreated = $false
                                Error = $null
                                DataPattern = "copy-pattern"
                            }
                        }

                        # Perform streaming copy operation
                        $sourceStream = [System.IO.File]::OpenRead($SourcePath)
                        $targetStream = [System.IO.File]::Create($TargetPath)

                        $buffer = New-Object byte[] 65536  # 64KB buffer
                        $totalBytes = 0

                        while ($true) {
                            $bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)
                            if ($bytesRead -eq 0) { break }

                            $targetStream.Write($buffer, 0, $bytesRead)
                            $totalBytes += $bytesRead
                        }

                        $sourceStream.Close()
                        $targetStream.Close()

                        $result.OperationResult.Success = $true
                        $result.OperationResult.BytesCopied = $totalBytes
                        $result.OperationResult.FileCreated = $true
                        $result.Success = $true

                        return $result
                    }
                    catch {
                        # Cleanup streams if they exist
                        try { $sourceStream.Close() } catch { }
                        try { $targetStream.Close() } catch { }

                        return @{
                            ParticipantId = $ParticipantId
                            Success = $false
                            OperationResult = @{
                                Success = $false
                                Error = $_.Exception.Message
                                DataPattern = "copy-pattern"
                            }
                        }
                    }
                }
                Parameters = @{
                    SourcePath = $sourceFile
                    TargetPath = $copyTargetFile
                    ParticipantId = "copier-$i"
                }
            }
        }

        return $this.ExecuteSimultaneousOperations($operations, $participantCount, 45)
    }

    [bool] ValidateSimultaneousAccessAtomicity([hashtable] $creationResult, [hashtable] $copyResult) {
        $this.LogInfo("Validating simultaneous access atomicity and outcomes")

        try {
            # Validate file creation race - exactly one should succeed
            $creationAtomicity = $this.ValidateAtomicity($creationResult.ParticipantResults, @{
                ExclusiveWinner = $true
                DataConsistency = $true
                ProperErrorHandling = $true
            })

            if (-not $creationAtomicity) {
                $this.LogError("File creation atomicity validation failed")
                return $false
            }

            # Validate copy operations - all should succeed (different targets)
            $successfulCopies = ($copyResult.ParticipantResults | Where-Object { $_.Success -and $_.OperationResult.Success }).Count
            $expectedCopies = $copyResult.ParticipantResults.Count

            if ($successfulCopies -ne $expectedCopies) {
                $this.LogError("Copy operation validation failed: Expected $expectedCopies successful copies, got $successfulCopies")
                return $false
            }

            # Validate timing analysis shows true simultaneity
            $creationTimingValid = $this.ValidateSimultaneousTiming($creationResult.TimingAnalysis)
            $copyTimingValid = $this.ValidateSimultaneousTiming($copyResult.TimingAnalysis)

            if (-not $creationTimingValid -or -not $copyTimingValid) {
                $this.LogError("Timing analysis validation failed: Creation=$creationTimingValid, Copy=$copyTimingValid")
                return $false
            }

            # Validate file system state consistency
            $filesystemConsistent = $this.ValidateFilesystemState()

            $this.AddTestMetric("CreationAtomicity", $creationAtomicity)
            $this.AddTestMetric("CopyOperationsSuccessful", $successfulCopies -eq $expectedCopies)
            $this.AddTestMetric("TimingAnalysisValid", $creationTimingValid -and $copyTimingValid)
            $this.AddTestMetric("FilesystemConsistent", $filesystemConsistent)

            return $creationAtomicity -and ($successfulCopies -eq $expectedCopies) -and $creationTimingValid -and $copyTimingValid -and $filesystemConsistent
        }
        catch {
            $this.LogError("Simultaneous access atomicity validation failed: $($_.Exception.Message)")
            return $false
        }
    }

    [bool] ValidateSimultaneousTiming([hashtable] $timingAnalysis) {
        # Check that operations were truly simultaneous (within reasonable timing window)
        if ($timingAnalysis.ConcurrencyLevel -lt 2) {
            $this.LogError("Insufficient concurrency level: $($timingAnalysis.ConcurrencyLevel)")
            return $false
        }

        if ($timingAnalysis.TimingSpread.SpreadMs -gt 500) {
            $this.LogError("Timing spread too large: $($timingAnalysis.TimingSpread.SpreadMs)ms")
            return $false
        }

        $this.LogInfo("Timing analysis valid: Concurrency=$($timingAnalysis.ConcurrencyLevel), Spread=$($timingAnalysis.TimingSpread.SpreadMs)ms")
        return $true
    }

    [bool] ValidateFilesystemState() {
        try {
            $workingDir = $this.IsolationContext.WorkingDirectory
            $files = Get-ChildItem $workingDir -Filter "*.dat" -ErrorAction SilentlyContinue

            # Check that all created files have correct content
            foreach ($file in $files) {
                if ($file.Name -like "race-target.dat" -or $file.Name -like "copy-target-*.dat") {
                    $fileSize = $file.Length
                    $expectedSize = $this.ParseSize($this.TestDataSize)

                    if ($fileSize -ne $expectedSize) {
                        $this.LogError("File size mismatch for $($file.Name): Expected $expectedSize, got $fileSize")
                        return $false
                    }

                    # Validate file content pattern
                    $fileData = [System.IO.File]::ReadAllBytes($file.FullName)
                    for ($i = 0; $i -lt [Math]::Min(1000, $fileData.Length); $i += 100) {
                        if ($fileData[$i] -ne ($i % 256)) {
                            $this.LogError("File content corruption detected in $($file.Name) at offset $i")
                            return $false
                        }
                    }
                }
            }

            $this.LogInfo("Filesystem state validation successful: $($files.Count) files validated")
            return $true
        }
        catch {
            $this.LogError("Filesystem state validation failed: $($_.Exception.Message)")
            return $false
        }
    }
}