#Requires -Version 5.1
<#
.SYNOPSIS
    BlueCat DNS Manager - Ad-hoc DNS record management GUI
.DESCRIPTION
    WPF GUI for managing DNS records via the BlueCat Address Manager RESTful v2 API.
    Supports creating, modifying, deleting records and deploying them independently
    of the normal scheduled deployment batch.
.NOTES
    Requires: BAM 9.5.0+, System.Data.SQLite.dll in .\lib\ folder
#>

param(
    [string]$BamServer,
    [switch]$SkipCertCheck
)

# ---------------------------------------------------------------------------
# Bootstrap - load assemblies and modules
# ---------------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

if ($PSScriptRoot) {
    $scriptRoot = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$modulesPath = Join-Path $scriptRoot 'modules'
$dataPath = Join-Path $scriptRoot 'data'
$libPath = Join-Path $scriptRoot 'lib'

# Load SQLite assembly
$sqliteDll = Join-Path $libPath 'System.Data.SQLite.dll'
if (Test-Path $sqliteDll) {
    function Get-DllMachineType {
        param([string]$Path)
        $fs = [System.IO.File]::OpenRead($Path)
        $br = New-Object System.IO.BinaryReader($fs)
        try {
            $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peOffset = $br.ReadInt32()
            $fs.Seek($peOffset + 4, [System.IO.SeekOrigin]::Begin) | Out-Null
            $machine = $br.ReadUInt16()
            return $machine
        }
        finally {
            $br.Close()
            $fs.Close()
        }
    }

    try {
        $machine = Get-DllMachineType -Path $sqliteDll
        switch ($machine) {
            332 { $dllArch = 'x86' }         # 0x014C
            34404 { $dllArch = 'x64' }       # 0x8664
            default { $dllArch = 'unknown' }
        }
        $procArch = if ([IntPtr]::Size -eq 8) { 'x64' } else { 'x86' }
        if ($dllArch -ne 'unknown' -and $dllArch -ne $procArch) {
            [System.Windows.MessageBox]::Show(
                "Mismatch between System.Data.SQLite.dll architecture ($dllArch) and PowerShell process ($procArch).`n`nPlease place the matching SQLite build in the .\lib\ folder.",
                "SQLite Architecture Mismatch", "OK", "Error"
            )
            exit 1
        }
    }
    catch {
        # If we can't determine architecture, continue but wrap initialization later
    }

    try {
        Add-Type -Path $sqliteDll
    }
    catch [System.IO.FileLoadException] {
        $err = $_.Exception
        if ($err.HResult -eq 0x80131515 -or $err.Message -match 'Operation is not supported') {
            try {
                if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
                    Unblock-File -Path $sqliteDll -ErrorAction Stop
                }
                else {
                    if (Get-Item -Path $sqliteDll -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
                        Remove-Item -Path $sqliteDll -Stream Zone.Identifier -ErrorAction Stop
                    }
                }
                Add-Type -Path $sqliteDll
            }
            catch {
                [System.Windows.MessageBox]::Show("Failed to load SQLite after unblocking: $($_.Exception.Message)", "SQLite Load Error", "OK", "Error")
                exit 1
            }
        }
        else {
            throw
        }
    }
} else {
    [System.Windows.MessageBox]::Show(
        "SQLite library not found at:`n$sqliteDll`n`nPlease place System.Data.SQLite.dll in the .\lib\ folder.",
        "Missing Dependency", "OK", "Error"
    )
    exit 1
}

Import-Module (Join-Path $modulesPath 'BlueCatApi.psm1') -Force
Import-Module (Join-Path $modulesPath 'StagingDb.psm1') -Force

# Initialize staging database
$dbFile = Join-Path $dataPath 'staging.db'
try {
    Initialize-StagingDb -Path $dbFile
}
catch [System.AccessViolationException] {
    $msg = "The embedded SQLite native library raised an AccessViolationException when opening the database.`n`n" +
           "This usually indicates a mismatch between the System.Data.SQLite.dll architecture (x86 vs x64) and the running PowerShell process." +
           "`n`nPlease ensure you have the correct System.Data.SQLite build for your PowerShell (use 64-bit DLL for 64-bit PowerShell)." +
           "`n`nPath: $sqliteDll`n`nError: $($_.Exception.Message)"
    [System.Windows.MessageBox]::Show($msg, "SQLite native load error", "OK", "Error")
    exit 1
}
catch {
    $err = $_.Exception.Message
    [System.Windows.MessageBox]::Show("Failed to initialize staging DB: $err", "DB Initialization Error", "OK", "Error")
    exit 1
}

# ---------------------------------------------------------------------------
# XAML UI Definition
# ---------------------------------------------------------------------------

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="BlueCat DNS Manager"
    Width="960" Height="720"
    WindowStartupLocation="CenterScreen"
    Background="#1e1e2e">

    <Window.Resources>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="Black"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="Black"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="4,2"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#ddd"/>
                    <Setter Property="Foreground" Value="Black"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#89b4fa"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#74c7ec"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#45475a"/>
                    <Setter Property="Foreground" Value="#6c7086"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#f38ba8"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#eba0ac"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SuccessButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#a6e3a1"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#94e2d5"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#181825"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="RowBackground" Value="#1e1e2e"/>
            <Setter Property="AlternatingRowBackground" Value="#181825"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#313244"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#89b4fa"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#6c7086"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="16,8"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Foreground" Value="#89b4fa"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#89b4fa"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Padding" Value="10"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header / Connection Bar -->
        <Border Grid.Row="0" Background="#181825" Padding="12,8">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="BlueCat DNS Manager"
                           Foreground="#89b4fa" FontSize="18" FontWeight="Bold"
                           VerticalAlignment="Center" Margin="0,0,20,0"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Label Content="Server:" Margin="0,0,4,0"/>
                    <TextBox x:Name="txtServer" Width="220" Margin="0,0,10,0"/>
                    <Label Content="Config:" Margin="0,0,4,0"/>
                    <ComboBox x:Name="cboConfig" Width="180" Margin="0,0,10,0" DisplayMemberPath="name"/>
                    <Label Content="View:" Margin="0,0,4,0"/>
                    <ComboBox x:Name="cboView" Width="180" DisplayMemberPath="name"/>
                </StackPanel>
                <Button Grid.Column="2" x:Name="btnConnect" Content="Connect" Margin="10,0,0,0"/>
                <Ellipse Grid.Column="3" x:Name="statusLight" Width="12" Height="12"
                         Fill="#f38ba8" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Main Content Tabs -->
        <TabControl Grid.Row="1" x:Name="mainTabs" Background="#1e1e2e" BorderBrush="#45475a"
                    Margin="0" Padding="0">

            <!-- TAB: Create / Modify Record -->
            <TabItem Header="Create / Modify">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16">
                    <StackPanel>
                        <GroupBox Header="Record Details">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="120"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="120"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Label Grid.Row="0" Grid.Column="0" Content="Record Type:"/>
                                <ComboBox Grid.Row="0" Grid.Column="1" x:Name="cboRecordType" Margin="0,2">
                                    <ComboBoxItem Content="A / Host Record" IsSelected="True"/>
                                    <ComboBoxItem Content="CNAME"/>
                                    <ComboBoxItem Content="MX"/>
                                    <ComboBoxItem Content="TXT"/>
                                    <ComboBoxItem Content="SRV"/>
                                    <ComboBoxItem Content="Generic"/>
                                </ComboBox>

                                <Label Grid.Row="0" Grid.Column="2" Content="TTL:"/>
                                <TextBox Grid.Row="0" Grid.Column="3" x:Name="txtTTL" Text="300" Margin="0,2"/>

                                <Label Grid.Row="1" Grid.Column="0" Content="Record Name:"/>
                                <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtRecordName" Margin="0,2"/>

                                <Label Grid.Row="1" Grid.Column="2" Content="Zone:"/>
                                <ComboBox Grid.Row="1" Grid.Column="3" x:Name="cboZone" Margin="0,2"
                                          IsEditable="True" DisplayMemberPath="absoluteName"/>

                                <Label Grid.Row="2" Grid.Column="0" Content="Value / Target:"/>
                                <TextBox Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="3"
                                         x:Name="txtRecordValue" Margin="0,2"/>

                                <Label Grid.Row="3" Grid.Column="0" Content="Comment:"/>
                                <TextBox Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="3"
                                         x:Name="txtComment" Margin="0,2"/>

                                <StackPanel Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="4"
                                            Orientation="Horizontal" Margin="0,8,0,0">
                                    <CheckBox x:Name="chkDeployNow" Content="Deploy immediately after save"
                                              IsChecked="False" Margin="0,0,20,0"/>
                                    <CheckBox x:Name="chkReverse" Content="Create reverse (PTR) record"
                                              Margin="0,0,20,0"/>
                                </StackPanel>
                            </Grid>
                        </GroupBox>

                        <GroupBox Header="Schedule (optional)">
                            <StackPanel Orientation="Horizontal">
                                <CheckBox x:Name="chkSchedule" Content="Schedule deployment for:"
                                          Margin="0,0,10,0" VerticalAlignment="Center"/>
                                <DatePicker x:Name="dpScheduleDate" Width="120" Margin="0,0,6,0" SelectedDateFormat="Short"/>
                                <ComboBox x:Name="cboScheduleTime" Width="80" IsEditable="True"/>
                                <ComboBox x:Name="cboScheduleAmpm" Width="60" Margin="6,0,0,0">
                                    <ComboBoxItem>AM</ComboBoxItem>
                                    <ComboBoxItem>PM</ComboBoxItem>
                                </ComboBox>
                                <Label Content="(AM/PM)" Foreground="#6c7086"/>
                            </StackPanel>
                        </GroupBox>

                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,0,0">
                            <Button x:Name="btnCreateRecord" Content="Create Record"
                                    Style="{StaticResource SuccessButton}" Margin="0,0,10,0"/>
                            <Button x:Name="btnModifyRecord" Content="Modify Selected Record"/>
                        </StackPanel>

                        <GroupBox Header="Existing Records in Zone" Margin="0,16,0,0">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                    <TextBox x:Name="txtSearchRecords" Width="300"
                                             Margin="0,0,10,0"/>
                                    <Button x:Name="btnSearchRecords" Content="Search Zone Records"/>
                                </StackPanel>
                                <DataGrid x:Name="dgRecords" AutoGenerateColumns="False"
                                          IsReadOnly="True" Height="220"
                                          SelectionMode="Single"
                                          CanUserSortColumns="True">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="ID" Binding="{Binding id}" Width="70"/>
                                        <DataGridTextColumn Header="Type" Binding="{Binding type}" Width="100"/>
                                        <DataGridTextColumn Header="Name" Binding="{Binding absoluteName}" Width="220"/>
                                        <DataGridTextColumn Header="Value" Binding="{Binding rdata}" Width="*"/>
                                        <DataGridTextColumn Header="TTL" Binding="{Binding ttl}" Width="60"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <!-- TAB: Delete Record -->
            <TabItem Header="Delete Record">
                <StackPanel Margin="16">
                    <GroupBox Header="Find Record to Delete">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <Label Content="Zone:"/>
                                <ComboBox x:Name="cboDeleteZone" Width="260" Margin="0,0,10,0"
                                          IsEditable="True" DisplayMemberPath="absoluteName"/>
                                <TextBox x:Name="txtDeleteSearch" Width="240" Margin="0,0,10,0"/>
                                <Button x:Name="btnDeleteSearch" Content="Search"/>
                            </StackPanel>
                            <DataGrid x:Name="dgDeleteRecords" AutoGenerateColumns="False"
                                      IsReadOnly="True" Height="300"
                                      SelectionMode="Single">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="ID" Binding="{Binding id}" Width="70"/>
                                    <DataGridTextColumn Header="Type" Binding="{Binding type}" Width="100"/>
                                    <DataGridTextColumn Header="Name" Binding="{Binding absoluteName}" Width="220"/>
                                    <DataGridTextColumn Header="Value" Binding="{Binding rdata}" Width="*"/>
                                    <DataGridTextColumn Header="TTL" Binding="{Binding ttl}" Width="60"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </StackPanel>
                    </GroupBox>

                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                        <CheckBox x:Name="chkDeleteDeploy" Content="Deploy immediately after delete"
                                  IsChecked="False" Margin="0,0,20,0" VerticalAlignment="Center"/>
                        <TextBox x:Name="txtDeleteComment" Width="300" Margin="0,0,10,0"/>
                        <Label Content="Comment" Foreground="#6c7086"/>
                    </StackPanel>

                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
                        <Button x:Name="btnDeleteRecord" Content="Delete Selected Record"
                                Style="{StaticResource DangerButton}"/>
                    </StackPanel>
                </StackPanel>
            </TabItem>

            <!-- TAB: Staged Items -->
            <TabItem Header="Staged Items">
                <StackPanel Margin="16">
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                        <Label Content="Filter:"/>
                        <ComboBox x:Name="cboStagedFilter" Width="150" Margin="0,0,10,0" SelectedIndex="0">
                            <ComboBoxItem Content="All"/>
                            <ComboBoxItem Content="Pending"/>
                            <ComboBoxItem Content="Deployed"/>
                            <ComboBoxItem Content="Failed"/>
                            <ComboBoxItem Content="Scheduled"/>
                        </ComboBox>
                        <Button x:Name="btnRefreshStaged" Content="Refresh"/>
                        <Button x:Name="btnCancelStaged" Content="Cancel Selected"
                                Style="{StaticResource DangerButton}" Margin="10,0,0,0"/>
                        <Button x:Name="btnDeployStaged" Content="Deploy Selected Now"
                                Style="{StaticResource SuccessButton}" Margin="10,0,0,0"/>
                    </StackPanel>

                    <DataGrid x:Name="dgStaged" AutoGenerateColumns="False"
                              IsReadOnly="True" Height="480"
                              SelectionMode="Single"
                              CanUserSortColumns="True">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="ID" Binding="{Binding id}" Width="50"/>
                            <DataGridTextColumn Header="Action" Binding="{Binding action}" Width="70"/>
                            <DataGridTextColumn Header="Type" Binding="{Binding record_type}" Width="80"/>
                            <DataGridTextColumn Header="Name" Binding="{Binding record_name}" Width="180"/>
                            <DataGridTextColumn Header="Zone" Binding="{Binding zone_name}" Width="150"/>
                            <DataGridTextColumn Header="Value" Binding="{Binding record_value}" Width="140"/>
                            <DataGridTextColumn Header="Deploy" Binding="{Binding deploy_mode}" Width="75"/>
                            <DataGridTextColumn Header="Scheduled" Binding="{Binding scheduled_time}" Width="130"/>
                            <DataGridTextColumn Header="Status" Binding="{Binding status}" Width="75"/>
                            <DataGridTextColumn Header="Created By" Binding="{Binding created_by}" Width="100"/>
                            <DataGridTextColumn Header="Created" Binding="{Binding created_at}" Width="130"/>
                            <DataGridTextColumn Header="Deployed" Binding="{Binding deployed_at}" Width="130"/>
                            <DataGridTextColumn Header="Error" Binding="{Binding error_message}" Width="150"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </StackPanel>
            </TabItem>

            <!-- TAB: Quick / Selective Deploy -->
            <TabItem Header="Deploy Tools">
                <StackPanel Margin="16">
                    <GroupBox Header="Selective Deploy (single entity)">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <Label Content="Entity ID:"/>
                                <TextBox x:Name="txtDeployEntityId" Width="150" Margin="0,0,10,0"/>
                                <Button x:Name="btnSelectiveDeploy" Content="Selective Deploy"
                                        Style="{StaticResource SuccessButton}"/>
                            </StackPanel>
                            <TextBlock Foreground="#6c7086" FontSize="12" TextWrapping="Wrap"
                                       Text="Deploys only the specified entity and its related records. Does NOT push the entire staged batch. Use the record ID from the Create/Modify or Delete tabs."/>
                        </StackPanel>
                    </GroupBox>

                    <GroupBox Header="Quick Deploy (entire zone)">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <Label Content="Zone:"/>
                                <ComboBox x:Name="cboQuickDeployZone" Width="260" Margin="0,0,10,0"
                                          IsEditable="True" DisplayMemberPath="absoluteName"/>
                                <Button x:Name="btnQuickDeploy" Content="Quick Deploy Zone"/>
                            </StackPanel>
                            <TextBlock Foreground="#6c7086" FontSize="12" TextWrapping="Wrap"
                                       Text="Deploys ALL pending changes in the selected zone. This is faster than a full server deploy but pushes everything staged in that zone."/>
                        </StackPanel>
                    </GroupBox>

                    <GroupBox Header="Deployment Status Check">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <Label Content="Deployment ID:"/>
                                <TextBox x:Name="txtCheckDeployId" Width="150" Margin="0,0,10,0"/>
                                <Button x:Name="btnCheckDeploy" Content="Check Status"/>
                            </StackPanel>
                            <TextBox x:Name="txtDeployResult" Height="120"
                                     IsReadOnly="True" TextWrapping="Wrap"
                                     VerticalScrollBarVisibility="Auto"
                                     Background="#181825" Foreground="#a6e3a1"
                                     FontFamily="Consolas" FontSize="12"/>
                        </StackPanel>
                    </GroupBox>
                </StackPanel>
            </TabItem>

        </TabControl>

        <!-- Status Bar -->
        <Border Grid.Row="2" Background="#181825" Padding="12,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" x:Name="statusText" Foreground="#a6adc8" FontSize="12"
                           Text="Not connected" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" x:Name="userText" Foreground="#6c7086" FontSize="12"
                           VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

