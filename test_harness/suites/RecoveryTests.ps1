# Recovery Test Suite for Contention Testing
# Tests system recovery and cleanup under failure conditions

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")

# Base class for recovery tests
class RecoveryTestBase {
    [string] $TestId
    [string] $TestTempDirectory
    [array] $ManagedProcesses
    [array] $TempFiles
    [array] $FileLocks
    [hashtable] $RecoveryConfig

    RecoveryTestBase([string] $testId) {
        $this.TestId = $testId
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.TestTempDirectory = Join-Path $tempBase "RecoveryTest-$testId-$(Get-Random)"
        $this.ManagedProcesses = @()
        $this.TempFiles = @()
        $this.FileLocks = @()
        $this.RecoveryConfig = @{
            ProcessTerminationTimeout = 5000    # 5 seconds
            CleanupValidationTimeout = 3000     # 3 seconds
            FileCleanupRetries = 3
            ProcessCleanupRetries = 3
        }
    }

    [void] SetupTest() {
        try {
            # Create test directory
            if (-not (Test-Path $this.TestTempDirectory)) {
                New-Item -ItemType Directory -Path $this.TestTempDirectory -Force | Out-Null
                Write-TestLog -Message "Created test directory: $($this.TestTempDirectory)" -Level "INFO" -TestId $this.TestId
            }

            Write-TestLog -Message "Recovery test framework initialized" -Level "INFO" -TestId $this.TestId
        }
        catch {
            throw "Failed to setup recovery test: $($_.Exception.Message)"
        }
    }

    [void] CleanupTest() {
        try {
            # Terminate any remaining processes
            $this.TerminateAllManagedProcesses()

            # Clean up file locks
            $this.ReleaseAllFileLocks()

            # Clean up temporary files
            $this.CleanupTempFiles()

            # Clean up test directory
            if (Test-Path $this.TestTempDirectory) {
                Remove-Item -Path $this.TestTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-TestLog -Message "Recovery test cleanup completed" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Recovery test cleanup failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
    }

    # Process management methods
    [object] CreateManagedProcess([string] $processName, [string] $command, [array] $arguments = @()) {
        $processInfo = @{
            Name = $processName
            Command = $command
            Arguments = $arguments
            Process = $null
            ProcessId = $null
            StartTime = $null
            IsRunning = $false
            TempFiles = @()
            FileLocks = @()
        }

        $this.ManagedProcesses += $processInfo
        Write-TestLog -Message "Created managed process: $processName" -Level "INFO" -TestId $this.TestId
        return $processInfo
    }

    [void] StartManagedProcess([object] $processInfo) {
        try {
            # Start process
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = $processInfo.Command
            $processStartInfo.Arguments = $processInfo.Arguments -join " "
            $processStartInfo.UseShellExecute = $false
            $processStartInfo.CreateNoWindow = $true
            $processStartInfo.RedirectStandardOutput = $true
            $processStartInfo.RedirectStandardError = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processStartInfo

            $success = $process.Start()
            if (-not $success) {
                throw "Failed to start process $($processInfo.Name)"
            }

            $processInfo.Process = $process
            $processInfo.ProcessId = $process.Id
            $processInfo.StartTime = Get-Date
            $processInfo.IsRunning = $true

            Write-TestLog -Message "Started managed process: $($processInfo.Name) (PID: $($process.Id))" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Failed to start managed process $($processInfo.Name): $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
            throw
        }
    }

    [void] TerminateManagedProcess([object] $processInfo, [bool] $forceful = $false) {
        try {
            if ($processInfo.Process -and -not $processInfo.Process.HasExited) {
                Write-TestLog -Message "Terminating managed process: $($processInfo.Name) (PID: $($processInfo.ProcessId))" -Level "INFO" -TestId $this.TestId

                if ($forceful) {
                    # Force kill the process
                    $processInfo.Process.Kill()
                    Write-TestLog -Message "Force-killed process: $($processInfo.Name)" -Level "INFO" -TestId $this.TestId
                } else {
                    # Try graceful termination first
                    try {
                        $processInfo.Process.CloseMainWindow()
                        if (-not $processInfo.Process.WaitForExit($this.RecoveryConfig.ProcessTerminationTimeout)) {
                            Write-TestLog -Message "Graceful termination timeout, force-killing process: $($processInfo.Name)" -Level "WARN" -TestId $this.TestId
                            $processInfo.Process.Kill()
                        }
                    }
                    catch {
                        Write-TestLog -Message "Graceful termination failed, force-killing process: $($processInfo.Name)" -Level "WARN" -TestId $this.TestId
                        $processInfo.Process.Kill()
                    }
                }

                # Wait for process to actually terminate
                $processInfo.Process.WaitForExit(2000)
            }

            $processInfo.IsRunning = $false
            Write-TestLog -Message "Process terminated: $($processInfo.Name)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Failed to terminate process $($processInfo.Name): $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
    }

    [void] TerminateAllManagedProcesses() {
        foreach ($processInfo in $this.ManagedProcesses) {
            if ($processInfo.IsRunning) {
                $this.TerminateManagedProcess($processInfo, $true)
            }
        }
    }

    # File management methods
    [string] CreateTempFile([string] $fileName, [string] $content = "") {
        $filePath = Join-Path $this.TestTempDirectory $fileName

        try {
            Set-Content -Path $filePath -Value $content -Encoding UTF8
            $this.TempFiles += $filePath
            Write-TestLog -Message "Created temp file: $filePath" -Level "INFO" -TestId $this.TestId
            return $filePath
        }
        catch {
            Write-TestLog -Message "Failed to create temp file ${filePath}: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
            throw
        }
    }

    [object] CreateFileLock([string] $filePath, [string] $lockType = "Exclusive") {
        try {
            $fileStream = switch ($lockType) {
                "Exclusive" {
                    [System.IO.File]::Open($filePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                }
                "Read" {
                    [System.IO.File]::Open($filePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                }
                "Write" {
                    [System.IO.File]::Open($filePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                }
                default {
                    throw "Unknown lock type: $lockType"
                }
            }

            $lockInfo = @{
                FilePath = $filePath
                LockType = $lockType
                FileStream = $fileStream
                CreatedAt = Get-Date
            }

            $this.FileLocks += $lockInfo
            Write-TestLog -Message "Created file lock: $filePath ($lockType)" -Level "INFO" -TestId $this.TestId
            return $lockInfo
        }
        catch {
            Write-TestLog -Message "Failed to create file lock ${filePath} (${lockType}): $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
            throw
        }
    }

    [void] ReleaseFileLock([object] $lockInfo) {
        try {
            if ($lockInfo.FileStream) {
                $lockInfo.FileStream.Close()
                $lockInfo.FileStream.Dispose()
                $lockInfo.FileStream = $null
            }
            Write-TestLog -Message "Released file lock: $($lockInfo.FilePath)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            Write-TestLog -Message "Failed to release file lock $($lockInfo.FilePath) - $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
    }

    [void] ReleaseAllFileLocks() {
        foreach ($lockInfo in $this.FileLocks) {
            if ($lockInfo.FileStream) {
                $this.ReleaseFileLock($lockInfo)
            }
        }
    }

    [void] CleanupTempFiles() {
        foreach ($filePath in $this.TempFiles) {
            try {
                if (Test-Path $filePath) {
                    Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
                    Write-TestLog -Message "Cleaned up temp file: $filePath" -Level "INFO" -TestId $this.TestId
                }
            }
            catch {
                Write-TestLog -Message "Failed to cleanup temp file ${filePath} - $($_.Exception.Message)" -Level "WARN" -TestId $this.TestId
            }
        }
    }

    # Recovery validation methods
    [hashtable] ValidateSystemCleanup() {
        $validation = @{
            Success = $true
            ProcessesClean = $true
            FilesClean = $true
            LocksClean = $true
            Issues = @()
        }

        try {
            # Check for orphaned processes
            foreach ($processInfo in $this.ManagedProcesses) {
                if ($processInfo.ProcessId) {
                    $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
                    if ($process -and -not $process.HasExited) {
                        $validation.ProcessesClean = $false
                        $validation.Issues += "Orphaned process found: $($processInfo.Name) (PID: $($processInfo.ProcessId))"
                    }
                }
            }

            # Check for leaked files
            $remainingFiles = @()
            foreach ($filePath in $this.TempFiles) {
                if (Test-Path $filePath) {
                    $remainingFiles += $filePath
                }
            }

            if ($remainingFiles.Count -gt 0) {
                $validation.FilesClean = $false
                $validation.Issues += "Leaked files found: $($remainingFiles.Count) files not cleaned up"
            }

            # Check for unreleased file locks
            $activeLocks = @()
            foreach ($lockInfo in $this.FileLocks) {
                if ($lockInfo.FileStream) {
                    $activeLocks += $lockInfo.FilePath
                }
            }

            if ($activeLocks.Count -gt 0) {
                $validation.LocksClean = $false
                $validation.Issues += "Unreleased file locks found: $($activeLocks.Count) locks still active"
            }

            $validation.Success = $validation.ProcessesClean -and $validation.FilesClean -and $validation.LocksClean

            Write-TestLog -Message "System cleanup validation: Success=$($validation.Success)" -Level "INFO" -TestId $this.TestId
            if ($validation.Issues.Count -gt 0) {
                foreach ($issue in $validation.Issues) {
                    Write-TestLog -Message "Cleanup issue: $issue" -Level "WARN" -TestId $this.TestId
                }
            }
        }
        catch {
            $validation.Success = $false
            $validation.Issues += "Validation error: $($_.Exception.Message)"
            Write-TestLog -Message "System cleanup validation failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $validation
    }

    [hashtable] SimulateProcessTermination([string] $processName) {
        $simulation = @{
            Success = $false
            ProcessName = $processName
            StartTime = Get-Date
            EndTime = $null
            Details = @{}
        }

        try {
            Write-TestLog -Message "Simulating process termination: $processName" -Level "INFO" -TestId $this.TestId

            $processInfo = $this.ManagedProcesses | Where-Object { $_.Name -eq $processName } | Select-Object -First 1
            if (-not $processInfo) {
                throw "Managed process not found: $processName"
            }

            if (-not $processInfo.IsRunning) {
                throw "Process is not running: $processName"
            }

            # Simulate sudden termination
            $this.TerminateManagedProcess($processInfo, $true)

            $simulation.Details.ProcessId = $processInfo.ProcessId
            $simulation.Details.TerminationType = "Forceful"
            $simulation.EndTime = Get-Date
            $simulation.Success = $true

            Write-TestLog -Message "Process termination simulation completed: $processName" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $simulation.EndTime = Get-Date
            $simulation.Details.Error = $_.Exception.Message
            Write-TestLog -Message "Process termination simulation failed: $processName - $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $simulation
    }
}

# Utility functions for recovery testing
function Test-ProcessCleanup {
    param(
        [array] $ExpectedProcessIds,
        [int] $TimeoutSeconds = 10
    )

    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    $orphanedProcesses = @()

    while ((Get-Date) -lt $endTime) {
        $orphanedProcesses = @()

        foreach ($processId in $ExpectedProcessIds) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($process -and -not $process.HasExited) {
                $orphanedProcesses += $processId
            }
        }

        if ($orphanedProcesses.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 500
    }

    return @{
        Success = ($orphanedProcesses.Count -eq 0)
        OrphanedProcesses = $orphanedProcesses
        TimeoutReached = ((Get-Date) -ge $endTime)
    }
}

function Test-FileCleanup {
    param(
        [array] $ExpectedFiles,
        [int] $TimeoutSeconds = 5
    )

    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    $remainingFiles = @()

    while ((Get-Date) -lt $endTime) {
        $remainingFiles = @()

        foreach ($filePath in $ExpectedFiles) {
            if (Test-Path $filePath) {
                $remainingFiles += $filePath
            }
        }

        if ($remainingFiles.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 200
    }

    return @{
        Success = ($remainingFiles.Count -eq 0)
        RemainingFiles = $remainingFiles
        TimeoutReached = ((Get-Date) -ge $endTime)
    }
}

function Test-FileLockRelease {
    param(
        [string] $FilePath,
        [int] $TimeoutSeconds = 5
    )

    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    $lockReleased = $false

    while ((Get-Date) -lt $endTime -and -not $lockReleased) {
        try {
            # Try to open the file exclusively to test if lock is released
            $testStream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $testStream.Close()
            $testStream.Dispose()
            $lockReleased = $true
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }

    return @{
        Success = $lockReleased
        TimeoutReached = ((Get-Date) -ge $endTime)
    }
}

Write-TestLog -Message "Recovery test framework loaded successfully" -Level "INFO" -TestId "RECOVERY"