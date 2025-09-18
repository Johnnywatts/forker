using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Threading
using namespace System.IO
using namespace System.Net.Http
using namespace System.Management.Automation

enum IntegrationType {
    WebHook = 0
    RestAPI = 1
    Database = 2
    FileShare = 3
    EventLog = 4
    SNMP = 5
    Email = 6
}

enum IntegrationStatus {
    Unknown = 0
    Connected = 1
    Disconnected = 2
    Error = 3
    Disabled = 4
}

class IntegrationEndpoint {
    [string] $Name
    [IntegrationType] $Type
    [string] $Endpoint
    [hashtable] $Configuration
    [IntegrationStatus] $Status
    [DateTime] $LastSuccessfulConnection
    [DateTime] $LastAttempt
    [string] $LastError
    [int] $FailureCount
    [bool] $Enabled

    IntegrationEndpoint([string]$name, [IntegrationType]$type, [string]$endpoint, [hashtable]$config) {
        $this.Name = $name
        $this.Type = $type
        $this.Endpoint = $endpoint
        $this.Configuration = $config
        $this.Status = [IntegrationStatus]::Unknown
        $this.LastSuccessfulConnection = [DateTime]::MinValue
        $this.LastAttempt = [DateTime]::MinValue
        $this.LastError = ""
        $this.FailureCount = 0
        $this.Enabled = $true
    }

    [hashtable] ToHashtable() {
        return @{
            Name = $this.Name
            Type = $this.Type.ToString()
            Endpoint = $this.Endpoint
            Status = $this.Status.ToString()
            LastSuccessfulConnection = if ($this.LastSuccessfulConnection -ne [DateTime]::MinValue) { $this.LastSuccessfulConnection.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
            LastAttempt = if ($this.LastAttempt -ne [DateTime]::MinValue) { $this.LastAttempt.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
            LastError = $this.LastError
            FailureCount = $this.FailureCount
            Enabled = $this.Enabled
        }
    }
}

class IntegrationEvent {
    [string] $Id
    [DateTime] $Timestamp
    [string] $EventType
    [string] $Source
    [hashtable] $Data
    [string] $CorrelationId

    IntegrationEvent([string]$eventType, [string]$source, [hashtable]$data, [string]$correlationId = "") {
        $this.Id = [Guid]::NewGuid().ToString()
        $this.Timestamp = Get-Date
        $this.EventType = $eventType
        $this.Source = $source
        $this.Data = $data
        $this.CorrelationId = if ($correlationId) { $correlationId } else { [Guid]::NewGuid().ToString() }
    }
}

class SystemIntegrationMonitor {
    [hashtable] $Config
    [object] $Logger
    [List[IntegrationEndpoint]] $Endpoints
    [ConcurrentQueue[IntegrationEvent]] $EventQueue
    [System.Threading.Timer] $MonitoringTimer
    [System.Threading.Timer] $EventProcessingTimer
    [bool] $IsRunning
    [HttpClient] $HttpClient
    [object] $LockObject

    SystemIntegrationMonitor([hashtable]$config, [object]$logger) {
        $this.Config = $config
        $this.Logger = $logger
        $this.Endpoints = [List[IntegrationEndpoint]]::new()
        $this.EventQueue = [ConcurrentQueue[IntegrationEvent]]::new()
        $this.IsRunning = $false
        $this.HttpClient = [HttpClient]::new()
        $this.LockObject = [object]::new()

        # Configure HTTP client
        $this.HttpClient.Timeout = [TimeSpan]::FromSeconds(30)

        # Initialize integration endpoints from configuration
        $this.InitializeEndpoints()
    }

    [void] InitializeEndpoints() {
        try {
            # Check if integration configuration exists
            if (-not $this.Config.ContainsKey('Integration')) {
                $this.Logger.LogInformation("No integration configuration found")
                return
            }

            $integrationConfig = $this.Config['Integration']

            # Initialize webhook endpoints
            if ($integrationConfig.ContainsKey('WebHooks')) {
                foreach ($webhook in $integrationConfig['WebHooks']) {
                    $endpoint = [IntegrationEndpoint]::new(
                        $webhook['Name'],
                        [IntegrationType]::WebHook,
                        $webhook['Url'],
                        $webhook
                    )
                    $this.Endpoints.Add($endpoint)
                }
            }

            # Initialize REST API endpoints
            if ($integrationConfig.ContainsKey('APIs')) {
                foreach ($api in $integrationConfig['APIs']) {
                    $endpoint = [IntegrationEndpoint]::new(
                        $api['Name'],
                        [IntegrationType]::RestAPI,
                        $api['BaseUrl'],
                        $api
                    )
                    $this.Endpoints.Add($endpoint)
                }
            }

            # Initialize database connections
            if ($integrationConfig.ContainsKey('Databases')) {
                foreach ($db in $integrationConfig['Databases']) {
                    $endpoint = [IntegrationEndpoint]::new(
                        $db['Name'],
                        [IntegrationType]::Database,
                        $db['ConnectionString'],
                        $db
                    )
                    $this.Endpoints.Add($endpoint)
                }
            }

            # Initialize file share integrations
            if ($integrationConfig.ContainsKey('FileShares')) {
                foreach ($share in $integrationConfig['FileShares']) {
                    $endpoint = [IntegrationEndpoint]::new(
                        $share['Name'],
                        [IntegrationType]::FileShare,
                        $share['Path'],
                        $share
                    )
                    $this.Endpoints.Add($endpoint)
                }
            }

            $this.Logger.LogInformation("Initialized $($this.Endpoints.Count) integration endpoints")
        }
        catch {
            $this.Logger.LogError("Error initializing integration endpoints", $_.Exception)
        }
    }

    [void] Start() {
        if ($this.IsRunning) {
            $this.Logger.LogWarning("System integration monitor is already running")
            return
        }

        try {
            $this.IsRunning = $true

            # Start connectivity monitoring timer (every 5 minutes)
            $this.MonitoringTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $monitor = $state
                    $monitor.CheckEndpointConnectivity()
                },
                $this,
                [TimeSpan]::FromSeconds(30),    # Initial delay
                [TimeSpan]::FromMinutes(5)      # Check interval
            )

            # Start event processing timer (every 30 seconds)
            $this.EventProcessingTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $monitor = $state
                    $monitor.ProcessPendingEvents()
                },
                $this,
                [TimeSpan]::FromSeconds(10),    # Initial delay
                [TimeSpan]::FromSeconds(30)     # Processing interval
            )