# ---------------------------------------------------------------------------
# Create WPF window from XAML
# ---------------------------------------------------------------------------

$reader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
}
catch {
    $err = $_.Exception
    $full = $err.ToString()
    $logDir = Join-Path $scriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }
    $logFile = Join-Path $logDir 'xaml-parse-error.txt'
    $full | Out-File -FilePath $logFile -Encoding UTF8
    Write-Error $full
    [System.Windows.MessageBox]::Show("Failed to parse XAML window. Details written to: `n$logFile", "XAML Parse Error", "OK", "Error")
    exit 1
}

# Map named controls
$controls = @{}
$xaml.SelectNodes('//*[@*[contains(translate(name(),"x","X"),"Name")]]') | ForEach-Object {
    $name = $_.Name
    if (-not $name) { $name = $_.'x:Name' }
    if ($name) {
        $controls[$name] = $window.FindName($name)
    }
}

# Convenience aliases
$txtServer          = $controls['txtServer']
$cboConfig          = $controls['cboConfig']
$cboView            = $controls['cboView']
$btnConnect         = $controls['btnConnect']
$statusLight        = $controls['statusLight']
$statusText         = $controls['statusText']
$userText           = $controls['userText']

$cboRecordType      = $controls['cboRecordType']
$txtTTL             = $controls['txtTTL']
$txtRecordName      = $controls['txtRecordName']
$cboZone            = $controls['cboZone']
$txtRecordValue     = $controls['txtRecordValue']
$txtComment         = $controls['txtComment']
$chkDeployNow       = $controls['chkDeployNow']
$chkReverse         = $controls['chkReverse']
$chkSchedule        = $controls['chkSchedule']
$dpScheduleDate     = $controls['dpScheduleDate']
$cboScheduleTime    = $controls['cboScheduleTime']
$cboScheduleAmpm    = $controls['cboScheduleAmpm']
$btnCreateRecord    = $controls['btnCreateRecord']
$btnModifyRecord    = $controls['btnModifyRecord']
$txtSearchRecords   = $controls['txtSearchRecords']
$btnSearchRecords   = $controls['btnSearchRecords']
$dgRecords          = $controls['dgRecords']

