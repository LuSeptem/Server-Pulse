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
        Background="Transparent" ShowInTaskbar="True" WindowStartupLocation="CenterScreen"
        FontFamily="Bahnschrift, Microsoft YaHei UI" Foreground="#E7EBE8">
  <Window.Resources>
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
                <Setter TargetName="Surface" Property="Background" Value="#252A27"/>
                <Setter Property="Foreground" Value="#F4F7F5"/>
              </Trigger>
              <Trigger Property="Tag" Value="active">
                <Setter TargetName="Surface" Property="Background" Value="#A7D948"/>
                <Setter Property="Foreground" Value="#0B0E0C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
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
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Background" Value="#B9EC58"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Background" Value="#91C235"/></Trigger>
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
          <Slider x:Name="OpacitySlider" Width="58" Minimum="40" Maximum="100" Value="94" TickFrequency="5"
                  IsSnapToTickEnabled="True" ToolTip="透明度" Foreground="#A7D948" Margin="4,0,6,0"/>
          <Button x:Name="EdgeButton" Content="边" Style="{StaticResource QuietButton}" ToolTip="贴边自动隐藏"/>
          <Button x:Name="PinButton" Content="置" Style="{StaticResource QuietButton}" ToolTip="始终置顶"/>
          <Button x:Name="MinimizeButton" Content="—" Style="{StaticResource QuietButton}" ToolTip="最小化"/>
          <Button x:Name="CloseButton" Content="×" Style="{StaticResource QuietButton}" ToolTip="关闭"/>
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
            <TextBlock x:Name="SummaryText" Text="等待首次采集" Foreground="#939D97" FontSize="10" VerticalAlignment="Center"/>
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
$names = 'WindowSurface','DragArea','FleetDot','FleetState','OpacitySlider','EdgeButton','PinButton','MinimizeButton','CloseButton','SummaryText','HistoryButton','RefreshIntervalBox','UpdatedText','ServerPanel'
$ui = @{}
foreach ($name in $names) { $ui[$name] = $window.FindName($name) }

$settingsDirectory = Join-Path $env:LOCALAPPDATA 'ServerPulse'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$settings = [PSCustomObject]@{ Version = 2; Opacity = 0.94; AutoHide = $true; Topmost = $true; RefreshIntervalSeconds = $null; Width = 420.0; Height = 560.0; Left = $null; Top = $null }
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

. (Join-Path $scriptRoot 'src\ServerPulse.Core.ps1')
. (Join-Path $scriptRoot 'src\ServerPulse.History.ps1')
$config = Get-ServerPulseConfig -Path $configPath
$configuredInterval = ConvertTo-RefreshIntervalSeconds ([Math]::Round($config.PollIntervalMs / 1000))
$savedInterval = ConvertTo-RefreshIntervalSeconds $settings.RefreshIntervalSeconds
$script:refreshIntervalSeconds = if ($null -ne $savedInterval) { $savedInterval } elseif ($null -ne $configuredInterval) { $configuredInterval } else { 5 }
$ui.RefreshIntervalBox.Text = [string]$script:refreshIntervalSeconds
$historyDirectory = Join-Path $settingsDirectory 'history'
$script:historyRecorder = New-ServerPulseHistoryRecorder -Directory $historyDirectory -RetentionDays $config.HistoryRetentionDays
if (-not $SmokeTest) { try { Remove-ExpiredServerPulseHistory $script:historyRecorder } catch { } }
$script:cards = @{}
$script:collectionProcess = $null
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

function New-Brush([string]$Color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function New-AlphaBrush([string]$Color, [double]$Opacity) {
    $base = [Windows.Media.ColorConverter]::ConvertFromString($Color)
    $alpha = [byte][Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, $Opacity)) * 255)
    $value = [Windows.Media.Color]::FromArgb($alpha, $base.R, $base.G, $base.B)
    $brush = [Windows.Media.SolidColorBrush]::new()
    $brush.Color = $value
    return $brush
}

function New-Text([string]$Text, [double]$Size, [string]$Color) {
    $block = [Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = New-Brush $Color
    $block.VerticalAlignment = 'Center'
    return $block
}

function New-MetricCell([string]$Label) {
    $panel = [Windows.Controls.StackPanel]::new()
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

function Add-ServerCard($server) {
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

    $meta = New-Text ("SSH  {0}" -f $server.host) 8 '#626C66'
    $meta.Margin = [Windows.Thickness]::new(0, 3, 0, 6)
    [Windows.Controls.Grid]::SetRow($meta, 1); [void]$layout.Children.Add($meta)

    $metricsGrid = [Windows.Controls.Primitives.UniformGrid]::new(); $metricsGrid.Columns = 2
    $cpu = New-MetricCell 'CPU'; $memory = New-MetricCell 'MEM'
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
        Surface=$surface; State=$state; Meta=$meta; Cpu=$cpu; Memory=$memory;
        GpuSummary=$gpuSummary; GpuWrap=$gpuWrap; Error=$error
    }
}

foreach ($server in $config.Servers) { Add-ServerCard $server }

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

function Update-ServerCard($server) {
    $card = $script:cards[[string]$server.Id]
    if ($null -eq $card) { return }
    $online = $server.Status -eq 'online'
    $card.State.Text = if ($online) { '● 在线' } else { '● 离线' }
    $card.State.Foreground = New-Brush $(if ($online) { '#A7D948' } else { '#FF6B6B' })
    $card.Error.Visibility = if ($online) { 'Collapsed' } else { 'Visible' }
    $card.Error.Text = if ($online) { '' } else { [string]$server.Error }
    if (-not $online -or $null -eq $server.Metrics) {
        $card.Meta.Text = "SSH  $($server.Host)"
        Set-Metric $card.Cpu $null; Set-Metric $card.Memory $null
        $card.GpuSummary.Text = 'GPU · 暂无指标'
        $card.GpuWrap.Children.Clear()
        return
    }

    $metrics = $server.Metrics
    $card.Meta.Text = "{0}   ·   {1} ms   ·   LOAD {2:0.00}" -f $metrics.Hostname, $server.LatencyMs, [double]$metrics.Load.One
    Set-Metric $card.Cpu $metrics.Cpu.Utilization
    Set-Metric $card.Memory $metrics.Memory.Percent
    $card.Memory.Value.Text = Format-MemoryUsage $metrics.Memory.Percent $metrics.Memory.UsedMiB $metrics.Memory.TotalMiB
    $gpus = @($metrics.Gpus)
    $used = ($gpus | Where-Object { $null -ne $_.MemoryUsedMiB } | Measure-Object MemoryUsedMiB -Sum).Sum
    $total = ($gpus | Where-Object { $null -ne $_.MemoryTotalMiB } | Measure-Object MemoryTotalMiB -Sum).Sum
    $card.GpuSummary.Text = "GPU  {0} 块   ·   总显存 {1} / {2}" -f $gpus.Count, (Format-Memory $used), (Format-Memory $total)
    $card.GpuWrap.Children.Clear()
    foreach ($gpu in $gpus) {
        $chip = [Windows.Controls.Border]::new(); $chip.Width = 164; $chip.Background = New-AlphaBrush '#222724' $script:backgroundOpacity; $chip.CornerRadius = [Windows.CornerRadius]::new(6); $chip.Margin = [Windows.Thickness]::new(0,0,7,7); $chip.Padding = [Windows.Thickness]::new(9,7,9,8)
        $gpuPanel = [Windows.Controls.StackPanel]::new()
        $gpuHeader = [Windows.Controls.Grid]::new(); [void]$gpuHeader.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()); $gpuHeaderRight = [Windows.Controls.ColumnDefinition]::new(); $gpuHeaderRight.Width = 'Auto'; [void]$gpuHeader.ColumnDefinitions.Add($gpuHeaderRight)
        $gpuLabel = New-Text ("GPU {0}" -f [int]$gpu.Index) 10 '#DCE3DE'; $gpuLabel.FontWeight = 'SemiBold'
        $gpuTemp = New-Text ("{0:0}°C" -f [double]$gpu.TemperatureC) 9 '#8A958E'; $gpuTemp.HorizontalAlignment = 'Right'; [Windows.Controls.Grid]::SetColumn($gpuTemp,1)
        [void]$gpuHeader.Children.Add($gpuLabel); [void]$gpuHeader.Children.Add($gpuTemp)
        $loadValue = New-Text (Format-Percent $gpu.Utilization) 19 '#F2F5F3'; $loadValue.FontWeight = 'SemiBold'; $loadValue.Margin = [Windows.Thickness]::new(0,5,0,3)
        $loadBar = [Windows.Controls.ProgressBar]::new(); $loadBar.Minimum=0; $loadBar.Maximum=100; $loadBar.Height=3; $loadBar.Value=if($null -eq $gpu.Utilization){0}else{[double]$gpu.Utilization}; $loadBar.Background=New-Brush '#343B36'; $loadBar.Foreground=New-Brush '#A7D948'
        $vramPercent = if ($gpu.MemoryTotalMiB -and [double]$gpu.MemoryTotalMiB -gt 0) { [double]$gpu.MemoryUsedMiB * 100 / [double]$gpu.MemoryTotalMiB } else { 0 }
        $vramText = New-Text ("显存  {0} / {1}" -f (Format-Memory $gpu.MemoryUsedMiB), (Format-Memory $gpu.MemoryTotalMiB)) 9 '#B5BDB8'; $vramText.Margin = [Windows.Thickness]::new(0,7,0,3)
        $vramBar = [Windows.Controls.ProgressBar]::new(); $vramBar.Minimum=0; $vramBar.Maximum=100; $vramBar.Height=3; $vramBar.Value=$vramPercent; $vramBar.Background=New-Brush '#343B36'; $vramBar.Foreground=New-Brush '#79C8D8'
        [void]$gpuPanel.Children.Add($gpuHeader); [void]$gpuPanel.Children.Add($loadValue); [void]$gpuPanel.Children.Add($loadBar); [void]$gpuPanel.Children.Add($vramText); [void]$gpuPanel.Children.Add($vramBar)
        $chip.Child = $gpuPanel
        [void]$card.GpuWrap.Children.Add($chip)
    }
}

function Save-Settings {
    if (-not (Test-Path -LiteralPath $settingsDirectory)) { [void](New-Item -ItemType Directory -Path $settingsDirectory) }
    $left = if ($script:hiddenAtEdge) { $script:shownLeft } else { $window.Left }
    $top = if ($script:hiddenAtEdge) { $script:shownTop } else { $window.Top }
    [PSCustomObject]@{
        Version=2; Opacity=[Math]::Round($script:backgroundOpacity,2); AutoHide=($ui.EdgeButton.Tag -eq 'active'); Topmost=$window.Topmost
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
    if (-not $script:collectionProcess) {
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
    if (-not $script:dockSide -or $script:hiddenAtEdge -or $ui.EdgeButton.Tag -ne 'active') { return }
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
    if ($script:internalMove -or $script:hiddenAtEdge) { return }
    $work = Get-WorkArea
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

function Save-NativeScreenshot {
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
    $stream = [IO.File]::Create((Join-Path $directory 'native-window.png'))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Complete-SmokeTest {
    if (-not $SmokeTest -or $script:smokeFinished) { return }
    $script:smokeFinished = $true
    try {
        $window.UpdateLayout()
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
        $historySmoke = Show-ServerPulseHistoryWindow -Owner $window -Recorder $script:historyRecorder -ScreenshotPath (Join-Path $scriptRoot 'tests\artifacts\history-window.png') -SmokeTest
        if (-not $historySmoke.QueryClickPassed) { throw "历史查询按钮事件失败：$($historySmoke.QueryClickError)" }
        if (-not $historySmoke.QueryFailureContained) { throw '历史查询异常未被窗口内提示安全拦截' }
        if (-not $historySmoke.ChangedRangeQueryPassed) { throw "修改时间后的历史查询失败：$($historySmoke.ChangedRangeQueryError)" }
        if (-not $historySmoke.NormalRenderPassed) { throw '历史图表正常渲染失败' }
        if (-not $historySmoke.HoverInteractionPassed) { throw "历史图表悬停交互失败：$($historySmoke.HoverInteractionError)" }
        if (-not $historySmoke.CloseHitTestPassed) { throw "历史窗口关闭按钮被其他元素遮挡：$($historySmoke.CloseHitElement)" }
        if (-not $historySmoke.CloseSeparatedFromDragArea) { throw '历史窗口关闭按钮位于拖拽事件区域内' }
        if (-not $historySmoke.CloseButtonPassed) { throw "历史窗口关闭按钮失败：$($historySmoke.CloseButtonError)" }
        if ($historySmoke.PanelCount -lt 1 -or -not (ConvertFrom-HistoryMinuteText $historySmoke.Start) -or -not (ConvertFrom-HistoryMinuteText $historySmoke.End) -or -not $historySmoke.ValidationPassed) { throw '历史窗口、默认时间范围与红框校验失败' }
        $script:dispatcherProbeHandled = $false
        [void]$window.Dispatcher.BeginInvoke([Action]{ throw 'ServerPulse dispatcher containment probe' },[Windows.Threading.DispatcherPriority]::Background)
        $probeFrame=[Windows.Threading.DispatcherFrame]::new()
        [void]$window.Dispatcher.BeginInvoke([Action]{ $probeFrame.Continue=$false }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        [Windows.Threading.Dispatcher]::PushFrame($probeFrame)
        if (-not $script:dispatcherProbeHandled) { throw '未处理的 UI 事件异常未被安全拦截' }
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
        $script:isDragging = $false; Schedule-EdgeHide
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
        $script:isDragging = $false; Schedule-EdgeHide
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

function Start-Collection {
    if ($script:collectionProcess -and -not $script:collectionProcess.HasExited) { return }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'powershell.exe'
    $info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$collectorPath`" -ConfigPath `"$configPath`""
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8; $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $script:collectionProcess = [Diagnostics.Process]::Start($info)
    $script:stdoutTask = $script:collectionProcess.StandardOutput.ReadToEndAsync()
    $script:stderrTask = $script:collectionProcess.StandardError.ReadToEndAsync()
}

$pollTimer = [Windows.Threading.DispatcherTimer]::new(); $pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$pollTimer.Add_Tick({
    if ($script:collectionProcess -and $script:collectionProcess.HasExited) {
        $stdout = $script:stdoutTask.Result.Trim(); $stderr = $script:stderrTask.Result.Trim()
        $script:collectionProcess = $null
        if ($stdout) {
            try {
                $snapshot = $stdout | ConvertFrom-Json
                try { Add-ServerPulseHistorySnapshot -Recorder $script:historyRecorder -Snapshot $snapshot } catch { $ui.HistoryButton.ToolTip = "历史记录失败：$($_.Exception.Message)" }
                $servers = @($snapshot.Servers)
                foreach ($server in $servers) { Update-ServerCard $server }
                $online = @($servers | Where-Object { $_.Status -eq 'online' }).Count
                $gpuCount = ($servers | Where-Object { $_.Status -eq 'online' } | ForEach-Object { @($_.Metrics.Gpus).Count } | Measure-Object -Sum).Sum
                if ($null -eq $gpuCount) { $gpuCount = 0 }
                $ui.SummaryText.Text = "$online / $($servers.Count) 在线   ·   $gpuCount GPU"
                $ui.UpdatedText.Text = [DateTime]::Now.ToString('HH:mm:ss')
                $ui.FleetState.Text = if ($online -eq $servers.Count) { '  全部在线' } else { "  $online / $($servers.Count) 在线" }
                $ui.FleetDot.Fill = New-Brush $(if ($online -eq $servers.Count) { '#A7D948' } elseif ($online -gt 0) { '#E4B64B' } else { '#FF6B6B' })
                if ($SmokeTest -and -not $script:smokeFinished) {
                    [void]$window.Dispatcher.BeginInvoke(
                        [Action]{ Complete-SmokeTest },
                        [Windows.Threading.DispatcherPriority]::Background
                    )
                }
            } catch { $ui.SummaryText.Text = "采集结果错误：$($_.Exception.Message)" }
        } elseif ($stderr) { $ui.SummaryText.Text = "采集器错误：$stderr" }
        $script:nextCollection = [DateTime]::UtcNow.AddSeconds($script:refreshIntervalSeconds)
    }
    if (-not $script:collectionProcess -and [DateTime]::UtcNow -ge $script:nextCollection) { Start-Collection }
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
$window.Add_MouseLeave({ if ($script:dockSide -and -not $script:hiddenAtEdge -and $ui.EdgeButton.Tag -eq 'active') { $hideTimer.Start() } })
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
    catch { $ui.SummaryText.Text = "历史记录错误：$($_.Exception.Message)" }
})
$ui.EdgeButton.Add_Click({
    if ($ui.EdgeButton.Tag -eq 'active') { $ui.EdgeButton.Tag = $null; $hideTimer.Stop(); Show-FromEdge }
    else { $ui.EdgeButton.Tag = 'active'; Schedule-EdgeHide }
})
$ui.PinButton.Add_Click({ $window.Topmost = -not $window.Topmost; $ui.PinButton.Tag = if ($window.Topmost) { 'active' } else { $null } })
$ui.MinimizeButton.Add_Click({ $window.WindowState = 'Minimized' })
$ui.CloseButton.Add_Click({ $window.Close() })

$window.Add_Loaded({
    if ($null -ne $settings.Left -and $null -ne $settings.Top) {
        $window.Left = [double]$settings.Left; $window.Top = [double]$settings.Top
    }
    $cursorTimer.Start(); $pollTimer.Start(); Start-Collection
})
$window.Add_Closing({
    $pollTimer.Stop(); $cursorTimer.Stop(); $hideTimer.Stop(); $dockDetectTimer.Stop()
    if ($script:collectionProcess -and -not $script:collectionProcess.HasExited) { $script:collectionProcess.Kill() }
    if (-not $SmokeTest) { try { [void](Flush-ServerPulseHistoryRecorder $script:historyRecorder) } catch { } }
    if (-not $SmokeTest) { Save-Settings }
})

[void]$window.ShowDialog()
if ($SmokeTest) {
    if ($script:smokeError) { throw $script:smokeError }
    if (-not $script:smokePassed) { throw '原生窗口冒烟测试未完成' }
    Write-Output 'PASS: native window, resize, opacity, edge hide, SSH snapshot'
}
