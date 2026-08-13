param([switch]$SmokeTest)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config\servers.json'
$collectorPath = Join-Path $scriptRoot 'src\Collect-Metrics.ps1'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server Pulse" Width="420" Height="560" MinWidth="340" MinHeight="300"
        WindowStyle="None" ResizeMode="CanResizeWithGrip" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" WindowStartupLocation="CenterScreen"
        FontFamily="Bahnschrift, Microsoft YaHei UI" Foreground="#E7EBE8">
  <Window.Resources>
    <SolidColorBrush x:Key="ThemeQuietHoverBackground" Color="#252A27"/>
    <SolidColorBrush x:Key="ThemeQuietHoverForeground" Color="#F4F7F5"/>
    <SolidColorBrush x:Key="ThemeAccentBackground" Color="#A7D948"/>
    <SolidColorBrush x:Key="ThemeAccentForeground" Color="#0B0E0C"/>
    <SolidColorBrush x:Key="ThemeAccentHover" Color="#B9EC58"/>
    <SolidColorBrush x:Key="ThemeAccentPressed" Color="#91C235"/>
    <Style x:Key="QuietButton" TargetType="Button">
      <Setter Property="Foreground" Value="#8C9690"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="MinWidth" Value="32"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Surface" Background="{TemplateBinding Background}" CornerRadius="5" Margin="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Surface" Property="Background" Value="{DynamicResource ThemeQuietHoverBackground}"/>
                <Setter Property="Foreground" Value="{DynamicResource ThemeQuietHoverForeground}"/>
              </Trigger>
              <Trigger Property="Tag" Value="active">
                <Setter TargetName="Surface" Property="Background" Value="{DynamicResource ThemeAccentBackground}"/>
                <Setter Property="Foreground" Value="{DynamicResource ThemeAccentForeground}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ManageButton" TargetType="Button" BasedOn="{StaticResource QuietButton}">
      <Setter Property="MinWidth" Value="62"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="Foreground" Value="#AAB4AE"/>
    </Style>
    <Style x:Key="HistoryAccentButton" TargetType="Button">
      <Setter Property="Foreground" Value="#0B0E0C"/>
      <Setter Property="Background" Value="#A7D948"/>
      <Setter Property="BorderBrush" Value="#BCEB62"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="MinWidth" Value="44"/>
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Background" Value="{DynamicResource ThemeAccentHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Background" Value="{DynamicResource ThemeAccentPressed}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="WindowSurface" Background="#F20D100E" BorderBrush="#343A36" BorderThickness="1" CornerRadius="12">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="44"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="24"/>
      </Grid.RowDefinitions>

      <Grid x:Name="DragArea" Grid.Row="0" Background="Transparent" Margin="10,5,7,3">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="FleetDot" Width="7" Height="7" Fill="#657069" Margin="3,0,9,0"/>
          <TextBlock Text="SERVER PULSE" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="FleetState" Text="  连接中" Foreground="#78827C" FontSize="10" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="ThemeButton" Style="{StaticResource QuietButton}" ToolTip="界面主题" MinWidth="48" Background="#202521">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Viewbox Width="12" Height="12" Margin="0,0,4,0"><Canvas Width="16" Height="16"><Ellipse Width="12" Height="12" Canvas.Left="2" Canvas.Top="2" Fill="Transparent" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type Button}}}" StrokeThickness="1.5"/><Path Data="M8 2 A6 6 0 0 0 8 14 Z" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type Button}}}"/></Canvas></Viewbox>
              <TextBlock x:Name="ThemeButtonText" Text="暗" FontSize="9" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Slider x:Name="OpacitySlider" Width="58" Minimum="40" Maximum="100" Value="94" TickFrequency="5"
                  IsSnapToTickEnabled="True" ToolTip="透明度" Foreground="#A7D948" Margin="4,0,6,0"/>
          <Button x:Name="EdgeButton" Style="{StaticResource QuietButton}" ToolTip="贴边自动隐藏">
            <Viewbox Width="16" Height="16"><Canvas Width="16" Height="16"><Path Data="M13.5 2.5v11 M2 8h9 M7.7 4.7L11 8l-3.3 3.3" Fill="Transparent" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type Button}}}" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas></Viewbox>
          </Button>
          <Button x:Name="PinButton" Style="{StaticResource QuietButton}" ToolTip="始终置顶">
            <Viewbox Width="16" Height="16"><Canvas Width="16" Height="16"><Path Data="M2.5 2.5h11 M8 14V5 M4.7 8.3L8 5l3.3 3.3" Fill="Transparent" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType={x:Type Button}}}" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas></Viewbox>
          </Button>
          <Button x:Name="MinimizeButton" Content="—" Style="{StaticResource QuietButton}" ToolTip="隐藏到托盘"/>
          <Button x:Name="CloseButton" Content="×" Style="{StaticResource QuietButton}" ToolTip="退出"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="36"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border BorderBrush="#242925" BorderThickness="0,1,0,1" Padding="15,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="SummaryText" Text="等待首次采集" Foreground="#939D97" FontSize="10" VerticalAlignment="Center"/>
              <Button x:Name="ServerButton" Style="{StaticResource ManageButton}" ToolTip="选择监视 SSH 服务器" Margin="8,0,0,0">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Viewbox Width="14" Height="14" Margin="0,0,5,0"><Canvas Width="16" Height="16"><Path Data="M2 2.5h12v4H2z M2 9.5h12v4H2z" Fill="Transparent" Stroke="#A7D948" StrokeThickness="1.4" StrokeLineJoin="Round"/><Path Data="M4.2 4.5h.1 M4.2 11.5h.1" Stroke="#A7D948" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox>
                  <TextBlock Text="管理" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="HistoryButton" Content="记录" Style="{StaticResource HistoryAccentButton}" Margin="0,0,8,0" ToolTip="查看占用记录"/>
              <TextBlock Text="刷新" Foreground="#68736C" FontSize="8" VerticalAlignment="Center" Margin="0,0,4,0"/>
              <TextBox x:Name="RefreshIntervalBox" Width="32" Height="20" MaxLength="3" Text="5" TextAlignment="Center"
                       VerticalContentAlignment="Center" Padding="2,0" FontSize="9" Foreground="#C5CDC8"
                       Background="#1A1F1C" BorderBrush="#343B36" BorderThickness="1" CaretBrush="#A7D948"
                       SelectionBrush="#A7D948" ToolTip="刷新间隔：1–300 秒，回车生效"/>
              <TextBlock Text="s" Foreground="#68736C" FontSize="8" VerticalAlignment="Center" Margin="3,0,10,0"/>
              <TextBlock x:Name="UpdatedText" Text="--:--:--" Foreground="#5F6963" FontSize="9" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </Border>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" Padding="12">
          <StackPanel x:Name="ServerPanel"/>
        </ScrollViewer>
      </Grid>

      <Grid Grid.Row="2" Margin="14,0,8,0">
        <TextBlock Text="拖动右下角调节尺寸" Foreground="#56605A" FontSize="8" VerticalAlignment="Center"/>
        <ResizeGrip HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="14" Height="14" Foreground="#69736D"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = [Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = 'WindowSurface','DragArea','FleetDot','FleetState','ThemeButton','ThemeButtonText','OpacitySlider','EdgeButton','PinButton','ServerButton','MinimizeButton','CloseButton','SummaryText','HistoryButton','RefreshIntervalBox','UpdatedText','ServerPanel'
$ui = @{}
foreach ($name in $names) { $ui[$name] = $window.FindName($name) }

$settingsDirectory = if($SmokeTest){Join-Path $scriptRoot 'tests\artifacts\localappdata-smoke\ServerPulse'}else{Join-Path $env:LOCALAPPDATA 'ServerPulse'}
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$settings = [PSCustomObject]@{ Version = 3; ThemeMode = 'dark'; Opacity = 0.94; AutoHide = $true; Topmost = $true; RefreshIntervalSeconds = $null; Width = 420.0; Height = 560.0; Left = $null; Top = $null }
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $currentLayout = $saved.PSObject.Properties.Name -contains 'Version' -and [int]$saved.Version -ge 2
        foreach ($property in $settings.PSObject.Properties.Name) {
            if ($saved.PSObject.Properties.Name -contains $property) { $settings.$property = $saved.$property }
        }
        if (-not $currentLayout) {
            $settings.Width = 420.0; $settings.Height = 560.0; $settings.Left = $null; $settings.Top = $null
        }
    } catch { }
}

function Write-ServerPulseErrorLog {
    param([Parameter(Mandatory)][Exception]$Exception, [string]$Context='UI event')

    if (-not (Test-Path -LiteralPath $settingsDirectory)) { [void](New-Item -ItemType Directory -Path $settingsDirectory -Force) }
    $logPath=Join-Path $settingsDirectory 'error.log'
    $entry="[{0}] {1}`r`n{2}`r`n`r`n" -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff'),$Context,$Exception.ToString()
    [IO.File]::AppendAllText($logPath,$entry,[Text.UTF8Encoding]::new($true))
    return $logPath
}

function Show-ServerPulseErrorDialog {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$Detail,
        [string]$LogPath,
        [switch]$SmokeTest
    )

    [xml]$dialogXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server Pulse" Width="500" SizeToContent="Height" MinHeight="210"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" WindowStartupLocation="CenterOwner" Topmost="True"
        FontFamily="Bahnschrift, Microsoft YaHei UI" Foreground="#E7EBE8">
  <Border Background="#FC111512" BorderBrush="#FF6B6B" BorderThickness="1" CornerRadius="11" Padding="18,15,18,16">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <DockPanel>
        <Ellipse Width="9" Height="9" Fill="#FF6B6B" Margin="0,0,10,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="DialogTitle" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </DockPanel>
      <TextBlock x:Name="DialogMessage" Grid.Row="1" Margin="19,14,0,0" FontSize="11" Foreground="#DCE3DF" TextWrapping="Wrap"/>
      <StackPanel Grid.Row="2" Margin="19,10,0,0">
        <TextBlock x:Name="DialogDetail" FontSize="9" Foreground="#FF9B93" TextWrapping="Wrap"/>
        <TextBlock x:Name="DialogLogPath" Margin="0,8,0,0" FontSize="8" Foreground="#78837C" TextWrapping="Wrap"/>
      </StackPanel>
      <Button x:Name="DialogCloseButton" Grid.Row="3" Content="知道了" Width="78" Height="28" Margin="0,16,0,0" HorizontalAlignment="Right"
              Foreground="#0B0E0C" Background="#A7D948" BorderBrush="#BCEB62" BorderThickness="1" FontSize="9" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </Border>
</Window>
'@
    $reader=[Xml.XmlNodeReader]::new($dialogXaml)
    $dialog=[Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner=$Owner
    $dialog.FindName('DialogTitle').Text=$Title
    $dialog.FindName('DialogMessage').Text=$Message
    $dialog.FindName('DialogDetail').Text=$Detail
    $dialog.FindName('DialogLogPath').Text=if([string]::IsNullOrWhiteSpace($LogPath)){''}else{"详细日志：$LogPath"}
    $dialog.FindName('DialogCloseButton').Add_Click({param($sender,$event);$target=[Windows.Window]::GetWindow($sender);if($null-ne$target){$target.Close()}})
    Update-ServerPulseThemeVisualTree $dialog
    if($SmokeTest){
        $result=[PSCustomObject]@{Topmost=$dialog.Topmost;ShowInTaskbar=$dialog.ShowInTaskbar;OwnerMatches=($dialog.Owner-eq$Owner);Title=$dialog.FindName('DialogTitle').Text;Message=$dialog.FindName('DialogMessage').Text}
        $dialog.Close()
        return $result
    }
    [void]$dialog.ShowDialog()
}

$window.Dispatcher.Add_UnhandledException({
    param($sender,$eventArgs)
    try {
        if ($SmokeTest -and $eventArgs.Exception.Message -eq 'ServerPulse dispatcher containment probe') {
            $script:dispatcherProbeHandled=$true
        } else {
            $logPath=Write-ServerPulseErrorLog -Exception $eventArgs.Exception -Context 'DispatcherUnhandledException'
            $ui.SummaryText.Text='界面操作发生异常，软件已保持运行'
            $ui.SummaryText.ToolTip="错误详情已写入 $logPath"
        }
    } catch {
        $ui.SummaryText.Text='界面操作发生异常，软件已保持运行'
    }
    $eventArgs.Handled=$true
})

