# TestSetup.ps1 - Common test setup and utilities

# Import required modules for testing
Import-Module Pester -Force -ErrorAction Stop

# Set up test environment
$script:TestRoot = $PSScriptRoot
$script:ProjectRoot = Split-Path $TestRoot -Parent
$script:ModuleRoot = Join-Path $ProjectRoot "modules\FileCopier"
$script:ConfigRoot = Join-Path $ProjectRoot "config"
$script:TestDataRoot = Join-Path $TestRoot "TestData"

# Create test data directory if it doesn't exist
if (-not (Test-Path $TestDataRoot)) {
    New-Item -Path $TestDataRoot -ItemType Directory -Force | Out-Null
}

# Test configuration constants
$script:TestConfig = @{
    TempDirectory = Join-Path $TestDataRoot "temp"
    SourceDirectory = Join-Path $TestDataRoot "source"
    TargetADirectory = Join-Path $TestDataRoot "targetA"
    TargetBDirectory = Join-Path $TestDataRoot "targetB"
    ErrorDirectory = Join-Path $TestDataRoot "error"
    ProcessingDirectory = Join-Path $TestDataRoot "processing"
}

# Test file templates
$script:SmallTestFile = @{
    Name = "small_test.txt"
    Content = "This is a small test file for unit testing."
    Size = 41
}

$script:MediumTestFile = @{
    Name = "medium_test.svs"
    Size = 1048576  # 1MB
}

$script:ValidTestConfig = @{
    directories = @{
        source = $script:TestConfig.SourceDirectory
        targetA = $script:TestConfig.TargetADirectory
        targetB = $script:TestConfig.TargetBDirectory
        error = $script:TestConfig.ErrorDirectory
        processing = $script:TestConfig.ProcessingDirectory
    }
    monitoring = @{
        includeSubdirectories = $false
        fileFilters = @("*.svs", "*.txt")
        excludeExtensions = @(".tmp", ".temp")
        minimumFileAge = 1
        stabilityCheckInterval = 1
        maxStabilityChecks = 3
    }
    copying = @{
        maxRetries = 2
        retryDelaySeconds = @(1, 2)
        maxConcurrentCopies = 2
        preserveTimestamps = $true
        chunkSizeBytes = 65536
        verifyAfterCopy = $true
    }
    verification = @{
        method = "hash"
        hashAlgorithm = "SHA256"
        fallbackToSizeCheck = $true
        maxRetries = 2
        retryDelaySeconds = 1
        streamingHashChunkSize = 4096
    }
    logging = @{
        level = "Information"
        fileLogging = $false
        eventLogSource = "FileCopierTest"
        maxLogSizeMB = 10
        logRetentionDays = 7
        logDirectory = Join-Path $script:TestConfig.TempDirectory "logs"
        enablePerformanceLogging = $false
    }
    service = @{
        pollingIntervalSeconds = 1
        shutdownTimeoutSeconds = 10
        healthCheckIntervalMinutes = 1
        maxProcessingQueueSize = 100
        enableHotConfigReload = $true
    }
}

function Initialize-TestEnvironment {
    <#
    .SYNOPSIS
        Initializes the test environment by creating necessary directories and files.
    #>
    [CmdletBinding()]
    param()

    # Clean up any existing test environment
    Cleanup-TestEnvironment

    # Create test directories
    foreach ($dir in $script:TestConfig.Values) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    Write-Verbose "Test environment initialized"
}

function Cleanup-TestEnvironment {
    <#
    .SYNOPSIS
        Cleans up the test environment by removing test directories and files.
    #>
    [CmdletBinding()]
    param()

    # Remove test directories if they exist
    foreach ($dir in $script:TestConfig.Values) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction Continue
            }
            catch {
                # Ignore cleanup errors in tests
                Write-Warning "Failed to cleanup directory: $dir"
            }
        }
    }

    Write-Verbose "Test environment cleaned up"
}

function New-TestFile {
    <#
    .SYNOPSIS
        Creates a test file with specified content or size.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Content,
        [int]$SizeBytes,
        [switch]$Binary
    )

    $directory = Split-Path $Path -Parent
    if (-not (Test-Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    if ($Content) {
        $Content | Out-File -FilePath $Path -Encoding UTF8
    }
    elseif ($SizeBytes -gt 0) {
        if ($Binary) {
            # Create binary test data
            $bytes = New-Object byte[] $SizeBytes
            (New-Object Random).NextBytes($bytes)
            [System.IO.File]::WriteAllBytes($Path, $bytes)
        }
        else {
            # Create text test data
            $chunk = "This is test data for file size testing. " * 100
            $content = ""
            while ($content.Length -lt $SizeBytes) {
                $content += $chunk
            }
            $content = $content.Substring(0, $SizeBytes)
            $content | Out-File -FilePath $Path -Encoding UTF8 -NoNewline
        }
    }
    else {
        # Create empty file
        New-Item -Path $Path -ItemType File -Force | Out-Null
    }

    return Get-Item $Path
}

function Test-FilesIdentical {
    <#
    .SYNOPSIS
        Tests if two files are identical by comparing their hash values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path1,

        [Parameter(Mandatory)]
        [string]$Path2
    )

    if (-not (Test-Path $Path1) -or -not (Test-Path $Path2)) {
        return $false
    }

    try {
        $hash1 = Get-FileHash -Path $Path1 -Algorithm SHA256
        $hash2 = Get-FileHash -Path $Path2 -Algorithm SHA256
        return $hash1.Hash -eq $hash2.Hash
    }
    catch {
        return $false
    }
}

function Wait-ForCondition {
    <#
    .SYNOPSIS
        Waits for a condition to become true with timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$Condition,

        [int]$TimeoutSeconds = 10,
        [int]$IntervalMilliseconds = 100,
        [string]$Description = "Condition"
    )

    $timeout = [DateTime]::Now.AddSeconds($TimeoutSeconds)

    while ([DateTime]::Now -lt $timeout) {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }

    throw "Timeout waiting for $Description after $TimeoutSeconds seconds"
}

function Assert-DirectoryExists {
    <#
    .SYNOPSIS
        Asserts that a directory exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Message = "Directory should exist: $Path"
    )

    if (-not (Test-Path $Path -PathType Container)) {
        throw $Message
    }
}

function Assert-FileExists {
    <#
    .SYNOPSIS
        Asserts that a file exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Message = "File should exist: $Path"
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw $Message
    }
}

function Assert-FileNotExists {
    <#
    .SYNOPSIS
        Asserts that a file does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Message = "File should not exist: $Path"
    )

    if (Test-Path $Path) {
        throw $Message
    }
}

# Test utilities are available when this script is dot-sourced