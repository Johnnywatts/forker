using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Threading
using namespace System.IO
using namespace System.Text
using namespace System.Net

class MonitoringDashboard {
    [hashtable] $Config
    [object] $Logger
    [DiagnosticCommands] $Diagnostics
    [PerformanceCounterManager] $PerfCounters
    [System.Net.HttpListener] $HttpListener
    [bool] $IsRunning
    [int] $Port
    [System.Threading.Timer] $RefreshTimer
    [ConcurrentDictionary[string, object]] $CachedData

    MonitoringDashboard([hashtable]$config, [object]$logger) {
        $this.Config = $config
        $this.Logger = $logger
        $this.Port = 8080  # Default port
        $this.IsRunning = $false
        $this.CachedData = [ConcurrentDictionary[string, object]]::new()

        $this.Diagnostics = [DiagnosticCommands]::new($config, $logger)

        if ($config['Performance']['Monitoring']['PerformanceCounters']) {
            $this.PerfCounters = [PerformanceCounterManager]::new($config, $logger)
        }
    }

    [void] Start([int]$port = 8080) {
        if ($this.IsRunning) {
            $this.Logger.LogWarning("Monitoring dashboard is already running")
            return
        }

        try {
            $this.Port = $port
            $this.HttpListener = [System.Net.HttpListener]::new()
            $this.HttpListener.Prefixes.Add("http://localhost:$port/")
            $this.HttpListener.Start()
            $this.IsRunning = $true

            # Start background data refresh timer (every 30 seconds)
            $this.RefreshTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $dashboard = $state
                    $dashboard.RefreshCachedData()
                },
                $this,
                [TimeSpan]::FromSeconds(5),  # Initial delay
                [TimeSpan]::FromSeconds(30)  # Refresh interval
            )

            # Start listener in background
            $this.StartHttpListener()

            $this.Logger.LogInformation("Monitoring dashboard started on http://localhost:$port")
        }
        catch {
            $this.IsRunning = $false
            $this.Logger.LogError("Failed to start monitoring dashboard", $_.Exception)
            throw
        }
    }

    [void] Stop() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            $this.IsRunning = $false

            if ($this.RefreshTimer) {
                $this.RefreshTimer.Dispose()
                $this.RefreshTimer = $null
            }

            if ($this.HttpListener) {
                $this.HttpListener.Stop()
                $this.HttpListener.Close()
                $this.HttpListener = $null
            }

            $this.Logger.LogInformation("Monitoring dashboard stopped")
        }
        catch {
            $this.Logger.LogError("Error stopping monitoring dashboard", $_.Exception)
        }
    }

    [void] StartHttpListener() {
        # Start async listener
        $asyncResult = $this.HttpListener.BeginGetContext(
            [System.AsyncCallback]{
                param($result)
                $dashboard = $result.AsyncState
                $dashboard.ProcessRequest($result)
            },
            $this
        )
    }

    [void] ProcessRequest([System.IAsyncResult]$result) {
        if (-not $this.IsRunning) {
            return
        }

        try {
            $context = $this.HttpListener.EndGetContext($result)
            $request = $context.Request
            $response = $context.Response

            # Set CORS headers
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

            # Handle preflight requests
            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 200
                $response.Close()
                $this.StartHttpListener()  # Continue listening
                return
            }

            $path = $request.Url.AbsolutePath.ToLower()
            $responseContent = ""
            $contentType = "text/html; charset=utf-8"

            switch ($path) {
                "/" {
                    $responseContent = $this.GenerateMainDashboard()
                }
                "/api/health" {
                    $responseContent = $this.GetHealthData()
                    $contentType = "application/json"
                }
                "/api/performance" {
                    $responseContent = $this.GetPerformanceData()
                    $contentType = "application/json"
                }
                "/api/errors" {
                    $responseContent = $this.GetErrorData()
                    $contentType = "application/json"
                }
                "/api/connectivity" {
                    $responseContent = $this.GetConnectivityData()
                    $contentType = "application/json"
                }
                "/styles.css" {
                    $responseContent = $this.GetCssStyles()
                    $contentType = "text/css"
                }
                "/script.js" {
                    $responseContent = $this.GetJavaScript()
                    $contentType = "application/javascript"
                }
                default {
                    $response.StatusCode = 404
                    $responseContent = "<html><body><h1>404 - Not Found</h1></body></html>"
                }
            }

            $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseContent)
            $response.ContentLength64 = $buffer.Length
            $response.ContentType = $contentType
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.Close()
        }
        catch {
            $this.Logger.LogError("Error processing dashboard request", $_.Exception)
        }
        finally {
            if ($this.IsRunning) {
                $this.StartHttpListener()  # Continue listening
            }
        }
    }

    [void] RefreshCachedData() {
        try {
            $this.CachedData['health'] = $this.Diagnostics.GetSystemHealth()
            $this.CachedData['performance'] = $this.Diagnostics.GetPerformanceMetrics()
            $this.CachedData['errors'] = $this.Diagnostics.GetRecentErrors(24)
            $this.CachedData['connectivity'] = $this.Diagnostics.TestConnectivity()
            $this.CachedData['lastRefresh'] = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        catch {
            $this.Logger.LogError("Failed to refresh cached dashboard data", $_.Exception)
        }
    }

    [string] GenerateMainDashboard() {
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FileCopier Service - Monitoring Dashboard</title>
    <link rel="stylesheet" href="/styles.css">
    <script src="/script.js"></script>
</head>
<body>
    <header>
        <h1>FileCopier Service - Monitoring Dashboard</h1>
        <div class="last-updated">Last Updated: <span id="lastUpdated">Loading...</span></div>
    </header>

    <main>
        <div class="dashboard-grid">
            <!-- System Health Panel -->
            <div class="panel" id="health-panel">
                <h2>System Health</h2>
                <div class="status-indicator" id="overall-status">
                    <span class="status-badge" id="status-badge">Loading...</span>
                </div>
                <div class="health-components" id="health-components">
                    Loading components...
                </div>
            </div>

            <!-- Performance Metrics Panel -->
            <div class="panel" id="performance-panel">
                <h2>Performance Metrics</h2>
                <div class="metrics-grid" id="performance-metrics">
                    Loading metrics...
                </div>
            </div>

            <!-- Processing Statistics Panel -->
            <div class="panel" id="processing-panel">
                <h2>Processing Statistics</h2>
                <div class="stats-grid" id="processing-stats">
                    Loading statistics...
                </div>
            </div>

            <!-- System Resources Panel -->
            <div class="panel" id="resources-panel">
                <h2>System Resources</h2>
                <div class="resources-grid" id="system-resources">
                    Loading resources...
                </div>
            </div>

            <!-- Recent Errors Panel -->
            <div class="panel" id="errors-panel">
                <h2>Recent Errors (24h)</h2>
                <div class="errors-list" id="recent-errors">
                    Loading errors...
                </div>
            </div>

            <!-- Connectivity Status Panel -->
            <div class="panel" id="connectivity-panel">
                <h2>Connectivity Status</h2>
                <div class="connectivity-grid" id="connectivity-status">
                    Loading connectivity...
                </div>
            </div>
        </div>
    </main>

    <footer>
        <p>FileCopier Service Dashboard - Phase 5B | Auto-refresh: 30 seconds</p>
    </footer>
</body>
</html>
"@
        return $html
    }

    [string] GetCssStyles() {
        $css = @"
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background-color: #f5f5f5;
    color: #333;
    line-height: 1.6;
}

header {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: white;
    padding: 2rem;
    text-align: center;
    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
}

header h1 {
    font-size: 2rem;
    margin-bottom: 0.5rem;
}

.last-updated {
    font-size: 0.9rem;
    opacity: 0.9;
}

main {
    max-width: 1400px;
    margin: 2rem auto;
    padding: 0 1rem;
}

.dashboard-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
    gap: 1.5rem;
}

.panel {
    background: white;
    border-radius: 12px;
    padding: 1.5rem;
    box-shadow: 0 4px 6px rgba(0,0,0,0.1);
    border: 1px solid #e1e5e9;
}

