#Requires -Version 5.1
<#
.SYNOPSIS
    Server QA Checker - Automated server build validation GUI
.DESCRIPTION
    WPF GUI that collects server configuration data via Invoke-Command,
    validates it against t-shirt size templates, and displays color-coded
    pass/fail results. Replaces manual comparison of Get-QAinfo output.
.NOTES
    Requires: PowerShell 5.1+, WinRM access to target servers
#>

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
$modulesPath   = Join-Path $scriptRoot 'modules'
$groupLifecycleModulePath = Join-Path $modulesPath 'ActiveDirectory\GroupLifecycle.psm1'
$templatesPath = Join-Path $scriptRoot 'templates'
$reportsPath   = Join-Path $scriptRoot 'reports'
$logsPath      = Join-Path $scriptRoot 'logs'

# Ensure output directories exist
foreach ($dir in @($reportsPath, $logsPath)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# Import modules
Import-Module (Join-Path $modulesPath 'QaDataCollector.psm1') -Force
Import-Module (Join-Path $modulesPath 'QaValidationEngine.psm1') -Force
Import-Module (Join-Path $modulesPath 'QaResultExporter.psm1') -Force
if (Test-Path $groupLifecycleModulePath) {
    Import-Module $groupLifecycleModulePath -Force
}

# ---------------------------------------------------------------------------
# XAML UI Definition
# ---------------------------------------------------------------------------

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Server QA Checker"
    Width="1100" Height="800"
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

        <!-- Header / Input Bar -->
        <Border Grid.Row="0" Background="#181825" Padding="12,8">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Server QA Checker"
                           Foreground="#89b4fa" FontSize="18" FontWeight="Bold"
                           VerticalAlignment="Center" Margin="0,0,20,0"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Label Content="Server:" Margin="0,0,4,0"/>
                    <Grid Width="260" Margin="0,0,12,0">
                        <TextBox x:Name="txtServer"/>
                        <TextBlock x:Name="txtServerHint" Text="ServerFQDN" Foreground="#585b70"
                                   IsHitTestVisible="False" VerticalAlignment="Center" Margin="4,0,0,0"
                                   FontStyle="Italic"/>
                    </Grid>
                    <Label Content="Template:" Margin="0,0,4,0"/>
                    <ComboBox x:Name="cboTemplate" Width="200" Margin="0,0,12,0"/>
                </StackPanel>
                <Button Grid.Column="2" x:Name="btnRunQa" Content="Run QA" Margin="10,0,0,0"
                        Style="{StaticResource SuccessButton}"/>
                <Button Grid.Column="3" x:Name="btnCredential" Content="Credentials"
                        Margin="8,0,0,0" FontSize="11" Padding="10,6"
                        Background="#45475a" Foreground="#a6adc8"
                        ToolTip="Left-click: set alternate credentials. Right-click: clear."/>
                <Ellipse Grid.Column="4" x:Name="statusLight" Width="14" Height="14"
                         Fill="#6c7086" Margin="12,0,0,0" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Main Content Tabs -->
        <TabControl Grid.Row="1" x:Name="mainTabs" Background="#1e1e2e" BorderBrush="#45475a"
                    Margin="0" Padding="0">

            <!-- TAB: QA Results -->
            <TabItem Header="QA Results">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Summary Bar -->
                    <Border Grid.Row="0" x:Name="pnlSummary" Background="#181825"
                            Padding="16,10" Visibility="Collapsed">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Orientation="Horizontal">
                                <Border Background="#a6e3a1" CornerRadius="3" Padding="10,4" Margin="0,0,8,0">
                                    <TextBlock x:Name="lblPassCount" Text="Pass: 0"
                                               Foreground="#1e1e2e" FontWeight="SemiBold" FontSize="12"/>
                                </Border>
                                <Border Background="#f38ba8" CornerRadius="3" Padding="10,4" Margin="0,0,8,0">
                                    <TextBlock x:Name="lblFailCount" Text="Fail: 0"
                                               Foreground="#1e1e2e" FontWeight="SemiBold" FontSize="12"/>
                                </Border>
                                <Border Background="#f9e2af" CornerRadius="3" Padding="10,4" Margin="0,0,8,0">
                                    <TextBlock x:Name="lblWarnCount" Text="Warn: 0"
                                               Foreground="#1e1e2e" FontWeight="SemiBold" FontSize="12"/>
                                </Border>
                                <Border Background="#89b4fa" CornerRadius="3" Padding="10,4" Margin="0,0,8,0">
                                    <TextBlock x:Name="lblInfoCount" Text="Info: 0"
                                               Foreground="#1e1e2e" FontWeight="SemiBold" FontSize="12"/>
                                </Border>
                                <Border Background="#6c7086" CornerRadius="3" Padding="10,4" Margin="0,0,8,0">
                                    <TextBlock x:Name="lblErrorCount" Text="Error: 0"
                                               Foreground="#1e1e2e" FontWeight="SemiBold" FontSize="12"/>
                                </Border>
                                <TextBlock x:Name="lblPassPct" Text=""
                                           Foreground="#cdd6f4" FontSize="18" FontWeight="Bold"
                                           VerticalAlignment="Center" Margin="12,0,0,0"/>
                            </StackPanel>

                            <CheckBox Grid.Column="1" x:Name="chkFailOnly" Content="Failures Only"
                                      Margin="12,0,0,0" VerticalAlignment="Center" IsEnabled="False" HorizontalAlignment="Right"/>
                        </Grid>
                    </Border>

                    <!-- Progress Bar -->
                    <ProgressBar Grid.Row="1" x:Name="progressBar" Height="4"
                                 IsIndeterminate="True" Visibility="Collapsed"
                                 Background="#313244" Foreground="#89b4fa"/>

                    <!-- Results area -->
                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="16">
                        <StackPanel x:Name="pnlResults">
                            <TextBlock x:Name="txtPlaceholder"
                                       Text="Enter a server name and select a template, then click Run QA."
                                       Foreground="#6c7086" FontSize="14"
                                       HorizontalAlignment="Center" Margin="0,40,0,0"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>

            <!-- TAB: Raw Data -->
            <TabItem Header="Raw Data">
                <TextBox x:Name="txtRawData" IsReadOnly="True"
                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                         AcceptsReturn="True"
                         Background="#181825" Foreground="#a6e3a1"
                         FontFamily="Consolas" FontSize="12"
                         Padding="16"/>
            </TabItem>
        </TabControl>

        <!-- Status Bar -->
        <Border Grid.Row="2" Background="#181825" Padding="12,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" x:Name="statusText" Foreground="#a6adc8"
                           FontSize="12" Text="Ready" VerticalAlignment="Center"/>
                <Button Grid.Column="1" x:Name="btnRemovePatch" Content="Remove From Patch Group"
                        Margin="0,0,8,0" IsEnabled="False"/>
                <Button Grid.Column="2" x:Name="btnExportHtml" Content="Export HTML"
                        Margin="0,0,8,0" IsEnabled="False"/>
                <Button Grid.Column="3" x:Name="btnExportCsv" Content="Export CSV"
                        IsEnabled="False"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

# ---------------------------------------------------------------------------
# Window creation and control mapping
# ---------------------------------------------------------------------------

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Map all named controls
$xaml.SelectNodes('//*[@*[contains(translate(name(),"x","X"),"Name")]]') | ForEach-Object {
    $name = $_.Name
    if (-not $name) { $name = $_.'x:Name' }
    if ($name) {
        Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
    }
}

# ---------------------------------------------------------------------------
# State variables
# ---------------------------------------------------------------------------

$script:CurrentResults    = $null
$script:CurrentServerData = $null
$script:Templates         = @{}
$script:IsRunning         = $false
$script:Credential        = $null
$script:CredentialSplat   = @{}
$script:PatchGroups       = @(
    @{ Name = 'Patch-nsm-newserverbuild'; Domain = 'DOMAIN1.REDACTED' }
    @{ Name = 'Patch-gov-newserverbuild'; Domain = 'DOMAIN1.REDACTED' }
    @{ Name = 'Patch-Newserverbuild'; Domain = 'DOMAIN2.REDACTED' }
)

# ---------------------------------------------------------------------------
# Helper: BrushConverter shorthand
# ---------------------------------------------------------------------------

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter

function New-Brush {
    param([string]$Hex)
    $script:BrushConverter.ConvertFromString($Hex)
}

# ---------------------------------------------------------------------------
# Helper: Status bar and status light
# ---------------------------------------------------------------------------

function Set-Status {
    param([string]$Message, [string]$Color = '#a6adc8')
    $statusText.Text = $Message
    $statusText.Foreground = New-Brush $Color
}

function Set-StatusLight {
    param(
        [ValidateSet('idle','running','pass','fail','mixed')]
        [string]$State
    )
    switch ($State) {
        'idle'    { $statusLight.Fill = New-Brush '#6c7086' }
        'running' { $statusLight.Fill = New-Brush '#f9e2af' }
        'pass'    { $statusLight.Fill = New-Brush '#a6e3a1' }
        'fail'    { $statusLight.Fill = New-Brush '#f38ba8' }
        'mixed'   { $statusLight.Fill = New-Brush '#f9e2af' }
    }
}

# ---------------------------------------------------------------------------
# Helper: Template loading
# ---------------------------------------------------------------------------

function Load-Templates {
    $script:Templates = @{}
    $cboTemplate.Items.Clear()

    $jsonFiles = Get-ChildItem -Path $templatesPath -Filter '*.json' -ErrorAction SilentlyContinue

    foreach ($file in $jsonFiles) {
        try {
            $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            $name = $content.templateName
            if (-not $name) { $name = $file.BaseName }
            $script:Templates[$name] = $content
            $cboTemplate.Items.Add($name) | Out-Null
        }
        catch {
            # Skip invalid template files
        }
    }

    if ($cboTemplate.Items.Count -gt 0) {
        $cboTemplate.SelectedIndex = 0
    }
}

# ---------------------------------------------------------------------------
# Helper: Summary bar update
# ---------------------------------------------------------------------------

function Update-SummaryBar {
    param([PSCustomObject[]]$Results)

    $passCount  = @($Results | Where-Object { $_.Status -eq 'Pass' }).Count
    $failCount  = @($Results | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount  = @($Results | Where-Object { $_.Status -eq 'Warn' }).Count
    $infoCount  = @($Results | Where-Object { $_.Status -eq 'Info' }).Count
    $errorCount = @($Results | Where-Object { $_.Status -eq 'Error' }).Count

    $lblPassCount.Text  = "Pass: $passCount"
    $lblFailCount.Text  = "Fail: $failCount"
    $lblWarnCount.Text  = "Warn: $warnCount"
    $lblInfoCount.Text  = "Info: $infoCount"
    $lblErrorCount.Text = "Error: $errorCount"

    $gradedCount = $passCount + $failCount
    if ($gradedCount -gt 0) {
        $pct = [math]::Round(($passCount / $gradedCount) * 100)
        $lblPassPct.Text = "$pct% Pass"
    }
    else {
        $lblPassPct.Text = ''
    }

    $pnlSummary.Visibility = 'Visible'
}

# ---------------------------------------------------------------------------
# Helper: Dynamic results panel builder
# ---------------------------------------------------------------------------

function New-ResultHeaderRow {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

    $col0 = New-Object System.Windows.Controls.ColumnDefinition
    $col0.Width = [System.Windows.GridLength]::new(160)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col3 = New-Object System.Windows.Controls.ColumnDefinition
    $col3.Width = [System.Windows.GridLength]::new(80)
    $grid.ColumnDefinitions.Add($col0)
    $grid.ColumnDefinitions.Add($col1)
    $grid.ColumnDefinitions.Add($col2)
    $grid.ColumnDefinitions.Add($col3)

    $headers = @('Check', 'Expected', 'Actual', 'Status')
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $headers[$i]
        $tb.Foreground = New-Brush '#89b4fa'
        $tb.FontWeight = 'SemiBold'
        $tb.FontSize = 12
        $tb.Margin = [System.Windows.Thickness]::new(4, 2, 4, 2)
        [System.Windows.Controls.Grid]::SetColumn($tb, $i)
        $grid.Children.Add($tb) | Out-Null
    }

    # Separator line
    $sep = New-Object System.Windows.Controls.Border
    $sep.BorderBrush = New-Brush '#45475a'
    $sep.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $sep.Margin = [System.Windows.Thickness]::new(0, 2, 0, 4)
    [System.Windows.Controls.Grid]::SetColumnSpan($sep, 4)
    $grid.Children.Add($sep) | Out-Null

    return $grid
}

function New-ResultRow {
    param([PSCustomObject]$Result)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)

    $col0 = New-Object System.Windows.Controls.ColumnDefinition
    $col0.Width = [System.Windows.GridLength]::new(160)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col3 = New-Object System.Windows.Controls.ColumnDefinition
    $col3.Width = [System.Windows.GridLength]::new(80)
    $grid.ColumnDefinitions.Add($col0)
    $grid.ColumnDefinitions.Add($col1)
    $grid.ColumnDefinitions.Add($col2)
    $grid.ColumnDefinitions.Add($col3)

    # Check name
    $tbName = New-Object System.Windows.Controls.TextBlock
    $tbName.Text = $Result.Category
    $tbName.Foreground = New-Brush '#cdd6f4'
    $tbName.FontSize = 12
    $tbName.Margin = [System.Windows.Thickness]::new(4, 4, 4, 4)
    $tbName.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetColumn($tbName, 0)
    $grid.Children.Add($tbName) | Out-Null

    # Expected
    $tbExpected = New-Object System.Windows.Controls.TextBlock
    $tbExpected.Text = $Result.Expected
    $tbExpected.Foreground = New-Brush '#a6adc8'
    $tbExpected.FontSize = 12
    $tbExpected.Margin = [System.Windows.Thickness]::new(4, 4, 4, 4)
    $tbExpected.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetColumn($tbExpected, 1)
    $grid.Children.Add($tbExpected) | Out-Null

    # Actual
    $tbActual = New-Object System.Windows.Controls.TextBlock
    $tbActual.Text = $Result.Actual
    $tbActual.Foreground = New-Brush '#cdd6f4'
    $tbActual.FontSize = 12
    $tbActual.Margin = [System.Windows.Thickness]::new(4, 4, 4, 4)
    $tbActual.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetColumn($tbActual, 2)
    $grid.Children.Add($tbActual) | Out-Null

    # Status badge
    $statusBorder = New-Object System.Windows.Controls.Border
    $statusBorder.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $statusBorder.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
    $statusBorder.Margin = [System.Windows.Thickness]::new(4, 4, 4, 4)
    $statusBorder.HorizontalAlignment = 'Left'
    $statusBorder.VerticalAlignment = 'Center'

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.Text = $Result.Status.ToUpper()
    $statusText.FontWeight = 'SemiBold'
    $statusText.FontSize = 11
    $statusText.Foreground = New-Brush '#1e1e2e'

    switch ($Result.Status) {
        'Pass'  { $statusBorder.Background = New-Brush '#a6e3a1' }
        'Fail'  { $statusBorder.Background = New-Brush '#f38ba8' }
        'Warn'  { $statusBorder.Background = New-Brush '#f9e2af' }
        'Info'  { $statusBorder.Background = New-Brush '#89b4fa' }
        'Error' { $statusBorder.Background = New-Brush '#f38ba8' }
        'Skip'  { $statusBorder.Background = New-Brush '#6c7086' }
        default { $statusBorder.Background = New-Brush '#6c7086' }
    }

    $statusBorder.Child = $statusText
    [System.Windows.Controls.Grid]::SetColumn($statusBorder, 3)
    $grid.Children.Add($statusBorder) | Out-Null

    # Tooltip with details
    if ($Result.Details) {
        $grid.ToolTip = $Result.Details
    }

    return $grid
}

function Build-ResultsPanel {
    param([PSCustomObject[]]$Results)

    $pnlResults.Children.Clear()

    # Group results by category display groups
    $categories = @(
        @{ Name = 'Connectivity';     Keys = @('connectivity', 'winActivation') }
        @{ Name = 'Hardware';         Keys = @('cpu', 'memoryGB') }
        @{ Name = 'Network';          Keys = @('ipConfig', 'traceroute') }
        @{ Name = 'Software';         Keys = @('installedSoftware', 'vmwareTools') }
        @{ Name = 'Security';         Keys = @('localAdmins') }
        @{ Name = 'Storage';          Keys = @('drivePermissions', 'fDrive') }
        @{ Name = 'Patching';         Keys = @('recentHotfixes') }
        @{ Name = 'Active Directory'; Keys = @('ouPath') }
    )

    foreach ($cat in $categories) {
        $catResults = @($Results | Where-Object { $_.CheckKey -in $cat.Keys -and $_.Status -ne 'Skip' -and $_.Category -ne 'Backend NIC' })
        if ($catResults.Count -eq 0) { continue }

        # GroupBox with pass/fail badge in header
        $catPass = @($catResults | Where-Object { $_.Status -eq 'Pass' }).Count
        $catFail = @($catResults | Where-Object { $_.Status -eq 'Fail' }).Count
        $catError = @($catResults | Where-Object { $_.Status -eq 'Error' }).Count

        $headerPanel = New-Object System.Windows.Controls.StackPanel
        $headerPanel.Orientation = 'Horizontal'

        $headerText = New-Object System.Windows.Controls.TextBlock
        $headerText.Text = $cat.Name
        $headerText.VerticalAlignment = 'Center'
        $headerText.Foreground = New-Brush '#89b4fa'
        $headerPanel.Children.Add($headerText) | Out-Null

        if ($catFail -gt 0 -or $catError -gt 0) {
            $badgeBorder = New-Object System.Windows.Controls.Border
            $badgeBorder.Background = New-Brush '#f38ba8'
            $badgeBorder.CornerRadius = [System.Windows.CornerRadius]::new(3)
            $badgeBorder.Padding = [System.Windows.Thickness]::new(6, 1, 6, 1)
            $badgeBorder.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $badgeBorder.VerticalAlignment = 'Center'
            $badgeText = New-Object System.Windows.Controls.TextBlock
            $failTotal = $catFail + $catError
            $badgeText.Text = "$failTotal FAIL"
            $badgeText.FontSize = 10
            $badgeText.FontWeight = 'SemiBold'
            $badgeText.Foreground = New-Brush '#1e1e2e'
            $badgeBorder.Child = $badgeText
            $headerPanel.Children.Add($badgeBorder) | Out-Null
        }
        elseif ($catPass -gt 0) {
            $badgeBorder = New-Object System.Windows.Controls.Border
            $badgeBorder.Background = New-Brush '#a6e3a1'
            $badgeBorder.CornerRadius = [System.Windows.CornerRadius]::new(3)
            $badgeBorder.Padding = [System.Windows.Thickness]::new(6, 1, 6, 1)
            $badgeBorder.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $badgeBorder.VerticalAlignment = 'Center'
            $badgeText = New-Object System.Windows.Controls.TextBlock
            $badgeText.Text = "ALL PASS"
            $badgeText.FontSize = 10
            $badgeText.FontWeight = 'SemiBold'
            $badgeText.Foreground = New-Brush '#1e1e2e'
            $badgeBorder.Child = $badgeText
            $headerPanel.Children.Add($badgeBorder) | Out-Null
        }

        $gb = New-Object System.Windows.Controls.GroupBox
        $gb.Header = $headerPanel
        $gb.Foreground = New-Brush '#89b4fa'
        $gb.BorderBrush = New-Brush '#45475a'
        $gb.Padding = [System.Windows.Thickness]::new(10)
        $gb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

        $sp = New-Object System.Windows.Controls.StackPanel

        # Header row
        $sp.Children.Add((New-ResultHeaderRow)) | Out-Null

        # Data rows
        $adapterSeen = $false
        foreach ($r in $catResults) {
            # Add separator between adapters in Network category
            if ($cat.Name -eq 'Network' -and $r.Category -eq 'Adapter') {
                if ($adapterSeen) {
                    $sep = New-Object System.Windows.Controls.Border
                    $sep.BorderBrush = New-Brush '#45475a'
                    $sep.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
                    $sep.Margin = [System.Windows.Thickness]::new(4, 6, 4, 6)
                    $sp.Children.Add($sep) | Out-Null
                }
                $adapterSeen = $true
            }
            $sp.Children.Add((New-ResultRow -Result $r)) | Out-Null
        }

        $gb.Content = $sp
        $pnlResults.Children.Add($gb) | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Event: Set / Clear alternate credentials
# ---------------------------------------------------------------------------

$btnCredential.Add_Click({
    $cred = Get-Credential -Message 'Enter alternate credentials for remote server access'
    if ($cred) {
        $script:Credential      = $cred
        $script:CredentialSplat = @{ Credential = $cred }
        $btnCredential.Content    = $cred.UserName
        $btnCredential.Background = New-Brush '#fab387'
        $btnCredential.Foreground = New-Brush '#1e1e2e'
    }
})

$btnCredential.Add_MouseRightButtonUp({
    $script:Credential      = $null
    $script:CredentialSplat = @{}
    $btnCredential.Content    = 'Credentials'
    $btnCredential.Background = New-Brush '#45475a'
    $btnCredential.Foreground = New-Brush '#a6adc8'
})

# ---------------------------------------------------------------------------
# Event: Run QA
# ---------------------------------------------------------------------------

$btnRunQa.Add_Click({
    $server = $txtServer.Text.Trim()
    if (-not $server) {
        [System.Windows.MessageBox]::Show('Enter a server name.', 'Validation', 'OK', 'Warning')
        return
    }

    $templateName = $cboTemplate.SelectedItem
    if (-not $templateName) {
        [System.Windows.MessageBox]::Show('Select a check template.', 'Validation', 'OK', 'Warning')
        return
    }

    $template = $script:Templates[$templateName]
    if (-not $template) {
        [System.Windows.MessageBox]::Show('Template not found.', 'Error', 'OK', 'Error')
        return
    }

    # Reset UI
    $script:IsRunning = $true
    $btnRunQa.IsEnabled = $false
    $btnExportHtml.IsEnabled = $false
    $btnExportCsv.IsEnabled = $false
    $btnRemovePatch.IsEnabled = $false
    $chkFailOnly.IsEnabled = $false
    Set-StatusLight 'running'
    Set-Status "Running QA checks on $server..." '#f9e2af'
    $progressBar.Visibility = 'Visible'
    $pnlSummary.Visibility = 'Collapsed'
    $pnlResults.Children.Clear()

    # Force UI refresh
    $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})

    try {
        # Determine traceroute target from template
        $traceTarget = 'DOMAIN1.REDACTED'
        if ($template.checks.traceroute -and $template.checks.traceroute.target) {
            $traceTarget = $template.checks.traceroute.target
        }

        # Collect data
        Set-Status "Collecting data from $server..." '#f9e2af'
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})

        $script:CurrentServerData = Get-QaServerData -ComputerName $server -TracerouteTarget $traceTarget @script:CredentialSplat

        # Validate
        Set-Status "Validating results against template '$templateName'..." '#f9e2af'
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})

        $script:CurrentResults = Invoke-QaValidation -ServerData $script:CurrentServerData -Template $template

        # Build results UI
        Build-ResultsPanel -Results $script:CurrentResults
        Update-SummaryBar -Results $script:CurrentResults

        # Populate raw data tab
        $rawJson = $script:CurrentServerData | ConvertTo-Json -Depth 10
        $txtRawData.Text = $rawJson

        # Set final status
        $passCount = @($script:CurrentResults | Where-Object { $_.Status -eq 'Pass' }).Count
        $failCount = @($script:CurrentResults | Where-Object { $_.Status -eq 'Fail' }).Count
        $gradedCount = $passCount + $failCount
        $pct = if ($gradedCount -gt 0) { [math]::Round(($passCount / $gradedCount) * 100) } else { 0 }

        if ($failCount -eq 0 -and @($script:CurrentResults | Where-Object { $_.Status -eq 'Error' }).Count -eq 0) {
            Set-StatusLight 'pass'
            Set-Status "QA complete for $server - All checks passed ($passCount/$gradedCount)" '#a6e3a1'
            $btnRemovePatch.IsEnabled = $true
        }
        elseif ($failCount -gt 0) {
            Set-StatusLight 'fail'
            Set-Status "QA complete for $server - $failCount failed, $passCount passed ($pct%)" '#f38ba8'
        }
        else {
            Set-StatusLight 'mixed'
            Set-Status "QA complete for $server - $passCount/$gradedCount passed with some errors" '#f9e2af'
        }

        $btnExportHtml.IsEnabled = $true
        $btnExportCsv.IsEnabled = $true
        $chkFailOnly.IsEnabled = $true
        $chkFailOnly.IsChecked = $false
    }
    catch {
        [System.Windows.MessageBox]::Show("QA check failed: $($_.Exception.Message)", 'QA Error', 'OK', 'Error')
        Set-Status 'QA check failed' '#f38ba8'
        Set-StatusLight 'fail'
    }
    finally {
        $script:IsRunning = $false
        $btnRunQa.IsEnabled = $true
        $progressBar.Visibility = 'Collapsed'
    }
})

# ---------------------------------------------------------------------------
# Event: Enter key on server name triggers Run QA
# ---------------------------------------------------------------------------

$txtServer.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') {
        $btnRunQa.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }
})

$txtServer.Add_TextChanged({ $txtServerHint.Visibility = if ($txtServer.Text) { 'Hidden' } else { 'Visible' } })
$txtServer.Add_GotFocus({   $txtServerHint.Visibility = 'Hidden' })
$txtServer.Add_LostFocus({  $txtServerHint.Visibility = if ($txtServer.Text) { 'Hidden' } else { 'Visible' } })

# ---------------------------------------------------------------------------
# Event: Fail-only filter toggle
# ---------------------------------------------------------------------------

$chkFailOnly.Add_Checked({
    if (-not $script:CurrentResults) { return }
    $filtered = @($script:CurrentResults | Where-Object { $_.Status -in @('Fail', 'Error', 'Warn') })
    Build-ResultsPanel -Results $filtered
})

$chkFailOnly.Add_Unchecked({
    if (-not $script:CurrentResults) { return }
    Build-ResultsPanel -Results $script:CurrentResults
    Update-SummaryBar -Results $script:CurrentResults
})

# Event: Remove From Patch Group

$btnRemovePatch.Add_Click({
    $server = $txtServer.Text.Trim()
    if (-not $server) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        "Confirm removal of '$server' from NewServerBuild patch group?",
        'Confirm Patch Group Removal',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $btnRemovePatch.IsEnabled = $false
    Set-Status "Removing $server from patch lifecycle groups..." '#f9e2af'

    try {
        $results = Remove-ServerFromPatchGroups -ComputerFQDN $server -PatchGroups $script:PatchGroups @script:CredentialSplat -ErrorAction Stop
        if ($results) {
            [System.Windows.MessageBox]::Show(
                'Success!',
                'Patch Group Removal Complete',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            Set-Status "Patch group removal complete for $server" '#a6e3a1'
        }
        else {
            [System.Windows.MessageBox]::Show(
                'Server was not a member of any patch lifecycle groups.',
                'No Changes Required',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            Set-Status "No patch group changes required for $server" '#a6adc8'
        }
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            'Patch Group Removal Failed',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
        Set-Status 'Patch group removal failed' '#f38ba8'
    }
    finally {
        $btnRemovePatch.IsEnabled = $true
    }
})

# Event: Export HTML

$btnExportHtml.Add_Click({
    if (-not $script:CurrentResults) { return }

    $server = $txtServer.Text.Trim()
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $filename = "QA-${server}-${timestamp}.html"
    $path = Join-Path $reportsPath $filename

    try {
        Export-QaResultsHtml -ComputerName $server -Results $script:CurrentResults `
            -TemplateName $cboTemplate.SelectedItem -OutputPath $path

        Set-Status "Report exported: $filename" '#a6e3a1'
        Start-Process $path
    }
    catch {
        [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'Export Error', 'OK', 'Error')
    }
})

# ---------------------------------------------------------------------------
# Event: Export CSV
# ---------------------------------------------------------------------------

$btnExportCsv.Add_Click({
    if (-not $script:CurrentResults) { return }

    $server = $txtServer.Text.Trim()
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $filename = "QA-${server}-${timestamp}.csv"
    $path = Join-Path $reportsPath $filename

    try {
        Export-QaResultsCsv -ComputerName $server -Results $script:CurrentResults -OutputPath $path

        Set-Status "CSV exported: $filename" '#a6e3a1'
        Start-Process $path
    }
    catch {
        [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'Export Error', 'OK', 'Error')
    }
})

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

Load-Templates
$window.ShowDialog() | Out-Null
