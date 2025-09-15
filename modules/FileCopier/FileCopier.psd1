@{
    # Root module file
    RootModule = 'FileCopier.psm1'

    ModuleVersion = '0.1.0'
    GUID = 'f47a3f8e-9d4c-4b85-a6f1-8e9c2d3a4b5c'
    Author = 'File Copier Service'
    CompanyName = 'Unknown'
    Copyright = '(c) 2025. All rights reserved.'
    Description = 'Windows file copier service for large SVS files with dual-target replication'
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @('System.IO', 'System.Security.Cryptography')

    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    ScriptsToProcess = @()

    # Functions to export from this module (updated to match actual functions)
    FunctionsToExport = @(
        'Initialize-FileCopierConfig',
        'Get-FileCopierConfig',
        'Set-FileCopierConfig',
        'Test-FileCopierConfig',
        'Reload-FileCopierConfig',
        'Initialize-FileCopierLogging',
        'Write-FileCopierLog',
        'Set-FileCopierLogLevel',
        'Get-FileCopierLogLevel',
        'Get-LoggingPerformanceCounters',
        'Reset-LoggingPerformanceCounters',
        'Stop-FileCopierLogging',
        'Test-DirectoryAccess',
        'Get-FileStability',
        'Get-SafeFileName',
        'Measure-ExecutionTime',
        'Get-MemoryUsage',
        'Format-ByteSize',
        'Format-Duration',
        'Invoke-WithRetry'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
            Tags = @('FileSystem', 'Service', 'Copy', 'SVS', 'DigitalPathology', 'Windows')
            LicenseUri = ''
            ProjectUri = 'https://github.com/Johnnywatts/forker'
            ReleaseNotes = 'Initial development version with configuration management'
        }
    }

    # HelpInfo URI of this module
    HelpInfoURI = ''

    # Default prefix for commands exported from this module
    DefaultCommandPrefix = ''

    # Nested modules are now handled by the root module
    # NestedModules = @()
}