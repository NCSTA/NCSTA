[CmdletBinding()]
param(
    [Parameter()]
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
$applicationRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    (Get-Location).Path
} else {
    $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $applicationRoot 'config\AgpmScheduler.config.json'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$modulePath = Join-Path $applicationRoot 'modules\AgpmScheduler\AgpmScheduler.psd1'
Import-Module $modulePath -Force
$script:Config = Get-AgpmSchedulerConfig -Path $ConfigPath
Initialize-AgpmSchedulerData -Config $script:Config | Out-Null
$script:GpoRows = @()

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AGPM Deployment Scheduler"
    Width="1100"
    Height="780"
    MinWidth="900"
    MinHeight="680"
    WindowStartupLocation="CenterScreen"
    Background="#0F1720"
    Foreground="#E7EDF3"
    FontFamily="Segoe UI"
    FontSize="13"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True">
    <Window.Resources>
        <SolidColorBrush x:Key="WindowBrush" Color="#0F1720"/>
        <SolidColorBrush x:Key="SurfaceBrush" Color="#18222D"/>
        <SolidColorBrush x:Key="InputBrush" Color="#111A23"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#354453"/>
        <SolidColorBrush x:Key="TextBrush" Color="#E7EDF3"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#A2B0BE"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#2F73EA"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#3E82F4"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Padding" Value="0"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource InputBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Height" Value="32"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="{StaticResource InputBrush}"/>
            <Setter Property="Foreground" Value="#111111"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="Padding" Value="7,4"/>
            <Setter Property="Height" Value="32"/>
        </Style>
        <Style TargetType="DatePicker">
            <Setter Property="Background" Value="{StaticResource InputBrush}"/>
            <Setter Property="Foreground" Value="#111111"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="Height" Value="32"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#FFFFFF"/>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Padding" Value="16,7"/>
            <Setter Property="MinHeight" Value="34"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource AccentHoverBrush}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="MinHeight" Value="32"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="{StaticResource WindowBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="Background" Value="#111A23"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="Padding" Value="18,9"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border
                            x:Name="TabBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="1,1,1,0"
                            Padding="{TemplateBinding Padding}">
                            <ContentPresenter
                                ContentSource="Header"
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="#18222D"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="#223140"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="{StaticResource InputBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="RowBackground" Value="{StaticResource InputBrush}"/>
            <Setter Property="AlternatingRowBackground" Value="#16222C"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#17324D"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="Padding" Value="9,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="8,6"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#284C70"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="78"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="34"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#17324D">
            <StackPanel Margin="28,12,20,8">
                <TextBlock
                    Text="AGPM Deployment Scheduler"
                    FontSize="24"
                    FontWeight="SemiBold"
                    Foreground="White"/>
                <TextBlock
                    Text="Schedule approved, checked-in Group Policy deployments"
                    Margin="1,3,0,0"
                    Foreground="#C9D8E8"/>
            </StackPanel>
        </Border>

        <TabControl Grid.Row="1" Margin="14,10,14,0">
            <TabItem Header="Schedule Deployment">
                <Border
                    Background="{StaticResource SurfaceBrush}"
                    BorderBrush="{StaticResource BorderBrush}"
                    BorderThickness="1"
                    Padding="24">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*" MinHeight="150"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="130"/>
                            <ColumnDefinition Width="*" MinWidth="250"/>
                            <ColumnDefinition Width="20"/>
                            <ColumnDefinition Width="130"/>
                            <ColumnDefinition Width="*" MinWidth="180"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Row="0" Grid.ColumnSpan="5" Margin="0,0,0,17">
                            <TextBlock
                                Text="Deployment details"
                                FontSize="18"
                                FontWeight="SemiBold"
                                Foreground="#8BB7E0"/>
                            <TextBlock
                                Text="Select a domain, load its checked-in GPOs, and choose a deployment window."
                                Margin="0,5,0,0"
                                Foreground="{StaticResource MutedBrush}"/>
                        </StackPanel>

                        <Label Grid.Row="1" Grid.Column="0" Content="Domain"/>
                        <ComboBox
                            x:Name="DomainBox"
                            Grid.Row="1"
                            Grid.Column="1"
                            Grid.ColumnSpan="2"
                            Margin="0,0,14,12"/>
                        <Button
                            x:Name="LoadButton"
                            Grid.Row="1"
                            Grid.Column="3"
                            Grid.ColumnSpan="2"
                            Content="Load checked-in GPOs"
                            Margin="0,0,0,12"
                            Style="{StaticResource PrimaryButton}"/>

                        <Label
                            Grid.Row="2"
                            Grid.Column="0"
                            Content="Available GPOs"
                            VerticalContentAlignment="Top"
                            Padding="0,7,0,0"/>
                        <Border
                            Grid.Row="2"
                            Grid.Column="1"
                            Grid.ColumnSpan="3"
                            Background="{StaticResource InputBrush}"
                            BorderBrush="{StaticResource BorderBrush}"
                            BorderThickness="1"
                            Margin="0,0,14,14">
                            <ListBox
                                x:Name="GpoList"
                                Background="Transparent"
                                BorderThickness="0"
                                Foreground="{StaticResource TextBrush}"
                                Padding="6"/>
                        </Border>
                        <StackPanel Grid.Row="2" Grid.Column="4" Margin="0,0,0,14">
                            <TextBlock
                                x:Name="SelectionLabel"
                                Text="0 selected"
                                HorizontalAlignment="Center"
                                Foreground="{StaticResource MutedBrush}"
                                Margin="0,4,0,12"/>
                            <Button
                                x:Name="SelectAllButton"
                                Content="Select all"
                                Margin="0,0,0,8"
                                Style="{StaticResource SecondaryButton}"/>
                            <Button
                                x:Name="ClearButton"
                                Content="Clear"
                                Style="{StaticResource SecondaryButton}"/>
                        </StackPanel>

                        <Label Grid.Row="3" Grid.Column="0" Content="Scheduled date"/>
                        <DatePicker
                            x:Name="ScheduleDate"
                            Grid.Row="3"
                            Grid.Column="1"
                            Margin="0,0,0,10"/>
                        <Label Grid.Row="3" Grid.Column="3" Content="Scheduled time"/>
                        <TextBox
                            x:Name="ScheduleTime"
                            Grid.Row="3"
                            Grid.Column="4"
                            Text="09:00 PM"
                            Margin="0,0,0,10"/>

                        <Label Grid.Row="4" Grid.Column="0" Content="Change ticket"/>
                        <TextBox
                            x:Name="TicketBox"
                            Grid.Row="4"
                            Grid.Column="1"
                            Margin="0,0,0,10"/>
                        <Label Grid.Row="4" Grid.Column="3" Content="Comment"/>
                        <TextBox
                            x:Name="CommentBox"
                            Grid.Row="4"
                            Grid.Column="4"
                            Margin="0,0,0,10"/>

                        <Label Grid.Row="5" Grid.Column="0" Content="Notify recipients"/>
                        <StackPanel Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="4">
                            <TextBox x:Name="NotifyBox"/>
                            <TextBlock
                                Text="Separate multiple email addresses with commas"
                                Margin="2,4,0,9"
                                FontSize="11"
                                Foreground="{StaticResource MutedBrush}"/>
                        </StackPanel>

                        <Grid Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="4" Margin="0,4,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <CheckBox
                                x:Name="TestModeToggle"
                                Grid.Column="0"
                                VerticalAlignment="Center"
                                Foreground="#F6B95F"
                                FontWeight="SemiBold"
                                Content="Test mode - simulate deployment"/>
                            <Button
                                x:Name="ScheduleButton"
                                Grid.Column="2"
                                Width="220"
                                Content="Schedule deployment"
                                Style="{StaticResource PrimaryButton}"/>
                        </Grid>
                    </Grid>
                </Border>
            </TabItem>

            <TabItem Header="Pending Deployments">
                <Border
                    Background="{StaticResource SurfaceBrush}"
                    BorderBrush="{StaticResource BorderBrush}"
                    BorderThickness="1"
                    Padding="24">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <StackPanel Grid.Row="0" Margin="0,0,0,16">
                            <TextBlock
                                Text="Pending deployments"
                                FontSize="18"
                                FontWeight="SemiBold"
                                Foreground="#8BB7E0"/>
                            <TextBlock
                                Text="Review or cancel jobs that have not started processing."
                                Margin="0,5,0,0"
                                Foreground="{StaticResource MutedBrush}"/>
                        </StackPanel>
                        <DataGrid
                            x:Name="JobsGrid"
                            Grid.Row="1"
                            SelectionMode="Single"
                            SelectionUnit="FullRow">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Scheduled" Binding="{Binding ScheduledAt}" Width="1.4*"/>
                                <DataGridTextColumn Header="Mode" Binding="{Binding Mode}" Width="0.6*"/>
                                <DataGridTextColumn Header="Change ticket" Binding="{Binding ChangeTicket}" Width="1.2*"/>
                                <DataGridTextColumn Header="Requested by" Binding="{Binding RequestedBy}" Width="1.5*"/>
                                <DataGridTextColumn Header="GPOs" Binding="{Binding GpoCount}" Width="0.5*"/>
                                <DataGridTextColumn Header="Job ID" Binding="{Binding JobId}" Width="2*"/>
                            </DataGrid.Columns>
                        </DataGrid>
                        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,14,0,0">
                            <Button
                                x:Name="RefreshJobsButton"
                                Width="120"
                                Content="Refresh"
                                Margin="0,0,10,0"
                                Style="{StaticResource SecondaryButton}"/>
                            <Button
                                x:Name="CancelJobButton"
                                Width="150"
                                Content="Cancel selected"
                                Foreground="#FF8A80"
                                Style="{StaticResource SecondaryButton}"/>
                        </StackPanel>
                    </Grid>
                </Border>
            </TabItem>
        </TabControl>

        <Border Grid.Row="2" Background="#101820" Padding="18,7">
            <TextBlock
                x:Name="StatusLabel"
                Text="Ready"
                Foreground="{StaticResource MutedBrush}"/>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$domainBox = $window.FindName('DomainBox')
$loadButton = $window.FindName('LoadButton')
$gpoList = $window.FindName('GpoList')
$selectionLabel = $window.FindName('SelectionLabel')
$selectAllButton = $window.FindName('SelectAllButton')
$clearButton = $window.FindName('ClearButton')
$scheduleDate = $window.FindName('ScheduleDate')
$scheduleTime = $window.FindName('ScheduleTime')
$ticketBox = $window.FindName('TicketBox')
$commentBox = $window.FindName('CommentBox')
$notifyBox = $window.FindName('NotifyBox')
$testModeToggle = $window.FindName('TestModeToggle')
$scheduleButton = $window.FindName('ScheduleButton')
$jobsGrid = $window.FindName('JobsGrid')
$refreshJobsButton = $window.FindName('RefreshJobsButton')
$cancelJobButton = $window.FindName('CancelJobButton')
$statusLabel = $window.FindName('StatusLabel')

foreach ($domain in @($script:Config.Domains | Where-Object Enabled)) {
    [void]$domainBox.Items.Add([string]$domain.Name)
}
if ($domainBox.Items.Count -gt 0) {
    $domainBox.SelectedIndex = 0
}
$scheduleDate.SelectedDate = (Get-Date).Date.AddDays(1)
$testModeToggle.IsChecked = [bool]$script:Config.Runner.WhatIf

function Set-Status {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Normal', 'Success', 'Error')]
        [string] $Kind = 'Normal'
    )
    $statusLabel.Text = $Message
    $statusLabel.Foreground = switch ($Kind) {
        'Success' { [Windows.Media.Brushes]::LightGreen }
        'Error' { [Windows.Media.Brushes]::Salmon }
        default { [Windows.Media.Brushes]::LightSlateGray }
    }
}

function Update-SelectionCount {
    $count = @($gpoList.Items | Where-Object IsChecked).Count
    $selectionLabel.Text = "$count selected"
}

function Refresh-PendingJobs {
    $rows = @(Get-AgpmDeploymentJob -Config $script:Config -Status Pending |
        Sort-Object { [datetime]$_.ScheduledAt } |
        ForEach-Object {
            [pscustomobject]@{
                JobId = $_.JobId
                ScheduledAt = ([datetime]$_.ScheduledAt).ToString('yyyy-MM-dd hh:mm tt')
                Mode = if ($null -ne $_.PSObject.Properties['WhatIf'] -and $_.WhatIf) {
                    'Test'
                } else {
                    'Live'
                }
                ChangeTicket = $_.ChangeTicket
                RequestedBy = $_.RequestedBy
                GpoCount = @($_.Gpos).Count
            }
        })
    $jobsGrid.ItemsSource = $null
    $jobsGrid.ItemsSource = $rows
}

$loadButton.Add_Click({
    try {
        if (-not $domainBox.SelectedItem) {
            throw 'Select a domain first.'
        }
        $window.Cursor = [Windows.Input.Cursors]::Wait
        $domain = [string]$domainBox.SelectedItem
        $script:GpoRows = @(Get-AgpmControlledGpo -Domain $domain |
            Where-Object State -eq 'CHECKED_IN' |
            Sort-Object Name |
            ForEach-Object {
                Add-Member -InputObject $_ -NotePropertyName Domain -NotePropertyValue $domain -Force
                $_
            })

        $gpoList.Items.Clear()
        for ($index = 0; $index -lt $script:GpoRows.Count; $index++) {
            $gpo = $script:GpoRows[$index]
            $checkBox = New-Object Windows.Controls.CheckBox
            $checkBox.Content = '{0}  [{1}]' -f $gpo.Name, $gpo.ID
            $checkBox.Tag = $index
            $checkBox.Foreground = [Windows.Media.Brushes]::Gainsboro
            $checkBox.Margin = New-Object Windows.Thickness(5, 4, 5, 4)
            $checkBox.Add_Checked({ Update-SelectionCount })
            $checkBox.Add_Unchecked({ Update-SelectionCount })
            [void]$gpoList.Items.Add($checkBox)
        }
        Update-SelectionCount
        Set-Status "Loaded $($script:GpoRows.Count) checked-in GPOs." Success
    } catch {
        Set-Status $_.Exception.Message Error
        [Windows.MessageBox]::Show(
            $_.Exception.Message, 'Load failed', 'OK', 'Error') | Out-Null
    } finally {
        $window.Cursor = [Windows.Input.Cursors]::Arrow
    }
})

