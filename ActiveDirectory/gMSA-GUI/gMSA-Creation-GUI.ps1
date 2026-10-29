param(
    # Run every AD command as this account instead of the signed-in user.
    # Can also be set or changed from the window with "Use admin credentials".
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="gMSA Management Utility"
        Height="880"
        Width="1140"
        MinHeight="680"
        MinWidth="900"
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
        <SolidColorBrush x:Key="DangerBrush" Color="#D9534F" />
        <SolidColorBrush x:Key="WarningBrush" Color="#F0B429" />
        <SolidColorBrush x:Key="WarningPanelBrush" Color="#2A2418" />
        <SolidColorBrush x:Key="TextBrush" Color="#F3F5F7" />
        <SolidColorBrush x:Key="MutedTextBrush" Color="#AEB7C4" />
        <SolidColorBrush x:Key="InputBrush" Color="#111318" />

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
        </Style>
        <Style x:Key="CardHeading" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="FontSize" Value="15" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Margin" Value="0,0,0,4" />
        </Style>
        <Style x:Key="CardSubheading" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MutedTextBrush}" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="TextWrapping" Value="Wrap" />
            <Setter Property="Margin" Value="0,0,0,16" />
        </Style>
        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Margin" Value="0,0,0,6" />
        </Style>
        <Style x:Key="Hint" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MutedTextBrush}" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="TextWrapping" Value="Wrap" />
            <Setter Property="Margin" Value="0,0,0,16" />
        </Style>
        <Style x:Key="SummaryKey" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MutedTextBrush}" />
            <Setter Property="Margin" Value="0,0,16,6" />
        </Style>
        <Style x:Key="SummaryValue" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="FontFamily" Value="Consolas" />
            <Setter Property="TextWrapping" Value="Wrap" />
            <Setter Property="Margin" Value="0,0,0,6" />
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource PanelBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="8" />
            <Setter Property="Padding" Value="18" />
        </Style>
        <Style x:Key="Divider" TargetType="Border">
            <Setter Property="Height" Value="1" />
            <Setter Property="Background" Value="{StaticResource BorderBrush}" />
            <Setter Property="Margin" Value="0,16,0,16" />
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource InputBrush}" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="CaretBrush" Value="{StaticResource TextBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="8,6" />
            <Setter Property="Margin" Value="0,0,0,6" />
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="Margin" Value="0,0,16,8" />
        </Style>

        <!-- Buttons: blue for the main action, outlined for secondary actions, red for removals.
             Disabled buttons fade instead of turning white. -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderBrush" Value="Transparent" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="16,8" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.85" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.7" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.35" />
                                <Setter Property="Cursor" Value="Arrow" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource DangerBrush}" />
        </Style>

        <Style TargetType="ListView">
            <Setter Property="Background" Value="{StaticResource InputBrush}" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="SelectionMode" Value="Extended" />
        </Style>
        <!-- Own row template: the default one paints selected rows white, which hides the text. -->
        <Style TargetType="ListViewItem">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Padding" Value="2,4" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListViewItem">
                        <Border x:Name="RowBorder"
                                Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}"
                                                  Content="{TemplateBinding Content}" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RowBorder" Property="Background" Value="#2C3440" />
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="RowBorder" Property="Background" Value="#1F4E73" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="GridViewColumnHeader">
            <Setter Property="Foreground" Value="{StaticResource MutedTextBrush}" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GridViewColumnHeader">
                        <Grid>
                            <Border Background="{StaticResource PanelAltBrush}"
                                    BorderBrush="{StaticResource BorderBrush}"
                                    BorderThickness="0,0,1,1"
                                    Padding="8,6">
                                <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" />
                            </Border>
                            <Thumb x:Name="PART_HeaderGripper"
                                   HorizontalAlignment="Right"
                                   Width="8"
                                   Margin="0,0,-4,0"
                                   Cursor="SizeWE">
                                <Thumb.Template>
                                    <ControlTemplate TargetType="Thumb">
                                        <Border Background="Transparent" />
                                    </ControlTemplate>
                                </Thumb.Template>
                            </Thumb>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TabControl">
            <Setter Property="Background" Value="{StaticResource WindowBrush}" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Padding" Value="0,16,0,0" />
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
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Cursor" Value="SizeWE" />
            <Setter Property="HorizontalAlignment" Value="Stretch" />
            <Setter Property="VerticalAlignment" Value="Stretch" />
            <Setter Property="ResizeBehavior" Value="PreviousAndNext" />
            <Setter Property="ResizeDirection" Value="Columns" />
            <Setter Property="ShowsPreview" Value="False" />
            <Setter Property="ToolTip" Value="Drag to resize panels" />
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <TabControl Name="MainTabControl" Grid.Row="0">

            <!-- Create gMSA: 1 details, 2 review, 3 create -->
            <TabItem Header="Create gMSA">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="400" MinWidth="320" />
                        <ColumnDefinition Width="16" />
                        <ColumnDefinition Width="*" MinWidth="380" />
                    </Grid.ColumnDefinitions>
                    <GridSplitter Grid.Column="1" Style="{StaticResource SplitterStyle}" />

                    <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                        <Border Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Style="{StaticResource CardHeading}" Text="1 &#183; Account details" />
                                <TextBlock Style="{StaticResource CardSubheading}"
                                           Text="What to create, and which servers or accounts may use it." />

                                <TextBlock Style="{StaticResource FieldLabel}" Text="Domain" />
                                <TextBox Name="DomainTextBox" />
                                <TextBlock Style="{StaticResource Hint}"
                                           Text="Domain name or a specific domain controller, e.g. domain.com" />

                                <TextBlock Style="{StaticResource FieldLabel}" Text="gMSA name" />
                                <TextBox Name="ServiceNameTextBox" />
                                <TextBlock Style="{StaticResource Hint}"
                                           Text="Up to 15 characters, e.g. gMSA-sqlp100z (no trailing dollar sign)" />

                                <TextBlock Style="{StaticResource FieldLabel}" Text="Allowed principals" />
                                <TextBox Name="ServersTextBox"
                                         AcceptsReturn="True"
                                         VerticalScrollBarVisibility="Auto"
                                         Height="130"
                                         TextWrapping="Wrap" />
                                <TextBlock Style="{StaticResource Hint}"
                                           Text="One per line: the servers, service accounts, or groups that will use this gMSA, e.g. sqlserver01a or svc-sqlagent" />

                                <Button Name="AdvancedToggleButton"
                                        Style="{StaticResource SecondaryButton}"
                                        Content="Show advanced options"
                                        Padding="12,6"
                                        HorizontalAlignment="Left" />
                                <Border Name="AdvancedPanel"
                                        Visibility="Collapsed"
                                        Background="{StaticResource WarningPanelBrush}"
                                        BorderBrush="{StaticResource WarningBrush}"
                                        BorderThickness="1"
                                        CornerRadius="6"
                                        Padding="12"
                                        Margin="0,12,0,0">
                                    <StackPanel>
                                        <CheckBox Name="DelegationCheckBox"
                                                  Content="Enable unconstrained delegation"
                                                  Margin="0,0,0,8" />
                                        <TextBlock Foreground="{StaticResource WarningBrush}"
                                                   FontSize="12"
                                                   TextWrapping="Wrap"
                                                   Text="Unconstrained delegation lets this account impersonate any user to any service. Turn it on only when the application requires it and constrained delegation is not an option." />
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource Divider}" />
                                <WrapPanel>
                                    <Button Name="PreviewButton" Content="Review" Margin="0,0,10,0" />
                                    <Button Name="ResetButton" Style="{StaticResource SecondaryButton}" Content="Reset form" />
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                    </ScrollViewer>

                    <Grid Grid.Column="2">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Style="{StaticResource Card}" Margin="0,0,0,16">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="*" />
                                </Grid.RowDefinitions>
                                <TextBlock Grid.Row="0" Style="{StaticResource CardHeading}" Text="2 &#183; Review" />
                                <TextBlock Grid.Row="1"
                                           Style="{StaticResource CardSubheading}"
                                           Text="Review checks every entry against Active Directory. Nothing is changed until you select Create gMSA." />
                                <Grid Name="ReviewContentGrid" Grid.Row="2" Visibility="Collapsed">
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto" />
                                        <RowDefinition Height="*" />
                                        <RowDefinition Height="Auto" />
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0">
                                        <Grid Margin="0,0,0,10">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto" />
                                                <ColumnDefinition Width="*" />
                                            </Grid.ColumnDefinitions>
                                            <Grid.RowDefinitions>
                                                <RowDefinition Height="Auto" />
                                                <RowDefinition Height="Auto" />
                                                <RowDefinition Height="Auto" />
                                                <RowDefinition Height="Auto" />
                                            </Grid.RowDefinitions>
                                            <TextBlock Grid.Row="0" Style="{StaticResource SummaryKey}" Text="Account" />
                                            <TextBlock Grid.Row="0" Grid.Column="1" Name="SummaryAccountText" Style="{StaticResource SummaryValue}" />
                                            <TextBlock Grid.Row="1" Style="{StaticResource SummaryKey}" Text="DNS host name" />
                                            <TextBlock Grid.Row="1" Grid.Column="1" Name="SummaryDnsText" Style="{StaticResource SummaryValue}" />
                                            <TextBlock Grid.Row="2" Style="{StaticResource SummaryKey}" Text="Domain" />
                                            <TextBlock Grid.Row="2" Grid.Column="1" Name="SummaryDomainText" Style="{StaticResource SummaryValue}" />
                                            <TextBlock Grid.Row="3" Style="{StaticResource SummaryKey}" Text="Delegation" />
                                            <TextBlock Grid.Row="3" Grid.Column="1" Name="SummaryDelegationText" Style="{StaticResource SummaryValue}" />
                                        </Grid>
                                        <TextBlock Name="ReviewPrincipalsLabel" Style="{StaticResource FieldLabel}" />
                                    </StackPanel>
                                    <ListView Name="ReviewPrincipalsListView" Grid.Row="1" SelectionMode="Single">
                                        <ListView.View>
                                            <GridView>
                                                <GridViewColumn Header="Type" Width="120" DisplayMemberBinding="{Binding Type}" />
                                                <GridViewColumn Header="Name" Width="170" DisplayMemberBinding="{Binding Name}" />
                                                <GridViewColumn Header="Distinguished name" Width="420" DisplayMemberBinding="{Binding DistinguishedName}" />
                                            </GridView>
                                        </ListView.View>
                                    </ListView>
                                    <TextBox Name="PreviewTextBox"
                                             Grid.Row="1"
                                             Visibility="Collapsed"
                                             Margin="0"
                                             IsReadOnly="True"
                                             AcceptsReturn="True"
                                             VerticalScrollBarVisibility="Auto"
                                             HorizontalScrollBarVisibility="Auto"
                                             TextWrapping="NoWrap"
                                             FontFamily="Consolas" />
                                    <Button Name="ShowScriptButton"
                                            Grid.Row="2"
                                            Style="{StaticResource SecondaryButton}"
                                            Content="Show PowerShell"
                                            Padding="12,6"
                                            Margin="0,12,0,0"
                                            HorizontalAlignment="Left" />
                                </Grid>
                            </Grid>
                        </Border>

                        <Border Grid.Row="1" Style="{StaticResource Card}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Style="{StaticResource CardHeading}" Text="3 &#183; Create" />
                                    <TextBlock Name="CreateStatusText"
                                               Foreground="{StaticResource MutedTextBrush}"
                                               TextWrapping="Wrap" />
                                </StackPanel>
                                <Button Name="ExecuteButton"
                                        Grid.Column="1"
                                        Content="Create gMSA"
                                        VerticalAlignment="Center"
                                        Margin="16,0,0,0"
                                        IsEnabled="False" />
                            </Grid>
                        </Border>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- Manage gMSA: change principals and SPNs on an existing account -->
            <TabItem Name="ManageTab" Header="Manage gMSA">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Style="{StaticResource Card}" Margin="0,0,0,16">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="Auto" />
                            </Grid.RowDefinitions>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="16" />
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="16" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Row="0" Grid.Column="0" Style="{StaticResource FieldLabel}" Text="Domain" />
                            <TextBox Grid.Row="1" Grid.Column="0" Name="ManageDomainTextBox"
                                     ToolTip="Domain name or a specific domain controller, e.g. domain.com" />
                            <TextBlock Grid.Row="0" Grid.Column="2" Style="{StaticResource FieldLabel}" Text="gMSA name" />
                            <TextBox Grid.Row="1" Grid.Column="2" Name="ManageServiceNameTextBox"
                                     ToolTip="Without the trailing dollar sign, e.g. gMSA-sqlp100z" />
                            <Button Grid.Row="1" Grid.Column="4" Name="ManageLoadButton"
                                    Content="Load gMSA"
                                    Padding="16,0"
                                    Margin="0,0,0,6" />
                            <TextBlock Grid.Row="2" Grid.ColumnSpan="5" Name="ManageStatusTextBlock"
                                       Foreground="{StaticResource MutedTextBrush}"
                                       TextWrapping="Wrap"
                                       Margin="0,6,0,0" />
                        </Grid>
                    </Border>

                    <!-- Shared row sizes keep the two cards' buttons and inputs on the same lines.
                         The grid fills the window, and scrolls once the window is shorter than MinHeight. -->
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                    <Grid Grid.IsSharedSizeScope="True"
                          MinHeight="560"
                          Height="{Binding ViewportHeight, RelativeSource={RelativeSource AncestorType=ScrollViewer}}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" MinWidth="320" />
                            <ColumnDefinition Width="16" />
                            <ColumnDefinition Width="*" MinWidth="320" />
                        </Grid.ColumnDefinitions>
                        <GridSplitter Grid.Column="1" Style="{StaticResource SplitterStyle}" />

                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto" SharedSizeGroup="CardHeading" />
                                    <RowDefinition Height="*" MinHeight="80" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="RemoveRow" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddLabel" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddOptions" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddInput" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddButton" />
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0">
                                    <TextBlock Style="{StaticResource CardHeading}" Text="Allowed principals" />
                                    <TextBlock Style="{StaticResource CardSubheading}"
                                               Text="Servers, service accounts, and groups that can retrieve the password." />
                                </StackPanel>
                                <ListView Name="ManagePrincipalsListView"
                                          Grid.Row="1"
                                          ToolTip="Ctrl+click or Shift+click to select several entries.">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="Type" Width="120" DisplayMemberBinding="{Binding Type}" />
                                            <GridViewColumn Header="Name" Width="160" DisplayMemberBinding="{Binding Name}" />
                                            <GridViewColumn Header="Distinguished name" Width="400" DisplayMemberBinding="{Binding DistinguishedName}" />
                                        </GridView>
                                    </ListView.View>
                                </ListView>
                                <Button Name="ManageRemovePrincipalButton"
                                        Grid.Row="2"
                                        Style="{StaticResource DangerButton}"
                                        Content="Remove selected"
                                        HorizontalAlignment="Left"
                                        Margin="0,10,0,0"
                                        IsEnabled="False" />
                                <StackPanel Grid.Row="3">
                                    <Border Style="{StaticResource Divider}" />
                                    <TextBlock Style="{StaticResource FieldLabel}" Text="Add principals" />
                                </StackPanel>
                                <WrapPanel Grid.Row="4" Margin="0,2,0,0">
                                    <RadioButton Name="PrincipalTypeAutoRadio" GroupName="PrincipalType" Content="Auto-detect" IsChecked="True"
                                                 ToolTip="Match by name: service accounts and groups first, then computers." />
                                    <RadioButton Name="PrincipalTypeServerRadio" GroupName="PrincipalType" Content="Server" />
                                    <RadioButton Name="PrincipalTypeUserRadio" GroupName="PrincipalType" Content="Service Account" />
                                    <RadioButton Name="PrincipalTypeGroupRadio" GroupName="PrincipalType" Content="Group" />
                                    <RadioButton Name="PrincipalTypeGmsaRadio" GroupName="PrincipalType" Content="gMSA" />
                                </WrapPanel>
                                <StackPanel Grid.Row="5">
                                    <TextBox Name="ManageAddPrincipalTextBox"
                                             AcceptsReturn="True"
                                             VerticalScrollBarVisibility="Auto"
                                             Height="70"
                                             TextWrapping="Wrap" />
                                    <TextBlock Style="{StaticResource Hint}"
                                               Text="One name per line, e.g. sqlserver01c or svc-sqlagent" />
                                </StackPanel>
                                <Button Name="ManageAddPrincipalButton"
                                        Grid.Row="6"
                                        Content="Add principals"
                                        HorizontalAlignment="Left"
                                        IsEnabled="False" />
                            </Grid>
                        </Border>

                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto" SharedSizeGroup="CardHeading" />
                                    <RowDefinition Height="*" MinHeight="80" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="RemoveRow" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddLabel" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddOptions" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddInput" />
                                    <RowDefinition Height="Auto" SharedSizeGroup="AddButton" />
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0">
                                    <TextBlock Style="{StaticResource CardHeading}" Text="Service principal names (SPNs)" />
                                    <TextBlock Style="{StaticResource CardSubheading}"
                                               Text="Kerberos service names registered on this gMSA." />
                                </StackPanel>
                                <ListView Name="ManageSpnListView"
                                          Grid.Row="1"
                                          ToolTip="Ctrl+click or Shift+click to select several entries.">
                                    <ListView.View>
                                        <GridView>
                                            <GridViewColumn Header="SPN" Width="420" DisplayMemberBinding="{Binding Spn}" />
                                        </GridView>
                                    </ListView.View>
                                </ListView>
                                <Button Name="ManageRemoveSpnButton"
                                        Grid.Row="2"
                                        Style="{StaticResource DangerButton}"
                                        Content="Remove selected"
                                        HorizontalAlignment="Left"
                                        Margin="0,10,0,0"
                                        IsEnabled="False" />
                                <StackPanel Grid.Row="3">
                                    <Border Style="{StaticResource Divider}" />
                                    <TextBlock Style="{StaticResource FieldLabel}" Text="Add SPNs" />
                                </StackPanel>
                                <TextBlock Grid.Row="4"
                                           Foreground="{StaticResource MutedTextBrush}"
                                           TextWrapping="Wrap"
                                           Margin="0,2,0,8"
                                           Text="Format: service/host[:port]" />
                                <StackPanel Grid.Row="5">
                                    <TextBox Name="ManageAddSpnTextBox"
                                             AcceptsReturn="True"
                                             VerticalScrollBarVisibility="Auto"
                                             Height="70"
                                             TextWrapping="Wrap" />
                                    <TextBlock Style="{StaticResource Hint}"
                                               Text="One SPN per line, e.g. MSSQLSvc/sqlserver01a.domain.com:1433" />
                                </StackPanel>
                                <Button Name="ManageAddSpnButton"
                                        Grid.Row="6"
                                        Content="Add SPNs"
                                        HorizontalAlignment="Left"
                                        IsEnabled="False" />
                            </Grid>
                        </Border>
                    </Grid>
                    </ScrollViewer>
                </Grid>
            </TabItem>

            <TabItem Name="ConsoleLogTab" Header="Console Log">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <DockPanel Margin="0,0,0,12" LastChildFill="True">
                        <Button Name="ClearLogButton"
                                Style="{StaticResource SecondaryButton}"
                                Content="Clear log"
                                DockPanel.Dock="Left" />
                        <TextBlock VerticalAlignment="Center"
                                   Foreground="{StaticResource MutedTextBrush}"
                                   Margin="12,0,0,0"
                                   Text="Timestamps, step details, generated commands, and raw errors are shown here for troubleshooting." />
                    </DockPanel>
                    <TextBox Name="LogTextBox"
                             Grid.Row="1"
                             Margin="0"
                             IsReadOnly="True"
                             AcceptsReturn="True"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap"
                             FontFamily="Consolas" />
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Credentials button and status light, as in the Server QA Checker.
             Sits in the empty space to the right of the tab headers. -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button Name="CredentialButton"
                    Style="{StaticResource SecondaryButton}"
                    Content="Credentials"
                    Padding="12,5"
                    ToolTip="Left-click: set alternate credentials. Right-click: clear." />
            <Ellipse Name="CredentialStatusLight"
                     Width="12"
                     Height="12"
                     Margin="10,0,0,0"
                     VerticalAlignment="Center" />
        </StackPanel>

        <!-- Status bar, as in the BlueCat DNS Manager -->
        <Border Grid.Row="1" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush}"
                BorderThickness="1" CornerRadius="6" Padding="12,6" Margin="0,12,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <TextBlock Name="StatusText" Grid.Column="0" FontSize="12" VerticalAlignment="Center"
                           Foreground="{StaticResource MutedTextBrush}" />
                <TextBlock Name="UserText" Grid.Column="1" FontSize="12" VerticalAlignment="Center"
                           Foreground="{StaticResource MutedTextBrush}" />
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'MainTabControl',
    'ManageTab',
    'ConsoleLogTab',
    'DomainTextBox',
    'ServiceNameTextBox',
    'ServersTextBox',
    'AdvancedToggleButton',
    'AdvancedPanel',
    'DelegationCheckBox',
    'PreviewButton',
    'ResetButton',
    'ReviewContentGrid',
    'SummaryAccountText',
    'SummaryDnsText',
    'SummaryDomainText',
    'SummaryDelegationText',
    'ReviewPrincipalsLabel',
    'ReviewPrincipalsListView',
    'PreviewTextBox',
    'ShowScriptButton',
    'CreateStatusText',
    'ExecuteButton',
    'ManageDomainTextBox',
    'ManageServiceNameTextBox',
    'ManageLoadButton',
    'ManageStatusTextBlock',
    'ManagePrincipalsListView',
    'ManageRemovePrincipalButton',
    'PrincipalTypeAutoRadio',
    'PrincipalTypeServerRadio',
    'PrincipalTypeUserRadio',
    'PrincipalTypeGroupRadio',
    'PrincipalTypeGmsaRadio',
    'ManageAddPrincipalTextBox',
    'ManageAddPrincipalButton',
    'ManageSpnListView',
    'ManageRemoveSpnButton',
    'ManageAddSpnTextBox',
    'ManageAddSpnButton',
    'LogTextBox',
    'ClearLogButton',
    'CredentialButton',
    'CredentialStatusLight',
    'StatusText',
    'UserText'
)

$ui = @{}
foreach ($name in $controlNames) {
    $ui[$name] = $window.FindName($name)
}

$script:AppTitle = 'gMSA Management Utility'

# Set by Review and required by Create: the signature of the reviewed form and
# the principal DNs that were resolved for it, so Create runs exactly what was reviewed.
$script:PreviewSignature   = $null
$script:PreviewCommandText = ''
$script:ReviewedPrincipalDns = @()

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
        # Write-Log must never throw - silently swallow if the TextBox is unavailable
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
            $script:AppTitle,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    catch {
        try {
            [System.Windows.MessageBox]::Show(
                $Message,
                $script:AppTitle,
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        catch {
            Write-Log -Level 'ERROR' -Message ("Unable to show error dialog: {0}" -f $_.Exception.Message)
        }
    }
}

function Show-ValidationError {
    param([string]$Message)

    Write-Log -Level 'ERROR' -Message $Message
    Show-ErrorDialog -Message $Message
}

function Confirm-Change {
    param(
        [string]$Message,
        [string]$Title = 'Confirm Change'
    )

    $result = [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}

# Runs a button action so that no exception can escape and crash the WPF dispatcher.
function Invoke-UiAction {
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

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

$script:CurrentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$script:AdCredential    = $null
# Splatted into every AD cmdlet call, as in the Server QA Checker:
# empty runs as the signed-in user, @{ Credential = ... } runs as the alternate account.
$script:CredentialSplat = @{}

function New-Brush {
    param([string]$Color)
    [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-Status {
    param([string]$Message, [string]$Color = '#AEB7C4')
    $ui.StatusText.Text = $Message
    $ui.StatusText.Foreground = New-Brush $Color
}

# Status light: grey = signed-in user, amber = alternate credentials not yet
# checked against a domain, green = alternate credentials verified.
function Set-AdCredential {
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$Verified
    )

    # A review was checked under the previous account, so it no longer counts.
    Reset-PreviewState

    $button = $ui.CredentialButton
    if ($Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $script:AdCredential    = $Credential
        $script:CredentialSplat = @{ Credential = $Credential }
        $button.Content     = $Credential.UserName
        $button.Background  = New-Brush '#F0B429'
        $button.Foreground  = New-Brush '#18212B'
        $button.BorderBrush = New-Brush '#F0B429'
        $ui.UserText.Text   = 'User: {0} (alternate credentials)' -f $Credential.UserName
        $window.Title       = '{0} - {1}' -f $script:AppTitle, $Credential.UserName
        if ($Verified) {
            $ui.CredentialStatusLight.Fill = New-Brush '#3FB950'
        } else {
            $ui.CredentialStatusLight.Fill = New-Brush '#F0B429'
            Set-Status ('Using {0}. The credentials are checked on the first AD command.' -f $Credential.UserName) '#F0B429'
        }
        Write-Log -Level 'INFO' -Message ('AD commands now run as {0}.' -f $Credential.UserName)
    } else {
        $script:AdCredential    = $null
        $script:CredentialSplat = @{}
        $button.Content = 'Credentials'
        foreach ($property in [System.Windows.Controls.Control]::BackgroundProperty,
                              [System.Windows.Controls.Control]::ForegroundProperty,
                              [System.Windows.Controls.Control]::BorderBrushProperty) {
            $button.ClearValue($property)
        }
        $ui.CredentialStatusLight.Fill = New-Brush '#6C7086'
        $ui.UserText.Text = 'User: {0}' -f $script:CurrentUserName
        $window.Title     = $script:AppTitle
        Set-Status 'Using the signed-in account.'
        Write-Log -Level 'INFO' -Message ('AD commands now run as {0} (signed-in user).' -f $script:CurrentUserName)
    }
}

function Request-AdCredential {
    $credential = Get-Credential -Message 'Enter alternate credentials for Active Directory (DOMAIN\user or user@domain)'
    if (-not $credential) { return }

    # Check the account against whichever domain is already filled in, so a
    # mistyped password shows up now rather than halfway through a change.
    $domain = @($ui.ManageDomainTextBox.Text.Trim(), $ui.DomainTextBox.Text.Trim()) | Where-Object { $_ } | Select-Object -First 1
    if (-not $domain) {
        Set-AdCredential -Credential $credential
        return
    }

    Ensure-ActiveDirectoryModule
    Set-Status ("Checking {0} against {1}..." -f $credential.UserName, $domain) '#F0B429'
    Write-Log -Level 'STEP' -Message ("Checking credentials for {0} against '{1}'." -f $credential.UserName, $domain)
    try {
        Get-ADDomain -Server $domain -Credential $credential -ErrorAction Stop | Out-Null
    }
    catch {
        Set-Status ('Credential check failed for {0}.' -f $credential.UserName) '#D9534F'
        throw
    }
    Set-AdCredential -Credential $credential -Verified
    Set-Status ('Credentials verified against {0}.' -f $domain) '#3FB950'
}

function Ensure-ActiveDirectoryModule {
    if (-not (Get-Module -Name ActiveDirectory)) {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Log -Level 'STEP' -Message 'Imported ActiveDirectory module.'
    }
}

function Get-MultiLineValues {
    param([string]$Text)

    return @(
        $Text -split "(`r`n|`n|`r)" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
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
        'Server'         { return Get-ADComputer       -Identity $Name -Server $Domain @script:CredentialSplat -ErrorAction Stop }
        'ServiceAccount' { return Get-ADUser           -Identity $Name -Server $Domain @script:CredentialSplat -ErrorAction Stop }
        'Group'          { return Get-ADGroup          -Identity $Name -Server $Domain @script:CredentialSplat -ErrorAction Stop }
        'gMSA'           { return Get-ADServiceAccount -Identity $Name -Server $Domain @script:CredentialSplat -ErrorAction Stop }
    }

    $properties = @('sAMAccountName', 'objectClass')

    if ($Name -match '=.+,') {
        return Get-ADObject -Identity $Name -Server $Domain -Properties $properties @script:CredentialSplat -ErrorAction Stop
    }

    $escaped = ConvertTo-LdapFilterValue -Value $Name
    $found = @(Get-ADObject -LDAPFilter "(sAMAccountName=$escaped)" -Server $Domain -Properties $properties @script:CredentialSplat -ErrorAction Stop)

    # Computer accounts carry a trailing $, so fall back to that when the bare name has no match.
    if ($found.Count -eq 0 -and -not $Name.EndsWith('$')) {
        $found = @(Get-ADObject -LDAPFilter "(sAMAccountName=$escaped`$)" -Server $Domain -Properties $properties @script:CredentialSplat -ErrorAction Stop)
    }

    if ($found.Count -eq 0) {
        throw ("No server, service account, or group named '{0}' was found in '{1}'." -f $Name, $Domain)
    }
    if ($found.Count -gt 1) {
        throw ("'{0}' matched more than one object in '{1}'. Use the distinguished name instead." -f $Name, $Domain)
    }
    return $found[0]
}

function Get-PrincipalTypeLabel {
    param([string]$ObjectClass)

    switch ($ObjectClass) {
        'computer'                        { return 'Server' }
        'user'                            { return 'Service Account' }
        'msDS-GroupManagedServiceAccount' { return 'gMSA' }
        'msDS-ManagedServiceAccount'      { return 'MSA' }
        'group'                           { return 'Group' }
        default                           { return $ObjectClass }
    }
}

# One row of a principals table (Type / Name / Distinguished name).
function New-PrincipalRow {
    param([object]$Object)

    [pscustomobject]@{
        Type              = Get-PrincipalTypeLabel -ObjectClass $Object.ObjectClass
        Name              = [string]$Object.sAMAccountName
        DistinguishedName = [string]$Object.DistinguishedName
    }
}

function Get-PrincipalRow {
    param(
        [string]$DistinguishedName,
        [string]$Domain
    )

    try {
        $object = Get-ADObject -Identity $DistinguishedName -Server $Domain -Properties sAMAccountName, objectClass @script:CredentialSplat -ErrorAction Stop
        return New-PrincipalRow -Object $object
    }
    catch {
        return [pscustomobject]@{ Type = 'Unresolved'; Name = ''; DistinguishedName = $DistinguishedName }
    }
}

# ---------------------------------------------------------------------------
# Create gMSA tab
# ---------------------------------------------------------------------------

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
    if (-not $InputState.Domain)       { $issues.Add('Domain is required.') }
    if (-not $InputState.ServiceName)  { $issues.Add('gMSA name is required.') }
    elseif ($InputState.ServiceName.Length -gt 15) {
        $issues.Add(("gMSA name '{0}' is {1} characters; the limit is 15." -f $InputState.ServiceName, $InputState.ServiceName.Length))
    }
    if (-not $InputState.Servers -or $InputState.Servers.Count -eq 0) {
        $issues.Add('At least one allowed principal (server, service account, or group) is required.')
    }

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

function Reset-PreviewState {
    $hadReview = [bool]$script:PreviewSignature

    $script:PreviewSignature     = $null
    $script:PreviewCommandText   = ''
    $script:ReviewedPrincipalDns = @()
    $ui.ExecuteButton.IsEnabled  = $false
    $ui.ReviewContentGrid.Visibility = 'Collapsed'
    $ui.ReviewPrincipalsListView.ItemsSource = $null
    $ui.PreviewTextBox.Clear()

    $ui.CreateStatusText.Text = if ($hadReview) {
        'The details changed since the last review. Select Review again.'
    } else {
        'Fill in the account details, then select Review.'
    }
}

function Set-ReviewView {
    param([switch]$Script)

    if ($Script) {
        $ui.ReviewPrincipalsListView.Visibility = 'Collapsed'
        $ui.ReviewPrincipalsLabel.Text = 'PowerShell that Create gMSA will run'
        $ui.PreviewTextBox.Visibility = 'Visible'
        $ui.ShowScriptButton.Content = 'Show summary'
    } else {
        $ui.PreviewTextBox.Visibility = 'Collapsed'
        $ui.ReviewPrincipalsLabel.Text = 'Allowed to retrieve the password ({0})' -f $script:ReviewedPrincipalDns.Count
        $ui.ReviewPrincipalsListView.Visibility = 'Visible'
        $ui.ShowScriptButton.Content = 'Show PowerShell'
    }
}

# The exact PowerShell that Create gMSA runs, using the principal DNs resolved during Review.
function Format-Preview {
    param(
        [object]$InputState,
        [string[]]$PrincipalDns
    )

    $principalLines = ($PrincipalDns | ForEach-Object { "    '{0}'" -f ($_ -replace "'", "''") }) -join ",`r`n"

    # With alternate credentials active, every command carries -Credential.
    $credentialLine = ''
    $credentialArg  = ''
    if ($script:AdCredential) {
        $credentialLine = "`r`n`$credential     = Get-Credential '{0}'" -f $script:AdCredential.UserName
        $credentialArg  = ' -Credential $credential'
    }

    $delegationBlock = if ($InputState.EnableDelegation) {
@"

`$msa = Get-ADServiceAccount -Identity '$($InputState.SamAccountName)' -Server `$domain$credentialArg
Set-ADAccountControl -Identity `$msa -TrustedForDelegation `$true -TrustedToAuthForDelegation `$false -Server `$domain$credentialArg
"@
    } else {
        @"

# Unconstrained delegation stays off.
"@
    }

@"
# PowerShell that Create gMSA will run
`$domain         = '$($InputState.Domain)'
`$serviceName    = '$($InputState.ServiceName)'
`$samAccountName = '$($InputState.SamAccountName)'
`$dnsHostName    = '$($InputState.DnsHostName)'$credentialLine
`$principalDns = @(
$principalLines
)

New-ADServiceAccount -Name `$serviceName ``
    -DNSHostName `$dnsHostName ``
    -SamAccountName `$samAccountName ``
    -PrincipalsAllowedToRetrieveManagedPassword `$principalDns ``
    -Server `$domain$credentialArg
$delegationBlock
"@
}

function Invoke-Review {
    Reset-PreviewState

    $state  = Get-InputState
    $issues = @(Test-CreateInputs -InputState $state)
    if ($issues.Count -gt 0) {
        Show-ValidationError -Message ($issues -join [Environment]::NewLine)
        return
    }

    Ensure-ActiveDirectoryModule
    $ui.CreateStatusText.Text = 'Checking the details against Active Directory...'
    Write-Log -Level 'STEP' -Message ("Reviewing gMSA '{0}' in '{1}'." -f $state.SamAccountName, $state.Domain)

    $escapedSam = ConvertTo-LdapFilterValue -Value $state.SamAccountName
    $existing = @(Get-ADObject -LDAPFilter "(sAMAccountName=$escapedSam)" -Server $state.Domain @script:CredentialSplat -ErrorAction Stop)
    if ($existing.Count -gt 0) {
        $ui.CreateStatusText.Text = 'Fill in the account details, then select Review.'
        Show-ValidationError -Message ("An account named '{0}' already exists in '{1}':`n`n{2}`n`nUse the Manage gMSA tab to change it." -f `
            $state.SamAccountName, $state.Domain, $existing[0].DistinguishedName)
        return
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $dns  = New-Object System.Collections.Generic.List[string]
    foreach ($name in $state.Servers) {
        Write-Log -Level 'STEP' -Message ("Resolving '{0}' against '{1}'." -f $name, $state.Domain)
        $object = Resolve-AllowedPrincipal -Name $name -Domain $state.Domain
        if ($dns -contains $object.DistinguishedName) {
            Write-Log -Level 'INFO' -Message ("'{0}' is listed more than once; keeping one entry." -f $name)
            continue
        }
        Write-Log -Level 'INFO' -Message ("Resolved '{0}' as {1}: {2}" -f $name, $object.ObjectClass, $object.DistinguishedName)
        $dns.Add($object.DistinguishedName)
        $rows.Add((New-PrincipalRow -Object $object))
    }

    $ui.SummaryAccountText.Text = $state.SamAccountName
    $ui.SummaryDnsText.Text     = $state.DnsHostName
    $ui.SummaryDomainText.Text  = $state.Domain
    if ($state.EnableDelegation) {
        $ui.SummaryDelegationText.Text       = 'Unconstrained delegation ON'
        $ui.SummaryDelegationText.Foreground = $window.FindResource('WarningBrush')
    } else {
        $ui.SummaryDelegationText.Text       = 'Off'
        $ui.SummaryDelegationText.Foreground = $window.FindResource('TextBrush')
    }
    $ui.ReviewPrincipalsListView.ItemsSource = $rows.ToArray()

    $script:ReviewedPrincipalDns = $dns.ToArray()
    $script:PreviewCommandText   = Format-Preview -InputState $state -PrincipalDns $script:ReviewedPrincipalDns
    $script:PreviewSignature     = Get-StateSignature -InputState $state
    $ui.PreviewTextBox.Text      = $script:PreviewCommandText

    Set-ReviewView
    $ui.ReviewContentGrid.Visibility = 'Visible'
    $ui.ExecuteButton.IsEnabled = $true
    $ui.CreateStatusText.Text = "Ready to create {0} in {1}. You'll be asked to confirm." -f $state.SamAccountName, $state.Domain

    Write-Log -Level 'SUCCESS' -Message ("Review passed for '{0}': {1} principal(s)." -f $state.SamAccountName, $rows.Count)
}

function Invoke-CreateGmsa {
    param(
        [object]$InputState,
        [string[]]$PrincipalDns
    )

    Ensure-ActiveDirectoryModule

    Write-Log -Level 'STEP' -Message ("Creating gMSA '{0}' with DNS host '{1}'." -f $InputState.ServiceName, $InputState.DnsHostName)
    $newParams = @{
        Name                                       = $InputState.ServiceName
        DNSHostName                                = $InputState.DnsHostName
        SamAccountName                             = $InputState.SamAccountName
        PrincipalsAllowedToRetrieveManagedPassword = $PrincipalDns
        Server                                     = $InputState.Domain
        ErrorAction                                = 'Stop'
    }
    New-ADServiceAccount @newParams @script:CredentialSplat

    if ($InputState.EnableDelegation) {
        Write-Log -Level 'STEP' -Message ("Enabling unconstrained delegation for '{0}'." -f $InputState.ServiceName)
        # Retrieve the created account, then use -Identity (not pipeline) for Set-ADAccountControl
        $msa = Get-ADServiceAccount -Identity $InputState.SamAccountName -Server $InputState.Domain @script:CredentialSplat -ErrorAction Stop
        Set-ADAccountControl -Identity $msa -TrustedForDelegation $true -TrustedToAuthForDelegation $false `
            -Server $InputState.Domain @script:CredentialSplat -ErrorAction Stop
    }

    Write-Log -Level 'SUCCESS' -Message ("gMSA '{0}' created successfully." -f $InputState.ServiceName)
}

function Invoke-Create {
    $state  = Get-InputState
    $issues = @(Test-CreateInputs -InputState $state)
    if ($issues.Count -gt 0) {
        Show-ValidationError -Message ($issues -join [Environment]::NewLine)
        return
    }

    if ((Get-StateSignature -InputState $state) -ne $script:PreviewSignature) {
        Reset-PreviewState
        Show-ValidationError -Message 'The details changed since the last review. Select Review again before creating.'
        return
    }

    $message = "Create gMSA '{0}' in '{1}' with {2} allowed principal(s)?" -f `
        $state.SamAccountName, $state.Domain, $script:ReviewedPrincipalDns.Count
    if ($state.EnableDelegation) {
        $message += "`n`nUnconstrained delegation will be turned ON."
    }
    if (-not (Confirm-Change -Message $message -Title 'Confirm Create')) {
        Write-Log -Level 'INFO' -Message 'Create cancelled by user.'
        return
    }

    Write-Log -Level 'STEP' -Message 'Create confirmed by user.'
    Invoke-CreateGmsa -InputState $state -PrincipalDns $script:ReviewedPrincipalDns

    # Disable Create immediately to prevent creating twice, then open the new
    # account in the Manage tab so SPNs can be added straight away.
    Reset-PreviewState
    $ui.CreateStatusText.Text = "Created {0}. It is open in the Manage gMSA tab." -f $state.SamAccountName
    $ui.ManageDomainTextBox.Text      = $state.Domain
    $ui.ManageServiceNameTextBox.Text = $state.ServiceName
    $ui.MainTabControl.SelectedItem   = $ui.ManageTab

    $loaded = $true
    try {
        Import-ManageTarget -Domain $state.Domain -SamAccountName $state.SamAccountName
    }
    catch {
        # The account exists; a domain controller that hasn't replicated it yet can make the load fail.
        $loaded = $false
        Write-Log -Level 'ERROR' -Message ("Created '{0}', but loading it failed: {1}" -f $state.SamAccountName, $_.Exception.Message)
    }

    $doneMessage = if ($loaded) {
        "gMSA '{0}' was created and is now open in the Manage gMSA tab, where you can add SPNs." -f $state.SamAccountName
    } else {
        "gMSA '{0}' was created, but it could not be loaded yet, possibly because of AD replication. Select Load gMSA again in a minute." -f $state.SamAccountName
    }
    [System.Windows.MessageBox]::Show(
        $window,
        $doneMessage,
        'gMSA Created',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}

function Reset-CreateForm {
    $ui.DomainTextBox.Clear()
    $ui.ServiceNameTextBox.Clear()
    $ui.ServersTextBox.Clear()
    $ui.DelegationCheckBox.IsChecked = $false
    $ui.AdvancedPanel.Visibility = 'Collapsed'
    $ui.AdvancedToggleButton.Content = 'Show advanced options'
    $script:PreviewSignature = $null
    Reset-PreviewState
    Write-Log -Level 'INFO' -Message 'Form reset to defaults.'
}

# ---------------------------------------------------------------------------
# Manage gMSA tab
# ---------------------------------------------------------------------------

# The gMSA currently loaded in the Manage tab. Every change is applied to this
# account, never to whatever is typed in the fields, and the target is cleared
# as soon as either field is edited.
$script:ManageTarget = $null

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
    $ui.ManagePrincipalsListView.ItemsSource = $null
    $ui.ManageSpnListView.ItemsSource = $null
    $ui.ManageStatusTextBlock.Text = 'No gMSA loaded. Enter the domain and gMSA name, then select Load gMSA.'
    Set-ManageButtonsEnabled -Enabled $false
}

function Import-ManageTarget {
    param(
        [string]$Domain,
        [string]$SamAccountName
    )

    Ensure-ActiveDirectoryModule
    Write-Log -Level 'STEP' -Message ("Loading gMSA '{0}' from '{1}'." -f $SamAccountName, $Domain)

    $account = Get-ADServiceAccount -Identity $SamAccountName -Server $Domain `
                   -Properties PrincipalsAllowedToRetrieveManagedPassword, ServicePrincipalNames @script:CredentialSplat -ErrorAction Stop
    $principals = @($account.PrincipalsAllowedToRetrieveManagedPassword | ForEach-Object { [string]$_ })
    $spns       = @($account.ServicePrincipalNames | ForEach-Object { [string]$_ } | Sort-Object)

    $ui.ManagePrincipalsListView.ItemsSource = @(
        foreach ($dn in $principals) { Get-PrincipalRow -DistinguishedName $dn -Domain $Domain }
    )
    $ui.ManageSpnListView.ItemsSource = @(
        foreach ($spn in $spns) { [pscustomobject]@{ Spn = $spn } }
    )

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
        -PrincipalsAllowedToRetrieveManagedPassword $DistinguishedNames @script:CredentialSplat -ErrorAction Stop
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
        $added.Add(("  {0} ({1})" -f $object.sAMAccountName, (Get-PrincipalTypeLabel -ObjectClass $object.ObjectClass)))
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
    $target       = $script:ManageTarget
    $selectedRows = @($ui.ManagePrincipalsListView.SelectedItems)
    if ($selectedRows.Count -eq 0) {
        Show-ValidationError -Message 'Select one or more principals to remove.'
        return
    }

    $selected  = @($selectedRows | ForEach-Object { $_.DistinguishedName })
    $remaining = @($target.Principals | Where-Object { $selected -notcontains $_ })
    if ($remaining.Count -eq 0) {
        Show-ValidationError -Message 'At least one principal must stay allowed to retrieve the password. Add the replacement first, then remove this one.'
        return
    }

    $list = ($selectedRows | ForEach-Object {
        $label = if ($_.Name) { $_.Name } else { $_.DistinguishedName }
        '  {0} ({1})' -f $label, $_.Type
    }) -join "`n"
    $message = "Stop these principals from retrieving the password for '{0}'?`n`n{1}`n`nServices using this gMSA on a removed server will fail at their next password refresh." -f `
        $target.SamAccountName, $list
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
            Get-ADObject -LDAPFilter "(servicePrincipalName=$escaped)" -Server $target.Domain @script:CredentialSplat -ErrorAction Stop |
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
        -ServicePrincipalNames @{ Add = $toAdd.ToArray() } @script:CredentialSplat -ErrorAction Stop
    Write-Log -Level 'SUCCESS' -Message ("Added {0} SPN(s) to '{1}'." -f $toAdd.Count, $target.SamAccountName)
    $ui.ManageAddSpnTextBox.Clear()
    Update-ManageTarget
}

function Remove-ManageSpns {
    $target   = $script:ManageTarget
    $selected = @($ui.ManageSpnListView.SelectedItems | ForEach-Object { [string]$_.Spn })
    if ($selected.Count -eq 0) {
        Show-ValidationError -Message 'Select one or more SPNs to remove.'
        return
    }

    $message = "Remove these SPNs from '{0}'?`n`n{1}" -f $target.SamAccountName, (($selected | ForEach-Object { '  ' + $_ }) -join "`n")
    if (-not (Confirm-Change -Message $message)) {
        Write-Log -Level 'INFO' -Message 'Remove SPNs cancelled by user.'
        return
    }

    Write-Log -Level 'STEP' -Message ("Running: Set-ADServiceAccount -Identity '{0}' -Server '{1}' -ServicePrincipalNames @{{Remove='{2}'}}" -f `
        $target.SamAccountName, $target.Domain, ($selected -join "','"))
    Set-ADServiceAccount -Identity $target.SamAccountName -Server $target.Domain `
        -ServicePrincipalNames @{ Remove = $selected } @script:CredentialSplat -ErrorAction Stop
    Write-Log -Level 'SUCCESS' -Message ("Removed {0} SPN(s) from '{1}'." -f $selected.Count, $target.SamAccountName)
    Update-ManageTarget
}

# ---------------------------------------------------------------------------
# Event wiring
# ---------------------------------------------------------------------------

$ui.PreviewButton.Add_Click({
    Invoke-UiAction -Context 'Review' -Action {
        try { Invoke-Review }
        catch {
            $ui.CreateStatusText.Text = 'Review failed. See the Console Log for details.'
            throw
        }
    }
})
$ui.ExecuteButton.Add_Click({
    Invoke-UiAction -Context 'Create' -Action { Invoke-Create }
})
$ui.ResetButton.Add_Click({
    Invoke-UiAction -Context 'Reset' -Action { Reset-CreateForm }
})
$ui.ShowScriptButton.Add_Click({
    Invoke-UiAction -Context 'Toggle review view' -Action {
        Set-ReviewView -Script:($ui.PreviewTextBox.Visibility -ne 'Visible')
    }
})
$ui.AdvancedToggleButton.Add_Click({
    Invoke-UiAction -Context 'Toggle advanced options' -Action {
        if ($ui.AdvancedPanel.Visibility -eq 'Visible') {
            $ui.AdvancedPanel.Visibility = 'Collapsed'
            $ui.AdvancedToggleButton.Content = 'Show advanced options'
        } else {
            $ui.AdvancedPanel.Visibility = 'Visible'
            $ui.AdvancedToggleButton.Content = 'Hide advanced options'
        }
    }
})

# Any edit to the Create form invalidates the last review.
foreach ($textBox in $ui.DomainTextBox, $ui.ServiceNameTextBox, $ui.ServersTextBox) {
    $textBox.Add_TextChanged({
        try { Reset-PreviewState } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
    })
}
$ui.DelegationCheckBox.Add_Checked({
    try { Reset-PreviewState } catch { Write-Log -Level 'ERROR' -Message ("Checked error: {0}" -f $_.Exception.Message) }
})
$ui.DelegationCheckBox.Add_Unchecked({
    try { Reset-PreviewState } catch { Write-Log -Level 'ERROR' -Message ("Unchecked error: {0}" -f $_.Exception.Message) }
})

$ui.ManageLoadButton.Add_Click({
    Invoke-UiAction -Context 'Load gMSA' -Action {
        $domain      = $ui.ManageDomainTextBox.Text.Trim()
        $serviceName = $ui.ManageServiceNameTextBox.Text.Trim().TrimEnd('$')
        if (-not $domain -or -not $serviceName) {
            Show-ValidationError -Message 'Domain and gMSA name are required to load a gMSA.'
            return
        }
        Clear-ManageTarget
        Import-ManageTarget -Domain $domain -SamAccountName ('{0}$' -f $serviceName)
    }
})
$ui.ManageAddPrincipalButton.Add_Click({
    Invoke-UiAction -Context 'Add principals' -Action { Add-ManagePrincipals }
})
$ui.ManageRemovePrincipalButton.Add_Click({
    Invoke-UiAction -Context 'Remove principals' -Action { Remove-ManagePrincipals }
})
$ui.ManageAddSpnButton.Add_Click({
    Invoke-UiAction -Context 'Add SPNs' -Action { Add-ManageSpns }
})
$ui.ManageRemoveSpnButton.Add_Click({
    Invoke-UiAction -Context 'Remove SPNs' -Action { Remove-ManageSpns }
})
foreach ($textBox in $ui.ManageDomainTextBox, $ui.ManageServiceNameTextBox) {
    $textBox.Add_TextChanged({
        try { if ($script:ManageTarget) { Clear-ManageTarget } } catch { Write-Log -Level 'ERROR' -Message ("TextChanged error: {0}" -f $_.Exception.Message) }
    })
}

$ui.CredentialButton.Add_Click({
    Invoke-UiAction -Context 'Set credentials' -Action { Request-AdCredential }
})
$ui.CredentialButton.Add_MouseRightButtonUp({
    Invoke-UiAction -Context 'Clear credentials' -Action { Set-AdCredential -Credential $null }
})

$ui.ClearLogButton.Add_Click({
    try {
        $ui.LogTextBox.Clear()
        Write-Log -Level 'INFO' -Message 'Log cleared.'
    } catch { }
})

Reset-PreviewState
Clear-ManageTarget
Set-AdCredential -Credential $Credential

$window.Add_SourceInitialized({
    try {
        Write-Log -Level 'INFO' -Message ('{0} loaded.' -f $script:AppTitle)
        Write-Log -Level 'INFO' -Message 'Create gMSA: fill in the details, Review, then Create. Manage gMSA: change principals and SPNs on an existing account.'
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
            ('{0} - Unexpected Error' -f $script:AppTitle),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch { }
    $e.Handled = $true
})

[void]$window.ShowDialog()
