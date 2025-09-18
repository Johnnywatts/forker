# RetryHandler.ps1 - Advanced retry mechanism with exponential backoff
# Part of Phase 4B: Error Handling & Recovery

using namespace System.Threading
using namespace System.Collections.Concurrent

# Retry strategy configuration
class RetryStrategy {
    [int] $MaxAttempts = 3
    [int] $BaseDelayMs = 1000
    [int] $MaxDelayMs = 300000  # 5 minutes max
    [double] $BackoffMultiplier = 2.0
    [bool] $UseJitter = $true
    [double] $JitterFactor = 0.1
    [string[]] $RetriableErrors = @()
    [string[]] $NonRetriableErrors = @()

    RetryStrategy() {}

    RetryStrategy([hashtable] $config) {
        if ($config.ContainsKey('MaxAttempts')) { $this.MaxAttempts = $config.MaxAttempts }
        if ($config.ContainsKey('BaseDelayMs')) { $this.BaseDelayMs = $config.BaseDelayMs }
        if ($config.ContainsKey('MaxDelayMs')) { $this.MaxDelayMs = $config.MaxDelayMs }
        if ($config.ContainsKey('BackoffMultiplier')) { $this.BackoffMultiplier = $config.BackoffMultiplier }
        if ($config.ContainsKey('UseJitter')) { $this.UseJitter = $config.UseJitter }
        if ($config.ContainsKey('JitterFactor')) { $this.JitterFactor = $config.JitterFactor }
        if ($config.ContainsKey('RetriableErrors')) { $this.RetriableErrors = $config.RetriableErrors }
        if ($config.ContainsKey('NonRetriableErrors')) { $this.NonRetriableErrors = $config.NonRetriableErrors }
    }
}

# Retry attempt information
class RetryAttempt {
    [int] $AttemptNumber
    [DateTime] $StartTime
    [DateTime] $EndTime
    [TimeSpan] $Duration
    [string] $Error
    [int] $DelayBeforeMs
    [bool] $Success
    [hashtable] $Context

    RetryAttempt([int] $attemptNumber) {
        $this.AttemptNumber = $attemptNumber
        $this.StartTime = Get-Date
        $this.Context = @{}
        $this.Success = $false
    }

    [void] Complete([bool] $success, [string] $error = "") {
        $this.EndTime = Get-Date
        $this.Duration = $this.EndTime - $this.StartTime
        $this.Success = $success
        $this.Error = $error
    }
}

# Result of retry operation
class RetryResult {
    [bool] $Success
    [object] $Result
    [int] $TotalAttempts
    [TimeSpan] $TotalDuration
    [RetryAttempt[]] $Attempts
    [string] $FinalError
    [bool] $WasRetriable
    [string] $FailureReason

    RetryResult() {
        $this.Attempts = @()
        $this.Success = $false
        $this.WasRetriable = $true
    }
}

# Advanced retry handler with exponential backoff and circuit breaker pattern
class RetryHandler {
    [string] $LogContext = "RetryHandler"
    [hashtable] $Config
    [hashtable] $DefaultStrategies
    [ConcurrentDictionary[string, int]] $FailureCounts
    [ConcurrentDictionary[string, DateTime]] $CircuitBreakerState
    [int] $CircuitBreakerThreshold = 10
    [int] $CircuitBreakerTimeoutMinutes = 15
    [System.Random] $Random

    RetryHandler([hashtable] $config) {
        $this.Config = $config
        $this.Random = [System.Random]::new()
        $this.FailureCounts = [ConcurrentDictionary[string, int]]::new()
        $this.CircuitBreakerState = [ConcurrentDictionary[string, DateTime]]::new()

        $this.InitializeDefaultStrategies()

        Write-FileCopierLog -Level "Information" -Message "RetryHandler initialized" -Category $this.LogContext -Properties @{
            CircuitBreakerThreshold = $this.CircuitBreakerThreshold
            CircuitBreakerTimeoutMinutes = $this.CircuitBreakerTimeoutMinutes
            StrategiesConfigured = $this.DefaultStrategies.Keys.Count
        }
    }

    # Initialize default retry strategies for different operation types
    [void] InitializeDefaultStrategies() {
        $this.DefaultStrategies = @{
            'FileSystem' = [RetryStrategy]@{
                MaxAttempts = 5
                BaseDelayMs = 2000
                MaxDelayMs = 60000  # 1 minute max
                BackoffMultiplier = 2.0
                UseJitter = $true
                RetriableErrors = @(
                    'sharing violation',
                    'file is being used',
                    'access denied',
                    'disk full'
                )
                NonRetriableErrors = @(
                    'file not found',
                    'path not found',
                    'invalid path'
                )
            }
            'Network' = [RetryStrategy]@{
                MaxAttempts = 3
                BaseDelayMs = 5000
                MaxDelayMs = 300000  # 5 minutes max
                BackoffMultiplier = 2.5
                UseJitter = $true
                RetriableErrors = @(
                    'network path not found',
                    'connection timed out',
                    'remote procedure call failed',
                    'network unreachable'
                )
                NonRetriableErrors = @(
                    'access denied',
                    'logon failure',
                    'invalid credentials'
                )
            }
            'Verification' = [RetryStrategy]@{
                MaxAttempts = 2
                BaseDelayMs = 1000
                MaxDelayMs = 10000
                BackoffMultiplier = 2.0
                UseJitter = $false
                RetriableErrors = @(
                    'file is being modified',
                    'temporary file access'
                )
                NonRetriableErrors = @(
                    'hash mismatch',
                    'file corrupted',
                    'checksum failed'
                )
            }
            'Processing' = [RetryStrategy]@{
                MaxAttempts = 3
                BaseDelayMs = 1000
                MaxDelayMs = 30000
                BackoffMultiplier = 2.0
                UseJitter = $true
                RetriableErrors = @(
                    'resource temporarily unavailable',
                    'operation in progress'
                )
                NonRetriableErrors = @(
                    'invalid operation',
                    'configuration error'
                )
            }
        }

        # Apply configuration overrides
        if ($this.Config.ContainsKey('Retry') -and $this.Config.Retry.ContainsKey('Strategies')) {
            foreach ($strategyName in $this.Config.Retry.Strategies.Keys) {
                $configStrategy = $this.Config.Retry.Strategies[$strategyName]
                if ($this.DefaultStrategies.ContainsKey($strategyName)) {
                    # Update existing strategy
                    $existing = $this.DefaultStrategies[$strategyName]
                    foreach ($prop in $configStrategy.Keys) {
                        if ($existing.PSObject.Properties.Name -contains $prop) {
                            $existing.$prop = $configStrategy[$prop]
                        }
                    }
                } else {
                    # Create new strategy
                    $this.DefaultStrategies[$strategyName] = [RetryStrategy]::new($configStrategy)
                }
            }
        }
    }