$window.Width = [Math]::Max($window.MinWidth, [double]$settings.Width)
$window.Height = [Math]::Max($window.MinHeight, [double]$settings.Height)
$window.Opacity = 1.0
$window.Topmost = [bool]$settings.Topmost
$ui.OpacitySlider.Value = [Math]::Max(40, [Math]::Min(100, [double]$settings.Opacity * 100))
$ui.EdgeButton.Tag = if ([bool]$settings.AutoHide) { 'active' } else { $null }
$ui.PinButton.Tag = if ($window.Topmost) { 'active' } else { $null }

. (Join-Path $scriptRoot 'src\ServerPulse.Theme.ps1')
. (Join-Path $scriptRoot 'src\ServerPulse.Core.ps1')
. (Join-Path $scriptRoot 'src\ServerPulse.History.ps1')
. (Join-Path $scriptRoot 'src\ServerPulse.Ssh.ps1')
. (Join-Path $scriptRoot 'src\ServerPulse.ServerManager.ps1')
$config = Get-ServerPulseConfig -Path $configPath
$serverStorePath = Join-Path $settingsDirectory 'servers.json'
$script:firstServerStoreRun = -not (Test-Path -LiteralPath $serverStorePath)
$script:serverStore = Initialize-ServerPulseServerStore -SeedConfig $config -Path $serverStorePath
if ($script:firstServerStoreRun -and -not $SmokeTest) { Save-ServerPulseServerStore $script:serverStore }
$script:sessionSecrets = New-ServerPulseSessionSecretStore
$script:serverAuthStates = @{}
$script:forceReconnectServers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:askPassPath = Ensure-ServerPulseAskPassHelper (Join-Path $settingsDirectory 'bin')
$configuredInterval = ConvertTo-RefreshIntervalSeconds ([Math]::Round($config.PollIntervalMs / 1000))
$savedInterval = ConvertTo-RefreshIntervalSeconds $settings.RefreshIntervalSeconds
$script:refreshIntervalSeconds = if ($null -ne $savedInterval) { $savedInterval } elseif ($null -ne $configuredInterval) { $configuredInterval } else { 5 }
$ui.RefreshIntervalBox.Text = [string]$script:refreshIntervalSeconds
$historyDirectory = Join-Path $settingsDirectory 'history'
$script:historyRecorder = New-ServerPulseHistoryRecorder -Directory $historyDirectory -RetentionDays $config.HistoryRetentionDays
if (-not $SmokeTest) { try { Remove-ExpiredServerPulseHistory $script:historyRecorder } catch { } }
$script:cards = @{}
$script:collectionProcess = $null
$script:collectionBusy = $false
$script:stdoutTask = $null
$script:stderrTask = $null
$script:nextCollection = [DateTime]::UtcNow
$script:dockSide = $null
$script:hiddenAtEdge = $false
$script:internalMove = $false
$script:shownLeft = $null
$script:shownTop = $null
$script:backgroundOpacity = $ui.OpacitySlider.Value / 100
$script:edgeRevealArmed = $false
$script:isDragging = $false
$script:dragStartCursor = $null
$script:dragStartLeft = 0.0
$script:dragStartTop = 0.0
$script:dragScaleX = 1.0
$script:dragScaleY = 1.0
$script:smokeFinished = $false
$script:smokePassed = $false
$script:smokeError = $null
$script:authManagerPrompted = $false
$script:sshManagerOpen = $false
$script:sshManagerOpenQueued = $false
$script:sshManagerWindow = $null

function New-Brush([string]$Color) {
    return New-ServerPulseThemeBrush $Color
}

function New-AlphaBrush([string]$Color, [double]$Opacity) {
    $base = ConvertTo-ServerPulseThemeColor ([Windows.Media.ColorConverter]::ConvertFromString($Color)) $script:serverPulseResolvedTheme
    $alpha = [byte][Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, $Opacity)) * 255)
    $value = [Windows.Media.Color]::FromArgb($alpha, $base.R, $base.G, $base.B)
    $brush = [Windows.Media.SolidColorBrush]::new()
    $brush.Color = $value
    return Register-ServerPulseThemeBrush $brush
}