.panel h2 {
    color: #2c3e50;
    margin-bottom: 1rem;
    font-size: 1.3rem;
    border-bottom: 2px solid #ecf0f1;
    padding-bottom: 0.5rem;
}

.status-indicator {
    text-align: center;
    margin-bottom: 1rem;
}

.status-badge {
    display: inline-block;
    padding: 0.5rem 1rem;
    border-radius: 20px;
    font-weight: bold;
    text-transform: uppercase;
    font-size: 0.9rem;
}

.status-healthy { background-color: #2ecc71; color: white; }
.status-warning { background-color: #f39c12; color: white; }
.status-critical { background-color: #e74c3c; color: white; }
.status-error { background-color: #8e44ad; color: white; }
.status-loading { background-color: #95a5a6; color: white; }

.health-components {
    display: grid;
    gap: 0.5rem;
}

.component-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem;
    background-color: #f8f9fa;
    border-radius: 6px;
    border-left: 4px solid #ddd;
}

.component-healthy { border-left-color: #2ecc71; }
.component-warning { border-left-color: #f39c12; }
.component-critical { border-left-color: #e74c3c; }
.component-error { border-left-color: #8e44ad; }

.metrics-grid, .stats-grid, .resources-grid, .connectivity-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
    gap: 1rem;
}

.metric-item, .stat-item, .resource-item, .connectivity-item {
    text-align: center;
    padding: 1rem;
    background-color: #f8f9fa;
    border-radius: 8px;
    border: 1px solid #e9ecef;
}

.metric-value, .stat-value, .resource-value {
    font-size: 1.5rem;
    font-weight: bold;
    color: #2c3e50;
    margin-bottom: 0.25rem;
}

.metric-label, .stat-label, .resource-label {
    font-size: 0.8rem;
    color: #7f8c8d;
    text-transform: uppercase;
}

.errors-list {
    max-height: 300px;
    overflow-y: auto;
}

.error-item {
    padding: 0.75rem;
    margin-bottom: 0.5rem;
    background-color: #fff5f5;
    border-left: 4px solid #e74c3c;
    border-radius: 4px;
}

.error-timestamp {
    font-size: 0.8rem;
    color: #7f8c8d;
    margin-bottom: 0.25rem;
}

.error-message {
    font-size: 0.9rem;
    color: #2c3e50;
}

.connectivity-item {
    border-left: 4px solid #ddd;
}

.connectivity-passed { border-left-color: #2ecc71; }
.connectivity-warning { border-left-color: #f39c12; }
.connectivity-failed { border-left-color: #e74c3c; }

footer {
    text-align: center;
    padding: 2rem;
    color: #7f8c8d;
    background-color: white;
    margin-top: 2rem;
}

.loading {
    display: flex;
    justify-content: center;
    align-items: center;
    height: 100px;
    color: #7f8c8d;
}

@media (max-width: 768px) {
    .dashboard-grid {
        grid-template-columns: 1fr;
    }

    header {
        padding: 1rem;
    }

    header h1 {
        font-size: 1.5rem;
    }

    .metrics-grid, .stats-grid, .resources-grid, .connectivity-grid {
        grid-template-columns: repeat(auto-fit, minmax(100px, 1fr));
    }
}
"@
        return $css
    }

    [string] GetJavaScript() {
        $js = @"
class DashboardManager {
    constructor() {
        this.refreshInterval = 30000; // 30 seconds
        this.init();
    }

    init() {
        this.loadData();
        setInterval(() => this.loadData(), this.refreshInterval);
    }

    async loadData() {
        try {
            await Promise.all([
                this.loadHealthData(),
                this.loadPerformanceData(),
                this.loadErrorData(),
                this.loadConnectivityData()
            ]);
            this.updateLastRefresh();
        } catch (error) {
            console.error('Error loading dashboard data:', error);
        }
    }

    async loadHealthData() {
        try {
            const response = await fetch('/api/health');
            const data = await response.json();
            this.updateHealthPanel(data);
        } catch (error) {
            console.error('Error loading health data:', error);
        }
    }

    async loadPerformanceData() {
        try {
            const response = await fetch('/api/performance');
            const data = await response.json();
            this.updatePerformancePanel(data);
        } catch (error) {
            console.error('Error loading performance data:', error);
        }
    }

    async loadErrorData() {
        try {
            const response = await fetch('/api/errors');
            const data = await response.json();
            this.updateErrorPanel(data);
        } catch (error) {
            console.error('Error loading error data:', error);
        }
    }

    async loadConnectivityData() {
        try {
            const response = await fetch('/api/connectivity');
            const data = await response.json();
            this.updateConnectivityPanel(data);
        } catch (error) {
            console.error('Error loading connectivity data:', error);
        }
    }

    updateHealthPanel(data) {
        const statusBadge = document.getElementById('status-badge');
        const healthComponents = document.getElementById('health-components');

        // Update overall status
        statusBadge.textContent = data.Status || 'Unknown';
        statusBadge.className = 'status-badge status-' + (data.Status || 'loading').toLowerCase();

        // Update components
        if (data.Components) {
            let componentsHtml = '';
            Object.entries(data.Components).forEach(([name, component]) => {
                const statusClass = 'component-' + (component.Status || 'error').toLowerCase();
                componentsHtml += ``
                    <div class="component-item `${statusClass}">
                        <span>`${name}</span>
                        <span class="status-badge status-`${(component.Status || 'error').toLowerCase()}">`${component.Status}</span>
                    </div>
                ``;
            });
            healthComponents.innerHTML = componentsHtml;
        }
    }

    updatePerformancePanel(data) {
        const performanceMetrics = document.getElementById('performance-metrics');
        const processingStats = document.getElementById('processing-stats');
        const systemResources = document.getElementById('system-resources');

        if (data.Summary) {
            // Performance metrics
            performanceMetrics.innerHTML = ``
                <div class="metric-item">
                    <div class="metric-value">`${data.Summary.TotalFilesProcessed || 0}</div>
                    <div class="metric-label">Files Processed</div>
                </div>
                <div class="metric-item">
                    <div class="metric-value">`${data.Summary.SuccessRate || 0}%</div>
                    <div class="metric-label">Success Rate</div>
                </div>
                <div class="metric-item">
                    <div class="metric-value">`${data.Summary.AverageProcessingTimeSeconds || 0}s</div>
                    <div class="metric-label">Avg Process Time</div>
                </div>
                <div class="metric-item">
                    <div class="metric-value">`${data.Summary.AverageCopySpeedMBps || 0}</div>
                    <div class="metric-label">Avg Speed (MB/s)</div>
                </div>
            ``;

            // Processing statistics
            processingStats.innerHTML = ``
                <div class="stat-item">
                    <div class="stat-value">`${data.Summary.CurrentQueueDepth || 0}</div>
                    <div class="stat-label">Queue Depth</div>
                </div>
                <div class="stat-item">
                    <div class="stat-value">`${data.Summary.TotalFilesInError || 0}</div>
                    <div class="stat-label">Files in Error</div>
                </div>
                <div class="stat-item">
                    <div class="stat-value">`${data.Counters?.ActiveCopyOperations || 0}</div>
                    <div class="stat-label">Active Operations</div>
                </div>
                <div class="stat-item">
                    <div class="stat-value">`${data.Counters?.RetryAttempts || 0}</div>
                    <div class="stat-label">Retry Attempts</div>
                </div>
            ``;
        }

        // System resources (mock data for demonstration)
        systemResources.innerHTML = ``
            <div class="resource-item">
                <div class="resource-value">45%</div>
                <div class="resource-label">Memory Usage</div>
            </div>
            <div class="resource-item">
                <div class="resource-value">23%</div>
                <div class="resource-label">CPU Usage</div>
            </div>
            <div class="resource-item">
                <div class="resource-value">2.1TB</div>
                <div class="resource-label">Free Space</div>
            </div>
            <div class="resource-item">
                <div class="resource-value">Online</div>
                <div class="resource-label">Service Status</div>
            </div>
        ``;
    }

    updateErrorPanel(data) {
        const recentErrors = document.getElementById('recent-errors');

        if (data.Errors && data.Errors.length > 0) {
            let errorsHtml = '';
            data.Errors.slice(0, 10).forEach(error => {
                errorsHtml += ``
                    <div class="error-item">
                        <div class="error-timestamp">`${error.Timestamp} - `${error.Level}</div>
                        <div class="error-message">`${error.Message}</div>
                    </div>
                ``;
            });
            recentErrors.innerHTML = errorsHtml;
        } else {
            recentErrors.innerHTML = '<div class="loading">No recent errors</div>';
        }
    }

    updateConnectivityPanel(data) {
        const connectivityStatus = document.getElementById('connectivity-status');

        if (data.Tests) {
            let connectivityHtml = '';

            // Source directory
            if (data.Tests.SourceDirectory) {
                const test = data.Tests.SourceDirectory;
                const statusClass = 'connectivity-' + (test.Status || 'failed').toLowerCase();
                connectivityHtml += ``
                    <div class="connectivity-item `${statusClass}">
                        <div class="resource-value">`${test.Status}</div>
                        <div class="resource-label">Source Directory</div>
                    </div>
                ``;
            }

            // Target directories
            if (data.Tests.TargetDirectories) {
                Object.entries(data.Tests.TargetDirectories).forEach(([name, test]) => {
                    const statusClass = 'connectivity-' + (test.Status || 'failed').toLowerCase();
                    connectivityHtml += ``
                        <div class="connectivity-item `${statusClass}">
                            <div class="resource-value">`${test.Status}</div>
                            <div class="resource-label">`${name}</div>
                        </div>
                    ``;
                });
            }

            // Quarantine directory
            if (data.Tests.QuarantineDirectory) {
                const test = data.Tests.QuarantineDirectory;
                const statusClass = 'connectivity-' + (test.Status || 'failed').toLowerCase();
                connectivityHtml += ``
                    <div class="connectivity-item `${statusClass}">
                        <div class="resource-value">`${test.Status}</div>
                        <div class="resource-label">Quarantine</div>
                    </div>
                ``;
            }

            connectivityStatus.innerHTML = connectivityHtml;
        }
    }

    updateLastRefresh() {
        const lastUpdated = document.getElementById('lastUpdated');
        lastUpdated.textContent = new Date().toLocaleString();
    }
}

// Initialize dashboard when page loads
document.addEventListener('DOMContentLoaded', () => {
    new DashboardManager();
});
"@
        return $js
    }

    [string] GetHealthData() {
        $data = $this.CachedData['health']
        if (-not $data) {
            $data = $this.Diagnostics.GetSystemHealth()
        }
        return $data | ConvertTo-Json -Depth 10
    }

    [string] GetPerformanceData() {
        $data = $this.CachedData['performance']
        if (-not $data) {
            $data = $this.Diagnostics.GetPerformanceMetrics()
        }
        return $data | ConvertTo-Json -Depth 10
    }

    [string] GetErrorData() {
        $data = $this.CachedData['errors']
        if (-not $data) {
            $data = $this.Diagnostics.GetRecentErrors(24)
        }
        return $data | ConvertTo-Json -Depth 10
    }

    [string] GetConnectivityData() {
        $data = $this.CachedData['connectivity']
        if (-not $data) {
            $data = $this.Diagnostics.TestConnectivity()
        }
        return $data | ConvertTo-Json -Depth 10
    }
}

# Export dashboard functions for console use
function Start-FileCopierDashboard {
    param(
        [hashtable]$Config,
        [object]$Logger,
        [int]$Port = 8080
    )

    $dashboard = [MonitoringDashboard]::new($Config, $Logger)
    $dashboard.Start($Port)
    return $dashboard
}

function Stop-FileCopierDashboard {
    param(
        [MonitoringDashboard]$Dashboard
    )

    $Dashboard.Stop()
}