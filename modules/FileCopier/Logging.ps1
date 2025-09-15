# Logging.ps1 - Placeholder for logging functionality
# This will be implemented in Phase 1B

function Write-FileCopierLog {
    param(
        [string]$Message,
        [string]$Level = "Information"
    )
    Write-Host "[$Level] $Message"
}

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed