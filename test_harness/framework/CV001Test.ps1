# CV-001: Temporary File Cleanup Verification Test
# Tests verification of temporary file cleanup across various scenarios

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")
. (Join-Path $PSScriptRoot ".." "suites" "RecoveryTests.ps1")

class TempFileCleanupTest : RecoveryTestBase {
    [hashtable] $TestScenarios
    [hashtable] $CleanupResults

    TempFileCleanupTest() : base("CV-001") {
        $this.TestScenarios = @{
            RegularFiles = @()
            LockedFiles = @()
            LargeFiles = @()
            NestedFiles = @()
            PermissionFiles = @()
        }
        $this.CleanupResults = @{}
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
            Write-TestLog -Message "Starting CV-001 Temporary File Cleanup Verification Test" -Level "INFO" -TestId $this.TestId

            # Setup test environment
            $this.SetupTest()

            # Phase 1: Create various types of temporary files
            Write-TestLog -Message "Phase 1: Creating various types of temporary files" -Level "INFO" -TestId $this.TestId
            $fileCreationResult = $this.CreateTestFiles()
            $result.Details.FileCreation = $fileCreationResult

            if (-not $fileCreationResult.Success) {
                throw "Failed to create test files: $($fileCreationResult.Error)"
            }

            # Phase 2: Test cleanup of regular files
            Write-TestLog -Message "Phase 2: Testing cleanup of regular files" -Level "INFO" -TestId $this.TestId
            $regularCleanup = $this.TestRegularFileCleanup()
            $result.Details.RegularFileCleanup = $regularCleanup

            # Phase 3: Test cleanup of locked files
            Write-TestLog -Message "Phase 3: Testing cleanup of locked files" -Level "INFO" -TestId $this.TestId
            $lockedCleanup = $this.TestLockedFileCleanup()
            $result.Details.LockedFileCleanup = $lockedCleanup

            # Phase 4: Test cleanup of nested files
            Write-TestLog -Message "Phase 4: Testing cleanup of nested directory files" -Level "INFO" -TestId $this.TestId
            $nestedCleanup = $this.TestNestedFileCleanup()
            $result.Details.NestedFileCleanup = $nestedCleanup

            # Phase 5: Comprehensive cleanup validation
            Write-TestLog -Message "Phase 5: Comprehensive cleanup validation" -Level "INFO" -TestId $this.TestId
            $finalValidation = $this.ValidateComprehensiveCleanup()
            $result.Details.FinalValidation = $finalValidation
            $result.ValidationResults = $finalValidation

            # Determine overall success
            $allPhasesSuccessful = $regularCleanup.Success -and $lockedCleanup.Success -and
                                  $nestedCleanup.Success -and $finalValidation.Success

            if ($allPhasesSuccessful) {
                $result.Status = "Passed"
                Write-TestLog -Message "CV-001 test completed successfully" -Level "INFO" -TestId $this.TestId
            } else {
                $failedPhases = @()
                if (-not $regularCleanup.Success) { $failedPhases += "Regular files" }
                if (-not $lockedCleanup.Success) { $failedPhases += "Locked files" }
                if (-not $nestedCleanup.Success) { $failedPhases += "Nested files" }
                if (-not $finalValidation.Success) { $failedPhases += "Final validation" }

                throw "CV-001 test failed in phases: $($failedPhases -join ', ')"
            }
        }
        catch {
            $result.Status = "Failed"
            $result.ErrorMessage = $_.Exception.Message
            Write-TestLog -Message "CV-001 test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
        finally {
            $result.EndTime = Get-Date
            $this.CleanupTest()
        }

        return $result
    }

