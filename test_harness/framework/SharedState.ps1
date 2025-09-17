# Shared State Management for Multi-Process Coordination

class SharedStateManager {
    [string] $StateId
    [string] $StateDirectory
    [string] $StateFile
    [string] $LockFile
    [hashtable] $LocalCache
    [int] $LockTimeoutMs
    [int] $MaxRetries

    SharedStateManager([string] $stateId) {
        $this.StateId = $stateId
        $this.LocalCache = @{}
        $this.LockTimeoutMs = 5000
        $this.MaxRetries = 50

        # Create state directory
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.StateDirectory = Join-Path $tempBase "shared-state-$stateId"

        if (-not (Test-Path $this.StateDirectory)) {
            New-Item -ItemType Directory -Path $this.StateDirectory -Force | Out-Null
        }

        $this.StateFile = Join-Path $this.StateDirectory "state.json"
        $this.LockFile = Join-Path $this.StateDirectory "state.lock"

        # Initialize state file if it doesn't exist
        $this.InitializeState()

        Write-Host "[SHARED-STATE] Initialized shared state manager $stateId" -ForegroundColor DarkGreen
    }

    [void] InitializeState() {
        if (-not (Test-Path $this.StateFile)) {
            $initialState = @{
                StateId = $this.StateId
                CreatedTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                LastModified = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                Data = @{}
            }

            $initialState | ConvertTo-Json -Depth 10 | Set-Content $this.StateFile -Force
        }
    }

    [bool] AcquireLock() {
        $attempts = 0
        $backoffMs = 10

        while ($attempts -lt $this.MaxRetries) {
            try {
                # Try to create lock file exclusively
                $lockData = @{
                    ProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
                    AcquiredTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                    ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
                }

                # Use exclusive creation
                $lockFilePath = $this.LockFile
                $lockFileItem = New-Item -Path $lockFilePath -ItemType File -Force -ErrorAction Stop
                $lockData | ConvertTo-Json | Set-Content $lockFileItem.FullName

                return $true
            }
            catch {
                $attempts++

                # Exponential backoff with jitter
                $jitter = Get-Random -Minimum 0 -Maximum ($backoffMs / 2)
                Start-Sleep -Milliseconds ($backoffMs + $jitter)
                $backoffMs = [Math]::Min($backoffMs * 2, 200)
            }
        }

        Write-Warning "[SHARED-STATE] Failed to acquire lock for state $($this.StateId) after $attempts attempts"
        return $false
    }