$cboDeleteZone      = $controls['cboDeleteZone']
$txtDeleteSearch    = $controls['txtDeleteSearch']
$btnDeleteSearch    = $controls['btnDeleteSearch']
$dgDeleteRecords    = $controls['dgDeleteRecords']
$chkDeleteDeploy    = $controls['chkDeleteDeploy']
$txtDeleteComment   = $controls['txtDeleteComment']
$btnDeleteRecord    = $controls['btnDeleteRecord']

$cboStagedFilter    = $controls['cboStagedFilter']
$btnRefreshStaged   = $controls['btnRefreshStaged']
$btnCancelStaged    = $controls['btnCancelStaged']
$btnDeployStaged    = $controls['btnDeployStaged']
$dgStaged           = $controls['dgStaged']

$txtDeployEntityId  = $controls['txtDeployEntityId']
$btnSelectiveDeploy = $controls['btnSelectiveDeploy']
$cboQuickDeployZone = $controls['cboQuickDeployZone']
$btnQuickDeploy     = $controls['btnQuickDeploy']
$txtCheckDeployId   = $controls['txtCheckDeployId']
$btnCheckDeploy     = $controls['btnCheckDeploy']


$txtDeployResult    = $controls['txtDeployResult']

if ($BamServer) { $txtServer.Text = $BamServer }

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:IsConnected = $false
$script:ZoneCache = @()

function Set-Status {
    param([string]$Message, [string]$Color = '#a6adc8')
    $statusText.Text = $Message
    $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Show-Error {
    param([string]$Title, [string]$Message)
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error')
}

function Show-Info {
    param([string]$Title, [string]$Message)
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information')
}

function Populate-ZoneCombos {
    $topZones = Get-BlueCatZones
    $allZones = New-Object System.Collections.ArrayList
    $seenZoneIds = @{}

    Add-ZonesRecursive -Zones $topZones -Accumulator $allZones -SeenIds $seenZoneIds
    $script:ZoneCache = @($allZones | Sort-Object absoluteName)

    $cboZone.ItemsSource = $script:ZoneCache
    $cboDeleteZone.ItemsSource = $script:ZoneCache
    $cboQuickDeployZone.ItemsSource = $script:ZoneCache
    if ($script:ZoneCache.Count -gt 0) {
        $cboZone.SelectedIndex = 0
        $cboDeleteZone.SelectedIndex = 0
        $cboQuickDeployZone.SelectedIndex = 0
    }
}

function Add-ZonesRecursive {
    param(
        [object[]]$Zones,
        [System.Collections.ArrayList]$Accumulator,
        [hashtable]$SeenIds
    )

    foreach ($zone in @($Zones)) {
        if (-not $zone -or -not $zone.id) { continue }

        $zoneId = [int]$zone.id
        if ($SeenIds.ContainsKey($zoneId)) { continue }
        $SeenIds[$zoneId] = $true
        [void]$Accumulator.Add($zone)

        try {
            $childZones = Get-BlueCatSubZones -ZoneId $zoneId
            if ($childZones -and $childZones.Count -gt 0) {
                Add-ZonesRecursive -Zones $childZones -Accumulator $Accumulator -SeenIds $SeenIds
            }
        }
        catch {
            Write-Verbose "Failed to load child zones for zone ID $zoneId`: $($_.Exception.Message)"
        }
    }
}

function Refresh-StagedGrid {
    $filterText = ($cboStagedFilter.SelectedItem.Content).ToString().ToLower()
    $data = Get-StagedChanges -Filter $filterText
    $dgStaged.ItemsSource = $data.DefaultView
}

function Get-SelectedZone {
    param($combo)

    if ($combo.SelectedItem -and $combo.SelectedItem.id) {
        return $combo.SelectedItem
    }

    $zoneText = $combo.Text.Trim()
    if (-not $zoneText) { return $null }

    $match = $script:ZoneCache | Where-Object { $_.absoluteName -eq $zoneText } | Select-Object -First 1
    if ($match) { return $match }

    return $script:ZoneCache | Where-Object { $_.name -eq $zoneText } | Select-Object -First 1
}

function Get-SelectedZoneId {
    param($combo)
    $sel = Get-SelectedZone $combo
    if ($sel -and $sel.id) { return [int]$sel.id }
    return $null
}

function New-RecordSearchFilter {
    param([string]$SearchText)

    $search = $SearchText.Trim()
    if (-not $search) { return $null }

    $escapedSearch = $search.Replace("'", "''")
    if ($search -match '\.') {
        return "absoluteName:contains('$escapedSearch')"
    }

    return "name:contains('$escapedSearch')"
}

function Get-RecordDisplayValue {
    param($record)
    if ($record.rdata) { return $record.rdata }
    if ($record.text) { return $record.text }
    if ($record.addresses) {
        return ($record.addresses | ForEach-Object { $_.address }) -join ', '
    }
    if ($record.linkedRecord -and $record.linkedRecord.absoluteName) {
        return $record.linkedRecord.absoluteName
    }
    return ''
}

# ---------------------------------------------------------------------------
# Event: Connect
# ---------------------------------------------------------------------------

$btnConnect.Add_Click({
    if ($script:IsConnected) {
        try {
            Disconnect-BlueCat
        } catch {}
        $script:IsConnected = $false
        $statusLight.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#f38ba8')
        $btnConnect.Content = 'Connect'
        Set-Status 'Disconnected'
        $userText.Text = ''
        return
    }

    $server = $txtServer.Text.Trim()
    if (-not $server) {
        Show-Error 'Connection' 'Please enter the BAM server hostname or IP.'
        return
    }

    $cred = Get-Credential -Message "Enter BlueCat Address Manager credentials for $server"
    if (-not $cred) { return }

    Set-Status 'Connecting...' '#f9e2af'

    try {
        $params = @{ Server = $server; Credential = $cred }
        if ($SkipCertCheck) { $params['SkipCertCheck'] = $true }
        Connect-BlueCat @params

        $configs = Get-BlueCatConfigurations
        $cboConfig.ItemsSource = $configs
        if ($configs.Count -gt 0) {
            $cboConfig.SelectedIndex = 0
        }

        $script:IsConnected = $true
        $statusLight.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#a6e3a1')
        $btnConnect.Content = 'Disconnect'
        $userText.Text = "User: $(Get-BlueCatCurrentUser)"
        Set-Status "Connected to $server" '#a6e3a1'
    }
    catch {
        Show-Error 'Connection Failed' $_.Exception.Message
        Set-Status 'Connection failed' '#f38ba8'
    }
})

# Event: Config changed -> load views
$cboConfig.Add_SelectionChanged({
    $sel = $cboConfig.SelectedItem
    if (-not $sel) { return }

    try {
        Set-BlueCatContext -ConfigurationId $sel.id -ViewId 0
        $views = Get-BlueCatViews -ConfigurationId $sel.id
        $cboView.ItemsSource = $views
        if ($views.Count -gt 0) {
            $cboView.SelectedIndex = 0
        }
    }
    catch {
        Show-Error 'Load Views' $_.Exception.Message
    }
})

# Event: View changed -> set context and load zones
$cboView.Add_SelectionChanged({
    $selConfig = $cboConfig.SelectedItem
    $selView = $cboView.SelectedItem
    if (-not $selConfig -or -not $selView) { return }

    try {
        Set-BlueCatContext -ConfigurationId $selConfig.id -ViewId $selView.id
        Populate-ZoneCombos
        Set-Status "Context: $($selConfig.name) / $($selView.name) - $($script:ZoneCache.Count) zones loaded"
    }
    catch {
        Show-Error 'Load Zones' $_.Exception.Message
    }
})

# ---------------------------------------------------------------------------
# Event: Search records in zone
# ---------------------------------------------------------------------------

$btnSearchRecords.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $zoneId = Get-SelectedZoneId $cboZone
    if (-not $zoneId) { Show-Error 'Error' 'Select a zone first.'; return }

    Set-Status 'Searching records...' '#f9e2af'
    try {
        $filter = New-RecordSearchFilter -SearchText $txtSearchRecords.Text
        $records = Get-BlueCatResourceRecords -ZoneId $zoneId -Filter $filter

        $display = $records | ForEach-Object {
            [PSCustomObject]@{
                id           = $_.id
                type         = $_.type
                absoluteName = $_.absoluteName
                rdata        = (Get-RecordDisplayValue $_)
                ttl          = $_.ttl
            }
        }

        $dgRecords.ItemsSource = @($display)
        Set-Status "$($records.Count) records found"
    }
    catch {
        Show-Error 'Search Failed' $_.Exception.Message
        Set-Status 'Search failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Create Record
# ---------------------------------------------------------------------------

$btnCreateRecord.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $zoneId = Get-SelectedZoneId $cboZone
    if (-not $zoneId) { Show-Error 'Error' 'Select a zone.'; return }

    $recName  = $txtRecordName.Text.Trim()
    $recValue = $txtRecordValue.Text.Trim()
    $recType  = Get-BlueCatRecordTypeApiName ($cboRecordType.SelectedItem.Content.ToString())
    $ttl      = [int]$txtTTL.Text
    $comment  = $txtComment.Text.Trim()
    $selectedZone = Get-SelectedZone $cboZone
    $zoneName = $selectedZone.absoluteName

    if (-not $recName -or -not $recValue) {
        Show-Error 'Validation' 'Record name and value are required.'
        return
    }

    $linkedRecord = $null
    if ($recType -eq 'AliasRecord') {
        $targetRecord = $dgRecords.SelectedItem
        $targetName = $recValue.TrimEnd('.')

        if (-not $targetRecord -or $targetRecord.absoluteName -ne $targetName) {
            Show-Error 'Validation' "For CNAME records, search for and select the target record in Existing Records in Zone, then set Value / Target to that selected record's FQDN."
            return
        }

        $linkedRecord = @{
            id   = [int]$targetRecord.id
            type = $targetRecord.type
        }
    }

    $deployMode = 'manual'
    $scheduledTime = $null

    if ($chkSchedule.IsChecked) {
        $deployMode = 'scheduled'
        try {
            if (-not $dpScheduleDate.SelectedDate) {
                Show-Error 'Validation' 'Please select a schedule date.'
                return
            }
            $datePart = $dpScheduleDate.SelectedDate.Value.ToString('yyyy-MM-dd')
            $timePart = $cboScheduleTime.Text
            $ampm = $cboScheduleAmpm.Text
            $scheduledTime = [datetime]::ParseExact(
                "$datePart $timePart $ampm",
                'yyyy-MM-dd hh:mm tt', $null
            )
        }
        catch {
            Show-Error 'Validation' 'Invalid schedule date/time format. Use yyyy-MM-dd HH:mm.'
            return
        }
    }
    elseif ($chkDeployNow.IsChecked) {
        $deployMode = 'immediate'
    }

    Set-Status 'Creating record...' '#f9e2af'

    try {
        $params = @{
            ZoneId  = $zoneId
            Type    = $recType
            Name    = $recName
            RData   = $recValue
            TTL     = $ttl
            Comment = $comment
        }
        if ($chkReverse.IsChecked) { $params['CreateReverseRecord'] = $true }
        if ($linkedRecord) { $params['LinkedRecord'] = $linkedRecord }

        $newRecord = New-BlueCatResourceRecord @params
        $entityId = $newRecord.id

        # Log to staging DB
        $stageParams = @{
            RecordType  = $recType
            RecordName  = $recName
            ZoneName    = $zoneName
            RecordValue = $recValue
            TTL         = $ttl
            Action      = 'create'
            DeployMode  = $deployMode
            CreatedBy   = Get-BlueCatCurrentUser
            BamEntityId = $entityId
            Comment     = $comment
        }
        if ($scheduledTime) { $stageParams['ScheduledTime'] = $scheduledTime }
        $stageId = Add-StagedChange @stageParams

        if ($deployMode -eq 'immediate') {
            Set-Status 'Deploying record...' '#f9e2af'
            try {
                $deployment = Invoke-BlueCatSelectiveDeploy -EntityId $entityId
                Update-StagedChangeStatus -Id $stageId -Status 'deployed' -DeploymentId $deployment.id
                Set-Status "Record created and deployed (Entity: $entityId)" '#a6e3a1'
            }
            catch {
                Update-StagedChangeStatus -Id $stageId -Status 'failed' -ErrorMessage $_.Exception.Message
                Show-Error 'Deploy Failed' "Record was created (ID: $entityId) but deployment failed:`n$($_.Exception.Message)"
                Set-Status 'Record created but deploy failed' '#f38ba8'
            }
        }
        elseif ($deployMode -eq 'scheduled') {
            Set-Status "Record created, deployment scheduled for $($scheduledTime.ToString('yyyy-MM-dd HH:mm'))" '#f9e2af'
        }
        else {
            Set-Status "Record created (Entity: $entityId) - not deployed" '#f9e2af'
        }

        # Clear form
        $txtRecordName.Text = ''
        $txtRecordValue.Text = ''
        $txtComment.Text = ''
    }
    catch {
        Show-Error 'Create Failed' $_.Exception.Message
        Set-Status 'Create failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Modify Record (from grid selection)
# ---------------------------------------------------------------------------

$btnModifyRecord.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $selected = $dgRecords.SelectedItem
    if (-not $selected) {
        Show-Error 'Error' 'Select a record from the grid to modify.'
        return
    }

    $recValue = $txtRecordValue.Text.Trim()
    $ttl      = [int]$txtTTL.Text
    $comment  = $txtComment.Text.Trim()
    $selectedZone = Get-SelectedZone $cboZone
    $zoneName = $selectedZone.absoluteName

    if (-not $recValue) {
        Show-Error 'Validation' 'Enter the new value for the record.'
        return
    }

    $deployMode = if ($chkDeployNow.IsChecked) { 'immediate' } else { 'manual' }

    $confirmResult = [System.Windows.MessageBox]::Show(
        "Modify record '$($selected.absoluteName)' (ID: $($selected.id))?`nNew value: $recValue",
        'Confirm Modify', 'YesNo', 'Question'
    )
    if ($confirmResult -ne 'Yes') { return }

    Set-Status 'Modifying record...' '#f9e2af'

    try {
        $params = @{
            Id      = [int]$selected.id
            RData   = $recValue
            TTL     = $ttl
            Comment = $comment
            Type    = $selected.type
        }
        Update-BlueCatResourceRecord @params

        $stageId = Add-StagedChange -RecordType $selected.type -RecordName $selected.absoluteName `
            -ZoneName $zoneName -RecordValue $recValue -TTL $ttl -Action 'modify' `
            -DeployMode $deployMode -CreatedBy (Get-BlueCatCurrentUser) `
            -BamEntityId ([int]$selected.id) -Comment $comment

        if ($deployMode -eq 'immediate') {
            Set-Status 'Deploying modified record...' '#f9e2af'
            try {
                $deployment = Invoke-BlueCatSelectiveDeploy -EntityId ([int]$selected.id)
                Update-StagedChangeStatus -Id $stageId -Status 'deployed' -DeploymentId $deployment.id
                Set-Status "Record modified and deployed" '#a6e3a1'
            }
            catch {
                Update-StagedChangeStatus -Id $stageId -Status 'failed' -ErrorMessage $_.Exception.Message
                Show-Error 'Deploy Failed' "Record modified but deployment failed:`n$($_.Exception.Message)"
                Set-Status 'Record modified but deploy failed' '#f38ba8'
            }
        }
        else {
            Set-Status "Record modified (not deployed)"
        }
    }
    catch {
        Show-Error 'Modify Failed' $_.Exception.Message
        Set-Status 'Modify failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Delete tab - Search
# ---------------------------------------------------------------------------

$btnDeleteSearch.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $zoneId = Get-SelectedZoneId $cboDeleteZone
    if (-not $zoneId) { Show-Error 'Error' 'Select a zone first.'; return }

    Set-Status 'Searching records...' '#f9e2af'
    try {
        $filter = New-RecordSearchFilter -SearchText $txtDeleteSearch.Text
        $records = Get-BlueCatResourceRecords -ZoneId $zoneId -Filter $filter

        $display = $records | ForEach-Object {
            [PSCustomObject]@{
                id           = $_.id
                type         = $_.type
                absoluteName = $_.absoluteName
                rdata        = (Get-RecordDisplayValue $_)
                ttl          = $_.ttl
            }
        }

        $dgDeleteRecords.ItemsSource = @($display)
        Set-Status "$($records.Count) records found"
    }
    catch {
        Show-Error 'Search Failed' $_.Exception.Message
        Set-Status 'Search failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Delete Record
# ---------------------------------------------------------------------------

$btnDeleteRecord.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $selected = $dgDeleteRecords.SelectedItem
    if (-not $selected) {
        Show-Error 'Error' 'Select a record from the grid to delete.'
        return
    }

    $confirmResult = [System.Windows.MessageBox]::Show(
        "DELETE record '$($selected.absoluteName)' (ID: $($selected.id))?`n`nThis cannot be undone.",
        'Confirm Delete', 'YesNo', 'Warning'
    )
    if ($confirmResult -ne 'Yes') { return }

    $comment  = $txtDeleteComment.Text.Trim()
    $selectedZone = Get-SelectedZone $cboDeleteZone
    $zoneName = $selectedZone.absoluteName
    $deployNow = $chkDeleteDeploy.IsChecked
    $entityId = [int]$selected.id

    Set-Status 'Deleting record...' '#f9e2af'

    try {
        Remove-BlueCatResourceRecord -Id $entityId -Comment $comment

        $stageId = Add-StagedChange -RecordType $selected.type -RecordName $selected.absoluteName `
            -ZoneName $zoneName -RecordValue $selected.rdata -Action 'delete' `
            -DeployMode $(if ($deployNow) {'immediate'} else {'manual'}) `
            -CreatedBy (Get-BlueCatCurrentUser) -BamEntityId $entityId -Comment $comment

        if ($deployNow) {
            Set-Status 'Deploying deletion...' '#f9e2af'
            try {
                # After delete, deploy via quick deploy on the zone since entity no longer exists
                $zoneId = Get-SelectedZoneId $cboDeleteZone
                $deployment = Invoke-BlueCatQuickDeploy -ZoneId $zoneId
                Update-StagedChangeStatus -Id $stageId -Status 'deployed' -DeploymentId $deployment.id
                Set-Status "Record deleted and zone deployed" '#a6e3a1'
            }
            catch {
                # Try selective deploy as fallback
                try {
                    $deployment = Invoke-BlueCatSelectiveDeploy -EntityId $entityId
                    Update-StagedChangeStatus -Id $stageId -Status 'deployed' -DeploymentId $deployment.id
                    Set-Status "Record deleted and deployed" '#a6e3a1'
                }
                catch {
                    Update-StagedChangeStatus -Id $stageId -Status 'failed' -ErrorMessage $_.Exception.Message
                    Show-Error 'Deploy Failed' "Record deleted but deployment failed:`n$($_.Exception.Message)"
                    Set-Status 'Deleted but deploy failed' '#f38ba8'
                }
            }
        }
        else {
            Set-Status "Record deleted (not deployed)" '#f9e2af'
        }

        # Refresh grid
        $btnDeleteSearch.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
    catch {
        Show-Error 'Delete Failed' $_.Exception.Message
        Set-Status 'Delete failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Staged Items tab
# ---------------------------------------------------------------------------

$btnRefreshStaged.Add_Click({
    Refresh-StagedGrid
    Set-Status 'Staged items refreshed'
})

$btnCancelStaged.Add_Click({
    $selected = $dgStaged.SelectedItem
    if (-not $selected) {
        Show-Error 'Error' 'Select a staged item to cancel.'
        return
    }

    $row = $selected.Row
    $id = [int]$row['id']
    $status = $row['status'].ToString()

    if ($status -notin @('pending','failed')) {
        Show-Error 'Error' "Cannot cancel an item with status '$status'."
        return
    }

    Update-StagedChangeStatus -Id $id -Status 'cancelled'
    Refresh-StagedGrid
    Set-Status "Staged item $id cancelled"
})

$btnDeployStaged.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $selected = $dgStaged.SelectedItem
    if (-not $selected) {
        Show-Error 'Error' 'Select a staged item to deploy.'
        return
    }

    $row = $selected.Row
    $id = [int]$row['id']
    $entityId = if ($row['bam_entity_id'] -is [DBNull]) { 0 } else { [int]$row['bam_entity_id'] }

    if ($entityId -le 0) {
        Show-Error 'Error' 'No BAM entity ID associated with this staged item. Cannot deploy.'
        return
    }

    Set-Status 'Deploying staged item...' '#f9e2af'
    Update-StagedChangeStatus -Id $id -Status 'deploying'

    try {
        $deployment = Invoke-BlueCatSelectiveDeploy -EntityId $entityId
        Update-StagedChangeStatus -Id $id -Status 'deployed' -DeploymentId $deployment.id
        Set-Status "Staged item $id deployed successfully" '#a6e3a1'
    }
    catch {
        Update-StagedChangeStatus -Id $id -Status 'failed' -ErrorMessage $_.Exception.Message
        Show-Error 'Deploy Failed' $_.Exception.Message
        Set-Status 'Deploy failed' '#f38ba8'
    }

    Refresh-StagedGrid
})

# ---------------------------------------------------------------------------
# Event: Deploy Tools tab
# ---------------------------------------------------------------------------

$btnSelectiveDeploy.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $entityId = $txtDeployEntityId.Text.Trim()
    if (-not $entityId -or $entityId -notmatch '^\d+$') {
        Show-Error 'Validation' 'Enter a valid entity ID.'
        return
    }

    Set-Status 'Running selective deploy...' '#f9e2af'
    try {
        $result = Invoke-BlueCatSelectiveDeploy -EntityId ([int]$entityId)
        $txtDeployResult.Text = ($result | ConvertTo-Json -Depth 5)
        Set-Status "Selective deploy initiated for entity $entityId" '#a6e3a1'
    }
    catch {
        $txtDeployResult.Text = "ERROR: $($_.Exception.Message)"
        Set-Status 'Selective deploy failed' '#f38ba8'
    }
})

$btnQuickDeploy.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $zoneId = Get-SelectedZoneId $cboQuickDeployZone
    if (-not $zoneId) { Show-Error 'Error' 'Select a zone.'; return }

    $confirmResult = [System.Windows.MessageBox]::Show(
        "Quick deploy will push ALL pending changes in the selected zone.`nContinue?",
        'Confirm Quick Deploy', 'YesNo', 'Warning'
    )
    if ($confirmResult -ne 'Yes') { return }

    Set-Status 'Running quick deploy...' '#f9e2af'
    try {
        $result = Invoke-BlueCatQuickDeploy -ZoneId $zoneId
        $txtDeployResult.Text = ($result | ConvertTo-Json -Depth 5)
        Set-Status "Quick deploy initiated for zone" '#a6e3a1'
    }
    catch {
        $txtDeployResult.Text = "ERROR: $($_.Exception.Message)"
        Set-Status 'Quick deploy failed' '#f38ba8'
    }
})

