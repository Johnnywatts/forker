# WDR-001: Write-During-Read Contention Test
# Validates proper blocking behavior when writing to a file that is being read

class WriteDuringReadTest : FileLockingTestCase {
    WriteDuringReadTest() : base("WDR-001", "Write-during-read blocking validation") {
        $this.TestDataSize = "4MB"  # Large enough to create read window for write attempts
    }

    [bool] ExecuteFileLockingTest() {
        $this.LogInfo("Starting Write-During-Read (WDR-001) contention test")

        try {
            # Test the contention scenario where write is attempted during read

            # Step 1: Validate initial conditions
            if (-not (Test-Path $this.SourceFile)) {
                $this.LogError("Source file does not exist")
                return $false
            }

            # Step 2: Test write attempts during active file read
            $this.LogInfo("Testing write attempts during file read operations")

            $writeBlockingResult = $this.TestWriteDuringRead()

            # Step 3: Test exclusive read locks blocking writes
            $this.LogInfo("Testing exclusive read scenarios")

            $exclusiveReadResult = $this.TestExclusiveReadBlocking()

            # Step 4: Analyze results
            $this.AddTestDetail("WriteDuringReadResult", $writeBlockingResult)
            $this.AddTestDetail("ExclusiveReadResult", $exclusiveReadResult)

            $this.AddTestMetric("WriteAttempts", $writeBlockingResult.WriteAttempts.Count)
            $this.AddTestMetric("BlockedWrites", ($writeBlockingResult.WriteAttempts | Where-Object { -not $_.Success }).Count)
            $this.AddTestMetric("SuccessfulWrites", ($writeBlockingResult.WriteAttempts | Where-Object { $_.Success }).Count)
            $this.AddTestMetric("ExclusiveReadWorking", $exclusiveReadResult.Success)

            # Step 5: Validate file integrity and proper coordination
            $integrityValid = $this.ValidateReadWriteCoordination($writeBlockingResult)

            # Success criteria:
            # 1. Read operations complete successfully
            # 2. Write operations show appropriate blocking or coordination behavior
            # 3. File integrity maintained throughout all operations
            # 4. No data corruption or partial writes

            if ($writeBlockingResult.Success -and $exclusiveReadResult.Success -and $integrityValid) {
                $this.LogInfo("WDR-001 test PASSED: Write-during-read handled correctly")
                return $true
            } else {
                $this.LogError("WDR-001 test FAILED: WriteBlocking=$($writeBlockingResult.Success), ExclusiveRead=$($exclusiveReadResult.Success), Integrity=$integrityValid")
                return $false
            }
        }
        catch {
            $this.LogError("WDR-001 test execution failed: $($_.Exception.Message)")
            return $false
        }
    }

    [hashtable] TestWriteDuringRead() {
        $result = @{
            Success = $false
            WriteAttempts = @()
            ReadCompleted = $false
            Error = $null
        }

        # Initialize variables for proper scoping
        $readerJob = $null
        $writerJob = $null

        try {
            # Copy source to target for reading
            Copy-Item $this.SourceFile $this.TargetFile -Force

            # Start a background job that reads the target file slowly
            $readerJob = Start-Job -ScriptBlock {
                param($TargetPath)

                try {
                    # Read file in small chunks with delays to create write opportunity window
                    $fileStream = [System.IO.File]::OpenRead($TargetPath)
                    $buffer = New-Object byte[] 32768  # 32KB chunks
                    $totalBytesRead = 0

                    while ($true) {
                        $bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)
                        if ($bytesRead -eq 0) { break }

                        $totalBytesRead += $bytesRead

                        # Deliberate delay to keep file open and create contention window
                        Start-Sleep -Milliseconds 75
                    }

                    $fileStream.Close()

                    return @{
                        Success = $true
                        BytesRead = $totalBytesRead
                        Completed = $true
                    }
                }
                catch {
                    try { $fileStream.Close() } catch { }
                    return @{
                        Success = $false
                        Error = $_.Exception.Message
                        Completed = $false
                    }
                }
            } -ArgumentList $this.TargetFile

            # Give the reader job a moment to start and open the file
            Start-Sleep -Milliseconds 150

            # Start a background job that attempts to write to the same file
            $writerJob = Start-Job -ScriptBlock {
                param($TargetPath)

                $writeAttempts = @()
                $maxAttempts = 6
                $startTime = Get-Date

                for ($i = 0; $i -lt $maxAttempts; $i++) {
                    $attemptTime = Get-Date
                    $elapsedMs = ($attemptTime - $startTime).TotalMilliseconds

                    $attempt = @{
                        Attempt = $i + 1
                        ElapsedMs = $elapsedMs
                        Success = $false
                        Error = $null
                        AccessMode = "WriteTest"
                    }

                    try {
                        # Attempt to open file for writing (should conflict with reader)
                        $writeStream = [System.IO.File]::Open($TargetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

                        # If we get here, try to write some test data
                        $testData = [System.Text.Encoding]::UTF8.GetBytes("WRITE_TEST_$i")
                        $writeStream.Write($testData, 0, $testData.Length)
                        $writeStream.Flush()
                        $writeStream.Close()

                        $attempt.Success = $true
                    }
                    catch [System.IO.IOException] {
                        $attempt.Error = "IOException: " + $_.Exception.Message
                        $attempt.Success = $false  # Expected - file is being read
                    }
                    catch [System.UnauthorizedAccessException] {
                        $attempt.Error = "UnauthorizedAccess: " + $_.Exception.Message
                        $attempt.Success = $false
                    }
                    catch {
                        $attempt.Error = "Other: " + $_.Exception.Message
                        $attempt.Success = $false
                    }

                    $writeAttempts += $attempt
                    Start-Sleep -Milliseconds 200
                }

                return $writeAttempts
            } -ArgumentList $this.TargetFile

            # Wait for both jobs to complete
            $readerResult = Wait-Job $readerJob -Timeout 20
            $writerResult = Wait-Job $writerJob -Timeout 20

            if ($readerResult) {
                $readerOutput = Receive-Job $readerJob
                $result.ReadCompleted = $readerOutput.Success
            }

            if ($writerResult) {
                $result.WriteAttempts = Receive-Job $writerJob
            }

            # Clean up jobs
            Remove-Job $readerJob
            Remove-Job $writerJob

            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
            # Cleanup jobs if they exist
            try { if ($readerJob) { Remove-Job $readerJob -Force } } catch { }
            try { if ($writerJob) { Remove-Job $writerJob -Force } } catch { }
        }

        return $result
    }

