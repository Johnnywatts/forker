# File Locking Test Framework for Multi-Process Contention Testing

# Base class for file locking contention tests
class FileLockingTestCase : IsolatedContentionTestCase {
    [string] $SourceFile
    [string] $TargetFile
    [string] $TestDataSize
    [object] $ProcessCoordinator  # ProcessCoordinator instance
    [object] $SharedState        # SharedStateManager instance

    FileLockingTestCase([string] $testId, [string] $description) : base($testId, "FileLocking", $description) {
        $this.TestDataSize = "1MB"  # Default test data size
        $this.ProcessCoordinator = $null
        $this.SharedState = $null
    }

    [void] InitializeFileLocking() {
        # Create process coordinator for multi-process testing
        $coordinatorId = "$($this.TestId)-coordinator"
        $this.ProcessCoordinator = New-ProcessCoordinator -CoordinatorId $coordinatorId
        $this.RegisterCleanupResource("ProcessCoordinator", $this.ProcessCoordinator)

        # Create shared state for process communication
        $stateId = "$($this.TestId)-state"
        $this.SharedState = New-SharedStateManager -StateId $stateId
        $this.RegisterCleanupResource("SharedStateManager", $this.SharedState)

        # Create test files in isolation directory
        $workingDir = $this.IsolationContext.WorkingDirectory
        $this.SourceFile = Join-Path $workingDir "source-file.dat"
        $this.TargetFile = Join-Path $workingDir "target-file.dat"

        # Create source file with test data
        $this.CreateTestFile($this.SourceFile, $this.TestDataSize)

        $this.LogInfo("File locking test initialized with $($this.TestDataSize) test file")
        $this.AddTestDetail("SourceFile", $this.SourceFile)
        $this.AddTestDetail("TargetFile", $this.TargetFile)
    }

    [void] CreateTestFile([string] $filePath, [string] $size) {
        $sizeBytes = $this.ParseSize($size)
        $data = New-Object byte[] $sizeBytes

        # Fill with recognizable pattern for integrity validation
        for ($i = 0; $i -lt $sizeBytes; $i++) {
            $data[$i] = $i % 256
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

    [bool] ValidateFileIntegrity([string] $filePath) {
        if (-not (Test-Path $filePath)) {
            return $false
        }

        try {
            $fileInfo = Get-Item $filePath
            $data = [System.IO.File]::ReadAllBytes($filePath)

            # Validate file size and pattern
            $expectedSize = $this.ParseSize($this.TestDataSize)
            if ($data.Length -ne $expectedSize) {
                $this.LogError("File size mismatch: expected $expectedSize, got $($data.Length)")
                return $false
            }

            # Validate data pattern (every 100th byte for performance)
            for ($i = 0; $i -lt $data.Length; $i += 100) {
                $expectedValue = $i % 256
                if ($data[$i] -ne $expectedValue) {
                    $this.LogError("Data corruption detected at offset $i : expected $expectedValue, got $($data[$i])")
                    return $false
                }
            }

            return $true
        }
        catch {
            $this.LogError("File integrity validation failed: $($_.Exception.Message)")
            return $false
        }
    }

    [hashtable] GetFileLockInfo([string] $filePath) {
        # Cross-platform file lock detection
        $lockInfo = @{
            FilePath = $filePath
            IsLocked = $false
            LockedBy = $null
            LockType = $null
            Accessible = $true
        }

        try {
            # Try to open file for write access to detect locks
            $fileStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $fileStream.Close()
            $lockInfo.IsLocked = $false
        }
        catch [System.IO.IOException] {
            $lockInfo.IsLocked = $true
            $lockInfo.LockType = "WriteExclusive"
        }
        catch [System.UnauthorizedAccessException] {
            $lockInfo.IsLocked = $true
            $lockInfo.LockType = "ReadOnly"
        }
        catch {
            $lockInfo.Accessible = $false
            $lockInfo.LockType = "Unknown"
        }

        return $lockInfo
    }

    [object] CreateFileCopyProcess([string] $sourceFile, [string] $targetFile, [string] $processId) {
        $copyScript = {
            param($SourcePath, $TargetPath, $ProcessId, $StateId)

            try {
                # Initialize shared state in process
                $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
                $stateDir = Join-Path $tempBase "shared-state-$StateId"
                $stateFile = Join-Path $stateDir "state.json"

                # Signal process start
                $startTime = Get-Date
                $result = @{
                    ProcessId = $ProcessId
                    StartTime = $startTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                    Status = "Started"
                }

                # Attempt file copy with streaming
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

                $endTime = Get-Date
                $duration = ($endTime - $startTime).TotalSeconds

                $result.Status = "Completed"
                $result.EndTime = $endTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                $result.Duration = $duration
                $result.BytesCopied = $totalBytes
                $result.Success = $true

                return $result
            }
            catch {
                # Cleanup streams if they exist
                try { $sourceStream.Close() } catch { }
                try { $targetStream.Close() } catch { }

                $result.Status = "Failed"
                $result.Error = $_.Exception.Message
                $result.Success = $false
                return $result
            }
        }

        $stateId = $this.SharedState.StateId
        return $this.ProcessCoordinator.StartCoordinatedProcess($copyScript, @($sourceFile, $targetFile, $processId, $stateId), $null)
    }

    [object] CreateFileReadProcess([string] $filePath, [string] $processId) {
        $readScript = {
            param($FilePath, $ProcessId, $StateId)

            try {
                $startTime = Get-Date
                $result = @{
                    ProcessId = $ProcessId
                    StartTime = $startTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                    Status = "Started"
                }

                # Attempt file read
                $data = [System.IO.File]::ReadAllBytes($FilePath)

                $endTime = Get-Date
                $duration = ($endTime - $startTime).TotalSeconds

                $result.Status = "Completed"
                $result.EndTime = $endTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                $result.Duration = $duration
                $result.BytesRead = $data.Length
                $result.Success = $true

                return $result
            }
            catch {
                $result.Status = "Failed"
                $result.Error = $_.Exception.Message
                $result.Success = $false
                return $result
            }
        }

        $stateId = $this.SharedState.StateId
        return $this.ProcessCoordinator.StartCoordinatedProcess($readScript, @($filePath, $processId, $stateId), $null)
    }

    [object] CreateFileDeleteProcess([string] $filePath, [string] $processId) {
        $deleteScript = {
            param($FilePath, $ProcessId, $StateId)

            try {
                $startTime = Get-Date
                $result = @{
                    ProcessId = $ProcessId
                    StartTime = $startTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                    Status = "Started"
                }

                # Attempt file deletion
                Remove-Item $FilePath -Force -ErrorAction Stop

                $endTime = Get-Date
                $duration = ($endTime - $startTime).TotalSeconds

                $result.Status = "Completed"
                $result.EndTime = $endTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
                $result.Duration = $duration
                $result.Success = $true

                return $result
            }
            catch {
                $result.Status = "Failed"
                $result.Error = $_.Exception.Message
                $result.Success = $false
                return $result
            }
        }

        $stateId = $this.SharedState.StateId
        return $this.ProcessCoordinator.StartCoordinatedProcess($deleteScript, @($filePath, $processId, $stateId), $null)
    }

    [bool] WaitForProcessCompletion([object] $processInfo, [int] $timeoutSeconds = 30) {
        $result = $this.ProcessCoordinator.WaitForProcess($processInfo.ProcessId, $timeoutSeconds)

        if ($result.Success -and $result.Output -ne $null) {
            $this.AddTestDetail("Process-$($processInfo.ProcessId)", $result.Output)
            return $result.Output.Success -eq $true
        }
        elseif ($result.TimedOut) {
            $this.LogError("Process $($processInfo.ProcessId) timed out after $timeoutSeconds seconds")
            return $false
        }
        else {
            $this.LogError("Process $($processInfo.ProcessId) failed to complete")
            return $false
        }
    }

    [void] ValidateTestPreconditions() {
        # Ensure test files exist and are accessible
        if (-not (Test-Path $this.SourceFile)) {
            throw "Source file not found: $($this.SourceFile)"
        }

        # Ensure target file does not exist
        if (Test-Path $this.TargetFile) {
            Remove-Item $this.TargetFile -Force
        }

        # Validate file integrity
        if (-not $this.ValidateFileIntegrity($this.SourceFile)) {
            throw "Source file integrity validation failed"
        }

        $this.LogInfo("Test preconditions validated")
    }

    # Override base RunTest method to include file locking initialization
    [bool] RunTest() {
        try {
            # Ensure working directory is available before file operations
            if (-not $this.IsolationContext.WorkingDirectory) {
                $this.LogError("Working directory not initialized")
                return $false
            }

            $this.InitializeFileLocking()
            $this.ValidateTestPreconditions()
            return $this.ExecuteFileLockingTest()
        }
        catch {
            $this.LogError("File locking test setup failed: $($_.Exception.Message)")
            return $false
        }
    }

    # Abstract method that must be implemented by specific tests
    [bool] ExecuteFileLockingTest() {
        throw "ExecuteFileLockingTest must be implemented by derived classes"
    }
}