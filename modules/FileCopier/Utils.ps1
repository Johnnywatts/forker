# Utils.ps1 - Utility functions for File Copier Service

#region File System Utilities
function Test-DirectoryAccess {
    <#
    .SYNOPSIS
        Tests if a directory is accessible for read/write operations.

    .DESCRIPTION
        Performs comprehensive directory access testing including read, write, and create permissions.

    .PARAMETER Path
        Directory path to test.

    .PARAMETER RequiredAccess
        Required access level: Read, Write, or Full.

    .EXAMPLE
        Test-DirectoryAccess -Path "C:\Source" -RequiredAccess "Read"

    .EXAMPLE
        Test-DirectoryAccess -Path "C:\Target" -RequiredAccess "Full"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("Read", "Write", "Full")]
        [string]$RequiredAccess
    )

    $result = @{
        Path = $Path
        Exists = $false
        CanRead = $false
        CanWrite = $false
        CanCreate = $false
        IsAccessible = $false
        Error = $null
    }

    try {
        # Check if directory exists
        $result.Exists = Test-Path $Path -PathType Container

        if ($result.Exists) {
            # Test read access
            try {
                Get-ChildItem $Path -ErrorAction Stop | Out-Null
                $result.CanRead = $true
            }
            catch {
                $result.Error = "Cannot read directory: $($_.Exception.Message)"
            }

            # Test write access if read is successful
            if ($result.CanRead -and ($RequiredAccess -eq "Write" -or $RequiredAccess -eq "Full")) {
                try {
                    $testFile = Join-Path $Path "._test_access_$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
                    "test" | Out-File $testFile -ErrorAction Stop
                    Remove-Item $testFile -ErrorAction Stop
                    $result.CanWrite = $true
                }
                catch {
                    $result.Error = "Cannot write to directory: $($_.Exception.Message)"
                }
            }
        }
        else {
            # Test if we can create the directory
            $parentPath = Split-Path $Path -Parent
            if ($parentPath -and (Test-Path $parentPath)) {
                try {
                    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    Remove-Item -Path $Path -Force -ErrorAction Stop
                    $result.CanCreate = $true
                }
                catch {
                    $result.Error = "Cannot create directory: $($_.Exception.Message)"
                }
            }
            else {
                $result.Error = "Parent directory does not exist: $parentPath"
            }
        }

        # Determine overall accessibility
        switch ($RequiredAccess) {
            "Read" { $result.IsAccessible = $result.CanRead }
            "Write" { $result.IsAccessible = $result.CanRead -and $result.CanWrite }
            "Full" { $result.IsAccessible = ($result.CanRead -and $result.CanWrite) -or $result.CanCreate }
        }

        return $result
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Get-FileStability {
    <#
    .SYNOPSIS
        Checks if a file is stable (not being written to).

    .DESCRIPTION
        Monitors file size and modification time to determine if a file is still being written.

    .PARAMETER FilePath
        Path to the file to check.

    .PARAMETER CheckInterval
        Interval between checks in seconds.

    .PARAMETER MaxChecks
        Maximum number of stability checks.

    .EXAMPLE
        Get-FileStability -FilePath "C:\Source\file.svs" -CheckInterval 2 -MaxChecks 5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [int]$CheckInterval = 2,
        [int]$MaxChecks = 5
    )

    if (-not (Test-Path $FilePath)) {
        return @{
            IsStable = $false
            Error = "File not found: $FilePath"
        }
    }

    try {
        $previousSize = -1
        $previousModified = [DateTime]::MinValue
        $checksPerformed = 0

        for ($i = 0; $i -lt $MaxChecks; $i++) {
            $checksPerformed++
            $fileInfo = Get-Item $FilePath -ErrorAction Stop

            if ($i -eq 0) {
                $previousSize = $fileInfo.Length
                $previousModified = $fileInfo.LastWriteTime
                Start-Sleep -Seconds $CheckInterval
                continue
            }

            if ($fileInfo.Length -eq $previousSize -and $fileInfo.LastWriteTime -eq $previousModified) {
                return @{
                    IsStable = $true
                    ChecksPerformed = $checksPerformed
                    FinalSize = $fileInfo.Length
                    FinalModified = $fileInfo.LastWriteTime
                }
            }

            $previousSize = $fileInfo.Length
            $previousModified = $fileInfo.LastWriteTime

            if ($i -lt ($MaxChecks - 1)) {
                Start-Sleep -Seconds $CheckInterval
            }
        }

        return @{
            IsStable = $false
            ChecksPerformed = $checksPerformed
            Error = "File still changing after $MaxChecks checks"
            FinalSize = $previousSize
            FinalModified = $previousModified
        }
    }
    catch {
        return @{
            IsStable = $false
            ChecksPerformed = $checksPerformed
            Error = $_.Exception.Message
        }
    }
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Generates a safe filename by removing/replacing invalid characters.

    .DESCRIPTION
        Sanitizes a filename to ensure it's valid for Windows file systems.

    .PARAMETER FileName
        Original filename to sanitize.

    .PARAMETER Replacement
        Character to replace invalid characters with.

    .EXAMPLE
        Get-SafeFileName -FileName "file:name*.txt"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [char]$Replacement = '_'
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeName = $FileName

    foreach ($char in $invalidChars) {
        $safeName = $safeName.Replace($char, $Replacement)
    }

    # Remove any double replacements
    while ($safeName.Contains("$Replacement$Replacement")) {
        $safeName = $safeName.Replace("$Replacement$Replacement", "$Replacement")
    }

    return $safeName.Trim($Replacement)
}
#endregion

#region Performance Utilities
function Measure-ExecutionTime {
    <#
    .SYNOPSIS
        Measures execution time of a script block.

    .DESCRIPTION
        Executes a script block and returns execution time along with the result.

    .PARAMETER ScriptBlock
        Script block to execute and measure.

    .PARAMETER Description
        Description of the operation being measured.

    .EXAMPLE
        Measure-ExecutionTime -ScriptBlock { Copy-Item "source.txt" "dest.txt" } -Description "File copy"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,

        [string]$Description = "Operation"
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $error = $null

    try {
        $result = & $ScriptBlock
    }
    catch {
        $error = $_.Exception
    }
    finally {
        $stopwatch.Stop()
    }

    return @{
        Result = $result
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
        Description = $Description
        Error = $error
    }
}

function Get-MemoryUsage {
    <#
    .SYNOPSIS
        Gets current memory usage for the PowerShell process.

    .DESCRIPTION
        Returns memory usage information for monitoring and debugging.

    .EXAMPLE
        Get-MemoryUsage
    #>
    [CmdletBinding()]
    param()

    $process = Get-Process -Id $PID
    $workingSet = $process.WorkingSet64
    $privateMemory = $process.PrivateMemorySize64

    return @{
        WorkingSetMB = [Math]::Round($workingSet / 1MB, 2)
        PrivateMemoryMB = [Math]::Round($privateMemory / 1MB, 2)
        Timestamp = Get-Date
        ProcessId = $PID
    }
}
#endregion

#region String Utilities
function Format-ByteSize {
    <#
    .SYNOPSIS
        Formats byte size into human-readable format.

    .DESCRIPTION
        Converts byte values to KB, MB, GB, etc. with appropriate units.

    .PARAMETER Bytes
        Number of bytes to format.

    .PARAMETER Precision
        Decimal precision for the result.

    .EXAMPLE
        Format-ByteSize -Bytes 1048576
        # Returns "1.00 MB"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$Bytes,

        [int]$Precision = 2
    )

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $unitIndex = 0

    [double]$size = $Bytes
    while ($size -ge 1024 -and $unitIndex -lt ($units.Length - 1)) {
        $size /= 1024
        $unitIndex++
    }

    return "{0:N$Precision} {1}" -f $size, $units[$unitIndex]
}

function Format-Duration {
    <#
    .SYNOPSIS
        Formats a TimeSpan into human-readable format.

    .DESCRIPTION
        Converts TimeSpan objects to readable duration strings.

    .PARAMETER TimeSpan
        TimeSpan to format.

    .PARAMETER ShowMilliseconds
        Include milliseconds in the output.

    .EXAMPLE
        Format-Duration -TimeSpan (New-TimeSpan -Seconds 125)
        # Returns "2m 5s"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$TimeSpan,

        [switch]$ShowMilliseconds
    )

    $parts = @()

    if ($TimeSpan.Days -gt 0) {
        $parts += "$($TimeSpan.Days)d"
    }
    if ($TimeSpan.Hours -gt 0) {
        $parts += "$($TimeSpan.Hours)h"
    }
    if ($TimeSpan.Minutes -gt 0) {
        $parts += "$($TimeSpan.Minutes)m"
    }
    if ($TimeSpan.Seconds -gt 0 -or $parts.Count -eq 0) {
        $parts += "$($TimeSpan.Seconds)s"
    }
    if ($ShowMilliseconds -and $TimeSpan.Milliseconds -gt 0) {
        $parts += "$($TimeSpan.Milliseconds)ms"
    }

    return $parts -join " "
}
#endregion

#region Retry Utilities
function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with retry logic.

    .DESCRIPTION
        Retries a script block execution with configurable delays and retry counts.

    .PARAMETER ScriptBlock
        Script block to execute.

    .PARAMETER MaxRetries
        Maximum number of retry attempts.

    .PARAMETER RetryDelays
        Array of delay seconds for each retry attempt.

    .PARAMETER Description
        Description of the operation for logging.

    .EXAMPLE
        Invoke-WithRetry -ScriptBlock { Copy-Item "source" "dest" } -MaxRetries 3 -RetryDelays @(1,5,15)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,

        [int]$MaxRetries = 3,
        [int[]]$RetryDelays = @(1, 5, 15),
        [string]$Description = "Operation"
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            $result = & $ScriptBlock
            if ($attempt -gt 0) {
                Write-Verbose "$Description succeeded on attempt $($attempt + 1)"
            }
            return $result
        }
        catch {
            $lastError = $_
            $attempt++

            if ($attempt -le $MaxRetries) {
                $delay = if ($attempt -le $RetryDelays.Count) { $RetryDelays[$attempt - 1] } else { $RetryDelays[-1] }
                Write-Warning "$Description failed on attempt $attempt`: $($_.Exception.Message). Retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
            }
        }
    }

    Write-Error "$Description failed after $($attempt) attempts. Last error: $($lastError.Exception.Message)"
    throw $lastError
}
#endregion

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed