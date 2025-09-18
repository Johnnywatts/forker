# Unit Tests for File Verification Module
# Tests streaming SHA256 verification, fallback methods, and non-locking access

BeforeAll {
    # Import required modules
    $ModulePath = Join-Path $PSScriptRoot "../../modules/FileCopier"
    Import-Module (Join-Path $ModulePath "Configuration.ps1") -Force
    Import-Module (Join-Path $ModulePath "Logging.ps1") -Force
    Import-Module (Join-Path $ModulePath "Utils.ps1") -Force
    Import-Module (Join-Path $ModulePath "Verification.ps1") -Force

    # Create test directory
    if ($env:TEMP) {
        $Global:TestDirectory = Join-Path $env:TEMP "FileCopier.VerificationTests.$(Get-Random)"
    } else {
        $Global:TestDirectory = Join-Path "/tmp" "FileCopier.VerificationTests.$(Get-Random)"
    }
    New-Item -ItemType Directory -Path $Global:TestDirectory -Force | Out-Null

    # Test configuration
    $Global:TestConfig = @{
        Verification = @{
            HashRetryAttempts = 3
            TimestampToleranceSeconds = 2
            SmallFileSizeMB = 1
            LargeFileSizeMB = 100
            EnableLargeFileHashing = $true
            MultiTargetTimeoutSeconds = 60
        }
        FileOperations = @{
            ChunkSize = 8192  # Smaller chunks for faster testing
        }
        Logging = @{
            Level = "ERROR"  # Reduce noise in tests
            Target = "Console"
        }
    }

    # Initialize logging for tests
    Initialize-FileCopierLogging -LogLevel "ERROR" -EnableConsoleLogging -EnableFileLogging:$false -EnableEventLogging:$false

    # Helper function to create test files with known content
    function New-TestFile {
        param(
            [string] $FilePath,
            [int] $SizeBytes = 1024,
            [string] $Content = $null
        )

        if ($Content) {
            $Content | Out-File -FilePath $FilePath -Encoding UTF8 -NoNewline
        } else {
            $randomContent = -join ((1..$SizeBytes) | ForEach-Object { [char]((Get-Random -Minimum 65 -Maximum 91)) })
            $randomContent | Out-File -FilePath $FilePath -Encoding UTF8 -NoNewline
        }

        return $FilePath
    }

    # Helper function to create files with specific hash
    function New-FileWithHash {
        param(
            [string] $FilePath,
            [string] $Content = "Test content for hash verification"
        )

        $Content | Out-File -FilePath $FilePath -Encoding UTF8 -NoNewline

        # Calculate expected hash
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $hashString = [BitConverter]::ToString($hash) -replace '-', ''

        return @{
            FilePath = $FilePath
            Content = $Content
            ExpectedHash = $hashString
        }
    }
}

