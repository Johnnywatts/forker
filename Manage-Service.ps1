# Manage-Service.ps1 - Comprehensive FileCopier Service Management Utility
# Part of Phase 5A: Service Deployment
# Provides unified interface for all service management operations

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "Management operation to perform")]
    [ValidateSet(
        "Install", "Uninstall", "Start", "Stop", "Restart", "Status", "Health",
        "Configure", "Validate", "Monitor", "Logs", "Reset", "Backup", "Restore",
        "Performance", "Diagnostics", "Update", "Test"
    )]
    [string]$Operation,

    [Parameter(Mandatory = $false, HelpMessage = "Service name")]
    [string]$ServiceName = "FileCopierService",

    [Parameter(Mandatory = $false, HelpMessage = "Configuration file path")]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false, HelpMessage = "Source directory to monitor")]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $false, HelpMessage = "Installation directory")]
    [string]$InstallDirectory = "C:\FileCopier",

    [Parameter(Mandatory = $false, HelpMessage = "Output format for results")]
    [ValidateSet("Text", "JSON", "Table", "CSV", "XML")]
    [string]$OutputFormat = "Text",

    [Parameter(Mandatory = $false, HelpMessage = "Enable verbose output")]
    [switch]$Verbose,

    [Parameter(Mandatory = $false, HelpMessage = "Force operation without confirmation")]
    [switch]$Force,

    [Parameter(Mandatory = $false, HelpMessage = "Run in interactive mode")]
    [switch]$Interactive,

    [Parameter(Mandatory = $false, HelpMessage = "Save output to file")]
    [string]$OutputFile,

    [Parameter(Mandatory = $false, HelpMessage = "Include detailed information")]
    [switch]$Detailed,

    [Parameter(Mandatory = $false, HelpMessage = "Number of log lines to display")]
    [int]$LogLines = 50,

    [Parameter(Mandatory = $false, HelpMessage = "Follow logs in real-time")]
    [switch]$Follow,

    [Parameter(Mandatory = $false, HelpMessage = "Backup destination directory")]
    [string]$BackupPath = "$env:TEMP\FileCopierBackup"
)

# Script constants and variables
$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StartScript = Join-Path $script:ScriptDirectory "Start-FileCopier.ps1"
$script:InstallScript = Join-Path $script:ScriptDirectory "Install-Service.ps1"
$script:HealthScript = Join-Path $script:ScriptDirectory "Get-ServiceHealth.ps1"
$script:ModulePath = Join-Path $script:ScriptDirectory "modules\FileCopier\FileCopier.psm1"

# Management result structure
class ManagementResult {
    [string] $Operation
    [bool] $Success
    [string] $Message
    [hashtable] $Data
    [DateTime] $ExecutionTime
    [TimeSpan] $Duration
    [string[]] $Warnings
    [string[]] $Errors

    ManagementResult([string] $operation) {
        $this.Operation = $operation
        $this.Success = $false
        $this.Message = ""
        $this.Data = @{}
        $this.ExecutionTime = Get-Date
        $this.Warnings = @()
        $this.Errors = @()
    }

    [void] Complete([bool] $success, [string] $message, [DateTime] $startTime) {
        $this.Success = $success
        $this.Message = $message
        $this.Duration = (Get-Date) - $startTime
    }
}

function Write-ManagementLog {
    param(
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error", "Success", "Debug")]
        [string]$Level = "Information"
    )

    if ($Level -eq "Debug" -and -not $Verbose) {
        return
    }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "Error" { "Red" }
        "Warning" { "Yellow" }
        "Success" { "Green" }
        "Debug" { "Gray" }
        default { "White" }
    }

    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

function Test-Prerequisites {
    param([string] $Operation)

    $issues = @()

    # Check if running as administrator for system operations
    if ($Operation -in @("Install", "Uninstall", "Configure")) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $issues += "Administrator privileges required for operation: $Operation"
        }
    }

    # Check required scripts exist
    $requiredScripts = @{
        "Start-FileCopier.ps1" = $script:StartScript
        "Install-Service.ps1" = $script:InstallScript
        "Get-ServiceHealth.ps1" = $script:HealthScript
    }

    foreach ($scriptName in $requiredScripts.Keys) {
        $scriptPath = $requiredScripts[$scriptName]
        if (-not (Test-Path $scriptPath)) {
            $issues += "Required script not found: $scriptName at $scriptPath"
        }
    }

    # Check module exists
    if (-not (Test-Path $script:ModulePath)) {
        $issues += "FileCopier module not found at: $script:ModulePath"
    }

    return $issues
}

function Invoke-ServiceInstall {
    param([ManagementResult] $Result)

    Write-ManagementLog "Installing FileCopier Service..." -Level "Information"

    try {
        $installArgs = @(
            "-Action", "Install",
            "-ServiceName", $ServiceName,
            "-InstallDirectory", $InstallDirectory
        )

        if ($ConfigPath) { $installArgs += @("-ConfigPath", $ConfigPath) }
        if ($SourceDirectory) { $installArgs += @("-SourceDirectory", $SourceDirectory) }
        if ($Force) { $installArgs += "-Force" }

        $installResult = & PowerShell.exe -File $script:InstallScript @installArgs

        if ($LASTEXITCODE -eq 0) {
            $Result.Success = $true
            $Result.Message = "Service installed successfully"
            $Result.Data["InstallDirectory"] = $InstallDirectory
            $Result.Data["ServiceName"] = $ServiceName
        } else {
            $Result.Errors += "Installation failed with exit code: $LASTEXITCODE"
            $Result.Message = "Service installation failed"
        }
    }
    catch {
        $Result.Errors += "Installation error: $($_.Exception.Message)"
        $Result.Message = "Service installation failed"
    }
}

function Invoke-ServiceUninstall {
    param([ManagementResult] $Result)

    Write-ManagementLog "Uninstalling FileCopier Service..." -Level "Information"

    if (-not $Force) {
        $confirmation = Read-Host "Are you sure you want to uninstall the service '$ServiceName'? (Y/N)"
        if ($confirmation -notmatch '^[Yy]') {
            $Result.Message = "Operation cancelled by user"
            return
        }
    }

    try {
        $uninstallArgs = @(
            "-Action", "Uninstall",
            "-ServiceName", $ServiceName
        )

        $uninstallResult = & PowerShell.exe -File $script:InstallScript @uninstallArgs

        if ($LASTEXITCODE -eq 0) {
            $Result.Success = $true
            $Result.Message = "Service uninstalled successfully"
        } else {
            $Result.Errors += "Uninstallation failed with exit code: $LASTEXITCODE"
            $Result.Message = "Service uninstallation failed"
        }
    }
    catch {
        $Result.Errors += "Uninstallation error: $($_.Exception.Message)"
        $Result.Message = "Service uninstallation failed"
    }
}

function Invoke-ServiceControl {
    param([ManagementResult] $Result, [string] $Action)

    Write-ManagementLog "$Action FileCopier Service..." -Level "Information"

    try {
        $controlArgs = @(
            "-Action", $Action,
            "-ServiceName", $ServiceName
        )

        $controlResult = & PowerShell.exe -File $script:InstallScript @controlArgs

        if ($LASTEXITCODE -eq 0) {
            $Result.Success = $true
            $Result.Message = "Service $($Action.ToLower()) completed successfully"

            # Get service status after operation
            try {
                $service = Get-Service -Name $ServiceName -ErrorAction Stop
                $Result.Data["ServiceStatus"] = $service.Status.ToString()
                $Result.Data["StartType"] = $service.StartType.ToString()
            }
            catch {
                $Result.Warnings += "Could not retrieve service status after $Action"
            }
        } else {
            $Result.Errors += "$Action failed with exit code: $LASTEXITCODE"
            $Result.Message = "Service $($Action.ToLower()) failed"
        }
    }
    catch {
        $Result.Errors += "$Action error: $($_.Exception.Message)"
        $Result.Message = "Service $($Action.ToLower()) failed"
    }
}

function Get-ServiceStatus {
    param([ManagementResult] $Result)

    Write-ManagementLog "Getting service status..." -Level "Information"

    try {
        # Get Windows service status
        try {
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            $Result.Data["WindowsService"] = @{
                Status = $service.Status.ToString()
                StartType = $service.StartType.ToString()
                DisplayName = $service.DisplayName
                ServiceName = $service.ServiceName
                CanStop = $service.CanStop
                CanPauseAndContinue = $service.CanPauseAndContinue
            }

            # Get additional service information
            try {
                $serviceWmi = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'"
                if ($serviceWmi) {
                    $Result.Data["WindowsService"]["ProcessId"] = $serviceWmi.ProcessId
                    $Result.Data["WindowsService"]["StartName"] = $serviceWmi.StartName
                    $Result.Data["WindowsService"]["PathName"] = $serviceWmi.PathName
                }
            }
            catch {
                $Result.Warnings += "Could not retrieve WMI service information"
            }

            $Result.Success = $true
            $Result.Message = "Service status retrieved successfully"
        }
        catch [System.ServiceProcess.ServiceController] {
            $Result.Success = $false
            $Result.Message = "Service '$ServiceName' is not installed"
            $Result.Data["WindowsService"] = @{
                Status = "NotInstalled"
            }
        }

        # Try to get FileCopier-specific status if running
        if ($Result.Data["WindowsService"]["Status"] -eq "Running") {
            try {
                Write-ManagementLog "Getting FileCopier service details..." -Level "Debug"

                $healthArgs = @(
                    "-ServiceName", $ServiceName,
                    "-OutputFormat", "JSON",
                    "-Detailed"
                )
                if ($Detailed) { $healthArgs += "-IncludeMetrics" }

                $healthOutput = & PowerShell.exe -File $script:HealthScript @healthArgs
                if ($LASTEXITCODE -eq 0 -and $healthOutput) {
                    $healthData = $healthOutput | ConvertFrom-Json
                    $Result.Data["FileCopierService"] = $healthData
                }
            }
            catch {
                $Result.Warnings += "Could not retrieve FileCopier service details: $($_.Exception.Message)"
            }
        }
    }
    catch {
        $Result.Errors += "Error getting service status: $($_.Exception.Message)"
        $Result.Message = "Failed to get service status"
    }
}

function Get-ServiceHealth {
    param([ManagementResult] $Result)

    Write-ManagementLog "Performing health check..." -Level "Information"

    try {
        $healthArgs = @(
            "-ServiceName", $ServiceName,
            "-OutputFormat", "JSON"
        )
        if ($Detailed) { $healthArgs += @("-Detailed", "-IncludeMetrics") }

        $healthOutput = & PowerShell.exe -File $script:HealthScript @healthArgs

        if ($LASTEXITCODE -eq 0 -and $healthOutput) {
            $healthData = $healthOutput | ConvertFrom-Json
            $Result.Data["HealthCheck"] = $healthData
            $Result.Success = $true
            $Result.Message = "Health check completed - Status: $($healthData.OverallStatus)"

            if ($healthData.OverallStatus -in @("Warning", "Critical")) {
                $Result.Warnings += "Service health issues detected"
            }
        } else {
            $Result.Errors += "Health check failed with exit code: $LASTEXITCODE"
            $Result.Message = "Health check failed"
        }
    }
    catch {
        $Result.Errors += "Health check error: $($_.Exception.Message)"
        $Result.Message = "Health check failed"
    }
}

function Show-ServiceLogs {
    param([ManagementResult] $Result)

    Write-ManagementLog "Retrieving service logs..." -Level "Information"

    try {
        $logPaths = @(
            "$InstallDirectory\Logs\service.log",
            "$InstallDirectory\Logs\service-stdout.log",
            "$InstallDirectory\Logs\service-stderr.log",
            "C:\FileCopier\Logs\service.log"
        )

        $foundLogs = @()
        foreach ($logPath in $logPaths) {
            if (Test-Path $logPath) {
                $foundLogs += $logPath
            }
        }

        if ($foundLogs.Count -eq 0) {
            $Result.Message = "No log files found"
            $Result.Warnings += "Log files not found in expected locations"
            return
        }

        $Result.Data["LogFiles"] = $foundLogs
        $Result.Data["LogEntries"] = @()

        # Read recent log entries
        foreach ($logFile in $foundLogs) {
            try {
                Write-ManagementLog "Reading log file: $logFile" -Level "Debug"

                if ($Follow) {
                    Write-ManagementLog "Following log file in real-time (Ctrl+C to stop)..." -Level "Information"
                    Get-Content -Path $logFile -Tail $LogLines -Wait
                } else {
                    $logContent = Get-Content -Path $logFile -Tail $LogLines -ErrorAction Stop
                    $Result.Data["LogEntries"] += @{
                        File = $logFile
                        Lines = $logContent
                        Count = $logContent.Count
                    }
                }
            }
            catch {
                $Result.Warnings += "Could not read log file: $logFile - $($_.Exception.Message)"
            }
        }

        if (-not $Follow) {
            $Result.Success = $true
            $Result.Message = "Log files retrieved successfully"
        }
    }
    catch {
        $Result.Errors += "Error retrieving logs: $($_.Exception.Message)"
        $Result.Message = "Failed to retrieve logs"
    }
}

function Start-ServiceMonitoring {
    param([ManagementResult] $Result)

    Write-ManagementLog "Starting service monitoring..." -Level "Information"

    try {
        $monitorArgs = @(
            "-ServiceName", $ServiceName,
            "-Monitor",
            "-MonitorInterval", "30",
            "-OutputFormat", $OutputFormat
        )
        if ($Detailed) { $monitorArgs += @("-Detailed", "-IncludeMetrics") }
        if ($OutputFile) { $monitorArgs += @("-OutputFile", $OutputFile) }

        & PowerShell.exe -File $script:HealthScript @monitorArgs

        $Result.Success = $true
        $Result.Message = "Monitoring session completed"
    }
    catch {
        $Result.Errors += "Monitoring error: $($_.Exception.Message)"
        $Result.Message = "Monitoring failed"
    }
}

function Reset-ServiceData {
    param([ManagementResult] $Result)

    Write-ManagementLog "Resetting service data..." -Level "Information"

    if (-not $Force) {
        $confirmation = Read-Host "This will clear all service data including logs and quarantine files. Continue? (Y/N)"
        if ($confirmation -notmatch '^[Yy]') {
            $Result.Message = "Reset cancelled by user"
            return
        }
    }

    try {
        $resetPaths = @(
            "$InstallDirectory\Logs",
            "$InstallDirectory\Quarantine",
            "$InstallDirectory\Temp",
            "C:\FileCopier\Logs",
            "C:\FileCopier\Quarantine",
            "C:\FileCopier\Temp"
        )

        $clearedPaths = @()
        foreach ($resetPath in $resetPaths) {
            if (Test-Path $resetPath) {
                try {
                    Get-ChildItem -Path $resetPath -Recurse | Remove-Item -Force -Recurse
                    $clearedPaths += $resetPath
                    Write-ManagementLog "Cleared: $resetPath" -Level "Debug"
                }
                catch {
                    $Result.Warnings += "Could not clear path: $resetPath - $($_.Exception.Message)"
                }
            }
        }

        $Result.Data["ClearedPaths"] = $clearedPaths
        $Result.Success = $true
        $Result.Message = "Service data reset completed"
        Write-ManagementLog "Reset completed - cleared $($clearedPaths.Count) directories" -Level "Success"
    }
    catch {
        $Result.Errors += "Reset error: $($_.Exception.Message)"
        $Result.Message = "Service data reset failed"
    }
}

function Backup-ServiceConfiguration {
    param([ManagementResult] $Result)

    Write-ManagementLog "Backing up service configuration..." -Level "Information"

    try {
        # Create backup directory
        $backupTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupDir = Join-Path $BackupPath "FileCopier-Backup-$backupTimestamp"

        if (-not (Test-Path $BackupPath)) {
            New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
        }
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

        # Items to backup
        $backupItems = @(
            @{ Source = $script:StartScript; Name = "Start-FileCopier.ps1" },
            @{ Source = $script:InstallScript; Name = "Install-Service.ps1" },
            @{ Source = $script:HealthScript; Name = "Get-ServiceHealth.ps1" },
            @{ Source = (Join-Path $script:ScriptDirectory "Manage-Service.ps1"); Name = "Manage-Service.ps1" },
            @{ Source = (Join-Path $script:ScriptDirectory "config"); Name = "config" },
            @{ Source = $script:ModulePath; Name = "FileCopier.psm1" }
        )

        # Add current service configuration if running
        if ($ConfigPath -and (Test-Path $ConfigPath)) {
            $backupItems += @{ Source = $ConfigPath; Name = "current-config.json" }
        }

        $backedUpItems = @()
        foreach ($item in $backupItems) {
            if (Test-Path $item.Source) {
                try {
                    $destPath = Join-Path $backupDir $item.Name
                    if ((Get-Item $item.Source).PSIsContainer) {
                        Copy-Item -Path $item.Source -Destination $destPath -Recurse -Force
                    } else {
                        Copy-Item -Path $item.Source -Destination $destPath -Force
                    }
                    $backedUpItems += $item.Name
                    Write-ManagementLog "Backed up: $($item.Name)" -Level "Debug"
                }
                catch {
                    $Result.Warnings += "Could not backup $($item.Name): $($_.Exception.Message)"
                }
            }
        }

        # Create backup manifest
        $manifest = @{
            BackupTime = Get-Date
            ServiceName = $ServiceName
            BackupVersion = "Phase 5A"
            Items = $backedUpItems
            OriginalPaths = $backupItems
        }

        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $backupDir "backup-manifest.json") -Encoding UTF8

        $Result.Data["BackupDirectory"] = $backupDir
        $Result.Data["BackedUpItems"] = $backedUpItems
        $Result.Success = $true
        $Result.Message = "Backup completed successfully"
        Write-ManagementLog "Backup created at: $backupDir" -Level "Success"
    }
    catch {
        $Result.Errors += "Backup error: $($_.Exception.Message)"
        $Result.Message = "Backup failed"
    }
}

function Format-ManagementResult {
    param([ManagementResult] $Result, [string] $Format)

    switch ($Format.ToLower()) {
        "json" {
            return ($Result | ConvertTo-Json -Depth 10)
        }
        "table" {
            $tableData = [PSCustomObject]@{
                Operation = $Result.Operation
                Success = $Result.Success
                Message = $Result.Message
                Duration = "$([Math]::Round($Result.Duration.TotalSeconds, 2))s"
                Warnings = $Result.Warnings.Count
                Errors = $Result.Errors.Count
                ExecutionTime = $Result.ExecutionTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
            return ($tableData | Format-Table -AutoSize | Out-String)
        }
        "csv" {
            $csvData = [PSCustomObject]@{
                Operation = $Result.Operation
                Success = $Result.Success
                Message = $Result.Message
                DurationSeconds = $Result.Duration.TotalSeconds
                WarningCount = $Result.Warnings.Count
                ErrorCount = $Result.Errors.Count
                ExecutionTime = $Result.ExecutionTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
            return ($csvData | ConvertTo-Csv -NoTypeInformation)
        }
        "xml" {
            return ($Result | ConvertTo-Xml -NoTypeInformation).OuterXml
        }
        "text" -default {
            $output = @"
=== FileCopier Service Management Result ===
Operation: $($Result.Operation)
Success: $($Result.Success)
Message: $($Result.Message)
Duration: $([Math]::Round($Result.Duration.TotalSeconds, 2)) seconds
Execution Time: $($Result.ExecutionTime.ToString('yyyy-MM-dd HH:mm:ss'))

"@
            if ($Result.Warnings.Count -gt 0) {
                $output += "Warnings:`n"
                $Result.Warnings | ForEach-Object { $output += "  - $_`n" }
                $output += "`n"
            }

            if ($Result.Errors.Count -gt 0) {
                $output += "Errors:`n"
                $Result.Errors | ForEach-Object { $output += "  - $_`n" }
                $output += "`n"
            }

            if ($Result.Data.Count -gt 0) {
                $output += "Additional Data:`n"
                foreach ($key in $Result.Data.Keys) {
                    $value = $Result.Data[$key]
                    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                        $output += "  $key : $($value.Count) items`n"
                    } else {
                        $output += "  $key : $value`n"
                    }
                }
            }

            return $output
        }
    }
}

# Main execution function
function Main {
    $startTime = Get-Date
    $result = [ManagementResult]::new($Operation)

    Write-ManagementLog "Starting FileCopier Service Management - Operation: $Operation" -Level "Information"

    # Check prerequisites
    $prerequisiteIssues = Test-Prerequisites -Operation $Operation
    if ($prerequisiteIssues.Count -gt 0) {
        $result.Errors = $prerequisiteIssues
        $result.Complete($false, "Prerequisites not met", $startTime)

        $formattedResult = Format-ManagementResult -Result $result -Format $OutputFormat
        if ($OutputFile) {
            $formattedResult | Out-File -FilePath $OutputFile -Encoding UTF8
        } else {
            Write-Output $formattedResult
        }
        exit 1
    }

    # Execute requested operation
    try {
        switch ($Operation.ToLower()) {
            "install" { Invoke-ServiceInstall -Result $result }
            "uninstall" { Invoke-ServiceUninstall -Result $result }
            "start" { Invoke-ServiceControl -Result $result -Action "Start" }
            "stop" { Invoke-ServiceControl -Result $result -Action "Stop" }
            "restart" { Invoke-ServiceControl -Result $result -Action "Restart" }
            "status" { Get-ServiceStatus -Result $result }
            "health" { Get-ServiceHealth -Result $result }
            "logs" { Show-ServiceLogs -Result $result }
            "monitor" { Start-ServiceMonitoring -Result $result }
            "reset" { Reset-ServiceData -Result $result }
            "backup" { Backup-ServiceConfiguration -Result $result }
            "validate" {
                # Validate installation
                $validateArgs = @("-Action", "Validate", "-ServiceName", $ServiceName)
                & PowerShell.exe -File $script:InstallScript @validateArgs
                $result.Success = ($LASTEXITCODE -eq 0)
                $result.Message = if ($result.Success) { "Validation passed" } else { "Validation failed" }
            }
            default {
                $result.Errors += "Unknown operation: $Operation"
                $result.Message = "Invalid operation specified"
            }
        }
    }
    catch {
        $result.Errors += "Unexpected error: $($_.Exception.Message)"
        $result.Message = "Operation failed with unexpected error"
    }

    # Complete result
    if ($result.Success -eq $false -and $result.Message -eq "") {
        $result.Message = "Operation completed with issues"
    }
    elseif ($result.Success -eq $true -and $result.Message -eq "") {
        $result.Message = "Operation completed successfully"
    }

    $result.Complete($result.Success, $result.Message, $startTime)

    # Output result
    $formattedResult = Format-ManagementResult -Result $result -Format $OutputFormat

    if ($OutputFile) {
        $formattedResult | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-ManagementLog "Results written to: $OutputFile" -Level "Information"
    } else {
        Write-Output $formattedResult
    }

    # Exit with appropriate code
    exit $(if ($result.Success) { 0 } else { 1 })
}

# Interactive menu mode
function Start-InteractiveMode {
    Write-Host "`n=== FileCopier Service Management ===" -ForegroundColor Cyan
    Write-Host "Interactive Mode" -ForegroundColor Gray

    do {
        Write-Host "`nAvailable Operations:" -ForegroundColor White
        Write-Host "  1. Install Service" -ForegroundColor Gray
        Write-Host "  2. Uninstall Service" -ForegroundColor Gray
        Write-Host "  3. Start Service" -ForegroundColor Gray
        Write-Host "  4. Stop Service" -ForegroundColor Gray
        Write-Host "  5. Restart Service" -ForegroundColor Gray
        Write-Host "  6. Service Status" -ForegroundColor Gray
        Write-Host "  7. Health Check" -ForegroundColor Gray
        Write-Host "  8. View Logs" -ForegroundColor Gray
        Write-Host "  9. Monitor Service" -ForegroundColor Gray
        Write-Host " 10. Reset Service Data" -ForegroundColor Gray
        Write-Host " 11. Backup Configuration" -ForegroundColor Gray
        Write-Host " 12. Validate Installation" -ForegroundColor Gray
        Write-Host "  0. Exit" -ForegroundColor Yellow

        $choice = Read-Host "`nEnter choice (0-12)"

        $operation = switch ($choice) {
            "1" { "Install" }
            "2" { "Uninstall" }
            "3" { "Start" }
            "4" { "Stop" }
            "5" { "Restart" }
            "6" { "Status" }
            "7" { "Health" }
            "8" { "Logs" }
            "9" { "Monitor" }
            "10" { "Reset" }
            "11" { "Backup" }
            "12" { "Validate" }
            "0" { $null }
            default {
                Write-Host "Invalid choice. Please try again." -ForegroundColor Red
                continue
            }
        }

        if ($operation) {
            Write-Host "`nExecuting: $operation..." -ForegroundColor Yellow
            try {
                $global:Operation = $operation
                Main
            }
            catch {
                Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            }
            Write-Host "`nPress any key to continue..." -ForegroundColor Gray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }

    } while ($choice -ne "0")

    Write-Host "`nExiting interactive mode." -ForegroundColor Yellow
}

# Execute main function or start interactive mode
if ($Interactive) {
    Start-InteractiveMode
} else {
    Main
}