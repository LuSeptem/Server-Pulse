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
            <TextBlock x:Name="SummaryText" Text="等待首次采集" Foreground="#939D97" FontSize="10" VerticalAlignment="Center"/>
            <TextBlock x:Name="UpdatedText" Text="--:--:--" Foreground="#5F6963" FontSize="9" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="12">
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
$names = 'DragArea','FleetDot','FleetState','OpacitySlider','EdgeButton','PinButton','MinimizeButton','CloseButton','SummaryText','UpdatedText','ServerPanel'
$ui = @{}
foreach ($name in $names) { $ui[$name] = $window.FindName($name) }

$settingsDirectory = Join-Path $env:LOCALAPPDATA 'ServerPulse'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$settings = [PSCustomObject]@{ Opacity = 0.94; AutoHide = $true; Topmost = $true; Width = 420.0; Height = 560.0; Left = $null; Top = $null }
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $settings.PSObject.Properties.Name) {
            if ($saved.PSObject.Properties.Name -contains $property) { $settings.$property = $saved.$property }
        }
    } catch { }
}

$window.Width = [Math]::Max($window.MinWidth, [double]$settings.Width)
$window.Height = [Math]::Max($window.MinHeight, [double]$settings.Height)
$window.Opacity = [Math]::Max(0.4, [Math]::Min(1.0, [double]$settings.Opacity))
$window.Topmost = [bool]$settings.Topmost
$ui.OpacitySlider.Value = $window.Opacity * 100
$ui.EdgeButton.Tag = if ([bool]$settings.AutoHide) { 'active' } else { $null }
$ui.PinButton.Tag = if ($window.Topmost) { 'active' } else { $null }

. (Join-Path $scriptRoot 'src\ServerPulse.Core.ps1')
$config = Get-ServerPulseConfig -Path $configPath
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
$script:smokeFinished = $false
$script:smokePassed = $false
$script:smokeError = $null

function New-Brush([string]$Color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
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
    $panel.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $labelBlock = New-Text $Label 8 '#6C7770'
    $labelBlock.Margin = [Windows.Thickness]::new(0, 0, 0, 3)
    $valueBlock = New-Text '—' 21 '#EDF1EE'
    $valueBlock.FontWeight = 'SemiBold'
    $bar = [Windows.Controls.ProgressBar]::new()
    $bar.Height = 3
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Margin = [Windows.Thickness]::new(0, 7, 0, 0)
    $bar.Background = New-Brush '#2B312D'
    $bar.Foreground = New-Brush '#A7D948'
    [void]$panel.Children.Add($labelBlock)
    [void]$panel.Children.Add($valueBlock)
    [void]$panel.Children.Add($bar)
    return @{ Panel = $panel; Value = $valueBlock; Bar = $bar }
}

function Add-ServerCard($server) {
    $surface = [Windows.Controls.Border]::new()
    $surface.Background = New-Brush '#171A18'
    $surface.BorderBrush = New-Brush '#2B302D'
    $surface.BorderThickness = [Windows.Thickness]::new(1)
    $surface.CornerRadius = [Windows.CornerRadius]::new(8)
    $surface.Padding = [Windows.Thickness]::new(14)
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
    $meta.Margin = [Windows.Thickness]::new(0, 5, 0, 12)
    [Windows.Controls.Grid]::SetRow($meta, 1); [void]$layout.Children.Add($meta)

    $metricsGrid = [Windows.Controls.Primitives.UniformGrid]::new(); $metricsGrid.Columns = 3
    $cpu = New-MetricCell 'CPU'; $memory = New-MetricCell 'MEM'; $gpu = New-MetricCell 'GPU AVG'
    [void]$metricsGrid.Children.Add($cpu.Panel); [void]$metricsGrid.Children.Add($memory.Panel); [void]$metricsGrid.Children.Add($gpu.Panel)
    [Windows.Controls.Grid]::SetRow($metricsGrid, 2); [void]$layout.Children.Add($metricsGrid)

    $details = [Windows.Controls.StackPanel]::new(); $details.Margin = [Windows.Thickness]::new(0, 11, 0, 0)
    $gpuSummary = New-Text '等待 GPU 数据' 8 '#717B75'
    $gpuWrap = [Windows.Controls.WrapPanel]::new(); $gpuWrap.Margin = [Windows.Thickness]::new(0, 7, 0, 0)
    $error = New-Text '' 8 '#FF7B72'; $error.TextWrapping = 'Wrap'; $error.Margin = [Windows.Thickness]::new(0, 7, 0, 0); $error.Visibility = 'Collapsed'
    [void]$details.Children.Add($gpuSummary); [void]$details.Children.Add($gpuWrap); [void]$details.Children.Add($error)
    [Windows.Controls.Grid]::SetRow($details, 3); [void]$layout.Children.Add($details)

    $surface.Child = $layout
    [void]$ui.ServerPanel.Children.Add($surface)
    $script:cards[[string]$server.id] = @{
        Surface=$surface; State=$state; Meta=$meta; Cpu=$cpu; Memory=$memory; Gpu=$gpu;
        GpuSummary=$gpuSummary; GpuWrap=$gpuWrap; Error=$error
    }
}

foreach ($server in $config.Servers) { Add-ServerCard $server }

function Format-Percent($Value) {
    if ($null -eq $Value) { return '—' }
    return ('{0:0}%' -f [double]$Value)
}

function Format-Memory($MiB) {
    if ($null -eq $MiB) { return '—' }
    if ([double]$MiB -ge 1024) { return ('{0:0.0} GB' -f ([double]$MiB / 1024)) }
    return ('{0:0} MB' -f [double]$MiB)
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
        Set-Metric $card.Cpu $null; Set-Metric $card.Memory $null; Set-Metric $card.Gpu $null
        $card.GpuSummary.Text = '暂无指标'
        $card.GpuWrap.Children.Clear()
        return
    }

    $metrics = $server.Metrics
    $card.Meta.Text = "{0}   ·   {1} ms   ·   LOAD {2:0.00}" -f $metrics.Hostname, $server.LatencyMs, [double]$metrics.Load.One
    Set-Metric $card.Cpu $metrics.Cpu.Utilization
    Set-Metric $card.Memory $metrics.Memory.Percent
    $gpus = @($metrics.Gpus)
    $gpuValues = @($gpus | Where-Object { $null -ne $_.Utilization } | ForEach-Object { [double]$_.Utilization })
    $gpuAverage = if ($gpuValues.Count) { ($gpuValues | Measure-Object -Average).Average } else { $null }
    Set-Metric $card.Gpu $gpuAverage
    $used = ($gpus | Where-Object { $null -ne $_.MemoryUsedMiB } | Measure-Object MemoryUsedMiB -Sum).Sum
    $total = ($gpus | Where-Object { $null -ne $_.MemoryTotalMiB } | Measure-Object MemoryTotalMiB -Sum).Sum
    $card.GpuSummary.Text = "{0} GPU   ·   显存 {1} / {2}   ·   内存 {3} / {4}" -f $gpus.Count, (Format-Memory $used), (Format-Memory $total), (Format-Memory $metrics.Memory.UsedMiB), (Format-Memory $metrics.Memory.TotalMiB)
    $card.GpuWrap.Children.Clear()
    foreach ($gpu in $gpus) {
        $chip = [Windows.Controls.Border]::new(); $chip.Background = New-Brush '#222724'; $chip.CornerRadius = [Windows.CornerRadius]::new(4); $chip.Margin = [Windows.Thickness]::new(0,0,5,5); $chip.Padding = [Windows.Thickness]::new(6,3,6,3)
        $chip.Child = New-Text ("{0}  {1}  {2:0}°" -f [int]$gpu.Index, (Format-Percent $gpu.Utilization), [double]$gpu.TemperatureC) 8 '#AAB3AD'
        [void]$card.GpuWrap.Children.Add($chip)
    }
}