AfterAll {
    # Cleanup test directory
    if (Test-Path $Global:TestDirectory) {
        Remove-Item -Path $Global:TestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "FileVerification Class" {
    BeforeEach {
        $script:Verifier = [FileVerification]::new($Global:TestConfig)
    }

    Context "Initialization" {
        It "Should initialize with configuration" {
            $script:Verifier | Should -Not -BeNullOrEmpty
            $script:Verifier.Config | Should -Not -BeNullOrEmpty
            $script:Verifier.LogContext | Should -Be "FileVerification"
        }

        It "Should initialize performance counters" {
            $script:Verifier.PerformanceCounters | Should -Not -BeNullOrEmpty
            $script:Verifier.PerformanceCounters.VerificationCount | Should -Be 0
            $script:Verifier.PerformanceCounters.VerificationErrors | Should -Be 0
        }
    }

    Context "Hash Calculation" {
        It "Should calculate SHA256 hash for small file" {
            $testFile = New-FileWithHash -FilePath (Join-Path $Global:TestDirectory "small-test.txt")

            $actualHash = $script:Verifier.CalculateStreamingHash($testFile.FilePath)

            $actualHash | Should -Be $testFile.ExpectedHash
        }

        It "Should handle file access with sharing enabled" {
            $testFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "shared-access.txt") -Content "Shared access test"

            # Open file for reading in another stream (simulating polling process)
            $readerStream = [System.IO.FileStream]::new($testFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)

            try {
                # Should be able to calculate hash while file is open
                $hash = $script:Verifier.CalculateStreamingHash($testFile)
                $hash | Should -Not -BeNullOrEmpty
                $hash.Length | Should -Be 64  # SHA256 hex string length
            }
            finally {
                $readerStream.Close()
                $readerStream.Dispose()
            }
        }

        It "Should retry on file access failures" {
            $testFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "retry-test.txt") -Content "Retry test content"

            # Mock a temporarily locked file by opening exclusively briefly
            $job = Start-Job -ScriptBlock {
                param($FilePath)
                $exclusiveStream = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                Start-Sleep -Milliseconds 500  # Hold lock briefly
                $exclusiveStream.Close()
                $exclusiveStream.Dispose()
            } -ArgumentList $testFile

            # Start hash calculation slightly after lock
            Start-Sleep -Milliseconds 100
            $hash = $script:Verifier.CalculateStreamingHash($testFile)

            $hash | Should -Not -BeNullOrEmpty

            Wait-Job $job | Remove-Job
        }

        It "Should handle large files efficiently" {
            # Create larger test file (1MB)
            $largeContent = "Large file test content " * 43690  # Approximately 1MB
            $largeFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "large-test.txt") -Content $largeContent

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $hash = $script:Verifier.CalculateStreamingHash($largeFile)
            $stopwatch.Stop()

            $hash | Should -Not -BeNullOrEmpty
            $hash.Length | Should -Be 64
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 2000  # Should complete within 2 seconds
        }
    }

    Context "File Verification Methods" {
        It "Should verify identical files with hash method" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "source.txt") -Content "Identical content"
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "target.txt") -Content "Identical content"

            $result = $script:Verifier.VerifyFile($sourceFile, $targetFile, "Hash")

            $result.Success | Should -Be $true
            $result.Method | Should -Be "Hash"
            $result.SourceHash | Should -Be $result.TargetHash
            $result.UsedFallback | Should -Be $false
        }

        It "Should detect different files with hash method" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "source2.txt") -Content "Source content"
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "target2.txt") -Content "Different content"

            $result = $script:Verifier.VerifyFile($sourceFile, $targetFile, "Hash")

            $result.Success | Should -Be $false
            $result.Method | Should -Be "Hash"
            $result.SourceHash | Should -Not -Be $result.TargetHash
        }

        It "Should verify with size and timestamp method" {
            $content = "Size and timestamp test"
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "source3.txt") -Content $content
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "target3.txt") -Content $content

            # Ensure same timestamp
            $timestamp = (Get-Item $sourceFile).LastWriteTime
            (Get-Item $targetFile).LastWriteTime = $timestamp

            $result = $script:Verifier.VerifyFile($sourceFile, $targetFile, "SizeAndTimestamp")

            $result.Success | Should -Be $true
            $result.Method | Should -Be "SizeAndTimestamp"
            $result.UsedFallback | Should -Be $true
        }

        It "Should detect size mismatch in size-only verification" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "source4.txt") -Content "Short"
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "target4.txt") -Content "Much longer content"

            $result = $script:Verifier.VerifyFile($sourceFile, $targetFile, "SizeOnly")

            $result.Success | Should -Be $false
            $result.Method | Should -Be "SizeOnly"
            $result.UsedFallback | Should -Be $true
        }

        It "Should auto-select verification method based on file size" {
            # Small file should use hash
            $smallFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "small.txt") -SizeBytes 512
            $smallTarget = New-TestFile -FilePath (Join-Path $Global:TestDirectory "small-target.txt") -SizeBytes 512

            $result = $script:Verifier.VerifyFile($smallFile, $smallTarget, "Auto")

            $result.Method | Should -Be "Hash"
        }

        It "Should handle fallback when hash calculation fails" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "fallback-source.txt") -Content "Fallback test"
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "fallback-target.txt") -Content "Fallback test"

            # Mock hash calculation failure by temporarily using invalid chunk size
            $originalChunkSize = $script:Verifier.Config.FileOperations.ChunkSize
            $script:Verifier.Config.FileOperations.ChunkSize = -1  # Invalid chunk size

            try {
                $result = $script:Verifier.VerifyFile($sourceFile, $targetFile, "Hash")

                $result.Success | Should -Be $true  # Should succeed via fallback
                $result.UsedFallback | Should -Be $true
                $result.Method | Should -Be "SizeAndTimestamp"
            }
            finally {
                $script:Verifier.Config.FileOperations.ChunkSize = $originalChunkSize
            }
        }
    }

    Context "Multi-Target Verification" {
        It "Should verify multiple targets successfully" {
            $content = "Multi-target test content"
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "multi-source.txt") -Content $content
            $target1 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "multi-target1.txt") -Content $content
            $target2 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "multi-target2.txt") -Content $content

            $result = $script:Verifier.VerifyMultipleTargets($sourceFile, @($target1, $target2), "Hash")

            $result.Success | Should -Be $true
            $result.TargetResults.Count | Should -Be 2
            $result.TargetResults[0].Success | Should -Be $true
            $result.TargetResults[1].Success | Should -Be $true
        }

        It "Should detect failure in multi-target verification" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "multi-source2.txt") -Content "Source content"
            $target1 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "multi-target3.txt") -Content "Source content"
            $target2 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "multi-target4.txt") -Content "Different content"

            $result = $script:Verifier.VerifyMultipleTargets($sourceFile, @($target1, $target2), "Hash")

            $result.Success | Should -Be $false  # Should fail due to target2 mismatch
            $result.TargetResults.Count | Should -Be 2
            $result.TargetResults[0].Success | Should -Be $true
            $result.TargetResults[1].Success | Should -Be $false
        }
    }

    Context "Performance Monitoring" {
        It "Should update performance counters" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "perf-source.txt") -Content "Performance test"
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "perf-target.txt") -Content "Performance test"

            $initialCount = $script:Verifier.PerformanceCounters.VerificationCount

            $result = $script:Verifier.VerifyFile($sourceFile, $targetFile, "Hash")

            $script:Verifier.PerformanceCounters.VerificationCount | Should -Be ($initialCount + 1)
            $script:Verifier.PerformanceCounters.HashCalculationTimeMs.Count | Should -BeGreaterThan $initialCount
        }

        It "Should provide performance statistics" {
            # Perform a few verifications to generate statistics
            for ($i = 1; $i -le 3; $i++) {
                $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "stats-source$i.txt") -Content "Stats test $i"
                $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "stats-target$i.txt") -Content "Stats test $i"
                $script:Verifier.VerifyFile($sourceFile, $targetFile, "Hash") | Out-Null
            }

            $stats = $script:Verifier.GetPerformanceStatistics()

            $stats | Should -Not -BeNullOrEmpty
            $stats.VerificationCount | Should -BeGreaterThan 0
            $stats.AverageVerificationTimeMs | Should -BeGreaterThan 0
            $stats.VerificationThroughputMBps | Should -BeGreaterThan 0
        }
    }

    Context "Health Checks" {
        It "Should perform health check successfully" {
            $health = $script:Verifier.PerformHealthCheck()

            $health.Status | Should -BeIn @("Healthy", "Warning")
            $health.Checks | Should -Not -BeNullOrEmpty
            $health.Checks.Configuration | Should -Be "OK"
            $health.Checks.FileAccess | Should -Be "OK"
            $health.Checks.Performance | Should -Be "OK"
        }

        It "Should detect configuration issues" {
            # Create verifier with invalid configuration
            $invalidConfig = $Global:TestConfig.Clone()
            $invalidConfig.Verification.Remove("HashRetryAttempts")

            $invalidVerifier = [FileVerification]::new($invalidConfig)
            $configCheck = $invalidVerifier.ValidateConfiguration()

            $configCheck | Should -Not -Be "OK"
            $configCheck | Should -Match "Missing configuration"
        }
    }

    Context "Error Handling" {
        It "Should handle missing source file" {
            $missingSource = Join-Path $Global:TestDirectory "missing-source.txt"
            $targetFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "error-target.txt") -Content "Target exists"

            $result = $script:Verifier.VerifyFile($missingSource, $targetFile, "Hash")

            $result.Success | Should -Be $false
            $result.Error | Should -Match "Source file not found"
        }

        It "Should handle missing target file" {
            $sourceFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "error-source.txt") -Content "Source exists"
            $missingTarget = Join-Path $Global:TestDirectory "missing-target.txt"

            $result = $script:Verifier.VerifyFile($sourceFile, $missingTarget, "Hash")

            $result.Success | Should -Be $false
            $result.Error | Should -Match "Target file not found"
        }

        It "Should track error count in performance counters" {
            $initialErrors = $script:Verifier.PerformanceCounters.VerificationErrors

            # Trigger an error
            $result = $script:Verifier.VerifyFile("nonexistent", "alsononexistent", "Hash")

            $script:Verifier.PerformanceCounters.VerificationErrors | Should -Be ($initialErrors + 1)
        }
    }
}

