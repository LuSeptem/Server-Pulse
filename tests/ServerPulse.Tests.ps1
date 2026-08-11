$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Core.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.History.ps1')

$passed = 0
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message：期望 '$Expected'，实际 '$Actual'"
    }
    $script:passed++
}

$fields = @(Split-MetricCsvLine '0, "GPU, Pro", "a""b"')
Assert-Equal $fields.Count 3 'CSV 字段数量'
Assert-Equal $fields[1] 'GPU, Pro' 'CSV 逗号字段'
Assert-Equal $fields[2] 'a"b' 'CSV 双引号字段'

$sample = @'
HOSTNAME=compute-01
CPU_PERCENT=37.5
MEM_TOTAL_KIB=67108864
MEM_USED_KIB=16777216
MEM_PERCENT=25.0
LOAD_1=1.20
LOAD_5=1.10
LOAD_15=0.90
UPTIME_SECONDS=172861
GPUS_BEGIN
0, NVIDIA GeForce RTX 3090, GPU-aaa, 72, 12000, 24576, 68, 280.5, 350.0, 77
1, NVIDIA RTX A6000, GPU-bbb, 0, 100, 49140, 31, [N/A], 300.0, 30
GPUS_END
'@

$metrics = ConvertFrom-ServerMetricsOutput -Output $sample
Assert-Equal $metrics.Hostname 'compute-01' '主机名'
Assert-Equal $metrics.Cpu.Utilization 37.5 'CPU 利用率'
Assert-Equal $metrics.Memory.UsedMiB 16384 '已用内存'
Assert-Equal (Format-MemoryUsage $metrics.Memory.Percent $metrics.Memory.UsedMiB $metrics.Memory.TotalMiB) '25% · 16.0/64.0 GB' '系统内存显示百分比和具体用量'
Assert-Equal @($metrics.Gpus).Count 2 'GPU 数量'
Assert-Equal $metrics.Gpus[0].MemoryUsedMiB 12000 'GPU 已用显存'
Assert-Equal $metrics.Gpus[0].MemoryTotalMiB 24576 'GPU 总显存'
Assert-Equal $metrics.Gpus[1].PowerDrawW $null '无效数值转换'

Assert-Equal (ConvertTo-RefreshIntervalSeconds '1') 1 '最小刷新间隔'
Assert-Equal (ConvertTo-RefreshIntervalSeconds '300') 300 '最大刷新间隔'
Assert-Equal (ConvertTo-RefreshIntervalSeconds '0') $null '拒绝过小刷新间隔'
Assert-Equal (ConvertTo-RefreshIntervalSeconds '301') $null '拒绝过大刷新间隔'
Assert-Equal (ConvertTo-RefreshIntervalSeconds 'fast') $null '拒绝非数字刷新间隔'
Assert-Equal (ConvertFrom-HistoryMinuteText '2026-08-11 09:07').ToString('yyyyMMddHHmm') '202608110907' '分钟精度时间解析'
Assert-Equal (ConvertFrom-HistoryMinuteText '2026/08/11 09:07') $null '拒绝非标准历史时间'
$validDateParts = ConvertFrom-HistoryDateParts -Year 2024 -Month 2 -Day 29 -Hour 23 -Minute 59
Assert-Equal $validDateParts.Value.ToString('yyyyMMddHHmm') '202402292359' '闰年分框时间校验'
Assert-Equal ((ConvertFrom-HistoryDateParts -Year 1999 -Month 2 -Day 1 -Hour 0 -Minute 0).InvalidFields -contains 'Year') $true '年份越界校验'
Assert-Equal ((ConvertFrom-HistoryDateParts -Year 2026 -Month 13 -Day 1 -Hour 0 -Minute 0).InvalidFields -contains 'Month') $true '月份越界校验'
Assert-Equal ((ConvertFrom-HistoryDateParts -Year 2026 -Month 2 -Day 29 -Hour 0 -Minute 0).InvalidFields -contains 'Day') $true '实际月份天数校验'
Assert-Equal ((ConvertFrom-HistoryDateParts -Year 2026 -Month 1 -Day 1 -Hour 24 -Minute 0).InvalidFields -contains 'Hour') $true '小时越界校验'
Assert-Equal ((ConvertFrom-HistoryDateParts -Year 2026 -Month 1 -Day 1 -Hour 0 -Minute 60).InvalidFields -contains 'Minute') $true '分钟越界校验'

$hoverSeries = @(
    [PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Points=@([PSCustomObject]@{Time=[datetime]'2026-08-11 09:15';Value=20},[PSCustomObject]@{Time=[datetime]'2026-08-11 09:45';Value=55})},
    [PSCustomObject]@{Name='VRAM';Suffix='%';Color='#79C8D8';Points=@([PSCustomObject]@{Time=[datetime]'2026-08-11 09:45';Value=80},[PSCustomObject]@{Time=[datetime]'2026-08-11 09:50';Value=$null})},
    [PSCustomObject]@{Name='TEMP';Suffix='°C';Color='#E4B64B';Points=@([PSCustomObject]@{Time=[datetime]'2026-08-11 09:45';Value=64})}
)
$hoverSample = Get-HistoryChartHoverSample -Series $hoverSeries -Start ([datetime]'2026-08-11 09:00') -End ([datetime]'2026-08-11 10:00') -CursorX 180
Assert-Equal $hoverSample.Time.ToString('yyyy-MM-dd HH:mm') '2026-08-11 09:45' '折线图按横轴选择具体分钟'
Assert-Equal @($hoverSample.Values).Count 3 '折线图同时返回同一横轴全部指标'
Assert-Equal $hoverSample.Values[0].Name 'GPU' '折线图保持指标顺序'
Assert-Equal $hoverSample.Values[1].Value 80 '折线图返回同分钟显存值'
Assert-Equal $hoverSample.Values[2].Suffix '°C' '折线图返回同分钟温度单位'

$threw = $false
try { ConvertFrom-ServerMetricsOutput -Output 'HOSTNAME=node-only' | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true '不完整输出校验'

$config = Get-ServerPulseConfig -Path (Join-Path $PSScriptRoot '..\config\servers.json')
Assert-Equal @($config.Servers).Count 2 '服务器配置数量'
Assert-Equal $config.Servers[0].host '3090' '第一台 SSH 别名'
Assert-Equal $config.Servers[1].host 'a6000' '第二台 SSH 别名'
Assert-Equal $config.HistoryRetentionDays 30 '历史记录保留天数'

$historySnapshot = [PSCustomObject]@{
    Servers = @(
        [PSCustomObject]@{
            Id='3090'; Label='RTX 3090'; Host='3090'; Status='online'; LatencyMs=20
            Metrics=[PSCustomObject]@{
                Hostname='gpu-node'; Cpu=[PSCustomObject]@{Utilization=40}; Memory=[PSCustomObject]@{UsedMiB=100;TotalMiB=200;Percent=50}
                Load=[PSCustomObject]@{One=1;Five=2;Fifteen=3}; UptimeSeconds=1000
                Gpus=@([PSCustomObject]@{Index=0;Name='GPU';Uuid='id';Utilization=80;MemoryUsedMiB=120;MemoryTotalMiB=240;TemperatureC=60;PowerDrawW=200;PowerLimitW=300;FanPercent=70})
            }
        }
    )
}
$historySnapshot2 = $historySnapshot | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$historySnapshot2.Servers[0].Metrics.Cpu.Utilization = 60
$historySnapshot2.Servers[0].Metrics.Gpus[0].Utilization = 100
$record = ConvertTo-HistoryMinuteRecord -Snapshots @($historySnapshot,$historySnapshot2) -Minute ([datetime]'2026-08-11 09:07')
Assert-Equal $record.Timestamp '2026-08-11T09:07:00' '历史记录分钟键'
Assert-Equal $record.SampleCount 2 '历史记录样本数'
Assert-Equal $record.Servers[0].CpuPercent 50 'CPU 分钟平均值'
Assert-Equal $record.Servers[0].Gpus[0].Utilization 90 'GPU 分钟平均值'
Assert-Equal $record.Servers[0].Gpus[0].MemoryUsedMiB 120 'GPU 显存历史记录'

$historyTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ("serverpulse-history-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $recorder = New-ServerPulseHistoryRecorder -Directory $historyTestDirectory -RetentionDays 30
    Add-ServerPulseHistorySnapshot -Recorder $recorder -Snapshot $historySnapshot -Timestamp ([datetime]'2026-08-11 09:07:05')
    Add-ServerPulseHistorySnapshot -Recorder $recorder -Snapshot $historySnapshot2 -Timestamp ([datetime]'2026-08-11 09:07:45')
    [void](Flush-ServerPulseHistoryRecorder $recorder)
    $storedRecords = @(Get-ServerPulseHistoryRecords -Recorder $recorder -Start ([datetime]'2026-08-11 09:07') -End ([datetime]'2026-08-11 09:07'))
    Assert-Equal $storedRecords.Count 1 '按分钟持久化历史记录'
    Assert-Equal $storedRecords[0].Servers[0].CpuPercent 50 '读取持久化 CPU 平均值'
} finally {
    $historyTestFile = Join-Path $historyTestDirectory '2026-08-11.json'
    if (Test-Path -LiteralPath $historyTestFile) { Remove-Item -LiteralPath $historyTestFile -Force }
    if (Test-Path -LiteralPath $historyTestDirectory) { Remove-Item -LiteralPath $historyTestDirectory -Force }
}

$mainScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ServerPulse.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($mainScript -match '\.DragMove\(')) $false '禁止调用会触发 Windows Snap Assist 的 DragMove'
Assert-Equal ([bool]($mainScript -match 'Update-ManualDragPosition')) $true '使用应用内坐标拖拽'
$historyScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.History.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($historyScript -match 'HistoryCloseButton\.Add_Click\(\{\s*\$historyWindow\.Close')) $false '历史关闭回调不得依赖动态窗口变量'
Assert-Equal ([bool]($historyScript -match '\[Windows\.Window\]::GetWindow\(\$sender\)')) $true '历史关闭回调从按钮解析所属窗口'
Assert-Equal ([bool]($historyScript -match 'HistoryDragArea\.Add_Mouse[^\r\n]+\$drag')) $false '历史拖拽回调不得依赖动态拖拽变量'
Assert-Equal ([bool]($historyScript -match 'Register-HistoryWindowDragArea')) $true '历史拖拽事件使用独立注册函数'
Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
$closeTestWindow=[Windows.Window]::new(); $closeTestButton=[Windows.Controls.Button]::new(); $closeTestWindow.Content=$closeTestButton
Register-HistoryWindowCloseButton -Button $closeTestButton
$closeTestWindow.Show(); $closeTestButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Assert-Equal $closeTestWindow.IsVisible $false '关闭事件注册作用域结束后仍可关闭所属窗口'
$dragTestWindow=[Windows.Window]::new(); $dragTestArea=[Windows.Controls.Grid]::new(); $dragTestWindow.Content=$dragTestArea
$dragTestState=Register-HistoryWindowDragArea -DragArea $dragTestArea
$dragTestWindow.Show()
$dragDown=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $dragDown.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent
$dragTestArea.RaiseEvent($dragDown)
Assert-Equal $dragTestState.Active $true '拖拽事件注册作用域结束后仍可开始拖动'
$dragTestWindow.Left=100; $dragTestWindow.Top=100; $dragTestState.Left=100; $dragTestState.Top=100
$dragCursor=[Windows.Forms.Cursor]::Position; $dragTestState.Cursor=[PSCustomObject]@{X=$dragCursor.X-24;Y=$dragCursor.Y-16}; $dragTestState.ScaleX=1.0; $dragTestState.ScaleY=1.0
$dragMove=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $dragMove.RoutedEvent=[Windows.UIElement]::MouseMoveEvent
$dragTestArea.RaiseEvent($dragMove)
Assert-Equal ([Math]::Round($dragTestWindow.Left)) 124 '历史窗口拖动更新横向坐标'
Assert-Equal ([Math]::Round($dragTestWindow.Top)) 116 '历史窗口拖动更新纵向坐标'
$dragUp=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $dragUp.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent
$dragTestArea.RaiseEvent($dragUp)
Assert-Equal $dragTestState.Active $false '释放鼠标后结束历史窗口拖动'
$dragTestWindow.Close()

$wpfHoverTime=[datetime]'2026-08-11 09:45'
$wpfHoverSeries=@(
    [PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Latest=55;Points=@([PSCustomObject]@{Time=$wpfHoverTime;Value=55})},
    [PSCustomObject]@{Name='VRAM';Suffix='%';Color='#79C8D8';Latest=80;Points=@([PSCustomObject]@{Time=$wpfHoverTime;Value=80})},
    [PSCustomObject]@{Name='TEMP';Suffix='°C';Color='#E4B64B';Latest=64;Points=@([PSCustomObject]@{Time=$wpfHoverTime;Value=64})}
)
$wpfHoverWindow=[Windows.Window]::new(); $wpfHoverCard=New-HistoryChartCard -Title 'GPU 0' -Subtitle '' -Series $wpfHoverSeries -Start $wpfHoverTime.AddMinutes(-30) -End $wpfHoverTime.AddMinutes(30); $wpfHoverWindow.Content=$wpfHoverCard
$wpfHoverWindow.Show(); $wpfHoverWindow.UpdateLayout()
$wpfHoverMove=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $wpfHoverMove.RoutedEvent=[Windows.UIElement]::MouseMoveEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverMove)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count 3 'WPF 悬停同时标记同分钟三条曲线'
Assert-Equal $wpfHoverCard.Tag.TimeBlock.Text '2026-08-11 09:45' 'WPF 悬停显示完整具体时间'
Assert-Equal ([bool]($wpfHoverCard.Tag.ValueBlock.Text -match '^GPU 55%.*VRAM 80%.*TEMP 64°C$')) $true 'WPF 悬停同时显示同分钟全部结果'
$wpfHoverLeave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $wpfHoverLeave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverLeave)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -ne 'Collapsed' }).Count 0 '鼠标移出后隐藏全部悬停标记'
$wpfHoverWindow.Close()

Write-Output "PASS: $passed assertions"