function Save-Settings {
    if (-not (Test-Path -LiteralPath $settingsDirectory)) { [void](New-Item -ItemType Directory -Path $settingsDirectory) }
    $left = if ($script:hiddenAtEdge) { $script:shownLeft } else { $window.Left }
    $top = if ($script:hiddenAtEdge) { $script:shownTop } else { $window.Top }
    [PSCustomObject]@{
        Opacity=[Math]::Round($window.Opacity,2); AutoHide=($ui.EdgeButton.Tag -eq 'active'); Topmost=$window.Topmost
        Width=$window.Width; Height=$window.Height; Left=$left; Top=$top
    } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
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

function Hide-ToEdge {
    if (-not $script:dockSide -or $script:hiddenAtEdge -or $ui.EdgeButton.Tag -ne 'active') { return }
    $work = Get-WorkArea
    $script:shownLeft = $window.Left; $script:shownTop = $window.Top
    $script:internalMove = $true
    if ($script:dockSide -eq 'left') { $window.Left = $work.Left - $window.ActualWidth + 7 }
    elseif ($script:dockSide -eq 'right') { $window.Left = $work.Left + $work.Width - 7 }
    elseif ($script:dockSide -eq 'top') { $window.Top = $work.Top - $window.ActualHeight + 7 }
    $script:hiddenAtEdge = $true
    $script:internalMove = $false
}

function Show-FromEdge {
    if (-not $script:hiddenAtEdge) { return }
    $script:internalMove = $true
    $window.Left = $script:shownLeft; $window.Top = $script:shownTop
    $script:hiddenAtEdge = $false
    $script:internalMove = $false
}

$hideTimer = [Windows.Threading.DispatcherTimer]::new(); $hideTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$hideTimer.Add_Tick({ $hideTimer.Stop(); Hide-ToEdge })
function Schedule-EdgeHide {
    if ($script:internalMove -or $script:hiddenAtEdge) { return }
    $work = Get-WorkArea
    $script:dockSide = $null
    if ([Math]::Abs($window.Left - $work.Left) -le 16) { $script:dockSide = 'left'; $window.Left = $work.Left }
    elseif ([Math]::Abs(($window.Left + $window.ActualWidth) - ($work.Left + $work.Width)) -le 16) { $script:dockSide = 'right'; $window.Left = $work.Left + $work.Width - $window.ActualWidth }
    elseif ([Math]::Abs($window.Top - $work.Top) -le 16) { $script:dockSide = 'top'; $window.Top = $work.Top }
    $hideTimer.Stop()
    if ($script:dockSide -and $ui.EdgeButton.Tag -eq 'active') { $hideTimer.Start() }
}

$cursorTimer = [Windows.Threading.DispatcherTimer]::new(); $cursorTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$cursorTimer.Add_Tick({
    if (-not $script:hiddenAtEdge) { return }
    $work = Get-WorkArea; $cursor = [Windows.Forms.Cursor]::Position
    $x = $cursor.X / $work.ScaleX; $y = $cursor.Y / $work.ScaleY
    $touches = if ($script:dockSide -eq 'left') { $x -le $work.Left + 8 -and $y -ge $script:shownTop -and $y -le $script:shownTop + $window.ActualHeight }
        elseif ($script:dockSide -eq 'right') { $x -ge $work.Left + $work.Width - 8 -and $y -ge $script:shownTop -and $y -le $script:shownTop + $window.ActualHeight }
        else { $y -le $work.Top + 8 -and $x -ge $script:shownLeft -and $x -le $script:shownLeft + $window.ActualWidth }
    if ($touches) { Show-FromEdge }
})

function Save-NativeScreenshot {
    $directory = Join-Path $scriptRoot 'tests\artifacts'
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
    $width = [Math]::Max(1, [int]($window.ActualWidth * $dpi.DpiScaleX))
    $height = [Math]::Max(1, [int]($window.ActualHeight * $dpi.DpiScaleY))
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, $dpi.PixelsPerInchX, $dpi.PixelsPerInchY, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
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
        $originalOpacity = $window.Opacity; $window.Opacity = 0.8
        if ([Math]::Abs($window.Opacity - 0.8) -gt 0.01) { throw '透明度验证失败' }
        $originalWidth = $window.Width; $window.Width = $originalWidth + 20
        if ($window.Width -le $originalWidth) { throw '尺寸调节验证失败' }
        $window.Width = $originalWidth; $window.Opacity = $originalOpacity
        $work = Get-WorkArea; $window.Left = $work.Left; $script:dockSide = 'left'; Hide-ToEdge
        if (-not $script:hiddenAtEdge) { throw '贴边隐藏验证失败' }
        Show-FromEdge
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
        $script:nextCollection = [DateTime]::UtcNow.AddMilliseconds($config.PollIntervalMs)
    }
    if (-not $script:collectionProcess -and [DateTime]::UtcNow -ge $script:nextCollection) { Start-Collection }
})

$ui.DragArea.Add_MouseLeftButtonDown({
    param($sender, $event)
    if ($event.ChangedButton -eq 'Left') { $window.DragMove(); Schedule-EdgeHide }
})
$window.Add_LocationChanged({ if (-not $script:internalMove) { $hideTimer.Stop() } })
$window.Add_MouseLeave({ if ($script:dockSide -and -not $script:hiddenAtEdge -and $ui.EdgeButton.Tag -eq 'active') { $hideTimer.Start() } })
$ui.OpacitySlider.Add_ValueChanged({ $window.Opacity = [Math]::Max(0.4, $ui.OpacitySlider.Value / 100) })
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
    $pollTimer.Stop(); $cursorTimer.Stop(); $hideTimer.Stop()
    if ($script:collectionProcess -and -not $script:collectionProcess.HasExited) { $script:collectionProcess.Kill() }
    if (-not $SmokeTest) { Save-Settings }
})

[void]$window.ShowDialog()
if ($SmokeTest) {
    if ($script:smokeError) { throw $script:smokeError }
    if (-not $script:smokePassed) { throw '原生窗口冒烟测试未完成' }
    Write-Output 'PASS: native window, resize, opacity, edge hide, SSH snapshot'
}
