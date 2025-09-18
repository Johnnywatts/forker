# Start-FileCopier.ps1 - Main service entry point for FileCopier Service
# Part of Phase 5A: Service Deployment
# This script is designed to run as a Windows service via NSSM

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Path to configuration file")]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false, HelpMessage = "Source directory to monitor")]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $false, HelpMessage = "Service operation mode")]
    [ValidateSet("Start", "Stop", "Restart", "Status", "Install", "Uninstall")]
    [string]$Operation = "Start",

    [Parameter(Mandatory = $false, HelpMessage = "Enable interactive mode for testing")]
    [switch]$Interactive,

    [Parameter(Mandatory = $false, HelpMessage = "Enable verbose logging")]
    [switch]$Verbose,

    [Parameter(Mandatory = $false, HelpMessage = "Run as console application (not service)")]
    [switch]$Console
)

# Set error action preference
$ErrorActionPreference = 'Stop'

# Script variables
$script:ServiceName = "FileCopierService"
$script:ServiceDisplayName = "File Copier Service for SVS Files"
$script:ServiceDescription = "Automated file copying service optimized for large SVS medical imaging files with verification and multi-target support"
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:ScriptDirectory = Split-Path -Parent $script:ScriptPath
$script:ModulePath = Join-Path $script:ScriptDirectory "modules\FileCopier\FileCopier.psm1"
$script:DefaultConfigPath = Join-Path $script:ScriptDirectory "config\service-config.json"
$script:GlobalService = $null
$script:IsRunning = $false

# Import required modules
try {
    Write-Host "Loading FileCopier module from: $script:ModulePath" -ForegroundColor Green
    Import-Module $script:ModulePath -Force -Global
    Write-Host "FileCopier module loaded successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to load FileCopier module: $($_.Exception.Message)"
    Write-Error "Module path: $script:ModulePath"
    exit 1
}

function Write-ServiceLog {
    param(
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error", "Debug")]
        [string]$Level = "Information",
        [hashtable]$Properties = @{}
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Add properties if provided
    if ($Properties.Count -gt 0) {
        $propString = ($Properties.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
        $logEntry += " | $propString"
    }

    # Output based on level
    switch ($Level) {
        "Error" { Write-Host $logEntry -ForegroundColor Red }
        "Warning" { Write-Host $logEntry -ForegroundColor Yellow }
        "Debug" {
            if ($Verbose) { Write-Host $logEntry -ForegroundColor Gray }
        }
        default { Write-Host $logEntry -ForegroundColor White }
    }

    # Also write to event log if running as service (non-interactive)
    if (-not $Interactive -and -not $Console) {
        try {
            $eventLogLevel = switch ($Level) {
                "Error" { "Error" }
                "Warning" { "Warning" }
                default { "Information" }
            }
            Write-EventLog -LogName Application -Source $script:ServiceName -EntryType $eventLogLevel -EventId 1000 -Message $Message -ErrorAction SilentlyContinue
        }
        catch {
            # Ignore event log errors to prevent service failures
        }
    }
}

function Initialize-ServiceEventLog {
    try {
        # Check if event source exists
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:ServiceName)) {
            Write-ServiceLog "Creating event log source: $script:ServiceName" -Level "Information"
            [System.Diagnostics.EventLog]::CreateEventSource($script:ServiceName, "Application")
        }
    }
    catch {
        Write-ServiceLog "Warning: Could not initialize event log source: $($_.Exception.Message)" -Level "Warning"
    }
}

function Get-ServiceConfiguration {
    param(
        [string]$ConfigFilePath
    )

    # Determine configuration file path
    $configPath = $ConfigFilePath
    if (-not $configPath) {
        $configPath = $script:DefaultConfigPath
    }

    Write-ServiceLog "Loading configuration from: $configPath" -Level "Information"

    # Check if config file exists
    if (-not (Test-Path $configPath)) {
        Write-ServiceLog "Configuration file not found, creating default configuration" -Level "Warning" -Properties @{
            ExpectedPath = $configPath
        }

        # Create default configuration
        $defaultConfig = Get-DefaultServiceConfiguration

        # Ensure config directory exists
        $configDir = Split-Path -Parent $configPath
        if (-not (Test-Path $configDir)) {
            New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        }

        # Save default configuration
        $defaultConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
        Write-ServiceLog "Default configuration created at: $configPath" -Level "Information"

        return $defaultConfig
    }

    # Load existing configuration
    try {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json -AsHashtable
        Write-ServiceLog "Configuration loaded successfully" -Level "Information" -Properties @{
            ConfigPath = $configPath
            SourceDirectory = $config.SourceDirectory
            TargetCount = $config.Targets.Count
        }
        return $config
    }
    catch {
        Write-ServiceLog "Failed to load configuration file: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

function Get-DefaultServiceConfiguration {
    return @{
        SourceDirectory = "C:\FileCopier\Watch"
        Targets = @{
            TargetA = @{
                Path = "C:\FileCopier\TargetA"
                Enabled = $true
            }
            TargetB = @{
                Path = "C:\FileCopier\TargetB"
                Enabled = $true
            }
        }
        FileWatcher = @{
            PollingInterval = 5000
            StabilityCheckInterval = 2000
            StabilityChecks = 3
            IncludePatterns = @("*.svs", "*.tiff", "*.tif")
            ExcludePatterns = @("*.tmp", "*.temp", "*~*")
        }
        Processing = @{
            MaxConcurrentCopies = 4
            RetryAttempts = 3
            RetryDelay = 5000
            QueueCheckInterval = 1000
            QuarantineDirectory = "C:\FileCopier\Quarantine"
        }
        Verification = @{
            Enabled = $true
            HashAlgorithm = "SHA256"
            HashRetryAttempts = 2
            HashRetryDelay = 2000
            StreamBufferSize = 1048576
        }
        Logging = @{
            Level = "Information"
            FilePath = "C:\FileCopier\Logs\service.log"
            MaxFileSizeMB = 50
            MaxFiles = 10
            AuditDirectory = "C:\FileCopier\Logs\Audit"
            AuditFlushInterval = 10000
        }
        Service = @{
            HealthCheckInterval = 30000
            ConfigReloadInterval = 300000
            IntegrationInterval = 2000
            MaxMemoryMB = 1024
            GracefulShutdownTimeoutSeconds = 30
        }
        Retry = @{
            Strategies = @{
                FileSystem = @{
                    MaxAttempts = 5
                    BaseDelayMs = 2000
                    MaxDelayMs = 60000
                    BackoffMultiplier = 2.0
                }
                Network = @{
                    MaxAttempts = 3
                    BaseDelayMs = 5000
                    MaxDelayMs = 300000
                    BackoffMultiplier = 2.5
                }
                Verification = @{
                    MaxAttempts = 2
                    BaseDelayMs = 1000
                    MaxDelayMs = 10000
                    BackoffMultiplier = 2.0
                }
            }
        }
    }
}

function Start-FileCopierService {
    param(
        [hashtable]$Config,
        [string]$SourceDir
    )

    try {
        Write-ServiceLog "Starting FileCopier Service" -Level "Information" -Properties @{
            Version = "Phase 5A"
            SourceDirectory = if ($SourceDir) { $SourceDir } else { $Config.SourceDirectory }
            Interactive = $Interactive.IsPresent
            Console = $Console.IsPresent
        }

        # Override source directory if provided
        if ($SourceDir) {
            $Config.SourceDirectory = $SourceDir
        }

        # Validate source directory
        if (-not (Test-Path $Config.SourceDirectory)) {
            Write-ServiceLog "Creating source directory: $($Config.SourceDirectory)" -Level "Information"
            New-Item -Path $Config.SourceDirectory -ItemType Directory -Force | Out-Null
        }

        # Validate target directories
        foreach ($targetName in $Config.Targets.Keys) {
            $target = $Config.Targets[$targetName]
            if ($target.Enabled -and -not (Test-Path $target.Path)) {
                Write-ServiceLog "Creating target directory: $($target.Path)" -Level "Information" -Properties @{
                    TargetName = $targetName
                }
                New-Item -Path $target.Path -ItemType Directory -Force | Out-Null
            }
        }

        # Create logging directory
        $logDir = Split-Path -Parent $Config.Logging.FilePath
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }

        # Create quarantine directory
        if (-not (Test-Path $Config.Processing.QuarantineDirectory)) {
            New-Item -Path $Config.Processing.QuarantineDirectory -ItemType Directory -Force | Out-Null
        }

        # Start the service
        $result = Start-FileCopierService -SourceDirectory $Config.SourceDirectory -Configuration $Config

        if ($result) {
            $script:GlobalService = Get-Variable -Name "script:GlobalFileCopierService" -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            $script:IsRunning = $true

            Write-ServiceLog "FileCopier Service started successfully" -Level "Information" -Properties @{
                ServiceRunning = $script:IsRunning
                ProcessId = $PID
            }

            return $true
        } else {
            Write-ServiceLog "Failed to start FileCopier Service" -Level "Error"
            return $false
        }
    }
    catch {
        Write-ServiceLog "Error starting FileCopier Service: $($_.Exception.Message)" -Level "Error" -Properties @{
            Exception = $_.Exception.GetType().Name
            StackTrace = $_.ScriptStackTrace
        }
        return $false
    }
}

function Stop-FileCopierService {
    try {
        Write-ServiceLog "Stopping FileCopier Service" -Level "Information"

        if ($script:GlobalService) {
            $result = Stop-FileCopierService -Service $script:GlobalService
            $script:IsRunning = $false
            $script:GlobalService = $null

            Write-ServiceLog "FileCopier Service stopped successfully" -Level "Information" -Properties @{
                StopResult = $result
            }
            return $result
        } else {
            Write-ServiceLog "No active service instance found" -Level "Warning"
            return $true
        }
    }
    catch {
        Write-ServiceLog "Error stopping FileCopier Service: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Get-ServiceStatus {
    try {
        if ($script:GlobalService -and $script:IsRunning) {
            $status = Get-FileCopierServiceStatus -Service $script:GlobalService

            Write-ServiceLog "Service Status Retrieved" -Level "Information" -Properties @{
                IsRunning = $status.IsRunning
                StartTime = $status.StartTime
                UptimeHours = if ($status.StartTime) { [Math]::Round(((Get-Date) - $status.StartTime).TotalHours, 2) } else { 0 }
            }

            return $status
        } else {
            Write-ServiceLog "Service is not running" -Level "Information"
            return $null
        }
    }
    catch {
        Write-ServiceLog "Error getting service status: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

function Wait-ForServiceShutdown {
    Write-ServiceLog "Waiting for shutdown signal..." -Level "Information"

    # Register for console events (Ctrl+C, etc.)
    $null = [Console]::TreatControlCAsInput = $false

    try {
        if ($Console) {
            # Console mode - wait for Ctrl+C or 'q' key
            Write-ServiceLog "Running in console mode. Press 'q' to quit or Ctrl+C to stop." -Level "Information"

            do {
                $key = $null
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'Q' -or $key.Key -eq 'q') {
                        Write-ServiceLog "Quit command received" -Level "Information"
                        break
                    }
                }

                # Check service health periodically
                if ($script:GlobalService) {
                    try {
                        $health = $script:GlobalService.GetHealthStatus()
                        if ($health.Status -ne "Healthy") {
                            Write-ServiceLog "Service health issue detected: $($health.Status)" -Level "Warning"
                        }
                    }
                    catch {
                        Write-ServiceLog "Health check failed: $($_.Exception.Message)" -Level "Warning"
                    }
                }

                Start-Sleep -Milliseconds 1000
            } while ($script:IsRunning)
        } else {
            # Service mode - run indefinitely until stopped
            while ($script:IsRunning) {
                Start-Sleep -Seconds 10

                # Periodic health check
                if ($script:GlobalService) {
                    try {
                        $health = $script:GlobalService.GetHealthStatus()
                        if ($health.Status -ne "Healthy") {
                            Write-ServiceLog "Service health issue: $($health.Status)" -Level "Warning" -Properties @{
                                Components = ($health.Components.Keys -join ", ")
                            }
                        }
                    }
                    catch {
                        Write-ServiceLog "Health check error: $($_.Exception.Message)" -Level "Error"
                    }
                }
            }
        }
    }
    catch {
        Write-ServiceLog "Error in service wait loop: $($_.Exception.Message)" -Level "Error"
    }
    finally {
        Write-ServiceLog "Service wait loop ended" -Level "Information"
    }
}

function Show-ServiceStatus {
    $status = Get-ServiceStatus

    if ($status) {
        Write-Host "`n=== FileCopier Service Status ===" -ForegroundColor Cyan
        Write-Host "Status: Running" -ForegroundColor Green
        Write-Host "Start Time: $($status.StartTime)" -ForegroundColor White
        Write-Host "Uptime: $([Math]::Round(((Get-Date) - $status.StartTime).TotalHours, 2)) hours" -ForegroundColor White
        Write-Host "Process ID: $PID" -ForegroundColor White
        Write-Host "Configuration:" -ForegroundColor White
        Write-Host "  Source Directory: $($status.Configuration.SourceDirectory)" -ForegroundColor Gray
        Write-Host "  Target Count: $($status.Configuration.Targets.Count)" -ForegroundColor Gray
        Write-Host "Statistics:" -ForegroundColor White
        if ($status.Statistics) {
            Write-Host "  Files Processed: $($status.Statistics.TotalFilesProcessed)" -ForegroundColor Gray
            Write-Host "  Files Succeeded: $($status.Statistics.TotalFilesSucceeded)" -ForegroundColor Gray
            Write-Host "  Files Failed: $($status.Statistics.TotalFilesFailed)" -ForegroundColor Gray
        }
        Write-Host "================================`n" -ForegroundColor Cyan
    } else {
        Write-Host "`n=== FileCopier Service Status ===" -ForegroundColor Cyan
        Write-Host "Status: Not Running" -ForegroundColor Red
        Write-Host "================================`n" -ForegroundColor Cyan
    }
}

# Main execution logic
function Main {
    Write-ServiceLog "FileCopier Service Entry Point Started" -Level "Information" -Properties @{
        Operation = $Operation
        ScriptPath = $script:ScriptPath
        ConfigPath = $ConfigPath
        SourceDirectory = $SourceDirectory
        Interactive = $Interactive.IsPresent
        Console = $Console.IsPresent
        ProcessId = $PID
    }

    # Initialize event log for service mode
    if (-not $Interactive -and -not $Console) {
        Initialize-ServiceEventLog
    }

    switch ($Operation.ToLower()) {
        "start" {
            try {
                # Load configuration
                $config = Get-ServiceConfiguration -ConfigFilePath $ConfigPath

                # Start the service
                $started = Start-FileCopierService -Config $config -SourceDir $SourceDirectory

                if ($started) {
                    if ($Interactive -or $Console) {
                        Show-ServiceStatus
                        Wait-ForServiceShutdown
                    } else {
                        # Service mode - run indefinitely
                        Wait-For-ServiceShutdown
                    }
                } else {
                    Write-ServiceLog "Failed to start service" -Level "Error"
                    exit 1
                }
            }
            catch {
                Write-ServiceLog "Critical error during service startup: $($_.Exception.Message)" -Level "Error"
                exit 1
            }
            finally {
                # Always attempt graceful shutdown
                try {
                    Stop-FileCopierService | Out-Null
                    Write-ServiceLog "Service shutdown completed" -Level "Information"
                }
                catch {
                    Write-ServiceLog "Error during service shutdown: $($_.Exception.Message)" -Level "Error"
                }
            }
        }

        "stop" {
            $stopped = Stop-FileCopierService
            if ($stopped) {
                Write-Host "FileCopier Service stopped successfully" -ForegroundColor Green
                exit 0
            } else {
                Write-Host "Failed to stop FileCopier Service" -ForegroundColor Red
                exit 1
            }
        }

        "restart" {
            Write-Host "Restarting FileCopier Service..." -ForegroundColor Yellow
            Stop-FileCopierService | Out-Null
            Start-Sleep -Seconds 2

            $config = Get-ServiceConfiguration -ConfigFilePath $ConfigPath
            $restarted = Start-FileCopierService -Config $config -SourceDir $SourceDirectory

            if ($restarted) {
                Write-Host "FileCopier Service restarted successfully" -ForegroundColor Green
                exit 0
            } else {
                Write-Host "Failed to restart FileCopier Service" -ForegroundColor Red
                exit 1
            }
        }

        "status" {
            Show-ServiceStatus
            exit 0
        }

        default {
            Write-Host "Invalid operation: $Operation" -ForegroundColor Red
            Write-Host "Valid operations: Start, Stop, Restart, Status, Install, Uninstall" -ForegroundColor Yellow
            exit 1
        }
    }
}

# Trap Ctrl+C and other termination signals
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-ServiceLog "PowerShell exiting - attempting graceful service shutdown" -Level "Information"
    if ($script:GlobalService) {
        try {
            Stop-FileCopierService -Service $script:GlobalService | Out-Null
        }
        catch {
            Write-ServiceLog "Error during exit cleanup: $($_.Exception.Message)" -Level "Error"
        }
    }
}

# Handle console control events
try {
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class ConsoleControl {
            public delegate bool ControlEventHandler(int eventType);
            [DllImport("kernel32.dll")]
            public static extern bool SetConsoleCtrlHandler(ControlEventHandler handler, bool add);
        }
"@

    $handler = {
        param($eventType)
        Write-ServiceLog "Console control event received: $eventType" -Level "Information"
        $script:IsRunning = $false
        if ($script:GlobalService) {
            Stop-FileCopierService -Service $script:GlobalService | Out-Null
        }
        return $true
    }

    [ConsoleControl]::SetConsoleCtrlHandler($handler, $true) | Out-Null
}
catch {
    Write-ServiceLog "Warning: Could not register console control handler: $($_.Exception.Message)" -Level "Warning"
}

# Execute main function
try {
    Main
}
catch {
    Write-ServiceLog "Unhandled exception in main execution: $($_.Exception.Message)" -Level "Error" -Properties @{
        Exception = $_.Exception.GetType().Name
        StackTrace = $_.ScriptStackTrace
    }
    exit 1
}