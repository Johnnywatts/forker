#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Concurrent stress test for File Copier Service
.DESCRIPTION
    Creates a demanding test scenario with:
    - Primary copy operations (source -> targetA + targetB)
    - Aggressive background process copying/deleting from targetB
    - Real-time monitoring and statistics
#>

param(
    [int]$TestDurationSeconds = 30,
    [int]$BackgroundCopyIntervalMs = 100,
    [switch]$Verbose
)

# Import the module
Import-Module './modules/FileCopier/FileCopier.psd1' -Force

Write-Host "=== CONCURRENT STRESS TEST STARTING ===" -ForegroundColor Cyan
Write-Host "Duration: $TestDurationSeconds seconds" -ForegroundColor Yellow
Write-Host "Background copy interval: $BackgroundCopyIntervalMs ms" -ForegroundColor Yellow
Write-Host ""

# Test directories
$sourceDir = "./tests/TestData/source"
$targetADir = "./tests/TestData/targetA"
$targetBDir = "./tests/TestData/targetB"
$stressDir = "./tests/TestData/stress-temp"

# Ensure directories exist and are clean
@($targetADir, $targetBDir, $stressDir) | ForEach-Object {
    if (Test-Path $_) { Remove-Item "$_/*" -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

# Get source files
$sourceFiles = Get-ChildItem $sourceDir -File

Write-Host "Source files found:" -ForegroundColor Green
$sourceFiles | ForEach-Object {
    $sizeMB = [math]::Round($_.Length / 1MB, 2)
    Write-Host "  - $($_.Name) ($sizeMB MB)"
}
Write-Host ""

# Statistics tracking
$script:stats = @{
    MainCopiesCompleted = 0
    MainCopiesFailed = 0
    BackgroundCopiesCompleted = 0
    BackgroundCopiesFailed = 0
    BackgroundDeletesCompleted = 0
    TotalBytesMainCopied = 0
    TotalBytesBackgroundCopied = 0
    StartTime = Get-Date
}

# Background process function
$backgroundProcess = {
    param($targetBDir, $stressDir, $intervalMs, $stats)

    while ($true) {
        try {
            # Look for files in targetB to copy and delete
            $files = Get-ChildItem $targetBDir -File -ErrorAction SilentlyContinue

            foreach ($file in $files) {
                try {
                    # Copy to stress directory
                    $stressFile = Join-Path $stressDir "stress-$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')-$($file.Name)"
                    Copy-Item $file.FullName $stressFile -Force
                    $stats.BackgroundCopiesCompleted++
                    $stats.TotalBytesBackgroundCopied += $file.Length

                    # Immediately delete the copy (we don't need to keep it)
                    Remove-Item $stressFile -Force

                    # Sometimes delete from targetB too (aggressive competition)
                    if ((Get-Random -Minimum 1 -Maximum 10) -le 3) {
                        Remove-Item $file.FullName -Force
                        $stats.BackgroundDeletesCompleted++
                    }
                } catch {
                    $stats.BackgroundCopiesFailed++
                }
            }
        } catch {
            # Continue on errors
        }

        Start-Sleep -Milliseconds $intervalMs
    }
}

# Start background job
Write-Host "Starting aggressive background copy/delete process..." -ForegroundColor Yellow
$backgroundJob = Start-Job -ScriptBlock $backgroundProcess -ArgumentList $targetBDir, $stressDir, $BackgroundCopyIntervalMs, $script:stats

# Main stress test loop
$endTime = (Get-Date).AddSeconds($TestDurationSeconds)
$mainCopyCount = 0

Write-Host "Starting main copy operations with background interference..." -ForegroundColor Yellow
Write-Host ""

while ((Get-Date) -lt $endTime) {
    foreach ($sourceFile in $sourceFiles) {
        if ((Get-Date) -ge $endTime) { break }

        $mainCopyCount++
        $targetAFile = Join-Path $targetADir "main-copy-$mainCopyCount-$($sourceFile.Name)"
        $targetBFile = Join-Path $targetBDir "main-copy-$mainCopyCount-$($sourceFile.Name)"

        Write-Host "Main copy #$mainCopyCount : $($sourceFile.Name) -> A + B" -ForegroundColor Cyan

        # Progress callback for main operations
        $progressCallback = {
            param($BytesCopied, $TotalBytes, $PercentComplete, $OperationId)
            if ($PercentComplete % 25 -eq 0) {
                $sizeMB = [math]::Round($BytesCopied / 1MB, 2)
                $totalMB = [math]::Round($TotalBytes / 1MB, 2)
                Write-Host "    Progress: $PercentComplete% ($sizeMB MB / $totalMB MB)" -ForegroundColor DarkCyan
            }
        }

        try {
            # Multi-destination copy (competing with background process for targetB)
            $startTime = Get-Date
            $result = Copy-FileToMultipleDestinations -SourcePath $sourceFile.FullName -DestinationPaths @($targetAFile, $targetBFile) -ProgressCallback $progressCallback
            $duration = ((Get-Date) - $startTime).TotalSeconds

            if ($result.Success) {
                $script:stats.MainCopiesCompleted++
                $script:stats.TotalBytesMainCopied += $sourceFile.Length * 2  # Two destinations
                $throughputMBps = [math]::Round(($sourceFile.Length * 2 / 1MB) / $duration, 2)
                Write-Host "    ✅ SUCCESS: $throughputMBps MB/s (dual targets)" -ForegroundColor Green
            } else {
                $script:stats.MainCopiesFailed++
                Write-Host "    ❌ FAILED" -ForegroundColor Red
            }
        } catch {
            $script:stats.MainCopiesFailed++
            Write-Host "    ❌ EXCEPTION: $($_.Exception.Message)" -ForegroundColor Red
        }

        # Brief pause to let background process work
        Start-Sleep -Milliseconds 50
    }
}

# Stop background job
Write-Host ""
Write-Host "Stopping background process..." -ForegroundColor Yellow
Stop-Job $backgroundJob -Force
Remove-Job $backgroundJob -Force

# Calculate final statistics
$totalDuration = ((Get-Date) - $script:stats.StartTime).TotalSeconds
$mainThroughputMBps = [math]::Round($script:stats.TotalBytesMainCopied / 1MB / $totalDuration, 2)
$backgroundThroughputMBps = [math]::Round($script:stats.TotalBytesBackgroundCopied / 1MB / $totalDuration, 2)

Write-Host ""
Write-Host "=== CONCURRENT STRESS TEST RESULTS ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Test Duration: $([math]::Round($totalDuration, 2)) seconds" -ForegroundColor White
Write-Host ""
Write-Host "MAIN COPY OPERATIONS:" -ForegroundColor Green
Write-Host "  ✅ Completed: $($script:stats.MainCopiesCompleted)"
Write-Host "  ❌ Failed: $($script:stats.MainCopiesFailed)"
Write-Host "  📊 Success Rate: $([math]::Round($script:stats.MainCopiesCompleted / ($script:stats.MainCopiesCompleted + $script:stats.MainCopiesFailed) * 100, 1))%"
Write-Host "  🚀 Throughput: $mainThroughputMBps MB/s"
Write-Host "  💾 Total Data: $([math]::Round($script:stats.TotalBytesMainCopied / 1MB, 2)) MB"
Write-Host ""
Write-Host "BACKGROUND INTERFERENCE:" -ForegroundColor Yellow
Write-Host "  📋 Copies Completed: $($script:stats.BackgroundCopiesCompleted)"
Write-Host "  ❌ Copies Failed: $($script:stats.BackgroundCopiesFailed)"
Write-Host "  🗑️ Files Deleted: $($script:stats.BackgroundDeletesCompleted)"
Write-Host "  🚀 Throughput: $backgroundThroughputMBps MB/s"
Write-Host "  💾 Total Data: $([math]::Round($script:stats.TotalBytesBackgroundCopied / 1MB, 2)) MB"
Write-Host ""

# Cleanup
Write-Host "Cleaning up test files..." -ForegroundColor Gray
@($targetADir, $targetBDir, $stressDir) | ForEach-Object {
    Remove-Item "$_/*" -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== STRESS TEST COMPLETED ===" -ForegroundColor Cyan