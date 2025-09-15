# CopyEngine.ps1 - Streaming file copy functionality for large files

#region Module Variables
$script:CopyOperations = @{}  # Track active copy operations
$script:CopyStats = @{
    TotalFilesCopied = 0
    TotalBytesCopied = 0
    AverageSpeed = 0
    LastCopyDuration = 0
}
#endregion

#region Core Copy Functions

<#
.SYNOPSIS
    Copies a file using streaming I/O for memory efficiency with large files.

.DESCRIPTION
    Implements chunked file copying with progress tracking, designed for large SVS files.
    Uses configurable chunk sizes and preserves file attributes and timestamps.

.PARAMETER SourcePath
    Full path to the source file to copy.

.PARAMETER DestinationPath
    Full path where the file should be copied.

.PARAMETER ChunkSizeBytes
    Size of chunks to read/write at a time. Defaults to configuration value.

.PARAMETER PreserveTimestamps
    Whether to preserve original file timestamps. Defaults to configuration value.

.PARAMETER OperationId
    Unique identifier for tracking this copy operation.

.PARAMETER ProgressCallback
    Script block to call for progress updates.

.EXAMPLE
    Copy-FileStreaming -SourcePath "C:\source\large.svs" -DestinationPath "C:\target\large.svs"

.NOTES
    Designed for large file efficiency with minimal memory footprint.
#>
function Copy-FileStreaming {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [int]$ChunkSizeBytes,

        [bool]$PreserveTimestamps,

        [string]$OperationId = [System.Guid]::NewGuid().ToString(),

        [scriptblock]$ProgressCallback
    )

    begin {
        Write-FileCopierLog -Message "Starting streaming copy operation" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
            SourcePath = $SourcePath
            DestinationPath = $DestinationPath
            ChunkSizeBytes = $ChunkSizeBytes
        }

        # Get configuration if parameters not specified
        if (-not $PSBoundParameters.ContainsKey('ChunkSizeBytes')) {
            $copyConfig = Get-FileCopierConfig -Section "copying"
            $ChunkSizeBytes = $copyConfig.chunkSizeBytes
        }

        if (-not $PSBoundParameters.ContainsKey('PreserveTimestamps')) {
            $copyConfig = Get-FileCopierConfig -Section "copying"
            $PreserveTimestamps = $copyConfig.preserveTimestamps
        }

        # Initialize operation tracking
        $script:CopyOperations[$OperationId] = @{
            SourcePath = $SourcePath
            DestinationPath = $DestinationPath
            StartTime = Get-Date
            BytesCopied = 0
            TotalBytes = 0
            Status = "Initializing"
        }
    }

    process {
        try {
            # Validate source file exists
            if (-not (Test-Path -Path $SourcePath -PathType Leaf)) {
                throw "Source file not found: $SourcePath"
            }

            # Get source file info
            $sourceFile = Get-Item -Path $SourcePath
            $totalBytes = $sourceFile.Length
            $script:CopyOperations[$OperationId].TotalBytes = $totalBytes

            Write-FileCopierLog -Message "Source file validated" -Level "Debug" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                FileSize = $totalBytes
                FileName = $sourceFile.Name
            }

            # Ensure destination directory exists
            $destinationDir = Split-Path -Path $DestinationPath -Parent
            if (-not (Test-Path -Path $destinationDir)) {
                New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
                Write-FileCopierLog -Message "Created destination directory" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                    Directory = $destinationDir
                }
            }

            # Create temporary destination path for atomic operation
            $tempDestination = $DestinationPath + ".tmp"

            # Initialize streams
            $sourceStream = $null
            $destinationStream = $null
            $buffer = New-Object byte[] $ChunkSizeBytes
            $bytesCopied = 0

            try {
                # Open source file for reading
                $sourceStream = [System.IO.File]::OpenRead($SourcePath)

                # Open destination file for writing
                $destinationStream = [System.IO.File]::Create($tempDestination)

                $script:CopyOperations[$OperationId].Status = "Copying"

                Write-FileCopierLog -Message "Started streaming copy" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                    ChunkSize = $ChunkSizeBytes
                    TotalSize = $totalBytes
                }

                # Streaming copy loop
                do {
                    $bytesRead = $sourceStream.Read($buffer, 0, $ChunkSizeBytes)
                    if ($bytesRead -gt 0) {
                        $destinationStream.Write($buffer, 0, $bytesRead)
                        $bytesCopied += $bytesRead
                        $script:CopyOperations[$OperationId].BytesCopied = $bytesCopied

                        # Progress callback
                        if ($ProgressCallback -and $totalBytes -gt 0) {
                            $percentComplete = ($bytesCopied / $totalBytes) * 100
                            & $ProgressCallback -BytesCopied $bytesCopied -TotalBytes $totalBytes -PercentComplete $percentComplete -OperationId $OperationId
                        }

                        # Log progress for large files (every 100MB)
                        if ($bytesCopied % 104857600 -eq 0 -and $bytesCopied -gt 0) {
                            $percentComplete = [math]::Round(($bytesCopied / $totalBytes) * 100, 1)
                            Write-FileCopierLog -Message "Copy progress" -Level "Debug" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                                BytesCopied = $bytesCopied
                                PercentComplete = $percentComplete
                            }
                        }
                    }
                } while ($bytesRead -gt 0)

                # Ensure all data is written
                $destinationStream.Flush()
                $destinationStream.Close()
                $sourceStream.Close()

                # Verify copy completed successfully
                if ($bytesCopied -ne $totalBytes) {
                    throw "Copy incomplete: copied $bytesCopied bytes, expected $totalBytes bytes"
                }

                # Final progress callback (ensure 100% is always reported)
                if ($ProgressCallback -and $totalBytes -gt 0) {
                    & $ProgressCallback -BytesCopied $bytesCopied -TotalBytes $totalBytes -PercentComplete 100 -OperationId $OperationId
                }

                Write-FileCopierLog -Message "Streaming copy completed" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                    BytesCopied = $bytesCopied
                    Success = $true
                }

                # Preserve timestamps if requested
                if ($PreserveTimestamps) {
                    $tempFile = Get-Item -Path $tempDestination
                    $tempFile.CreationTime = $sourceFile.CreationTime
                    $tempFile.LastWriteTime = $sourceFile.LastWriteTime
                    $tempFile.LastAccessTime = $sourceFile.LastAccessTime

                    Write-FileCopierLog -Message "Preserved file timestamps" -Level "Debug" -Category "CopyEngine" -OperationId $OperationId
                }

                # Atomic move to final destination
                Move-Item -Path $tempDestination -Destination $DestinationPath -Force

                $script:CopyOperations[$OperationId].Status = "Completed"

                # Update global statistics
                $script:CopyStats.TotalFilesCopied++
                $script:CopyStats.TotalBytesCopied += $bytesCopied
                $copyDuration = ((Get-Date) - $script:CopyOperations[$OperationId].StartTime).TotalSeconds
                $script:CopyStats.LastCopyDuration = $copyDuration

                if ($copyDuration -gt 0) {
                    $speed = $bytesCopied / $copyDuration
                    $script:CopyStats.AverageSpeed = ($script:CopyStats.AverageSpeed + $speed) / 2
                }

                Write-FileCopierLog -Message "File copy operation completed successfully" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                    FinalPath = $DestinationPath
                    Duration = $copyDuration
                    Speed = if ($copyDuration -gt 0) { [math]::Round($bytesCopied / $copyDuration / 1MB, 2) } else { 0 }
                    SpeedUnit = "MB/s"
                }

                return @{
                    Success = $true
                    BytesCopied = $bytesCopied
                    Duration = $copyDuration
                    AverageSpeed = if ($copyDuration -gt 0) { $bytesCopied / $copyDuration } else { 0 }
                    OperationId = $OperationId
                }

            }
            finally {
                # Cleanup streams
                if ($sourceStream) {
                    $sourceStream.Dispose()
                }
                if ($destinationStream) {
                    $destinationStream.Dispose()
                }

                # Cleanup temporary file if it exists
                if (Test-Path -Path $tempDestination) {
                    try {
                        Remove-Item -Path $tempDestination -Force
                        Write-FileCopierLog -Message "Cleaned up temporary file" -Level "Debug" -Category "CopyEngine" -OperationId $OperationId
                    }
                    catch {
                        Write-FileCopierLog -Message "Failed to cleanup temporary file" -Level "Warning" -Category "CopyEngine" -OperationId $OperationId -Exception $_.Exception
                    }
                }
            }

        }
        catch {
            $script:CopyOperations[$OperationId].Status = "Failed"

            Write-FileCopierLog -Message "File copy operation failed" -Level "Error" -Category "CopyEngine" -OperationId $OperationId -Exception $_.Exception -Properties @{
                SourcePath = $SourcePath
                DestinationPath = $DestinationPath
                BytesCopied = $script:CopyOperations[$OperationId].BytesCopied
            }

            return @{
                Success = $false
                Error = $_.Exception.Message
                BytesCopied = $script:CopyOperations[$OperationId].BytesCopied
                OperationId = $OperationId
            }
        }
        finally {
            # Keep operation record for a short time for monitoring
            Start-Job -ScriptBlock {
                param($OpId)
                Start-Sleep -Seconds 300  # Keep for 5 minutes
                if ($script:CopyOperations.ContainsKey($OpId)) {
                    $script:CopyOperations.Remove($OpId)
                }
            } -ArgumentList $OperationId | Out-Null
        }
    }
}

<#
.SYNOPSIS
    Copies a file to multiple destinations simultaneously.

.DESCRIPTION
    Efficiently copies a single source file to multiple target destinations using
    streaming I/O. Reads the source file once and writes to multiple streams.

.PARAMETER SourcePath
    Full path to the source file to copy.

.PARAMETER DestinationPaths
    Array of destination paths where the file should be copied.

.PARAMETER ChunkSizeBytes
    Size of chunks to read/write at a time.

.PARAMETER PreserveTimestamps
    Whether to preserve original file timestamps.

.PARAMETER OperationId
    Unique identifier for tracking this copy operation.

.PARAMETER ProgressCallback
    Script block to call for progress updates.

.EXAMPLE
    Copy-FileToMultipleDestinations -SourcePath "C:\source\file.svs" -DestinationPaths @("C:\targetA\file.svs", "C:\targetB\file.svs")

.NOTES
    More efficient than multiple individual copy operations for the same source file.
#>
function Copy-FileToMultipleDestinations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string[]]$DestinationPaths,

        [int]$ChunkSizeBytes,

        [bool]$PreserveTimestamps,

        [string]$OperationId = [System.Guid]::NewGuid().ToString(),

        [scriptblock]$ProgressCallback
    )

    begin {
        Write-FileCopierLog -Message "Starting multi-destination streaming copy" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
            SourcePath = $SourcePath
            DestinationCount = $DestinationPaths.Count
            Destinations = ($DestinationPaths -join "; ")
        }

        # Get configuration if parameters not specified
        if (-not $PSBoundParameters.ContainsKey('ChunkSizeBytes')) {
            $copyConfig = Get-FileCopierConfig -Section "copying"
            $ChunkSizeBytes = $copyConfig.chunkSizeBytes
        }

        if (-not $PSBoundParameters.ContainsKey('PreserveTimestamps')) {
            $copyConfig = Get-FileCopierConfig -Section "copying"
            $PreserveTimestamps = $copyConfig.preserveTimestamps
        }
    }

    process {
        try {
            # Validate source file
            if (-not (Test-Path -Path $SourcePath -PathType Leaf)) {
                throw "Source file not found: $SourcePath"
            }

            $sourceFile = Get-Item -Path $SourcePath
            $totalBytes = $sourceFile.Length

            # Prepare temporary destination paths
            $tempDestinations = @()
            $destinationStreams = @()

            foreach ($destPath in $DestinationPaths) {
                $destDir = Split-Path -Path $destPath -Parent
                if (-not (Test-Path -Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }
                $tempDestinations += "$destPath.tmp"
            }

            $sourceStream = $null
            $buffer = New-Object byte[] $ChunkSizeBytes
            $bytesCopied = 0

            try {
                # Open source stream
                $sourceStream = [System.IO.File]::OpenRead($SourcePath)

                # Open all destination streams
                foreach ($tempDest in $tempDestinations) {
                    $destinationStreams += [System.IO.File]::Create($tempDest)
                }

                Write-FileCopierLog -Message "Started multi-destination streaming copy" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                    StreamsOpened = $destinationStreams.Count
                    TotalSize = $totalBytes
                }

                # Streaming copy loop - read once, write to all destinations
                do {
                    $bytesRead = $sourceStream.Read($buffer, 0, $ChunkSizeBytes)
                    if ($bytesRead -gt 0) {
                        # Write to all destination streams
                        foreach ($destStream in $destinationStreams) {
                            $destStream.Write($buffer, 0, $bytesRead)
                        }

                        $bytesCopied += $bytesRead

                        # Progress callback
                        if ($ProgressCallback -and $totalBytes -gt 0) {
                            $percentComplete = ($bytesCopied / $totalBytes) * 100
                            & $ProgressCallback -BytesCopied $bytesCopied -TotalBytes $totalBytes -PercentComplete $percentComplete -OperationId $OperationId
                        }
                    }
                } while ($bytesRead -gt 0)

                # Close all streams
                $sourceStream.Close()
                foreach ($destStream in $destinationStreams) {
                    $destStream.Flush()
                    $destStream.Close()
                }

                # Verify and finalize all copies
                for ($i = 0; $i -lt $DestinationPaths.Count; $i++) {
                    $tempPath = $tempDestinations[$i]
                    $finalPath = $DestinationPaths[$i]

                    # Verify size
                    $tempFile = Get-Item -Path $tempPath
                    if ($tempFile.Length -ne $totalBytes) {
                        throw "Copy verification failed for $finalPath - size mismatch"
                    }

                    # Preserve timestamps
                    if ($PreserveTimestamps) {
                        $tempFile.CreationTime = $sourceFile.CreationTime
                        $tempFile.LastWriteTime = $sourceFile.LastWriteTime
                        $tempFile.LastAccessTime = $sourceFile.LastAccessTime
                    }

                    # Atomic move to final destination
                    Move-Item -Path $tempPath -Destination $finalPath -Force
                }

                # Update statistics
                $copyDuration = ((Get-Date) - (Get-Date).AddSeconds(-10)).TotalSeconds  # Approximate for now
                $script:CopyStats.TotalFilesCopied += $DestinationPaths.Count
                $script:CopyStats.TotalBytesCopied += ($bytesCopied * $DestinationPaths.Count)

                Write-FileCopierLog -Message "Multi-destination copy completed successfully" -Level "Information" -Category "CopyEngine" -OperationId $OperationId -Properties @{
                    DestinationsCompleted = $DestinationPaths.Count
                    TotalBytesWritten = ($bytesCopied * $DestinationPaths.Count)
                }

                return @{
                    Success = $true
                    BytesCopied = $bytesCopied
                    DestinationsCompleted = $DestinationPaths.Count
                    OperationId = $OperationId
                }
            }
            finally {
                # Cleanup streams
                if ($sourceStream) { $sourceStream.Dispose() }
                foreach ($stream in $destinationStreams) {
                    if ($stream) { $stream.Dispose() }
                }

                # Cleanup any remaining temporary files
                foreach ($tempPath in $tempDestinations) {
                    if (Test-Path -Path $tempPath) {
                        try {
                            Remove-Item -Path $tempPath -Force
                        }
                        catch {
                            Write-FileCopierLog -Message "Failed to cleanup temporary file: $tempPath" -Level "Warning" -Category "CopyEngine" -OperationId $OperationId
                        }
                    }
                }
            }
        }
        catch {
            Write-FileCopierLog -Message "Multi-destination copy failed" -Level "Error" -Category "CopyEngine" -OperationId $OperationId -Exception $_.Exception

            return @{
                Success = $false
                Error = $_.Exception.Message
                OperationId = $OperationId
            }
        }
    }
}

#endregion

#region Monitoring and Statistics Functions

<#
.SYNOPSIS
    Gets information about active copy operations.

.DESCRIPTION
    Returns details about currently running copy operations for monitoring purposes.

.PARAMETER OperationId
    Specific operation ID to get info for. If not specified, returns all active operations.

.EXAMPLE
    Get-CopyOperationInfo

.EXAMPLE
    Get-CopyOperationInfo -OperationId "12345678-1234-1234-1234-123456789012"
#>
function Get-CopyOperationInfo {
    [CmdletBinding()]
    param(
        [string]$OperationId
    )

    if ($OperationId) {
        if ($script:CopyOperations.ContainsKey($OperationId)) {
            return $script:CopyOperations[$OperationId]
        }
        else {
            Write-Warning "Operation ID not found: $OperationId"
            return $null
        }
    }
    else {
        return $script:CopyOperations.Clone()
    }
}

<#
.SYNOPSIS
    Gets copy engine performance statistics.

.DESCRIPTION
    Returns performance metrics for the copy engine including throughput and success rates.

.EXAMPLE
    Get-CopyEngineStatistics
#>
function Get-CopyEngineStatistics {
    [CmdletBinding()]
    param()

    return $script:CopyStats.Clone()
}

<#
.SYNOPSIS
    Resets copy engine performance statistics.

.DESCRIPTION
    Clears all performance counters and statistics.

.EXAMPLE
    Reset-CopyEngineStatistics
#>
function Reset-CopyEngineStatistics {
    [CmdletBinding()]
    param()

    $script:CopyStats = @{
        TotalFilesCopied = 0
        TotalBytesCopied = 0
        AverageSpeed = 0
        LastCopyDuration = 0
    }

    Write-FileCopierLog -Message "Copy engine statistics reset" -Level "Information" -Category "CopyEngine"
}

#endregion

# Functions are exported by the main FileCopier.psm1 module