    # Execute operation with retry logic
    [RetryResult] ExecuteWithRetry([scriptblock] $operation, [string] $operationType = "Default", [hashtable] $context = @{}) {
        $result = [RetryResult]::new()
        $strategy = $this.GetRetryStrategy($operationType)

        # Check circuit breaker
        if ($this.IsCircuitBreakerOpen($operationType)) {
            $result.Success = $false
            $result.WasRetriable = $false
            $result.FailureReason = "Circuit breaker is open for operation type: $operationType"
            Write-FileCopierLog -Level "Warning" -Message $result.FailureReason -Category $this.LogContext -Properties @{
                OperationType = $operationType
                Context = $context
            }
            return $result
        }

        $startTime = Get-Date

        for ($attemptNum = 1; $attemptNum -le $strategy.MaxAttempts; $attemptNum++) {
            $attempt = [RetryAttempt]::new($attemptNum)
            $attempt.Context = $context.Clone()

            try {
                Write-FileCopierLog -Level "Debug" -Message "Executing retry attempt" -Category $this.LogContext -Properties @{
                    AttemptNumber = $attemptNum
                    MaxAttempts = $strategy.MaxAttempts
                    OperationType = $operationType
                    Context = $context
                }

                # Execute the operation
                $operationResult = & $operation

                # Success
                $attempt.Complete($true)
                $result.Attempts += $attempt
                $result.Success = $true
                $result.Result = $operationResult
                $result.TotalAttempts = $attemptNum
                $result.TotalDuration = (Get-Date) - $startTime

                # Reset failure count on success
                $this.ResetFailureCount($operationType)

                Write-FileCopierLog -Level "Information" -Message "Operation succeeded after retry" -Category $this.LogContext -Properties @{
                    OperationType = $operationType
                    AttemptNumber = $attemptNum
                    TotalDuration = $result.TotalDuration.TotalMilliseconds
                    Context = $context
                }

                return $result
            }
            catch {
                $errorMessage = $_.Exception.Message
                $attempt.Complete($false, $errorMessage)
                $result.Attempts += $attempt
                $result.FinalError = $errorMessage

                Write-FileCopierLog -Level "Warning" -Message "Retry attempt failed" -Category $this.LogContext -Properties @{
                    AttemptNumber = $attemptNum
                    MaxAttempts = $strategy.MaxAttempts
                    Error = $errorMessage
                    OperationType = $operationType
                    Context = $context
                }

                # Check if error is retriable
                if (-not $this.IsRetriableError($errorMessage, $strategy)) {
                    $result.WasRetriable = $false
                    $result.FailureReason = "Error is not retriable: $errorMessage"
                    break
                }

                # If this was the last attempt, don't wait
                if ($attemptNum -eq $strategy.MaxAttempts) {
                    break
                }

                # Calculate delay for next attempt
                $delay = $this.CalculateDelay($attemptNum, $strategy)
                $attempt.DelayBeforeMs = $delay

                Write-FileCopierLog -Level "Information" -Message "Waiting before next retry attempt" -Category $this.LogContext -Properties @{
                    AttemptNumber = $attemptNum
                    NextAttemptIn = $attemptNum + 1
                    DelayMs = $delay
                    OperationType = $operationType
                }

                # Wait with cancellation support
                Start-Sleep -Milliseconds $delay
            }
        }

        # All attempts failed
        $result.Success = $false
        $result.TotalAttempts = $strategy.MaxAttempts
        $result.TotalDuration = (Get-Date) - $startTime

        # Update circuit breaker
        $this.IncrementFailureCount($operationType)

        Write-FileCopierLog -Level "Error" -Message "All retry attempts failed" -Category $this.LogContext -Properties @{
            OperationType = $operationType
            TotalAttempts = $result.TotalAttempts
            TotalDuration = $result.TotalDuration.TotalMilliseconds
            FinalError = $result.FinalError
            WasRetriable = $result.WasRetriable
            FailureReason = $result.FailureReason
            Context = $context
        }

        return $result
    }

    # Get retry strategy for operation type
    [RetryStrategy] GetRetryStrategy([string] $operationType) {
        if ($this.DefaultStrategies.ContainsKey($operationType)) {
            return $this.DefaultStrategies[$operationType]
        }

        # Return default strategy
        return [RetryStrategy]@{
            MaxAttempts = 3
            BaseDelayMs = 1000
            MaxDelayMs = 30000
            BackoffMultiplier = 2.0
            UseJitter = $true
        }
    }

    # Check if error is retriable based on strategy
    [bool] IsRetriableError([string] $errorMessage, [RetryStrategy] $strategy) {
        $lowerError = $errorMessage.ToLowerInvariant()

        # Check non-retriable patterns first
        foreach ($pattern in $strategy.NonRetriableErrors) {
            if ($lowerError -match $pattern.ToLowerInvariant()) {
                return $false
            }
        }

        # If retriable patterns are defined, only those errors are retriable
        if ($strategy.RetriableErrors.Count -gt 0) {
            foreach ($pattern in $strategy.RetriableErrors) {
                if ($lowerError -match $pattern.ToLowerInvariant()) {
                    return $true
                }
            }
            return $false  # Not in retriable list
        }

        # If no specific patterns, assume retriable
        return $true
    }

    # Calculate delay with exponential backoff and jitter
    [int] CalculateDelay([int] $attemptNumber, [RetryStrategy] $strategy) {
        # Calculate exponential backoff
        $exponentialDelay = $strategy.BaseDelayMs * [Math]::Pow($strategy.BackoffMultiplier, $attemptNumber - 1)

        # Apply maximum delay cap
        $delay = [Math]::Min($exponentialDelay, $strategy.MaxDelayMs)

        # Add jitter if enabled
        if ($strategy.UseJitter) {
            $jitterAmount = $delay * $strategy.JitterFactor
            $jitter = ($this.Random.NextDouble() - 0.5) * 2 * $jitterAmount
            $delay = [Math]::Max(0, $delay + $jitter)
        }

        return [int]$delay
    }

