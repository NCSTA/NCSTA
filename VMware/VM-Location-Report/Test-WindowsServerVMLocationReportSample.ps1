# Sample test harness for Export-WindowsServerVMLocationReport.ps1.
#
# This file mocks the PowerCLI read-only inventory commands so the HTML report
# can be generated without connecting to vCenter.

$sampleOutputDir = Join-Path $PSScriptRoot 'SampleReports'
$reportScriptPath = Join-Path $PSScriptRoot 'Export-WindowsServerVMLocationReport.ps1'

function New-SampleHost {
    param(
        [string]$Name,
        [string]$Cluster,
        [int]$Sockets,
        [int]$Cores
    )

    [pscustomobject]@{
        Name = $Name
        Cluster = $Cluster
        ExtensionData = [pscustomobject]@{
            Hardware = [pscustomobject]@{
                CpuInfo = [pscustomobject]@{
                    NumCpuPackages = $Sockets
                    NumCpuCores = $Cores
                }
            }
        }
    }
}

function New-SampleVM {
    param(
        [string]$Name,
        [object]$VMHost,
        [string]$GuestId,
        [string]$GuestFullName,
        [string]$PowerState,
        [int]$VCpu,
        [double]$MemoryGB
    )

    [pscustomobject]@{
        Name = $Name
        GuestId = $GuestId
        Guest = [pscustomobject]@{
            OSFullName = $GuestFullName
        }
        ExtensionData = [pscustomobject]@{
            Config = [pscustomobject]@{
                Template = $false
                GuestId = $GuestId
                GuestFullName = $GuestFullName
            }
        }
        VMHost = $VMHost
        PowerState = $PowerState
        NumCpu = $VCpu
        MemoryGB = $MemoryGB
    }
}

$sampleInventory = @{}

$eastProdA1 = New-SampleHost -Name 'esx-east-prod-01.example.local' -Cluster 'Production Core' -Sockets 2 -Cores 56
$eastProdA2 = New-SampleHost -Name 'esx-east-prod-02.example.local' -Cluster 'Production Core' -Sockets 2 -Cores 56
$eastLinux1 = New-SampleHost -Name 'esx-east-linux-01.example.local' -Cluster 'Linux Platform' -Sockets 2 -Cores 64
$eastMgmt1 = New-SampleHost -Name 'esx-east-mgmt-01.example.local' -Cluster 'Management' -Sockets 2 -Cores 48
$eastStandalone = New-SampleHost -Name 'esx-east-standalone-01.example.local' -Cluster $null -Sockets 1 -Cores 24

$westDr1 = New-SampleHost -Name 'esx-west-dr-01.example.local' -Cluster 'DR Synergy Cluster' -Sockets 2 -Cores 56
$westDr2 = New-SampleHost -Name 'esx-west-dr-02.example.local' -Cluster 'DR Synergy Cluster' -Sockets 2 -Cores 56
$westCitrix1 = New-SampleHost -Name 'esx-west-citrix-01.example.local' -Cluster 'Citrix Management' -Sockets 2 -Cores 56
$westDev1 = New-SampleHost -Name 'esx-west-dev-01.example.local' -Cluster 'DEV' -Sockets 2 -Cores 40

$sampleInventory['vcsa-east.example.local'] = [pscustomobject]@{
    Clusters = @('Production Core', 'Linux Platform', 'Management', 'Empty Review Cluster')
    Hosts = @($eastProdA1, $eastProdA2, $eastLinux1, $eastMgmt1, $eastStandalone)
    VMs = @(
        (New-SampleVM -Name 'APP-WIN-001' -VMHost $eastProdA1 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2022 (64-bit)' -PowerState 'PoweredOn' -VCpu 4 -MemoryGB 16),
        (New-SampleVM -Name 'SQL-WIN-001' -VMHost $eastProdA1 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2019 (64-bit)' -PowerState 'PoweredOn' -VCpu 8 -MemoryGB 32),
        (New-SampleVM -Name 'WEB-WIN-002' -VMHost $eastProdA2 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2022 (64-bit)' -PowerState 'PoweredOn' -VCpu 4 -MemoryGB 12),
        (New-SampleVM -Name 'RHEL-APP-001' -VMHost $eastLinux1 -GuestId 'rhel8_64Guest' -GuestFullName 'Red Hat Enterprise Linux 8 (64-bit)' -PowerState 'PoweredOn' -VCpu 4 -MemoryGB 16),
        (New-SampleVM -Name 'MGMT-WIN-001' -VMHost $eastMgmt1 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2019 (64-bit)' -PowerState 'PoweredOff' -VCpu 2 -MemoryGB 8)
    )
}

$sampleInventory['vcsa-west.example.local'] = [pscustomobject]@{
    Clusters = @('DR Synergy Cluster', 'Citrix Management', 'DEV')
    Hosts = @($westDr1, $westDr2, $westCitrix1, $westDev1)
    VMs = @(
        (New-SampleVM -Name 'DR-WIN-001' -VMHost $westDr2 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2016 (64-bit)' -PowerState 'PoweredOn' -VCpu 4 -MemoryGB 16),
        (New-SampleVM -Name 'CTX-WIN-001' -VMHost $westCitrix1 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2022 (64-bit)' -PowerState 'PoweredOn' -VCpu 4 -MemoryGB 16),
        (New-SampleVM -Name 'CTX-WIN-002' -VMHost $westCitrix1 -GuestId 'windows9Server64Guest' -GuestFullName 'Microsoft Windows Server 2022 (64-bit)' -PowerState 'PoweredOn' -VCpu 4 -MemoryGB 16),
        (New-SampleVM -Name 'DEV-LINUX-001' -VMHost $westDev1 -GuestId 'ubuntu64Guest' -GuestFullName 'Ubuntu Linux (64-bit)' -PowerState 'PoweredOn' -VCpu 2 -MemoryGB 8)
    )
}

function Set-PowerCLIConfiguration {
    param(
        [object]$InvalidCertificateAction,
        [object]$Scope,
        [object]$Confirm
    )
}

function Connect-VIServer {
    param([string]$Server)

    [pscustomobject]@{
        Name = $Server
    }
}

function Get-Cluster {
    param(
        [object]$Server,
        [object]$VM,
        [object]$VMHost
    )

    if ($VM) {
        if (-not $VM.VMHost.Cluster) {
            return $null
        }

        return [pscustomobject]@{ Name = $VM.VMHost.Cluster }
    }

    if ($VMHost) {
        if (-not $VMHost.Cluster) {
            return $null
        }

        return [pscustomobject]@{ Name = $VMHost.Cluster }
    }

    $sampleInventory[$Server.Name].Clusters | ForEach-Object {
        [pscustomobject]@{ Name = $_ }
    }
}

function Get-VMHost {
    param([object]$Server)

    $sampleInventory[$Server.Name].Hosts
}

function Get-VM {
    param([object]$Server)

    $sampleInventory[$Server.Name].VMs
}

$script = Get-Content -Path $reportScriptPath -Raw
$script = [regex]::Replace($script, '(?m)^\$outputDir\s*=.*$', "`$outputDir = '$sampleOutputDir'             # sample output")
$script = [regex]::Replace($script, '(?s)\$vCenters\s*=\s*@\(\s*.*?\s*\)\s*# --- END CONFIG ---', "`$vCenters = @('vcsa-east.example.local', 'vcsa-west.example.local')`r`n# --- END CONFIG ---")

Invoke-Expression $script

Get-ChildItem -Path $sampleOutputDir -Filter 'Windows_Server_VM_Location_Report_*.html' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
