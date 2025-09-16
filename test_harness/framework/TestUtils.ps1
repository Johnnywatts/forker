# Common Utilities for Contention Testing

# File and directory utilities
function New-TempTestDirectory {
    param(
        [string] $Prefix = "contention-test"
    )

    $tempDir = Join-Path $env:TEMP "$Prefix-$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    return $tempDir
}

function Remove-TempTestDirectory {
    param(
        [string] $Path
    )

    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-TestFile {
    param(
        [string] $Path,
        [int] $SizeBytes = 1024,
        [string] $Content = $null
    )

    if ($Content) {
        Set-Content -Path $Path -Value $Content -NoNewline
    } else {
        # Create file with specified size
        $content = "X" * $SizeBytes
        Set-Content -Path $Path -Value $content -NoNewline
    }

    return $Path
}

# Process utilities
function Start-TestProcess {
    param(
        [scriptblock] $ScriptBlock,
        [array] $ArgumentList = @(),
        [int] $TimeoutSeconds = 30
    )

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList

    return @{
        Job = $job
        TimeoutSeconds = $TimeoutSeconds
    }
}

function Wait-TestProcess {
    param(
        [object] $ProcessInfo,
        [switch] $PassThru
    )

    $result = Wait-Job $ProcessInfo.Job -Timeout $ProcessInfo.TimeoutSeconds

    if ($result) {
        $output = Receive-Job $ProcessInfo.Job
        Remove-Job $ProcessInfo.Job -Force

        if ($PassThru) {
            return @{
                Success = $true
                Output = $output
                TimedOut = $false
            }
        }
        return $output
    } else {
        # Timed out
        Stop-Job $ProcessInfo.Job -Force
        Remove-Job $ProcessInfo.Job -Force

        if ($PassThru) {
            return @{
                Success = $false
                Output = $null
                TimedOut = $true
            }
        }
        throw "Process timed out after $($ProcessInfo.TimeoutSeconds) seconds"
    }
}

# Timing utilities
function Measure-TestExecution {
    param(
        [scriptblock] $ScriptBlock,
        [array] $ArgumentList = @()
    )

    $startTime = Get-Date
    $result = & $ScriptBlock @ArgumentList
    $endTime = Get-Date

    return @{
        Result = $result
        Duration = ($endTime - $startTime).TotalSeconds
        StartTime = $startTime
        EndTime = $endTime
    }
}

function Start-TestTimer {
    return Get-Date
}

function Stop-TestTimer {
    param(
        [datetime] $StartTime
    )

    $endTime = Get-Date
    return @{
        Duration = ($endTime - $StartTime).TotalSeconds
        StartTime = $StartTime
        EndTime = $endTime
    }
}

# Validation utilities
function Test-FileContentEqual {
    param(
        [string] $FilePath1,
        [string] $FilePath2
    )

    if (-not (Test-Path $FilePath1) -or -not (Test-Path $FilePath2)) {
        return $false
    }

    $hash1 = Get-FileHash $FilePath1 -Algorithm SHA256
    $hash2 = Get-FileHash $FilePath2 -Algorithm SHA256

    return $hash1.Hash -eq $hash2.Hash
}

function Test-FileExists {
    param(
        [string] $FilePath,
        [int] $TimeoutSeconds = 5
    )

    $startTime = Get-Date
    while (((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $FilePath) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }

    return $false
}

function Wait-FileStable {
    param(
        [string] $FilePath,
        [int] $StableSeconds = 2,
        [int] $TimeoutSeconds = 30
    )

    $startTime = Get-Date
    $lastSize = -1
    $stableStart = $null

    while (((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $FilePath) {
            $currentSize = (Get-Item $FilePath).Length

            if ($currentSize -eq $lastSize) {
                if (-not $stableStart) {
                    $stableStart = Get-Date
                } elseif (((Get-Date) - $stableStart).TotalSeconds -ge $StableSeconds) {
                    return $true
                }
            } else {
                $lastSize = $currentSize
                $stableStart = $null
            }
        }

        Start-Sleep -Milliseconds 250
    }

    return $false
}

# Logging utilities
function Write-TestLog {
    param(
        [string] $Message,
        [string] $Level = "INFO",
        [string] $TestId = ""
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $prefix = if ($TestId) { "[$Level] [$TestId]" } else { "[$Level]" }

    switch ($Level) {
        "ERROR" { Write-Host "$timestamp $prefix $Message" -ForegroundColor Red }
        "WARN" { Write-Host "$timestamp $prefix $Message" -ForegroundColor Yellow }
        "INFO" { Write-Host "$timestamp $prefix $Message" -ForegroundColor Gray }
        "DEBUG" { Write-Host "$timestamp $prefix $Message" -ForegroundColor DarkGray }
        default { Write-Host "$timestamp $prefix $Message" }
    }
}

# Configuration utilities
function Get-TestConfiguration {
    param(
        [string] $ConfigPath = "config/ContentionTestConfig.json"
    )

    $fullPath = Join-Path $PSScriptRoot ".." $ConfigPath

    if (Test-Path $fullPath) {
        return Get-Content $fullPath | ConvertFrom-Json
    } else {
        Write-Warning "Configuration file not found: $fullPath"
        return @{}
    }
}

function Merge-TestConfiguration {
    param(
        [hashtable] $BaseConfig,
        [hashtable] $OverrideConfig
    )

    $merged = $BaseConfig.Clone()

    foreach ($key in $OverrideConfig.Keys) {
        $merged[$key] = $OverrideConfig[$key]
    }

    return $merged
}

# Platform utilities
function Get-PlatformInfo {
    return @{
        IsWindows = $IsWindows
        IsLinux = $IsLinux
        IsMacOS = $IsMacOS
        OSDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        ProcessArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    }
}

function Get-CrossPlatformCommand {
    param(
        [string] $WindowsCommand,
        [string] $LinuxCommand
    )

    if ($IsWindows) {
        return $WindowsCommand
    } else {
        return $LinuxCommand
    }
}