function New-Text([string]$Text, [double]$Size, [string]$Color) {
    $block = [Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = New-Brush $Color
    $block.VerticalAlignment = 'Center'
    return $block
}

$script:themeMode = Normalize-ServerPulseThemeMode ([string]$settings.ThemeMode)
$script:resolvedTheme = Set-ServerPulseThemeState -Mode $script:themeMode -ResolvedTheme (Resolve-ServerPulseTheme $script:themeMode)
Update-ServerPulseThemeVisualTree $window
$script:themeChoiceRows = [Collections.ArrayList]::new()
$script:themePopup = [Windows.Controls.Primitives.Popup]::new()
$script:themePopup.PlacementTarget = $ui.ThemeButton
$script:themePopup.Placement = 'Bottom'
$script:themePopup.HorizontalOffset = -78
$script:themePopup.VerticalOffset = 4
$script:themePopup.StaysOpen = $false
$script:themePopup.AllowsTransparency = $true
$themePopupSurface = [Windows.Controls.Border]::new()
$themePopupSurface.Width = 132
$themePopupSurface.Padding = [Windows.Thickness]::new(5)
$themePopupSurface.CornerRadius = [Windows.CornerRadius]::new(8)
$themePopupSurface.Background = New-AlphaBrush '#111512' 0.98
$themePopupSurface.BorderBrush = New-Brush '#343A36'
$themePopupSurface.BorderThickness = [Windows.Thickness]::new(1)
$themePopupPanel = [Windows.Controls.StackPanel]::new()
$themePopupSurface.Child = $themePopupPanel
$script:themePopup.Child = $themePopupSurface

function Update-ServerPulseThemeSelector {
    $labels = @{ light='亮'; dark='暗'; system='跟随系统' }
    $buttonLabels = @{ light='亮'; dark='暗'; system='系统' }
    $ui.ThemeButtonText.Text = [string]$buttonLabels[$script:themeMode]
    $ui.ThemeButton.ToolTip = "界面主题：$($labels[$script:themeMode])"
    foreach ($row in @($script:themeChoiceRows)) {
        $active = [string]$row.Mode -eq $script:themeMode
        $row.Surface.Background = if ($active) { New-Brush '#A7D948' } else { [Windows.Media.Brushes]::Transparent }
        $row.Label.Foreground = if ($active) { New-Brush '#0B0E0C' } else { New-Brush '#D7DDD9' }
        $row.Mark.Foreground = if ($active) { New-Brush '#0B0E0C' } else { New-Brush '#657069' }
        $row.Mark.Text = if ($active) { '●' } else { '' }
    }
}

function Set-ServerPulseThemeMode {
    param([string]$Mode, [switch]$Persist)
    $script:themeMode = Normalize-ServerPulseThemeMode $Mode
    $script:resolvedTheme = Set-ServerPulseThemeState -Mode $script:themeMode -ResolvedTheme (Resolve-ServerPulseTheme $script:themeMode)
    Update-ServerPulseThemeVisualTree $window
    foreach ($ownedWindow in @($window.OwnedWindows)) {
        if ($null -ne $ownedWindow) { Update-ServerPulseThemeVisualTree $ownedWindow }
    }
    if ($null -ne $script:themePopup.Child) { Update-ServerPulseThemeVisualTree $script:themePopup.Child }
    if ((Get-Variable -Name userUsagePopupManager -Scope Script -ErrorAction SilentlyContinue) -and $null -ne $script:userUsagePopupManager -and $null -ne $script:userUsagePopupManager.Surface) {
        Update-ServerPulseThemeVisualTree $script:userUsagePopupManager.Surface
    }
    Update-ServerPulseThemeSelector
    if ($Persist -and -not $SmokeTest) { Save-Settings }
}

foreach ($choice in @(@('light','亮'),@('dark','暗'),@('system','跟随系统'))) {
    $surface = [Windows.Controls.Border]::new()
    $surface.Height = 30
    $surface.Padding = [Windows.Thickness]::new(9,0,8,0)
    $surface.CornerRadius = [Windows.CornerRadius]::new(5)
    $surface.Cursor = [Windows.Input.Cursors]::Hand
    $grid = [Windows.Controls.Grid]::new()
    [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $markColumn = [Windows.Controls.ColumnDefinition]::new(); $markColumn.Width = 14
    [void]$grid.ColumnDefinitions.Add($markColumn)
    $label = New-Text $choice[1] 10 '#D7DDD9'
    $mark = New-Text '' 7 '#657069'; $mark.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($mark,1)
    [void]$grid.Children.Add($label); [void]$grid.Children.Add($mark)
    $surface.Child = $grid
    $row = [PSCustomObject]@{ Mode=$choice[0]; Surface=$surface; Label=$label; Mark=$mark }
    $surface.Tag = $row
    $surface.Add_MouseEnter({
        param($sender,$eventArgs)
        if ([string]$sender.Tag.Mode -ne $script:themeMode) { $sender.Background = New-Brush '#252A27' }
    })
    $surface.Add_MouseLeave({ Update-ServerPulseThemeSelector })
    $surface.Add_MouseLeftButtonUp({
        param($sender,$eventArgs)
        Set-ServerPulseThemeMode -Mode ([string]$sender.Tag.Mode) -Persist
        $script:themePopup.IsOpen = $false
        $eventArgs.Handled = $true
    })
    [void]$script:themeChoiceRows.Add($row)
    [void]$themePopupPanel.Children.Add($surface)
}
Update-ServerPulseThemeSelector

function New-MetricCell([string]$Label) {
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Background = [Windows.Media.Brushes]::Transparent
    $panel.Margin = [Windows.Thickness]::new(0, 0, 9, 0)
    $labelBlock = New-Text $Label 8 '#6C7770'
    $labelBlock.Margin = [Windows.Thickness]::new(0, 0, 0, 1)
    $valueBlock = New-Text '—' 14 '#D8DEDA'
    $valueBlock.FontWeight = 'SemiBold'
    $bar = [Windows.Controls.ProgressBar]::new()
    $bar.Height = 2
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
    $bar.Background = New-Brush '#2B312D'
    $bar.Foreground = New-Brush '#A7D948'
    [void]$panel.Children.Add($labelBlock)
    [void]$panel.Children.Add($valueBlock)
    [void]$panel.Children.Add($bar)
    return @{ Panel = $panel; Value = $valueBlock; Bar = $bar }
}

function Get-UserUsageProperty {
    param($InputObject, [string[]]$Names, $Default = $null)

    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function ConvertTo-UserUsageNumber($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [double]$Value } catch { return $null }
}

function Get-UserUsageStatus($Usage) {
    if ($null -eq $Usage) { return 'unavailable' }
    $status = [string](Get-UserUsageProperty $Usage @('Status','status') 'unavailable')
    $status = $status.Trim().ToLowerInvariant()
    if ($status -notin @('ok','partial','unavailable')) { return 'unavailable' }
    return $status
}

function Get-UserUsageRows {
    param($TargetState)

    $usage = $TargetState.Usage
    $users = @(Get-UserUsageProperty $usage @('Users','UserUsage','Items') @())
    $rows = foreach ($user in $users) {
        if ($null -eq $user) { continue }
        $uid = Get-UserUsageProperty $user @('Uid','UID','UserId') $null
        $name = [string](Get-UserUsageProperty $user @('Name','UserName','Username','DisplayName') '')
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = if ($null -ne $uid) { "UID $uid" } else { '未知用户' }
        }

        if ($TargetState.Kind -eq 'cpu') {
            $value = ConvertTo-UserUsageNumber (Get-UserUsageProperty $user @('Percent','CpuPercent','Utilization','Value') $null)
            $percent = $value
        } else {
            $value = ConvertTo-UserUsageNumber (Get-UserUsageProperty $user @('RssMiB','MemoryUsedMiB','UsedMiB','MemoryMiB','MiB','ValueMiB','Value') $null)
            $percent = ConvertTo-UserUsageNumber (Get-UserUsageProperty $user @('Percent','MemoryPercent','VramPercent') $null)
            if ($null -eq $percent -and $null -ne $value -and $TargetState.TotalMiB -gt 0) {
                $percent = $value * 100.0 / $TargetState.TotalMiB
            }
        }

        [PSCustomObject]@{
            Key = if ($null -ne $uid) { "uid:$uid" } else { "name:$name" }
            Name = $name
            Value = $value
            Percent = $percent
            SortValue = if ($null -eq $value) { 0.0 } else { [double]$value }
        }
    }
    return @($rows | Sort-Object -Property @{Expression='SortValue';Descending=$true}, @{Expression='Name';Descending=$false})
}

function Format-UserUsageValue {
    param([string]$Kind, $Value, $Percent)

    if ($null -eq $Value) { return '—' }
    if ($Kind -eq 'cpu') { return ('{0:0.0}%' -f [double]$Value) }
    $percentText = if ($null -eq $Percent) { '—' } else { '{0:0.0}%' -f [double]$Percent }
    return ('{0:0.0} GB · {1}' -f ([double]$Value / 1024.0), $percentText)
}

function Get-SystemUserUsageRow {
    param($TargetState)

    $usage = $TargetState.Usage
    $status = Get-UserUsageStatus $usage
    if ($TargetState.Kind -eq 'cpu') {
        $value = ConvertTo-UserUsageNumber (Get-UserUsageProperty $usage @('SystemUnattributedPercent','UnattributedPercent','SystemPercent') $null)
        $percent = $value
    } else {
        $value = ConvertTo-UserUsageNumber (Get-UserUsageProperty $usage @('SystemUnattributedMiB','UnattributedMiB','UnmappedMiB') $null)
        $percent = ConvertTo-UserUsageNumber (Get-UserUsageProperty $usage @('SystemUnattributedPercent','UnattributedPercent','UnmappedPercent') $null)
        if ($null -eq $percent -and $null -ne $value -and $TargetState.TotalMiB -gt 0) {
            $percent = $value * 100.0 / $TargetState.TotalMiB
        }
    }
    if ($status -eq 'unavailable') { $value = $null; $percent = $null }
    return [PSCustomObject]@{ Name='系统/未归属'; Value=$value; Percent=$percent }
}

function New-UserUsagePopupRow {
    param([string]$Name, [string]$Value, [switch]$System)

    $row = [Windows.Controls.Grid]::new()
    $row.Margin = [Windows.Thickness]::new(0, 0, 0, 5)
    [void]$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $right = [Windows.Controls.ColumnDefinition]::new(); $right.Width = 'Auto'; [void]$row.ColumnDefinitions.Add($right)
    $nameBlock = New-Text $Name 10 $(if ($System) { '#8C9690' } else { '#D7DDD9' })
    $nameBlock.TextTrimming = 'CharacterEllipsis'; $nameBlock.MaxWidth = 154
    $valueBlock = New-Text $Value 10 $(if ($System) { '#8C9690' } else { '#F0F3F1' })
    $valueBlock.FontWeight = 'SemiBold'; $valueBlock.Margin = [Windows.Thickness]::new(10,0,0,0)
    [Windows.Controls.Grid]::SetColumn($valueBlock,1)
    [void]$row.Children.Add($nameBlock); [void]$row.Children.Add($valueBlock)
    return $row
}

function Register-UserUsageExpandButton {
    param([Windows.Controls.Button]$Button, $Manager)

    $Button.Tag = $Manager
    $Button.Add_Click({
        param($sender,$eventArgs)
        $popupManager = $sender.Tag
        if ($null -eq $popupManager -or $null -eq $popupManager.CurrentTarget) { return }
        $popupManager.CurrentTarget.Expanded = -not [bool]$popupManager.CurrentTarget.Expanded
        Update-UserUsagePopupContent $popupManager
        $eventArgs.Handled = $true
    })
}

function Update-UserUsagePopupContent {
    param($Manager)

    $state = $Manager.CurrentTarget
    if ($null -eq $state) { return }
    $Manager.Header.Text = "$($state.Title) · 用户占用"
    $Manager.Mode.Text = if ($Manager.IsPinned) { '● 已固定' } else { '悬停预览' }
    $Manager.Mode.Foreground = New-Brush $(if ($Manager.IsPinned) { '#A7D948' } else { '#6F7A73' })
    $Manager.Rows.Children.Clear()

    $status = Get-UserUsageStatus $state.Usage
    $Manager.Status.Text = switch ($status) {
        'ok' { '归属数据完整' }
        'partial' { '部分归属 · 未读取项计入未归属' }
        default { '用户归属不可用' }
    }
    $Manager.Status.Foreground = New-Brush $(if ($status -eq 'ok') { '#6F7A73' } elseif ($status -eq 'partial') { '#E4B64B' } else { '#FF7B72' })

    $rows = @(Get-UserUsageRows $state | Where-Object { $_.SortValue -gt 0.0001 })
    $visibleRows = if ($state.Expanded) { $rows } else { @($rows | Select-Object -First 8) }
    foreach ($row in $visibleRows) {
        [void]$Manager.Rows.Children.Add((New-UserUsagePopupRow -Name $row.Name -Value (Format-UserUsageValue $state.Kind $row.Value $row.Percent)))
    }
    if ($rows.Count -eq 0 -and $status -ne 'unavailable') {
        $empty = New-Text '暂无可归属的活跃用户' 10 '#68736C'; $empty.Margin = [Windows.Thickness]::new(0,2,0,7)
        [void]$Manager.Rows.Children.Add($empty)
    }

    if ($rows.Count -gt 8) {
        $toggle = [Windows.Controls.Button]::new()
        $toggle.Content = if ($state.Expanded) { '收起' } else { "其他（$($rows.Count - 8) 用户）" }
        $toggle.Height = 25; $toggle.Margin = [Windows.Thickness]::new(0,1,0,7); $toggle.Cursor = 'Hand'
        $toggle.Foreground = New-Brush '#A7D948'; $toggle.Background = New-Brush '#202521'; $toggle.BorderBrush = New-Brush '#353C37'; $toggle.BorderThickness = [Windows.Thickness]::new(1)
        Register-UserUsageExpandButton -Button $toggle -Manager $Manager
        [void]$Manager.Rows.Children.Add($toggle)
    }

    $divider = [Windows.Controls.Border]::new(); $divider.Height = 1; $divider.Background = New-Brush '#303632'; $divider.Margin = [Windows.Thickness]::new(0,1,0,7)
    [void]$Manager.Rows.Children.Add($divider)
    $system = Get-SystemUserUsageRow $state
    [void]$Manager.Rows.Children.Add((New-UserUsagePopupRow -Name $system.Name -Value (Format-UserUsageValue $state.Kind $system.Value $system.Percent) -System))

    if ($state.Kind -eq 'memory') {
        $overlap = ConvertTo-UserUsageNumber (Get-UserUsageProperty $state.Usage @('RssOverlapMiB','OverlapMiB') $null)
        $Manager.Footer.Text = if ($null -ne $overlap -and $overlap -gt 0) {
            'RSS 估算 · 共享页可能重复（约 {0:0.0} GB）' -f ($overlap / 1024.0)
        } else { 'RSS 快速估算 · 共享页可能重复计入' }
    } elseif ($state.Kind -eq 'vram') {
        $Manager.Footer.Text = '逐卡显存 · 驱动与未映射占用归入未归属'
    } else {
        $Manager.Footer.Text = 'CPU 按整台服务器 0–100% 归一化'
    }
}

function Set-UserUsageTargetVisual {
    param($TargetState)

    if ($null -eq $TargetState -or $null -eq $TargetState.ValueElement) { return }
    $manager = $TargetState.Manager
    $isCurrent = $null -ne $manager.CurrentTarget -and $manager.CurrentTarget.Key -eq $TargetState.Key
    $color = if ($isCurrent -and $manager.IsPinned) { '#79C8D8' } elseif ($TargetState.IsHover) { '#FFFFFF' } else { $TargetState.DefaultForeground }
    $TargetState.ValueElement.Foreground = New-Brush $color
}

function Open-UserUsagePopup {
    param($TargetState, [switch]$Pinned)

    if ($null -eq $TargetState -or $null -eq $TargetState.Manager) { return }
    $manager = $TargetState.Manager
    $previous = $manager.CurrentTarget
    if ($null -ne $previous -and $previous.Key -ne $TargetState.Key) {
        $previous.Expanded = $false
        Set-UserUsageTargetVisual $previous
    }
    if ($null -eq $previous -or $previous.Key -ne $TargetState.Key) { $TargetState.Expanded = $false }
    $manager.CurrentTarget = $TargetState
    $manager.IsPinned = [bool]$Pinned
    $manager.CloseTimer.Stop()
    $manager.Popup.PlacementTarget = $TargetState.Target
    Update-UserUsagePopupContent $manager
    $manager.Popup.IsOpen = $true
    Set-UserUsageTargetVisual $TargetState
    if ($null -ne $script:hideTimer) { $script:hideTimer.Stop() }
    if ($null -ne $script:dockDetectTimer) { $script:dockDetectTimer.Stop() }
}

function Close-UserUsagePopup {
    param($Manager)

    if ($null -eq $Manager) { return }
    $previous = $Manager.CurrentTarget
    $Manager.CloseTimer.Stop()
    $Manager.Popup.IsOpen = $false
    $Manager.CurrentTarget = $null
    $Manager.IsPinned = $false
    if ($null -ne $previous) { $previous.Expanded = $false; Set-UserUsageTargetVisual $previous }
    if ($window.IsVisible -and $window.WindowState -eq 'Normal' -and $script:dockSide -and $ui.EdgeButton.Tag -eq 'active' -and -not $window.IsMouseOver) {
        $hideTimer.Stop(); $hideTimer.Start()
    }
}

function Invoke-UserUsageTargetMouseEnter {
    param($TargetState)

    if ($null -eq $TargetState) { return }
    $TargetState.IsHover = $true
    $manager = $TargetState.Manager
    $manager.CloseTimer.Stop()
    if (-not $manager.IsPinned) {
        Open-UserUsagePopup $TargetState -Pinned:$false
    }
    Set-UserUsageTargetVisual $TargetState
}

function Invoke-UserUsageTargetMouseLeave {
    param($TargetState)

    if ($null -eq $TargetState) { return }
    $TargetState.IsHover = $false
    Set-UserUsageTargetVisual $TargetState
    if (-not $TargetState.Manager.IsPinned) {
        $TargetState.Manager.CloseTimer.Stop(); $TargetState.Manager.CloseTimer.Start()
    }
}

function Invoke-UserUsageTargetClick {
    param($TargetState)

    if ($null -eq $TargetState) { return }
    $manager = $TargetState.Manager
    if ($manager.IsPinned -and $null -ne $manager.CurrentTarget -and $manager.CurrentTarget.Key -eq $TargetState.Key) {
        Close-UserUsagePopup $manager
    } else {
        Open-UserUsagePopup $TargetState -Pinned
    }
}

function Register-UserUsageTarget {
    param(
        [Windows.FrameworkElement]$Target,
        [string]$Key,
        [ValidateSet('cpu','memory','vram')][string]$Kind,
        [string]$Title,
        [Windows.Controls.TextBlock]$ValueElement,
        [string]$DefaultForeground,
        $Manager
    )

    $state = [PSCustomObject]@{
        Key=$Key; Kind=$Kind; Title=$Title; Target=$Target; ValueElement=$ValueElement
        DefaultForeground=$DefaultForeground; Usage=$null; TotalMiB=0.0; Expanded=$false
        IsHover=$false; Manager=$Manager
    }
    $Target.Tag = $state
    $Target.Cursor = 'Hand'
    $Target.ToolTip = '悬停查看用户占用，单击固定'
    $Manager.Targets[$Key] = $Target
    $Target.Add_MouseEnter({ param($sender,$eventArgs); Invoke-UserUsageTargetMouseEnter $sender.Tag })
    $Target.Add_MouseLeave({ param($sender,$eventArgs); Invoke-UserUsageTargetMouseLeave $sender.Tag })
    $Target.Add_MouseLeftButtonDown({
        param($sender,$eventArgs)
        Invoke-UserUsageTargetClick $sender.Tag
        $eventArgs.Handled = $true
    })
    return $state
}

function Update-UserUsageTarget {
    param([Windows.FrameworkElement]$Target, $Usage, [double]$TotalMiB = 0.0, [string]$Title)

    if ($null -eq $Target -or $null -eq $Target.Tag) { return }
    $state = $Target.Tag
    $state.Usage = $Usage
    $state.TotalMiB = [Math]::Max(0.0, $TotalMiB)
    if (-not [string]::IsNullOrWhiteSpace($Title)) { $state.Title = $Title }
    $status = Get-UserUsageStatus $Usage
    $Target.ToolTip = switch ($status) {
        'ok' { '悬停查看用户占用，单击固定' }
        'partial' { '用户归属不完整；悬停查看，单击固定' }
        default { '当前无法读取用户归属' }
    }
    if ($null -ne $state.Manager.CurrentTarget -and $state.Manager.CurrentTarget.Key -eq $state.Key -and $state.Manager.Popup.IsOpen) {
        Update-UserUsagePopupContent $state.Manager
    }
}

function New-UserUsagePopupManager {
    $popup = [Windows.Controls.Primitives.Popup]::new()
    $popup.AllowsTransparency = $true
    $popup.StaysOpen = $true
    $popup.Placement = [Windows.Controls.Primitives.PlacementMode]::Right
    $popup.HorizontalOffset = 8

    $surface = [Windows.Controls.Border]::new()
    $surface.Width = 286; $surface.MaxHeight = 430
    $surface.Padding = [Windows.Thickness]::new(12,10,12,10)
    $surface.CornerRadius = [Windows.CornerRadius]::new(8)
    $surface.Background = New-AlphaBrush '#111512' 0.98
    $surface.BorderBrush = New-Brush '#3A433C'; $surface.BorderThickness = [Windows.Thickness]::new(1)
    $shadow = [Windows.Media.Effects.DropShadowEffect]::new(); $shadow.BlurRadius=18; $shadow.ShadowDepth=3; $shadow.Opacity=0.55; $shadow.Color=[Windows.Media.Colors]::Black
    $surface.Effect = $shadow

    $layout = [Windows.Controls.StackPanel]::new()
    $headerGrid = [Windows.Controls.Grid]::new()
    [void]$headerGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $modeColumn = [Windows.Controls.ColumnDefinition]::new(); $modeColumn.Width='Auto'; [void]$headerGrid.ColumnDefinitions.Add($modeColumn)
    $header = New-Text '用户占用' 11 '#F0F3F1'; $header.FontWeight='SemiBold'
    $mode = New-Text '悬停预览' 8 '#6F7A73'; $mode.HorizontalAlignment='Right'; [Windows.Controls.Grid]::SetColumn($mode,1)
    [void]$headerGrid.Children.Add($header); [void]$headerGrid.Children.Add($mode)
    $status = New-Text '用户归属不可用' 8 '#6F7A73'; $status.Margin=[Windows.Thickness]::new(0,3,0,8)
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.MaxHeight=315; $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'
    $rows = [Windows.Controls.StackPanel]::new(); $scroll.Content=$rows
    $footer = New-Text '' 8 '#59635D'; $footer.Margin=[Windows.Thickness]::new(0,7,0,0); $footer.TextWrapping='Wrap'
    [void]$layout.Children.Add($headerGrid); [void]$layout.Children.Add($status); [void]$layout.Children.Add($scroll); [void]$layout.Children.Add($footer)
    $surface.Child = $layout; $popup.Child = $surface

    $timer = [Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[TimeSpan]::FromMilliseconds(180)
    $manager = [PSCustomObject]@{
        Popup=$popup; Surface=$surface; Header=$header; Mode=$mode; Status=$status; Rows=$rows; Footer=$footer
        CloseTimer=$timer; CurrentTarget=$null; IsPinned=$false; Targets=@{}
    }
    $timer.Tag = $manager
    $timer.Add_Tick({ param($sender,$eventArgs); $sender.Stop(); Close-UserUsagePopup $sender.Tag })
    $surface.Tag = $manager
    $surface.Add_MouseEnter({ param($sender,$eventArgs); $sender.Tag.CloseTimer.Stop() })
    $surface.Add_MouseLeave({
        param($sender,$eventArgs)
        if (-not $sender.Tag.IsPinned) { $sender.Tag.CloseTimer.Stop(); $sender.Tag.CloseTimer.Start() }
    })
    return $manager
}

function Register-UserUsageWindowEvents {
    param([Windows.Window]$HostWindow, $Manager)

    $eventState = [PSCustomObject]@{ UserUsageManager=$Manager }
    $HostWindow.Resources['ServerPulse.UserUsageEventState'] = $eventState
    $HostWindow.Add_MouseLeftButtonDown({
        param($sender,$eventArgs)
        Close-UserUsagePopup $sender.Resources['ServerPulse.UserUsageEventState'].UserUsageManager
    })
    $HostWindow.Add_PreviewKeyDown({
        param($sender,$eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Escape) {
            Close-UserUsagePopup $sender.Resources['ServerPulse.UserUsageEventState'].UserUsageManager
            $eventArgs.Handled = $true
        }
    })
    $HostWindow.Add_StateChanged({
        param($sender,$eventArgs)
        if ($sender.WindowState -eq [Windows.WindowState]::Minimized) { Close-UserUsagePopup $sender.Resources['ServerPulse.UserUsageEventState'].UserUsageManager }
    })
    $HostWindow.Add_IsVisibleChanged({
        param($sender,$eventArgs)
        if (-not $sender.IsVisible) { Close-UserUsagePopup $sender.Resources['ServerPulse.UserUsageEventState'].UserUsageManager }
    })
}

$script:userUsagePopupManager = New-UserUsagePopupManager
Register-UserUsageWindowEvents -HostWindow $window -Manager $script:userUsagePopupManager

function Add-ServerCard($server) {
    $sshTarget = if ($server.PSObject.Properties.Name -contains 'SshTarget') { [string]$server.SshTarget } else { [string]$server.host }
    $surface = [Windows.Controls.Border]::new()
    $surface.Background = New-AlphaBrush '#171A18' $script:backgroundOpacity
    $surface.BorderBrush = New-Brush '#2B302D'
    $surface.BorderThickness = [Windows.Thickness]::new(1)
    $surface.CornerRadius = [Windows.CornerRadius]::new(8)
    $surface.Padding = [Windows.Thickness]::new(12)
    $surface.Margin = [Windows.Thickness]::new(0, 0, 0, 10)

    $layout = [Windows.Controls.Grid]::new()
    foreach ($height in @('Auto','Auto','Auto','Auto')) {
        $row = [Windows.Controls.RowDefinition]::new()
        $row.Height = [Windows.GridLengthConverter]::new().ConvertFromString($height)
        [void]$layout.RowDefinitions.Add($row)
    }

    $header = [Windows.Controls.Grid]::new()
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $rightColumn = [Windows.Controls.ColumnDefinition]::new(); $rightColumn.Width = 'Auto'; [void]$header.ColumnDefinitions.Add($rightColumn)
    $title = New-Text ([string]$server.label) 14 '#F0F3F1'; $title.FontWeight = 'SemiBold'
    $state = New-Text '连接中' 9 '#7B857F'; $state.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($state, 1)
    [void]$header.Children.Add($title); [void]$header.Children.Add($state)
    [Windows.Controls.Grid]::SetRow($header, 0); [void]$layout.Children.Add($header)

    $meta = New-Text ("SSH  {0}" -f $sshTarget) 8 '#626C66'
    $meta.Margin = [Windows.Thickness]::new(0, 3, 0, 6)
    [Windows.Controls.Grid]::SetRow($meta, 1); [void]$layout.Children.Add($meta)

    $metricsGrid = [Windows.Controls.Primitives.UniformGrid]::new(); $metricsGrid.Columns = 2
    $cpu = New-MetricCell 'CPU'; $memory = New-MetricCell 'MEM'
    [void](Register-UserUsageTarget -Target $cpu.Panel -Key ("{0}:cpu" -f [string]$server.id) -Kind cpu -Title ("{0} · CPU" -f [string]$server.label) -ValueElement $cpu.Value -DefaultForeground '#D8DEDA' -Manager $script:userUsagePopupManager)
    [void](Register-UserUsageTarget -Target $memory.Panel -Key ("{0}:memory" -f [string]$server.id) -Kind memory -Title ("{0} · MEM" -f [string]$server.label) -ValueElement $memory.Value -DefaultForeground '#D8DEDA' -Manager $script:userUsagePopupManager)
    [void]$metricsGrid.Children.Add($cpu.Panel); [void]$metricsGrid.Children.Add($memory.Panel)
    [Windows.Controls.Grid]::SetRow($metricsGrid, 2); [void]$layout.Children.Add($metricsGrid)

    $details = [Windows.Controls.StackPanel]::new(); $details.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
    $gpuSummary = New-Text 'GPU · 等待数据' 11 '#DCE3DE'; $gpuSummary.FontWeight = 'SemiBold'
    $gpuWrap = [Windows.Controls.WrapPanel]::new(); $gpuWrap.Margin = [Windows.Thickness]::new(0, 7, 0, 0)
    $error = New-Text '' 8 '#FF7B72'; $error.TextWrapping = 'Wrap'; $error.Margin = [Windows.Thickness]::new(0, 7, 0, 0); $error.Visibility = 'Collapsed'
    [void]$details.Children.Add($gpuSummary); [void]$details.Children.Add($gpuWrap); [void]$details.Children.Add($error)
    [Windows.Controls.Grid]::SetRow($details, 3); [void]$layout.Children.Add($details)

    $surface.Child = $layout
    [void]$ui.ServerPanel.Children.Add($surface)
    $script:cards[[string]$server.id] = @{
        ServerId=[string]$server.id; Label=[string]$server.label; Surface=$surface; State=$state; Meta=$meta; Cpu=$cpu; Memory=$memory;
        GpuSummary=$gpuSummary; GpuWrap=$gpuWrap; GpuCards=@{}; Error=$error
    }
}

function Sync-ServerPulseCards {
    $active=@{}
    foreach($server in @($script:serverStore.Servers | Where-Object { $_.Monitored })){
        $id=[string]$server.Id;$active[$id]=$true
        if(-not $script:cards.ContainsKey($id)){Add-ServerCard $server}
        $script:cards[$id].Surface.Visibility='Visible'
        $script:cards[$id].Label=[string]$server.Label
    }
    foreach($entry in @($script:cards.GetEnumerator())){if(-not$active.ContainsKey([string]$entry.Key)){$entry.Value.Surface.Visibility='Collapsed'}}
    if($active.Count -eq 0){$ui.SummaryText.Text='尚未选择监视服务器';$ui.FleetState.Text='  未监视';$ui.FleetDot.Fill=New-Brush '#657069'}
}

Sync-ServerPulseCards

function Set-BackgroundOpacity([double]$Value) {
    $script:backgroundOpacity = [Math]::Max(0.4, [Math]::Min(1.0, $Value))
    $window.Opacity = 1.0
    $ui.WindowSurface.Background = New-AlphaBrush '#0D100E' $script:backgroundOpacity
    foreach ($card in $script:cards.Values) {
        $card.Surface.Background = New-AlphaBrush '#171A18' $script:backgroundOpacity
        foreach ($chip in $card.GpuWrap.Children) {
            $chip.Background = New-AlphaBrush '#222724' $script:backgroundOpacity
        }
    }
}

Set-BackgroundOpacity $script:backgroundOpacity

function Format-Percent($Value) {
    if ($null -eq $Value) { return '—' }
    return ('{0:0}%' -f [double]$Value)
}

function Set-Metric($cell, $value) {
    $cell.Value.Text = Format-Percent $value
    $cell.Bar.Value = if ($null -eq $value) { 0 } else { [Math]::Max(0, [Math]::Min(100, [double]$value)) }
    $cell.Bar.Foreground = if ($cell.Bar.Value -ge 90) { New-Brush '#FF6B6B' } elseif ($cell.Bar.Value -ge 75) { New-Brush '#E4B64B' } else { New-Brush '#A7D948' }
}

function New-GpuCardControl {
    param($Card, $Gpu)

    $index = [int]$Gpu.Index
    $chip = [Windows.Controls.Border]::new()
    $chip.Width = 164; $chip.Background = New-AlphaBrush '#222724' $script:backgroundOpacity
    $chip.CornerRadius = [Windows.CornerRadius]::new(6); $chip.Margin = [Windows.Thickness]::new(0,0,7,7); $chip.Padding = [Windows.Thickness]::new(9,7,9,8)
    $gpuPanel = [Windows.Controls.StackPanel]::new()
    $gpuHeader = [Windows.Controls.Grid]::new(); [void]$gpuHeader.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $gpuHeaderRight = [Windows.Controls.ColumnDefinition]::new(); $gpuHeaderRight.Width = 'Auto'; [void]$gpuHeader.ColumnDefinitions.Add($gpuHeaderRight)
    $gpuLabel = New-Text ("GPU {0}" -f $index) 10 '#DCE3DE'; $gpuLabel.FontWeight = 'SemiBold'
    $gpuTemp = New-Text '—°C' 9 '#8A958E'; $gpuTemp.HorizontalAlignment = 'Right'; [Windows.Controls.Grid]::SetColumn($gpuTemp,1)
    [void]$gpuHeader.Children.Add($gpuLabel); [void]$gpuHeader.Children.Add($gpuTemp)

    $loadValue = New-Text '—' 19 '#F2F5F3'; $loadValue.FontWeight = 'SemiBold'; $loadValue.Margin = [Windows.Thickness]::new(0,5,0,3)
    $loadBar = [Windows.Controls.ProgressBar]::new(); $loadBar.Minimum=0; $loadBar.Maximum=100; $loadBar.Height=3; $loadBar.Value=0
    $loadBar.Background=New-Brush '#343B36'; $loadBar.Foreground=New-Brush '#A7D948'

    $vramEntry = [Windows.Controls.Border]::new(); $vramEntry.Background=[Windows.Media.Brushes]::Transparent; $vramEntry.Padding=[Windows.Thickness]::new(0,4,0,0)
    $vramPanel = [Windows.Controls.StackPanel]::new()
    $vramText = New-Text '显存  —' 9 '#B5BDB8'; $vramText.Margin = [Windows.Thickness]::new(0,0,0,3)
    $vramBar = [Windows.Controls.ProgressBar]::new(); $vramBar.Minimum=0; $vramBar.Maximum=100; $vramBar.Height=3; $vramBar.Value=0
    $vramBar.Background=New-Brush '#343B36'; $vramBar.Foreground=New-Brush '#79C8D8'
    [void]$vramPanel.Children.Add($vramText); [void]$vramPanel.Children.Add($vramBar); $vramEntry.Child=$vramPanel
    [void](Register-UserUsageTarget -Target $vramEntry -Key ("{0}:gpu:{1}:vram" -f $Card.ServerId,$index) -Kind vram -Title ("{0} · GPU {1} VRAM" -f $Card.Label,$index) -ValueElement $vramText -DefaultForeground '#B5BDB8' -Manager $script:userUsagePopupManager)

    [void]$gpuPanel.Children.Add($gpuHeader); [void]$gpuPanel.Children.Add($loadValue); [void]$gpuPanel.Children.Add($loadBar); [void]$gpuPanel.Children.Add($vramEntry)
    $chip.Child = $gpuPanel
    [void]$Card.GpuWrap.Children.Add($chip)
    return @{
        Chip=$chip; Label=$gpuLabel; Temperature=$gpuTemp; LoadValue=$loadValue; LoadBar=$loadBar
        VramEntry=$vramEntry; VramText=$vramText; VramBar=$vramBar
    }
}

function Update-GpuCardControl {
    param($Control, $Gpu, $Card)

    $Control.Chip.Visibility = 'Visible'
    $Control.Label.Text = "GPU $([int]$Gpu.Index)"
    $temperature = ConvertTo-UserUsageNumber $Gpu.TemperatureC
    $Control.Temperature.Text = if ($null -eq $temperature) { '—°C' } else { '{0:0}°C' -f $temperature }
    $Control.LoadValue.Text = Format-Percent $Gpu.Utilization
    $utilization = ConvertTo-UserUsageNumber $Gpu.Utilization
    $Control.LoadBar.Value = if ($null -eq $utilization) { 0 } else { [Math]::Max(0,[Math]::Min(100,$utilization)) }
    $Control.LoadBar.Foreground = if ($Control.LoadBar.Value -ge 90) { New-Brush '#FF6B6B' } elseif ($Control.LoadBar.Value -ge 75) { New-Brush '#E4B64B' } else { New-Brush '#A7D948' }

    $usedMiB = ConvertTo-UserUsageNumber $Gpu.MemoryUsedMiB
    $totalMiB = ConvertTo-UserUsageNumber $Gpu.MemoryTotalMiB
    $vramPercent = if ($null -ne $usedMiB -and $null -ne $totalMiB -and $totalMiB -gt 0) { $usedMiB * 100.0 / $totalMiB } else { 0.0 }
    $Control.VramText.Text = "显存  $((Format-Memory $usedMiB)) / $((Format-Memory $totalMiB))"
    $Control.VramBar.Value = [Math]::Max(0,[Math]::Min(100,$vramPercent))
    $userMemory = Get-UserUsageProperty $Gpu @('UserMemory') $null
    Update-UserUsageTarget -Target $Control.VramEntry -Usage $userMemory -TotalMiB $(if ($null -eq $totalMiB) { 0.0 } else { $totalMiB }) -Title ("{0} · GPU {1} VRAM" -f $Card.Label,[int]$Gpu.Index)
}

function Hide-InactiveGpuCardControls {
    param($Card, [hashtable]$ActiveIndexes)

    foreach ($entry in @($Card.GpuCards.GetEnumerator())) {
        if (-not $ActiveIndexes.ContainsKey([string]$entry.Key)) {
            $entry.Value.Chip.Visibility = 'Collapsed'
            Update-UserUsageTarget -Target $entry.Value.VramEntry -Usage $null -TotalMiB 0
            $current = $script:userUsagePopupManager.CurrentTarget
            if ($null -ne $current -and $current.Key -eq $entry.Value.VramEntry.Tag.Key) {
                Close-UserUsagePopup $script:userUsagePopupManager
            }
        }
    }
}

function Update-ServerCard($server) {
    $card = $script:cards[[string]$server.Id]
    if ($null -eq $card) { return }
    $online = $server.Status -eq 'online'
    $retryAt=$null
    if($server.PSObject.Properties.Name-contains'RetryAt'-and-not[string]::IsNullOrWhiteSpace([string]$server.RetryAt)){try{$retryAt=[datetime]::Parse([string]$server.RetryAt).ToUniversalTime()}catch{}}
    $retrySeconds=if($null-ne$retryAt){[Math]::Max(0,[int][Math]::Ceiling(($retryAt-[datetime]::UtcNow).TotalSeconds))}else{0}
    $card.State.Text = switch([string]$server.Status){
        'online'{'● 在线'} 'authentication_required'{'● 待认证'} 'authentication_failed'{'● 认证暂停'}
        'host_key_unknown'{'● 待确认指纹'} 'host_key_changed'{'● 指纹异常'} 'connecting'{'● 连接中'}
        'retry_wait'{"● $retrySeconds 秒后重试"} 'circuit_open'{'● 重试已暂停'} default{'● 离线'}
    }
    $card.State.Foreground = New-Brush $(if ($online) { '#A7D948' } elseif($server.Status-in@('connection','connecting','retry_wait')){ '#E4B64B' } else { '#FF6B6B' })
    $card.Error.Visibility = if ($online) { 'Collapsed' } else { 'Visible' }
    $retryTimeText=if($null-ne$retryAt){$retryAt.ToLocalTime().ToString('HH:mm:ss')}else{'稍后'}
    $card.Error.Text = if($online){''}elseif($server.Status-eq'retry_wait'){"$([string]$server.Error)`n下次自动重试：$retryTimeText（连续失败 $([int]$server.ConsecutiveFailures) 次）"}elseif($server.Status-eq'circuit_open'){"$([string]$server.Error)`n已停止自动连接；请打开「管理」并点击「重新检测」。"}else{[string]$server.Error}
    if (-not $online -or $null -eq $server.Metrics) {
        $card.Meta.Text = "SSH  $($server.Host)"
        Set-Metric $card.Cpu $null; Set-Metric $card.Memory $null
        Update-UserUsageTarget -Target $card.Cpu.Panel -Usage $null -TotalMiB 0
        Update-UserUsageTarget -Target $card.Memory.Panel -Usage $null -TotalMiB 0
        $card.GpuSummary.Text = 'GPU · 暂无指标'
        Hide-InactiveGpuCardControls -Card $card -ActiveIndexes @{}
        return
    }

    $metrics = $server.Metrics
    $card.Meta.Text = "{0}   ·   {1} ms   ·   LOAD {2:0.00}" -f $metrics.Hostname, $server.LatencyMs, [double]$metrics.Load.One
    Set-Metric $card.Cpu $metrics.Cpu.Utilization
    Set-Metric $card.Memory $metrics.Memory.Percent
    $card.Memory.Value.Text = Format-MemoryUsage $metrics.Memory.Percent $metrics.Memory.UsedMiB $metrics.Memory.TotalMiB
    Update-UserUsageTarget -Target $card.Cpu.Panel -Usage (Get-UserUsageProperty $metrics.Cpu @('UserUsage') $null) -Title ("{0} · CPU" -f $card.Label)
    Update-UserUsageTarget -Target $card.Memory.Panel -Usage (Get-UserUsageProperty $metrics.Memory @('UserUsage') $null) -TotalMiB $(if ($null -eq $metrics.Memory.TotalMiB) { 0.0 } else { [double]$metrics.Memory.TotalMiB }) -Title ("{0} · MEM" -f $card.Label)
    $gpus = @($metrics.Gpus)
    $used = ($gpus | Where-Object { $null -ne $_.MemoryUsedMiB } | Measure-Object MemoryUsedMiB -Sum).Sum
    $total = ($gpus | Where-Object { $null -ne $_.MemoryTotalMiB } | Measure-Object MemoryTotalMiB -Sum).Sum
    $card.GpuSummary.Text = "GPU  {0} 块   ·   总显存 {1} / {2}" -f $gpus.Count, (Format-Memory $used), (Format-Memory $total)
    $activeIndexes = @{}
    foreach ($gpu in @($gpus | Sort-Object { [int]$_.Index })) {
        $indexKey = [string][int]$gpu.Index
        $activeIndexes[$indexKey] = $true
        if (-not $card.GpuCards.ContainsKey($indexKey)) {
            $card.GpuCards[$indexKey] = New-GpuCardControl -Card $card -Gpu $gpu
        }
        Update-GpuCardControl -Control $card.GpuCards[$indexKey] -Gpu $gpu -Card $card
    }
    Hide-InactiveGpuCardControls -Card $card -ActiveIndexes $activeIndexes
}

function Save-Settings {
    if (-not (Test-Path -LiteralPath $settingsDirectory)) { [void](New-Item -ItemType Directory -Path $settingsDirectory) }
    $left = if ($script:hiddenAtEdge) { $script:shownLeft } else { $window.Left }
    $top = if ($script:hiddenAtEdge) { $script:shownTop } else { $window.Top }
    [PSCustomObject]@{
        Version=3; ThemeMode=$script:themeMode; Opacity=[Math]::Round($script:backgroundOpacity,2); AutoHide=($ui.EdgeButton.Tag -eq 'active'); Topmost=$window.Topmost
        RefreshIntervalSeconds=$script:refreshIntervalSeconds
        Width=$window.Width; Height=$window.Height; Left=$left; Top=$top
    } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Set-RefreshInterval {
    param($Value, [switch]$Persist)

    $seconds = ConvertTo-RefreshIntervalSeconds $Value
    if ($null -eq $seconds) {
        $ui.RefreshIntervalBox.Text = [string]$script:refreshIntervalSeconds
        return $false
    }
    $changed = $seconds -ne $script:refreshIntervalSeconds
    $script:refreshIntervalSeconds = $seconds
    $ui.RefreshIntervalBox.Text = [string]$seconds
    if (-not $script:collectionBusy) {
        $script:nextCollection = [DateTime]::UtcNow.AddSeconds($seconds)
    }
    if ($Persist -and $changed -and -not $SmokeTest) { Save-Settings }
    return $true
}

function Get-WorkArea {
    $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
    $screen = [Windows.Forms.Screen]::FromHandle($handle)
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
    return [PSCustomObject]@{
        Left=$screen.WorkingArea.Left/$dpi.DpiScaleX; Top=$screen.WorkingArea.Top/$dpi.DpiScaleY
        Width=$screen.WorkingArea.Width/$dpi.DpiScaleX; Height=$screen.WorkingArea.Height/$dpi.DpiScaleY
        ScaleX=$dpi.DpiScaleX; ScaleY=$dpi.DpiScaleY
    }
}

function Update-ManualDragPosition($Cursor) {
    if (-not $script:isDragging) { return }
    $deltaX = ($Cursor.X - $script:dragStartCursor.X) / $script:dragScaleX
    $deltaY = ($Cursor.Y - $script:dragStartCursor.Y) / $script:dragScaleY
    $script:internalMove = $true
    $window.Left = $script:dragStartLeft + $deltaX
    $window.Top = $script:dragStartTop + $deltaY
    $script:internalMove = $false
}

function Stop-ManualDrag {
    if (-not $script:isDragging) { return }
    $script:isDragging = $false
    [void][Windows.Input.Mouse]::Capture($null)
    Schedule-EdgeHide
}

function Hide-ToEdge {
    if (-not $script:dockSide -or $script:hiddenAtEdge -or $ui.EdgeButton.Tag -ne 'active' -or $script:userUsagePopupManager.Popup.IsOpen) { return }
    $work = Get-WorkArea
    $script:shownLeft = $window.Left; $script:shownTop = $window.Top
    $script:internalMove = $true
    if ($script:dockSide -eq 'left') { $window.Left = $work.Left - $window.ActualWidth + 7 }
    elseif ($script:dockSide -eq 'right') { $window.Left = $work.Left + $work.Width - 7 }
    elseif ($script:dockSide -eq 'top') { $window.Top = $work.Top - $window.ActualHeight + 7 }
    $script:hiddenAtEdge = $true
    $script:edgeRevealArmed = $false
    $script:internalMove = $false
}

function Show-FromEdge {
    if (-not $script:hiddenAtEdge) { return }
    $script:internalMove = $true
    $window.Left = $script:shownLeft; $window.Top = $script:shownTop
    $script:hiddenAtEdge = $false
    $script:edgeRevealArmed = $false
    $script:internalMove = $false
}

$hideTimer = [Windows.Threading.DispatcherTimer]::new(); $hideTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$hideTimer.Add_Tick({ $hideTimer.Stop(); Hide-ToEdge })
$dockDetectTimer = [Windows.Threading.DispatcherTimer]::new(); $dockDetectTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$dockDetectTimer.Add_Tick({ $dockDetectTimer.Stop(); Schedule-EdgeHide })
function Schedule-EdgeHide {
    param($WorkArea = $null)

    if ($script:internalMove -or $script:hiddenAtEdge -or $script:userUsagePopupManager.Popup.IsOpen) { return }
    $work = if ($null -ne $WorkArea) { $WorkArea } else { Get-WorkArea }
    $script:dockSide = $null
    $targetLeft = $window.Left; $targetTop = $window.Top
    if ($window.Left -le $work.Left + 28) { $script:dockSide = 'left'; $targetLeft = $work.Left }
    elseif ($window.Left + $window.ActualWidth -ge $work.Left + $work.Width - 28) { $script:dockSide = 'right'; $targetLeft = $work.Left + $work.Width - $window.ActualWidth }
    elseif ($window.Top -le $work.Top + 28) { $script:dockSide = 'top'; $targetTop = $work.Top }
    $hideTimer.Stop()
    if ($script:dockSide -and $ui.EdgeButton.Tag -eq 'active') {
        $script:internalMove = $true
        $window.Left = $targetLeft; $window.Top = $targetTop
        $script:internalMove = $false
        $hideTimer.Start()
    }
}

$cursorTimer = [Windows.Threading.DispatcherTimer]::new(); $cursorTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$cursorTimer.Add_Tick({
    if (-not $script:hiddenAtEdge) { return }
    $work = Get-WorkArea; $cursor = [Windows.Forms.Cursor]::Position
    $x = $cursor.X / $work.ScaleX; $y = $cursor.Y / $work.ScaleY
    $touches = if ($script:dockSide -eq 'left') { $x -le $work.Left + 8 -and $y -ge $script:shownTop -and $y -le $script:shownTop + $window.ActualHeight }
        elseif ($script:dockSide -eq 'right') { $x -ge $work.Left + $work.Width - 8 -and $y -ge $script:shownTop -and $y -le $script:shownTop + $window.ActualHeight }
        else { $y -le $work.Top + 8 -and $x -ge $script:shownLeft -and $x -le $script:shownLeft + $window.ActualWidth }
    if (-not $script:edgeRevealArmed) {
        if (-not $touches) { $script:edgeRevealArmed = $true }
        return
    }
    if ($touches) { Show-FromEdge }
})
$themeFollowTimer = [Windows.Threading.DispatcherTimer]::new()
$themeFollowTimer.Interval = [TimeSpan]::FromSeconds(2)
$themeFollowTimer.Add_Tick({
    if ($script:themeMode -ne 'system') { return }
    $resolved = Resolve-ServerPulseTheme 'system'
    if ($resolved -ne $script:resolvedTheme) { Set-ServerPulseThemeMode -Mode 'system' }
})

function Get-ServerPulseAuthState {
    param([string]$ServerId)
    if(-not $script:serverAuthStates.ContainsKey($ServerId)){
        $script:serverAuthStates[$ServerId]=[PSCustomObject]@{Mode='auto';Paused=$false;Status='unknown';Notified=$false}
    }
    return $script:serverAuthStates[$ServerId]
}

function Request-ServerPulseReconnect {
    param([string]$ServerId)
    if([string]::IsNullOrWhiteSpace($ServerId)){return}
    [void]$script:forceReconnectServers.Add($ServerId)
    $state=Get-ServerPulseAuthState $ServerId;$state.Paused=$false;$state.Status='connecting';$state.Notified=$false
    $script:nextCollection=[datetime]::UtcNow
}

function Apply-ServerPulseManagedServers {
    param($Store,[object[]]$Rows)
    $script:serverStore=$Store
    foreach($row in @($Rows)){
        $state=Get-ServerPulseAuthState ([string]$row.Server.Id)
        $state.Mode=if($row.AuthMode -in @('passwordless','password')){[string]$row.AuthMode}else{'auto'}
        $state.Status=[string]$row.Status
        $state.Paused=([bool]$row.Server.Monitored -and $row.Status -in @('authentication_required','authentication_failed','host_key_unknown','host_key_changed'))
        if(-not$state.Paused){$state.Notified=$false}
    }
    if(@($script:serverAuthStates.Values|Where-Object{$_.Paused}).Count-eq0){$script:authManagerPrompted=$false}
    Sync-ServerPulseCards
    $script:nextCollection=[DateTime]::UtcNow
}

function Show-ServerPulseSshManager {
    param([switch]$Queued)
    if($Queued){
        if(-not$script:sshManagerOpenQueued){return}
        $script:sshManagerOpenQueued=$false
    }elseif($script:sshManagerOpenQueued){
        $script:sshManagerOpenQueued=$false
    }
    if($script:sshManagerOpen){if($null-ne$script:sshManagerWindow-and$script:sshManagerWindow.IsVisible){[void]$script:sshManagerWindow.Activate()};return}
    Close-UserUsagePopup $script:userUsagePopupManager
    $script:authManagerPrompted=$true
    $script:sshManagerOpen=$true
    try{
        $manager=Show-ServerPulseServerManager -Owner $window -Store $script:serverStore -SessionSecrets $script:sessionSecrets -AskPassPath $script:askPassPath -TimeoutMs $config.SshTimeoutMs -ValidationStates $script:serverAuthStates -OnRetryRequested {param($serverId);Request-ServerPulseReconnect $serverId} -OnApplied {param($store,$rows);Apply-ServerPulseManagedServers $store $rows}
        $script:sshManagerWindow=$manager.Window
        $manager.Window.Add_Closed({$script:sshManagerOpen=$false;$script:sshManagerWindow=$null})
    }catch{$script:sshManagerOpen=$false;$script:sshManagerWindow=$null;throw}
}

function Queue-ServerPulseSshManager {
    if($script:sshManagerOpen-or$script:sshManagerOpenQueued){return}
    $script:sshManagerOpenQueued=$true
    [void]$window.Dispatcher.BeginInvoke([Action]{Show-ServerPulseSshManager -Queued},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
}

function Show-ServerPulseFromTray {
    if ($script:hiddenAtEdge) { Show-FromEdge }
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) { $window.WindowState = [Windows.WindowState]::Normal }
    if (-not $window.IsVisible) { $window.Show() }
    [void]$window.Activate()
}

function Hide-ServerPulseToTray {
    Close-UserUsagePopup $script:userUsagePopupManager
    $hideTimer.Stop(); $dockDetectTimer.Stop()
    if ($script:hiddenAtEdge) { Show-FromEdge }
    $window.WindowState = [Windows.WindowState]::Minimized
}

$script:trayMenu = [Windows.Forms.ContextMenuStrip]::new()
$trayShowItem = $script:trayMenu.Items.Add('显示窗口')
$trayHideItem = $script:trayMenu.Items.Add('隐藏窗口')
$trayServersItem = $script:trayMenu.Items.Add('SSH 服务器...')
[void]$script:trayMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$trayExitItem = $script:trayMenu.Items.Add('退出')
$trayShowItem.Add_Click({ Show-ServerPulseFromTray })
$trayHideItem.Add_Click({ Hide-ServerPulseToTray })
$trayServersItem.Add_Click({ Show-ServerPulseFromTray; Show-ServerPulseSshManager })
$trayExitItem.Add_Click({ $window.Close() })
$script:trayIcon = [Windows.Forms.NotifyIcon]::new()
$script:trayIcon.Text = 'Server Pulse - SSH 资源监控'
$script:trayOwnedIcon = $null
$trayIconPath = Join-Path $scriptRoot 'assets\server-pulse.ico'
try {
    if (-not (Test-Path -LiteralPath $trayIconPath)) { throw '图标资源不存在' }
    $script:trayOwnedIcon = [Drawing.Icon]::new($trayIconPath)
    $script:trayIcon.Icon = $script:trayOwnedIcon
} catch {
    $script:trayIcon.Icon = [Drawing.SystemIcons]::Application
}
$script:trayIcon.ContextMenuStrip = $script:trayMenu
$script:trayIcon.Visible = $true
$script:trayIcon.Add_MouseClick({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-ServerPulseFromTray }
})
$script:trayIcon.Add_BalloonTipClicked({Show-ServerPulseFromTray;Show-ServerPulseSshManager})

function Save-NativeScreenshot {
    param([string]$FileName='native-window.png')
    $directory = Join-Path $scriptRoot 'tests\artifacts'
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
    $width = [Math]::Max(1, [int]($window.ActualWidth * $dpi.DpiScaleX))
    $height = [Math]::Max(1, [int]($window.ActualHeight * $dpi.DpiScaleY))
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $visual = [Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    $context.PushTransform([Windows.Media.ScaleTransform]::new($dpi.DpiScaleX, $dpi.DpiScaleY))
    $context.DrawRectangle([Windows.Media.VisualBrush]::new($window), $null, [Windows.Rect]::new(0, 0, $window.ActualWidth, $window.ActualHeight))
    $context.Pop()
    $context.Close()
    $bitmap.Render($visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $directory $FileName))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Complete-SmokeTest {
    if (-not $SmokeTest -or $script:smokeFinished) { return }
    $script:smokeFinished = $true
    try {
        $window.UpdateLayout()
        if ($window.ShowInTaskbar) { throw '主窗口不应显示在任务栏' }
        if ($null -eq $script:trayIcon -or -not $script:trayIcon.Visible) { throw '托盘图标创建失败' }
        if ($null -eq $script:trayOwnedIcon) { throw 'Server Pulse 自定义托盘图标加载失败' }
        Hide-ServerPulseToTray
        if ($window.WindowState -ne [Windows.WindowState]::Minimized) { throw '隐藏到托盘失败' }
        Show-ServerPulseFromTray
        if ($window.WindowState -ne [Windows.WindowState]::Normal -or -not $window.IsVisible) { throw '从托盘恢复窗口失败' }
        $ui.ThemeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if(-not$script:themePopup.IsOpen-or$script:themeChoiceRows.Count-ne3){throw '主题切换菜单按钮事件失败'}
        $script:themePopup.IsOpen=$false
        $originalThemeMode=$script:themeMode
        Set-ServerPulseThemeMode -Mode light
        $window.UpdateLayout()
        if($script:resolvedTheme-ne'light'-or$ui.ThemeButtonText.Text-ne'亮'-or$ui.WindowSurface.Background.Color.R-lt220){throw '主窗口亮色主题切换失败'}
        Save-NativeScreenshot 'native-window-light.png'
        $managerSmoke=Show-ServerPulseServerManager -Owner $window -Store $script:serverStore -SessionSecrets $script:sessionSecrets -AskPassPath $script:askPassPath -TimeoutMs $config.SshTimeoutMs -OnApplied {} -SmokeTest
        $managerSmoke.Window.Show();$managerSmoke.Window.UpdateLayout()
        if($managerSmoke.Context.Rows.Count-lt1-or$null-eq$managerSmoke.Context.Rows[0].Passwordless-or$null-eq$managerSmoke.Context.Rows[0].PasswordBox){throw 'SSH 服务器管理窗口验证失败'}
        if($managerSmoke.Window.Background.Color.R-lt220){throw 'SSH 管理窗口未继承亮色主题'}
        $managerSmoke.Window.Close()
        Set-ServerPulseThemeMode -Mode dark
        if($script:resolvedTheme-ne'dark'-or$ui.ThemeButtonText.Text-ne'暗'-or$ui.WindowSurface.Background.Color.R-gt80){throw '主窗口暗色主题还原失败'}
        Set-ServerPulseThemeMode -Mode $originalThemeMode
        Save-NativeScreenshot
        $originalOpacity = $script:backgroundOpacity; Set-BackgroundOpacity 0.55
        if ($window.Opacity -ne 1.0) { throw '文字层透明度不应改变' }
        if ($ui.WindowSurface.Background.Color.A -ge 255) { throw "背景透明度验证失败（Alpha=$($ui.WindowSurface.Background.Color.A)，Value=$script:backgroundOpacity）" }
        $originalWidth = $window.Width; $window.Width = $originalWidth + 20
        if ($window.Width -le $originalWidth) { throw '尺寸调节验证失败' }
        $window.Width = $originalWidth; Set-BackgroundOpacity $originalOpacity
        $originalInterval = $script:refreshIntervalSeconds
        if (-not (Set-RefreshInterval 12) -or $script:refreshIntervalSeconds -ne 12 -or $ui.RefreshIntervalBox.Text -ne '12') { throw '刷新间隔调节验证失败' }
        if (Set-RefreshInterval 'invalid') { throw '无效刷新间隔不应生效' }
        if ($script:refreshIntervalSeconds -ne 12 -or $ui.RefreshIntervalBox.Text -ne '12') { throw '无效刷新间隔应恢复当前值' }
        [void](Set-RefreshInterval $originalInterval)
        $historyRecord = Get-CurrentHistoryMinuteRecord $script:historyRecorder
        if ($null -eq $historyRecord -or @($historyRecord.Servers).Count -ne 2) { throw '历史分钟记录验证失败' }
        $beforeHistoryTheme=$script:themeMode;Set-ServerPulseThemeMode -Mode light
        $historySmoke = Show-ServerPulseHistoryWindow -Owner $window -Recorder $script:historyRecorder -ScreenshotPath (Join-Path $scriptRoot 'tests\artifacts\history-window.png') -SmokeTest
        Set-ServerPulseThemeMode -Mode $beforeHistoryTheme
        if($historySmoke.ThemeBackgroundR-lt220){throw '历史记录窗口未继承亮色主题'}
        if (-not $historySmoke.QueryClickPassed) { throw "历史查询按钮事件失败：$($historySmoke.QueryClickError)" }
        if (-not $historySmoke.QueryFailureContained) { throw '历史查询异常未被窗口内提示安全拦截' }
        if (-not $historySmoke.ChangedRangeQueryPassed) { throw "修改时间后的历史查询失败：$($historySmoke.ChangedRangeQueryError)" }
        if (-not $historySmoke.NormalRenderPassed) { throw '历史图表正常渲染失败' }
        if (-not $historySmoke.HoverInteractionPassed) { throw "历史图表悬停交互失败：$($historySmoke.HoverInteractionError)" }
        if (-not $historySmoke.CloseHitTestPassed) { throw "历史窗口关闭按钮被其他元素遮挡：$($historySmoke.CloseHitElement)" }
        if (-not $historySmoke.CloseSeparatedFromDragArea) { throw '历史窗口关闭按钮位于拖拽事件区域内' }
        if (-not $historySmoke.CloseButtonPassed) { throw "历史窗口关闭按钮失败：$($historySmoke.CloseButtonError)" }
        if ($historySmoke.PanelCount -lt 1 -or -not (ConvertFrom-HistoryMinuteText $historySmoke.Start) -or -not (ConvertFrom-HistoryMinuteText $historySmoke.End) -or -not $historySmoke.ValidationPassed) { throw '历史窗口、默认时间范围与红框校验失败' }
        $errorDialogSmoke=Show-ServerPulseErrorDialog -Owner $window -Title '历史记录错误' -Message '无法打开占用记录。' -Detail '测试异常' -LogPath 'C:\test\error.log' -SmokeTest
        if(-not$errorDialogSmoke.Topmost-or$errorDialogSmoke.ShowInTaskbar-or-not$errorDialogSmoke.OwnerMatches-or$errorDialogSmoke.Title-ne'历史记录错误'){throw '历史记录错误弹窗层级或所有者验证失败'}
        $script:dispatcherProbeHandled = $false
        [void]$window.Dispatcher.BeginInvoke([Action]{ throw 'ServerPulse dispatcher containment probe' },[Windows.Threading.DispatcherPriority]::Background)
        $probeFrame=[Windows.Threading.DispatcherFrame]::new()
        [void]$window.Dispatcher.BeginInvoke([Action]{ $probeFrame.Continue=$false }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        [Windows.Threading.Dispatcher]::PushFrame($probeFrame)
        if (-not $script:dispatcherProbeHandled) { throw '未处理的 UI 事件异常未被安全拦截' }
        # The pointer may have opened a hover preview while the smoke screenshot was rendered.
        # Close it so the edge-docking probe tests docking itself, not the intentional popup pause.
        Close-UserUsagePopup $script:userUsagePopupManager
        $hideTimer.Stop(); $dockDetectTimer.Stop(); Show-FromEdge
        $dragLeft = $window.Left; $dragTop = $window.Top
        $script:isDragging = $true; $script:dragStartCursor = [PSCustomObject]@{X=100;Y=100}; $script:dragStartLeft=$dragLeft; $script:dragStartTop=$dragTop; $script:dragScaleX=1.0; $script:dragScaleY=1.0
        Update-ManualDragPosition ([PSCustomObject]@{X=132;Y=118})
        $script:isDragging = $false
        if ([Math]::Abs($window.Left - ($dragLeft + 32)) -gt 1.0 -or [Math]::Abs($window.Top - ($dragTop + 18)) -gt 1.0) { throw "自定义拖拽验证失败（起点=$dragLeft,$dragTop；实际=$($window.Left),$($window.Top)）" }
        $script:internalMove = $true; $window.Left=$dragLeft; $window.Top=$dragTop; $script:internalMove = $false
        $work = Get-WorkArea
        $window.Left = $work.Left + 200; $window.Top = $work.Top + 80
        $script:isDragging = $true
        $script:dragStartCursor = [PSCustomObject]@{X=($window.Left + 110) * $work.ScaleX;Y=($window.Top + 16) * $work.ScaleY}
        $script:dragStartLeft = $window.Left; $script:dragStartTop = $window.Top; $script:dragScaleX=$work.ScaleX; $script:dragScaleY=$work.ScaleY
        Update-ManualDragPosition ([PSCustomObject]@{X=$work.Left * $work.ScaleX;Y=$script:dragStartCursor.Y})
        $script:isDragging = $false; Schedule-EdgeHide -WorkArea $work
        if ($script:dockSide -ne 'left' -or -not $hideTimer.IsEnabled) { throw "左侧越界贴边检测失败（Left=$($window.Left)）" }
        $hideTimer.Stop(); Hide-ToEdge
        if (-not $script:hiddenAtEdge) { throw '左侧贴边隐藏验证失败' }
        if ($script:edgeRevealArmed) { throw '贴边后不应立即允许唤回' }
        $script:edgeRevealArmed = $true; Show-FromEdge
        $window.Left = $work.Left + $work.Width - $window.ActualWidth - 200
        $script:isDragging = $true
        $script:dragStartCursor = [PSCustomObject]@{X=($window.Left + 110) * $work.ScaleX;Y=($window.Top + 16) * $work.ScaleY}
        $script:dragStartLeft = $window.Left; $script:dragStartTop = $window.Top; $script:dragScaleX=$work.ScaleX; $script:dragScaleY=$work.ScaleY
        Update-ManualDragPosition ([PSCustomObject]@{X=($work.Left + $work.Width) * $work.ScaleX;Y=$script:dragStartCursor.Y})
        $script:isDragging = $false; Schedule-EdgeHide -WorkArea $work
        if ($script:dockSide -ne 'right' -or -not $hideTimer.IsEnabled) { throw "右侧越界贴边检测失败（Right=$($window.Left + $window.ActualWidth)）" }
        $hideTimer.Stop(); Hide-ToEdge
        if (-not $script:hiddenAtEdge) { throw '右侧贴边隐藏验证失败' }
        $script:edgeRevealArmed = $true; Show-FromEdge
        $script:smokePassed = $true
        $window.Close()
    } catch {
        $script:smokeError = $_.Exception.Message
        $window.Close()
    }
}

function Start-CollectionWorker {
    if($script:collectionProcess -and -not $script:collectionProcess.HasExited){return $true}
    if($script:collectionProcess){$script:collectionProcess.Dispose();$script:collectionProcess=$null}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='powershell.exe'
    $info.Arguments="-NoProfile -ExecutionPolicy Bypass -File `"$collectorPath`" -ConfigPath `"$configPath`" -Worker"
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8
    $script:collectionProcess=[Diagnostics.Process]::Start($info)
    $script:stderrTask=$script:collectionProcess.StandardError.ReadToEndAsync()
    return $true
}

function Stop-CollectionWorker {
    $script:collectionBusy=$false;$script:stdoutTask=$null
    if(-not$script:collectionProcess){return}
    try{$script:collectionProcess.StandardInput.Close()}catch{}
    try{if(-not$script:collectionProcess.WaitForExit(1500)){$script:collectionProcess.Kill()}}catch{}
    $script:collectionProcess.Dispose();$script:collectionProcess=$null
}

function Start-Collection {
    if($script:collectionBusy){return}
    $runtimeServers=@()
    foreach($server in @($script:serverStore.Servers | Where-Object { $_.Monitored })){
        $state=Get-ServerPulseAuthState ([string]$server.Id)
        if($state.Paused){continue}
        $password=Get-ServerPulseSessionSecret $script:sessionSecrets $server.Identity
        if($null-eq$password){$stored=Get-ServerPulseStoredCredential $server.Identity;if($null-ne$stored){$password=[string]$stored.Password}}
        $runtimeServers += [PSCustomObject]@{
            Id=[string]$server.Id;Label=[string]$server.Label;Source=[string]$server.Source;SshTarget=[string]$server.SshTarget
            HostName=[string]$server.HostName;Port=[int]$server.Port;User=[string]$server.User;AuthMode=[string]$state.Mode;Password=$password
        }
    }
    if($runtimeServers.Count -eq 0){
        $selected=@($script:serverStore.Servers|Where-Object{$_.Monitored}).Count
        $ui.SummaryText.Text=if($selected -eq 0){'尚未选择监视服务器'}else{'所选服务器正在等待认证'}
        $ui.UpdatedText.Text=[DateTime]::Now.ToString('HH:mm:ss')
        $script:nextCollection=[DateTime]::UtcNow.AddSeconds($script:refreshIntervalSeconds)
        return
    }
    $forcedReconnects=@($script:forceReconnectServers)
    $runtimePayload=[PSCustomObject]@{SshTimeoutMs=$config.SshTimeoutMs;PollIntervalSeconds=$script:refreshIntervalSeconds;AskPassPath=$script:askPassPath;ForceReconnect=$forcedReconnects;Servers=$runtimeServers}|ConvertTo-Json -Depth 6 -Compress
    $password=$null;$stored=$null
    try{
        [void](Start-CollectionWorker)
        $script:collectionProcess.StandardInput.WriteLine($runtimePayload);$script:collectionProcess.StandardInput.Flush();foreach($serverId in $forcedReconnects){[void]$script:forceReconnectServers.Remove([string]$serverId)}
        $script:stdoutTask=$script:collectionProcess.StandardOutput.ReadLineAsync();$script:collectionBusy=$true
    }catch{
        $ui.SummaryText.Text="采集器启动失败：$($_.Exception.Message)";Stop-CollectionWorker
        $script:nextCollection=[DateTime]::UtcNow.AddSeconds($script:refreshIntervalSeconds)
    }finally{
        $runtimePayload=$null;foreach($item in $runtimeServers){$item.Password=$null}
    }
}

$pollTimer = [Windows.Threading.DispatcherTimer]::new(); $pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$pollTimer.Add_Tick({
    if ($script:collectionProcess -and $script:collectionProcess.HasExited) {
        $stderr=if($script:stderrTask -and $script:stderrTask.IsCompleted){$script:stderrTask.Result.Trim()}else{''}
        $script:collectionProcess.Dispose();$script:collectionProcess=$null;$script:collectionBusy=$false;$script:stdoutTask=$null
        $ui.SummaryText.Text=if($stderr){"采集器错误：$stderr"}else{'采集器意外退出，正在重启'}
        $script:nextCollection=[DateTime]::UtcNow.AddSeconds($script:refreshIntervalSeconds)
    }
    if($script:collectionBusy -and $script:stdoutTask -and $script:stdoutTask.IsCompleted){
        $stdout=([string]$script:stdoutTask.Result).Trim();$script:collectionBusy=$false;$script:stdoutTask=$null;$connectionPending=$false
        if ($stdout) {
            try {
                $snapshot = $stdout | ConvertFrom-Json
                if($snapshot.PSObject.Properties.Name -contains 'WorkerError' -and $snapshot.WorkerError){throw [string]$snapshot.WorkerError}
                try { Add-ServerPulseHistorySnapshot -Recorder $script:historyRecorder -Snapshot $snapshot } catch { $ui.HistoryButton.ToolTip = "历史记录失败：$($_.Exception.Message)" }
                $servers = @($snapshot.Servers)
                $shouldPromptAuth=$false
                foreach ($server in $servers) {
                    $authState=Get-ServerPulseAuthState ([string]$server.Id)
                    $authState.Status=[string]$server.Status
                    if($server.Status -eq 'online'){$authState.Mode=[string]$server.AuthMode;$authState.Paused=$false;$authState.Notified=$false}
                    elseif($server.Status -in @('authentication_required','authentication_failed','host_key_unknown','host_key_changed')){
                        $authState.Paused=$true
                        $shouldPromptAuth=$true
                        if(-not$authState.Notified -and -not$SmokeTest){
                            $script:trayIcon.BalloonTipTitle='Server Pulse 需要处理 SSH 认证'
                            $script:trayIcon.BalloonTipText="$($server.Label)：$($server.Error)"
                            $script:trayIcon.ShowBalloonTip(6000);$authState.Notified=$true
                        }
                    }
                    Update-ServerCard $server
                }
                if($shouldPromptAuth -and -not$script:authManagerPrompted -and -not$SmokeTest){Queue-ServerPulseSshManager}
                $online = @($servers | Where-Object { $_.Status -eq 'online' }).Count
                $selectedCount=@($script:serverStore.Servers|Where-Object{$_.Monitored}).Count
                $gpuCount = ($servers | Where-Object { $_.Status -eq 'online' } | ForEach-Object { @($_.Metrics.Gpus).Count } | Measure-Object -Sum).Sum
                if ($null -eq $gpuCount) { $gpuCount = 0 }
                $ui.SummaryText.Text = "$online / $selectedCount 在线   ·   $gpuCount GPU"
                $ui.UpdatedText.Text = [DateTime]::Now.ToString('HH:mm:ss')
                $ui.FleetState.Text = if ($selectedCount -gt 0 -and $online -eq $selectedCount) { '  全部在线' } else { "  $online / $selectedCount 在线" }
                $ui.FleetDot.Fill = New-Brush $(if ($selectedCount -gt 0 -and $online -eq $selectedCount) { '#A7D948' } elseif ($online -gt 0) { '#E4B64B' } else { '#FF6B6B' })
                $connectionPending=@($servers|Where-Object{$_.Status-in@('connecting','retry_wait')}).Count-gt0
                if ($SmokeTest -and -not $script:smokeFinished) {
                    [void]$window.Dispatcher.BeginInvoke(
                        [Action]{ Complete-SmokeTest },
                        [Windows.Threading.DispatcherPriority]::Background
                    )
                }
            } catch { $ui.SummaryText.Text = "采集结果错误：$($_.Exception.Message)" }
        } else { $ui.SummaryText.Text='采集器未返回数据' }
        $script:nextCollection = [DateTime]::UtcNow.AddSeconds($(if($connectionPending){1}else{$script:refreshIntervalSeconds}))
    }
    if (-not $script:collectionBusy -and [DateTime]::UtcNow -ge $script:nextCollection) { Start-Collection }
})

$ui.DragArea.Add_MouseLeftButtonDown({
    param($sender, $event)
    if ($event.ChangedButton -eq 'Left') {
        $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
        $script:isDragging = $true
        $script:dragStartCursor = [Windows.Forms.Cursor]::Position
        $script:dragStartLeft = $window.Left
        $script:dragStartTop = $window.Top
        $script:dragScaleX = $dpi.DpiScaleX
        $script:dragScaleY = $dpi.DpiScaleY
        $hideTimer.Stop(); $dockDetectTimer.Stop()
        [void][Windows.Input.Mouse]::Capture($ui.DragArea)
        $event.Handled = $true
    }
})
$ui.DragArea.Add_MouseMove({
    if ($script:isDragging -and [Windows.Input.Mouse]::LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        Update-ManualDragPosition ([Windows.Forms.Cursor]::Position)
    }
})
$ui.DragArea.Add_MouseLeftButtonUp({ Stop-ManualDrag })
$ui.DragArea.Add_LostMouseCapture({
    if ($script:isDragging -and [Windows.Input.Mouse]::LeftButton -ne [Windows.Input.MouseButtonState]::Pressed) {
        $script:isDragging = $false
        Schedule-EdgeHide
    }
})
$window.Add_LocationChanged({
    if (-not $script:internalMove -and -not $script:hiddenAtEdge) {
        $hideTimer.Stop(); $dockDetectTimer.Stop(); $dockDetectTimer.Start()
    }
})
$window.Add_MouseLeave({ if ($script:dockSide -and -not $script:hiddenAtEdge -and $ui.EdgeButton.Tag -eq 'active' -and -not $script:userUsagePopupManager.Popup.IsOpen) { $hideTimer.Start() } })
$ui.ThemeButton.Add_Click({ $script:themePopup.IsOpen = -not $script:themePopup.IsOpen })
$ui.OpacitySlider.Add_ValueChanged({ Set-BackgroundOpacity ($ui.OpacitySlider.Value / 100) })
$ui.RefreshIntervalBox.Add_PreviewTextInput({ param($sender,$event); if ($event.Text -notmatch '^\d+$') { $event.Handled = $true } })
$ui.RefreshIntervalBox.Add_PreviewKeyDown({
    param($sender,$event)
    if ($event.Key -eq [Windows.Input.Key]::Enter) {
        [void](Set-RefreshInterval $ui.RefreshIntervalBox.Text -Persist)
        [Windows.Input.Keyboard]::ClearFocus()
        $event.Handled = $true
    }
})
$ui.RefreshIntervalBox.Add_LostKeyboardFocus({ [void](Set-RefreshInterval $ui.RefreshIntervalBox.Text -Persist) })
$ui.HistoryButton.Add_Click({
    try { Show-ServerPulseHistoryWindow -Owner $window -Recorder $script:historyRecorder }
    catch {
        $historyException=$_.Exception
        $logPath=$null
        try{$logPath=Write-ServerPulseErrorLog -Exception $historyException -Context 'Open history window'}catch{}
        try{
            Show-ServerPulseErrorDialog -Owner $window -Title '历史记录错误' -Message '无法打开占用记录，主监控仍会继续运行。' -Detail $historyException.Message -LogPath $logPath
        }catch{
            [void][Windows.MessageBox]::Show($window,("无法打开占用记录。`n`n{0}" -f $historyException.Message),'Server Pulse · 历史记录错误','OK','Error')
        }
    }
})
$ui.EdgeButton.Add_Click({
    if ($ui.EdgeButton.Tag -eq 'active') { $ui.EdgeButton.Tag = $null; $hideTimer.Stop(); Show-FromEdge }
    else { $ui.EdgeButton.Tag = 'active'; Schedule-EdgeHide }
})
$ui.PinButton.Add_Click({ $window.Topmost = -not $window.Topmost; $ui.PinButton.Tag = if ($window.Topmost) { 'active' } else { $null } })
$ui.ServerButton.Add_Click({ Show-ServerPulseSshManager })
$ui.MinimizeButton.Add_Click({ Hide-ServerPulseToTray })
$ui.CloseButton.Add_Click({ Close-UserUsagePopup $script:userUsagePopupManager; $window.Close() })

$window.Add_Loaded({
    if ($null -ne $settings.Left -and $null -ne $settings.Top) {
        $window.Left = [double]$settings.Left; $window.Top = [double]$settings.Top
    }
    $cursorTimer.Start(); $themeFollowTimer.Start(); $pollTimer.Start(); Start-Collection
    if(($script:firstServerStoreRun -or @($script:serverStore.Servers|Where-Object{$_.Monitored}).Count-eq0) -and -not$SmokeTest){Queue-ServerPulseSshManager}
})
$window.Add_Closing({
    Close-UserUsagePopup $script:userUsagePopupManager
    if($null-ne$script:sshManagerWindow-and$script:sshManagerWindow.IsVisible){$script:sshManagerWindow.Close()}
    $pollTimer.Stop(); $cursorTimer.Stop(); $themeFollowTimer.Stop(); $hideTimer.Stop(); $dockDetectTimer.Stop()
    $script:trayIcon.Visible = $false
    $script:trayIcon.Dispose()
    if ($null -ne $script:trayOwnedIcon) { $script:trayOwnedIcon.Dispose(); $script:trayOwnedIcon = $null }
    $script:trayMenu.Dispose()
    Clear-ServerPulseSessionSecrets $script:sessionSecrets
    Stop-CollectionWorker
    if (-not $SmokeTest) { try { [void](Flush-ServerPulseHistoryRecorder $script:historyRecorder) } catch { } }
    if (-not $SmokeTest) { Save-Settings }
})

[void]$window.ShowDialog()
if ($SmokeTest) {
    if ($script:smokeError) { throw $script:smokeError }
    if (-not $script:smokePassed) { throw '原生窗口冒烟测试未完成' }
    Write-Output 'PASS: native window, light/dark theme, tray, SSH manager, resize, opacity, edge hide, SSH snapshot'
}