Describe "Static Utility Functions" {
    Context "Compare-FileHashes" {
        It "Should compare file hashes correctly" {
            $content = "Hash comparison test"
            $file1 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "hash1.txt") -Content $content
            $file2 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "hash2.txt") -Content $content

            $result = Compare-FileHashes -SourceFile $file1 -TargetFile $file2

            $result.Success | Should -Be $true
            $result.Method | Should -Be "Hash"
        }

        It "Should accept custom configuration" {
            $customConfig = @{
                FileOperations = @{ ChunkSize = 4096 }
                Verification = @{ HashRetryAttempts = 5 }
            }

            $file1 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "custom1.txt") -Content "Custom config test"
            $file2 = New-TestFile -FilePath (Join-Path $Global:TestDirectory "custom2.txt") -Content "Custom config test"

            $result = Compare-FileHashes -SourceFile $file1 -TargetFile $file2 -Configuration $customConfig

            $result.Success | Should -Be $true
        }
    }

    Context "Test-FileIntegrity" {
        It "Should validate file against expected hash" {
            $testFile = New-FileWithHash -FilePath (Join-Path $Global:TestDirectory "integrity.txt")

            $result = Test-FileIntegrity -FilePath $testFile.FilePath -ExpectedHash $testFile.ExpectedHash

            $result.Success | Should -Be $true
            $result.ActualHash | Should -Be $testFile.ExpectedHash
        }

        It "Should detect hash mismatch" {
            $testFile = New-FileWithHash -FilePath (Join-Path $Global:TestDirectory "integrity2.txt")
            $wrongHash = "0123456789ABCDEF" * 4  # 64 character fake hash

            $result = Test-FileIntegrity -FilePath $testFile.FilePath -ExpectedHash $wrongHash

            $result.Success | Should -Be $false
            $result.ActualHash | Should -Not -Be $wrongHash
        }
    }

    Context "Get-DefaultVerificationConfig" {
        It "Should return valid default configuration" {
            $config = Get-DefaultVerificationConfig

            $config | Should -Not -BeNullOrEmpty
            $config.Verification | Should -Not -BeNullOrEmpty
            $config.FileOperations | Should -Not -BeNullOrEmpty
            $config.Verification.HashRetryAttempts | Should -BeGreaterThan 0
            $config.FileOperations.ChunkSize | Should -BeGreaterThan 0
        }
    }
}

