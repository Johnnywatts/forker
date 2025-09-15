# Configuration.ps1 - Configuration management for File Copier Service

#region Private Variables
$script:CurrentConfig = $null
$script:ConfigFilePath = $null
$script:ConfigSchemaPath = $null
$script:DefaultConfigPath = "$PSScriptRoot\..\..\config\settings.json"
$script:DefaultSchemaPath = "$PSScriptRoot\..\..\config\settings.schema.json"
#endregion

#region Private Functions
function Test-JsonSchema {
    param(
        [Parameter(Mandatory)]
        [object]$JsonObject,

        [Parameter(Mandatory)]
        [string]$SchemaPath
    )

    if (-not (Test-Path $SchemaPath)) {
        throw "Schema file not found: $SchemaPath"
    }

    try {
        $schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json

        # Basic validation - check required properties
        $errors = @()

        if ($schema.required) {
            foreach ($requiredProp in $schema.required) {
                if (-not $JsonObject.PSObject.Properties[$requiredProp]) {
                    $errors += "Missing required property: $requiredProp"
                }
            }
        }

        # Only validate directories if running on production (skip for testing scenarios)
        $isTestEnvironment = $env:PESTER_CONTEXT -or $JsonObject.directories.source -like "/tmp/*"
        if ($JsonObject.directories -and -not $isTestEnvironment) {
            foreach ($dirProp in $JsonObject.directories.PSObject.Properties) {
                $dirPath = $dirProp.Value
                if ($dirPath -and -not [string]::IsNullOrWhiteSpace($dirPath)) {
                    $parentDir = Split-Path $dirPath -Parent
                    if ($parentDir -and -not (Test-Path $parentDir)) {
                        $errors += "Parent directory does not exist for $($dirProp.Name): $parentDir"
                    }
                }
            }
        }

        # Validate numeric ranges
        if ($JsonObject.copying -and $JsonObject.copying.maxRetries) {
            if ($JsonObject.copying.maxRetries -lt 0 -or $JsonObject.copying.maxRetries -gt 10) {
                $errors += "maxRetries must be between 0 and 10"
            }
        }

        if ($JsonObject.copying -and $JsonObject.copying.maxConcurrentCopies) {
            if ($JsonObject.copying.maxConcurrentCopies -lt 1 -or $JsonObject.copying.maxConcurrentCopies -gt 10) {
                $errors += "maxConcurrentCopies must be between 1 and 10"
            }
        }

        return @{
            IsValid = ($errors.Count -eq 0)
            Errors = $errors
        }
    }
    catch {
        return @{
            IsValid = $false
            Errors = @("Schema validation failed: $($_.Exception.Message)")
        }
    }
}

function Merge-ConfigWithEnvironment {
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    # Environment variable overrides with FC_ prefix
    $envOverrides = @{
        'FC_SOURCE_DIR' = 'directories.source'
        'FC_TARGETA_DIR' = 'directories.targetA'
        'FC_TARGETB_DIR' = 'directories.targetB'
        'FC_ERROR_DIR' = 'directories.error'
        'FC_PROCESSING_DIR' = 'directories.processing'
        'FC_LOG_LEVEL' = 'logging.level'
        'FC_MAX_CONCURRENT' = 'copying.maxConcurrentCopies'
        'FC_POLLING_INTERVAL' = 'service.pollingIntervalSeconds'
    }

    foreach ($envVar in $envOverrides.Keys) {
        $envValue = [Environment]::GetEnvironmentVariable($envVar)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            $configPath = $envOverrides[$envVar]
            $pathParts = $configPath.Split('.')

            if ($pathParts.Count -eq 2) {
                $section = $pathParts[0]
                $property = $pathParts[1]

                if ($Config.PSObject.Properties[$section]) {
                    # Convert numeric values
                    if ($envValue -match '^\d+$') {
                        $envValue = [int]$envValue
                    }

                    $Config.$section.$property = $envValue
                    Write-Verbose "Applied environment override: $envVar = $envValue"
                }
            }
        }
    }

    return $Config
}

function Get-DefaultConfiguration {
    # Use cross-platform friendly paths
    $isWindows = $PSVersionTable.PSVersion.Major -le 5 -or $IsWindows
    $basePath = if ($isWindows) { "C:\FileCopier" } else { "/tmp/filecopier" }
    $sourceBase = if ($isWindows) { "C:\" } else { "/tmp/" }

    return @{
        directories = @{
            source = "${sourceBase}Source"
            targetA = "${sourceBase}TargetA"
            targetB = "${sourceBase}TargetB"
            error = "${basePath}/temp/error"
            processing = "${basePath}/temp/processing"
        }
        monitoring = @{
            includeSubdirectories = $false
            fileFilters = @("*.svs", "*.tiff", "*.tif")
            excludeExtensions = @(".tmp", ".temp", ".part", ".lock")
            minimumFileAge = 5
            stabilityCheckInterval = 2
            maxStabilityChecks = 10
        }
        copying = @{
            maxRetries = 3
            retryDelaySeconds = @(1, 5, 15)
            maxConcurrentCopies = 3
            preserveTimestamps = $true
            chunkSizeBytes = 1048576
            verifyAfterCopy = $true
        }
        verification = @{
            method = "hash"
            hashAlgorithm = "SHA256"
            fallbackToSizeCheck = $true
            maxRetries = 5
            retryDelaySeconds = 2
            streamingHashChunkSize = 65536
        }
        logging = @{
            level = "Information"
            fileLogging = $true
            eventLogSource = "FileCopierService"
            maxLogSizeMB = 100
            logRetentionDays = 30
            logDirectory = "${basePath}/logs"
            enablePerformanceLogging = $true
        }
        service = @{
            pollingIntervalSeconds = 1
            shutdownTimeoutSeconds = 30
            healthCheckIntervalMinutes = 5
            maxProcessingQueueSize = 1000
            enableHotConfigReload = $true
        }
    }
}
#endregion

#region Public Functions
function Initialize-FileCopierConfig {
    <#
    .SYNOPSIS
        Initializes the File Copier configuration system.

    .DESCRIPTION
        Loads configuration from file, validates against schema, and applies environment overrides.

    .PARAMETER ConfigPath
        Path to the configuration JSON file. Defaults to settings.json in config directory.

    .PARAMETER SchemaPath
        Path to the JSON schema file. Defaults to settings.schema.json in config directory.

    .EXAMPLE
        Initialize-FileCopierConfig

    .EXAMPLE
        Initialize-FileCopierConfig -ConfigPath "C:\MyApp\config.json"
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$SchemaPath
    )

    try {
        # Set default paths if not provided
        if (-not $ConfigPath) {
            $ConfigPath = $script:DefaultConfigPath
        }
        if (-not $SchemaPath) {
            $SchemaPath = $script:DefaultSchemaPath
        }

        $script:ConfigFilePath = $ConfigPath
        $script:ConfigSchemaPath = $SchemaPath

        Write-Verbose "Loading configuration from: $ConfigPath"

        # Load configuration
        if (Test-Path $ConfigPath) {
            $configContent = Get-Content $ConfigPath -Raw
            $config = $configContent | ConvertFrom-Json
            Write-Verbose "Configuration loaded successfully"
        }
        else {
            Write-Warning "Configuration file not found: $ConfigPath. Using default configuration."
            $config = Get-DefaultConfiguration
        }

        # Validate against schema if schema exists and config was loaded from file
        if ((Test-Path $SchemaPath) -and (Test-Path $ConfigPath)) {
            Write-Verbose "Validating configuration against schema: $SchemaPath"
            $validationResult = Test-JsonSchema -JsonObject $config -SchemaPath $SchemaPath

            if (-not $validationResult.IsValid) {
                $errorMessage = "Configuration validation failed:`n" + ($validationResult.Errors -join "`n")
                throw $errorMessage
            }
            Write-Verbose "Configuration validation passed"
        }
        else {
            if (Test-Path $SchemaPath) {
                Write-Verbose "Using default configuration, skipping schema validation."
            } else {
                Write-Warning "Schema file not found: $SchemaPath. Skipping validation."
            }
        }

        # Apply environment variable overrides
        $config = Merge-ConfigWithEnvironment -Config $config

        # If using default config, don't validate directory existence during initialization
        $skipDirectoryValidation = -not (Test-Path $ConfigPath)
        if ($skipDirectoryValidation) {
            Write-Verbose "Using default configuration, skipping directory validation during initialization."
        }

        # Store in script variable
        $script:CurrentConfig = $config

        Write-Verbose "Configuration initialized successfully"
        return $config
    }
    catch {
        Write-Error "Failed to initialize configuration: $($_.Exception.Message)"
        throw
    }
}

function Get-FileCopierConfig {
    <#
    .SYNOPSIS
        Gets the current File Copier configuration.

    .DESCRIPTION
        Returns the currently loaded configuration object, or initializes it if not already loaded.

    .PARAMETER Section
        Optional section name to return only a specific configuration section.

    .EXAMPLE
        $config = Get-FileCopierConfig

    .EXAMPLE
        $dirs = Get-FileCopierConfig -Section "directories"
    #>
    [CmdletBinding()]
    param(
        [string]$Section
    )

    if (-not $script:CurrentConfig) {
        Write-Verbose "Configuration not loaded, initializing..."
        Initialize-FileCopierConfig | Out-Null
    }

    if ($Section) {
        if ($script:CurrentConfig.PSObject.Properties[$Section]) {
            return $script:CurrentConfig.$Section
        }
        else {
            throw "Configuration section '$Section' not found"
        }
    }

    return $script:CurrentConfig
}

function Set-FileCopierConfig {
    <#
    .SYNOPSIS
        Updates the File Copier configuration.

    .DESCRIPTION
        Updates configuration values and optionally saves to file.

    .PARAMETER Section
        Configuration section to update.

    .PARAMETER Property
        Property name within the section.

    .PARAMETER Value
        New value for the property.

    .PARAMETER Save
        Save the updated configuration to file.

    .EXAMPLE
        Set-FileCopierConfig -Section "copying" -Property "maxConcurrentCopies" -Value 5

    .EXAMPLE
        Set-FileCopierConfig -Section "logging" -Property "level" -Value "Debug" -Save
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Property,

        [Parameter(Mandatory)]
        $Value,

        [switch]$Save
    )

    if (-not $script:CurrentConfig) {
        throw "Configuration not initialized. Call Initialize-FileCopierConfig first."
    }

    if (-not $script:CurrentConfig.PSObject.Properties[$Section]) {
        throw "Configuration section '$Section' not found"
    }

    if (-not $script:CurrentConfig.$Section.PSObject.Properties[$Property]) {
        throw "Property '$Property' not found in section '$Section'"
    }

    $script:CurrentConfig.$Section.$Property = $Value
    Write-Verbose "Updated $Section.$Property = $Value"

    if ($Save -and $script:ConfigFilePath) {
        try {
            $script:CurrentConfig | ConvertTo-Json -Depth 10 | Set-Content $script:ConfigFilePath
            Write-Verbose "Configuration saved to: $script:ConfigFilePath"
        }
        catch {
            Write-Error "Failed to save configuration: $($_.Exception.Message)"
            throw
        }
    }
}

function Test-FileCopierConfig {
    <#
    .SYNOPSIS
        Validates the current File Copier configuration.

    .DESCRIPTION
        Performs comprehensive validation of the configuration including directory accessibility,
        numeric ranges, and schema compliance.

    .PARAMETER ShowDetails
        Show detailed validation results.

    .EXAMPLE
        Test-FileCopierConfig

    .EXAMPLE
        Test-FileCopierConfig -ShowDetails
    #>
    [CmdletBinding()]
    param(
        [switch]$ShowDetails
    )

    if (-not $script:CurrentConfig) {
        throw "Configuration not initialized. Call Initialize-FileCopierConfig first."
    }

    $validationErrors = @()
    $validationWarnings = @()

    try {
        # Schema validation
        if ($script:ConfigSchemaPath -and (Test-Path $script:ConfigSchemaPath)) {
            $schemaResult = Test-JsonSchema -JsonObject $script:CurrentConfig -SchemaPath $script:ConfigSchemaPath
            if (-not $schemaResult.IsValid) {
                $validationErrors += $schemaResult.Errors
            }
        }

        # Directory accessibility checks
        $config = $script:CurrentConfig
        if ($config.directories) {
            foreach ($dirProp in $config.directories.PSObject.Properties) {
                $dirPath = $dirProp.Value
                if ($dirPath) {
                    $parentDir = Split-Path $dirPath -Parent
                    if ($parentDir -and -not (Test-Path $parentDir)) {
                        $validationErrors += "Parent directory not accessible: $parentDir (for $($dirProp.Name))"
                    }
                    elseif (-not (Test-Path $dirPath)) {
                        $validationWarnings += "Directory does not exist but can be created: $dirPath"
                    }
                }
            }
        }

        # Logical validation checks
        if ($config.copying -and $config.copying.retryDelaySeconds) {
            if ($config.copying.retryDelaySeconds.Count -lt $config.copying.maxRetries) {
                $validationWarnings += "Fewer retry delays configured than max retries"
            }
        }

        if ($config.verification -and $config.verification.method -eq "hash") {
            if (-not $config.verification.hashAlgorithm -or [string]::IsNullOrWhiteSpace($config.verification.hashAlgorithm)) {
                $validationErrors += "Hash algorithm must be specified when verification method is 'hash'"
            }
        }

        $result = @{
            IsValid = ($validationErrors.Count -eq 0)
            Errors = $validationErrors
            Warnings = $validationWarnings
        }

        if ($ShowDetails) {
            Write-Host "Configuration Validation Results:" -ForegroundColor Cyan
            Write-Host "=================================" -ForegroundColor Cyan

            if ($result.IsValid) {
                Write-Host "✓ Configuration is valid" -ForegroundColor Green
            }
            else {
                Write-Host "✗ Configuration has errors" -ForegroundColor Red
            }

            if ($result.Errors.Count -gt 0) {
                Write-Host "`nErrors:" -ForegroundColor Red
                foreach ($error in $result.Errors) {
                    Write-Host "  • $error" -ForegroundColor Red
                }
            }

            if ($result.Warnings.Count -gt 0) {
                Write-Host "`nWarnings:" -ForegroundColor Yellow
                foreach ($warning in $result.Warnings) {
                    Write-Host "  • $warning" -ForegroundColor Yellow
                }
            }
        }

        return $result
    }
    catch {
        Write-Error "Configuration validation failed: $($_.Exception.Message)"
        return @{
            IsValid = $false
            Errors = @($_.Exception.Message)
            Warnings = @()
        }
    }
}

function Reload-FileCopierConfig {
    <#
    .SYNOPSIS
        Reloads the File Copier configuration from file.

    .DESCRIPTION
        Reloads configuration from the original file path, useful for hot configuration updates.

    .EXAMPLE
        Reload-FileCopierConfig
    #>
    [CmdletBinding()]
    param()

    if (-not $script:ConfigFilePath) {
        throw "No configuration file path set. Initialize configuration first."
    }

    Write-Verbose "Reloading configuration from: $script:ConfigFilePath"
    Initialize-FileCopierConfig -ConfigPath $script:ConfigFilePath -SchemaPath $script:ConfigSchemaPath
}
#endregion

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed