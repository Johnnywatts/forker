# Emergency Cleanup Procedures for Test Harness

class EmergencyCleanupManager {
    [string] $HarnessId
    [string[]] $KnownTempDirectories
    [hashtable] $ActiveProcesses
    [string] $CleanupLogPath

    EmergencyCleanupManager([string] $harnessId) {
        $this.HarnessId = $harnessId
        $this.KnownTempDirectories = @()
        $this.ActiveProcesses = @{}

        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.CleanupLogPath = Join-Path $tempBase "contention-cleanup-$harnessId.log"
    }

    [void] RegisterTempDirectory([string] $directory) {
        $this.KnownTempDirectories += $directory
        $this.LogCleanup("Registered temp directory: $directory")
    }

    [void] RegisterProcess([string] $processType, [int] $processId) {
        $this.ActiveProcesses[$processId] = $processType
        $this.LogCleanup("Registered process: $processType ($processId)")
    }

    [void] UnregisterProcess([int] $processId) {
        if ($this.ActiveProcesses.ContainsKey($processId)) {
            $processType = $this.ActiveProcesses[$processId]
            $this.ActiveProcesses.Remove($processId)
            $this.LogCleanup("Unregistered process: $processType ($processId)")
        }
    }

    [void] ExecuteEmergencyCleanup() {
        $this.LogCleanup("=== EMERGENCY CLEANUP STARTING ===")
        $cleanupErrors = @()

        # Clean up known temp directories
        foreach ($directory in $this.KnownTempDirectories) {
            try {
                if (Test-Path $directory) {
                    $this.LogCleanup("Cleaning temp directory: $directory")
                    Remove-Item $directory -Recurse -Force -ErrorAction Stop
                }
            }
            catch {
                $error = "Failed to clean directory $directory : $($_.Exception.Message)"
                $cleanupErrors += $error
                $this.LogCleanup("ERROR: $error")
            }
        }

        # Clean up registered processes
        foreach ($processId in $this.ActiveProcesses.Keys) {
            try {
                $processType = $this.ActiveProcesses[$processId]
                $process = Get-Process -Id $processId -ErrorAction SilentlyContinue

                if ($process -and -not $process.HasExited) {
                    $this.LogCleanup("Terminating process: $processType ($processId)")
                    Stop-Process -Id $processId -Force -ErrorAction Stop

                    # Wait for graceful exit
                    Start-Sleep -Seconds 2

                    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if ($process -and -not $process.HasExited) {
                        $this.LogCleanup("Force killing process: $processType ($processId)")
                        Stop-Process -Id $processId -Force
                    }
                }
            }
            catch {
                $error = "Failed to terminate process $processId : $($_.Exception.Message)"
                $cleanupErrors += $error
                $this.LogCleanup("ERROR: $error")
            }
        }

        # Clean up orphaned test directories
        $this.CleanupOrphanedTestDirectories()

        # Clean up PowerShell jobs
        $this.CleanupOrphanedJobs()

        $this.LogCleanup("=== EMERGENCY CLEANUP COMPLETED ===")

        if ($cleanupErrors.Count -gt 0) {
            $this.LogCleanup("Cleanup completed with $($cleanupErrors.Count) errors")
            Write-Warning "Emergency cleanup completed with errors. See log: $($this.CleanupLogPath)"
        }
    }

    [void] CleanupOrphanedTestDirectories() {
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }

        try {
            # Find all contention test directories
            $testDirs = Get-ChildItem $tempBase -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "contention-test-*" -or $_.Name -like "test-isolation-*" }

            foreach ($dir in $testDirs) {
                try {
                    # Check if directory is older than 1 hour (likely orphaned)
                    $ageHours = ((Get-Date) - $dir.CreationTime).TotalHours

                    if ($ageHours -gt 1) {
                        $this.LogCleanup("Cleaning orphaned test directory: $($dir.FullName) (age: $([math]::Round($ageHours, 1))h)")
                        Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop
                    }
                }
                catch {
                    $this.LogCleanup("ERROR: Failed to clean orphaned directory $($dir.FullName): $($_.Exception.Message)")
                }
            }
        }
        catch {
            $this.LogCleanup("ERROR: Failed to enumerate temp directories: $($_.Exception.Message)")
        }
    }

    [void] CleanupOrphanedJobs() {
        try {
            # Find jobs that might be from contention tests
            $jobs = Get-Job -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "*test*" -or $_.Name -like "*contention*"
            }

            foreach ($job in $jobs) {
                try {
                    $this.LogCleanup("Cleaning orphaned job: $($job.Name) (State: $($job.State))")

                    if ($job.State -eq "Running") {
                        Stop-Job $job -Force -ErrorAction SilentlyContinue
                    }

                    Remove-Job $job -Force -ErrorAction SilentlyContinue
                }
                catch {
                    $this.LogCleanup("ERROR: Failed to clean job $($job.Name): $($_.Exception.Message)")
                }
            }
        }
        catch {
            $this.LogCleanup("ERROR: Failed to enumerate jobs: $($_.Exception.Message)")
        }
    }

    [void] LogCleanup([string] $message) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logEntry = "$timestamp [CLEANUP] $message"

        try {
            Add-Content -Path $this.CleanupLogPath -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # If we can't log, continue anyway
        }

        # Use Write-Host for now instead of VerbosePreference
        # Write-Host $logEntry -ForegroundColor DarkGray
    }

    [void] FinalizeCleanup() {
        # Remove the cleanup log itself
        try {
            if (Test-Path $this.CleanupLogPath) {
                Remove-Item $this.CleanupLogPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Ignore cleanup log removal errors
        }
    }
}

# Global emergency cleanup function
function Invoke-EmergencyCleanup {
    param(
        [string] $HarnessId = "global"
    )

    $cleanup = [EmergencyCleanupManager]::new($HarnessId)
    $cleanup.ExecuteEmergencyCleanup()
    $cleanup.FinalizeCleanup()
}

# Register cleanup on script termination
$script:EmergencyCleanupManager = $null

function Register-EmergencyCleanup {
    param(
        [string] $HarnessId
    )

    $script:EmergencyCleanupManager = [EmergencyCleanupManager]::new($HarnessId)

    # Register exit handler
    Register-EngineEvent PowerShell.Exiting -Action {
        if ($script:EmergencyCleanupManager) {
            $script:EmergencyCleanupManager.ExecuteEmergencyCleanup()
        }
    } | Out-Null
}

function Get-EmergencyCleanupManager {
    return $script:EmergencyCleanupManager
}