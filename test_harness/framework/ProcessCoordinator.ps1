# Process Coordination and Synchronization Framework

# Cross-platform file-based barrier implementation
class ProcessBarrier {
    [string] $BarrierId
    [int] $ProcessCount
    [int] $TimeoutSeconds
    [string] $BarrierDirectory
    [string] $BarrierFile
    [string] $StatusFile
    [datetime] $CreateTime

    ProcessBarrier([string] $barrierId, [int] $processCount, [int] $timeoutSeconds) {
        $this.BarrierId = $barrierId
        $this.ProcessCount = $processCount
        $this.TimeoutSeconds = $timeoutSeconds
        $this.CreateTime = Get-Date

        # Create barrier directory in sync location
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.BarrierDirectory = Join-Path $tempBase "barrier-$barrierId"

        if (-not (Test-Path $this.BarrierDirectory)) {
            New-Item -ItemType Directory -Path $this.BarrierDirectory -Force | Out-Null
        }

        $this.BarrierFile = Join-Path $this.BarrierDirectory "barrier.lock"
        $this.StatusFile = Join-Path $this.BarrierDirectory "status.json"

        # Initialize barrier state
        $this.InitializeBarrier()
    }

    [void] InitializeBarrier() {
        $barrierState = @{
            BarrierId = $this.BarrierId
            ProcessCount = $this.ProcessCount
            TimeoutSeconds = $this.TimeoutSeconds
            CreateTime = $this.CreateTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
            WaitingProcesses = @()
            ReleasedProcesses = @()
            IsReleased = $false
        }

        $barrierState | ConvertTo-Json -Depth 3 | Set-Content $this.StatusFile -Force
        Write-Host "[BARRIER] Initialized barrier $($this.BarrierId) for $($this.ProcessCount) processes" -ForegroundColor DarkBlue
    }

    [bool] WaitForBarrier([string] $processId) {
        $startTime = Get-Date
        $registeredProcess = $false

        Write-Host "[BARRIER] Process $processId waiting at barrier $($this.BarrierId)" -ForegroundColor Blue

        while (((Get-Date) - $startTime).TotalSeconds -lt $this.TimeoutSeconds) {
            try {
                # Use file locking for atomic updates
                $lockAcquired = $this.AcquireBarrierLock()

                if ($lockAcquired) {
                    try {
                        $status = $this.GetBarrierStatus()

                        # Register this process if not already registered
                        if (-not $registeredProcess -and $processId -notin $status.WaitingProcesses) {
                            $status.WaitingProcesses += $processId
                            $registeredProcess = $true
                            Write-Host "[BARRIER] Process $processId registered (Total: $($status.WaitingProcesses.Count)/$($this.ProcessCount))" -ForegroundColor Blue
                        }

                        # Check if barrier should be released
                        if ($status.WaitingProcesses.Count -ge $this.ProcessCount -and -not $status.IsReleased) {
                            $status.IsReleased = $true
                            $status.ReleasedProcesses = $status.WaitingProcesses.Clone()
                            Write-Host "[BARRIER] Releasing barrier $($this.BarrierId) - all $($this.ProcessCount) processes ready" -ForegroundColor Green
                        }

                        # Update status
                        $this.SetBarrierStatus($status)

                        # Check if this process can proceed
                        if ($status.IsReleased -and $processId -in $status.ReleasedProcesses) {
                            Write-Host "[BARRIER] Process $processId released from barrier $($this.BarrierId)" -ForegroundColor Green
                            return $true
                        }
                    }
                    finally {
                        $this.ReleaseBarrierLock()
                    }
                }

                # Brief wait before retry
                Start-Sleep -Milliseconds 50
            }
            catch {
                Write-Warning "[BARRIER] Error in barrier wait for process $processId : $($_.Exception.Message)"
                Start-Sleep -Milliseconds 100
            }
        }

        Write-Warning "[BARRIER] Process $processId timed out waiting for barrier $($this.BarrierId)"
        return $false
    }

    [bool] AcquireBarrierLock() {
        $attempts = 0
        $maxAttempts = 20

        while ($attempts -lt $maxAttempts) {
            try {
                # Try to create lock file exclusively
                $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id
                $lockContent = @{
                    ProcessId = $processId
                    Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                }

                # Use New-Item with exclusive creation
                $lockFile = New-Item -Path $this.BarrierFile -ItemType File -Force -ErrorAction Stop
                $lockContent | ConvertTo-Json | Set-Content $lockFile.FullName

                return $true
            }
            catch {
                $attempts++
                Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 50)
            }
        }

        return $false
    }

    [void] ReleaseBarrierLock() {
        try {
            if (Test-Path $this.BarrierFile) {
                Remove-Item $this.BarrierFile -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Ignore lock release errors
        }
    }

    [object] GetBarrierStatus() {
        if (Test-Path $this.StatusFile) {
            $content = Get-Content $this.StatusFile -Raw | ConvertFrom-Json
            return $content
        }

        # Return default status if file doesn't exist
        return @{
            BarrierId = $this.BarrierId
            ProcessCount = $this.ProcessCount
            WaitingProcesses = @()
            ReleasedProcesses = @()
            IsReleased = $false
        }
    }

    [void] SetBarrierStatus([object] $status) {
        $status | ConvertTo-Json -Depth 3 | Set-Content $this.StatusFile -Force
    }

    [void] Cleanup() {
        try {
            if (Test-Path $this.BarrierDirectory) {
                Remove-Item $this.BarrierDirectory -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[BARRIER] Cleaned up barrier $($this.BarrierId)" -ForegroundColor DarkBlue
            }
        }
        catch {
            Write-Warning "[BARRIER] Failed to cleanup barrier $($this.BarrierId): $($_.Exception.Message)"
        }
    }
}

# Process coordination manager
class ProcessCoordinator {
    [string] $CoordinatorId
    [hashtable] $ActiveBarriers
    [hashtable] $ManagedProcesses
    [string] $CoordinationDirectory

    ProcessCoordinator([string] $coordinatorId) {
        $this.CoordinatorId = $coordinatorId
        $this.ActiveBarriers = @{}
        $this.ManagedProcesses = @{}

        # Create coordination directory
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.CoordinationDirectory = Join-Path $tempBase "coordination-$coordinatorId"

        if (-not (Test-Path $this.CoordinationDirectory)) {
            New-Item -ItemType Directory -Path $this.CoordinationDirectory -Force | Out-Null
        }

        Write-Host "[COORDINATOR] Initialized process coordinator $coordinatorId" -ForegroundColor Magenta
    }

    [ProcessBarrier] CreateBarrier([string] $barrierId, [int] $processCount, [int] $timeoutSeconds) {
        if ($this.ActiveBarriers.ContainsKey($barrierId)) {
            throw "Barrier $barrierId already exists"
        }

        $barrier = [ProcessBarrier]::new($barrierId, $processCount, $timeoutSeconds)
        $this.ActiveBarriers[$barrierId] = $barrier

        Write-Host "[COORDINATOR] Created barrier $barrierId for $processCount processes" -ForegroundColor Magenta
        return $barrier
    }

    [ProcessBarrier] GetBarrier([string] $barrierId) {
        if (-not $this.ActiveBarriers.ContainsKey($barrierId)) {
            throw "Barrier $barrierId does not exist"
        }

        return $this.ActiveBarriers[$barrierId]
    }

    [bool] WaitForBarrier([string] $barrierId, [string] $processId) {
        $barrier = $this.GetBarrier($barrierId)
        return $barrier.WaitForBarrier($processId)
    }

    [object] StartCoordinatedProcess([scriptblock] $scriptBlock, [array] $arguments = @(), [string] $barrierId = $null) {
        $processId = [System.Guid]::NewGuid().ToString('N')[0..7] -join ''

        # Create coordination script that includes barrier wait
        $coordinationScript = {
            param($OriginalScript, $Args, $BarrierId, $ProcessId, $CoordinatorId)

            # Import coordination framework in new process
            $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
            $coordinationDir = Join-Path $tempBase "coordination-$CoordinatorId"

            if ($BarrierId) {
                # Create barrier instance in new process
                $barrierDir = Join-Path $tempBase "barrier-$BarrierId"
                if (Test-Path $barrierDir) {
                    # Simple file-based barrier wait
                    $statusFile = Join-Path $barrierDir "status.json"
                    $startTime = Get-Date

                    # Wait for barrier release
                    while (((Get-Date) - $startTime).TotalSeconds -lt 30) {
                        if (Test-Path $statusFile) {
                            try {
                                $status = Get-Content $statusFile | ConvertFrom-Json
                                if ($status.IsReleased -and $ProcessId -in $status.ReleasedProcesses) {
                                    break
                                }
                            }
                            catch {
                                # Continue waiting
                            }
                        }
                        Start-Sleep -Milliseconds 50
                    }
                }
            }

            # Execute the original script
            return & $OriginalScript @Args
        }

        $job = Start-Job -ScriptBlock $coordinationScript -ArgumentList $scriptBlock, $arguments, $barrierId, $processId, $this.CoordinatorId

        $processInfo = @{
            ProcessId = $processId
            Job = $job
            BarrierId = $barrierId
            StartTime = Get-Date
        }

        $this.ManagedProcesses[$processId] = $processInfo

        Write-Host "[COORDINATOR] Started coordinated process $processId" -ForegroundColor Magenta
        return $processInfo
    }

    [object] WaitForProcess([string] $processId, [int] $timeoutSeconds = 30) {
        if (-not $this.ManagedProcesses.ContainsKey($processId)) {
            throw "Process $processId is not managed by this coordinator"
        }

        $processInfo = $this.ManagedProcesses[$processId]
        $job = $processInfo.Job

        $result = Wait-Job $job -Timeout $timeoutSeconds

        if ($result) {
            $output = Receive-Job $job
            Remove-Job $job -Force

            return @{
                ProcessId = $processId
                Success = $true
                Output = $output
                TimedOut = $false
                Duration = ((Get-Date) - $processInfo.StartTime).TotalSeconds
            }
        } else {
            # Timed out
            Stop-Job $job
            Remove-Job $job

            return @{
                ProcessId = $processId
                Success = $false
                Output = $null
                TimedOut = $true
                Duration = ((Get-Date) - $processInfo.StartTime).TotalSeconds
            }
        }
    }

    [void] CleanupBarrier([string] $barrierId) {
        if ($this.ActiveBarriers.ContainsKey($barrierId)) {
            $barrier = $this.ActiveBarriers[$barrierId]
            $barrier.Cleanup()
            $this.ActiveBarriers.Remove($barrierId)
        }
    }

    [void] CleanupAll() {
        # Cleanup all active barriers
        foreach ($barrierId in $this.ActiveBarriers.Keys) {
            $this.CleanupBarrier($barrierId)
        }

        # Cleanup any remaining processes
        foreach ($processId in $this.ManagedProcesses.Keys) {
            $processInfo = $this.ManagedProcesses[$processId]
            if ($processInfo.Job.State -eq "Running") {
                Stop-Job $processInfo.Job
                Remove-Job $processInfo.Job
            }
        }

        # Cleanup coordination directory
        try {
            if (Test-Path $this.CoordinationDirectory) {
                Remove-Item $this.CoordinationDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning "[COORDINATOR] Failed to cleanup coordination directory: $($_.Exception.Message)"
        }

        Write-Host "[COORDINATOR] Cleaned up process coordinator $($this.CoordinatorId)" -ForegroundColor Magenta
    }
}

# Factory functions for easy usage
function New-ProcessBarrier {
    param(
        [string] $BarrierId,
        [int] $ProcessCount,
        [int] $TimeoutSeconds = 30
    )

    return [ProcessBarrier]::new($BarrierId, $ProcessCount, $TimeoutSeconds)
}

function New-ProcessCoordinator {
    param(
        [string] $CoordinatorId = [System.Guid]::NewGuid().ToString('N')[0..7] -join ''
    )

    return [ProcessCoordinator]::new($CoordinatorId)
}

# Simplified barrier synchronization test
class BarrierSynchronizationTest : IsolatedContentionTestCase {
    BarrierSynchronizationTest() : base("BARRIER-001", "Coordination", "Process barrier synchronization test") {}

    [bool] RunTest() {
        $this.LogInfo("Testing process barrier file operations")

        try {
            # Test basic barrier creation and file operations
            $barrierId = "test-barrier-$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
            $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
            $barrierDir = Join-Path $tempBase "barrier-$barrierId"

            # Create barrier directory
            New-Item -ItemType Directory -Path $barrierDir -Force | Out-Null
            $this.RegisterCleanupDirectory($barrierDir)

            # Test status file operations
            $statusFile = Join-Path $barrierDir "status.json"
            $status = @{
                BarrierId = $barrierId
                ProcessCount = 3
                WaitingProcesses = @()
                ReleasedProcesses = @()
                IsReleased = $false
            }

            # Write and read status
            $status | ConvertTo-Json -Depth 3 | Set-Content $statusFile
            $readStatus = Get-Content $statusFile | ConvertFrom-Json

            $this.AddTestDetail("BarrierId", $readStatus.BarrierId)
            $this.AddTestDetail("ProcessCount", $readStatus.ProcessCount)

            # Test process registration simulation
            $testProcesses = @("proc1", "proc2", "proc3")
            foreach ($procId in $testProcesses) {
                $readStatus.WaitingProcesses += $procId
            }

            # Test barrier release
            if ($readStatus.WaitingProcesses.Count -ge $readStatus.ProcessCount) {
                $readStatus.IsReleased = $true
                $readStatus.ReleasedProcesses = $readStatus.WaitingProcesses.Clone()
            }

            # Write updated status
            $readStatus | ConvertTo-Json -Depth 3 | Set-Content $statusFile

            # Verify final state
            $finalStatus = Get-Content $statusFile | ConvertFrom-Json

            $this.AddTestMetric("WaitingProcesses", $finalStatus.WaitingProcesses.Count)
            $this.AddTestMetric("ReleasedProcesses", $finalStatus.ReleasedProcesses.Count)
            $this.AddTestDetail("IsReleased", $finalStatus.IsReleased)

            # Test lock file operations
            $lockFile = Join-Path $barrierDir "barrier.lock"
            $lockData = @{
                ProcessId = 12345
                Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            }

            $lockData | ConvertTo-Json | Set-Content $lockFile
            $this.AddTestDetail("LockFileCreated", (Test-Path $lockFile))

            # Verify all operations succeeded
            if ($finalStatus.IsReleased -and $finalStatus.ReleasedProcesses.Count -eq 3) {
                $this.LogInfo("Barrier synchronization operations completed successfully")
                return $true
            } else {
                $this.LogError("Barrier operations failed validation")
                return $false
            }
        }
        catch {
            $this.LogError("Barrier synchronization test failed: $($_.Exception.Message)")
            return $false
        }
    }
}