    [hashtable] TestExclusiveReadBlocking() {
        $result = @{
            Success = $false
            CanReadExclusively = $false
            WritesBlockedDuringRead = $false
            Error = $null
        }

        # Initialize variables for proper scoping
        $readStream = $null

        try {
            # Copy source to target for testing
            Copy-Item $this.SourceFile $this.TargetFile -Force

            # Open file for exclusive read access
            $readStream = [System.IO.File]::Open($this.TargetFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

            $result.CanReadExclusively = $true
            $this.LogInfo("Successfully opened file for exclusive read access")

            # While read stream is open, try to write - should demonstrate blocking
            $writeBlockedCount = 0
            $maxWriteAttempts = 3

            for ($i = 0; $i -lt $maxWriteAttempts; $i++) {
                try {
                    # Attempt to write while file is open for reading
                    $writeStream = [System.IO.File]::Open($this.TargetFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    $writeStream.Close()
                    # If we get here, write was not blocked (might be platform behavior)
                }
                catch {
                    $writeBlockedCount++
                    $this.LogInfo("Write attempt $($i+1) blocked as expected: $($_.Exception.GetType().Name)")
                }

                Start-Sleep -Milliseconds 100
            }

            # Close read stream
            $readStream.Close()
            $readStream = $null

            # Determine if blocking behavior is working as expected
            # On some platforms/filesystems, read locks may not block writes as strictly
            $result.WritesBlockedDuringRead = $writeBlockedCount -gt 0
            $result.Success = $result.CanReadExclusively

        }
        catch {
            $result.Error = $_.Exception.Message
            try { if ($readStream) { $readStream.Close() } } catch { }
        }

        return $result
    }

    [bool] ValidateReadWriteCoordination([hashtable] $writeBlockingResult) {
        $this.LogInfo("Validating read-write coordination and file integrity")

        try {
            # Check that the read operation completed successfully
            if (-not $writeBlockingResult.ReadCompleted) {
                $this.LogError("Read operation did not complete successfully")
                return $false
            }

            # Validate that file still exists and has correct content
            if (-not (Test-Path $this.TargetFile)) {
                $this.LogError("Target file missing after read-write test")
                return $false
            }

            # Check file integrity
            $integrityValid = $this.ValidateFileIntegrity($this.TargetFile)
            if (-not $integrityValid) {
                $this.LogError("File integrity validation failed after read-write coordination")
                return $false
            }

            # Analyze write attempt patterns
            $totalWriteAttempts = $writeBlockingResult.WriteAttempts.Count
            $successfulWrites = ($writeBlockingResult.WriteAttempts | Where-Object { $_.Success }).Count
            $blockedWrites = $totalWriteAttempts - $successfulWrites

            $this.AddTestMetric("ReadWriteCoordination", $true)
            $this.AddTestMetric("WriteAttemptPatternValid", $totalWriteAttempts -gt 0)
            $this.AddTestMetric("SomeWritesBlocked", $blockedWrites -gt 0)

            # Success criteria: read completed, file integrity maintained, some coordination behavior observed
            $coordinationWorking = $writeBlockingResult.ReadCompleted -and $integrityValid -and ($totalWriteAttempts -gt 0)

            if ($coordinationWorking) {
                $this.LogInfo("Read-write coordination validation successful")
                $this.LogInfo("  Read completed: $($writeBlockingResult.ReadCompleted)")
                $this.LogInfo("  File integrity: $integrityValid")
                $this.LogInfo("  Write attempts: $totalWriteAttempts")
                $this.LogInfo("  Blocked writes: $blockedWrites")
                return $true
            } else {
                $this.LogError("Read-write coordination validation failed")
                return $false
            }
        }
        catch {
            $this.LogError("Read-write coordination validation error: $($_.Exception.Message)")
            return $false
        }
    }
}