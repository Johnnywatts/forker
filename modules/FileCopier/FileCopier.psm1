# FileCopier.psm1 - Root module for File Copier Service

# Get the module directory
$ModuleRoot = $PSScriptRoot

# Dot-source the component scripts in the correct order
. (Join-Path $ModuleRoot "Configuration.ps1")
. (Join-Path $ModuleRoot "Logging.ps1")
. (Join-Path $ModuleRoot "Utils.ps1")

# Export only the functions we want to be public
Export-ModuleMember -Function @(
    'Initialize-FileCopierConfig',
    'Get-FileCopierConfig',
    'Set-FileCopierConfig',
    'Test-FileCopierConfig',
    'Reload-FileCopierConfig',
    'Write-FileCopierLog',
    'Test-DirectoryAccess',
    'Get-FileStability',
    'Get-SafeFileName',
    'Measure-ExecutionTime',
    'Get-MemoryUsage',
    'Format-ByteSize',
    'Format-Duration',
    'Invoke-WithRetry'
)