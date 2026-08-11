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

Write-Output "PASS: $passed assertions"
