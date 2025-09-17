# DDO-001: Delete-During-Write Contention Test
# Validates proper conflict handling when deleting a file that is being written

class DeleteDuringWriteTest : FileLockingTestCase {
    DeleteDuringWriteTest() : base("DDO-001", "Delete-during-write conflict handling") {
        $this.TestDataSize = "3MB"  # Sufficient size to create deletion window
    }

    [bool] ExecuteFileLockingTest() {
        $this.LogInfo("Starting Delete-During-Write (DDO-001) contention test")

        try {
            # Test the contention scenario where deletion is attempted during write

            # Step 1: Validate initial conditions
            if (-not (Test-Path $this.SourceFile)) {
                $this.LogError("Source file does not exist")
                return $false
            }

            # Step 2: Test basic delete-during-write scenario
            $this.LogInfo("Testing delete attempts during file write operations")

            $deleteScenarioResult = $this.TestDeleteDuringWrite()

            # Step 3: Test delete attempts on locked files
            $this.LogInfo("Testing delete attempts on exclusively locked files")

            $lockScenarioResult = $this.TestDeleteOnLockedFile()

            # Step 4: Analyze results
            $this.AddTestDetail("DeleteDuringWriteResult", $deleteScenarioResult)
            $this.AddTestDetail("DeleteOnLockedResult", $lockScenarioResult)

            $this.AddTestMetric("DeleteAttempts", $deleteScenarioResult.DeleteAttempts.Count)
            $this.AddTestMetric("SuccessfulDeletes", ($deleteScenarioResult.DeleteAttempts | Where-Object { $_.Success }).Count)
            $this.AddTestMetric("BlockedDeletes", ($deleteScenarioResult.DeleteAttempts | Where-Object { -not $_.Success }).Count)
            $this.AddTestMetric("LockScenarioSuccess", $lockScenarioResult.Success)

            # Step 5: Validate data integrity and proper error handling
            $hasProperErrorHandling = $this.ValidateErrorHandling($deleteScenarioResult, $lockScenarioResult)

            # Success criteria:
            # 1. Delete operations either succeed (if timing allows) or fail gracefully
            # 2. No data corruption occurs in either scenario
            # 3. Proper error handling and resource cleanup
            # 4. File system remains in consistent state

            if ($deleteScenarioResult.Success -and $lockScenarioResult.Success -and $hasProperErrorHandling) {
                $this.LogInfo("DDO-001 test PASSED: Delete-during-write handled correctly")
                return $true
            } else {
                $this.LogError("DDO-001 test FAILED: DeleteScenario=$($deleteScenarioResult.Success), LockScenario=$($lockScenarioResult.Success), ErrorHandling=$hasProperErrorHandling")
                return $false
            }
        }
        catch {
            $this.LogError("DDO-001 test execution failed: $($_.Exception.Message)")
            return $false
        }
    }

