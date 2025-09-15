# Logging.ps1 - Comprehensive logging infrastructure for File Copier Service

#region Module Variables
$script:LogConfig = $null
$script:EventLogSource = $null
$script:LogFileHandle = $null
$script:PerformanceCounters = @{}
#endregion

#region Core Logging Functions
function Initialize-FileCopierLogging {
    <#
    .SYNOPSIS
        Initializes the File Copier logging system.

    .DESCRIPTION
        Sets up logging configuration, creates event log sources, and initializes file logging.

    .PARAMETER LogLevel
        Minimum log level to write (Trace, Debug, Information, Warning, Error, Critical).

    .PARAMETER LogDirectory
        Directory for log files. If not specified, uses configuration.

    .PARAMETER EventLogSource
        Windows Event Log source name. If not specified, uses configuration.

    .PARAMETER EnableFileLogging
        Whether to enable file-based logging.

    .PARAMETER EnableEventLogging
        Whether to enable Windows Event Log logging.

    .PARAMETER EnableConsoleLogging
        Whether to enable console logging.

    .EXAMPLE
        Initialize-FileCopierLogging -LogLevel "Information" -EnableFileLogging -EnableEventLogging
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$LogLevel = 'Information',

        [string]$LogDirectory,
        [string]$EventLogSource = 'FileCopierService',
        [switch]$EnableFileLogging = $true,
        [switch]$EnableEventLogging = $true,
        [switch]$EnableConsoleLogging = $false
    )

    try {
        # Get configuration if not provided
        if (-not $LogDirectory) {
            try {
                $config = Get-FileCopierConfig
                $LogDirectory = $config.logging.logDirectory
                if (-not $EventLogSource) {
                    $EventLogSource = $config.logging.eventLogSource
                }
                # Only use config values if not explicitly provided
                if (-not $PSBoundParameters.ContainsKey('EnableFileLogging')) {
                    $EnableFileLogging = $config.logging.fileLogging
                }
                if (-not $PSBoundParameters.ContainsKey('LogLevel')) {
                    $LogLevel = $config.logging.level
                }
            }
            catch {
                Write-Warning "Could not load configuration, using defaults: $_"
                $LogDirectory = if ($IsWindows) { "C:\FileCopier\logs" } else { "/tmp/filecopier/logs" }
            }
        }

        # Initialize logging configuration
        $script:LogConfig = @{
            Level = $LogLevel
            LevelNumeric = Get-LogLevelNumeric -Level $LogLevel
            Directory = $LogDirectory
            EventLogSource = $EventLogSource
            EnableFileLogging = $EnableFileLogging
            EnableEventLogging = $EnableEventLogging
            EnableConsoleLogging = $EnableConsoleLogging
            MaxLogSizeMB = 100
            LogRetentionDays = 30
        }

        # Create log directory if it doesn't exist
        if ($EnableFileLogging -and -not (Test-Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
            Write-Verbose "Created log directory: $LogDirectory"
        }

        # Initialize Windows Event Log source
        if ($EnableEventLogging) {
            Initialize-EventLogSource -Source $EventLogSource
        }

        # Initialize performance counters
        Initialize-PerformanceCounters

        Write-FileCopierLog -Message "File Copier logging initialized. Level: $LogLevel, Directory: $LogDirectory" -Level 'Information'
    }
    catch {
        Write-Error "Failed to initialize logging: $($_.Exception.Message)"
        throw
    }
}

function Write-FileCopierLog {
    <#
    .SYNOPSIS
        Writes a structured log message to all configured log outputs.

    .DESCRIPTION
        Writes log messages with consistent formatting to file, event log, and/or console.

    .PARAMETER Message
        The log message to write.

    .PARAMETER Level
        Log level (Trace, Debug, Information, Warning, Error, Critical).

    .PARAMETER Category
        Optional category for grouping related log messages.

    .PARAMETER Properties
        Hashtable of additional structured properties to log.

    .PARAMETER Exception
        Exception object to log with full details.

    .PARAMETER OperationId
        Optional operation ID for correlating related log entries.

    .EXAMPLE
        Write-FileCopierLog -Message "File copy started" -Level "Information" -Category "FileOperation" -Properties @{SourceFile="test.svs"; TargetFile="backup.svs"}

    .EXAMPLE
        Write-FileCopierLog -Message "Configuration error" -Level "Error" -Exception $_.Exception
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$Level,

        [string]$Category = 'General',
        [hashtable]$Properties = @{},
        [System.Exception]$Exception,
        [string]$OperationId
    )

    # Check if logging is initialized
    if (-not $script:LogConfig) {
        # Fallback to simple console logging
        Write-Host "[$Level] $Message"
        return
    }

    # Check log level filtering
    $messageLevel = Get-LogLevelNumeric -Level $Level
    if ($messageLevel -lt $script:LogConfig.LevelNumeric) {
        return
    }

    # Create structured log entry
    $logEntry = New-LogEntry -Message $Message -Level $Level -Category $Category -Properties $Properties -Exception $Exception -OperationId $OperationId

    # Write to enabled outputs
    if ($script:LogConfig.EnableFileLogging) {
        Write-FileLog -LogEntry $logEntry
    }

    if ($script:LogConfig.EnableEventLogging) {
        Write-EventLog -LogEntry $logEntry
    }

    if ($script:LogConfig.EnableConsoleLogging) {
        Write-ConsoleLog -LogEntry $logEntry
    }

    # Update performance counters
    Update-LoggingCounters -Level $Level
}

function Set-FileCopierLogLevel {
    <#
    .SYNOPSIS
        Changes the current logging level.

    .PARAMETER Level
        New log level to set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$Level
    )

    if ($script:LogConfig) {
        $script:LogConfig.Level = $Level
        $script:LogConfig.LevelNumeric = Get-LogLevelNumeric -Level $Level
        Write-FileCopierLog -Message "Log level changed to: $Level" -Level 'Information' -Category 'Configuration'
    }
    else {
        Write-Warning "Logging not initialized. Call Initialize-FileCopierLogging first."
    }
}

function Get-FileCopierLogLevel {
    <#
    .SYNOPSIS
        Gets the current logging level.
    #>
    if ($script:LogConfig) {
        return $script:LogConfig.Level
    }
    return 'Information'
}
#endregion

#region Helper Functions
function Get-LogLevelNumeric {
    param([string]$Level)

    switch ($Level) {
        'Trace' { return 0 }
        'Debug' { return 1 }
        'Information' { return 2 }
        'Warning' { return 3 }
        'Error' { return 4 }
        'Critical' { return 5 }
        default { return 2 }
    }
}

function New-LogEntry {
    param(
        [string]$Message,
        [string]$Level,
        [string]$Category,
        [hashtable]$Properties,
        [System.Exception]$Exception,
        [string]$OperationId
    )

    $entry = @{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Level = $Level
        Category = $Category
        Message = $Message
        ProcessId = $PID
        ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        MachineName = $env:COMPUTERNAME
        OperationId = $OperationId
        Properties = $Properties
    }

    if ($Exception) {
        $entry.Exception = @{
            Type = $Exception.GetType().FullName
            Message = $Exception.Message
            StackTrace = $Exception.StackTrace
        }
        if ($Exception.InnerException) {
            $entry.Exception.InnerException = @{
                Type = $Exception.InnerException.GetType().FullName
                Message = $Exception.InnerException.Message
            }
        }
    }

    return $entry
}
#endregion

#region File Logging
function Write-FileLog {
    param($LogEntry)

    try {
        $logFile = Get-LogFileName
        $formattedMessage = Format-LogMessage -LogEntry $LogEntry -Format 'File'

        # Check if log rotation is needed
        if (Test-LogRotationNeeded -LogFile $logFile) {
            Invoke-LogRotation -LogFile $logFile
        }

        Add-Content -Path $logFile -Value $formattedMessage -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to write to log file: $($_.Exception.Message)"
    }
}

function Get-LogFileName {
    $date = Get-Date -Format 'yyyy-MM-dd'
    $fileName = "FileCopier-$date.log"
    return Join-Path $script:LogConfig.Directory $fileName
}

function Test-LogRotationNeeded {
    param([string]$LogFile)

    if (-not (Test-Path $LogFile)) {
        return $false
    }

    $fileInfo = Get-Item $LogFile
    $maxSizeBytes = $script:LogConfig.MaxLogSizeMB * 1MB
    return ($fileInfo.Length -gt $maxSizeBytes)
}

function Invoke-LogRotation {
    param([string]$LogFile)

    try {
        $timestamp = Get-Date -Format 'HHmmss'
        $rotatedFile = $LogFile -replace '\.log$', "-$timestamp.log"
        Move-Item -Path $LogFile -Destination $rotatedFile -Force

        # Clean up old log files
        $cutoffDate = (Get-Date).AddDays(-$script:LogConfig.LogRetentionDays)
        $logDirectory = $script:LogConfig.Directory
        $oldLogs = Get-ChildItem -Path $logDirectory -Filter "FileCopier-*.log" | Where-Object { $_.LastWriteTime -lt $cutoffDate }

        foreach ($oldLog in $oldLogs) {
            Remove-Item -Path $oldLog.FullName -Force
            Write-FileCopierLog -Message "Removed old log file: $($oldLog.Name)" -Level 'Debug' -Category 'Maintenance'
        }
    }
    catch {
        Write-Warning "Log rotation failed: $($_.Exception.Message)"
    }
}
#endregion

#region Event Log Integration
function Initialize-EventLogSource {
    param([string]$Source)

    try {
        if ($IsWindows) {
            # Check if source exists
            if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
                # Try to create the source (requires elevated privileges)
                try {
                    [System.Diagnostics.EventLog]::CreateEventSource($Source, 'Application')
                    $script:EventLogSource = $Source
                    Write-Verbose "Created Event Log source: $Source"
                }
                catch [System.Security.SecurityException] {
                    Write-Warning "Cannot create Event Log source '$Source' - insufficient privileges. Event logging will be disabled."
                    $script:LogConfig.EnableEventLogging = $false
                    return
                }
                catch {
                    Write-Warning "Failed to create Event Log source '$Source': $($_.Exception.Message). Event logging will be disabled."
                    $script:LogConfig.EnableEventLogging = $false
                    return
                }
            }
            else {
                $script:EventLogSource = $Source
                Write-Verbose "Using existing Event Log source: $Source"
            }
        }
        else {
            Write-Warning "Event Log is only available on Windows. Event logging will be disabled."
            $script:LogConfig.EnableEventLogging = $false
        }
    }
    catch {
        Write-Warning "Event Log initialization failed: $($_.Exception.Message). Event logging will be disabled."
        $script:LogConfig.EnableEventLogging = $false
    }
}

function Write-EventLog {
    param($LogEntry)

    if (-not $IsWindows -or -not $script:EventLogSource) {
        return
    }

    try {
        $eventLogLevel = Convert-LogLevelToEventLogLevel -Level $LogEntry.Level
        $eventId = Get-EventIdForCategory -Category $LogEntry.Category
        $message = Format-LogMessage -LogEntry $LogEntry -Format 'EventLog'

        Write-EventLog -LogName 'Application' -Source $script:EventLogSource -EventId $eventId -EntryType $eventLogLevel -Message $message
    }
    catch {
        Write-Warning "Failed to write to Event Log: $($_.Exception.Message)"
    }
}

function Convert-LogLevelToEventLogLevel {
    param([string]$Level)

    switch ($Level) {
        'Trace' { return 'Information' }
        'Debug' { return 'Information' }
        'Information' { return 'Information' }
        'Warning' { return 'Warning' }
        'Error' { return 'Error' }
        'Critical' { return 'Error' }
        default { return 'Information' }
    }
}

function Get-EventIdForCategory {
    param([string]$Category)

    # Map categories to event IDs for better Event Log organization
    $eventIds = @{
        'General' = 1000
        'Configuration' = 1100
        'FileOperation' = 1200
        'Monitoring' = 1300
        'Performance' = 1400
        'Security' = 1500
        'Maintenance' = 1600
    }

    return $eventIds[$Category] ?? 1000
}
#endregion

#region Console Logging
function Write-ConsoleLog {
    param($LogEntry)

    $message = Format-LogMessage -LogEntry $LogEntry -Format 'Console'

    # Use colors for different log levels
    $color = switch ($LogEntry.Level) {
        'Trace' { 'DarkGray' }
        'Debug' { 'Gray' }
        'Information' { 'White' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Critical' { 'Magenta' }
        default { 'White' }
    }

    Write-Host $message -ForegroundColor $color
}
#endregion

#region Message Formatting
function Format-LogMessage {
    param(
        $LogEntry,
        [ValidateSet('File', 'EventLog', 'Console')]
        [string]$Format
    )

    switch ($Format) {
        'File' {
            $msg = "$($LogEntry.Timestamp) [$($LogEntry.Level.ToUpper().PadRight(11))] [$($LogEntry.Category)] $($LogEntry.Message)"

            if ($LogEntry.Properties.Count -gt 0) {
                $props = ($LogEntry.Properties.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                $msg += " | Properties: $props"
            }

            if ($LogEntry.OperationId) {
                $msg += " | OperationId: $($LogEntry.OperationId)"
            }

            if ($LogEntry.Exception) {
                $msg += " | Exception: $($LogEntry.Exception.Type) - $($LogEntry.Exception.Message)"
                if ($LogEntry.Exception.StackTrace) {
                    $msg += "`nStackTrace: $($LogEntry.Exception.StackTrace)"
                }
            }

            return $msg
        }

        'EventLog' {
            $msg = $LogEntry.Message

            if ($LogEntry.Properties.Count -gt 0) {
                $msg += "`n`nProperties:"
                foreach ($prop in $LogEntry.Properties.GetEnumerator()) {
                    $msg += "`n  $($prop.Key): $($prop.Value)"
                }
            }

            if ($LogEntry.Exception) {
                $msg += "`n`nException Details:"
                $msg += "`n  Type: $($LogEntry.Exception.Type)"
                $msg += "`n  Message: $($LogEntry.Exception.Message)"
                if ($LogEntry.Exception.StackTrace) {
                    $msg += "`n  Stack Trace: $($LogEntry.Exception.StackTrace)"
                }
            }

            $msg += "`n`nProcess ID: $($LogEntry.ProcessId)"
            $msg += "`nThread ID: $($LogEntry.ThreadId)"
            if ($LogEntry.OperationId) {
                $msg += "`nOperation ID: $($LogEntry.OperationId)"
            }

            return $msg
        }

        'Console' {
            $msg = "[$($LogEntry.Level.ToUpper())] $($LogEntry.Message)"
            if ($LogEntry.Category -ne 'General') {
                $msg = "[$($LogEntry.Category)] $msg"
            }
            return $msg
        }
    }
}
#endregion

#region Performance Counter Integration
function Initialize-PerformanceCounters {
    $script:PerformanceCounters = @{
        MessagesLogged = @{
            Total = 0
            Trace = 0
            Debug = 0
            Information = 0
            Warning = 0
            Error = 0
            Critical = 0
        }
        LastReset = Get-Date
    }
}

function Update-LoggingCounters {
    param([string]$Level)

    $script:PerformanceCounters.MessagesLogged.Total++
    $script:PerformanceCounters.MessagesLogged[$Level]++
}

function Get-LoggingPerformanceCounters {
    <#
    .SYNOPSIS
        Gets current logging performance counters.
    #>
    return $script:PerformanceCounters
}

function Reset-LoggingPerformanceCounters {
    <#
    .SYNOPSIS
        Resets logging performance counters.
    #>
    Initialize-PerformanceCounters
    Write-FileCopierLog -Message "Performance counters reset" -Level 'Information' -Category 'Maintenance'
}
#endregion

#region Cleanup
function Stop-FileCopierLogging {
    <#
    .SYNOPSIS
        Stops the logging system and performs cleanup.
    #>
    if ($script:LogConfig) {
        Write-FileCopierLog -Message "File Copier logging stopping" -Level 'Information'

        # Close any open file handles
        if ($script:LogFileHandle) {
            $script:LogFileHandle.Close()
            $script:LogFileHandle = $null
        }

        # Clear configuration
        $script:LogConfig = $null
        $script:EventLogSource = $null
    }
}
#endregion

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed