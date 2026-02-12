#Requires -Version 5.1
<#
.SYNOPSIS
    Setup script for BlueCat DNS Manager - downloads required dependencies.
.DESCRIPTION
    Downloads System.Data.SQLite from NuGet and places it in the lib\ folder.
    Run this once before first use.
#>

# Resolve project root
if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptDir = $PSCommandPath | Split-Path -Parent
}
$scriptRoot = Split-Path -Parent $scriptDir
$libPath = Join-Path $scriptRoot 'lib'
$dataPath = Join-Path $scriptRoot 'data'
$logsPath = Join-Path $scriptRoot 'logs'

Write-Host ""
Write-Host "BlueCat DNS Manager - Setup" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Project root: $scriptRoot" -ForegroundColor Gray
Write-Host ""

# Create directories
foreach ($dir in @($libPath, $dataPath, $logsPath)) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Write-Host "  Created: $dir" -ForegroundColor Gray
    }
}

# Check if SQLite already exists
$sqliteDll = Join-Path $libPath 'System.Data.SQLite.dll'
if (Test-Path $sqliteDll) {
    Write-Host "System.Data.SQLite.dll already exists in lib\." -ForegroundColor Green
    Write-Host ""
}
else {
    Write-Host "Downloading System.Data.SQLite from NuGet..." -ForegroundColor Yellow

    $nugetUrl = 'https://www.nuget.org/api/v2/package/System.Data.SQLite.Core/1.0.118.0'

    $tempZip = Join-Path $env:TEMP 'sqlite-nuget.zip'
    $tempExtract = Join-Path $env:TEMP 'sqlite-nuget'

    try {
        # Ensure TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Clean up any previous temp files
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }

        Write-Host "  Fetching package from nuget.org..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $nugetUrl -OutFile $tempZip -UseBasicParsing

        if (-not (Test-Path $tempZip)) {
            throw "Download completed but file not found at $tempZip"
        }

        Write-Host "  Extracting package..." -ForegroundColor Gray
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        # Find the correct DLL for .NET Framework 4.x
        $candidates = @(
            (Join-Path $tempExtract "lib\net46\System.Data.SQLite.dll"),
            (Join-Path $tempExtract "lib\net45\System.Data.SQLite.dll"),
            (Join-Path $tempExtract "lib\net40\System.Data.SQLite.dll")
        )

        $foundDll = $null
        foreach ($candidate in $candidates) {
            if (Test-Path $candidate) {
                $foundDll = $candidate
                break
            }
        }

        if (-not $foundDll) {
            $foundDll = Get-ChildItem -Path $tempExtract -Filter 'System.Data.SQLite.dll' -Recurse |
                        Select-Object -First 1 -ExpandProperty FullName
        }

        if ($foundDll) {
            Copy-Item $foundDll -Destination $sqliteDll -Force
            Write-Host "  Installed: $sqliteDll" -ForegroundColor Green
        }
        else {
            Write-Host "  ERROR: Could not find System.Data.SQLite.dll in the NuGet package." -ForegroundColor Red
            Write-Host "  Extracted contents:" -ForegroundColor Yellow
            Get-ChildItem -Path $tempExtract -Recurse -File | ForEach-Object {
                Write-Host "    $($_.FullName.Replace($tempExtract, '.'))" -ForegroundColor Gray
            }
        }

        # Also copy the native interop DLL
        $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
        $interopDir = Join-Path $tempExtract "runtimes\win-$arch\native"
        if (Test-Path $interopDir) {
            $interopFiles = Get-ChildItem $interopDir -Filter '*.dll'
            foreach ($f in $interopFiles) {
                Copy-Item $f.FullName -Destination (Join-Path $libPath $f.Name) -Force
                Write-Host "  Installed: $(Join-Path $libPath $f.Name)" -ForegroundColor Green
            }
        }
        else {
            $interopFile = Get-ChildItem -Path $tempExtract -Filter 'SQLite.Interop.dll' -Recurse |
                           Where-Object { $_.FullName -match $arch } |
                           Select-Object -First 1
            if ($interopFile) {
                Copy-Item $interopFile.FullName -Destination (Join-Path $libPath 'SQLite.Interop.dll') -Force
                Write-Host "  Installed: $(Join-Path $libPath 'SQLite.Interop.dll')" -ForegroundColor Green
            }
            else {
                Write-Host "  WARNING: SQLite.Interop.dll not found for $arch. You may need to download it manually." -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "  Auto-download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Manual install instructions:" -ForegroundColor Yellow
        Write-Host "  1. Download from: https://system.data.sqlite.org/index.html/doc/trunk/www/downloads.wiki" -ForegroundColor White
        Write-Host "  2. Get 'Precompiled Binaries for .NET Framework 4.6' (64-bit)" -ForegroundColor White
        Write-Host "  3. Extract System.Data.SQLite.dll and SQLite.Interop.dll to:" -ForegroundColor White
        Write-Host "     $libPath" -ForegroundColor Cyan
    }
    finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Verify
Write-Host ""
Write-Host "Verification:" -ForegroundColor Cyan

$checks = @(
    @{ Name = "System.Data.SQLite.dll"; Path = $sqliteDll },
    @{ Name = "data\ directory"; Path = $dataPath },
    @{ Name = "logs\ directory"; Path = $logsPath }
)

$allGood = $true
foreach ($check in $checks) {
    if (Test-Path $check.Path) {
        Write-Host "  [OK] $($check.Name)" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] $($check.Name)" -ForegroundColor Red
        $allGood = $false
    }
}

Write-Host ""
if ($allGood) {
    Write-Host "Setup complete. You can now run BlueCatDnsManager-GUI.ps1" -ForegroundColor Green
}
else {
    Write-Host "Setup incomplete. Please resolve the missing items above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
