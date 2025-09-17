# File Access Validation Utilities for Contention Testing

class FileAccessValidator {
    [string] $ValidatorId
    [hashtable] $ValidationResults

    FileAccessValidator([string] $validatorId) {
        $this.ValidatorId = $validatorId
        $this.ValidationResults = @{}
    }

    [hashtable] ValidateExclusiveAccess([string] $filePath, [string] $operation) {
        $result = @{
            FilePath = $filePath
            Operation = $operation
            Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            IsExclusive = $false
            CanAccess = $false
            Error = $null
            LockInfo = @{}
        }

        try {
            switch ($operation.ToUpper()) {
                "READ" {
                    $result = $this.ValidateReadAccess($filePath, $result)
                }
                "WRITE" {
                    $result = $this.ValidateWriteAccess($filePath, $result)
                }
                "DELETE" {
                    $result = $this.ValidateDeleteAccess($filePath, $result)
                }
                default {
                    $result.Error = "Unknown operation: $operation"
                }
            }
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        $this.ValidationResults["$operation-$(Get-Date -Format 'HHmmss-fff')"] = $result
        return $result
    }

    [hashtable] ValidateReadAccess([string] $filePath, [hashtable] $result) {
        try {
            # Try to open file for reading
            $fileStream = [System.IO.File]::OpenRead($filePath)

            # Read a small portion to ensure read access
            $buffer = New-Object byte[] 1024
            $bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)

            $fileStream.Close()

            $result.CanAccess = $true
            $result.IsExclusive = $false  # Read access is typically shared
            $result.LockInfo = @{
                AccessType = "Read"
                BytesRead = $bytesRead
                SharedAccess = $true
            }
        }
        catch [System.IO.IOException] {
            $result.CanAccess = $false
            $result.Error = "File is locked for reading: $($_.Exception.Message)"
        }
        catch [System.UnauthorizedAccessException] {
            $result.CanAccess = $false
            $result.Error = "Unauthorized access to file: $($_.Exception.Message)"
        }

        return $result
    }

    [hashtable] ValidateWriteAccess([string] $filePath, [hashtable] $result) {
        try {
            # Try to open file for writing (exclusive access)
            $fileStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

            # Try to write a test byte
            $testByte = [byte]0xFF
            $originalPosition = $fileStream.Position
            $fileStream.WriteByte($testByte)

            # Restore original state
            $fileStream.Seek($originalPosition, [System.IO.SeekOrigin]::Begin)
            $fileStream.WriteByte(0x00)

            $fileStream.Close()

            $result.CanAccess = $true
            $result.IsExclusive = $true
            $result.LockInfo = @{
                AccessType = "Write"
                ExclusiveAccess = $true
                TestWriteSuccessful = $true
            }
        }
        catch [System.IO.IOException] {
            $result.CanAccess = $false
            $result.IsExclusive = $false
            $result.Error = "File is locked for writing: $($_.Exception.Message)"
        }
        catch [System.UnauthorizedAccessException] {
            $result.CanAccess = $false
            $result.Error = "Unauthorized write access to file: $($_.Exception.Message)"
        }

        return $result
    }

    [hashtable] ValidateDeleteAccess([string] $filePath, [hashtable] $result) {
        $originalExists = Test-Path $filePath

        try {
            # Get file attributes before attempting delete
            if ($originalExists) {
                $fileInfo = Get-Item $filePath
                $result.LockInfo["OriginalSize"] = $fileInfo.Length
                $result.LockInfo["OriginalLastWrite"] = $fileInfo.LastWriteTime
            }

            # Try to delete the file
            Remove-Item $filePath -Force -ErrorAction Stop

            $result.CanAccess = $true
            $result.IsExclusive = $true
            $result.LockInfo["Deleted"] = $true
            $result.LockInfo["FileExisted"] = $originalExists

        }
        catch [System.IO.IOException] {
            $result.CanAccess = $false
            $result.Error = "File is locked and cannot be deleted: $($_.Exception.Message)"
        }
        catch [System.UnauthorizedAccessException] {
            $result.CanAccess = $false
            $result.Error = "Unauthorized delete access to file: $($_.Exception.Message)"
        }
        catch {
            $result.CanAccess = $false
            $result.Error = "Delete operation failed: $($_.Exception.Message)"
        }

        return $result
    }

    [hashtable] GetSystemFileLocks([string] $filePath) {
        $lockInfo = @{
            FilePath = $filePath
            HasLocks = $false
            LockDetails = @()
            Platform = if ($env:OS -eq $null -and $env:HOME -ne $null) { "Linux" } else { "Windows" }
        }

        try {
            $isLinux = ($env:OS -eq $null -and $env:HOME -ne $null)
            if ($isLinux) {
                # Use lsof to detect file locks on Linux
                $lsofResult = & lsof $filePath 2>$null
                if ($LASTEXITCODE -eq 0 -and $lsofResult) {
                    $lockInfo.HasLocks = $true
                    $lockInfo.LockDetails = $lsofResult
                }
            }
            else {
                # On Windows, try to detect locks by attempting exclusive access
                try {
                    $fileStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    $fileStream.Close()
                    $lockInfo.HasLocks = $false
                }
                catch [System.IO.IOException] {
                    $lockInfo.HasLocks = $true
                    $lockInfo.LockDetails = @("File is exclusively locked")
                }
            }
        }
        catch {
            $lockInfo.Error = $_.Exception.Message
        }

        return $lockInfo
    }

    [hashtable] ValidateDataIntegrity([string] $filePath, [hashtable] $expectedPattern = @{}) {
        $integrity = @{
            FilePath = $filePath
            IsValid = $false
            FileSize = 0
            ChecksumValid = $false
            PatternValid = $false
            Error = $null
        }

        try {
            if (-not (Test-Path $filePath)) {
                $integrity.Error = "File does not exist"
                return $integrity
            }

            $fileInfo = Get-Item $filePath
            $integrity.FileSize = $fileInfo.Length

            # Read file data
            $data = [System.IO.File]::ReadAllBytes($filePath)

            # Validate expected size
            if ($expectedPattern.ContainsKey("Size") -and $data.Length -ne $expectedPattern.Size) {
                $integrity.Error = "Size mismatch: expected $($expectedPattern.Size), got $($data.Length)"
                return $integrity
            }

            # Validate pattern if specified
            if ($expectedPattern.ContainsKey("Pattern") -and $expectedPattern.Pattern -eq "Sequential") {
                $patternValid = $true
                for ($i = 0; $i -lt $data.Length -and $i -lt 1024; $i += 100) {
                    if ($data[$i] -ne ($i % 256)) {
                        $patternValid = $false
                        break
                    }
                }
                $integrity.PatternValid = $patternValid
            }
            else {
                $integrity.PatternValid = $true  # No pattern specified
            }

            # Calculate simple checksum
            $checksum = 0
            for ($i = 0; $i -lt [Math]::Min($data.Length, 10000); $i++) {
                $checksum += $data[$i]
            }
            $integrity.Checksum = $checksum

            if ($expectedPattern.ContainsKey("Checksum")) {
                $integrity.ChecksumValid = ($integrity.Checksum -eq $expectedPattern.Checksum)
            }
            else {
                $integrity.ChecksumValid = $true  # No checksum specified
            }

            $integrity.IsValid = $integrity.PatternValid -and $integrity.ChecksumValid
        }
        catch {
            $integrity.Error = $_.Exception.Message
        }

        return $integrity
    }

    [hashtable] GetValidationSummary() {
        $summary = @{
            ValidatorId = $this.ValidatorId
            TotalValidations = $this.ValidationResults.Count
            SuccessfulValidations = 0
            FailedValidations = 0
            ValidationsByType = @{}
        }

        foreach ($key in $this.ValidationResults.Keys) {
            $result = $this.ValidationResults[$key]
            if ($result.CanAccess) {
                $summary.SuccessfulValidations++
            }
            else {
                $summary.FailedValidations++
            }

            if (-not $summary.ValidationsByType.ContainsKey($result.Operation)) {
                $summary.ValidationsByType[$result.Operation] = 0
            }
            $summary.ValidationsByType[$result.Operation]++
        }

        return $summary
    }

    [void] ClearValidationResults() {
        $this.ValidationResults.Clear()
    }
}

# Factory function
function New-FileAccessValidator {
    param(
        [string] $ValidatorId = [System.Guid]::NewGuid().ToString('N')[0..7] -join ''
    )

    return [FileAccessValidator]::new($ValidatorId)
}