    # Circuit breaker implementation
    [bool] IsCircuitBreakerOpen([string] $operationType) {
        $failureCount = 0
        if ($this.FailureCounts.TryGetValue($operationType, [ref] $failureCount)) {
            if ($failureCount -ge $this.CircuitBreakerThreshold) {
                $breakerTime = [DateTime]::MinValue
                if ($this.CircuitBreakerState.TryGetValue($operationType, [ref] $breakerTime)) {
                    $timeoutExpired = (Get-Date) -gt $breakerTime.AddMinutes($this.CircuitBreakerTimeoutMinutes)
                    if ($timeoutExpired) {
                        # Reset circuit breaker
                        $this.ResetFailureCount($operationType)
                        return $false
                    }
                    return $true
                }
            }
        }
        return $false
    }

    # Increment failure count for circuit breaker
    [void] IncrementFailureCount([string] $operationType) {
        $newCount = $this.FailureCounts.AddOrUpdate($operationType, 1, { param($key, $oldValue) return $oldValue + 1 })

        if ($newCount -eq $this.CircuitBreakerThreshold) {
            $this.CircuitBreakerState[$operationType] = Get-Date
            Write-FileCopierLog -Level "Warning" -Message "Circuit breaker opened due to repeated failures" -Category $this.LogContext -Properties @{
                OperationType = $operationType
                FailureCount = $newCount
                TimeoutMinutes = $this.CircuitBreakerTimeoutMinutes
            }
        }
    }

    # Reset failure count for circuit breaker
    [void] ResetFailureCount([string] $operationType) {
        $removed = $null
        $this.FailureCounts.TryRemove($operationType, [ref] $removed) | Out-Null
        $this.CircuitBreakerState.TryRemove($operationType, [ref] $removed) | Out-Null
    }

    # Get retry statistics
    [hashtable] GetRetryStatistics() {
        $stats = @{
            CircuitBreakerStates = @{}
            FailureCounts = @{}
            Thresholds = @{
                CircuitBreakerThreshold = $this.CircuitBreakerThreshold
                TimeoutMinutes = $this.CircuitBreakerTimeoutMinutes
            }
        }

        # Get current failure counts
        foreach ($key in $this.FailureCounts.Keys) {
            $count = 0
            if ($this.FailureCounts.TryGetValue($key, [ref] $count)) {
                $stats.FailureCounts[$key] = $count
            }
        }

        # Get circuit breaker states
        foreach ($key in $this.CircuitBreakerState.Keys) {
            $breakerTime = [DateTime]::MinValue
            if ($this.CircuitBreakerState.TryGetValue($key, [ref] $breakerTime)) {
                $stats.CircuitBreakerStates[$key] = @{
                    OpenedAt = $breakerTime
                    WillResetAt = $breakerTime.AddMinutes($this.CircuitBreakerTimeoutMinutes)
                    IsOpen = (Get-Date) -lt $breakerTime.AddMinutes($this.CircuitBreakerTimeoutMinutes)
                }
            }
        }

        return $stats
    }

    # Helper method for common retry scenarios
    [RetryResult] RetryFileOperation([scriptblock] $operation, [string] $filePath, [hashtable] $context = @{}) {
        $enhancedContext = $context.Clone()
        $enhancedContext['FilePath'] = $filePath
        $enhancedContext['OperationTime'] = Get-Date

        return $this.ExecuteWithRetry($operation, 'FileSystem', $enhancedContext)
    }

    [RetryResult] RetryNetworkOperation([scriptblock] $operation, [string] $networkPath, [hashtable] $context = @{}) {
        $enhancedContext = $context.Clone()
        $enhancedContext['NetworkPath'] = $networkPath
        $enhancedContext['OperationTime'] = Get-Date

        return $this.ExecuteWithRetry($operation, 'Network', $enhancedContext)
    }

    [RetryResult] RetryVerificationOperation([scriptblock] $operation, [string] $filePath, [hashtable] $context = @{}) {
        $enhancedContext = $context.Clone()
        $enhancedContext['FilePath'] = $filePath
        $enhancedContext['OperationTime'] = Get-Date

        return $this.ExecuteWithRetry($operation, 'Verification', $enhancedContext)
    }
}