$selectAllButton.Add_Click({
    foreach ($item in $gpoList.Items) {
        $item.IsChecked = $true
    }
    Update-SelectionCount
})

$clearButton.Add_Click({
    foreach ($item in $gpoList.Items) {
        $item.IsChecked = $false
    }
    Update-SelectionCount
})

$testModeToggle.Add_Checked({
    $testModeToggle.Content = 'Test mode - simulate deployment'
    $testModeToggle.Foreground = [Windows.Media.Brushes]::SandyBrown
})
$testModeToggle.Add_Unchecked({
    $testModeToggle.Content = 'Live mode - publish GPOs'
    $testModeToggle.Foreground = [Windows.Media.Brushes]::LightGreen
})
if (-not $testModeToggle.IsChecked) {
    $testModeToggle.Content = 'Live mode - publish GPOs'
    $testModeToggle.Foreground = [Windows.Media.Brushes]::LightGreen
}

$scheduleButton.Add_Click({
    try {
        $selected = foreach ($item in $gpoList.Items) {
            if ($item.IsChecked) {
                $script:GpoRows[[int]$item.Tag]
            }
        }
        if (-not $selected) {
            throw 'Select at least one GPO.'
        }
        if ([string]::IsNullOrWhiteSpace($ticketBox.Text)) {
            throw 'Enter a change-ticket number.'
        }
        if (-not $scheduleDate.SelectedDate) {
            throw 'Select a deployment date.'
        }

        $parsedTime = [datetime]::MinValue
        if (-not [datetime]::TryParse(
            $scheduleTime.Text,
            [Globalization.CultureInfo]::CurrentCulture,
            [Globalization.DateTimeStyles]::NoCurrentDateDefault,
            [ref]$parsedTime)) {
            throw "Enter a valid time, such as '09:00 PM'."
        }
        $scheduledAt = $scheduleDate.SelectedDate.Value.Date.Add($parsedTime.TimeOfDay)

        if (-not $testModeToggle.IsChecked) {
            $answer = [Windows.MessageBox]::Show(
                'This job is in LIVE MODE and will publish the selected GPOs. Continue?',
                'Confirm live deployment job', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') {
                return
            }
        }

        $recipients = @($notifyBox.Text -split ',' | ForEach-Object Trim |
            Where-Object { $_ })
        $job = New-AgpmDeploymentJob -Config $script:Config `
            -ScheduledAt $scheduledAt `
            -RequestedBy ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -ChangeTicket $ticketBox.Text.Trim() `
            -Comment $commentBox.Text.Trim() `
            -NotifyTo $recipients `
            -TestMode ([bool]$testModeToggle.IsChecked) `
            -Selections @($selected)
        Set-Status "Scheduled job $($job.JobId) with $(@($job.Gpos).Count) GPO(s)." Success
        Refresh-PendingJobs
    } catch {
        Set-Status $_.Exception.Message Error
        [Windows.MessageBox]::Show(
            $_.Exception.Message, 'Scheduling failed', 'OK', 'Error') | Out-Null
    }
})

$refreshJobsButton.Add_Click({ Refresh-PendingJobs })
$cancelJobButton.Add_Click({
    try {
        if (-not $jobsGrid.SelectedItem) {
            throw 'Select a pending deployment first.'
        }
        $jobId = [string]$jobsGrid.SelectedItem.JobId
        $answer = [Windows.MessageBox]::Show(
            "Cancel pending job $jobId?", 'Confirm cancellation', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') {
            Stop-AgpmDeploymentJob -Config $script:Config -JobId $jobId `
                -Confirm:$false | Out-Null
            Refresh-PendingJobs
            Set-Status "Cancelled job $jobId." Success
        }
    } catch {
        Set-Status $_.Exception.Message Error
        [Windows.MessageBox]::Show(
            $_.Exception.Message, 'Cancellation failed', 'OK', 'Error') | Out-Null
    }
})

Refresh-PendingJobs
[void]$window.ShowDialog()
