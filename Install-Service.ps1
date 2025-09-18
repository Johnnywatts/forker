# Install-Service.ps1 - NSSM service installation and management script
# Part of Phase 5A: Service Deployment
# Handles installation, configuration, and management of FileCopier as Windows Service

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Service installation action")]
    [ValidateSet("Install", "Uninstall", "Start", "Stop", "Restart", "Status", "Configure", "Validate")]
    [string]$Action = "Install",

    [Parameter(Mandatory = $false, HelpMessage = "Custom service name")]
    [string]$ServiceName = "FileCopierService",

    [Parameter(Mandatory = $false, HelpMessage = "Path to configuration file")]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false, HelpMessage = "Source directory to monitor")]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $false, HelpMessage = "Installation directory")]
    [string]$InstallDirectory = "C:\FileCopier",

    [Parameter(Mandatory = $false, HelpMessage = "Path to NSSM executable")]
    [string]$NSSMPath,

    [Parameter(Mandatory = $false, HelpMessage = "Service startup type")]
    [ValidateSet("Automatic", "Manual", "Disabled")]
    [string]$StartupType = "Automatic",

    [Parameter(Mandatory = $false, HelpMessage = "Service account username")]
    [string]$ServiceAccount,

    [Parameter(Mandatory = $false, HelpMessage = "Service account password")]
    [SecureString]$ServicePassword,

    [Parameter(Mandatory = $false, HelpMessage = "Force overwrite existing installation")]
    [switch]$Force,

    [Parameter(Mandatory = $false, HelpMessage = "Validate installation without making changes")]
    [switch]$WhatIf
)

# Script constants
$script:ServiceDisplayName = "File Copier Service for SVS Files"
$script:ServiceDescription = "Automated file copying service optimized for large SVS medical imaging files with verification and multi-target support"
$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StartScript = Join-Path $script:ScriptDirectory "Start-FileCopier.ps1"

# Service configuration defaults
$script:ServiceDefaults = @{
    DisplayName = $script:ServiceDisplayName
    Description = $script:ServiceDescription
    StartupType = $StartupType
    Account = if ($ServiceAccount) { $ServiceAccount } else { "LocalSystem" }
    DependsOn = @("Eventlog")
    Recovery = @{
        RestartDelay = 60000  # 1 minute
        RestartCount = 3
        RebootDelay = 300000  # 5 minutes
    }
    Logging = @{
        LogPath = "$InstallDirectory\Logs"
        MaxLogSizeMB = 10
        RotationDays = 30
    }
    Performance = @{
        MaxMemoryMB = 1024
        CPUPriority = "Normal"
        IOPriority = "Normal"
    }
}

function Write-InstallLog {
    param(
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error", "Success")]
        [string]$Level = "Information"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Error" { "Red" }
        "Warning" { "Yellow" }
        "Success" { "Green" }
        default { "White" }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-AdminPrivileges {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-NSSMExecutable {
    param([string]$CustomPath)

    # Check custom path first
    if ($CustomPath -and (Test-Path $CustomPath)) {
        return $CustomPath
    }

    # Check common NSSM installation locations
    $commonPaths = @(
        "${env:ProgramFiles}\NSSM\win64\nssm.exe",
        "${env:ProgramFiles(x86)}\NSSM\win64\nssm.exe",
        "${env:ProgramFiles}\NSSM\win32\nssm.exe",
        "${env:ProgramFiles(x86)}\NSSM\win32\nssm.exe",
        (Join-Path $script:ScriptDirectory "tools\nssm.exe"),
        "nssm.exe"  # Check PATH
    )

    foreach ($path in $commonPaths) {
        if (Test-Path $path -ErrorAction SilentlyContinue) {
            return $path
        }
    }

    # Try to find nssm in PATH
    try {
        $nssmInPath = Get-Command "nssm.exe" -ErrorAction Stop
        return $nssmInPath.Source
    }
    catch {
        return $null
    }
}

function Install-NSSMIfNeeded {
    param([string]$NSSMExecutable)

    if ($NSSMExecutable -and (Test-Path $NSSMExecutable)) {
        return $NSSMExecutable
    }

    Write-InstallLog "NSSM not found. Attempting to download and install..." -Level "Warning"

    # Create tools directory
    $toolsDir = Join-Path $script:ScriptDirectory "tools"
    if (-not (Test-Path $toolsDir)) {
        New-Item -Path $toolsDir -ItemType Directory -Force | Out-Null
    }

    $nssmZip = Join-Path $toolsDir "nssm.zip"
    $nssmDir = Join-Path $toolsDir "nssm"
    $nssmExe = Join-Path $nssmDir "win64\nssm.exe"

    try {
        # Download NSSM
        Write-InstallLog "Downloading NSSM from official website..." -Level "Information"
        $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing

        # Extract NSSM
        Write-InstallLog "Extracting NSSM..." -Level "Information"
        if (Test-Path $nssmDir) {
            Remove-Item -Path $nssmDir -Recurse -Force
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nssmZip, $toolsDir)

        # Find the extracted nssm directory (it might have version in name)
        $extractedDirs = Get-ChildItem -Path $toolsDir -Directory | Where-Object { $_.Name -like "nssm*" }
        if ($extractedDirs) {
            $actualNssmDir = $extractedDirs[0].FullName
            if ($actualNssmDir -ne $nssmDir) {
                Rename-Item -Path $actualNssmDir -NewName $nssmDir
            }
        }

        # Clean up
        Remove-Item -Path $nssmZip -Force -ErrorAction SilentlyContinue

        # Verify installation
        if (Test-Path $nssmExe) {
            Write-InstallLog "NSSM downloaded and extracted successfully" -Level "Success"
            return $nssmExe
        } else {
            throw "NSSM executable not found after extraction"
        }
    }
    catch {
        Write-InstallLog "Failed to download/install NSSM: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

function Test-ServiceExists {
    param([string]$Name)

    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Install-FileCopierService {
    param(
        [string]$NSSMPath,
        [hashtable]$Config
    )

    Write-InstallLog "Installing FileCopier Service..." -Level "Information"

    try {
        # Check if service already exists
        if (Test-ServiceExists -Name $ServiceName) {
            if ($Force) {
                Write-InstallLog "Service exists, removing due to -Force parameter..." -Level "Warning"
                Uninstall-FileCopierService -NSSMPath $NSSMPath
            } else {
                Write-InstallLog "Service '$ServiceName' already exists. Use -Force to overwrite." -Level "Error"
                return $false
            }
        }

        # Prepare service installation command
        $serviceArgs = @(
            "install",
            $ServiceName,
            "`"$script:StartScript`"",
            "-Operation", "Start",
            "-Console:$false"
        )

        # Add configuration path if specified
        if ($ConfigPath) {
            $serviceArgs += "-ConfigPath"
            $serviceArgs += "`"$ConfigPath`""
        }

        # Add source directory if specified
        if ($SourceDirectory) {
            $serviceArgs += "-SourceDirectory"
            $serviceArgs += "`"$SourceDirectory`""
        }

        Write-InstallLog "Executing NSSM install command..." -Level "Information"
        Write-InstallLog "Command: $NSSMPath $($serviceArgs -join ' ')" -Level "Information"

        # Install service with NSSM
        $installResult = & $NSSMPath $serviceArgs 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-InstallLog "Service installed successfully" -Level "Success"
        } else {
            Write-InstallLog "NSSM install failed with exit code: $LASTEXITCODE" -Level "Error"
            Write-InstallLog "Output: $installResult" -Level "Error"
            return $false
        }

        # Configure service properties
        Configure-ServiceProperties -NSSMPath $NSSMPath -Config $Config

        Write-InstallLog "FileCopier Service installation completed successfully" -Level "Success"
        return $true
    }
    catch {
        Write-InstallLog "Error during service installation: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Configure-ServiceProperties {
    param(
        [string]$NSSMPath,
        [hashtable]$Config
    )

    Write-InstallLog "Configuring service properties..." -Level "Information"

    $configurations = @(
        @{ Param = "DisplayName"; Value = $script:ServiceDefaults.DisplayName },
        @{ Param = "Description"; Value = $script:ServiceDefaults.Description },
        @{ Param = "Start"; Value = $script:ServiceDefaults.StartupType },
        @{ Param = "AppDirectory"; Value = $script:ScriptDirectory },
        @{ Param = "AppStdout"; Value = "$($script:ServiceDefaults.Logging.LogPath)\service-stdout.log" },
        @{ Param = "AppStderr"; Value = "$($script:ServiceDefaults.Logging.LogPath)\service-stderr.log" },
        @{ Param = "AppRotateFiles"; Value = "1" },
        @{ Param = "AppRotateOnline"; Value = "1" },
        @{ Param = "AppRotateBytes"; Value = ($script:ServiceDefaults.Logging.MaxLogSizeMB * 1024 * 1024).ToString() }
    )

    # Configure service account if specified
    if ($ServiceAccount) {
        $configurations += @{ Param = "ObjectName"; Value = $ServiceAccount }
    }

    # Configure dependencies
    if ($script:ServiceDefaults.DependsOn) {
        $dependencies = $script:ServiceDefaults.DependsOn -join "/"
        $configurations += @{ Param = "DependOnService"; Value = $dependencies }
    }

    # Apply configurations
    foreach ($config in $configurations) {
        try {
            Write-InstallLog "Setting $($config.Param) = $($config.Value)" -Level "Information"
            $result = & $NSSMPath "set" $ServiceName $config.Param $config.Value 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-InstallLog "Warning: Failed to set $($config.Param): $result" -Level "Warning"
            }
        }
        catch {
            Write-InstallLog "Error setting $($config.Param): $($_.Exception.Message)" -Level "Warning"
        }
    }

    # Configure service recovery options
    Configure-ServiceRecovery -NSSMPath $NSSMPath
}

function Configure-ServiceRecovery {
    param([string]$NSSMPath)

    Write-InstallLog "Configuring service recovery options..." -Level "Information"

    $recoverySettings = @(
        @{ Param = "AppExit"; Value = "Default"; Action = "Restart" },
        @{ Param = "AppRestartDelay"; Value = $script:ServiceDefaults.Recovery.RestartDelay.ToString() },
        @{ Param = "AppStopMethodSkip"; Value = "0" },
        @{ Param = "AppStopMethodConsole"; Value = "30000" },  # 30 second timeout
        @{ Param = "AppStopMethodWindow"; Value = "30000" },
        @{ Param = "AppStopMethodThreads"; Value = "30000" }
    )

    foreach ($setting in $recoverySettings) {
        try {
            $result = & $NSSMPath "set" $ServiceName $setting.Param $setting.Value 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-InstallLog "Warning: Failed to set recovery setting $($setting.Param): $result" -Level "Warning"
            }
        }
        catch {
            Write-InstallLog "Error setting recovery $($setting.Param): $($_.Exception.Message)" -Level "Warning"
        }
    }
}

function Uninstall-FileCopierService {
    param([string]$NSSMPath)

    Write-InstallLog "Uninstalling FileCopier Service..." -Level "Information"

    try {
        # Check if service exists
        if (-not (Test-ServiceExists -Name $ServiceName)) {
            Write-InstallLog "Service '$ServiceName' does not exist" -Level "Warning"
            return $true
        }

        # Stop service if running
        try {
            $service = Get-Service -Name $ServiceName
            if ($service.Status -eq 'Running') {
                Write-InstallLog "Stopping service before removal..." -Level "Information"
                Stop-Service -Name $ServiceName -Force -Timeout 30
                Start-Sleep -Seconds 2
            }
        }
        catch {
            Write-InstallLog "Warning: Could not stop service: $($_.Exception.Message)" -Level "Warning"
        }

        # Remove service with NSSM
        $removeResult = & $NSSMPath "remove" $ServiceName "confirm" 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-InstallLog "Service uninstalled successfully" -Level "Success"
            return $true
        } else {
            Write-InstallLog "NSSM remove failed with exit code: $LASTEXITCODE" -Level "Error"
            Write-InstallLog "Output: $removeResult" -Level "Error"
            return $false
        }
    }
    catch {
        Write-InstallLog "Error during service removal: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Start-FileCopierWindowsService {
    param([string]$NSSMPath)

    Write-InstallLog "Starting FileCopier Service..." -Level "Information"

    try {
        if (-not (Test-ServiceExists -Name $ServiceName)) {
            Write-InstallLog "Service '$ServiceName' does not exist" -Level "Error"
            return $false
        }

        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-InstallLog "Service started successfully" -Level "Success"

        # Wait a moment and check status
        Start-Sleep -Seconds 2
        $service = Get-Service -Name $ServiceName
        Write-InstallLog "Service status: $($service.Status)" -Level "Information"

        return $true
    }
    catch {
        Write-InstallLog "Error starting service: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Stop-FileCopierWindowsService {
    param([string]$NSSMPath)

    Write-InstallLog "Stopping FileCopier Service..." -Level "Information"

    try {
        if (-not (Test-ServiceExists -Name $ServiceName)) {
            Write-InstallLog "Service '$ServiceName' does not exist" -Level "Warning"
            return $true
        }

        $service = Get-Service -Name $ServiceName
        if ($service.Status -ne 'Running') {
            Write-InstallLog "Service is not running" -Level "Information"
            return $true
        }

        Stop-Service -Name $ServiceName -Force -Timeout 30 -ErrorAction Stop
        Write-InstallLog "Service stopped successfully" -Level "Success"

        return $true
    }
    catch {
        Write-InstallLog "Error stopping service: $($_.Exception.Message)" -Level "Error"
        return $false
    }
}

function Get-FileCopierServiceStatus {
    try {
        if (-not (Test-ServiceExists -Name $ServiceName)) {
            Write-Host "Service Status: Not Installed" -ForegroundColor Red
            return
        }

        $service = Get-Service -Name $ServiceName
        $statusColor = switch ($service.Status) {
            'Running' { 'Green' }
            'Stopped' { 'Red' }
            default { 'Yellow' }
        }

        Write-Host "`n=== FileCopier Service Status ===" -ForegroundColor Cyan
        Write-Host "Service Name: $($service.Name)" -ForegroundColor White
        Write-Host "Display Name: $($service.DisplayName)" -ForegroundColor White
        Write-Host "Status: $($service.Status)" -ForegroundColor $statusColor
        Write-Host "Startup Type: $($service.StartType)" -ForegroundColor White

        # Get additional service information
        try {
            $serviceWmi = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'"
            if ($serviceWmi) {
                Write-Host "Service Account: $($serviceWmi.StartName)" -ForegroundColor White
                Write-Host "Process ID: $($serviceWmi.ProcessId)" -ForegroundColor White
            }
        }
        catch {
            Write-InstallLog "Could not retrieve additional service information" -Level "Warning"
        }

        Write-Host "================================`n" -ForegroundColor Cyan
    }
    catch {
        Write-InstallLog "Error getting service status: $($_.Exception.Message)" -Level "Error"
    }
}

function Test-Installation {
    param([string]$NSSMPath)

    Write-InstallLog "Validating FileCopier Service installation..." -Level "Information"

    $validationResults = @{
        NSSMAvailable = $false
        AdminPrivileges = $false
        StartScriptExists = $false
        ModuleExists = $false
        DirectoriesCreated = $false
        ServiceInstalled = $false
        ServiceRunning = $false
    }

    # Check NSSM availability
    $validationResults.NSSMAvailable = (Test-Path $NSSMPath)
    Write-InstallLog "NSSM Available: $($validationResults.NSSMAvailable)" -Level $(if ($validationResults.NSSMAvailable) { "Success" } else { "Error" })

    # Check admin privileges
    $validationResults.AdminPrivileges = Test-AdminPrivileges
    Write-InstallLog "Admin Privileges: $($validationResults.AdminPrivileges)" -Level $(if ($validationResults.AdminPrivileges) { "Success" } else { "Error" })

    # Check start script
    $validationResults.StartScriptExists = (Test-Path $script:StartScript)
    Write-InstallLog "Start Script Exists: $($validationResults.StartScriptExists)" -Level $(if ($validationResults.StartScriptExists) { "Success" } else { "Error" })

    # Check module
    $modulePath = Join-Path $script:ScriptDirectory "modules\FileCopier\FileCopier.psm1"
    $validationResults.ModuleExists = (Test-Path $modulePath)
    Write-InstallLog "Module Exists: $($validationResults.ModuleExists)" -Level $(if ($validationResults.ModuleExists) { "Success" } else { "Error" })

    # Check directories
    $requiredDirs = @($InstallDirectory, "$InstallDirectory\Logs", "$InstallDirectory\Config")
    $allDirsExist = $true
    foreach ($dir in $requiredDirs) {
        if (-not (Test-Path $dir)) {
            $allDirsExist = $false
            break
        }
    }
    $validationResults.DirectoriesCreated = $allDirsExist
    Write-InstallLog "Required Directories: $($validationResults.DirectoriesCreated)" -Level $(if ($validationResults.DirectoriesCreated) { "Success" } else { "Warning" })

    # Check service installation
    $validationResults.ServiceInstalled = Test-ServiceExists -Name $ServiceName
    Write-InstallLog "Service Installed: $($validationResults.ServiceInstalled)" -Level $(if ($validationResults.ServiceInstalled) { "Success" } else { "Warning" })

    # Check service status
    if ($validationResults.ServiceInstalled) {
        try {
            $service = Get-Service -Name $ServiceName
            $validationResults.ServiceRunning = ($service.Status -eq 'Running')
        }
        catch {
            $validationResults.ServiceRunning = $false
        }
    }
    Write-InstallLog "Service Running: $($validationResults.ServiceRunning)" -Level $(if ($validationResults.ServiceRunning) { "Success" } else { "Warning" })

    # Overall assessment
    $criticalIssues = @()
    if (-not $validationResults.NSSMAvailable) { $criticalIssues += "NSSM not available" }
    if (-not $validationResults.AdminPrivileges) { $criticalIssues += "Admin privileges required" }
    if (-not $validationResults.StartScriptExists) { $criticalIssues += "Start script missing" }
    if (-not $validationResults.ModuleExists) { $criticalIssues += "Module missing" }

    if ($criticalIssues.Count -eq 0) {
        Write-InstallLog "Validation completed - Ready for installation" -Level "Success"
        return $true
    } else {
        Write-InstallLog "Validation failed - Critical issues: $($criticalIssues -join ', ')" -Level "Error"
        return $false
    }
}

function Initialize-InstallDirectories {
    Write-InstallLog "Creating installation directories..." -Level "Information"

    $directories = @(
        $InstallDirectory,
        "$InstallDirectory\Logs",
        "$InstallDirectory\Config",
        "$InstallDirectory\Quarantine",
        "$InstallDirectory\Watch",
        "$InstallDirectory\TargetA",
        "$InstallDirectory\TargetB"
    )

    foreach ($dir in $directories) {
        try {
            if (-not (Test-Path $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
                Write-InstallLog "Created directory: $dir" -Level "Information"
            } else {
                Write-InstallLog "Directory exists: $dir" -Level "Information"
            }
        }
        catch {
            Write-InstallLog "Failed to create directory $dir : $($_.Exception.Message)" -Level "Error"
            return $false
        }
    }

    return $true
}

# Main execution logic
function Main {
    Write-InstallLog "FileCopier Service Installation Script Started" -Level "Information"
    Write-InstallLog "Action: $Action, Service Name: $ServiceName" -Level "Information"

    # Check admin privileges for most operations
    if ($Action -in @("Install", "Uninstall", "Configure") -and -not (Test-AdminPrivileges)) {
        Write-InstallLog "Administrator privileges required for action: $Action" -Level "Error"
        Write-InstallLog "Please run this script as Administrator" -Level "Error"
        exit 1
    }

    # Find NSSM executable
    $nssmExecutable = Find-NSSMExecutable -CustomPath $NSSMPath

    if (-not $nssmExecutable -and $Action -in @("Install", "Uninstall", "Configure")) {
        Write-InstallLog "Attempting to install NSSM automatically..." -Level "Information"
        $nssmExecutable = Install-NSSMIfNeeded -NSSMExecutable $nssmExecutable

        if (-not $nssmExecutable) {
            Write-InstallLog "NSSM is required but not found. Please install NSSM or specify path with -NSSMPath" -Level "Error"
            Write-InstallLog "Download from: https://nssm.cc/download" -Level "Information"
            exit 1
        }
    }

    Write-InstallLog "Using NSSM: $nssmExecutable" -Level "Information"

    # Execute requested action
    switch ($Action.ToLower()) {
        "install" {
            if ($WhatIf) {
                Write-InstallLog "WhatIf: Would install service with following configuration:" -Level "Information"
                Write-InstallLog "  Service Name: $ServiceName" -Level "Information"
                Write-InstallLog "  NSSM Path: $nssmExecutable" -Level "Information"
                Write-InstallLog "  Start Script: $script:StartScript" -Level "Information"
                Write-InstallLog "  Install Directory: $InstallDirectory" -Level "Information"
                exit 0
            }

            # Initialize directories
            if (-not (Initialize-InstallDirectories)) {
                exit 1
            }

            # Install service
            $success = Install-FileCopierService -NSSMPath $nssmExecutable -Config $script:ServiceDefaults

            if ($success) {
                Write-InstallLog "Installation completed successfully!" -Level "Success"
                Write-InstallLog "Use 'Install-Service.ps1 -Action Start' to start the service" -Level "Information"
                exit 0
            } else {
                Write-InstallLog "Installation failed" -Level "Error"
                exit 1
            }
        }

        "uninstall" {
            $success = Uninstall-FileCopierService -NSSMPath $nssmExecutable
            exit $(if ($success) { 0 } else { 1 })
        }

        "start" {
            $success = Start-FileCopierWindowsService -NSSMPath $nssmExecutable
            exit $(if ($success) { 0 } else { 1 })
        }

        "stop" {
            $success = Stop-FileCopierWindowsService -NSSMPath $nssmExecutable
            exit $(if ($success) { 0 } else { 1 })
        }

        "restart" {
            Write-InstallLog "Restarting FileCopier Service..." -Level "Information"
            Stop-FileCopierWindowsService -NSSMPath $nssmExecutable | Out-Null
            Start-Sleep -Seconds 3
            $success = Start-FileCopierWindowsService -NSSMPath $nssmExecutable
            exit $(if ($success) { 0 } else { 1 })
        }

        "status" {
            Get-FileCopierServiceStatus
            exit 0
        }

        "validate" {
            $valid = Test-Installation -NSSMPath $nssmExecutable
            exit $(if ($valid) { 0 } else { 1 })
        }

        "configure" {
            if (Test-ServiceExists -Name $ServiceName) {
                Configure-ServiceProperties -NSSMPath $nssmExecutable -Config $script:ServiceDefaults
                Write-InstallLog "Service configuration updated" -Level "Success"
                exit 0
            } else {
                Write-InstallLog "Service not installed. Run with -Action Install first." -Level "Error"
                exit 1
            }
        }

        default {
            Write-InstallLog "Invalid action: $Action" -Level "Error"
            Write-InstallLog "Valid actions: Install, Uninstall, Start, Stop, Restart, Status, Configure, Validate" -Level "Information"
            exit 1
        }
    }
}

# Execute main function
Main