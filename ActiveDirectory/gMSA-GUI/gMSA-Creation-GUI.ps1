Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="gMSA Creation Utility"
        Height="860"
        Width="1120"
        MinHeight="640"
        MinWidth="820"
        WindowStartupLocation="CenterScreen"
        Background="#17191F"
        Foreground="#F3F5F7"
        FontFamily="Segoe UI"
        ResizeMode="CanResize">
    <Window.Resources>
        <SolidColorBrush x:Key="WindowBrush" Color="#17191F" />
        <SolidColorBrush x:Key="PanelBrush" Color="#20242C" />
        <SolidColorBrush x:Key="PanelAltBrush" Color="#262C36" />
        <SolidColorBrush x:Key="BorderBrush" Color="#3A4250" />
        <SolidColorBrush x:Key="AccentBrush" Color="#3FA9F5" />
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#6CBDF8" />
        <SolidColorBrush x:Key="TextBrush" Color="#F3F5F7" />
        <SolidColorBrush x:Key="MutedTextBrush" Color="#AEB7C4" />
        <SolidColorBrush x:Key="InputBrush" Color="#111318" />
        <SolidColorBrush x:Key="SplitterBrush" Color="#3A4250" />
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Margin" Value="0,0,0,6" />
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource InputBrush}" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="8,6" />
            <Setter Property="Margin" Value="0,0,0,12" />
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="Margin" Value="0,6,0,12" />
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="Margin" Value="0,0,16,8" />
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="{StaticResource InputBrush}" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="FontFamily" Value="Consolas" />
            <Setter Property="SelectionMode" Value="Extended" />
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Padding" Value="14,8" />
            <Setter Property="Margin" Value="0,0,10,0" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Cursor" Value="Hand" />
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="Margin" Value="0,0,0,14" />
            <Setter Property="Padding" Value="12" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Background" Value="{StaticResource PanelBrush}" />
        </Style>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="{StaticResource WindowBrush}" />
            <Setter Property="BorderThickness" Value="0" />
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="{StaticResource PanelAltBrush}" />
            <Setter Property="Foreground" Value="#D8E0EA" />
            <Setter Property="Padding" Value="18,8" />
            <Setter Property="Margin" Value="0,0,8,0" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#CBD5E1" />
                    <Setter Property="Foreground" Value="#18212B" />
                    <Setter Property="BorderBrush" Value="#CBD5E1" />
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#344052" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SplitterStyle" TargetType="GridSplitter">
            <Setter Property="Background" Value="{StaticResource SplitterBrush}" />
            <Setter Property="Cursor" Value="SizeWE" />
            <Setter Property="Width" Value="5" />
            <Setter Property="HorizontalAlignment" Value="Stretch" />
            <Setter Property="VerticalAlignment" Value="Stretch" />
            <Setter Property="Margin" Value="0" />
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <TabControl Name="MainTabControl">
            <TabItem Header="Create gMSA">
                <Grid Background="#17191F">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0"
                            Background="#20242C"
                            CornerRadius="8"
                            Padding="16"
                            Margin="0,0,0,14"
                            BorderBrush="#3A4250"
                            BorderThickness="1">
                        <TextBlock TextWrapping="Wrap"
                                   Foreground="#AEB7C4"
                                   FontSize="13"
                                   Text="Enter the target domain, the short gMSA name, and one server, service account, or group per line. Preview builds the exact PowerShell steps first, then Execute runs them only after confirmation." />
                    </Border>
                    <Grid Grid.Row="1">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="320" MinWidth="240" />
                            <ColumnDefinition Width="5" />
                            <ColumnDefinition Width="*" MinWidth="360" />
                        </Grid.ColumnDefinitions>

                        <!-- Resizable splitter between left and right panels -->
                        <GridSplitter Grid.Column="1"
                                      Style="{StaticResource SplitterStyle}"
                                      ResizeBehavior="PreviousAndNext"
                                      ResizeDirection="Columns"
                                      ShowsPreview="False"
                                      ToolTip="Drag to resize panels" />

                        <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <GroupBox Header="Inputs">
                                    <StackPanel>
                                        <Label Content="Domain / AD Server" />
                                        <TextBox Name="DomainTextBox"
                                                 ToolTip="Example: domain.com" />
                                        <Label Content="gMSA Short Name" />
                                        <TextBox Name="ServiceNameTextBox"
                                                 ToolTip="Example: gMSA-sqlp100z (do not include trailing $)" />
                                        <Label Content="Allowed Principals (one per line)" />
                                        <TextBox Name="ServersTextBox"
                                                 AcceptsReturn="True"
                                                 VerticalScrollBarVisibility="Auto"
                                                 Height="160"
                                                 TextWrapping="Wrap"
                                                 ToolTip="Servers, service accounts, or groups by sAMAccountName or DN.&#x0a;Example: sqlserver01a&#x0a;svc-sqlagent" />
                                        <CheckBox Name="DelegationCheckBox"
                                                  Content="Enable unconstrained delegation after creation" />
                                    </StackPanel>
                                </GroupBox>
                                <GroupBox Header="Actions">
                                    <StackPanel>
                                        <WrapPanel Margin="0,0,0,8">
                                            <Button Name="PreviewButton" Content="Preview Command" Padding="14,8" Margin="0,0,10,6" />
                                            <Button Name="ExecuteButton" Content="Execute" Padding="14,8" Margin="0,0,10,6" IsEnabled="False" />
                                            <Button Name="ResetButton" Content="Reset Form" Padding="14,8" Margin="0,0,0,6" />
                                        </WrapPanel>
                                        <TextBlock Foreground="#AEB7C4"
                                                   TextWrapping="Wrap"
                                                   Text="Execute stays disabled until a fresh preview is generated from the current field values." />
                                    </StackPanel>
                                </GroupBox>
                            </StackPanel>
                        </ScrollViewer>

                        <Grid Grid.Column="2">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*" MinHeight="120" />
                                <RowDefinition Height="5" />
                                <RowDefinition Height="*" MinHeight="120" />
                            </Grid.RowDefinitions>

                            <!-- Vertical splitter between Preview and Lookup panels -->
                            <GridSplitter Grid.Row="1"
                                          Height="5"
                                          HorizontalAlignment="Stretch"
                                          VerticalAlignment="Stretch"
                                          Background="#3A4250"
                                          Cursor="SizeNS"
                                          ResizeBehavior="PreviousAndNext"
                                          ResizeDirection="Rows"
                                          ShowsPreview="False"
                                          ToolTip="Drag to resize Preview / Lookup panels" />

                            <GroupBox Header="Preview" Grid.Row="0">
                                <TextBox Name="PreviewTextBox"
                                         IsReadOnly="True"
                                         AcceptsReturn="True"
                                         VerticalScrollBarVisibility="Auto"
                                         HorizontalScrollBarVisibility="Auto"
                                         TextWrapping="NoWrap"
                                         FontFamily="Consolas" />
                            </GroupBox>
                            <GroupBox Header="Managed Password Retrieval Lookup" Grid.Row="2">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto" />
                                        <RowDefinition Height="*" />
                                    </Grid.RowDefinitions>
                                    <DockPanel Margin="0,0,0,10" LastChildFill="True">
                                        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                                            <Button Name="LookupButton" Content="Run Lookup" Padding="14,8" Margin="0,0,10,0" />
                                            <Button Name="ClearLookupButton" Content="Clear Output" Padding="14,8" Margin="0,0,0,0" />
                                        </StackPanel>
                                        <TextBlock VerticalAlignment="Center"
                                                   Foreground="#AEB7C4"
                                                   Margin="12,0,0,0"
                                                   Text="Uses the current Domain and gMSA Short Name fields." />
                                    </DockPanel>
                                    <TextBox Name="LookupOutputTextBox"
                                             Grid.Row="1"
                                             IsReadOnly="True"
                                             AcceptsReturn="True"
                                             VerticalScrollBarVisibility="Auto"
                                             HorizontalScrollBarVisibility="Auto"
                                             TextWrapping="NoWrap"
                                             FontFamily="Consolas" />
                                </Grid>
                            </GroupBox>
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Manage gMSA">
                <Grid Background="#17191F">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0"
                            Background="#20242C"
                            CornerRadius="8"
                            Padding="16,16,16,12"
                            Margin="0,0,0,14"
                            BorderBrush="#3A4250"
                            BorderThickness="1">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="Auto" />
                            </Grid.RowDefinitions>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="12" />
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="12" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0">
                                <Label Content="Domain / AD Server" />
                                <TextBox Name="ManageDomainTextBox"
                                         ToolTip="Example: domain.com" />
                            </StackPanel>
                            <StackPanel Grid.Column="2">
                                <Label Content="gMSA Short Name" />
                                <TextBox Name="ManageServiceNameTextBox"
                                         ToolTip="Example: gMSA-sqlp100z (do not include trailing $)" />
                            </StackPanel>
                            <Button Name="ManageLoadButton"
                                    Grid.Column="4"
                                    Content="Load gMSA"
                                    VerticalAlignment="Bottom"
                                    Margin="0,0,0,12" />
                            <TextBlock Name="ManageStatusTextBlock"
                                       Grid.Row="1"
                                       Grid.ColumnSpan="5"
                                       Foreground="#AEB7C4"
                                       TextWrapping="Wrap" />
                        </Grid>
                    </Border>
                    <Grid Grid.Row="1">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" MinWidth="300" />
                            <ColumnDefinition Width="5" />
                            <ColumnDefinition Width="*" MinWidth="300" />
                        </Grid.ColumnDefinitions>

                        <GridSplitter Grid.Column="1"
                                      Style="{StaticResource SplitterStyle}"
                                      ResizeBehavior="PreviousAndNext"
                                      ResizeDirection="Columns"
                                      ShowsPreview="False"
                                      ToolTip="Drag to resize panels" />

                        <GroupBox Header="Allowed Principals (can retrieve the password)" Grid.Column="0" Margin="0,0,10,0">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="*" MinHeight="80" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                </Grid.RowDefinitions>
                                <ListBox Name="ManagePrincipalsListBox"
                                         Grid.Row="0"
                                         ToolTip="Ctrl+click or Shift+click to select several entries." />
                                <Button Name="ManageRemovePrincipalButton"
                                        Grid.Row="1"
                                        Content="Remove Selected"
                                        HorizontalAlignment="Left"
                                        Margin="0,8,0,14"
                                        IsEnabled="False" />
                                <Label Grid.Row="2" Content="Object type to add" />
                                <WrapPanel Grid.Row="3">
                                    <RadioButton Name="PrincipalTypeAutoRadio" GroupName="PrincipalType" Content="Auto-detect" IsChecked="True"
                                                 ToolTip="Match by name: service accounts and groups first, then computers." />
                                    <RadioButton Name="PrincipalTypeServerRadio" GroupName="PrincipalType" Content="Server" />
                                    <RadioButton Name="PrincipalTypeUserRadio" GroupName="PrincipalType" Content="Service Account" />
                                    <RadioButton Name="PrincipalTypeGroupRadio" GroupName="PrincipalType" Content="Group" />
                                    <RadioButton Name="PrincipalTypeGmsaRadio" GroupName="PrincipalType" Content="gMSA" />
                                </WrapPanel>
                                <TextBox Name="ManageAddPrincipalTextBox"
                                         Grid.Row="4"
                                         AcceptsReturn="True"
                                         VerticalScrollBarVisibility="Auto"
                                         Height="70"
                                         TextWrapping="Wrap"
                                         ToolTip="One name per line. Example: sqlserver01c&#x0a;svc-sqlagent" />
                                <Button Name="ManageAddPrincipalButton"
                                        Grid.Row="5"
                                        Content="Add Principals"
                                        HorizontalAlignment="Left"
                                        IsEnabled="False" />
                            </Grid>
                        </GroupBox>

                        <GroupBox Header="Service Principal Names (SPNs)" Grid.Column="2" Margin="10,0,0,0">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="*" MinHeight="80" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                </Grid.RowDefinitions>
                                <ListBox Name="ManageSpnListBox"
                                         Grid.Row="0"
                                         ToolTip="Ctrl+click or Shift+click to select several entries." />
                                <Button Name="ManageRemoveSpnButton"
                                        Grid.Row="1"
                                        Content="Remove Selected"
                                        HorizontalAlignment="Left"
                                        Margin="0,8,0,14"
                                        IsEnabled="False" />
                                <Label Grid.Row="2" Content="SPNs to add (one per line, service/host[:port])" />
                                <TextBox Name="ManageAddSpnTextBox"
                                         Grid.Row="3"
                                         AcceptsReturn="True"
                                         VerticalScrollBarVisibility="Auto"
                                         Height="70"
                                         TextWrapping="Wrap"
                                         ToolTip="Example: MSSQLSvc/sqlserver01a.domain.com:1433&#x0a;HTTP/app01.domain.com" />
                                <Button Name="ManageAddSpnButton"
                                        Grid.Row="4"
                                        Content="Add SPNs"
                                        HorizontalAlignment="Left"
                                        IsEnabled="False" />
                            </Grid>
                        </GroupBox>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Name="ConsoleLogTab" Header="Console Log">
                <Grid Background="#17191F">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <DockPanel Margin="0,0,0,12" LastChildFill="True">
                        <Button Name="ClearLogButton" Content="Clear Log" Padding="14,8" DockPanel.Dock="Left" />
                        <TextBlock VerticalAlignment="Center"
                                   Foreground="#AEB7C4"
                                   Margin="12,0,0,0"
                                   Text="Timestamps, step details, generated commands, and raw errors are shown here for troubleshooting." />
                    </DockPanel>
                    <TextBox Name="LogTextBox"
                             Grid.Row="1"
                             IsReadOnly="True"
                             AcceptsReturn="True"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap"
                             FontFamily="Consolas"
                             Background="#111318" />
                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'DomainTextBox',
    'ServiceNameTextBox',
    'ServersTextBox',
    'DelegationCheckBox',
    'PreviewButton',
    'ExecuteButton',
    'ResetButton',
    'PreviewTextBox',
    'LookupButton',
    'ClearLookupButton',
    'LookupOutputTextBox',
    'LogTextBox',
    'ClearLogButton',
    'MainTabControl',
    'ConsoleLogTab',
    'ManageDomainTextBox',
    'ManageServiceNameTextBox',
    'ManageLoadButton',
    'ManageStatusTextBlock',
    'ManagePrincipalsListBox',
    'ManageRemovePrincipalButton',
    'PrincipalTypeAutoRadio',
    'PrincipalTypeServerRadio',
    'PrincipalTypeUserRadio',
    'PrincipalTypeGroupRadio',
    'PrincipalTypeGmsaRadio',
    'ManageAddPrincipalTextBox',
    'ManageAddPrincipalButton',
    'ManageSpnListBox',
    'ManageRemoveSpnButton',
    'ManageAddSpnTextBox',
    'ManageAddSpnButton'
)

$ui = @{}
foreach ($name in $controlNames) {
    $ui[$name] = $window.FindName($name)
}

$script:PreviewSignature = $null
$script:PreviewCommandText = ''

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'STEP', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $entry = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
        $ui.LogTextBox.AppendText($entry + [Environment]::NewLine)
        $ui.LogTextBox.ScrollToEnd()
    } catch {
        # Write-Log must never throw — silently swallow if the TextBox is unavailable
    }
}

# Logs an error, switches to the Console Log tab, and optionally shows a dialog.
function Write-ErrorLog {
    param(
        [string]$Context,
        [string]$FullText,
        [string]$ShortMessage,
        [switch]$ShowDialog
    )

    Write-Log -Level 'ERROR' -Message ("{0}: {1}" -f $Context, $FullText)
    try { $ui.MainTabControl.SelectedItem = $ui.ConsoleLogTab } catch { }
    if ($ShowDialog) {
        Show-ErrorDialog -Message ("{0} failed.`n`n{1}" -f $Context, $ShortMessage)
    }
}

function Show-ErrorDialog {
    param([string]$Message)

    try {
        [System.Windows.MessageBox]::Show(
            $window,
            $Message,
            'gMSA Creation Utility',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    catch {
        try {
            [System.Windows.MessageBox]::Show(
                $Message,
                'gMSA Creation Utility',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        catch {
            Write-Log -Level 'ERROR' -Message ("Unable to show error dialog: {0}" -f $_.Exception.Message)
        }
    }
}

function Ensure-ActiveDirectoryModule {
    if (-not (Get-Module -Name ActiveDirectory)) {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Log -Level 'STEP' -Message 'Imported ActiveDirectory module.'
    }
}

function Reset-PreviewState {
    $script:PreviewSignature = $null
    $script:PreviewCommandText = ''
    $ui.ExecuteButton.IsEnabled = $false
}

function Get-MultiLineValues {
    param([string]$Text)

    return @(
        $Text -split "(`r`n|`n|`r)" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
}

function Get-InputState {
    $domain = $ui.DomainTextBox.Text.Trim()
    $serviceName = $ui.ServiceNameTextBox.Text.Trim().TrimEnd('$')
    $servers = @(Get-MultiLineValues -Text $ui.ServersTextBox.Text)
    $samAccountName = if ($serviceName) { '{0}$' -f $serviceName } else { '' }
    $dnsHostName    = if ($serviceName -and $domain) { '{0}.{1}' -f $serviceName, $domain } else { '' }

    [pscustomobject]@{
        Domain         = $domain
        ServiceName    = $serviceName
        Servers        = $servers
        SamAccountName = $samAccountName
        DnsHostName    = $dnsHostName
        EnableDelegation = ($ui.DelegationCheckBox.IsChecked -eq $true)
    }
}

function Test-CreateInputs {
    param([object]$InputState)

    $issues = New-Object System.Collections.Generic.List[string]
    if (-not $InputState.Domain)       { $issues.Add('Domain / AD Server is required.') }
    if (-not $InputState.ServiceName)  { $issues.Add('gMSA Short Name is required.') }
    if (-not $InputState.Servers -or $InputState.Servers.Count -eq 0) {
        $issues.Add('At least one allowed principal (server or service account) is required.')
    }

    return $issues
}

function Test-LookupInputs {
    param([object]$InputState)

    $issues = New-Object System.Collections.Generic.List[string]
    if (-not $InputState.Domain)      { $issues.Add('Domain / AD Server is required for lookup.') }
    if (-not $InputState.ServiceName) { $issues.Add('gMSA Short Name is required for lookup.') }

    return $issues
}

function Get-StateSignature {
    param([object]$InputState)

    return (
        @(
            $InputState.Domain
            $InputState.ServiceName
            ($InputState.Servers -join '|')
            $InputState.EnableDelegation
        ) -join '::'
    )
}

function Format-Preview {
    param([object]$InputState)

    $serverLines = if ($InputState.Servers.Count -gt 0) {
        ($InputState.Servers | ForEach-Object { "    '{0}'" -f $_ }) -join ",`r`n"
    } else {
        "    '<server>'"
    }

    $delegationBlock = if ($InputState.EnableDelegation) {
@"

`$msa = Get-ADServiceAccount -Identity '$($InputState.SamAccountName)' -Server '$($InputState.Domain)'
Set-ADAccountControl -Identity `$msa -TrustedForDelegation `$true -TrustedToAuthForDelegation `$false -Server '$($InputState.Domain)'
"@
    } else {
        @"

# Unconstrained delegation is disabled in this preview.
"@
    }

@"
# Generated preview for gMSA creation
`$domain         = '$($InputState.Domain)'
`$serviceName    = '$($InputState.ServiceName)'
`$samAccountName = '$($InputState.SamAccountName)'
`$dnsHostName    = '$($InputState.DnsHostName)'
`$servers = @(
$serverLines
)

# Each entry resolves as a DN, an exact sAMAccountName (service account / group),
# or a computer name (sAMAccountName with trailing `$).
`$principalDns = foreach (`$principal in `$servers) {
    if (`$principal -match '=.+,') {
        (Get-ADObject -Identity `$principal -Server `$domain).DistinguishedName
        continue
    }
    `$match = @(Get-ADObject -LDAPFilter "(sAMAccountName=`$principal)" -Server `$domain)
    if (`$match.Count -eq 0 -and -not `$principal.EndsWith('`$')) {
        `$match = @(Get-ADObject -LDAPFilter "(sAMAccountName=`$principal```$)" -Server `$domain)
    }
    if (`$match.Count -ne 1) { throw "Could not resolve '`$principal' to a single AD object." }
    `$match[0].DistinguishedName
}

New-ADServiceAccount -Name `$serviceName ``
    -DNSHostName `$dnsHostName ``
    -SamAccountName `$samAccountName ``
    -PrincipalsAllowedToRetrieveManagedPassword `$principalDns ``
    -Server `$domain
$delegationBlock

(Get-ADServiceAccount -Identity '$($InputState.SamAccountName)' -Server '$($InputState.Domain)' -Properties PrincipalsAllowedToRetrieveManagedPassword).PrincipalsAllowedToRetrieveManagedPassword
"@
}

function ConvertTo-LdapFilterValue {
    param([string]$Value)

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Value.ToCharArray()) {
        switch ($char) {
            '\'      { [void]$builder.Append('\5c') }
            '*'      { [void]$builder.Append('\2a') }
            '('      { [void]$builder.Append('\28') }
            ')'      { [void]$builder.Append('\29') }
            "`0"     { [void]$builder.Append('\00') }
            default  { [void]$builder.Append($char) }
        }
    }
    return $builder.ToString()
}

# Resolves a server, service account (user / MSA), or group to its AD object.
# Accepts a DN, an exact sAMAccountName, or a computer name without the trailing $.
# A specific -Type looks the name up with that object's cmdlet; 'Auto' matches any type.
function Resolve-AllowedPrincipal {
    param(
        [string]$Name,
        [string]$Domain,
        [ValidateSet('Auto', 'Server', 'ServiceAccount', 'Group', 'gMSA')]
        [string]$Type = 'Auto'
    )

    switch ($Type) {
        'Server'         { return Get-ADComputer       -Identity $Name -Server $Domain -ErrorAction Stop }
        'ServiceAccount' { return Get-ADUser           -Identity $Name -Server $Domain -ErrorAction Stop }
        'Group'          { return Get-ADGroup          -Identity $Name -Server $Domain -ErrorAction Stop }
        'gMSA'           { return Get-ADServiceAccount -Identity $Name -Server $Domain -ErrorAction Stop }
    }

    $properties = @('sAMAccountName', 'objectClass')

    if ($Name -match '=.+,') {
        return Get-ADObject -Identity $Name -Server $Domain -Properties $properties -ErrorAction Stop
    }

    $escaped = ConvertTo-LdapFilterValue -Value $Name
    $found = @(Get-ADObject -LDAPFilter "(sAMAccountName=$escaped)" -Server $Domain -Properties $properties -ErrorAction Stop)

    # Computer accounts carry a trailing $, so fall back to that when the bare name has no match.
    if ($found.Count -eq 0 -and -not $Name.EndsWith('$')) {
        $found = @(Get-ADObject -LDAPFilter "(sAMAccountName=$escaped`$)" -Server $Domain -Properties $properties -ErrorAction Stop)
    }

    if ($found.Count -eq 0) {
        throw ("No server, service account, or group named '{0}' was found in '{1}'." -f $Name, $Domain)
    }
    if ($found.Count -gt 1) {
        throw ("'{0}' matched more than one object in '{1}'. Use the distinguished name instead." -f $Name, $Domain)
    }
    return $found[0]
}

function Format-PrincipalEntry {
    param(
        [string]$DistinguishedName,
        [string]$Domain
    )

    try {
        $object = Get-ADObject -Identity $DistinguishedName -Server $Domain -Properties sAMAccountName, objectClass -ErrorAction Stop
        $type = switch ($object.ObjectClass) {
            'computer'                         { 'Server' }
            'user'                             { 'Service Account' }
            'msDS-GroupManagedServiceAccount'  { 'gMSA' }
            'msDS-ManagedServiceAccount'       { 'MSA' }
            'group'                            { 'Group' }
            default                            { $object.ObjectClass }
        }
        return "{0,-16} {1,-24} {2}" -f ('[' + $type + ']'), $object.sAMAccountName, $DistinguishedName
    }
    catch {
        return "{0,-16} {1,-24} {2}" -f '[Unresolved]', '', $DistinguishedName
    }
}

function Get-LookupCommandText {
    param([object]$InputState)

    return "(Get-ADServiceAccount -Identity '{0}' -Server '{1}' -Properties PrincipalsAllowedToRetrieveManagedPassword).PrincipalsAllowedToRetrieveManagedPassword" -f $InputState.SamAccountName, $InputState.Domain
}

# $Silent suppresses the error dialog and tab-switch when called from the Execute flow.
# Errors are always written to the log regardless.
function Invoke-ManagedPasswordLookup {
    param([switch]$Silent)

    # Everything inside one try-catch — Get-InputState and validation included —
    # so no exception can escape and crash the WPF dispatcher.
    try {
        $state = Get-InputState
        $issues = @(Test-LookupInputs -InputState $state)
        if ($issues.Count -gt 0) {
            $message = $issues -join [Environment]::NewLine
            Write-Log -Level 'ERROR' -Message $message
            if (-not $Silent) { Show-ErrorDialog -Message $message }
            return
        }

        Ensure-ActiveDirectoryModule
        $lookupCommand = Get-LookupCommandText -InputState $state
        Write-Log -Level 'STEP' -Message ("Running lookup command: {0}" -f $lookupCommand)

        # Use SamAccountName (includes trailing $) for reliable MSA identity resolution
        $result = Get-ADServiceAccount -Identity $state.SamAccountName -Server $state.Domain `
                      -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction Stop
        $principals = @($result.PrincipalsAllowedToRetrieveManagedPassword)

        if ($principals.Count -eq 0) {
            $ui.LookupOutputTextBox.Text = 'No principals are currently configured.'
        } else {
            $lines = foreach ($principal in $principals) {
                Format-PrincipalEntry -DistinguishedName ([string]$principal) -Domain $state.Domain
            }
            $ui.LookupOutputTextBox.Text = $lines -join [Environment]::NewLine
        }

        Write-Log -Level 'SUCCESS' -Message ("Lookup completed successfully for '{0}' in '{1}'." -f $state.ServiceName, $state.Domain)
    }
    catch {
        $errorText    = ($_ | Out-String).Trim()
        $errorMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $errorText }
        try { $ui.LookupOutputTextBox.Text = $errorText } catch { }
        Write-ErrorLog -Context 'Lookup' -FullText $errorText -ShortMessage $errorMessage -ShowDialog:(-not $Silent)
    }
}

function Invoke-CreateGmsa {
    param([object]$InputState)

    Ensure-ActiveDirectoryModule

    $resolvedDns = New-Object System.Collections.Generic.List[string]

    foreach ($principal in $InputState.Servers) {
        Write-Log -Level 'STEP' -Message ("Resolving AD principal '{0}' against '{1}'." -f $principal, $InputState.Domain)
        $object = Resolve-AllowedPrincipal -Name $principal -Domain $InputState.Domain
        Write-Log -Level 'INFO' -Message ("Resolved '{0}' as {1}: {2}" -f $principal, $object.ObjectClass, $object.DistinguishedName)
        $resolvedDns.Add($object.DistinguishedName)
    }

    Write-Log -Level 'STEP' -Message ("Creating gMSA '{0}' with DNS host '{1}'." -f $InputState.ServiceName, $InputState.DnsHostName)
    $newParams = @{
        Name                                   = $InputState.ServiceName
        DNSHostName                            = $InputState.DnsHostName
        SamAccountName                         = $InputState.SamAccountName
        PrincipalsAllowedToRetrieveManagedPassword = $resolvedDns.ToArray()
        Server                                 = $InputState.Domain
        ErrorAction                            = 'Stop'
    }
    New-ADServiceAccount @newParams

    if ($InputState.EnableDelegation) {
        Write-Log -Level 'STEP' -Message ("Enabling unconstrained delegation for '{0}'." -f $InputState.ServiceName)
        # Retrieve the created account, then use -Identity (not pipeline) for Set-ADAccountControl
        $msa = Get-ADServiceAccount -Identity $InputState.SamAccountName -Server $InputState.Domain -ErrorAction Stop
        Set-ADAccountControl -Identity $msa -TrustedForDelegation $true -TrustedToAuthForDelegation $false `
            -Server $InputState.Domain -ErrorAction Stop
    }

    Write-Log -Level 'SUCCESS' -Message ("gMSA '{0}' created successfully." -f $InputState.ServiceName)
}

# ---------------------------------------------------------------------------
# Manage gMSA tab
# ---------------------------------------------------------------------------

# The gMSA currently loaded in the Manage tab. Every change is applied to this
# account, never to whatever is typed in the fields, and the target is cleared
# as soon as either field is edited.
$script:ManageTarget = $null

function Show-ValidationError {
    param([string]$Message)

    Write-Log -Level 'ERROR' -Message $Message
    Show-ErrorDialog -Message $Message
}

function Confirm-Change {
    param([string]$Message)

    $result = [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        'Confirm Change',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}

function Get-SelectedPrincipalType {
    if ($ui.PrincipalTypeServerRadio.IsChecked -eq $true) { return 'Server' }
    if ($ui.PrincipalTypeUserRadio.IsChecked   -eq $true) { return 'ServiceAccount' }
    if ($ui.PrincipalTypeGroupRadio.IsChecked  -eq $true) { return 'Group' }
    if ($ui.PrincipalTypeGmsaRadio.IsChecked   -eq $true) { return 'gMSA' }
    return 'Auto'
}

function Set-ManageButtonsEnabled {
    param([bool]$Enabled)

    foreach ($name in 'ManageAddPrincipalButton', 'ManageRemovePrincipalButton', 'ManageAddSpnButton', 'ManageRemoveSpnButton') {
        $ui[$name].IsEnabled = $Enabled
    }
}

function Clear-ManageTarget {
    $script:ManageTarget = $null
    $ui.ManagePrincipalsListBox.Items.Clear()
    $ui.ManageSpnListBox.Items.Clear()
    $ui.ManageStatusTextBlock.Text = 'No gMSA loaded. Enter the domain and gMSA short name, then select Load gMSA.'
    Set-ManageButtonsEnabled -Enabled $false
}

function New-ListEntry {
    param(
        [string]$Text,
        [string]$Value
    )

    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = $Text
    $item.Tag = $Value
    return $item
}

function Get-SelectedListValues {
    param([System.Windows.Controls.ListBox]$ListBox)

    return @($ListBox.SelectedItems | ForEach-Object { [string]$_.Tag })
}

function Get-SelectedListText {
    param([System.Windows.Controls.ListBox]$ListBox)

    return (@($ListBox.SelectedItems | ForEach-Object { '  ' + [string]$_.Content }) -join [Environment]::NewLine)
}

function Import-ManageTarget {
    param(
        [string]$Domain,
        [string]$SamAccountName
    )

    Ensure-ActiveDirectoryModule
    Write-Log -Level 'STEP' -Message ("Loading gMSA '{0}' from '{1}'." -f $SamAccountName, $Domain)

    $account = Get-ADServiceAccount -Identity $SamAccountName -Server $Domain `
                   -Properties PrincipalsAllowedToRetrieveManagedPassword, ServicePrincipalNames -ErrorAction Stop
    $principals = @($account.PrincipalsAllowedToRetrieveManagedPassword | ForEach-Object { [string]$_ })
    $spns       = @($account.ServicePrincipalNames | ForEach-Object { [string]$_ } | Sort-Object)

    $ui.ManagePrincipalsListBox.Items.Clear()
    foreach ($dn in $principals) {
        $text = Format-PrincipalEntry -DistinguishedName $dn -Domain $Domain
        [void]$ui.ManagePrincipalsListBox.Items.Add((New-ListEntry -Text $text -Value $dn))
    }

    $ui.ManageSpnListBox.Items.Clear()
    foreach ($spn in $spns) {
        [void]$ui.ManageSpnListBox.Items.Add((New-ListEntry -Text $spn -Value $spn))
    }

    $script:ManageTarget = [pscustomobject]@{
        Domain            = $Domain
        SamAccountName    = $account.SamAccountName
        DistinguishedName = $account.DistinguishedName
        Principals        = $principals
        Spns              = $spns
    }

    $ui.ManageStatusTextBlock.Text = "Loaded {0}: {1} allowed principal(s), {2} SPN(s). Changes apply to this account only." -f `
        $account.SamAccountName, $principals.Count, $spns.Count
    Set-ManageButtonsEnabled -Enabled $true
    Write-Log -Level 'SUCCESS' -Message ("Loaded '{0}': {1} principal(s), {2} SPN(s)." -f $account.SamAccountName, $principals.Count, $spns.Count)
}

function Update-ManageTarget {
    Import-ManageTarget -Domain $script:ManageTarget.Domain -SamAccountName $script:ManageTarget.SamAccountName
}

# Set-ADServiceAccount replaces the whole allowed list, so add and remove both
# write the full list back.
function Set-AllowedPrincipals {
    param([string[]]$DistinguishedNames)

    $target = $script:ManageTarget
    Write-Log -Level 'STEP' -Message ("Running: Set-ADServiceAccount -Identity '{0}' -Server '{1}' -PrincipalsAllowedToRetrieveManagedPassword <{2} principal(s)>" -f `
        $target.SamAccountName, $target.Domain, $DistinguishedNames.Count)
    Set-ADServiceAccount -Identity $target.SamAccountName -Server $target.Domain `
        -PrincipalsAllowedToRetrieveManagedPassword $DistinguishedNames -ErrorAction Stop
}

function Add-ManagePrincipals {
    $target = $script:ManageTarget
    $names  = @(Get-MultiLineValues -Text $ui.ManageAddPrincipalTextBox.Text)
    if ($names.Count -eq 0) {
        Show-ValidationError -Message 'Enter at least one server, service account, or group to add.'
        return
    }

    Ensure-ActiveDirectoryModule
    $type    = Get-SelectedPrincipalType
    $updated = New-Object System.Collections.Generic.List[string]
    foreach ($dn in $target.Principals) { $updated.Add($dn) }
    $added   = New-Object System.Collections.Generic.List[string]

    foreach ($name in $names) {
        Write-Log -Level 'STEP' -Message ("Resolving '{0}' as {1} against '{2}'." -f $name, $type, $target.Domain)
        $object = Resolve-AllowedPrincipal -Name $name -Domain $target.Domain -Type $type
        if ($updated -contains $object.DistinguishedName) {
            Write-Log -Level 'INFO' -Message ("'{0}' is already allowed; skipping." -f $name)
            continue
        }
        $updated.Add($object.DistinguishedName)
        $added.Add(("  {0} ({1})" -f $object.sAMAccountName, $object.ObjectClass))
    }

    if ($added.Count -eq 0) {
        Write-Log -Level 'INFO' -Message 'Nothing to add; every entry is already allowed.'
        Show-ValidationError -Message 'Every entry is already allowed to retrieve the password.'
        return
    }

    $message = "Allow these principals to retrieve the password for '{0}'?`n`n{1}" -f $target.SamAccountName, ($added -join "`n")
    if (-not (Confirm-Change -Message $message)) {
        Write-Log -Level 'INFO' -Message 'Add principals cancelled by user.'
        return
    }

    Set-AllowedPrincipals -DistinguishedNames $updated.ToArray()
    Write-Log -Level 'SUCCESS' -Message ("Added {0} principal(s) to '{1}'." -f $added.Count, $target.SamAccountName)
    $ui.ManageAddPrincipalTextBox.Clear()
    Update-ManageTarget
}

function Remove-ManagePrincipals {
    $target   = $script:ManageTarget
    $selected = @(Get-SelectedListValues -ListBox $ui.ManagePrincipalsListBox)
    if ($selected.Count -eq 0) {
        Show-ValidationError -Message 'Select one or more principals to remove.'
        return
    }

    $remaining = @($target.Principals | Where-Object { $selected -notcontains $_ })
    if ($remaining.Count -eq 0) {
        Show-ValidationError -Message 'At least one principal must stay allowed to retrieve the password. Add the replacement first, then remove this one.'
        return
    }

    $message = "Stop these principals from retrieving the password for '{0}'?`n`n{1}`n`nServices using this gMSA on a removed server will fail at their next password refresh." -f `
        $target.SamAccountName, (Get-SelectedListText -ListBox $ui.ManagePrincipalsListBox)
    if (-not (Confirm-Change -Message $message)) {
        Write-Log -Level 'INFO' -Message 'Remove principals cancelled by user.'
        return
    }

    Set-AllowedPrincipals -DistinguishedNames $remaining
    Write-Log -Level 'SUCCESS' -Message ("Removed {0} principal(s) from '{1}'." -f $selected.Count, $target.SamAccountName)
    Update-ManageTarget
}

function Add-ManageSpns {
    $target = $script:ManageTarget
    $spns   = @(Get-MultiLineValues -Text $ui.ManageAddSpnTextBox.Text)
    if ($spns.Count -eq 0) {
        Show-ValidationError -Message 'Enter at least one SPN to add.'
        return
    }

    Ensure-ActiveDirectoryModule
    $toAdd = New-Object System.Collections.Generic.List[string]

    foreach ($spn in $spns) {
        if ($spn -notmatch '^[^/\s]+/[^/\s]+(/[^/\s]+)?$') {
            Show-ValidationError -Message ("'{0}' is not a valid SPN. Use service/host[:port], for example MSSQLSvc/sqlserver01a.domain.com:1433." -f $spn)
            return
        }
        if ($target.Spns -contains $spn -or $toAdd -contains $spn) {
            Write-Log -Level 'INFO' -Message ("SPN '{0}' is already on '{1}'; skipping." -f $spn, $target.SamAccountName)
            continue
        }

        # Duplicate SPNs break Kerberos for both accounts, so refuse one that is
        # already registered on another object in the domain.
        Write-Log -Level 'STEP' -Message ("Checking '{0}' for duplicate SPN '{1}'." -f $target.Domain, $spn)
        $escaped = ConvertTo-LdapFilterValue -Value $spn
        $owners  = @(
            Get-ADObject -LDAPFilter "(servicePrincipalName=$escaped)" -Server $target.Domain -ErrorAction Stop |
            Where-Object { $_.DistinguishedName -ne $target.DistinguishedName }
        )
        if ($owners.Count -gt 0) {
            Show-ValidationError -Message ("SPN '{0}' is already registered on:`n`n{1}`n`nRemove it there first; duplicate SPNs break Kerberos authentication." -f `
                $spn, (($owners | ForEach-Object { '  ' + $_.DistinguishedName }) -join "`n"))
            return
        }
        $toAdd.Add($spn)
    }

    if ($toAdd.Count -eq 0) {
        Write-Log -Level 'INFO' -Message 'Nothing to add; every SPN is already on the account.'
        Show-ValidationError -Message 'Every SPN entered is already on this account.'
        return
    }

    $message = "Add these SPNs to '{0}'?`n`n{1}" -f $target.SamAccountName, (($toAdd | ForEach-Object { '  ' + $_ }) -join "`n")
    if (-not (Confirm-Change -Message $message)) {
        Write-Log -Level 'INFO' -Message 'Add SPNs cancelled by user.'
        return
    }

    Write-Log -Level 'STEP' -Message ("Running: Set-ADServiceAccount -Identity '{0}' -Server '{1}' -ServicePrincipalNames @{{Add='{2}'}}" -f `
        $target.SamAccountName, $target.Domain, ($toAdd -join "','"))
    Set-ADServiceAccount -Identity $target.SamAccountName -Server $target.Domain `
        -ServicePrincipalNames @{ Add = $toAdd.ToArray() } -ErrorAction Stop
    Write-Log -Level 'SUCCESS' -Message ("Added {0} SPN(s) to '{1}'." -f $toAdd.Count, $target.SamAccountName)
    $ui.ManageAddSpnTextBox.Clear()
    Update-ManageTarget
}

function Remove-ManageSpns {
    $target   = $script:ManageTarget
    $selected = @(Get-SelectedListValues -ListBox $ui.ManageSpnListBox)
    if ($selected.Count -eq 0) {
        Show-ValidationError -Message 'Select one or more SPNs to remove.'
        return
    }

    $message = "Remove these SPNs from '{0}'?`n`n{1}" -f $target.SamAccountName, (Get-SelectedListText -ListBox $ui.ManageSpnListBox)
    if (-not (Confirm-Change -Message $message)) {
        Write-Log -Level 'INFO' -Message 'Remove SPNs cancelled by user.'
        return
    }

    Write-Log -Level 'STEP' -Message ("Running: Set-ADServiceAccount -Identity '{0}' -Server '{1}' -ServicePrincipalNames @{{Remove='{2}'}}" -f `
        $target.SamAccountName, $target.Domain, ($selected -join "','"))
    Set-ADServiceAccount -Identity $target.SamAccountName -Server $target.Domain `
        -ServicePrincipalNames @{ Remove = $selected } -ErrorAction Stop
    Write-Log -Level 'SUCCESS' -Message ("Removed {0} SPN(s) from '{1}'." -f $selected.Count, $target.SamAccountName)
    Update-ManageTarget
}

# Runs a Manage tab action with the same error handling the other buttons use.
function Invoke-ManageAction {
    param(
        [string]$Context,
        [scriptblock]$Action
    )

    try { & $Action }
    catch {
        $errorText    = ($_ | Out-String).Trim()
        $errorMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $errorText }
        Write-ErrorLog -Context $Context -FullText $errorText -ShortMessage $errorMessage -ShowDialog
    }
}

function Register-DirtyTracking {
    param([System.Windows.Controls.Primitives.ToggleButton]$ToggleControl)
    $ToggleControl.Add_Checked({
        try { Reset-PreviewState }
        catch { Write-Log -Level 'ERROR' -Message ("DirtyTracking (Checked) error: {0}" -f $_.Exception.Message) }
    })
    $ToggleControl.Add_Unchecked({
        try { Reset-PreviewState }
        catch { Write-Log -Level 'ERROR' -Message ("DirtyTracking (Unchecked) error: {0}" -f $_.Exception.Message) }
    })
}

$ui.PreviewButton.Add_Click({
    try {
        $state = Get-InputState
        $issues = @(Test-CreateInputs -InputState $state)
        if ($issues.Count -gt 0) {
            $message = $issues -join [Environment]::NewLine
            Write-Log -Level 'ERROR' -Message $message
            Show-ErrorDialog -Message $message
            return
        }

        $script:PreviewCommandText = Format-Preview -InputState $state
        $script:PreviewSignature   = Get-StateSignature -InputState $state
        $ui.PreviewTextBox.Text    = $script:PreviewCommandText
        $ui.ExecuteButton.IsEnabled = $true

        Write-Log -Level 'STEP' -Message ("Preview generated for '{0}' in '{1}'." -f $state.ServiceName, $state.Domain)
    }
    catch {
        $errorText    = ($_ | Out-String).Trim()
        $errorMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $errorText }
        Write-ErrorLog -Context 'Preview' -FullText $errorText -ShortMessage $errorMessage -ShowDialog
    }
})

$ui.ExecuteButton.Add_Click({
    try {
        $state  = Get-InputState
        $issues = @(Test-CreateInputs -InputState $state)
        if ($issues.Count -gt 0) {
            $message = $issues -join [Environment]::NewLine
            Write-Log -Level 'ERROR' -Message $message
            Show-ErrorDialog -Message $message
            return
        }

        $signature = Get-StateSignature -InputState $state
        if ($signature -ne $script:PreviewSignature) {
            $message = 'The form has changed since the last preview. Generate a new preview before executing.'
            Write-Log -Level 'ERROR' -Message $message
            Show-ErrorDialog -Message $message
            Reset-PreviewState
            return
        }

        $confirmation = [System.Windows.MessageBox]::Show(
            $window,
            ("Execute gMSA creation for '{0}' in '{1}' now?" -f $state.ServiceName, $state.Domain),
            'Confirm Execution',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )

        if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-Log -Level 'INFO' -Message 'Execution cancelled by user.'
            return
        }

        Write-Log -Level 'STEP' -Message 'Execution confirmed by user.'
        Invoke-CreateGmsa -InputState $state

        # Disable Execute immediately after creation to prevent double-execution.
        # Run lookup silently (errors go to log only — the creation already succeeded).
        Reset-PreviewState
        Invoke-ManagedPasswordLookup -Silent

        # Pre-fill the Manage tab so SPNs can be added to the new account straight away.
        $ui.ManageDomainTextBox.Text      = $state.Domain
        $ui.ManageServiceNameTextBox.Text = $state.ServiceName

        [System.Windows.MessageBox]::Show(
            $window,
            'gMSA creation completed successfully. The latest retrieval principals have been loaded into the Lookup panel.',
            'Success',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
    catch {
        $errorText    = ($_ | Out-String).Trim()
        $errorMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $errorText }
        Write-ErrorLog -Context 'Execution' -FullText $errorText -ShortMessage $errorMessage -ShowDialog
    }
})

$ui.LookupButton.Add_Click({
    try { Invoke-ManagedPasswordLookup }
    catch {
        $errorText    = ($_ | Out-String).Trim()
        $errorMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $errorText }
        Write-ErrorLog -Context 'Lookup' -FullText $errorText -ShortMessage $errorMessage -ShowDialog
    }
})

$ui.ClearLookupButton.Add_Click({
    try {
        $ui.LookupOutputTextBox.Clear()
        Write-Log -Level 'INFO' -Message 'Lookup output cleared.'
    } catch { Write-Log -Level 'ERROR' -Message ("Clear lookup failed: {0}" -f $_.Exception.Message) }
})

$ui.ClearLogButton.Add_Click({
    try {
        $ui.LogTextBox.Clear()
        Write-Log -Level 'INFO' -Message 'Log cleared.'
    } catch { }
})

$ui.ResetButton.Add_Click({
    try {
        $ui.DomainTextBox.Clear()
        $ui.ServiceNameTextBox.Clear()
        $ui.ServersTextBox.Clear()
        $ui.DelegationCheckBox.IsChecked = $false
        $ui.PreviewTextBox.Clear()
        $ui.LookupOutputTextBox.Clear()
        Reset-PreviewState
        Write-Log -Level 'INFO' -Message 'Form reset to defaults.'
    } catch {
        Write-Log -Level 'ERROR' -Message ("Reset failed: {0}" -f $_.Exception.Message)
    }
})

$ui.DomainTextBox.Add_TextChanged({
    try { Reset-PreviewState } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
})
$ui.ServiceNameTextBox.Add_TextChanged({
    try { Reset-PreviewState } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
})
$ui.ServersTextBox.Add_TextChanged({
    try { Reset-PreviewState } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
})
Register-DirtyTracking -ToggleControl $ui.DelegationCheckBox

$ui.ManageLoadButton.Add_Click({
    Invoke-ManageAction -Context 'Load gMSA' -Action {
        $domain      = $ui.ManageDomainTextBox.Text.Trim()
        $serviceName = $ui.ManageServiceNameTextBox.Text.Trim().TrimEnd('$')
        if (-not $domain -or -not $serviceName) {
            Show-ValidationError -Message 'Domain / AD Server and gMSA Short Name are required to load a gMSA.'
            return
        }
        Clear-ManageTarget
        Import-ManageTarget -Domain $domain -SamAccountName ('{0}$' -f $serviceName)
    }
})
$ui.ManageAddPrincipalButton.Add_Click({
    Invoke-ManageAction -Context 'Add principals' -Action { Add-ManagePrincipals }
})
$ui.ManageRemovePrincipalButton.Add_Click({
    Invoke-ManageAction -Context 'Remove principals' -Action { Remove-ManagePrincipals }
})
$ui.ManageAddSpnButton.Add_Click({
    Invoke-ManageAction -Context 'Add SPNs' -Action { Add-ManageSpns }
})
$ui.ManageRemoveSpnButton.Add_Click({
    Invoke-ManageAction -Context 'Remove SPNs' -Action { Remove-ManageSpns }
})
$ui.ManageDomainTextBox.Add_TextChanged({
    try { if ($script:ManageTarget) { Clear-ManageTarget } } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
})
$ui.ManageServiceNameTextBox.Add_TextChanged({
    try { if ($script:ManageTarget) { Clear-ManageTarget } } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
})
Clear-ManageTarget

$window.Add_SourceInitialized({
    try {
        Write-Log -Level 'INFO' -Message 'gMSA Creation Utility loaded.'
        Write-Log -Level 'INFO' -Message 'Use Preview Command before Execute. Lookup can be run independently at any time.'
        Write-Log -Level 'INFO' -Message 'Use the Manage gMSA tab to add or remove servers, service accounts, groups, and SPNs on an existing gMSA.'
    } catch { }
})

# Last-resort safety net: any exception that somehow escapes all handlers is
# caught here, logged, and marked handled so the window stays open.
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try {
        $errorText = ($e.Exception | Out-String).Trim()
        Write-Log -Level 'ERROR' -Message ("UNHANDLED DISPATCHER EXCEPTION: {0}" -f $errorText)
        try { $ui.MainTabControl.SelectedItem = $ui.ConsoleLogTab } catch { }
        [System.Windows.MessageBox]::Show(
            "An unexpected error was caught and logged to the Console Log tab.`n`nThe application will remain open.`n`n{0}" -f $e.Exception.Message,
            'gMSA Creation Utility - Unexpected Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch { }
    $e.Handled = $true
})

[void]$window.ShowDialog()