            $this.Logger.LogInformation("System integration monitor started")
        }
        catch {
            $this.IsRunning = $false
            $this.Logger.LogError("Failed to start system integration monitor", $_.Exception)
            throw
        }
    }

    [void] Stop() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            $this.IsRunning = $false

            if ($this.MonitoringTimer) {
                $this.MonitoringTimer.Dispose()
                $this.MonitoringTimer = $null
            }

            if ($this.EventProcessingTimer) {
                $this.EventProcessingTimer.Dispose()
                $this.EventProcessingTimer = $null
            }

            if ($this.HttpClient) {
                $this.HttpClient.Dispose()
            }

            $this.Logger.LogInformation("System integration monitor stopped")
        }
        catch {
            $this.Logger.LogError("Error stopping system integration monitor", $_.Exception)
        }
    }

    [void] CheckEndpointConnectivity() {
        try {
            foreach ($endpoint in $this.Endpoints) {
                if (-not $endpoint.Enabled) {
                    continue
                }

                $endpoint.LastAttempt = Get-Date

                try {
                    $success = $this.TestEndpointConnection($endpoint)

                    if ($success) {
                        $endpoint.Status = [IntegrationStatus]::Connected
                        $endpoint.LastSuccessfulConnection = Get-Date
                        $endpoint.FailureCount = 0
                        $endpoint.LastError = ""
                    } else {
                        $endpoint.Status = [IntegrationStatus]::Disconnected
                        $endpoint.FailureCount++
                    }
                }
                catch {
                    $endpoint.Status = [IntegrationStatus]::Error
                    $endpoint.FailureCount++
                    $endpoint.LastError = $_.Exception.Message
                    $this.Logger.LogWarning("Integration endpoint '$($endpoint.Name)' connection failed", $_.Exception)
                }

                # Disable endpoint if it has too many failures
                if ($endpoint.FailureCount -gt 5) {
                    $endpoint.Enabled = $false
                    $endpoint.Status = [IntegrationStatus]::Disabled
                    $this.Logger.LogError("Integration endpoint '$($endpoint.Name)' disabled due to repeated failures")
                }
            }
        }
        catch {
            $this.Logger.LogError("Error checking endpoint connectivity", $_.Exception)
        }
    }

    [bool] TestEndpointConnection([IntegrationEndpoint]$endpoint) {
        switch ($endpoint.Type) {
            ([IntegrationType]::WebHook) {
                return $this.TestWebHookConnection($endpoint)
            }
            ([IntegrationType]::RestAPI) {
                return $this.TestRestAPIConnection($endpoint)
            }
            ([IntegrationType]::Database) {
                return $this.TestDatabaseConnection($endpoint)
            }
            ([IntegrationType]::FileShare) {
                return $this.TestFileShareConnection($endpoint)
            }
            ([IntegrationType]::EventLog) {
                return $this.TestEventLogConnection($endpoint)
            }
            default {
                return $false
            }
        }
        return $false
    }

    [bool] TestWebHookConnection([IntegrationEndpoint]$endpoint) {
        try {
            # Send a simple ping/health check to the webhook
            $pingData = @{
                type = "ping"
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                source = "FileCopier Service"
            }

            $json = $pingData | ConvertTo-Json
            $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")

            $response = $this.HttpClient.PostAsync($endpoint.Endpoint, $content).GetAwaiter().GetResult()
            return $response.IsSuccessStatusCode
        }
        catch {
            return $false
        }
    }

    [bool] TestRestAPIConnection([IntegrationEndpoint]$endpoint) {
        try {
            # Test API health endpoint if configured
            $healthEndpoint = if ($endpoint.Configuration.ContainsKey('HealthEndpoint')) {
                $endpoint.Configuration['HealthEndpoint']
            } else {
                "$($endpoint.Endpoint)/health"
            }

            $response = $this.HttpClient.GetAsync($healthEndpoint).GetAwaiter().GetResult()
            return $response.IsSuccessStatusCode
        }
        catch {
            return $false
        }
    }

    [bool] TestDatabaseConnection([IntegrationEndpoint]$endpoint) {
        try {
            # Simple database connectivity test
            # Implementation would depend on database type (SQL Server, MySQL, etc.)
            # For now, just return true if connection string is provided
            return -not [string]::IsNullOrEmpty($endpoint.Endpoint)
        }
        catch {
            return $false
        }
    }

    [bool] TestFileShareConnection([IntegrationEndpoint]$endpoint) {
        try {
            return Test-Path $endpoint.Endpoint
        }
        catch {
            return $false
        }
    }

    [bool] TestEventLogConnection([IntegrationEndpoint]$endpoint) {
        try {
            # Test if we can write to the specified event log
            $logName = $endpoint.Configuration['LogName']
            $source = $endpoint.Configuration['Source']

            # Try to get the log to verify access
            Get-WinEvent -LogName $logName -MaxEvents 1 -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            return $false
        }
    }

    [void] SendIntegrationEvent([IntegrationEvent]$event) {
        $this.EventQueue.Enqueue($event)
        $this.Logger.LogDebug("Queued integration event: $($event.EventType)")
    }

    [void] ProcessPendingEvents() {
        try {
            $processedCount = 0
            $maxEventsPerBatch = 50

            while ($processedCount -lt $maxEventsPerBatch) {
                $event = $null
                if (-not $this.EventQueue.TryDequeue([ref]$event)) {
                    break
                }

                $this.ProcessIntegrationEvent($event)
                $processedCount++
            }

            if ($processedCount -gt 0) {
                $this.Logger.LogDebug("Processed $processedCount integration events")
            }
        }
        catch {
            $this.Logger.LogError("Error processing integration events", $_.Exception)
        }
    }

    [void] ProcessIntegrationEvent([IntegrationEvent]$event) {
        try {
            foreach ($endpoint in $this.Endpoints) {
                if (-not $endpoint.Enabled -or $endpoint.Status -ne [IntegrationStatus]::Connected) {
                    continue
                }

                # Check if endpoint should receive this event type
                if ($endpoint.Configuration.ContainsKey('EventTypes')) {
                    $allowedTypes = $endpoint.Configuration['EventTypes']
                    if ($allowedTypes -notcontains $event.EventType) {
                        continue
                    }
                }

                $this.SendEventToEndpoint($event, $endpoint)
            }
        }
        catch {
            $this.Logger.LogError("Error processing integration event", $_.Exception)
        }
    }

    [void] SendEventToEndpoint([IntegrationEvent]$event, [IntegrationEndpoint]$endpoint) {
        try {
            switch ($endpoint.Type) {
                ([IntegrationType]::WebHook) {
                    $this.SendWebHookEvent($event, $endpoint)
                }
                ([IntegrationType]::RestAPI) {
                    $this.SendRestAPIEvent($event, $endpoint)
                }
                ([IntegrationType]::FileShare) {
                    $this.SendFileShareEvent($event, $endpoint)
                }
                ([IntegrationType]::EventLog) {
                    $this.SendEventLogEvent($event, $endpoint)
                }
            }
        }
        catch {
            $this.Logger.LogError("Error sending event to endpoint '$($endpoint.Name)'", $_.Exception)
        }
    }

    [void] SendWebHookEvent([IntegrationEvent]$event, [IntegrationEndpoint]$endpoint) {
        try {
            $payload = @{
                id = $event.Id
                timestamp = $event.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
                eventType = $event.EventType
                source = $event.Source
                data = $event.Data
                correlationId = $event.CorrelationId
            }

            $json = $payload | ConvertTo-Json -Depth 10
            $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")

            # Add authentication headers if configured
            if ($endpoint.Configuration.ContainsKey('AuthToken')) {
                $this.HttpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $endpoint.Configuration['AuthToken'])
            }

            $response = $this.HttpClient.PostAsync($endpoint.Endpoint, $content).GetAwaiter().GetResult()

            if (-not $response.IsSuccessStatusCode) {
                $this.Logger.LogWarning("WebHook event failed: $($response.StatusCode) - $($response.ReasonPhrase)")
            }
        }
        catch {
            $this.Logger.LogError("Error sending webhook event", $_.Exception)
        }
    }

    [void] SendRestAPIEvent([IntegrationEvent]$event, [IntegrationEndpoint]$endpoint) {
        try {
            $apiEndpoint = "$($endpoint.Endpoint)/$($endpoint.Configuration['EventEndpoint'])"
            $this.SendWebHookEvent($event, [IntegrationEndpoint]::new($endpoint.Name, [IntegrationType]::WebHook, $apiEndpoint, $endpoint.Configuration))
        }
        catch {
            $this.Logger.LogError("Error sending REST API event", $_.Exception)
        }
    }

    [void] SendFileShareEvent([IntegrationEvent]$event, [IntegrationEndpoint]$endpoint) {
        try {
            $fileName = "event_$($event.Id)_$($event.Timestamp.ToString('yyyyMMdd_HHmmss')).json"
            $filePath = Join-Path $endpoint.Endpoint $fileName

            $eventData = @{
                id = $event.Id
                timestamp = $event.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
                eventType = $event.EventType
                source = $event.Source
                data = $event.Data
                correlationId = $event.CorrelationId
            }

            $eventData | ConvertTo-Json -Depth 10 | Out-File -FilePath $filePath -Encoding UTF8
        }
        catch {
            $this.Logger.LogError("Error sending file share event", $_.Exception)
        }
    }

    [void] SendEventLogEvent([IntegrationEvent]$event, [IntegrationEndpoint]$endpoint) {
        try {
            $logName = $endpoint.Configuration['LogName']
            $source = $endpoint.Configuration['Source']
            $eventId = if ($endpoint.Configuration.ContainsKey('EventId')) { $endpoint.Configuration['EventId'] } else { 5000 }

            $message = "$($event.EventType) from $($event.Source)`nCorrelation ID: $($event.CorrelationId)`nData: $($event.Data | ConvertTo-Json -Depth 5)"

            Write-EventLog -LogName $logName -Source $source -EventId $eventId -EntryType Information -Message $message
        }
        catch {
            $this.Logger.LogError("Error sending event log event", $_.Exception)
        }
    }

    [hashtable] GetIntegrationStatus() {
        $status = @{
            Timestamp = Get-Date.ToString("yyyy-MM-dd HH:mm:ss")
            TotalEndpoints = $this.Endpoints.Count
            ConnectedEndpoints = ($this.Endpoints | Where-Object { $_.Status -eq [IntegrationStatus]::Connected }).Count
            DisconnectedEndpoints = ($this.Endpoints | Where-Object { $_.Status -eq [IntegrationStatus]::Disconnected }).Count
            ErrorEndpoints = ($this.Endpoints | Where-Object { $_.Status -eq [IntegrationStatus]::Error }).Count
            DisabledEndpoints = ($this.Endpoints | Where-Object { $_.Status -eq [IntegrationStatus]::Disabled }).Count
            PendingEvents = $this.EventQueue.Count
            Endpoints = @()
        }

        foreach ($endpoint in $this.Endpoints) {
            $status.Endpoints += $endpoint.ToHashtable()
        }

        return $status
    }

    [void] EnableEndpoint([string]$name) {
        $endpoint = $this.Endpoints | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($endpoint) {
            $endpoint.Enabled = $true
            $endpoint.Status = [IntegrationStatus]::Unknown
            $endpoint.FailureCount = 0
            $this.Logger.LogInformation("Integration endpoint '$name' enabled")
        }
    }

    [void] DisableEndpoint([string]$name) {
        $endpoint = $this.Endpoints | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($endpoint) {
            $endpoint.Enabled = $false
            $endpoint.Status = [IntegrationStatus]::Disabled
            $this.Logger.LogInformation("Integration endpoint '$name' disabled")
        }
    }

    # Integration event helper methods
    [void] NotifyFileProcessingStarted([string]$filePath, [string]$targetPath) {
        $event = [IntegrationEvent]::new(
            "FileProcessingStarted",
            "FileCopier",
            @{
                filePath = $filePath
                targetPath = $targetPath
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        )
        $this.SendIntegrationEvent($event)
    }

    [void] NotifyFileProcessingCompleted([string]$filePath, [string]$targetPath, [long]$fileSize, [double]$processingTimeSeconds) {
        $event = [IntegrationEvent]::new(
            "FileProcessingCompleted",
            "FileCopier",
            @{
                filePath = $filePath
                targetPath = $targetPath
                fileSize = $fileSize
                processingTimeSeconds = $processingTimeSeconds
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        )
        $this.SendIntegrationEvent($event)
    }

    [void] NotifyFileProcessingFailed([string]$filePath, [string]$error, [string]$errorCategory) {
        $event = [IntegrationEvent]::new(
            "FileProcessingFailed",
            "FileCopier",
            @{
                filePath = $filePath
                error = $error
                errorCategory = $errorCategory
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        )
        $this.SendIntegrationEvent($event)
    }

    [void] NotifyServiceHealthChange([string]$status, [hashtable]$healthDetails) {
        $event = [IntegrationEvent]::new(
            "ServiceHealthChange",
            "FileCopier",
            @{
                status = $status
                healthDetails = $healthDetails
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        )
        $this.SendIntegrationEvent($event)
    }

    [void] NotifyPerformanceAlert([string]$alertType, [hashtable]$alertDetails) {
        $event = [IntegrationEvent]::new(
            "PerformanceAlert",
            "FileCopier",
            @{
                alertType = $alertType
                alertDetails = $alertDetails
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        )
        $this.SendIntegrationEvent($event)
    }
}

# Export system integration functions for console use
function Start-FileCopierSystemIntegration {
    param(
        [hashtable]$Config,
        [object]$Logger
    )

    $integration = [SystemIntegrationMonitor]::new($Config, $Logger)
    $integration.Start()
    return $integration
}

function Stop-FileCopierSystemIntegration {
    param(
        [SystemIntegrationMonitor]$SystemIntegration
    )

    $SystemIntegration.Stop()
}

function Get-FileCopierIntegrationStatus {
    param(
        [SystemIntegrationMonitor]$SystemIntegration
    )

    return $SystemIntegration.GetIntegrationStatus()
}

function Enable-FileCopierIntegrationEndpoint {
    param(
        [SystemIntegrationMonitor]$SystemIntegration,
        [string]$EndpointName
    )

    $SystemIntegration.EnableEndpoint($EndpointName)
}

function Disable-FileCopierIntegrationEndpoint {
    param(
        [SystemIntegrationMonitor]$SystemIntegration,
        [string]$EndpointName
    )

    $SystemIntegration.DisableEndpoint($EndpointName)
}

function Send-FileCopierIntegrationEvent {
    param(
        [SystemIntegrationMonitor]$SystemIntegration,
        [string]$EventType,
        [string]$Source,
        [hashtable]$Data
    )

    $event = [IntegrationEvent]::new($EventType, $Source, $Data)
    $SystemIntegration.SendIntegrationEvent($event)
}