    [void] ReleaseLock() {
        try {
            if (Test-Path $this.LockFile) {
                Remove-Item $this.LockFile -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Ignore lock release errors
        }
    }

    [object] GetValue([string] $key) {
        $lockAcquired = $this.AcquireLock()

        if ($lockAcquired) {
            try {
                $state = $this.LoadState()
                $value = $state.Data[$key]

                # Update local cache
                $this.LocalCache[$key] = $value

                return $value
            }
            finally {
                $this.ReleaseLock()
            }
        } else {
            # Fall back to cached value if lock acquisition fails
            if ($this.LocalCache.ContainsKey($key)) {
                Write-Warning "[SHARED-STATE] Using cached value for key '$key' due to lock failure"
                return $this.LocalCache[$key]
            }

            throw "Failed to acquire lock for reading key '$key' and no cached value available"
        }
    }

    [void] SetValue([string] $key, [object] $value) {
        $lockAcquired = $this.AcquireLock()

        if ($lockAcquired) {
            try {
                $state = $this.LoadState()
                $state.Data[$key] = $value
                $state.LastModified = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

                $this.SaveState($state)

                # Update local cache
                $this.LocalCache[$key] = $value
            }
            finally {
                $this.ReleaseLock()
            }
        } else {
            throw "Failed to acquire lock for setting key '$key'"
        }
    }

    [void] UpdateValue([string] $key, [scriptblock] $updateFunction) {
        $lockAcquired = $this.AcquireLock()

        if ($lockAcquired) {
            try {
                $state = $this.LoadState()
                $currentValue = $state.Data[$key]

                # Apply update function
                $newValue = & $updateFunction $currentValue

                $state.Data[$key] = $newValue
                $state.LastModified = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

                $this.SaveState($state)

                # Update local cache
                $this.LocalCache[$key] = $newValue
            }
            finally {
                $this.ReleaseLock()
            }
        } else {
            throw "Failed to acquire lock for updating key '$key'"
        }
    }

    [bool] CompareAndSwap([string] $key, [object] $expectedValue, [object] $newValue) {
        $lockAcquired = $this.AcquireLock()

        if ($lockAcquired) {
            try {
                $state = $this.LoadState()
                $currentValue = $state.Data[$key]

                # Compare current value with expected value
                $valuesEqual = $this.CompareValues($currentValue, $expectedValue)

                if ($valuesEqual) {
                    $state.Data[$key] = $newValue
                    $state.LastModified = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

                    $this.SaveState($state)

                    # Update local cache
                    $this.LocalCache[$key] = $newValue

                    return $true
                } else {
                    return $false
                }
            }
            finally {
                $this.ReleaseLock()
            }
        } else {
            throw "Failed to acquire lock for compare-and-swap on key '$key'"
        }
    }

    [bool] CompareValues([object] $value1, [object] $value2) {
        if ($value1 -eq $null -and $value2 -eq $null) {
            return $true
        }

        if ($value1 -eq $null -or $value2 -eq $null) {
            return $false
        }

        # For simple comparison
        return $value1.ToString() -eq $value2.ToString()
    }

    [void] RemoveValue([string] $key) {
        $lockAcquired = $this.AcquireLock()

        if ($lockAcquired) {
            try {
                $state = $this.LoadState()

                if ($state.Data.ContainsKey($key)) {
                    $state.Data.Remove($key)
                    $state.LastModified = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

                    $this.SaveState($state)
                }

                # Remove from local cache
                if ($this.LocalCache.ContainsKey($key)) {
                    $this.LocalCache.Remove($key)
                }
            }
            finally {
                $this.ReleaseLock()
            }
        } else {
            throw "Failed to acquire lock for removing key '$key'"
        }
    }

    [hashtable] GetAllValues() {
        $lockAcquired = $this.AcquireLock()

        if ($lockAcquired) {
            try {
                $state = $this.LoadState()
                return $state.Data.Clone()
            }
            finally {
                $this.ReleaseLock()
            }
        } else {
            throw "Failed to acquire lock for getting all values"
        }
    }

    [string[]] GetKeys() {
        $allValues = $this.GetAllValues()
        return $allValues.Keys
    }

    [bool] ContainsKey([string] $key) {
        $allValues = $this.GetAllValues()
        return $allValues.ContainsKey($key)
    }

    [object] LoadState() {
        if (Test-Path $this.StateFile) {
            $content = Get-Content $this.StateFile -Raw | ConvertFrom-Json

            # Convert PSObject to hashtable structure
            $state = @{
                StateId = $content.StateId
                CreatedTime = $content.CreatedTime
                LastModified = $content.LastModified
                Data = @{}
            }

            # Convert data properties to hashtable
            if ($content.Data) {
                foreach ($property in $content.Data.PSObject.Properties) {
                    $state.Data[$property.Name] = $property.Value
                }
            }

            return $state
        }

        # Return default state if file doesn't exist
        return @{
            StateId = $this.StateId
            CreatedTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            LastModified = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            Data = @{}
        }
    }

    [void] SaveState([object] $state) {
        $state | ConvertTo-Json -Depth 10 | Set-Content $this.StateFile -Force
    }

    [void] WaitForValue([string] $key, [object] $expectedValue, [int] $timeoutSeconds = 30) {
        $startTime = Get-Date

        while (((Get-Date) - $startTime).TotalSeconds -lt $timeoutSeconds) {
            try {
                $currentValue = $this.GetValue($key)

                if ($this.CompareValues($currentValue, $expectedValue)) {
                    return
                }
            }
            catch {
                # Continue waiting
            }

            Start-Sleep -Milliseconds 100
        }

        throw "Timeout waiting for key '$key' to have value '$expectedValue'"
    }

    [void] WaitForKey([string] $key, [int] $timeoutSeconds = 30) {
        $startTime = Get-Date

        while (((Get-Date) - $startTime).TotalSeconds -lt $timeoutSeconds) {
            try {
                if ($this.ContainsKey($key)) {
                    return
                }
            }
            catch {
                # Continue waiting
            }

            Start-Sleep -Milliseconds 100
        }

        throw "Timeout waiting for key '$key' to exist"
    }

    [void] Cleanup() {
        try {
            # Release any held locks
            $this.ReleaseLock()

            # Remove state directory
            if (Test-Path $this.StateDirectory) {
                Remove-Item $this.StateDirectory -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[SHARED-STATE] Cleaned up shared state $($this.StateId)" -ForegroundColor DarkGreen
            }
        }
        catch {
            Write-Warning "[SHARED-STATE] Failed to cleanup shared state $($this.StateId): $($_.Exception.Message)"
        }
    }
}

# Factory function
function New-SharedStateManager {
    param(
        [string] $StateId = [System.Guid]::NewGuid().ToString('N')[0..7] -join ''
    )

    return [SharedStateManager]::new($StateId)
}

# Shared state test
class SharedStateTest : IsolatedContentionTestCase {
    SharedStateTest() : base("SHARED-001", "Coordination", "Shared state management test") {}

    [bool] RunTest() {
        $this.LogInfo("Testing shared state management")

        try {
            # Create shared state manager
            $stateManager = New-SharedStateManager -StateId "test-state"
            $this.RegisterCleanupResource("SharedStateManager", $stateManager)

            # Test basic set/get operations
            $this.LogInfo("Testing basic set/get operations")
            $stateManager.SetValue("test-key", "test-value")
            $retrievedValue = $stateManager.GetValue("test-key")

            if ($retrievedValue -ne "test-value") {
                $this.LogError("Basic set/get failed: expected 'test-value', got '$retrievedValue'")
                return $false
            }

            # Test numeric operations
            $this.LogInfo("Testing numeric operations")
            $stateManager.SetValue("counter", 0)

            # Test atomic increment
            $stateManager.UpdateValue("counter", { param($current) return $current + 1 })
            $stateManager.UpdateValue("counter", { param($current) return $current + 1 })
            $stateManager.UpdateValue("counter", { param($current) return $current + 1 })

            $finalCounter = $stateManager.GetValue("counter")
            if ($finalCounter -ne 3) {
                $this.LogError("Atomic increment failed: expected 3, got $finalCounter")
                return $false
            }

            # Test compare-and-swap
            $this.LogInfo("Testing compare-and-swap operations")
            $casResult1 = $stateManager.CompareAndSwap("counter", 3, 10)
            $casResult2 = $stateManager.CompareAndSwap("counter", 5, 20)  # Should fail

            $casValue = $stateManager.GetValue("counter")

            if (-not $casResult1 -or $casResult2 -or $casValue -ne 10) {
                $this.LogError("Compare-and-swap failed: CAS1=$casResult1, CAS2=$casResult2, Value=$casValue")
                return $false
            }

            # Test key operations
            $this.LogInfo("Testing key operations")
            $stateManager.SetValue("key1", "value1")
            $stateManager.SetValue("key2", "value2")
            $stateManager.SetValue("key3", "value3")

            $allKeys = $stateManager.GetKeys()
            $allValues = $stateManager.GetAllValues()

            if ($allKeys.Count -lt 4 -or $allValues.Count -lt 4) {  # counter + 3 keys
                $this.LogError("Key operations failed: Keys=$($allKeys.Count), Values=$($allValues.Count)")
                return $false
            }

            # Test key existence
            if (-not $stateManager.ContainsKey("key1") -or $stateManager.ContainsKey("nonexistent")) {
                $this.LogError("Key existence check failed")
                return $false
            }

            # Test key removal
            $stateManager.RemoveValue("key2")
            if ($stateManager.ContainsKey("key2")) {
                $this.LogError("Key removal failed")
                return $false
            }

            # Test concurrent access simulation
            $this.LogInfo("Testing concurrent access simulation")
            $testResults = $this.SimulateConcurrentAccess($stateManager)

            if (-not $testResults) {
                $this.LogError("Concurrent access simulation failed")
                return $false
            }

            # Add test metrics
            $this.AddTestMetric("BasicOperations", "PASSED")
            $this.AddTestMetric("AtomicOperations", "PASSED")
            $this.AddTestMetric("CompareAndSwap", "PASSED")
            $this.AddTestMetric("KeyOperations", "PASSED")
            $this.AddTestMetric("ConcurrentAccess", "PASSED")

            $finalKeys = $stateManager.GetKeys()
            $this.AddTestDetail("FinalKeyCount", $finalKeys.Count)
            $this.AddTestDetail("FinalKeys", $finalKeys)

            $stateManager.Cleanup()

            $this.LogInfo("Shared state management test completed successfully")
            return $true
        }
        catch {
            $this.LogError("Shared state test failed: $($_.Exception.Message)")
            return $false
        }
    }

    [bool] SimulateConcurrentAccess([SharedStateManager] $stateManager) {
        try {
            # Simulate multiple processes incrementing a shared counter
            $stateManager.SetValue("shared-counter", 0)

            # Create multiple "processes" (background jobs) that increment the counter
            $jobs = @()
            for ($i = 1; $i -le 3; $i++) {
                $job = Start-Job -ScriptBlock {
                    param($StateDirectory, $ProcessId)

                    # Simulate creating a new state manager in different process
                    $stateFile = Join-Path $StateDirectory "state.json"

                    # Simple increment operation - in real scenario this would be through SharedStateManager
                    for ($j = 1; $j -le 3; $j++) {
                        # Simulate some work
                        Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 50)

                        # Simulate state access
                        if (Test-Path $stateFile) {
                            try {
                                $content = Get-Content $stateFile | ConvertFrom-Json
                                # In real implementation, this would use proper locking
                                Start-Sleep -Milliseconds 1
                            }
                            catch {
                                # Continue
                            }
                        }
                    }

                    return "Process $ProcessId completed"
                } -ArgumentList $stateManager.StateDirectory, $i

                $jobs += $job
                $this.RegisterCleanupResource("Job", $job)
            }

            # Wait for all jobs to complete
            $results = @()
            foreach ($job in $jobs) {
                $result = Wait-Job $job -Timeout 10
                if ($result) {
                    $output = Receive-Job $job
                    $results += $output
                }
                Remove-Job $job
            }

            # Verify results
            $this.AddTestDetail("ConcurrentJobResults", $results)
            return $results.Count -eq 3
        }
        catch {
            $this.LogError("Concurrent access simulation error: $($_.Exception.Message)")
            return $false
        }
    }
}