$btnCheckDeploy.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $deployId = $txtCheckDeployId.Text.Trim()
    if (-not $deployId -or $deployId -notmatch '^\d+$') {
        Show-Error 'Validation' 'Enter a valid deployment ID.'
        return
    }

    try {
        $result = Get-BlueCatDeploymentStatus -DeploymentId ([int]$deployId)
        $txtDeployResult.Text = ($result | ConvertTo-Json -Depth 5)
        Set-Status "Deployment $deployId status retrieved"
    }
    catch {
        $txtDeployResult.Text = "ERROR: $($_.Exception.Message)"
        Set-Status 'Status check failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Tab changed -> auto-refresh staged items
# ---------------------------------------------------------------------------

$controls['mainTabs'].Add_SelectionChanged({
    $tab = $controls['mainTabs'].SelectedItem
    if ($tab -and $tab.Header -eq 'Staged Items') {
        Refresh-StagedGrid
    }
})

# ---------------------------------------------------------------------------
# Window closing -> cleanup
# ---------------------------------------------------------------------------

$window.Add_Closing({
    try { Disconnect-BlueCat } catch {}
    try { Close-StagingDb } catch {}
})

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

    # Populate schedule time options (every 15 minutes) and set defaults
    $dpScheduleDate.SelectedDate = (Get-Date)
    $cboScheduleTime.Items.Clear()
    for ($h = 1; $h -le 12; $h++) {
        foreach ($m in 0,15,30,45) {
            $t = '{0:00}:{1:00}' -f $h, $m
            $null = $cboScheduleTime.Items.Add($t)
        }
    }
    # Select nearest 15-minute increment for current time (12-hour)
    $now = Get-Date
    $mins = [math]::Round($now.Minute / 15.0) * 15
    if ($mins -eq 60) { $mins = 0; $hour24 = ($now.Hour + 1) % 24 } else { $hour24 = $now.Hour }
    $hour12 = $hour24 % 12
    if ($hour12 -eq 0) { $hour12 = 12 }
    $defaultTime = '{0:00}:{1:00}' -f $hour12, $mins
    $cboScheduleTime.Text = $defaultTime
    # Set AM/PM default
    $ampm = if ($now.Hour -ge 12) { 'PM' } else { 'AM' }
    $cboScheduleAmpm.Text = $ampm

    Refresh-StagedGrid

# ---------------------------------------------------------------------------
# Show window
# ---------------------------------------------------------------------------

$window.ShowDialog() | Out-Null