    [hashtable] CreateTestFiles() {
        $creation = @{
            Success = $false
            Error = $null
            FilesCreated = 0
            Details = @{}
        }

        try {
            # Create regular temporary files
            Write-TestLog -Message "Creating regular temporary files" -Level "INFO" -TestId $this.TestId
            $this.TestScenarios.RegularFiles = @(
                $this.CreateTempFile("regular1.tmp", "Regular file content 1"),
                $this.CreateTempFile("regular2.dat", "Regular file content 2"),
                $this.CreateTempFile("regular3.txt", "Regular file content 3")
            )

            # Create locked files
            Write-TestLog -Message "Creating files with locks" -Level "INFO" -TestId $this.TestId
            $lockedFile1 = $this.CreateTempFile("locked1.tmp", "Locked file content 1")
            $lockedFile2 = $this.CreateTempFile("locked2.tmp", "Locked file content 2")

            $this.TestScenarios.LockedFiles = @($lockedFile1, $lockedFile2)

            # Create locks on these files
            $lock1 = $this.CreateFileLock($lockedFile1, "Exclusive")
            $lock2 = $this.CreateFileLock($lockedFile2, "Write")

            # Create nested directory structure
            Write-TestLog -Message "Creating nested directory structure" -Level "INFO" -TestId $this.TestId
            $nestedDir = Join-Path $this.TestTempDirectory "nested"
            $deepDir = Join-Path $nestedDir "deep"
            New-Item -ItemType Directory -Path $deepDir -Force | Out-Null

            $nestedFile1 = Join-Path $nestedDir "nested1.tmp"
            $nestedFile2 = Join-Path $deepDir "deep1.tmp"
            Set-Content -Path $nestedFile1 -Value "Nested file content 1"
            Set-Content -Path $nestedFile2 -Value "Deep nested file content"

            $this.TestScenarios.NestedFiles = @($nestedFile1, $nestedFile2)

            # Create large files
            Write-TestLog -Message "Creating large test files" -Level "INFO" -TestId $this.TestId
            $largeContent = "Large file content " * 1000
            $this.TestScenarios.LargeFiles = @(
                $this.CreateTempFile("large1.tmp", $largeContent),
                $this.CreateTempFile("large2.dat", $largeContent)
            )

            $creation.FilesCreated = $this.TestScenarios.RegularFiles.Count +
                                    $this.TestScenarios.LockedFiles.Count +
                                    $this.TestScenarios.NestedFiles.Count +
                                    $this.TestScenarios.LargeFiles.Count

            $creation.Details = @{
                RegularFiles = $this.TestScenarios.RegularFiles.Count
                LockedFiles = $this.TestScenarios.LockedFiles.Count
                NestedFiles = $this.TestScenarios.NestedFiles.Count
                LargeFiles = $this.TestScenarios.LargeFiles.Count
            }

            $creation.Success = $true
            Write-TestLog -Message "Created $($creation.FilesCreated) test files successfully" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $creation.Error = $_.Exception.Message
            Write-TestLog -Message "Failed to create test files: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $creation
    }

    [hashtable] TestRegularFileCleanup() {
        $cleanup = @{
            Success = $false
            Error = $null
            FilesTestedCount = 0
            FilesCleanedCount = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing cleanup of regular files" -Level "INFO" -TestId $this.TestId

            foreach ($filePath in $this.TestScenarios.RegularFiles) {
                $cleanup.FilesTestedCount++

                # Verify file exists before cleanup
                $existsBefore = Test-Path $filePath

                # Attempt cleanup
                try {
                    Remove-Item -Path $filePath -Force -ErrorAction Stop
                    $cleanupSuccessful = $true
                    $cleanup.FilesCleanedCount++
                } catch {
                    $cleanupSuccessful = $false
                }

                # Verify file removed after cleanup
                $existsAfter = Test-Path $filePath

                $fileResult = @{
                    FilePath = $filePath
                    ExistedBefore = $existsBefore
                    CleanupSuccessful = $cleanupSuccessful
                    ExistsAfter = $existsAfter
                    ProperlyRemoved = $existsBefore -and $cleanupSuccessful -and (-not $existsAfter)
                }

                $cleanup.Results += $fileResult

                Write-TestLog -Message "Regular file cleanup: $($filePath) - Removed: $($fileResult.ProperlyRemoved)" -Level "INFO" -TestId $this.TestId
            }

            # Test utility function
            $utilityTest = Test-FileCleanup $this.TestScenarios.RegularFiles -TimeoutSeconds 2

            $cleanup.Success = ($cleanup.FilesCleanedCount -eq $cleanup.FilesTestedCount) -and $utilityTest.Success
            Write-TestLog -Message "Regular file cleanup test: $($cleanup.Success) ($($cleanup.FilesCleanedCount)/$($cleanup.FilesTestedCount) files cleaned)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $cleanup.Error = $_.Exception.Message
            Write-TestLog -Message "Regular file cleanup test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $cleanup
    }

    [hashtable] TestLockedFileCleanup() {
        $cleanup = @{
            Success = $false
            Error = $null
            FilesTestedCount = 0
            LocksReleasedCount = 0
            FilesCleanedCount = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing cleanup of locked files" -Level "INFO" -TestId $this.TestId

            foreach ($filePath in $this.TestScenarios.LockedFiles) {
                $cleanup.FilesTestedCount++

                # Verify file is locked initially
                $initiallyLocked = $false
                try {
                    $testStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    $testStream.Close()
                    $testStream.Dispose()
                    $initiallyLocked = $false
                } catch {
                    $initiallyLocked = $true
                }

                # Release the lock
                $lockInfo = $this.FileLocks | Where-Object { $_.FilePath -eq $filePath } | Select-Object -First 1
                if ($lockInfo) {
                    $this.ReleaseFileLock($lockInfo)
                    $cleanup.LocksReleasedCount++
                }

                # Test lock release
                $lockReleaseResult = Test-FileLockRelease $filePath -TimeoutSeconds 3

                # Attempt cleanup after lock release
                try {
                    Remove-Item -Path $filePath -Force -ErrorAction Stop
                    $cleanupSuccessful = $true
                    $cleanup.FilesCleanedCount++
                } catch {
                    $cleanupSuccessful = $false
                }

                $fileResult = @{
                    FilePath = $filePath
                    InitiallyLocked = $initiallyLocked
                    LockReleased = $lockReleaseResult.Success
                    CleanupSuccessful = $cleanupSuccessful
                    ProperlyHandled = $initiallyLocked -and $lockReleaseResult.Success -and $cleanupSuccessful
                }

                $cleanup.Results += $fileResult

                Write-TestLog -Message "Locked file cleanup: $($filePath) - Initially locked: $($initiallyLocked), Released: $($lockReleaseResult.Success), Cleaned: $($cleanupSuccessful)" -Level "INFO" -TestId $this.TestId
            }

            $cleanup.Success = ($cleanup.LocksReleasedCount -eq $cleanup.FilesTestedCount) -and
                              ($cleanup.FilesCleanedCount -eq $cleanup.FilesTestedCount)

            Write-TestLog -Message "Locked file cleanup test: $($cleanup.Success) ($($cleanup.LocksReleasedCount) locks released, $($cleanup.FilesCleanedCount) files cleaned)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $cleanup.Error = $_.Exception.Message
            Write-TestLog -Message "Locked file cleanup test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $cleanup
    }

    [hashtable] TestNestedFileCleanup() {
        $cleanup = @{
            Success = $false
            Error = $null
            FilesTestedCount = 0
            FilesCleanedCount = 0
            DirectoriesCleanedCount = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing cleanup of nested directory files" -Level "INFO" -TestId $this.TestId

            foreach ($filePath in $this.TestScenarios.NestedFiles) {
                $cleanup.FilesTestedCount++

                # Verify file exists
                $existsBefore = Test-Path $filePath

                # Attempt cleanup
                try {
                    Remove-Item -Path $filePath -Force -ErrorAction Stop
                    $cleanupSuccessful = $true
                    $cleanup.FilesCleanedCount++
                } catch {
                    $cleanupSuccessful = $false
                }

                $fileResult = @{
                    FilePath = $filePath
                    ExistedBefore = $existsBefore
                    CleanupSuccessful = $cleanupSuccessful
                    ProperlyRemoved = $existsBefore -and $cleanupSuccessful -and (-not (Test-Path $filePath))
                }

                $cleanup.Results += $fileResult

                Write-TestLog -Message "Nested file cleanup: $($filePath) - Removed: $($fileResult.ProperlyRemoved)" -Level "INFO" -TestId $this.TestId
            }

            # Test directory cleanup
            $nestedDir = Join-Path $this.TestTempDirectory "nested"
            if (Test-Path $nestedDir) {
                try {
                    Remove-Item -Path $nestedDir -Recurse -Force -ErrorAction Stop
                    $cleanup.DirectoriesCleanedCount++
                    Write-TestLog -Message "Nested directory cleanup: $nestedDir - Removed successfully" -Level "INFO" -TestId $this.TestId
                } catch {
                    Write-TestLog -Message "Nested directory cleanup: $nestedDir - Failed to remove" -Level "WARN" -TestId $this.TestId
                }
            }

            $cleanup.Success = ($cleanup.FilesCleanedCount -eq $cleanup.FilesTestedCount) -and
                              ($cleanup.DirectoriesCleanedCount -eq 1)

            Write-TestLog -Message "Nested file cleanup test: $($cleanup.Success) ($($cleanup.FilesCleanedCount) files, $($cleanup.DirectoriesCleanedCount) directories cleaned)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $cleanup.Error = $_.Exception.Message
            Write-TestLog -Message "Nested file cleanup test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $cleanup
    }

    [hashtable] ValidateComprehensiveCleanup() {
        $validation = @{
            Success = $false
            Error = $null
            Summary = ""
            TotalFilesChecked = 0
            RemainingFiles = @()
            CleanupResults = @{}
        }

        try {
            Write-TestLog -Message "Performing comprehensive cleanup validation" -Level "INFO" -TestId $this.TestId

            # Collect all test files
            $allTestFiles = @()
            $allTestFiles += $this.TestScenarios.RegularFiles
            $allTestFiles += $this.TestScenarios.LockedFiles
            $allTestFiles += $this.TestScenarios.LargeFiles

            $validation.TotalFilesChecked = $allTestFiles.Count

            # Check for remaining files
            foreach ($filePath in $allTestFiles) {
                if (Test-Path $filePath) {
                    $validation.RemainingFiles += $filePath
                }
            }

            # Check nested files separately
            foreach ($filePath in $this.TestScenarios.NestedFiles) {
                if (Test-Path $filePath) {
                    $validation.RemainingFiles += $filePath
                }
            }

            # Run system cleanup validation
            $systemValidation = $this.ValidateSystemCleanup()
            $validation.CleanupResults = $systemValidation

            # Determine success
            $noRemainingFiles = $validation.RemainingFiles.Count -eq 0
            $systemClean = $systemValidation.Success

            $validation.Success = $noRemainingFiles -and $systemClean

            if ($validation.Success) {
                $validation.Summary = "All temporary files cleaned up successfully"
                Write-TestLog -Message "Comprehensive cleanup validation: PASSED - All files cleaned" -Level "INFO" -TestId $this.TestId
            } else {
                $issues = @()
                if (-not $noRemainingFiles) { $issues += "$($validation.RemainingFiles.Count) files remain" }
                if (-not $systemClean) { $issues += "System cleanup issues" }

                $validation.Summary = "Cleanup validation failed: $($issues -join ', ')"
                Write-TestLog -Message "Comprehensive cleanup validation: FAILED - $($validation.Summary)" -Level "ERROR" -TestId $this.TestId

                # Log remaining files
                foreach ($remainingFile in $validation.RemainingFiles) {
                    Write-TestLog -Message "Remaining file: $remainingFile" -Level "WARN" -TestId $this.TestId
                }
            }
        }
        catch {
            $validation.Error = $_.Exception.Message
            $validation.Summary = "Cleanup validation error: $($_.Exception.Message)"
            Write-TestLog -Message "Comprehensive cleanup validation failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $validation
    }
}

# Factory function for creating CV-001 test
function New-TempFileCleanupTest {
    return [TempFileCleanupTest]::new()
}

Write-TestLog -Message "CV-001 Temporary File Cleanup Test loaded successfully" -Level "INFO" -TestId "CV-001"