Set-StrictMode -Version Latest

function Test-AuditAdministrator {
    <# Returns true only when the current token is elevated. #>
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-AuditContext {
    <# Creates immutable run metadata and the auditor-visible report paths. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientName,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][hashtable]$Targets
    )

    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    }

    $computerName = $env:COMPUTERNAME
    $date = Get-Date
    # Match the legacy display format but never delete a pre-existing evidence folder.
    $baseName = '{0}-{1} {2}' -f $computerName, $date.ToLongDateString(), $date.ToLongTimeString().Replace(':', '.')
    $outputDirectory = Join-Path $OutputRoot $baseName
    $suffix = 1
    while (Test-Path -LiteralPath $outputDirectory) {
        $outputDirectory = Join-Path $OutputRoot ('{0}-{1}' -f $baseName, $suffix)
        $suffix++
    }
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    $reports = [ordered]@{
        SystemInfo            = "($computerName)SystemInfo.xls"
        Users                 = "($computerName)Users.xls"
        Groups                = "($computerName)Groups.xls"
        Netstat               = "($computerName)Netstat.txt"
        FilePermissions       = "($computerName)FilePermissions.xls"
        DirectoryPermissions  = "($computerName)DirectoryPermissions.xls"
        RegistryValues        = "($computerName)RegistryValues.xls"
        Services              = "($computerName)Services.xls"
        HotFixes              = "($computerName)HotFixes.xls"
        MissingHotfixes       = "($computerName)MissingHotfixes.xls"
        LogSettings           = "($computerName)LogSettings.xls"
        Shares                = "($computerName)Shares.xls"
        Drives                = "($computerName)Drives.xls"
        ADTrusts              = "($computerName)ADTrusts.xls"
        AdministrativeAccounts = "($computerName)AdministrativeAccounts.xls"
        Gpresult              = "($computerName)gpresult.txt"
        AuditPolicy           = "($computerName)AuditPolicy.txt"
        DetailedAuditSettings = "($computerName)DetailedAuditSettings.txt"
        EventLogPermissions   = "($computerName)EventLogPermissions.txt"
        ErrorLog              = 'ErrorLog.txt'
    }

    $paths = [ordered]@{}
    foreach ($name in $reports.Keys) { $paths[$name] = Join-Path $outputDirectory $reports[$name] }

    return [pscustomobject]@{
        Version = 'WindowsAudit PowerShell v0.1'
        ClientName = $ClientName
        ComputerName = $computerName
        Started = $date
        OutputDirectory = $outputDirectory
        Paths = $paths
        Targets = $Targets
        IsDomainController = $false
    }
}

function Initialize-AuditReports {
    <# Creates reports with the legacy confidentiality line. ADTrusts remains DC-only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = "{0}: Security Assessment: Confidential for {1} use only`r`n`r`n" -f $Context.Version, $Context.ClientName
    foreach ($name in $Context.Paths.Keys) {
        if ($name -eq 'ErrorLog' -or $name -in @('ADTrusts', 'AdministrativeAccounts')) { continue }
        [System.IO.File]::WriteAllText($Context.Paths[$name], $header, (Get-ReportTextEncoding -Context $Context))
    }
    [System.IO.File]::WriteAllText($Context.Paths.ErrorLog, ("{0} started: {1:o}`r`n" -f $Context.Version, $Context.Started), (Get-ReportTextEncoding -Context $Context))
}

function Get-ReportTextEncoding {
    <# Resolves the Windows ANSI code page explicitly on PowerShell 5.1 and 7+. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Targets.TextEncoding -ne 'Default') {
        return [System.Text.Encoding]::GetEncoding([string]$Context.Targets.TextEncoding)
    }
    return [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
}

function Write-AuditReport {
    <# Appends text with the configured legacy-compatible encoding. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateScript({ $Context.Paths.Contains($_) })][string]$Report,
        [AllowEmptyString()][string]$Text
    )

    $suffix = if ($Text.EndsWith([Environment]::NewLine)) { '' } else { [Environment]::NewLine }
    [System.IO.File]::AppendAllText($Context.Paths[$Report], $Text + $suffix, (Get-ReportTextEncoding -Context $Context))
}

function Write-AuditError {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Message)

    $line = '[{0:o}] {1}' -f (Get-Date), $Message.Trim()
    [System.IO.File]::AppendAllText($Context.Paths.ErrorLog, $line + [Environment]::NewLine, (Get-ReportTextEncoding -Context $Context))
}

function ConvertTo-AuditField {
    <# Keeps tabular reports parseable when native providers return newlines or tabs. #>
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
}

function ConvertTo-AuditQuotedField {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    return '"{0}"' -f ((ConvertTo-AuditField $Value).Replace('"', '""'))
}

function Invoke-AuditNative {
    <# Runs a built-in executable and sends stderr/exit failures to ErrorLog. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-AuditError -Context $Context -Message "Native command not found: $FilePath"
        return @()
    }
    try {
        $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            Write-AuditError -Context $Context -Message "Command exited ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
        }
        return @($output)
    }
    catch {
        Write-AuditError -Context $Context -Message "Command failed: $FilePath :: $($_.Exception.Message)"
        return @()
    }
}

function New-AuditManifest {
    <# Uses SHA-256 instead of the legacy bundled MD5 executable. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    Write-AuditReport -Context $Context -Report ErrorLog -Text "SHA-256 manifest created: SHA256SUMS.txt"
    $manifestPath = Join-Path $Context.OutputDirectory 'SHA256SUMS.txt'
    $entries = Get-ChildItem -LiteralPath $Context.OutputDirectory -Recurse -File |
        Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
        Sort-Object Name |
        ForEach-Object { "{0}`t{1}" -f $_.FullName.Substring($Context.OutputDirectory.Length).TrimStart('\'), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    [System.IO.File]::WriteAllLines($manifestPath, [string[]]$entries, (Get-ReportTextEncoding -Context $Context))
}

function Test-AuditManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AuditDirectory)

    $manifestPath = Join-Path $AuditDirectory 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "SHA-256 manifest not found: $manifestPath"
    }
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { throw "Invalid manifest record: $line" }
        $path = Join-Path $AuditDirectory $parts[0]
        $actual = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        [pscustomobject]@{ File = $parts[0]; Expected = $parts[1]; Actual = $actual; Match = ($actual -eq $parts[1]) }
    }
}

Export-ModuleMember -Function *-Audit*, Get-ReportTextEncoding, ConvertTo-AuditField, ConvertTo-AuditQuotedField, Test-AuditAdministrator
