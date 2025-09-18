# File Verification Module
# Implements non-locking file verification using streaming hash calculation
# Part of Phase 2B: Non-Locking Verification

using namespace System.Security.Cryptography
using namespace System.IO

class FileVerification {
    [string] $LogContext = "FileVerification"
    [hashtable] $Config
    [hashtable] $PerformanceCounters

    FileVerification([hashtable] $configuration) {
        $this.Config = $configuration
        $this.PerformanceCounters = @{
            VerificationCount = 0
            HashCalculationTimeMs = @()
            BytesVerified = 0
            VerificationErrors = 0
            FallbackVerifications = 0
        }

        Write-FileCopierLog -Level "Information" -Message "FileVerification module initialized" -Category $this.LogContext
    }

    # Main verification method with fallback strategies
    [hashtable] VerifyFile([string] $sourceFile, [string] $targetFile, [string] $verificationMethod = "Auto") {
        $verification = @{
            Success = $false
            Method = $verificationMethod
            SourceHash = $null
            TargetHash = $null
            FileSize = 0
            Duration = 0
            Error = $null
            UsedFallback = $false
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            Write-FileCopierLog -Level "Debug" -Message "Starting verification: $sourceFile -> $targetFile" -Category $this.LogContext

            # Check if files exist
            if (-not (Test-Path $sourceFile)) {
                throw "Source file not found: $sourceFile"
            }
            if (-not (Test-Path $targetFile)) {
                throw "Target file not found: $targetFile"
            }

            $sourceInfo = Get-Item $sourceFile
            $targetInfo = Get-Item $targetFile
            $verification.FileSize = $sourceInfo.Length

            # Choose verification method based on file size and configuration
            $actualMethod = $this.DetermineVerificationMethod($sourceInfo.Length, $verificationMethod)
            $verification.Method = $actualMethod

            switch ($actualMethod) {
                "Hash" {
                    $verification = $this.VerifyWithHash($sourceFile, $targetFile, $verification)
                }
                "SizeAndTimestamp" {
                    $verification = $this.VerifyWithSizeAndTimestamp($sourceInfo, $targetInfo, $verification)
                    $verification.UsedFallback = $true
                }
                "SizeOnly" {
                    $verification = $this.VerifyWithSizeOnly($sourceInfo, $targetInfo, $verification)
                    $verification.UsedFallback = $true
                }
                default {
                    throw "Unknown verification method: $actualMethod"
                }
            }

            if ($verification.Success) {
                Write-FileCopierLog -Level "Information" -Message "Verification successful: $($verification.Method) for $([math]::Round($verification.FileSize / 1MB, 2))MB file" -Category $this.LogContext
            }

        }
        catch {
            $verification.Success = $false
            $verification.Error = $_.Exception.Message
            $this.PerformanceCounters.VerificationErrors++
            Write-FileCopierLog -Level "Error" -Message "Verification failed: $($_.Exception.Message)" -Category $this.LogContext
        }
        finally {
            $stopwatch.Stop()
            $verification.Duration = $stopwatch.ElapsedMilliseconds
            $this.UpdatePerformanceCounters($verification)
        }

        return $verification
    }

    # Streaming SHA256 hash calculation with non-locking file access
    [hashtable] VerifyWithHash([string] $sourceFile, [string] $targetFile, [hashtable] $verification) {
        Write-FileCopierLog -Level "Debug" -Message "Using hash verification method" -Category $this.LogContext

        try {
            # Calculate hashes using streaming approach to avoid file locking
            $sourceHash = $this.CalculateStreamingHash($sourceFile)
            $targetHash = $this.CalculateStreamingHash($targetFile)

            $verification.SourceHash = $sourceHash
            $verification.TargetHash = $targetHash
            $verification.Success = ($sourceHash -eq $targetHash)

            if ($verification.Success) {
                Write-FileCopierLog -Level "Debug" -Message "Hash verification passed: $sourceHash" -Category $this.LogContext
            } else {
                Write-FileCopierLog -Level "Warning" -Message "Hash mismatch - Source: $sourceHash, Target: $targetHash" -Category $this.LogContext
            }
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Hash calculation failed, attempting fallback: $($_.Exception.Message)" -Category $this.LogContext

            # Fallback to size and timestamp verification
            $sourceInfo = Get-Item $sourceFile
            $targetInfo = Get-Item $targetFile
            $verification = $this.VerifyWithSizeAndTimestamp($sourceInfo, $targetInfo, $verification)
            $verification.UsedFallback = $true
            $verification.Method = "SizeAndTimestamp"
            $this.PerformanceCounters.FallbackVerifications++
        }

        return $verification
    }

    # Calculate SHA256 hash using streaming approach with minimal memory usage
    [string] CalculateStreamingHash([string] $filePath) {
        $hashAlgorithm = $null
        $fileStream = $null
        $retryCount = 0
        $maxRetries = $this.Config['Verification']['HashRetryAttempts']

        while ($retryCount -le $maxRetries) {
            try {
                # Use read-only access with sharing enabled to avoid locking
                $fileStream = [FileStream]::new(
                    $filePath,
                    [FileMode]::Open,
                    [FileAccess]::Read,
                    [FileShare]::ReadWrite  # Allow other processes to access file
                )

                $hashAlgorithm = [SHA256]::Create()
                $buffer = New-Object byte[] $this.Config['FileOperations']['ChunkSize']
                $totalBytesRead = 0

                while ($true) {
                    $bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)
                    if ($bytesRead -eq 0) { break }

                    $hashAlgorithm.TransformBlock($buffer, 0, $bytesRead, $null, 0) | Out-Null
                    $totalBytesRead += $bytesRead

                    # Progress callback for large files
                    if ($totalBytesRead % (10 * 1024 * 1024) -eq 0) {  # Every 10MB
                        Write-FileCopierLog -Level "Debug" -Message "Hash calculation progress: $([math]::Round($totalBytesRead / 1MB, 1))MB" -Category $this.LogContext
                    }

                    # Yield occasionally for large files to prevent blocking
                    if ($totalBytesRead % (50 * 1024 * 1024) -eq 0) {  # Every 50MB
                        Start-Sleep -Milliseconds 1
                    }
                }

                # Finalize hash calculation
                $hashAlgorithm.TransformFinalBlock(@(), 0, 0) | Out-Null
                $hashBytes = $hashAlgorithm.Hash
                $hashString = [BitConverter]::ToString($hashBytes) -replace '-', ''

                $this.PerformanceCounters.BytesVerified += $totalBytesRead

                return $hashString
            }
            catch [IOException] {
                $retryCount++
                if ($retryCount -le $maxRetries) {
                    $waitTime = [math]::Min(1000 * [math]::Pow(2, $retryCount - 1), 10000)  # Exponential backoff, max 10s
                    Write-FileCopierLog -Level "Warning" -Message "File access failed (attempt $retryCount/$($maxRetries + 1)), retrying in ${waitTime}ms: $($_.Exception.Message)" -Category $this.LogContext
                    Start-Sleep -Milliseconds $waitTime
                } else {
                    throw "Failed to access file after $($maxRetries + 1) attempts: $($_.Exception.Message)"
                }
            }
            catch {
                throw "Hash calculation error: $($_.Exception.Message)"
            }
            finally {
                if ($hashAlgorithm) { $hashAlgorithm.Dispose() }
                if ($fileStream) { $fileStream.Dispose() }
            }
        }

        throw "Maximum retry attempts exceeded for file: $filePath"
    }

    # Fallback verification using size and timestamp comparison
    [hashtable] VerifyWithSizeAndTimestamp([System.IO.FileInfo] $sourceInfo, [System.IO.FileInfo] $targetInfo, [hashtable] $verification) {
        Write-FileCopierLog -Level "Debug" -Message "Using size and timestamp verification method" -Category $this.LogContext

        try {
            # Compare file sizes
            $sizeMatch = ($sourceInfo.Length -eq $targetInfo.Length)

            # Compare last write times (with tolerance for file system precision)
            $timestampTolerance = [TimeSpan]::FromSeconds($this.Config['Verification']['TimestampToleranceSeconds'])
            $timeDifference = [Math]::Abs(($sourceInfo.LastWriteTime - $targetInfo.LastWriteTime).TotalSeconds)
            $timestampMatch = $timeDifference -le $timestampTolerance.TotalSeconds

            $verification.Success = $sizeMatch -and $timestampMatch
            $verification.SourceHash = "Size: $($sourceInfo.Length), Modified: $($sourceInfo.LastWriteTime)"
            $verification.TargetHash = "Size: $($targetInfo.Length), Modified: $($targetInfo.LastWriteTime)"

            if ($verification.Success) {
                Write-FileCopierLog -Level "Debug" -Message "Size and timestamp verification passed" -Category $this.LogContext
            } else {
                $reason = @()
                if (-not $sizeMatch) { $reason += "Size mismatch: $($sourceInfo.Length) vs $($targetInfo.Length)" }
                if (-not $timestampMatch) { $reason += "Timestamp difference: $([math]::Round($timeDifference, 2))s" }
                Write-FileCopierLog -Level "Warning" -Message "Size/timestamp verification failed: $($reason -join ', ')" -Category $this.LogContext
            }
        }
        catch {
            $verification.Success = $false
            $verification.Error = "Size/timestamp verification error: $($_.Exception.Message)"
            Write-FileCopierLog -Level "Error" -Message $verification.Error -Category $this.LogContext
        }

        return $verification
    }

    # Simple size-only verification (fastest fallback)
    [hashtable] VerifyWithSizeOnly([System.IO.FileInfo] $sourceInfo, [System.IO.FileInfo] $targetInfo, [hashtable] $verification) {
        Write-FileCopierLog -Level "Debug" -Message "Using size-only verification method" -Category $this.LogContext

        try {
            $verification.Success = ($sourceInfo.Length -eq $targetInfo.Length)
            $verification.SourceHash = "Size: $($sourceInfo.Length)"
            $verification.TargetHash = "Size: $($targetInfo.Length)"

            if ($verification.Success) {
                Write-FileCopierLog -Level "Debug" -Message "Size verification passed: $($sourceInfo.Length) bytes" -Category $this.LogContext
            } else {
                Write-FileCopierLog -Level "Warning" -Message "Size verification failed: $($sourceInfo.Length) vs $($targetInfo.Length)" -Category $this.LogContext
            }
        }
        catch {
            $verification.Success = $false
            $verification.Error = "Size verification error: $($_.Exception.Message)"
            Write-FileCopierLog -Level "Error" -Message $verification.Error -Category $this.LogContext
        }

        return $verification
    }

    # Determine optimal verification method based on file size and configuration
    [string] DetermineVerificationMethod([long] $fileSize, [string] $requestedMethod) {
        if ($requestedMethod -ne "Auto") {
            return $requestedMethod
        }

        $sizeMB = $fileSize / 1MB

        # Use configuration thresholds to determine method
        if ($sizeMB -le $this.Config['Verification']['SmallFileSizeMB']) {
            return "Hash"  # Always hash small files
        }
        elseif ($sizeMB -le $this.Config['Verification']['LargeFileSizeMB']) {
            return "Hash"  # Hash medium files if enabled
        }
        elseif ($this.Config['Verification']['EnableLargeFileHashing']) {
            return "Hash"  # Hash large files if explicitly enabled
        }
        else {
            return "SizeAndTimestamp"  # Fallback for very large files
        }
    }

    # Verify multiple targets against source with parallel processing
    [hashtable] VerifyMultipleTargets([string] $sourceFile, [string[]] $targetFiles, [string] $verificationMethod = "Auto") {
        $multiVerification = @{
            Success = $true
            SourceFile = $sourceFile
            TargetResults = @()
            OverallDuration = 0
            Method = $verificationMethod
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Write-FileCopierLog -Level "Information" -Message "Starting multi-target verification: $($targetFiles.Count) targets" -Category $this.LogContext

        try {
            # Parallel verification for multiple targets
            $jobs = @()
            foreach ($targetFile in $targetFiles) {
                $job = Start-Job -ScriptBlock {
                    param($SourceFile, $TargetFile, $Method, $Config, $LogContext)

                    # Re-create verification instance in job context
                    $verifier = [FileVerification]::new($Config)
                    return $verifier.VerifyFile($SourceFile, $TargetFile, $Method)
                } -ArgumentList $sourceFile, $targetFile, $verificationMethod, $this.Config, $this.LogContext

                $jobs += @{
                    Job = $job
                    TargetFile = $targetFile
                }
            }

            # Collect results with timeout
            $timeout = $this.Config['Verification']['MultiTargetTimeoutSeconds']
            foreach ($jobInfo in $jobs) {
                try {
                    $result = Wait-Job $jobInfo.Job -Timeout $timeout | Receive-Job
                    $result.TargetFile = $jobInfo.TargetFile
                    $multiVerification.TargetResults += $result

                    if (-not $result.Success) {
                        $multiVerification.Success = $false
                    }
                }
                catch {
                    $failedResult = @{
                        Success = $false
                        TargetFile = $jobInfo.TargetFile
                        Error = "Verification timeout or job failure: $($_.Exception.Message)"
                        Method = $verificationMethod
                        Duration = $timeout * 1000
                    }
                    $multiVerification.TargetResults += $failedResult
                    $multiVerification.Success = $false
                }
                finally {
                    Remove-Job $jobInfo.Job -Force -ErrorAction SilentlyContinue
                }
            }

            $successCount = ($multiVerification.TargetResults | Where-Object { $_.Success }).Count
            Write-FileCopierLog -Level "Information" -Message "Multi-target verification completed: $successCount/$($targetFiles.Count) successful" -Category $this.LogContext

        }
        catch {
            $multiVerification.Success = $false
            $multiVerification.Error = "Multi-target verification error: $($_.Exception.Message)"
            Write-FileCopierLog -Level "Error" -Message $multiVerification.Error -Category $this.LogContext
        }
        finally {
            $stopwatch.Stop()
            $multiVerification.OverallDuration = $stopwatch.ElapsedMilliseconds
        }

        return $multiVerification
    }

    # Performance monitoring and statistics
    [void] UpdatePerformanceCounters([hashtable] $verification) {
        $this.PerformanceCounters.VerificationCount++
        $this.PerformanceCounters.HashCalculationTimeMs += $verification.Duration

        if ($verification.UsedFallback) {
            $this.PerformanceCounters.FallbackVerifications++
        }
    }

    [hashtable] GetPerformanceStatistics() {
        $stats = $this.PerformanceCounters.Clone()

        if ($stats.HashCalculationTimeMs.Count -gt 0) {
            $times = $stats.HashCalculationTimeMs
            $stats.AverageVerificationTimeMs = ($times | Measure-Object -Average).Average
            $stats.MaxVerificationTimeMs = ($times | Measure-Object -Maximum).Maximum
            $stats.MinVerificationTimeMs = ($times | Measure-Object -Minimum).Minimum
        }

        if ($stats.BytesVerified -gt 0 -and $stats.HashCalculationTimeMs.Count -gt 0) {
            $totalTimeSeconds = ($stats.HashCalculationTimeMs | Measure-Object -Sum).Sum / 1000
            $stats.VerificationThroughputMBps = ($stats.BytesVerified / 1MB) / $totalTimeSeconds
        }

        $stats.FallbackRate = if ($stats.VerificationCount -gt 0) {
            $stats.FallbackVerifications / $stats.VerificationCount
        } else { 0 }

        return $stats
    }

    # Health check for verification system
    [hashtable] PerformHealthCheck() {
        $health = @{
            Status = "Healthy"
            Checks = @{}
            Timestamp = Get-Date
        }

        try {
            # Test configuration validity
            $health.Checks.Configuration = $this.ValidateConfiguration()

            # Test file access capabilities
            $health.Checks.FileAccess = $this.TestFileAccess()

            # Test hash calculation performance
            $health.Checks.Performance = $this.TestHashPerformance()

            # Overall health assessment
            $failedChecks = $health.Checks.Values | Where-Object { $_ -ne "OK" }
            if ($failedChecks.Count -gt 0) {
                $health.Status = "Warning"
            }

        }
        catch {
            $health.Status = "Error"
            $health.Error = $_.Exception.Message
        }

        return $health
    }

    [string] ValidateConfiguration() {
        try {
            $required = @("ChunkSize", "HashRetryAttempts", "TimestampToleranceSeconds")
            foreach ($setting in $required) {
                if (-not $this.Config['Verification'].ContainsKey($setting)) {
                    return "Missing configuration: $setting"
                }
            }
            return "OK"
        }
        catch {
            return "Configuration error: $($_.Exception.Message)"
        }
    }

    [string] TestFileAccess() {
        try {
            # Create a small test file
            $testFile = [System.IO.Path]::GetTempFileName()
            "Test content for verification health check" | Out-File $testFile

            # Test streaming hash calculation
            $hash = $this.CalculateStreamingHash($testFile)

            # Cleanup
            Remove-Item $testFile -Force

            return "OK"
        }
        catch {
            return "File access error: $($_.Exception.Message)"
        }
    }

    [string] TestHashPerformance() {
        try {
            $testData = "Performance test data " * 1000  # ~20KB
            $testFile = [System.IO.Path]::GetTempFileName()
            $testData | Out-File $testFile -Encoding UTF8

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $hash = $this.CalculateStreamingHash($testFile)
            $stopwatch.Stop()

            Remove-Item $testFile -Force

            $performanceMs = $stopwatch.ElapsedMilliseconds
            if ($performanceMs -gt 1000) {  # Warn if >1s for small file
                return "Performance warning: ${performanceMs}ms for small test file"
            }

            return "OK"
        }
        catch {
            return "Performance test error: $($_.Exception.Message)"
        }
    }
}

# Static utility functions for verification
function Compare-FileHashes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceFile,

        [Parameter(Mandatory = $true)]
        [string] $TargetFile,

        [hashtable] $Configuration = @{}
    )

    $defaultConfig = Get-DefaultVerificationConfig
    $config = Merge-ConfigurationSettings -BaseConfig $defaultConfig -OverrideConfig $Configuration

    $verifier = [FileVerification]::new($config)
    return $verifier.VerifyFile($SourceFile, $TargetFile, "Hash")
}

function Test-FileIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedHash,

        [hashtable] $Configuration = @{}
    )

    $defaultConfig = Get-DefaultVerificationConfig
    $config = Merge-ConfigurationSettings -BaseConfig $defaultConfig -OverrideConfig $Configuration

    $verifier = [FileVerification]::new($config)

    try {
        $actualHash = $verifier.CalculateStreamingHash($FilePath)
        return @{
            Success = ($actualHash -eq $ExpectedHash.ToUpper())
            ExpectedHash = $ExpectedHash.ToUpper()
            ActualHash = $actualHash
            FilePath = $FilePath
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            FilePath = $FilePath
            ExpectedHash = $ExpectedHash
        }
    }
}

function Merge-ConfigurationSettings {
    param(
        [hashtable]$BaseConfig,
        [hashtable]$OverrideConfig
    )

    $merged = $BaseConfig.Clone()
    if ($OverrideConfig) {
        foreach ($section in $OverrideConfig.Keys) {
            if ($merged.ContainsKey($section) -and $OverrideConfig[$section] -is [hashtable]) {
                foreach ($property in $OverrideConfig[$section].Keys) {
                    $merged[$section][$property] = $OverrideConfig[$section][$property]
                }
            } else {
                $merged[$section] = $OverrideConfig[$section]
            }
        }
    }
    return $merged
}

function Get-DefaultVerificationConfig {
    return @{
        Verification = @{
            HashRetryAttempts = 3
            TimestampToleranceSeconds = 2
            SmallFileSizeMB = 10
            LargeFileSizeMB = 1000
            EnableLargeFileHashing = $true
            MultiTargetTimeoutSeconds = 300
        }
        FileOperations = @{
            ChunkSize = 65536  # 64KB chunks
        }
    }
}

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed