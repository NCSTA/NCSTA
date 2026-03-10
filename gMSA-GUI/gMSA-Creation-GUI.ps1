Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="gMSA Creation Utility"
        Height="860"
        Width="1120"
        MinHeight="760"
        MinWidth="980"
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
                                   Text="Enter the target domain, the short gMSA name, and one server per line. Preview builds the exact PowerShell steps first, then Execute runs them only after confirmation." />
                    </Border>
                    <Grid Grid.Row="1">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="360" />
                            <ColumnDefinition Width="16" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <GroupBox Header="Inputs">
                                    <StackPanel>
                                        <Label Content="Domain / AD Server" />
                                        <TextBox Name="DomainTextBox"
                                                 ToolTip="Example: domain.com" />
                                        <Label Content="gMSA Short Name" />
                                        <TextBox Name="ServiceNameTextBox"
                                                 ToolTip="Example: gMSA-sqlp100z" />
                                        <Label Content="Allowed Servers (one per line)" />
                                        <TextBox Name="ServersTextBox"
                                                 AcceptsReturn="True"
                                                 VerticalScrollBarVisibility="Auto"
                                                 Height="180"
                                                 TextWrapping="Wrap"
                                                 ToolTip="Example: edcwsqlp100a&#x0a;edcwsqlp100b" />
                                        <CheckBox Name="DelegationCheckBox"
                                                  Content="Enable unconstrained delegation after creation" />
                                    </StackPanel>
                                </GroupBox>
                                <GroupBox Header="Actions">
                                    <StackPanel>
                                        <UniformGrid Rows="2" Columns="2" Margin="0,0,0,8">
                                            <Button Name="PreviewButton" Content="Preview Command" Width="140" HorizontalAlignment="Left" Margin="0,0,10,10" />
                                            <Button Name="ExecuteButton" Content="Execute" Width="110" HorizontalAlignment="Left" Margin="0,0,0,10" IsEnabled="False" />
                                            <Button Name="ResetButton" Content="Reset Form" Width="110" HorizontalAlignment="Left" Margin="0,0,10,0" />
                                        </UniformGrid>
                                        <TextBlock Foreground="#AEB7C4"
                                                   TextWrapping="Wrap"
                                                   Text="Execute stays disabled until a fresh preview is generated from the current field values." />
                                    </StackPanel>
                                </GroupBox>
                            </StackPanel>
                        </ScrollViewer>
                        <Grid Grid.Column="2">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*" />
                                <RowDefinition Height="14" />
                                <RowDefinition Height="*" />
                            </Grid.RowDefinitions>
                            <GroupBox Header="Preview">
                                <Grid>
                                    <TextBox Name="PreviewTextBox"
                                             IsReadOnly="True"
                                             AcceptsReturn="True"
                                             VerticalScrollBarVisibility="Auto"
                                             HorizontalScrollBarVisibility="Auto"
                                             TextWrapping="NoWrap"
                                             FontFamily="Consolas" />
                                </Grid>
                            </GroupBox>
                            <GroupBox Header="Managed Password Retrieval Lookup" Grid.Row="2">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto" />
                                        <RowDefinition Height="*" />
                                    </Grid.RowDefinitions>
                                    <DockPanel Margin="0,0,0,10" LastChildFill="True">
                                        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                                            <Button Name="LookupButton" Content="Run Lookup" Width="110" />
                                            <Button Name="ClearLookupButton" Content="Clear Output" Width="110" />
                                        </StackPanel>
                                        <TextBlock VerticalAlignment="Center"
                                                   Foreground="#AEB7C4"
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
            <TabItem Header="Console Log">
                <Grid Background="#17191F">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <DockPanel Margin="0,0,0,12" LastChildFill="True">
                        <Button Name="ClearLogButton" Content="Clear Log" Width="110" DockPanel.Dock="Left" />
                        <TextBlock VerticalAlignment="Center"
                                   Foreground="#AEB7C4"
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
    'MainTabControl'
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

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
    $ui.LogTextBox.AppendText($entry + [Environment]::NewLine)
    $ui.LogTextBox.ScrollToEnd()
}

function Show-ErrorDialog {
    param([string]$Message)
    [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        'gMSA Creation Utility',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
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

function Get-InputState {
    $domain = $ui.DomainTextBox.Text.Trim()
    $serviceName = $ui.ServiceNameTextBox.Text.Trim()
    $servers = @(
        $ui.ServersTextBox.Text -split "(`r`n|`n|`r)" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
    $samAccountName = if ($serviceName) { '{0}$' -f $serviceName.TrimEnd('$') } else { '' }
    $dnsHostName = if ($serviceName -and $domain) { '{0}.{1}' -f $serviceName.TrimEnd('$'), $domain } else { '' }

    [pscustomobject]@{
        Domain = $domain
        ServiceName = $serviceName.TrimEnd('$')
        Servers = $servers
        SamAccountName = $samAccountName
        DnsHostName = $dnsHostName
        EnableDelegation = [bool]$ui.DelegationCheckBox.IsChecked
    }
}

function Test-CreateInputs {
    param([object]$InputState)

    $issues = New-Object System.Collections.Generic.List[string]
    if (-not $InputState.Domain) { $issues.Add('Domain / AD Server is required.') }
    if (-not $InputState.ServiceName) { $issues.Add('gMSA Short Name is required.') }
    if (-not $InputState.Servers -or $InputState.Servers.Count -eq 0) { $issues.Add('At least one allowed server is required.') }

    return $issues
}

function Test-LookupInputs {
    param([object]$InputState)

    $issues = New-Object System.Collections.Generic.List[string]
    if (-not $InputState.Domain) { $issues.Add('Domain / AD Server is required for lookup.') }
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

`$msa = Get-ADServiceAccount -Identity '$($InputState.ServiceName)' -Server '$($InputState.Domain)'
`$msa | Set-ADAccountControl -TrustedForDelegation `$true -TrustedToAuthForDelegation `$false -Server '$($InputState.Domain)'
"@
    } else {
        @"

# Unconstrained delegation is disabled in this preview.
"@
    }

@"
# Generated preview for gMSA creation
`$domain = '$($InputState.Domain)'
`$serviceName = '$($InputState.ServiceName)'
`$samAccountName = '$($InputState.SamAccountName)'
`$dnsHostName = '$($InputState.DnsHostName)'
`$servers = @(
$serverLines
)

`$serverDns = foreach (`$server in `$servers) {
    (Get-ADComputer -Identity `$server -Server `$domain).DistinguishedName
}

New-ADServiceAccount -Name `$serviceName `
    -DNSHostName `$dnsHostName `
    -SamAccountName `$samAccountName `
    -PrincipalsAllowedToRetrieveManagedPassword `$serverDns `
    -Server `$domain
$delegationBlock

(Get-ADServiceAccount -Identity '$($InputState.ServiceName)' -Server '$($InputState.Domain)' -Properties PrincipalsAllowedToRetrieveManagedPassword).PrincipalsAllowedToRetrieveManagedPassword
"@
}

function Get-LookupCommandText {
    param([object]$InputState)

    return "(Get-ADServiceAccount -Identity '{0}' -Server '{1}' -Properties PrincipalsAllowedToRetrieveManagedPassword).PrincipalsAllowedToRetrieveManagedPassword" -f $InputState.ServiceName, $InputState.Domain
}

function Invoke-ManagedPasswordLookup {
    $state = Get-InputState
    $issues = Test-LookupInputs -InputState $state
    if ($issues.Count -gt 0) {
        $message = $issues -join [Environment]::NewLine
        Write-Log -Level 'ERROR' -Message $message
        Show-ErrorDialog -Message $message
        return
    }

    try {
        Ensure-ActiveDirectoryModule
        $lookupCommand = Get-LookupCommandText -InputState $state
        Write-Log -Level 'STEP' -Message ("Running lookup command: {0}" -f $lookupCommand)

        $result = Get-ADServiceAccount -Identity $state.ServiceName -Server $state.Domain -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction Stop
        $principals = @($result.PrincipalsAllowedToRetrieveManagedPassword)

        if ($principals.Count -eq 0) {
            $ui.LookupOutputTextBox.Text = 'No principals are currently configured.'
        } else {
            $ui.LookupOutputTextBox.Text = ($principals | ForEach-Object { $_ }) -join [Environment]::NewLine
        }

        Write-Log -Level 'SUCCESS' -Message ("Lookup completed successfully for '{0}' in '{1}'." -f $state.ServiceName, $state.Domain)
    }
    catch {
        $ui.LookupOutputTextBox.Text = $_ | Out-String
        Write-Log -Level 'ERROR' -Message ("Lookup failed: {0}" -f ($_ | Out-String).Trim())
        Show-ErrorDialog -Message ("Lookup failed.`n`n{0}" -f $_.Exception.Message)
        $ui.MainTabControl.SelectedIndex = 1
    }
}

function Invoke-CreateGmsa {
    param([object]$InputState)

    Ensure-ActiveDirectoryModule

    $resolvedDns = New-Object System.Collections.Generic.List[string]

    foreach ($server in $InputState.Servers) {
        Write-Log -Level 'STEP' -Message ("Resolving AD computer '{0}' against '{1}'." -f $server, $InputState.Domain)
        $computer = Get-ADComputer -Identity $server -Server $InputState.Domain -ErrorAction Stop
        $resolvedDns.Add($computer.DistinguishedName)
    }

    Write-Log -Level 'STEP' -Message ("Creating gMSA '{0}' with DNS host '{1}'." -f $InputState.ServiceName, $InputState.DnsHostName)
    $newParams = @{
        Name = $InputState.ServiceName
        DNSHostName = $InputState.DnsHostName
        SamAccountName = $InputState.SamAccountName
        PrincipalsAllowedToRetrieveManagedPassword = $resolvedDns.ToArray()
        Server = $InputState.Domain
        ErrorAction = 'Stop'
    }
    New-ADServiceAccount @newParams

    if ($InputState.EnableDelegation) {
        Write-Log -Level 'STEP' -Message ("Enabling unconstrained delegation for '{0}'." -f $InputState.ServiceName)
        $msa = Get-ADServiceAccount -Identity $InputState.ServiceName -Server $InputState.Domain -ErrorAction Stop
        $msa | Set-ADAccountControl -TrustedForDelegation $true -TrustedToAuthForDelegation $false -Server $InputState.Domain -ErrorAction Stop
    }

    Write-Log -Level 'SUCCESS' -Message ("gMSA '{0}' created successfully." -f $InputState.ServiceName)
}

function Register-DirtyTracking {
    param([System.Windows.Controls.Primitives.ToggleButton]$ToggleControl)
    $ToggleControl.Add_Checked({ Reset-PreviewState })
    $ToggleControl.Add_Unchecked({ Reset-PreviewState })
}

$ui.PreviewButton.Add_Click({
    $state = Get-InputState
    $issues = Test-CreateInputs -InputState $state
    if ($issues.Count -gt 0) {
        $message = $issues -join [Environment]::NewLine
        Write-Log -Level 'ERROR' -Message $message
        Show-ErrorDialog -Message $message
        return
    }

    $script:PreviewCommandText = Format-Preview -InputState $state
    $script:PreviewSignature = Get-StateSignature -InputState $state
    $ui.PreviewTextBox.Text = $script:PreviewCommandText
    $ui.ExecuteButton.IsEnabled = $true

    Write-Log -Level 'STEP' -Message ("Preview generated for '{0}' in '{1}'." -f $state.ServiceName, $state.Domain)
    $ui.MainTabControl.SelectedIndex = 0
})

$ui.ExecuteButton.Add_Click({
    $state = Get-InputState
    $issues = Test-CreateInputs -InputState $state
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

    try {
        Write-Log -Level 'STEP' -Message 'Execution confirmed by user.'
        Invoke-CreateGmsa -InputState $state
        Invoke-ManagedPasswordLookup
        [System.Windows.MessageBox]::Show(
            $window,
            'gMSA creation completed successfully. The latest retrieval principals have been loaded.',
            'Success',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
    catch {
        Write-Log -Level 'ERROR' -Message ("Execution failed: {0}" -f ($_ | Out-String).Trim())
        Show-ErrorDialog -Message ("Execution failed.`n`n{0}" -f $_.Exception.Message)
        $ui.MainTabControl.SelectedIndex = 1
    }
})

$ui.LookupButton.Add_Click({
    Invoke-ManagedPasswordLookup
})

$ui.ClearLookupButton.Add_Click({
    $ui.LookupOutputTextBox.Clear()
    Write-Log -Level 'INFO' -Message 'Lookup output cleared.'
})

$ui.ClearLogButton.Add_Click({
    $ui.LogTextBox.Clear()
    Write-Log -Level 'INFO' -Message 'Log cleared.'
})

$ui.ResetButton.Add_Click({
    $ui.DomainTextBox.Clear()
    $ui.ServiceNameTextBox.Clear()
    $ui.ServersTextBox.Clear()
    $ui.DelegationCheckBox.IsChecked = $false
    $ui.PreviewTextBox.Clear()
    $ui.LookupOutputTextBox.Clear()
    Reset-PreviewState
    Write-Log -Level 'INFO' -Message 'Form reset to defaults.'
})

$ui.DomainTextBox.Add_TextChanged({ Reset-PreviewState })
$ui.ServiceNameTextBox.Add_TextChanged({ Reset-PreviewState })
$ui.ServersTextBox.Add_TextChanged({ Reset-PreviewState })
Register-DirtyTracking -ToggleControl $ui.DelegationCheckBox

$window.Add_SourceInitialized({
    Write-Log -Level 'INFO' -Message 'gMSA Creation Utility loaded.'
    Write-Log -Level 'INFO' -Message 'Use Preview Command before Execute. Lookup can be run independently at any time.'
})

[void]$window.ShowDialog()