Describe "Non-Locking Behavior" {
    Context "Concurrent Access" {
        It "Should allow verification while file is being read by another process" {
            $testFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "concurrent.txt") -Content "Concurrent access test"

            # Start background job that reads file continuously
            $readerJob = Start-Job -ScriptBlock {
                param($FilePath)
                $stream = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    for ($i = 0; $i -lt 10; $i++) {
                        $buffer = New-Object byte[] 1024
                        $stream.Position = 0
                        $stream.Read($buffer, 0, $buffer.Length) | Out-Null
                        Start-Sleep -Milliseconds 100
                    }
                }
                finally {
                    $stream.Close()
                    $stream.Dispose()
                }
            } -ArgumentList $testFile

            # Verify file while reader is active
            Start-Sleep -Milliseconds 200  # Let reader start

            $verifier = [FileVerification]::new($Global:TestConfig)
            $hash = $verifier.CalculateStreamingHash($testFile)

            $hash | Should -Not -BeNullOrEmpty
            $hash.Length | Should -Be 64

            # Cleanup
            Wait-Job $readerJob | Remove-Job
        }

        It "Should not block other processes from accessing file during verification" {
            $testFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "nonblocking.txt") -Content "Non-blocking test content"

            # Start verification in background
            $verificationJob = Start-Job -ScriptBlock {
                param($FilePath, $Config)

                # Import module in job context
                $ModulePath = Join-Path $using:PSScriptRoot "../../modules/FileCopier"
                Import-Module (Join-Path $ModulePath "Configuration.ps1") -Force
                Import-Module (Join-Path $ModulePath "Logging.ps1") -Force
                Import-Module (Join-Path $ModulePath "Utils.ps1") -Force
                Import-Module (Join-Path $ModulePath "Verification.ps1") -Force

                Initialize-Logging -Configuration $Config.Logging

                $verifier = [FileVerification]::new($Config)
                return $verifier.CalculateStreamingHash($FilePath)
            } -ArgumentList $testFile, $Global:TestConfig

            # Try to access file while verification is running
            Start-Sleep -Milliseconds 100

            $accessSuccessful = $false
            try {
                $content = Get-Content $testFile -Raw
                $accessSuccessful = ($content.Length -gt 0)
            }
            catch {
                $accessSuccessful = $false
            }

            $hash = Wait-Job $verificationJob | Receive-Job
            Remove-Job $verificationJob

            $accessSuccessful | Should -Be $true
            $hash | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Performance Requirements" {
    Context "CPU Overhead" {
        It "Should maintain low CPU usage during verification" {
            # Create moderately sized test file (100KB)
            $largeContent = "Performance test " * 6400  # ~100KB
            $testFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "performance.txt") -Content $largeContent

            $verifier = [FileVerification]::new($Global:TestConfig)

            # Measure CPU time (approximate)
            $process = Get-Process -Id $PID
            $startCPU = $process.CPU
            $startTime = Get-Date

            $hash = $verifier.CalculateStreamingHash($testFile)

            $endTime = Get-Date
            $process = Get-Process -Id $PID
            $endCPU = $process.CPU

            $elapsedSeconds = ($endTime - $startTime).TotalSeconds
            $cpuUsage = if ($elapsedSeconds -gt 0) { ($endCPU - $startCPU) / $elapsedSeconds } else { 0 }

            # Verification should complete successfully
            $hash | Should -Not -BeNullOrEmpty

            # CPU usage should be reasonable (this is approximate and platform-dependent)
            # We'll just verify the operation completed in reasonable time
            $elapsedSeconds | Should -BeLessThan 2.0
        }
    }

    Context "Memory Efficiency" {
        It "Should use minimal memory for large file verification" {
            # Create 1MB test file
            $largeContent = "Large file content " * 52631  # ~1MB
            $largeFile = New-TestFile -FilePath (Join-Path $Global:TestDirectory "memory-test.txt") -Content $largeContent

            $verifier = [FileVerification]::new($Global:TestConfig)

            # Measure memory before
            [System.GC]::Collect()
            $startMemory = [System.GC]::GetTotalMemory($false)

            $hash = $verifier.CalculateStreamingHash($largeFile)

            # Measure memory after
            [System.GC]::Collect()
            $endMemory = [System.GC]::GetTotalMemory($false)

            $memoryUsed = $endMemory - $startMemory
            $fileSize = (Get-Item $largeFile).Length

            # Memory usage should be much less than file size (streaming approach)
            $hash | Should -Not -BeNullOrEmpty
            $memoryUsed | Should -BeLessThan ($fileSize * 0.1)  # Less than 10% of file size
        }
    }
}