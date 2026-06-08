#Requires -Version 5.1
<#
.SYNOPSIS
    BlueCat DNS Manager - Ad-hoc DNS record management GUI
.DESCRIPTION
    WPF GUI for managing DNS records via the BlueCat Address Manager RESTful v2 API.
    Supports creating, modifying, deleting records and deploying them independently
    of the normal scheduled deployment batch.
.NOTES
    Requires: BAM 9.5.0+
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
$logPath = Join-Path $scriptRoot 'logs'
if (-not (Test-Path $dataPath)) { New-Item -Path $dataPath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $logPath)) { New-Item -Path $logPath -ItemType Directory -Force | Out-Null }

Import-Module (Join-Path $modulesPath 'BlueCatApi.psm1') -Force

# ---------------------------------------------------------------------------
# XAML UI Definition
# ---------------------------------------------------------------------------

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="BlueCat DNS Manager"
    Width="1360" Height="820"
    MinWidth="1120" MinHeight="760"
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
                           Foreground="#89b4fa" FontSize="17" FontWeight="Bold"
                           VerticalAlignment="Center" Margin="0,0,14,0"/>
                <WrapPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Label Content="Server:" Margin="0,0,4,0"/>
                    <TextBox x:Name="txtServer" Width="180" Margin="0,0,8,0"/>
                    <Label Content="Config:" Margin="0,0,4,0"/>
                    <ComboBox x:Name="cboConfig" Width="150" Margin="0,0,8,0" DisplayMemberPath="name"/>
                    <StackPanel x:Name="pnlView" Orientation="Horizontal" Visibility="Collapsed">
                        <Label Content="View:" Margin="0,0,4,0"/>
                        <ComboBox x:Name="cboView" Width="95" Margin="0,0,8,0" DisplayMemberPath="name"/>
                    </StackPanel>
                    <Label Content="Zone:" Margin="0,0,4,0"/>
                    <ComboBox x:Name="cboZone" Width="250" Margin="0,0,8,0"
                              IsEditable="True" DisplayMemberPath="absoluteName"/>
                </WrapPanel>
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
                        <GroupBox Header="Existing Records in Selected Zone">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                    <Label Content="Search:"/>
                                    <TextBox x:Name="txtSearchRecords" Width="300"
                                             Margin="0,0,10,0"/>
                                    <Button x:Name="btnSearchRecords" Content="Search Records"/>
                                    <Button x:Name="btnNewRecord" Content="New Record"
                                            Margin="10,0,0,0"
                                            ToolTip="Clears any selected record and prepares the form below for creating a new DNS record."/>
                                    <Button x:Name="btnRecordHelp" Content="?" Width="32" Height="32"
                                            Padding="0" Margin="10,0,0,0"
                                            ToolTip="Create, modify, and record-type help"/>
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
                                <CheckBox x:Name="chkSchedule" Content="Scheduled deploy disabled"
                                          IsEnabled="False" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                <DatePicker x:Name="dpScheduleDate" Width="120" Margin="0,0,6,0" SelectedDateFormat="Short" IsEnabled="False"/>
                                <ComboBox x:Name="cboScheduleTime" Width="80" IsEditable="True" IsEnabled="False"/>
                                <ComboBox x:Name="cboScheduleAmpm" Width="60" Margin="6,0,0,0" IsEnabled="False">
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
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <!-- TAB: Delete Record -->
            <TabItem Header="Delete Record">
                <StackPanel Margin="16">
                    <GroupBox Header="Find Record to Delete">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <Label Content="Search:"/>
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

            <!-- TAB: Logs -->
            <TabItem Header="Logs">
                <StackPanel Margin="16">
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                        <Label Content="Filter:"/>
                        <ComboBox x:Name="cboStagedFilter" Width="150" Margin="0,0,10,0" SelectedIndex="0">
                            <ComboBoxItem Content="All"/>
                            <ComboBoxItem Content="Info"/>
                            <ComboBoxItem Content="Success"/>
                            <ComboBoxItem Content="Warning"/>
                            <ComboBoxItem Content="Error"/>
                        </ComboBox>
                        <Button x:Name="btnRefreshStaged" Content="Refresh Logs"/>
                        <Button x:Name="btnCancelStaged" Content="Clear View"
                                Style="{StaticResource DangerButton}" Margin="10,0,0,0"/>
                        <Button x:Name="btnDeployStaged" Content="Open Log Folder"
                                Style="{StaticResource SuccessButton}" Margin="10,0,0,0"/>
                    </StackPanel>

                    <DataGrid x:Name="dgStaged" AutoGenerateColumns="False"
                              IsReadOnly="True" Height="480"
                              SelectionMode="Single"
                              CanUserSortColumns="True">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Time" Binding="{Binding timestamp}" Width="145"/>
                            <DataGridTextColumn Header="Level" Binding="{Binding level}" Width="75"/>
                            <DataGridTextColumn Header="Action" Binding="{Binding action}" Width="115"/>
                            <DataGridTextColumn Header="Entity" Binding="{Binding entityId}" Width="75"/>
                            <DataGridTextColumn Header="Deployment" Binding="{Binding deploymentId}" Width="90"/>
                            <DataGridTextColumn Header="Record" Binding="{Binding record}" Width="220"/>
                            <DataGridTextColumn Header="Zone" Binding="{Binding zone}" Width="160"/>
                            <DataGridTextColumn Header="Message" Binding="{Binding message}" Width="*"/>
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
                                       Text="Deploys only the specified DNS record entity."/>
                        </StackPanel>
                    </GroupBox>

                    <GroupBox Header="Quick Deploy (entire zone)">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                <Button x:Name="btnQuickDeploy" Content="Quick Deploy Selected Zone"/>
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
                                <Button x:Name="btnRecentDeployments" Content="Recent Deployments" Margin="10,0,0,0"/>
                            </StackPanel>
                            <DataGrid x:Name="dgDeployments" AutoGenerateColumns="False"
                                      IsReadOnly="True" Height="220"
                                      SelectionMode="Single"
                                      CanUserSortColumns="True">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Time" Binding="{Binding time}" Width="145"/>
                                    <DataGridTextColumn Header="ID" Binding="{Binding id}" Width="70"/>
                                    <DataGridTextColumn Header="Type" Binding="{Binding deploymentType}" Width="135"/>
                                    <DataGridTextColumn Header="Name" Binding="{Binding name}" Width="190"/>
                                    <DataGridTextColumn Header="Action" Binding="{Binding action}" Width="105"/>
                                    <DataGridTextColumn Header="State" Binding="{Binding state}" Width="85"/>
                                    <DataGridTextColumn Header="Status" Binding="{Binding status}" Width="85"/>
                                    <DataGridTextColumn Header="Done" Binding="{Binding percentComplete}" Width="60"/>
                                    <DataGridTextColumn Header="User" Binding="{Binding user}" Width="95"/>
                                    <DataGridTextColumn Header="Message" Binding="{Binding message}" Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                            <TextBox x:Name="txtDeployResult" Height="54" Margin="0,8,0,0"
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
$pnlView            = $controls['pnlView']
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
$btnNewRecord       = $controls['btnNewRecord']
$btnRecordHelp      = $controls['btnRecordHelp']
$dgRecords          = $controls['dgRecords']

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
$btnQuickDeploy     = $controls['btnQuickDeploy']
$txtCheckDeployId   = $controls['txtCheckDeployId']
$btnCheckDeploy     = $controls['btnCheckDeploy']
$btnRecentDeployments = $controls['btnRecentDeployments']


$dgDeployments      = $controls['dgDeployments']
$txtDeployResult    = $controls['txtDeployResult']

$workArea = [System.Windows.SystemParameters]::WorkArea
$targetWidth = [math]::Min(1360, [math]::Max(960, [double]$workArea.Width - 40))
$targetHeight = [math]::Min(820, [math]::Max(720, [double]$workArea.Height - 60))
$window.MinWidth = [math]::Min(1120, $targetWidth)
$window.MinHeight = [math]::Min(760, $targetHeight)
$window.Width = $targetWidth
$window.Height = $targetHeight

if ($BamServer) { $txtServer.Text = $BamServer }

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:IsConnected = $false
$script:ZoneCache = @()
$script:ActivityLogFile = Join-Path $logPath "bluecat-dns-manager-$(Get-Date -Format 'yyyyMMdd').jsonl"
$script:SuppressRecordSelectionFill = $false

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

function Get-ExceptionMessage {
    param($ErrorRecord)

    $messages = New-Object System.Collections.ArrayList
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        [void]$messages.Add($ErrorRecord.ErrorDetails.Message)
    }
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        [void]$messages.Add($ErrorRecord.Exception.Message)
    }

    $webException = $ErrorRecord.Exception
    if ($webException -and $webException.Response) {
        try {
            $stream = $webException.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Dispose()
                if ($responseBody) { [void]$messages.Add($responseBody) }
            }
        }
        catch {}
    }

    if ($messages.Count -eq 0) { return 'Unknown error' }
    return (($messages | Select-Object -Unique) -join "`n")
}