    [hashtable] TestDeleteDuringWrite() {
        $result = @{
            Success = $false
            DeleteAttempts = @()
            FileWriteComplete = $false
            Error = $null
        }

        # Initialize variables for proper scoping
        $writerJob = $null
        $deleterJob = $null

        try {
            # Remove target file if it exists
            if (Test-Path $this.TargetFile) {
                Remove-Item $this.TargetFile -Force
            }

            # Start a background job that writes to the target file slowly
            $writerJob = Start-Job -ScriptBlock {
                param($SourcePath, $TargetPath)

                try {
                    $sourceData = [System.IO.File]::ReadAllBytes($SourcePath)
                    $targetStream = [System.IO.File]::Create($TargetPath)

                    # Write in small chunks with delays
                    $chunkSize = 32768  # 32KB chunks
                    $totalBytes = 0

                    for ($offset = 0; $offset -lt $sourceData.Length; $offset += $chunkSize) {
                        $remainingBytes = [Math]::Min($chunkSize, $sourceData.Length - $offset)
                        $targetStream.Write($sourceData, $offset, $remainingBytes)
                        $targetStream.Flush()
                        $totalBytes += $remainingBytes

                        # Deliberate delay to create deletion opportunity window
                        Start-Sleep -Milliseconds 100
                    }

                    $targetStream.Close()

                    return @{
                        Success = $true
                        BytesWritten = $totalBytes
                        Completed = $true
                    }
                }
                catch {
                    try { $targetStream.Close() } catch { }
                    return @{
                        Success = $false
                        Error = $_.Exception.Message
                        Completed = $false
                    }
                }
            } -ArgumentList $this.SourceFile, $this.TargetFile

            # Give the writer job a moment to start and create the file
            Start-Sleep -Milliseconds 200

            # Start a background job that attempts to delete the target file
            $deleterJob = Start-Job -ScriptBlock {
                param($TargetPath)

                $deleteAttempts = @()
                $maxAttempts = 8
                $startTime = Get-Date

                for ($i = 0; $i -lt $maxAttempts; $i++) {
                    $attemptTime = Get-Date
                    $elapsedMs = ($attemptTime - $startTime).TotalMilliseconds

                    $attempt = @{
                        Attempt = $i + 1
                        ElapsedMs = $elapsedMs
                        FileExists = (Test-Path $TargetPath)
                        Success = $false
                        Error = $null
                    }

                    if ($attempt.FileExists) {
                        try {
                            Remove-Item $TargetPath -Force -ErrorAction Stop
                            $attempt.Success = $true
                            $deleteAttempts += $attempt
                            break  # Successfully deleted, exit loop
                        }
                        catch {
                            $attempt.Success = $false
                            $attempt.Error = $_.Exception.GetType().Name + ": " + $_.Exception.Message
                        }
                    }

                    $deleteAttempts += $attempt
                    Start-Sleep -Milliseconds 150
                }

                return $deleteAttempts
            } -ArgumentList $this.TargetFile

            # Wait for both jobs to complete
            $writerResult = Wait-Job $writerJob -Timeout 15
            $deleterResult = Wait-Job $deleterJob -Timeout 15

            if ($writerResult) {
                $writerOutput = Receive-Job $writerJob
                $result.FileWriteComplete = $writerOutput.Success
            }

            if ($deleterResult) {
                $result.DeleteAttempts = Receive-Job $deleterJob
            }

            # Clean up jobs
            Remove-Job $writerJob
            Remove-Job $deleterJob

            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
            # Cleanup jobs if they exist
            try { if ($writerJob) { Remove-Job $writerJob -Force } } catch { }
            try { if ($deleterJob) { Remove-Job $deleterJob -Force } } catch { }
        }

        return $result
    }

    [hashtable] TestDeleteOnLockedFile() {
        $result = @{
            Success = $false
            CannotDeleteLocked = $false
            CanDeleteAfterClose = $false
            Error = $null
            Platform = if ($env:OS -eq $null -and $env:HOME -ne $null) { "Linux" } else { "Windows" }
        }

        # Initialize variables for proper scoping
        $fileStream = $null

        try {
            # Create a test file and lock it exclusively
            $lockTestFile = Join-Path (Split-Path $this.TargetFile -Parent) "lock-delete-test.dat"
            $testData = [System.Text.Encoding]::UTF8.GetBytes("Test data for lock deletion test " + ("X" * 1000))
            [System.IO.File]::WriteAllBytes($lockTestFile, $testData)

            # Open file with exclusive write access
            $fileStream = [System.IO.File]::Open($lockTestFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

            # Try to delete the locked file - behavior varies by platform
            try {
                Remove-Item $lockTestFile -Force -ErrorAction Stop

                if ($result.Platform -eq "Linux") {
                    # On Linux, deletion may succeed even with open handles (file is unlinked but handle remains valid)
                    $result.CannotDeleteLocked = $false
                    $this.LogInfo("Delete succeeded on locked file (Linux behavior)")
                } else {
                    # On Windows, this would be unexpected
                    $result.CannotDeleteLocked = $false
                    $this.LogInfo("Delete succeeded on locked file (unexpected on Windows)")
                }
            }
            catch {
                $result.CannotDeleteLocked = $true   # Expected on Windows, possible on Linux
                $this.LogInfo("Delete blocked on locked file as expected: $($_.Exception.GetType().Name)")
            }

            # Close the file stream
            $fileStream.Close()
            $fileStream = $null

            # Try to delete after closing (if file still exists)
            if (Test-Path $lockTestFile) {
                try {
                    Remove-Item $lockTestFile -Force -ErrorAction Stop
                    $result.CanDeleteAfterClose = $true
                }
                catch {
                    $result.CanDeleteAfterClose = $false
                    $result.Error = "Could not delete after closing: " + $_.Exception.Message
                }
            } else {
                # File was already deleted (Linux behavior)
                $result.CanDeleteAfterClose = $true
            }

            # Adjust success criteria based on platform
            if ($result.Platform -eq "Linux") {
                # On Linux, either deletion succeeds immediately or we can delete after close
                $result.Success = $result.CanDeleteAfterClose
            } else {
                # On Windows, expect blocking behavior
                $result.Success = $result.CannotDeleteLocked -and $result.CanDeleteAfterClose
            }
        }
        catch {
            $result.Error = $_.Exception.Message
            try { if ($fileStream) { $fileStream.Close() } } catch { }
        }

        return $result
    }

    [bool] ValidateErrorHandling([hashtable] $deleteScenarioResult, [hashtable] $lockScenarioResult) {
        $this.LogInfo("Validating error handling and resource cleanup")

        # Check that delete scenario handled errors gracefully
        $hasGracefulErrorHandling = $true

        if ($deleteScenarioResult.DeleteAttempts.Count -gt 0) {
            foreach ($attempt in $deleteScenarioResult.DeleteAttempts) {
                if (-not $attempt.Success -and -not $attempt.Error) {
                    # Failed attempt should have error information
                    $hasGracefulErrorHandling = $false
                    $this.LogError("Delete attempt $($attempt.Attempt) failed without error information")
                }
            }
        }

        # Check that lock scenario demonstrated expected behavior (platform-aware)
        $lockBehaviorCorrect = $lockScenarioResult.Success

        if (-not $lockBehaviorCorrect) {
            $this.LogError("Lock scenario behavior incorrect on $($lockScenarioResult.Platform): CannotDeleteLocked=$($lockScenarioResult.CannotDeleteLocked), CanDeleteAfterClose=$($lockScenarioResult.CanDeleteAfterClose)")
        } else {
            $this.LogInfo("Lock scenario behavior correct for $($lockScenarioResult.Platform) platform")
        }

        # Check file system state consistency
        $filesystemConsistent = $this.ValidateFilesystemConsistency()

        $this.AddTestMetric("GracefulErrorHandling", $hasGracefulErrorHandling)
        $this.AddTestMetric("LockBehaviorCorrect", $lockBehaviorCorrect)
        $this.AddTestMetric("FilesystemConsistent", $filesystemConsistent)

        return $hasGracefulErrorHandling -and $lockBehaviorCorrect -and $filesystemConsistent
    }

    [bool] ValidateFilesystemConsistency() {
        try {
            # Check that no temporary or partial files remain
            $workingDir = Split-Path $this.TargetFile -Parent
            $testFiles = Get-ChildItem $workingDir -Filter "*.dat" -ErrorAction SilentlyContinue

            # Should only have source file and possibly target file
            $unexpectedFiles = $testFiles | Where-Object { $_.Name -notmatch "source-file|target-file" }

            if ($unexpectedFiles.Count -gt 0) {
                $this.LogError("Found unexpected files: $($unexpectedFiles.Name -join ', ')")
                return $false
            }

            # Validate that source file is still intact
            if (-not $this.ValidateFileIntegrity($this.SourceFile)) {
                $this.LogError("Source file integrity compromised")
                return $false
            }

            # If target file exists, validate its integrity
            if (Test-Path $this.TargetFile) {
                if (-not $this.ValidateFileIntegrity($this.TargetFile)) {
                    $this.LogError("Target file exists but has integrity issues")
                    return $false
                }
            }

            return $true
        }
        catch {
            $this.LogError("Filesystem consistency check failed: $($_.Exception.Message)")
            return $false
        }
    }
}