function Write-AppLog {
    param(
        [ValidateSet('INFO','SUCCESS','WARNING','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Details = @{}
    )

    $deploymentId = ''
    if ($Details.ContainsKey('DeploymentId') -and $null -ne $Details['DeploymentId']) {
        $deploymentId = $Details['DeploymentId']
    }
    elseif ($Details.ContainsKey('Deployment') -and $null -ne $Details['Deployment']) {
        $deploymentId = Get-DeploymentIdFromResponse -Response $Details['Deployment']
    }

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        level     = $Level
        action    = $Action
        message   = $Message
        user      = if ($script:IsConnected) { Get-BlueCatCurrentUser } else { [Environment]::UserName }
        server    = $txtServer.Text.Trim()
        entityId  = if ($Details.ContainsKey('EntityId')) { $Details['EntityId'] } else { '' }
        deploymentId = $deploymentId
        record    = if ($Details.ContainsKey('Record')) { $Details['Record'] } else { '' }
        zone      = if ($Details.ContainsKey('Zone')) { $Details['Zone'] } else { '' }
        value     = if ($Details.ContainsKey('Value')) { $Details['Value'] } else { '' }
        details   = $Details
    }

    try {
        ($entry | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Path $script:ActivityLogFile -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to write activity log: $($_.Exception.Message)"
    }
}

function Refresh-LogGrid {
    $filterText = ($cboStagedFilter.SelectedItem.Content).ToString().ToUpper()
    $rows = New-Object System.Collections.ArrayList
    $files = Get-ChildItem -Path $logPath -Filter 'bluecat-dns-manager-*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10

    foreach ($file in $files) {
        $lines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue | Select-Object -Last 300
        foreach ($line in $lines) {
            if (-not $line) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($filterText -ne 'ALL' -and $entry.level -ne $filterText) { continue }
                [void]$rows.Add($entry)
            }
            catch {}
        }
    }

    $dgStaged.ItemsSource = @($rows | Sort-Object timestamp -Descending)
}

function Populate-ZoneCombos {
    $topZones = Get-BlueCatZones
    $allZones = New-Object System.Collections.ArrayList
    $seenZoneIds = @{}

    Add-ZonesRecursive -Zones $topZones -Accumulator $allZones -SeenIds $seenZoneIds
    $script:ZoneCache = @($allZones | Sort-Object absoluteName)

    $cboZone.ItemsSource = $script:ZoneCache
    if ($script:ZoneCache.Count -gt 0) {
        $cboZone.SelectedIndex = 0
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

function Get-DeploymentIdFromResponse {
    param([object]$Response)

    if (-not $Response) { return $null }

    foreach ($propertyName in @('id','deploymentId','deploymentID','taskId','deploymentTaskId')) {
        $property = $Response.PSObject.Properties[$propertyName]
        if ($property -and $property.Value -match '^\d+$') {
            return [int]$property.Value
        }
    }

    if ($Response.data) {
        return Get-DeploymentIdFromResponse -Response $Response.data
    }

    return $null
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

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string[]]$Names
    )

    if ($null -eq $InputObject) { return $null }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and $property.Value.ToString() -ne '') {
            return $property.Value
        }
    }
    return $null
}

function Get-RelativeRecordName {
    param(
        [string]$AbsoluteName,
        [string]$ZoneName
    )

    if (-not $AbsoluteName) { return '' }
    if (-not $ZoneName) { return $AbsoluteName }

    if ([string]::Equals($AbsoluteName, $ZoneName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '@'
    }

    $suffix = ".$ZoneName"
    if ($AbsoluteName.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $AbsoluteName.Substring(0, $AbsoluteName.Length - $suffix.Length)
    }

    return $AbsoluteName
}

function Set-RecordTypeSelection {
    param([string]$ApiType)

    $displayName = Get-BlueCatRecordTypeDisplayName $ApiType
    for ($i = 0; $i -lt $cboRecordType.Items.Count; $i++) {
        $item = $cboRecordType.Items[$i]
        if ($item.Content -and $item.Content.ToString() -eq $displayName) {
            $cboRecordType.SelectedIndex = $i
            return
        }
    }
}

function Clear-RecordForm {
    param([string]$StatusMessage)

    $script:SuppressRecordSelectionFill = $true
    try {
        $dgRecords.SelectedItem = $null
        $dgRecords.SelectedIndex = -1
    }
    finally {
        $script:SuppressRecordSelectionFill = $false
    }

    $cboRecordType.SelectedIndex = 0
    $txtTTL.Text = '300'
    $txtRecordName.Text = ''
    $txtRecordValue.Text = ''
    $txtComment.Text = ''
    $chkReverse.IsChecked = $false
    $btnModifyRecord.IsEnabled = $false

    if ($StatusMessage) {
        Set-Status $StatusMessage
    }
}

function Update-RecordFormFromSelection {
    param($SelectedRecord)

    if (-not $SelectedRecord) {
        $btnModifyRecord.IsEnabled = $false
        return
    }

    $selectedZone = Get-SelectedZone $cboZone
    $zoneName = if ($selectedZone) { $selectedZone.absoluteName } else { '' }

    Set-RecordTypeSelection -ApiType $SelectedRecord.type
    $txtRecordName.Text = Get-RelativeRecordName -AbsoluteName $SelectedRecord.absoluteName -ZoneName $zoneName
    $txtRecordValue.Text = $SelectedRecord.rdata
    $txtTTL.Text = if ($SelectedRecord.ttl) { $SelectedRecord.ttl.ToString() } else { '300' }
    $btnModifyRecord.IsEnabled = $true

    if ($SelectedRecord.id) {
        $txtDeployEntityId.Text = $SelectedRecord.id.ToString()
    }
}

function Get-DeploymentObjects {
    param([object]$InputObject)

    if ($null -eq $InputObject) { return @() }

    $dataProperty = $InputObject.PSObject.Properties['data']
    if ($dataProperty) {
        return Get-DeploymentObjects -InputObject $dataProperty.Value
    }

    if ($InputObject -is [System.Array]) {
        return @($InputObject)
    }

    return ,$InputObject
}

function Get-DeploymentDateValue {
    param($Deployment)

    return Get-ObjectPropertyValue -InputObject $Deployment -Names @(
        'creationDateTime',
        'startDateTime',
        'completionDateTime',
        'createdAt',
        'timestamp',
        'time'
    )
}

function Format-DeploymentDateValue {
    param($Value)

    if ($null -eq $Value -or $Value.ToString() -eq '') { return '' }
    try {
        return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        return $Value.ToString()
    }
}

function Get-DeploymentSortDate {
    param($Deployment)

    $value = Get-DeploymentDateValue -Deployment $Deployment
    if ($null -eq $value -or $value.ToString() -eq '') { return [datetime]::MinValue }
    try {
        return [datetime]$value
    }
    catch {
        return [datetime]::MinValue
    }
}

function Get-DeploymentUserName {
    param($Deployment)

    $user = Get-ObjectPropertyValue -InputObject $Deployment -Names @('user','createdBy','owner')
    if ($null -eq $user) { return '' }

    $name = Get-ObjectPropertyValue -InputObject $user -Names @('name','username','userName')
    if ($name) { return $name.ToString() }

    return $user.ToString()
}

function Get-DeploymentDisplayName {
    param($Deployment)

    $name = Get-ObjectPropertyValue -InputObject $Deployment -Names @(
        'name',
        'absoluteName',
        'entityName',
        'resourceName',
        'serverName'
    )
    if ($name) { return $name.ToString() }

    $message = Get-ObjectPropertyValue -InputObject $Deployment -Names @('message','description')
    if (-not $message) { return '' }

    $text = $message.ToString()
    if ($text -match '[#!]\s*(?<target>[^:]+?)(?:\s+(?:DNS|DHCPV4|DHCPV6|DHCP)\s+deployment|:|$)') {
        return $matches['target'].Trim()
    }

    return ''
}

function ConvertTo-DeploymentRows {
    param([object]$InputObject)

    $rows = New-Object System.Collections.ArrayList
    foreach ($deployment in @(Get-DeploymentObjects -InputObject $InputObject)) {
        if (-not $deployment) { continue }

        $method = Get-ObjectPropertyValue -InputObject $deployment -Names @('method','action')
        $service = Get-ObjectPropertyValue -InputObject $deployment -Names @('service')
        $actionParts = @($method, $service) | Where-Object {
            $null -ne $_ -and $_.ToString().Trim() -ne ''
        }
        $percentValue = Get-ObjectPropertyValue -InputObject $deployment -Names @('percentComplete','completionPercentage')
        $percentText = ''
        if ($null -ne $percentValue -and $percentValue.ToString() -ne '') {
            $percentText = if ($percentValue.ToString().EndsWith('%')) {
                $percentValue.ToString()
            } else {
                "$percentValue%"
            }
        }

        $dateValue = Get-DeploymentDateValue -Deployment $deployment
        [void]$rows.Add([PSCustomObject]@{
            time            = Format-DeploymentDateValue -Value $dateValue
            id              = (Get-ObjectPropertyValue -InputObject $deployment -Names @('id','deploymentId','deploymentID','taskId'))
            deploymentType  = (Get-ObjectPropertyValue -InputObject $deployment -Names @('type','deploymentType'))
            name            = Get-DeploymentDisplayName -Deployment $deployment
            action          = (($actionParts | ForEach-Object { $_.ToString() }) -join ' ')
            state           = (Get-ObjectPropertyValue -InputObject $deployment -Names @('state'))
            status          = (Get-ObjectPropertyValue -InputObject $deployment -Names @('status'))
            percentComplete = $percentText
            user            = Get-DeploymentUserName -Deployment $deployment
            message         = (Get-ObjectPropertyValue -InputObject $deployment -Names @('message','description'))
            sortDate        = Get-DeploymentSortDate -Deployment $deployment
        })
    }

    return @($rows | Sort-Object sortDate -Descending)
}

function Set-DeploymentResults {
    param(
        [object]$InputObject,
        [string]$Summary
    )

    $rows = @(ConvertTo-DeploymentRows -InputObject $InputObject)
    $dgDeployments.ItemsSource = $rows
    if ($rows.Count -gt 0) {
        $dgDeployments.SelectedIndex = 0
    }

    if ($Summary) {
        $txtDeployResult.Text = $Summary
    }
    elseif ($rows.Count -gt 0) {
        $txtDeployResult.Text = $rows[0].message
    }
    else {
        $txtDeployResult.Text = 'No deployment records returned.'
    }

    return $rows
}

function Set-DeploymentError {
    param([string]$Message)

    $dgDeployments.ItemsSource = @()
    $txtDeployResult.Text = "ERROR: $Message"
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
        $views = @(Get-BlueCatViews -ConfigurationId $sel.id)
        $cboView.ItemsSource = $views
        if ($views.Count -le 1) {
            $pnlView.Visibility = [System.Windows.Visibility]::Collapsed
        }
        else {
            $pnlView.Visibility = [System.Windows.Visibility]::Visible
        }
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

$cboZone.Add_SelectionChanged({
    if ($script:SuppressRecordSelectionFill) { return }

    $dgRecords.ItemsSource = @()
    $dgDeleteRecords.ItemsSource = @()
    Clear-RecordForm
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

$dgRecords.Add_SelectionChanged({
    if ($script:SuppressRecordSelectionFill) { return }

    Update-RecordFormFromSelection -SelectedRecord $dgRecords.SelectedItem
})

$btnNewRecord.Add_Click({
    Clear-RecordForm -StatusMessage 'Ready to create a new record'
})

$btnRecordHelp.Add_Click({
    $helpText = @"
Create / Modify quick guide

New Record: clears any selected existing record and resets Record Details for a new create action. It does not save anything until you click Create Record.

A / Host Record: choose A / Host Record, enter the host name, enter the IPv4 address in Value / Target, then click Create Record. Enable Create reverse (PTR) record only when a PTR should also be created.

CNAME: search for and select the existing target record first. Keep Value / Target set to that target FQDN, change Record Type to CNAME, enter the alias name in Record Name, then click Create Record.

MX: enter the mail record name, then use "priority target" in Value / Target, for example "10 mail.example.com".

TXT: enter the record name, then enter the TXT value in Value / Target.

SRV: use "priority weight port target" in Value / Target, for example "10 5 443 server.example.com".

Generic: enter the record name and raw record data in Value / Target.

Modify: search the selected zone, select the existing record, update Value / Target, TTL, or comment, then click Modify Selected Record.
"@
    Show-Info 'Create / Modify Help' $helpText
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
        Show-Error 'Scheduling Disabled' 'Scheduled deployments were disabled when SQLite staging was removed. Create the record without scheduling, then deploy from the Deploy Tools tab when ready.'
        return
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

        Write-AppLog -Level SUCCESS -Action 'CreateRecord' -Message "Created $recType '$recName' in $zoneName" -Details @{
            EntityId = $entityId
            Record   = $recName
            Zone     = $zoneName
            Value    = $recValue
            Type     = $recType
            TTL      = $ttl
            Comment  = $comment
        }

        if ($deployMode -eq 'immediate') {
            Set-Status 'Deploying record...' '#f9e2af'
            try {
                $deployment = Invoke-BlueCatSelectiveDeploy -EntityId $entityId
                $deploymentId = Get-DeploymentIdFromResponse -Response $deployment
                if ($deploymentId) {
                    $txtCheckDeployId.Text = $deploymentId.ToString()
                }
                Write-AppLog -Level SUCCESS -Action 'SelectiveDeploy' -Message "Selective deploy submitted for entity $entityId" -Details @{
                    EntityId   = $entityId
                    Record     = $recName
                    Zone       = $zoneName
                    DeploymentId = $deploymentId
                    Deployment = $deployment
                }
                Set-Status "Record created and deployed (Entity: $entityId)" '#a6e3a1'
            }
            catch {
                $errMsg = Get-ExceptionMessage $_
                Write-AppLog -Level ERROR -Action 'SelectiveDeploy' -Message $errMsg -Details @{
                    EntityId = $entityId
                    Record   = $recName
                    Zone     = $zoneName
                }
                Show-Error 'Deploy Failed' "Record was created (ID: $entityId) but deployment failed:`n$errMsg"
                Set-Status 'Record created but deploy failed' '#f38ba8'
            }
        }
        else {
            Set-Status "Record created (Entity: $entityId) - not deployed" '#f9e2af'
        }

        Clear-RecordForm
    }
    catch {
        $errMsg = Get-ExceptionMessage $_
        Write-AppLog -Level ERROR -Action 'CreateRecord' -Message $errMsg -Details @{
            Record = $recName
            Zone   = $zoneName
            Value  = $recValue
            Type   = $recType
        }
        Show-Error 'Create Failed' $errMsg
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

        Write-AppLog -Level SUCCESS -Action 'ModifyRecord' -Message "Modified '$($selected.absoluteName)'" -Details @{
            EntityId = [int]$selected.id
            Record   = $selected.absoluteName
            Zone     = $zoneName
            Value    = $recValue
            Type     = $selected.type
            TTL      = $ttl
            Comment  = $comment
        }

        if ($deployMode -eq 'immediate') {
            Set-Status 'Deploying modified record...' '#f9e2af'
            try {
                $deployment = Invoke-BlueCatSelectiveDeploy -EntityId ([int]$selected.id)
                $deploymentId = Get-DeploymentIdFromResponse -Response $deployment
                if ($deploymentId) {
                    $txtCheckDeployId.Text = $deploymentId.ToString()
                }
                Write-AppLog -Level SUCCESS -Action 'SelectiveDeploy' -Message "Selective deploy submitted for entity $($selected.id)" -Details @{
                    EntityId   = [int]$selected.id
                    Record     = $selected.absoluteName
                    Zone       = $zoneName
                    DeploymentId = $deploymentId
                    Deployment = $deployment
                }
                Set-Status "Record modified and deployed" '#a6e3a1'
            }
            catch {
                $errMsg = Get-ExceptionMessage $_
                Write-AppLog -Level ERROR -Action 'SelectiveDeploy' -Message $errMsg -Details @{
                    EntityId = [int]$selected.id
                    Record   = $selected.absoluteName
                    Zone     = $zoneName
                }
                Show-Error 'Deploy Failed' "Record modified but deployment failed:`n$errMsg"
                Set-Status 'Record modified but deploy failed' '#f38ba8'
            }
        }
        else {
            Set-Status "Record modified (not deployed)"
        }
    }
    catch {
        $errMsg = Get-ExceptionMessage $_
        Write-AppLog -Level ERROR -Action 'ModifyRecord' -Message $errMsg -Details @{
            EntityId = [int]$selected.id
            Record   = $selected.absoluteName
            Zone     = $zoneName
            Value    = $recValue
        }
        Show-Error 'Modify Failed' $errMsg
        Set-Status 'Modify failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Delete tab - Search
# ---------------------------------------------------------------------------

$btnDeleteSearch.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $zoneId = Get-SelectedZoneId $cboZone
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
    $selectedZone = Get-SelectedZone $cboZone
    $zoneName = $selectedZone.absoluteName
    $deployNow = $chkDeleteDeploy.IsChecked
    $entityId = [int]$selected.id

    Set-Status 'Deleting record...' '#f9e2af'

    try {
        Remove-BlueCatResourceRecord -Id $entityId -Comment $comment

        Write-AppLog -Level SUCCESS -Action 'DeleteRecord' -Message "Deleted '$($selected.absoluteName)'" -Details @{
            EntityId = $entityId
            Record   = $selected.absoluteName
            Zone     = $zoneName
            Value    = $selected.rdata
            Type     = $selected.type
            Comment  = $comment
        }

        if ($deployNow) {
            Set-Status 'Deploying deletion...' '#f9e2af'
            try {
                # After delete, deploy via quick deploy on the zone since entity no longer exists
                $zoneId = Get-SelectedZoneId $cboZone
                $deployment = Invoke-BlueCatQuickDeploy -ZoneId $zoneId
                $deploymentId = Get-DeploymentIdFromResponse -Response $deployment
                if ($deploymentId) {
                    $txtCheckDeployId.Text = $deploymentId.ToString()
                }
                Write-AppLog -Level SUCCESS -Action 'QuickDeploy' -Message "Quick deploy submitted for zone $zoneName" -Details @{
                    EntityId   = $entityId
                    Record     = $selected.absoluteName
                    Zone       = $zoneName
                    DeploymentId = $deploymentId
                    Deployment = $deployment
                }
                Set-Status "Record deleted and zone deployed" '#a6e3a1'
            }
            catch {
                # Try selective deploy as fallback
                try {
                    $deployment = Invoke-BlueCatSelectiveDeploy -EntityId $entityId
                    $deploymentId = Get-DeploymentIdFromResponse -Response $deployment
                    if ($deploymentId) {
                        $txtCheckDeployId.Text = $deploymentId.ToString()
                    }
                    Write-AppLog -Level SUCCESS -Action 'SelectiveDeploy' -Message "Selective deploy submitted for deleted entity $entityId" -Details @{
                        EntityId   = $entityId
                        Record     = $selected.absoluteName
                        Zone       = $zoneName
                        DeploymentId = $deploymentId
                        Deployment = $deployment
                    }
                    Set-Status "Record deleted and deployed" '#a6e3a1'
                }
                catch {
                    $errMsg = Get-ExceptionMessage $_
                    Write-AppLog -Level ERROR -Action 'DeployDeletedRecord' -Message $errMsg -Details @{
                        EntityId = $entityId
                        Record   = $selected.absoluteName
                        Zone     = $zoneName
                    }
                    Show-Error 'Deploy Failed' "Record deleted but deployment failed:`n$errMsg"
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
        $errMsg = Get-ExceptionMessage $_
        Write-AppLog -Level ERROR -Action 'DeleteRecord' -Message $errMsg -Details @{
            EntityId = $entityId
            Record   = $selected.absoluteName
            Zone     = $zoneName
        }
        Show-Error 'Delete Failed' $errMsg
        Set-Status 'Delete failed' '#f38ba8'
    }
})

# ---------------------------------------------------------------------------
# Event: Logs tab
# ---------------------------------------------------------------------------

$btnRefreshStaged.Add_Click({
    Refresh-LogGrid
    Set-Status 'Logs refreshed'
})

$btnCancelStaged.Add_Click({
    $dgStaged.ItemsSource = @()
    Set-Status 'Log view cleared'
})

$btnDeployStaged.Add_Click({
    try {
        [System.Diagnostics.Process]::Start('explorer.exe', $logPath) | Out-Null
        Set-Status "Opened log folder: $logPath"
    }
    catch {
        Show-Error 'Open Log Folder Failed' $_.Exception.Message
    }
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

    $scope = 'specific'

    Set-Status 'Running selective deploy...' '#f9e2af'
    try {
        $result = Invoke-BlueCatSelectiveDeploy -EntityId ([int]$entityId) -Scope $scope
        $deploymentId = Get-DeploymentIdFromResponse -Response $result
        if ($deploymentId) {
            $txtCheckDeployId.Text = $deploymentId.ToString()
        }
        if ($deploymentId) {
            [void](Set-DeploymentResults -InputObject $result -Summary "Selective deploy submitted for entity $entityId. Deployment ID: $deploymentId")
        } else {
            [void](Set-DeploymentResults -InputObject $result -Summary "Selective deploy submitted for entity $entityId. No deployment ID was detected in the response.")
        }
        Write-AppLog -Level SUCCESS -Action 'SelectiveDeploy' -Message "Selective deploy submitted for entity $entityId" -Details @{
            EntityId   = [int]$entityId
            Scope      = $scope
            DeploymentId = $deploymentId
            Deployment = $result
        }
        if ($deploymentId) {
            Set-Status "Selective deploy submitted for entity $entityId (deployment $deploymentId)" '#a6e3a1'
        } else {
            Set-Status "Selective deploy submitted for entity $entityId" '#a6e3a1'
        }
    }
    catch {
        $errMsg = Get-ExceptionMessage $_
        Set-DeploymentError -Message $errMsg
        Write-AppLog -Level ERROR -Action 'SelectiveDeploy' -Message $errMsg -Details @{
            EntityId = [int]$entityId
            Scope    = $scope
        }
        Set-Status 'Selective deploy failed' '#f38ba8'
    }
})

$btnQuickDeploy.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    $zoneId = Get-SelectedZoneId $cboZone
    if (-not $zoneId) { Show-Error 'Error' 'Select a zone.'; return }

    $confirmResult = [System.Windows.MessageBox]::Show(
        "Quick deploy will push ALL pending changes in the selected zone.`nContinue?",
        'Confirm Quick Deploy', 'YesNo', 'Warning'
    )
    if ($confirmResult -ne 'Yes') { return }

    Set-Status 'Running quick deploy...' '#f9e2af'
    try {
        $result = Invoke-BlueCatQuickDeploy -ZoneId $zoneId
        $deploymentId = Get-DeploymentIdFromResponse -Response $result
        if ($deploymentId) {
            $txtCheckDeployId.Text = $deploymentId.ToString()
        }
        $selectedZone = Get-SelectedZone $cboZone
        if ($deploymentId) {
            [void](Set-DeploymentResults -InputObject $result -Summary "Quick deploy submitted for zone $($selectedZone.absoluteName). Deployment ID: $deploymentId")
        } else {
            [void](Set-DeploymentResults -InputObject $result -Summary "Quick deploy submitted for zone $($selectedZone.absoluteName). No deployment ID was detected in the response.")
        }
        Write-AppLog -Level SUCCESS -Action 'QuickDeploy' -Message "Quick deploy submitted for zone $($selectedZone.absoluteName)" -Details @{
            Zone       = $selectedZone.absoluteName
            DeploymentId = $deploymentId
            Deployment = $result
        }
        if ($deploymentId) {
            Set-Status "Quick deploy submitted for zone (deployment $deploymentId)" '#a6e3a1'
        } else {
            Set-Status "Quick deploy submitted for zone" '#a6e3a1'
        }
    }
    catch {
        $errMsg = Get-ExceptionMessage $_
        Set-DeploymentError -Message $errMsg
        Write-AppLog -Level ERROR -Action 'QuickDeploy' -Message $errMsg -Details @{
            ZoneId = $zoneId
        }
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
        [void](Set-DeploymentResults -InputObject $result -Summary "Deployment $deployId status retrieved.")
        Write-AppLog -Level INFO -Action 'DeploymentStatus' -Message "Retrieved status for deployment $deployId" -Details @{
            DeploymentId = [int]$deployId
            Response = $result
        }
        Set-Status "Deployment $deployId status retrieved"
    }
    catch {
        $errMsg = Get-ExceptionMessage $_
        Set-DeploymentError -Message "Checking deployment ID ${deployId}: $errMsg. This usually means the value is not a deployment/task ID. Use the ID returned in the selective or quick deploy response, not the DNS record/entity ID."
        Write-AppLog -Level ERROR -Action 'DeploymentStatus' -Message $errMsg -Details @{
            DeploymentId = [int]$deployId
        }
        Set-Status 'Status check failed' '#f38ba8'
    }
})

$btnRecentDeployments.Add_Click({
    if (-not $script:IsConnected) { Show-Error 'Error' 'Not connected.'; return }

    Set-Status 'Loading recent deployments...' '#f9e2af'
    try {
        $result = Get-BlueCatDeployments -Limit 20
        $rows = Set-DeploymentResults -InputObject $result -Summary 'Recent deployments loaded. Rows are sorted newest first.'
        if ($rows.Count -gt 0 -and $rows[0].id) {
            $txtCheckDeployId.Text = $rows[0].id.ToString()
        }
        Write-AppLog -Level INFO -Action 'RecentDeployments' -Message 'Retrieved recent deployments' -Details @{
            Deployment = $result
        }
        Set-Status 'Recent deployments loaded' '#a6e3a1'
    }
    catch {
        $errMsg = Get-ExceptionMessage $_
        Set-DeploymentError -Message "Loading recent deployments: $errMsg"
        Write-AppLog -Level ERROR -Action 'RecentDeployments' -Message $errMsg
        Set-Status 'Recent deployments failed' '#f38ba8'
    }
})

$dgDeployments.Add_SelectionChanged({
    $selected = $dgDeployments.SelectedItem
    if ($selected -and $selected.message) {
        $txtDeployResult.Text = $selected.message.ToString()
    }
})

# ---------------------------------------------------------------------------
# Tab changed -> auto-refresh logs
# ---------------------------------------------------------------------------

$controls['mainTabs'].Add_SelectionChanged({
    $tab = $controls['mainTabs'].SelectedItem
    if ($tab -and $tab.Header -eq 'Logs') {
        Refresh-LogGrid
    }
})

# ---------------------------------------------------------------------------
# Window closing -> cleanup
# ---------------------------------------------------------------------------

$window.Add_Closing({
    try { Disconnect-BlueCat } catch {}
})

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

    $btnModifyRecord.IsEnabled = $false
    $dgDeployments.ItemsSource = @()

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

    Refresh-LogGrid

# ---------------------------------------------------------------------------
# Show window
# ---------------------------------------------------------------------------

$window.ShowDialog() | Out-Null
