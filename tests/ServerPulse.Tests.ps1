$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Theme.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Localization.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Storage.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Core.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.History.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Ssh.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Persistent.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Sample.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Agent.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.ServerManager.ps1')

$passed = 0
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message：期望 '$Expected'，实际 '$Actual'"
    }
    $script:passed++
}

Assert-Equal (Normalize-ServerPulseThemeMode 'LIGHT') 'light' '主题模式不区分大小写'
Assert-Equal (Normalize-ServerPulseThemeMode 'sepia') 'dark' '无效主题模式安全回退暗色'
Assert-Equal (Resolve-ServerPulseTheme -Mode system -SystemTheme light) 'light' '跟随系统可解析为亮色'
$themeDarkBackground=[Windows.Media.ColorConverter]::ConvertFromString('#0D100E')
$themeLightBackground=ConvertTo-ServerPulseThemeColor $themeDarkBackground light
Assert-Equal ($themeLightBackground.R -gt 220) $true '亮色主题将主背景转换为高亮度表面'
$themeRoundTrip=ConvertTo-ServerPulseThemeColor $themeLightBackground dark
Assert-Equal $themeRoundTrip.ToString() '#FF0D100E' '亮暗主题颜色可无损往返'
$themeRoot=[Windows.Controls.Border]::new();$themeRoot.Background=New-ServerPulseThemeBrush '#0D100E'
$themeText=[Windows.Controls.TextBlock]::new();$themeText.Foreground=New-ServerPulseThemeBrush '#E7EBE8';$themeRoot.Child=$themeText
[void](Set-ServerPulseThemeState light light);Update-ServerPulseThemeVisualTree $themeRoot
Assert-Equal ($themeRoot.Background.Color.R -gt 220) $true '主题切换更新现有 WPF 容器'
Assert-Equal ($themeText.Foreground.Color.R -lt 80) $true '亮色主题保持正文高对比度'
[void](Set-ServerPulseThemeState dark dark);Update-ServerPulseThemeVisualTree $themeRoot
Assert-Equal $themeRoot.Background.Color.ToString() '#FF0D100E' '现有 WPF 容器可切回暗色'

$brushRegistryBefore = $script:serverPulseThemeBrushes.Count
$cachedThemeBrush = New-ServerPulseThemeBrush '#A7D948'
1..1000 | ForEach-Object { $null = New-ServerPulseThemeBrush '#A7D948' }
$lastThemeBrush = New-ServerPulseThemeBrush '#A7D948'
Assert-Equal ([object]::ReferenceEquals($cachedThemeBrush,$lastThemeBrush)) $true '重复刷新复用同一主题画刷'
Assert-Equal ($script:serverPulseThemeBrushes.Count - $brushRegistryBefore) 1 '主题画刷缓存不会随刷新线性增长'

Assert-Equal (Normalize-ServerPulseLanguageMode 'EN') 'en' '语言模式不区分大小写'
Assert-Equal (Normalize-ServerPulseLanguageMode 'invalid') 'zh' '无效语言模式安全回退中文'
Assert-Equal (Resolve-ServerPulseLanguage -Mode system -SystemLanguage en) 'en' '跟随系统语言可解析为英文'
Assert-Equal (Set-ServerPulseLanguageState -Mode zh -ResolvedLanguage zh) 'zh' '语言状态可切换为中文'
Assert-Equal (Get-ServerPulseText 'main.manage') '管理' '默认界面文案为中文'
[void](Set-ServerPulseLanguageState -Mode en -ResolvedLanguage en)
Assert-Equal (Get-ServerPulseText 'main.manage') 'Manage' '英文资源可解析'
[void](Set-ServerPulseLanguageState -Mode zh -ResolvedLanguage zh)
Assert-Equal (Get-ServerPulseText 'history.popupPinHint') '单击曲线固定弹窗' '历史详情固定提示使用中文'
Assert-Equal (Get-ServerPulseText 'history.popupUnpinHint') '双击曲线解除固定' '历史详情解除固定提示使用中文'
Assert-Equal (Get-ServerPulseText 'history.userCurveHint') '单击查看用户曲线' '历史用户曲线提示使用中文'
[void](Set-ServerPulseLanguageState -Mode en -ResolvedLanguage en)
Assert-Equal (Get-ServerPulseText 'history.popupPinHint') 'Click curve to pin popup' '历史详情固定提示提供英文'
Assert-Equal (Get-ServerPulseText 'history.popupUnpinHint') 'Double-click curve to unpin' '历史详情解除固定提示提供英文'
Assert-Equal (Get-ServerPulseText 'history.userCurveHint') 'Click to view user curve' '历史用户曲线提示提供英文'
[void](Set-ServerPulseLanguageState -Mode zh -ResolvedLanguage zh)

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
Assert-Equal $metrics.ProtocolVersion 1 '旧协议输出识别为 v1'
Assert-Equal $metrics.Cpu.UserUsage.Status 'unavailable' 'v1 CPU 用户归属不可用'
Assert-Equal $metrics.Memory.UserUsage.Status 'unavailable' 'v1 内存用户归属不可用'
Assert-Equal $metrics.Gpus[0].UserMemory.Status 'unavailable' 'v1 GPU 用户归属不可用'
Assert-Equal (Format-ServerPulseGpuModel 'NVIDIA GeForce RTX 3090') 'NVIDIA RTX 3090' 'GPU 型号去除冗余 GeForce 前缀'
Assert-Equal (Format-ServerPulseGpuTitle -Index 0 -Name 'NVIDIA GeForce RTX 3090') 'GPU 0 · NVIDIA RTX 3090' 'GPU 标题包含型号'
Assert-Equal (Format-ServerPulseGpuTitle -Index 1 -Name '') 'GPU 1' '缺少 GPU 型号时安全回退标题'

$v2Sample = @"
PROTOCOL_VERSION=2
HOSTNAME=compute-v2
CPU_PERCENT=50
MEM_TOTAL_KIB=1048576
MEM_USED_KIB=524288
MEM_PERCENT=50
LOAD_1=1
LOAD_5=1
LOAD_15=1
UPTIME_SECONDS=100
CPU_USER_STATUS=partial
CPU_USER_SKIPPED=3
CPU_USER=1000`talpha`t30
CPU_USER=4242`tUID 4242`t25
MEMORY_USER_STATUS=partial
MEMORY_USER_SKIPPED=3
MEMORY_USER=1000`talpha`t600
MEMORY_USER=4242`tUID 4242`t100
GPUS_BEGIN
0, Test GPU, GPU-v2, 25, 1000, 2000, 40, 50, 200, 30
1, Empty GPU, GPU-empty, 0, 0, 2000, 30, 10, 200, 20
GPUS_END
GPU_USER_STATUS=partial
GPU_USER=GPU-v2`t1000`talpha`t700
GPU_USER=GPU-v2`t4242`tUID 4242`t50
GPU_UNMAPPED=GPU-v2`t2
"@
$v2Metrics = ConvertFrom-ServerMetricsOutput -Output $v2Sample
Assert-Equal $v2Metrics.ProtocolVersion 2 '识别用户指标协议 v2'
Assert-Equal $v2Metrics.Cpu.Percent 50 '保留 CPU Percent 聚合别名'
Assert-Equal $v2Metrics.Cpu.UserUsage.Status 'partial' 'CPU 用户归属 partial 状态'
Assert-Equal $v2Metrics.Cpu.UserUsage.Users[1].Name 'UID 4242' '未知 UID 使用稳定回退名称'
Assert-Equal $v2Metrics.Cpu.UserUsage.AttributedPercent 55 'CPU 已归属总量'
Assert-Equal $v2Metrics.Cpu.UserUsage.UnattributedPercent 0 'CPU 无未归属残差'
Assert-Equal $v2Metrics.Cpu.UserUsage.OverlapPercent 5 'CPU 超出聚合量记为重叠'
Assert-Equal $v2Metrics.Cpu.UserUsage.SkippedProcesses 3 'CPU 跳过进程数'
Assert-Equal $v2Metrics.Memory.UserUsage.AttributedMiB 700 '内存已归属总量'
Assert-Equal $v2Metrics.Memory.UserUsage.UnattributedMiB 0 '内存无未归属残差'
Assert-Equal $v2Metrics.Memory.UserUsage.OverlapMiB 188 '内存 RSS 超出聚合量记为重叠'
Assert-Equal $v2Metrics.Gpus[0].UserMemory.Users[1].Name 'UID 4242' 'GPU 用户未知 UID 回退名称'
Assert-Equal $v2Metrics.Gpus[0].UserMemory.AttributedMiB 750 'GPU 已归属显存'
Assert-Equal $v2Metrics.Gpus[0].UserMemory.UnattributedMiB 250 'GPU 未归属显存残差'
Assert-Equal $v2Metrics.Gpus[0].UserMemory.UnmappedProcesses 2 'GPU 未映射进程数'
Assert-Equal @($v2Metrics.Gpus[1].UserMemory.Users).Count 0 'GPU 用户列表允许为空'
Assert-Equal $v2Metrics.Gpus[1].UserMemory.Status 'partial' '空 GPU 继承采集 partial 状态'

$v2Unavailable = $v2Sample -replace 'CPU_USER_STATUS=partial','CPU_USER_STATUS=unavailable' -replace 'MEMORY_USER_STATUS=partial','MEMORY_USER_STATUS=unavailable' -replace 'GPU_USER_STATUS=partial','GPU_USER_STATUS=unavailable'
$unavailableMetrics = ConvertFrom-ServerMetricsOutput -Output $v2Unavailable
Assert-Equal $unavailableMetrics.Cpu.UserUsage.Status 'unavailable' '显式 CPU unavailable 状态'
Assert-Equal $unavailableMetrics.Memory.UserUsage.Status 'unavailable' '显式内存 unavailable 状态'
Assert-Equal $unavailableMetrics.Gpus[0].UserMemory.Status 'unavailable' '显式 GPU unavailable 状态'

$cpuResidualSample = $v2Sample -replace 'CPU_USER=4242.+',"CPU_USER=4242`tUID 4242`t5" -replace 'MEMORY_USER=4242.+',"MEMORY_USER=4242`tUID 4242`t50"
$residualMetrics = ConvertFrom-ServerMetricsOutput -Output $cpuResidualSample
Assert-Equal $residualMetrics.Cpu.UserUsage.UnattributedPercent 15 'CPU 聚合与用户和的未归属残差'
Assert-Equal $residualMetrics.Cpu.UserUsage.OverlapPercent 0 'CPU 残差场景无重叠'
Assert-Equal $residualMetrics.Memory.UserUsage.UnattributedMiB 0 '内存仍超出聚合量时未归属为零'
Assert-Equal $residualMetrics.Memory.UserUsage.OverlapMiB 138 '内存 RSS 重叠独立计算'
$memoryResidualSample = $v2Sample -replace 'MEMORY_USER=1000.+',"MEMORY_USER=1000`talpha`t200" -replace 'MEMORY_USER=4242.+',"MEMORY_USER=4242`tUID 4242`t100"
$memoryResidualMetrics = ConvertFrom-ServerMetricsOutput -Output $memoryResidualSample
Assert-Equal $memoryResidualMetrics.Memory.UserUsage.UnattributedMiB 212 '内存用户和低于整机占用时记录未归属残差'
Assert-Equal $memoryResidualMetrics.Memory.UserUsage.OverlapMiB 0 '内存残差场景无 RSS 重叠'
$emptyV2Sample = ($v2Sample -split "`r?`n" | Where-Object { $_ -notmatch '^(CPU_USER|MEMORY_USER|GPU_USER|GPU_UNMAPPED)=' }) -join "`n"
$emptyV2Metrics = ConvertFrom-ServerMetricsOutput -Output $emptyV2Sample
Assert-Equal @($emptyV2Metrics.Cpu.UserUsage.Users).Count 0 'v2 CPU 用户列表允许为空'
Assert-Equal $emptyV2Metrics.Cpu.UserUsage.UnattributedPercent 50 '空 CPU 用户列表将整机占用计为未归属'
Assert-Equal @($emptyV2Metrics.Memory.UserUsage.Users).Count 0 'v2 内存用户列表允许为空'
Assert-Equal $emptyV2Metrics.Memory.UserUsage.UnattributedMiB 512 '空内存用户列表将整机占用计为未归属'

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
                Hostname='gpu-node'
                Cpu=[PSCustomObject]@{Utilization=40;UserUsage=[PSCustomObject]@{Status='ok';Users=@([PSCustomObject]@{Uid='1000';Name='alpha';Percent=20});UnattributedPercent=20;OverlapPercent=0;AttributedPercent=20;SkippedProcesses=0}}
                Memory=[PSCustomObject]@{UsedMiB=100;TotalMiB=200;Percent=50;UserUsage=[PSCustomObject]@{Status='ok';Users=@([PSCustomObject]@{Uid='1000';Name='alpha';UsedMiB=80;Percent=40});UnattributedMiB=20;OverlapMiB=0;AttributedMiB=80;SkippedProcesses=0}}
                Load=[PSCustomObject]@{One=1;Five=2;Fifteen=3}; UptimeSeconds=1000
                Gpus=@([PSCustomObject]@{Index=0;Name='GPU';Uuid='id';Utilization=80;MemoryUsedMiB=120;MemoryTotalMiB=240;TemperatureC=60;PowerDrawW=200;PowerLimitW=300;FanPercent=70;UserMemory=[PSCustomObject]@{Status='ok';Users=@([PSCustomObject]@{Uid='1000';Name='alpha';UsedMiB=100;Percent=41.67});UnattributedMiB=20;AttributedMiB=100;UnmappedProcesses=0}})
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

$availableUserSample = [PSCustomObject]@{Status='ok';Users=@([PSCustomObject]@{Uid='1000';Name='alpha';Value=30;Percent=30});System=5;Overlap=0;Attributed=30;Skipped=0;Weight=1}
$availableMissingUserSample = [PSCustomObject]@{Status='ok';Users=@();System=35;Overlap=0;Attributed=0;Skipped=0;Weight=1}
$unavailableUserSample = [PSCustomObject]@{Status='unavailable';Users=@();System=$null;Overlap=$null;Attributed=$null;Skipped=$null;Weight=0}
$partialUserSample = [PSCustomObject]@{Status='partial';Users=@([PSCustomObject]@{Uid='1000';Name='alpha';Value=10;Percent=10});System=25;Overlap=1;Attributed=10;Skipped=2;Weight=1}
$emptyMerge = Merge-HistoryUserUsageSamples -Samples @() -Kind Cpu
Assert-Equal $emptyMerge.Status 'unavailable' '无在线样本时用户分钟聚合安全返回 unavailable'
$availableMerge = Merge-HistoryUserUsageSamples -Samples @($availableUserSample,$availableMissingUserSample) -Kind Cpu
Assert-Equal $availableMerge.Users[0].Percent 15 '历史可用分钟缺少用户按零计入平均'
Assert-Equal $availableMerge.ValidSamples 2 '历史用户平均记录可用样本数'
$excludedMerge = Merge-HistoryUserUsageSamples -Samples @($availableUserSample,$unavailableUserSample) -Kind Cpu
Assert-Equal $excludedMerge.Users[0].Percent 30 '历史 unavailable 分钟排除在用户平均外'
Assert-Equal $excludedMerge.ValidSamples 1 'unavailable 分钟不增加有效用户样本数'
$partialMerge = Merge-HistoryUserUsageSamples -Samples @($availableUserSample,$partialUserSample) -Kind Cpu
Assert-Equal $partialMerge.Status 'partial' '历史用户样本存在 partial 时保留状态'
Assert-Equal $partialMerge.Users[0].Percent 20 '历史 partial 样本参与可用平均'
$legacyGapPoint = ConvertTo-HistoryUserPoint -Time ([datetime]'2026-08-11 09:08') -Usage $null -Kind Cpu -TotalMiB $null
Assert-Equal $legacyGapPoint.Status 'unavailable' '旧历史记录形成用户曲线缺口'
Assert-Equal @($legacyGapPoint.Users).Count 0 '旧历史缺口不伪造零值用户'

$historyTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ("serverpulse-history-{0}" -f [guid]::NewGuid().ToString('N'))
$historyTestFailure = $null
try {
    $recorder = New-ServerPulseHistoryRecorder -Directory $historyTestDirectory -RetentionDays 30
    Add-ServerPulseHistorySnapshot -Recorder $recorder -Snapshot $historySnapshot -Timestamp ([datetime]'2026-08-11 09:07:05')
    Add-ServerPulseHistorySnapshot -Recorder $recorder -Snapshot $historySnapshot2 -Timestamp ([datetime]'2026-08-11 09:07:45')
    [void](Flush-ServerPulseHistoryRecorder $recorder)
    $storedRecords = @(Get-ServerPulseHistoryRecords -Recorder $recorder -Start ([datetime]'2026-08-11 09:07') -End ([datetime]'2026-08-11 09:07'))
    Assert-Equal $storedRecords.Count 1 '按分钟持久化历史记录'
    Assert-Equal $storedRecords[0].Servers[0].CpuPercent 50 '读取持久化 CPU 平均值'
    $jsonlPath = Join-Path $historyTestDirectory '2026-08-11.v2.jsonl'
    Assert-Equal (Test-Path -LiteralPath $jsonlPath) $true 'v2 历史写入 JSONL 文件'
    $jsonlEntry = (Get-Content -LiteralPath $jsonlPath -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal $jsonlEntry.Version 2 'JSONL 条目标记协议 v2'
    Assert-Equal $jsonlEntry.Record.Timestamp '2026-08-11T09:07:00' 'JSONL 条目包含分钟记录'

    $duplicateRecord = $storedRecords[0] | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $duplicateRecord.SampleCount = 1
    $duplicateRecord.Servers[0].OnlineSamples = 1
    $duplicateRecord.Servers[0].TotalSamples = 1
    $duplicateRecord.Servers[0].CpuPercent = 80
    $duplicateRecord.Servers[0].Gpus[0].ValidSamples = 1
    $duplicateRecord.Servers[0].Gpus[0].Utilization = 30
    Save-HistoryMinuteRecord -Recorder $recorder -Record $duplicateRecord
    Assert-Equal @(Get-Content -LiteralPath $jsonlPath -Encoding UTF8).Count 2 'JSONL 使用追加写入而非覆盖'
    $weightedRecords = @(Get-ServerPulseHistoryRecords -Recorder $recorder -Start ([datetime]'2026-08-11 09:07') -End ([datetime]'2026-08-11 09:07'))
    Assert-Equal $weightedRecords.Count 1 '同一分钟重复 JSONL 合并为单条记录'
    Assert-Equal $weightedRecords[0].SampleCount 3 '重复分钟合并样本数'
    Assert-Equal $weightedRecords[0].Servers[0].CpuPercent 60 '重复分钟按在线样本数加权合并 CPU'
    Assert-Equal $weightedRecords[0].Servers[0].Gpus[0].Utilization 70 '重复分钟按 GPU 有效样本数加权合并'

    Add-Content -LiteralPath $jsonlPath -Value '{"Version":2,"Record":' -Encoding UTF8
    $corruptTailRecords = @(Get-ServerPulseHistoryRecords -Recorder $recorder -Start ([datetime]'2026-08-11 09:07') -End ([datetime]'2026-08-11 09:07'))
    Assert-Equal $corruptTailRecords.Count 1 '损坏 JSONL 末行不影响此前完整记录'
    Assert-Equal ($recorder.ReadErrors.Count -gt 0) $true '损坏 JSONL 末行记录可观测读取错误'

    $legacyRecord = $storedRecords[0] | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $legacyRecord.Timestamp = '2026-08-11T09:08:00'
    $legacyRecord.PSObject.Properties.Remove('CpuUserUsage')
    $legacyRecord.Servers[0].PSObject.Properties.Remove('CpuUserUsage')
    $legacyRecord.Servers[0].PSObject.Properties.Remove('MemoryUserUsage')
    $legacyRecord.Servers[0].Gpus[0].PSObject.Properties.Remove('UserMemory')
    [PSCustomObject]@{Records=@($legacyRecord)} | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $historyTestDirectory '2026-08-11.json') -Encoding UTF8
    $mixedRecords = @(Get-ServerPulseHistoryRecords -Recorder $recorder -Start ([datetime]'2026-08-11 09:07') -End ([datetime]'2026-08-11 09:08'))
    Assert-Equal $mixedRecords.Count 2 '同一天混合查询旧 JSON 与 v2 JSONL'
    Assert-Equal $mixedRecords[1].Timestamp '2026-08-11T09:08:00' '混合格式查询按分钟排序'
    $mixedLegacyCpuUsage = Get-HistoryStoredUsageState (Get-HistoryObjectValue $mixedRecords[1].Servers[0] @('CpuUserUsage')) Cpu
    Assert-Equal $mixedLegacyCpuUsage.Status 'unavailable' '旧格式缺少用户字段读为 unavailable'

    # 窄窗口查询只解析窗口内的 JSONL 分钟，预过滤不引入额外分钟
    for ($h = 0; $h -lt 12; $h++) {
        $windowRecord = $storedRecords[0] | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $windowRecord.Timestamp = '2026-08-12T{0:00}:00:00' -f $h
        Save-HistoryMinuteRecord -Recorder $recorder -Record $windowRecord
    }
    $readErrorsBefore = $recorder.ReadErrors.Count
    $windowedRecords = @(Get-ServerPulseHistoryRecords -Recorder $recorder -Start ([datetime]'2026-08-12 03:00') -End ([datetime]'2026-08-12 04:59'))
    Assert-Equal ($windowedRecords.Timestamp -join ',') '2026-08-12T03:00:00,2026-08-12T04:00:00' '窄窗口查询只返回窗口内分钟且按序'
    Assert-Equal ($recorder.ReadErrors.Count -eq $readErrorsBefore) $true '窄窗口预过滤不产生新的读取错误'

    Set-Content -LiteralPath (Join-Path $historyTestDirectory '2026-06-01.json') -Value '{"Records":[]}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $historyTestDirectory '2026-06-01.v2.jsonl') -Value '' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $historyTestDirectory '2026-08-10.json') -Value '{"Records":[]}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $historyTestDirectory '2026-08-10.v2.jsonl') -Value '' -Encoding UTF8
    Remove-ExpiredServerPulseHistory -Recorder $recorder -Now ([datetime]'2026-08-12')
    Assert-Equal (Test-Path -LiteralPath (Join-Path $historyTestDirectory '2026-06-01.json')) $false '保留策略删除过期旧 JSON'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $historyTestDirectory '2026-06-01.v2.jsonl')) $false '保留策略删除过期 v2 JSONL'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $historyTestDirectory '2026-08-10.json')) $true '保留策略保留有效期旧 JSON'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $historyTestDirectory '2026-08-10.v2.jsonl')) $true '保留策略保留有效期 v2 JSONL'
} catch {
    $historyTestFailure = $_
} finally {
    if (Test-Path -LiteralPath $historyTestDirectory) {
        Get-ChildItem -LiteralPath $historyTestDirectory -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        Remove-Item -LiteralPath $historyTestDirectory -Force
    }
}
if ($null -ne $historyTestFailure) { throw $historyTestFailure }

$identity=ConvertTo-ServerPulseCanonicalIdentity -User 'alice' -HostName 'GPU.EXAMPLE' -Port 2202
Assert-Equal $identity 'alice@gpu.example:2202' 'SSH 登录身份规范化'
Assert-Equal ((Get-ServerPulseCredentialTarget $identity) -match '^ServerPulse:ssh:[0-9a-f]{64}$') $true 'Windows 凭据键不暴露登录身份'
Assert-Equal (Get-ServerPulseSshFailureKind 'Permission denied (publickey,password).') 'authentication' 'SSH 密码错误分类为认证问题'
Assert-Equal (Get-ServerPulseSshFailureKind 'REMOTE HOST IDENTIFICATION HAS CHANGED!') 'host_key_changed' 'SSH 指纹变化严格分类'
Assert-Equal (Get-ServerPulseSshFailureKind 'Host key verification failed.') 'host_key_unknown' '未知 SSH 主机密钥分类'
$ipv6Server=[PSCustomObject]@{Source='manual';User='alice';HostName='2001:db8::10';Port=2222}
Assert-Equal ((Get-ServerPulseSshArguments $ipv6Server passwordless 8000) -contains 'alice@[2001:db8::10]') $true '手动 IPv6 SSH 目标使用方括号'
$sessionSecrets=New-ServerPulseSessionSecretStore
Set-ServerPulseSessionSecret $sessionSecrets $identity 'session-secret'
Assert-Equal (Get-ServerPulseSessionSecret $sessionSecrets $identity) 'session-secret' '会话密码可供本次运行读取'
Remove-ServerPulseSessionSecret $sessionSecrets $identity
Assert-Equal ($null-eq(Get-ServerPulseSessionSecret $sessionSecrets $identity)) $true '取消监视立即清除会话密码'

$sshConfigTestPath=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-ssh-config-'+[guid]::NewGuid().ToString('N'))
try{
    @('Host 3090 a6000','  User alice','Host *.internal !blocked','Host concrete-host # comment')|Set-Content -LiteralPath $sshConfigTestPath -Encoding UTF8
    $aliases=@(Get-ServerPulseSshConfigAliases $sshConfigTestPath)
    Assert-Equal ($aliases -join ',') '3090,a6000,concrete-host' 'SSH config 发现具体 Host 并忽略通配符和否定项'
}finally{if(Test-Path $sshConfigTestPath){Remove-Item -LiteralPath $sshConfigTestPath -Force}}

$serverStoreTestDirectory=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-store-'+[guid]::NewGuid().ToString('N'))
$serverStoreTestPath=Join-Path $serverStoreTestDirectory 'servers.json'
try{
    $managed=New-ServerPulseManagedServer -Id 'stable-id' -Label 'GPU Node' -Source manual -SshTarget 'gpu.example' -HostName 'gpu.example' -Port 22 -User alice -Monitored $true
    $store=[PSCustomObject]@{Version=1;Path=$serverStoreTestPath;Servers=@($managed)}
    Save-ServerPulseServerStore $store
    $store.Servers[0].Label='GPU Node Updated';Save-ServerPulseServerStore $store
    $rawStore=Get-Content -LiteralPath $serverStoreTestPath -Raw -Encoding UTF8
    Assert-Equal (($rawStore|ConvertFrom-Json).Servers[0].Label) 'GPU Node Updated' '运行时服务器配置可原子替换已有文件'
    Assert-Equal ($rawStore -match 'session-secret|Password|Credential') $false '运行时服务器配置不保存密码或凭据令牌'
    $loaded=Initialize-ServerPulseServerStore -SeedConfig ([PSCustomObject]@{Servers=@()}) -Path $serverStoreTestPath
    Assert-Equal $loaded.Servers[0].Identity 'alice@gpu.example:22' 'LocalAppData 服务器配置可兼容读取'
    Assert-Equal $loaded.Servers[0].Monitored $true '监视选择持久保存'
    $knownHostsPath=Join-Path $serverStoreTestDirectory 'known_hosts'
    [IO.File]::WriteAllText($knownHostsPath,'existing-key',[Text.UTF8Encoding]::new($false))
    Assert-Equal (Add-ServerPulseTrustedHostKey -Lines @('new-key') -KnownHostsPath $knownHostsPath) 1 '确认后追加未知主机密钥'
    Assert-Equal ((Get-Content -LiteralPath $knownHostsPath -Raw)-match "existing-key`r?`nnew-key`r?`n$") $true 'known_hosts 原文件无换行时仍安全分隔新密钥'
    Assert-Equal (Add-ServerPulseTrustedHostKey -Lines @('new-key') -KnownHostsPath $knownHostsPath) 0 '相同主机密钥不重复写入'
}finally{if(Test-Path $serverStoreTestDirectory){Get-ChildItem $serverStoreTestDirectory -File|Remove-Item -Force;Remove-Item $serverStoreTestDirectory -Force}}

$askPassTestDirectory=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-askpass-'+[guid]::NewGuid().ToString('N'))
$aclPipe=New-ServerPulseSecurePipe ('serverpulse-acl-'+[guid]::NewGuid().ToString('N'))
try{
    $pipeAcl=if($null-ne$aclPipe.PSObject.Methods['GetAccessControl']){$aclPipe.GetAccessControl()}else{[IO.Pipes.PipesAclExtensions]::GetAccessControl($aclPipe)}
    $pipeRules=@($pipeAcl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]));$currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Assert-Equal $pipeAcl.AreAccessRulesProtected $true 'ASKPASS 命名管道禁用继承 ACL'
    Assert-Equal (@($pipeRules|Where-Object{$_.AccessControlType-eq'Allow'-and$_.IdentityReference.Value-eq$currentSid}).Count) 1 'ASKPASS 命名管道只授权当前 Windows SID'
    Assert-Equal (@($pipeRules|Where-Object{$_.IdentityReference.Value-ne$currentSid}).Count) 0 'ASKPASS 命名管道拒绝其他 SID'
}finally{$aclPipe.Dispose()}
try{
    $askPassPath=Ensure-ServerPulseAskPassHelper $askPassTestDirectory
    $mockServer=[PSCustomObject]@{Id='mock';Label='Mock';Source='manual';SshTarget='mock';HostName='mock';Port=22;User='tester'}
    $env:SERVERPULSE_MOCK_BATCH='fail'
    $mockSshPath=Join-Path $PSScriptRoot 'Mock-Ssh.cmd'
    $passwordResult=Invoke-ServerPulseSsh -Server $mockServer -Script 'ignored' -Mode password -Password 'mock-password' -TimeoutMs 8000 -AskPassPath $askPassPath -SshPath $mockSshPath
    Assert-Equal $passwordResult.ExitCode 0 'ASKPASS 命名管道完成普通密码认证'
    Assert-Equal ($passwordResult.Arguments -match 'mock-password') $false '密码不进入 SSH 命令行参数'
    $wrongResult=Invoke-ServerPulseServerConnection -Server $mockServer -Script 'ignored' -AuthMode auto -Password 'wrong-password' -TimeoutMs 8000 -AskPassPath $askPassPath -SshPath $mockSshPath
    Assert-Equal $wrongResult.Status 'authentication_failed' '错误密码分类为认证暂停而不是持续重试'
    $env:SERVERPULSE_MOCK_BATCH='ok'
    $batchResult=Invoke-ServerPulseServerConnection -Server $mockServer -Script 'ignored' -AuthMode auto -Password 'wrong-password' -TimeoutMs 8000 -AskPassPath $askPassPath -SshPath $mockSshPath
    Assert-Equal $batchResult.AuthMode 'passwordless' '免密成功时优先于已有密码'
    $env:SERVERPULSE_MOCK_BATCH='fail'
    $parallelRequests=@(
        [PSCustomObject]@{Id='one';Server=$mockServer;Password='mock-password'},
        [PSCustomObject]@{Id='two';Server=$mockServer;Password='mock-password'}
    )
    $parallelResults=Invoke-ServerPulseAuthenticationBatch -Requests $parallelRequests -ModulePath (Join-Path $PSScriptRoot '..\src\ServerPulse.Ssh.ps1') -AskPassPath $askPassPath -TimeoutMs 8000 -SshPath $mockSshPath
    Assert-Equal @($parallelResults|Where-Object{$_.Passed}).Count 2 '并行密码认证使用独立 ASKPASS 请求并全部完成'
}finally{
    Remove-Item Env:SERVERPULSE_MOCK_BATCH -ErrorAction SilentlyContinue
    if(Test-Path $askPassTestDirectory){Get-ChildItem $askPassTestDirectory -File|Remove-Item -Force;Remove-Item $askPassTestDirectory -Force}
}

$mainScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ServerPulse.ps1') -Raw -Encoding UTF8
$iconPath=Join-Path $PSScriptRoot '..\assets\server-pulse.ico';$iconBytes=[IO.File]::ReadAllBytes($iconPath)
Assert-Equal (($iconBytes[0..3]-join',')) '0,0,1,0' 'Server Pulse 托盘资源是有效 ICO 容器'
$iconCount=[BitConverter]::ToUInt16($iconBytes,4);Assert-Equal $iconCount 6 'ICO 包含六种分辨率'
$iconSizes=for($iconIndex=0;$iconIndex-lt$iconCount;$iconIndex++){$iconWidth=[int]$iconBytes[6+($iconIndex*16)];if($iconWidth-eq0){$iconWidth=256};$iconWidth}
Assert-Equal (($iconSizes|Sort-Object)-join',') '16,20,24,32,48,256' 'ICO 包含托盘和高分辨率所需尺寸'
Assert-Equal ([bool]($mainScript -match '\.DragMove\(')) $false '禁止调用会触发 Windows Snap Assist 的 DragMove'
Assert-Equal ([bool]($mainScript -match 'Update-ManualDragPosition')) $true '使用应用内坐标拖拽'
Assert-Equal ([bool]($mainScript -match 'ShowInTaskbar="False"')) $true '主窗口不占用 Windows 任务栏'
Assert-Equal ([bool]($mainScript -match 'x:Name="ThemeButton"')) $true '主窗口右上角提供主题切换按钮'
Assert-Equal ([bool]($mainScript -match "@\('light','亮'\),@\('dark','暗'\),@\('system','跟随系统'\)")) $true '主题菜单包含亮、暗和跟随系统三种模式'
Assert-Equal ([bool]($mainScript -match "ThemeMode = 'dark'")) $true '全新和旧配置默认使用暗色主题'
Assert-Equal ([bool]($mainScript -match 'ThemeMode=\$script:themeMode')) $true '用户主题选择随设置持久化'
Assert-Equal ([bool]($mainScript -match 'Get-ServerPulseSystemTheme|Resolve-ServerPulseTheme')) $true '跟随系统模式定时解析 Windows 应用主题'
Assert-Equal ([bool]($mainScript -match 'x:Name="LanguageButton"')) $true '主窗口右上角提供语言切换按钮'
Assert-Equal ([bool]($mainScript -match 'Format-ServerPulseGpuTitle')) $true '主界面 GPU 标题显示型号'
Assert-Equal ([bool]($mainScript -match "@\('zh','中文'\),@\('en','English'\),@\('system','跟随系统'\)")) $true '语言菜单包含中文、英文和跟随系统三种模式'
Assert-Equal ([bool]($mainScript -match "LanguageMode = 'zh'")) $true '全新配置默认使用中文'
Assert-Equal ([bool]($mainScript -match 'LanguageMode=\$script:languageMode')) $true '用户语言选择随设置持久化'
Assert-Equal ([bool]($mainScript -match 'Set-ServerPulseLanguageMode')) $true '语言按钮切换会刷新主界面'
Assert-Equal ([bool]($mainScript -match '\[Windows\.Forms\.NotifyIcon\]::new\(\)')) $true '创建 Windows 托盘图标'
Assert-Equal ([bool]($mainScript -match 'Join-Path \$scriptRoot ''assets\\server-pulse\.ico''')) $true '托盘加载 Server Pulse 多分辨率图标'
Assert-Equal ([bool]($mainScript -match '\$script:trayOwnedIcon\.Dispose\(\)')) $true '退出时释放自定义托盘图标句柄'
Assert-Equal ([bool]($mainScript -match '\[Windows\.Forms\.ContextMenuStrip\]::new\(\)')) $true '托盘图标提供操作菜单'
Assert-Equal ([bool]($mainScript -match 'function Show-ServerPulseFromTray')) $true '托盘可恢复主窗口'
Assert-Equal ([bool]($mainScript -match 'function Hide-ServerPulseToTray')) $true '托盘可隐藏主窗口'
Assert-Equal ([bool]($mainScript -match '(?s)\$ui\.MinimizeButton\.Add_Click.+?Hide-ServerPulseToTray')) $true '最小化按钮隐藏到托盘'
Assert-Equal ([bool]($mainScript -match '(?s)\$window\.Add_Closing.+?\$script:trayIcon\.Dispose\(\)')) $true '退出时释放托盘图标'
Assert-Equal ([bool]($mainScript -match 'Show-ServerPulseSshManager')) $true '主窗口和托盘可打开 SSH 服务器管理窗口'
Assert-Equal ([bool]($mainScript -match "'retry_wait'\{Get-ServerPulseText 'main.retryState'")) $true '主卡片显示断线自动重试倒计时'
Assert-Equal ([bool]($mainScript -match "'circuit_open'\{Get-ServerPulseText 'main.retryPaused'")) $true '主卡片显示连接熔断暂停'
Assert-Equal ([bool]($mainScript -match 'if\(\$script:sshManagerOpen\).*\$script:sshManagerWindow\.Activate\(\).*return')) $true 'SSH 管理窗口具有单实例激活门闩'
Assert-Equal ([bool]($mainScript -match 'if\(\$script:sshManagerOpen-or\$script:sshManagerOpenQueued\)\{return\}')) $true '自动打开 SSH 管理窗口不会重复排队'
Assert-Equal ([bool]($mainScript -match 'Show-ServerPulseSshManager -Queued')) $true '排队的管理窗口调用可被手动打开取消'
Assert-Equal ([bool]($mainScript -match 'Clear-ServerPulseSessionSecrets')) $true '退出程序时清除全部会话密码'
Assert-Equal ([bool]($mainScript -match '\$runtimePayload=\$null;foreach\(\$item in \$runtimeServers\)\{\$item\.Password=\$null\}')) $true '采集输入写入标准输入后清除主进程密码副本'
$sshScript=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.Ssh.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($sshScript -match 'SERVERPULSE_AUTH_TOKEN=\$token')) $true 'ASKPASS 仅通过环境传递随机令牌'
Assert-Equal ([bool]($sshScript -match 'EnvironmentVariables\[[^\]]+\]\s*=\s*\$Password')) $false '密码不得写入子进程环境变量'
$managerScript=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.ServerManager.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($managerScript -match 'New-ServerPulseThemeBrush')) $true 'SSH 管理窗口复用共享主题色'
Assert-Equal ([bool]($managerScript -match 'Update-ServerManagerLanguage')) $true 'SSH 管理窗口支持语言刷新'
Assert-Equal ([bool]($managerScript -match 'InheritHistory=\[bool\]\$w\.Tag\.Inherit\.IsChecked')) $true '编辑连接身份时由用户选择是否继承历史'
Assert-Equal ([bool]($managerScript -match 'DeleteCredentialButton')) $true '服务器管理窗口允许独立删除 Windows 凭据'
Assert-Equal ([bool]($managerScript -match 'New-ServerManagerButtonStyle')) $true '服务器管理按钮使用显式亮暗主题样式'
Assert-Equal ([bool]($managerScript -match 'New-ServerManagerCheckBoxStyle')) $true '服务器管理复选框使用显式亮暗主题样式'
Assert-Equal ([bool]($managerScript -match '\.BeginStop\(')) $true '关闭管理窗口时异步停止 SSH 发现而不阻塞 UI'
Assert-Equal ([bool]($managerScript -match '\$window\.ShowDialog\(\)')) $false 'SSH 管理窗口不得使用会禁用主界面的模态消息循环'
Assert-Equal ([bool]($managerScript -match '\$window\.Show\(\)')) $true 'SSH 管理窗口使用非模态显示'
Assert-Equal ([bool]($mainScript -match 'Register-UserUsageTarget')) $true '实时卡片注册用户占用交互目标'
Assert-Equal ([bool]($mainScript -match '\$Target\.Add_MouseEnter\(\{\s*param\(\$sender[^}]+Invoke-UserUsageTargetMouseEnter \$sender\.Tag')) $true '实时用户悬停回调通过 sender.Tag 保持注册后生命周期'
Assert-Equal ([bool]($mainScript -match '(?s)if \(\$manager\.IsPinned.+?\$manager\.CurrentTarget\.Key -eq \$TargetState\.Key\).+?Close-UserUsagePopup')) $true '实时用户卡片再次点击关闭已固定弹窗'
Assert-Equal ([bool]($mainScript -match '\$manager\.CurrentTarget = \$TargetState\s+\$manager\.IsPinned = \[bool\]\$Pinned')) $true '点击其他实时目标替换当前固定弹窗'
Assert-Equal ([bool]($mainScript -match '(?s)\$eventArgs\.Key -eq \[Windows\.Input\.Key\]::Escape[^}]+Close-UserUsagePopup')) $true 'Esc 关闭实时用户弹窗'
Assert-Equal ([bool]($mainScript -match '(?s)function Close-UserUsagePopup.+?-not \$window\.IsMouseOver.+?\$hideTimer\.Start\(\)')) $true '关闭用户弹窗时鼠标仍在主窗口内不得启动贴边收起'
Assert-Equal ([bool]($mainScript -match '\("\{0\}:gpu:\{1\}:vram" -f \$Card\.ServerId,\$index\)')) $true 'GPU 用户弹窗以服务器和稳定 GPU 索引为锚点'
Assert-Equal ([bool]($mainScript -match 'if \(\$isCurrent -and \$manager\.IsPinned\) \{ ''#79C8D8'' \}')) $true '固定实时用户目标使用稳定高亮色'
$liveUnknownRowsPattern = '(?s)if \(\[string\]::IsNullOrWhiteSpace\(\$name\)\).+?"UID \$uid"'
Assert-Equal ([bool]($mainScript -match $liveUnknownRowsPattern)) $true '实时弹窗未知用户名回退 UID'
$vramFormatPattern = '''\{0:0\.0\} GB · \{1\}'''
Assert-Equal ([bool]($mainScript -match $vramFormatPattern)) $true '实时显存用户值同时显示 GB 与百分比'
$historyScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.History.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($historyScript -match 'New-ServerPulseThemeBrush')) $true '历史记录窗口复用共享主题色'
Assert-Equal ([bool]($historyScript -match 'Format-ServerPulseGpuTitle')) $true '历史 GPU 图表标题显示型号'
Assert-Equal ([bool]($historyScript -match 'Update-HistoryChartPopupHint')) $true '历史详情浮窗更新固定状态提示'
Assert-Equal ([bool]($historyScript -match 'ClickCount[^\r\n]+-ge 2')) $true '历史详情浮窗支持双击曲线解除固定'
Assert-Equal ([bool]($historyScript -match 'history\.userCurveHint')) $true '历史用户行显示曲线查看提示'
Assert-Equal ([bool]($historyScript -match 'Update-HistoryWindowLanguage')) $true '历史记录窗口支持语言刷新'
Assert-Equal ([bool]($historyScript -match 'HistoryCloseButton\.Add_Click\(\{\s*\$historyWindow\.Close')) $false '历史关闭回调不得依赖动态窗口变量'
Assert-Equal ([bool]($historyScript -match '\[Windows\.Window\]::GetWindow\(\$sender\)')) $true '历史关闭回调从按钮解析所属窗口'
Assert-Equal ([bool]($historyScript -match 'HistoryDragArea\.Add_Mouse[^\r\n]+\$drag')) $false '历史拖拽回调不得依赖动态拖拽变量'
Assert-Equal ([bool]($historyScript -match 'Register-HistoryWindowDragArea')) $true '历史拖拽事件使用独立注册函数'
Assert-Equal ([bool]($historyScript -match '(?m)^\s*\$ui\s*=\s*@\{\}')) $false '历史窗口不得覆盖主窗口 UI 动态变量'
Assert-Equal ([bool]($historyScript -match 'ChartKey "\$ServerId/gpu/\$gpuIndex/vram"')) $true '历史 GPU 用户选择以服务器和稳定 GPU 索引为锚点'
Assert-Equal ([bool]($historyScript -match 'Renderer=\$\{function:Invoke-ServerPulseHistoryRender\}')) $true '历史查询状态捕获渲染器而非依赖动态命令查找'
Assert-Equal ([bool]($historyScript -match '(?s)\$renderCore\s*=.+?GetNewClosure')) $false '历史生产渲染不得进入隔离 helper 的动态闭包'
Assert-Equal ([bool]($mainScript -match 'function Show-ServerPulseErrorDialog')) $true '主窗口提供独立历史错误对话框'
Assert-Equal ([bool]($mainScript -match 'ShowInTaskbar="False" WindowStartupLocation="CenterOwner" Topmost="True"')) $true '历史错误对话框独立置顶且不创建任务栏项'
Assert-Equal ([bool]($mainScript -match "Context 'Open history window'")) $true '历史窗口打开异常写入错误日志'
Assert-Equal ([bool]($mainScript -match '\$ui\.SummaryText\.Text\s*=\s*"历史记录错误')) $false '历史窗口打开异常不再覆盖主状态栏'
Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
$renderDirectory=Join-Path ([IO.Path]::GetTempPath()) ("serverpulse-render-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $renderRecorder=New-ServerPulseHistoryRecorder -Directory $renderDirectory -RetentionDays 30
    $renderRecord=$record | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    Save-HistoryMinuteRecord -Recorder $renderRecorder -Record $renderRecord
    $renderUi=@{HistoryPanel=[Windows.Controls.StackPanel]::new();HistoryRangeStatus=[Windows.Controls.TextBlock]::new();HistoryFooterText=[Windows.Controls.TextBlock]::new()}
    foreach($prefix in @('HistoryStart','HistoryEnd')){foreach($field in @('Year','Month','Day','Hour','Minute')){$renderUi["${prefix}${field}Box"]=[Windows.Controls.TextBox]::new();$renderUi["${prefix}${field}Error"]=[Windows.Controls.TextBlock]::new()}}
    Set-HistoryDateFields -Ui $renderUi -Prefix HistoryStart -Value ([datetime]'2026-08-11 09:07')
    Set-HistoryDateFields -Ui $renderUi -Prefix HistoryEnd -Value ([datetime]'2026-08-11 09:07')
    $renderState=[PSCustomObject]@{Ui=$renderUi;Recorder=$renderRecorder;SelectionStore=@{};Renderer=${function:Invoke-ServerPulseHistoryRender};LastError=$null}
    $isolatedRender={param($state);& $state.Renderer -State $state}.GetNewClosure()
    $renderPassed=& $isolatedRender $renderState
    Assert-Equal $renderPassed $true '捕获的历史渲染器可从隔离动态闭包调用'
    Assert-Equal $renderUi.HistoryPanel.Children.Count 1 '隔离动态闭包正常生成历史服务器卡片'
    Assert-Equal $renderState.LastError $null '隔离动态闭包渲染不产生 helper 解析错误'
} finally {
    Remove-Item -LiteralPath $renderDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
$managerOwner=[Windows.Window]::new();$managerOwner.Show()
$managerServer=New-ServerPulseManagedServer -Id 'manager-test' -Label 'Manager Test' -Source manual -SshTarget 'gpu.example' -HostName 'gpu.example' -Port 22 -User alice -Monitored $true
$managerStore=[PSCustomObject]@{Version=1;Path=(Join-Path ([IO.Path]::GetTempPath()) 'serverpulse-manager-unused.json');Servers=@($managerServer)}
$managerSecrets=New-ServerPulseSessionSecretStore
$managerValidationStates=@{}
Set-ServerPulseSessionSecret $managerSecrets $managerServer.Identity 'manager-session-secret'
$managerConstruction=[Diagnostics.Stopwatch]::StartNew();$managerSmoke=Show-ServerPulseServerManager -Owner $managerOwner -Store $managerStore -SessionSecrets $managerSecrets -AskPassPath 'unused' -TimeoutMs 1000 -ValidationStates $managerValidationStates -OnApplied {} -SmokeTest;$managerConstruction.Stop()
Assert-Equal ($managerSmoke -is [PSCustomObject]) $true '服务器管理窗口冒烟入口只返回一个状态对象'
Assert-Equal ($managerConstruction.ElapsedMilliseconds-lt1000) $true 'SSH 配置发现不阻塞管理窗口构造'
Assert-Equal ($managerSmoke.Context.DiscoveryAsync -ne $null) $true 'SSH 配置发现运行在后台而非阻塞窗口构造'
$managerRow=$managerSmoke.Context.Rows[0]
Assert-Equal $managerRow.Monitor.IsChecked $true '服务器管理窗口显示监视选择'
Assert-Equal ($null -ne $managerRow.Monitor.Style) $true '监视复选框应用自定义主题样式'
Assert-Equal ($null -ne $managerRow.TestButton.Style) $true '重新检测按钮应用自定义主题样式'
Assert-Equal $managerRow.Passwordless.IsHitTestVisible $false '免密复选框只读并由检测结果控制'
Assert-Equal ([string]$managerRow.Passwordless.Parent.Children[1].ToolTip -match '终端 ssh 不会自动读取') $true '免密感叹号悬停解释凭据边界'
Assert-Equal $managerRow.SaveCredential.IsChecked $false '存入 Windows 凭据管理器默认不勾选'
$originalAuthenticationBatch=${function:Invoke-ServerPulseAuthenticationBatch}
try {
Set-Item -LiteralPath function:Invoke-ServerPulseAuthenticationBatch -Value { [PSCustomObject]@{Id='manager-test';Passed=$true;Status='online';AuthMode='passwordless';Error=$null} }
$script:manualRetryId=$null;$managerRow.Context.OnRetryRequested={param($serverId);$script:manualRetryId=$serverId}
Invoke-ServerManagerRowTest $managerRow -Manual
Assert-Equal $script:manualRetryId 'manager-test' '手动重新检测立即请求解除 Worker 熔断和退避'
Invoke-ServerManagerRowTest $managerRow
    Assert-Equal $managerRow.Status 'passwordless' '单服务器重新检测接受标量认证结果'
    Set-Item -LiteralPath function:Invoke-ServerPulseAuthenticationBatch -Value { throw 'mock internal detection error' }
    Invoke-ServerManagerRowTest $managerRow
    Assert-Equal $managerRow.Status 'error' '重新检测内部异常不伪装成连接失败'
    Assert-Equal $managerRow.StatusText.Text '检测失败' '重新检测内部异常使用明确状态文案'
} finally {
    Set-Item -LiteralPath function:Invoke-ServerPulseAuthenticationBatch -Value $originalAuthenticationBatch
}
Set-ServerManagerRowStatus $managerRow authentication_required
Assert-Equal $managerRow.PasswordPanel.Visibility 'Visible' '无可用认证时在服务器行展开密码输入'
$managerRow.PasswordBox.Password='visible-on-hold'
$eyeDown=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left);$eyeDown.RoutedEvent=[Windows.UIElement]::PreviewMouseLeftButtonDownEvent;$managerRow.Eye.RaiseEvent($eyeDown)
Assert-Equal $managerRow.Reveal.Text 'visible-on-hold' '按住眼睛按钮临时显示密码'
$eyeUp=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left);$eyeUp.RoutedEvent=[Windows.UIElement]::PreviewMouseLeftButtonUpEvent;$managerRow.Eye.RaiseEvent($eyeUp)
Assert-Equal $managerRow.Reveal.Visibility 'Collapsed' '松开眼睛按钮立即重新遮蔽密码'
Assert-Equal $managerRow.Reveal.Text '' '松开眼睛按钮清除明文副本'
$managerRow.PasswordBox.Password='replacement-session-secret';$managerRow.SaveCredential.IsChecked=$false
Complete-ServerPulseAuthenticationResult $managerRow.Context $managerRow ([PSCustomObject]@{Passed=$true;Status='online';AuthMode='password';Error=$null}) 'replacement-session-secret'
Assert-Equal (Get-ServerPulseSessionSecret $managerSecrets $managerServer.Identity) 'manager-session-secret' '验证新密码不会在应用前改写当前会话'
Assert-Equal (Get-ServerPulseSessionSecret $managerRow.Context.SessionSecrets $managerServer.Identity) 'replacement-session-secret' '服务器管理窗口在独立工作副本中暂存会话密码'
$managerRow.PasswordBox.Password='deferred-persist-secret';$managerRow.SaveCredential.IsChecked=$true
Complete-ServerPulseAuthenticationResult $managerRow.Context $managerRow ([PSCustomObject]@{Passed=$true;Status='online';AuthMode='password';Error=$null}) 'deferred-persist-secret'
Assert-Equal (Get-ServerPulseAuthenticationPassword $managerRow $managerRow.Context.SessionSecrets) 'deferred-persist-secret' '已验证的持久密码在应用前只存在于管理窗口待办中'
Assert-Equal (Get-ServerPulseSessionSecret $managerSecrets $managerServer.Identity) 'manager-session-secret' '待保存 Windows 凭据不会在应用前改变当前监控'
$managerRow.Monitor.IsChecked=$false
Assert-Equal (Get-ServerPulseSessionSecret $managerSecrets $managerServer.Identity) 'manager-session-secret' '取消管理窗口前取消勾选不提前改变当前会话密码'
$managerSmoke.Window.Close();$managerOwner.Close();Clear-ServerPulseSessionSecrets $managerSecrets
$rememberOwner=[Windows.Window]::new();$rememberOwner.Show();$rememberSecrets=New-ServerPulseSessionSecretStore;$rememberStates=@{}
$rememberFirst=Show-ServerPulseServerManager -Owner $rememberOwner -Store $managerStore -SessionSecrets $rememberSecrets -AskPassPath 'unused' -TimeoutMs 1000 -ValidationStates $rememberStates -OnApplied {} -SmokeTest
$rememberFirstRow=$rememberFirst.Context.Rows[0]
Complete-ServerPulseAuthenticationResult $rememberFirst.Context $rememberFirstRow ([PSCustomObject]@{Passed=$true;Status='online';AuthMode='passwordless';Error=$null}) $null
Assert-Equal $rememberStates['manager-test'].Mode 'passwordless' '重新检测成功后缓存免密认证模式'
$rememberFirst.Window.Close()
$rememberSecond=Show-ServerPulseServerManager -Owner $rememberOwner -Store $managerStore -SessionSecrets $rememberSecrets -AskPassPath 'unused' -TimeoutMs 1000 -ValidationStates $rememberStates -OnApplied {} -SmokeTest
$rememberSecondRow=$rememberSecond.Context.Rows[0]
Assert-Equal $rememberSecondRow.Status 'passwordless' '关闭并重开管理窗口仍显示免密已验证'
Assert-Equal $rememberSecondRow.Passwordless.IsChecked $true '关闭并重开管理窗口仍勾选免密登录'
Complete-ServerPulseAuthenticationResult $rememberSecond.Context $rememberSecondRow ([PSCustomObject]@{Passed=$true;Status='online';AuthMode='password';Error=$null}) $null
$rememberSecond.Window.Close()
$rememberThird=Show-ServerPulseServerManager -Owner $rememberOwner -Store $managerStore -SessionSecrets $rememberSecrets -AskPassPath 'unused' -TimeoutMs 1000 -ValidationStates $rememberStates -OnApplied {} -SmokeTest
Assert-Equal $rememberThird.Context.Rows[0].Status 'online' '密码验证结果关闭并重开管理窗口后仍保留'
Assert-Equal $rememberThird.Context.Rows[0].Passwordless.IsChecked $false '密码认证恢复时免密复选框保持未勾选'
$rememberThird.Window.Close();$rememberOwner.Close();Clear-ServerPulseSessionSecrets $rememberSecrets
$modelessOwner=[Windows.Window]::new();$modelessOwner.Topmost=$true;$modelessOwner.Show();$modelessSecrets=New-ServerPulseSessionSecretStore
$modelessManager=Show-ServerPulseServerManager -Owner $modelessOwner -Store $managerStore -SessionSecrets $modelessSecrets -AskPassPath 'unused' -TimeoutMs 1000 -OnApplied {}
Assert-Equal $modelessManager.Window.IsVisible $true '非模态 SSH 管理窗口立即可见'
Assert-Equal $modelessOwner.IsEnabled $true 'SSH 管理窗口打开时主窗口保持可点击'
Assert-Equal $modelessManager.Window.ShowInTaskbar $false 'SSH 管理窗口不创建独立任务栏项目'
Assert-Equal $modelessManager.Window.Topmost $true 'SSH 管理窗口跟随置顶主窗口'
$modelessManager.Window.Close();$modelessOwner.Close();Clear-ServerPulseSessionSecrets $modelessSecrets
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
$wpfHoverWindow=[Windows.Window]::new(); $wpfHoverWindow.Width=600; $wpfHoverCard=New-HistoryChartCard -Title 'GPU 0' -Subtitle '' -Series $wpfHoverSeries -Start $wpfHoverTime.AddMinutes(-30) -End $wpfHoverTime.AddMinutes(30)
$wpfHoverBlocker=[Windows.Controls.Border]::new(); $wpfHoverBlocker.Width=264; $wpfHoverBlocker.Height=142; $wpfHoverBlocker.Background=New-HistoryBrush '#1B201D'
$wpfHoverWrap=[Windows.Controls.WrapPanel]::new(); [void]$wpfHoverWrap.Children.Add($wpfHoverCard); [void]$wpfHoverWrap.Children.Add($wpfHoverBlocker); $wpfHoverWindow.Content=$wpfHoverWrap
$wpfHoverWindow.Show(); $wpfHoverWindow.UpdateLayout()
Assert-Equal @($wpfHoverCard.Tag.Views | Where-Object { $null -ne $_.Toggle }).Count 3 'GPU 图表提供三个指标显示开关'
$wpfHoverMove=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $wpfHoverMove.RoutedEvent=[Windows.UIElement]::MouseMoveEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverMove)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count 3 'WPF 悬停同时标记同分钟三条曲线'
Assert-Equal $wpfHoverCard.Tag.Popup.IsHitTestVisible $false '未锁定的历史悬停浮窗必须穿透鼠标以继续扫图'
Assert-Equal ([Windows.Controls.Panel]::GetZIndex($wpfHoverCard) -gt [Windows.Controls.Panel]::GetZIndex($wpfHoverBlocker)) $true '显示历史详情时当前图表卡片必须高于后续 GPU 卡片'
$wpfPopupLeft=[Windows.Controls.Canvas]::GetLeft($wpfHoverCard.Tag.Popup); $wpfPopupRight=$wpfPopupLeft+$wpfHoverCard.Tag.Popup.Width; $wpfSampleX=[Windows.Controls.Canvas]::GetLeft($wpfHoverCard.Tag.Markers[0].Shape)+4.5
Assert-Equal (($wpfPopupRight -le ($wpfSampleX-7)) -or ($wpfPopupLeft -ge ($wpfSampleX+7))) $true '历史悬停浮窗必须避开当前采样线'
Assert-Equal $wpfHoverCard.Tag.TimeBlock.Text '2026-08-11 09:45' 'WPF 悬停显示完整具体时间'
Assert-Equal @($wpfHoverCard.Tag.Views | Where-Object { $_.PopupRow.Visibility -eq 'Visible' }).Count 3 '悬停浮窗将三个指标分行显示'
Assert-Equal $wpfHoverCard.Tag.PopupHint.Text '单击曲线固定弹窗' 'WPF 悬停详情浮窗显示固定提示'
Assert-Equal $wpfHoverCard.Tag.Views[0].PopupText.Text 'GPU  55%' '悬停行显示 GPU 数值'
Assert-Equal $wpfHoverCard.Tag.Views[1].PopupDot.Fill.ToString() '#FF79C8D8' '悬停行使用对应曲线颜色标记'
$wpfToggleDown=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $wpfToggleDown.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent; $wpfHoverCard.Tag.Views[1].Toggle.RaiseEvent($wpfToggleDown)
Assert-Equal $wpfHoverCard.Tag.Views[1].IsVisible $false '点击 VRAM 开关隐藏指标'
Assert-Equal $wpfHoverCard.Tag.Views[1].Line.Visibility 'Collapsed' '隐藏指标同时隐藏对应曲线'
$wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverMove)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count 2 '隐藏后仅标记其余可见曲线'
Assert-Equal @($wpfHoverCard.Tag.Views | Where-Object { $_.PopupRow.Visibility -eq 'Visible' }).Count 2 '隐藏后浮窗不显示该指标行'
$wpfHoverDown=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $wpfHoverDown.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverDown)
Assert-Equal $wpfHoverCard.Tag.IsLocked $true '点击历史图表锁定当前分钟'
Assert-Equal $wpfHoverCard.Tag.PopupHint.Text '双击曲线解除固定' '锁定详情浮窗切换为双击解除提示'
Assert-Equal $wpfHoverCard.Tag.Popup.IsHitTestVisible $true '锁定后的历史浮窗恢复交互以选择用户曲线'
$wpfHoverLeave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $wpfHoverLeave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverLeave)
$wpfHoverCard.Tag.IsLocked=$false; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverLeave)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -ne 'Collapsed' }).Count 0 '未锁定时鼠标移出后隐藏全部悬停标记'
Assert-Equal ([Windows.Controls.Panel]::GetZIndex($wpfHoverCard)) 0 '历史详情关闭后恢复图表卡片默认层级'
$wpfHoverWindow.Close()

$gapStart=[datetime]'2026-08-11 09:00'
$gapSeries=@([PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Latest=40;Points=@(
    [PSCustomObject]@{Time=$gapStart;Value=10},
    [PSCustomObject]@{Time=$gapStart.AddMinutes(1);Value=20},
    [PSCustomObject]@{Time=$gapStart.AddMinutes(10);Value=30},
    [PSCustomObject]@{Time=$gapStart.AddMinutes(11);Value=40}
)})
$gapCard=New-HistoryChartCard -Title '缺失采样' -Subtitle '' -Series $gapSeries -Start $gapStart -End $gapStart.AddMinutes(12)
$gapView=$gapCard.Tag.Views[0]
Assert-Equal ([bool]($gapView.PSObject.Properties.Name -contains 'LineSegments')) $true '历史主曲线暴露按有效区间拆分的线段集合'
Assert-Equal @($gapView.LineSegments).Count 2 '历史主曲线不跨越缺失分钟直接连线'
$gapUser=[PSCustomObject]@{Identity='uid:gap';Uid='gap';Name='gap-user';RawValue=10.0;PlotValue=10.0;Color='#F07178';IsSystem=$false}
$gapUserPoints=@(
    [PSCustomObject]@{Time=$gapStart;Status='ok';Kind='Cpu';TotalMiB=$null;DetailNote='';Users=@($gapUser)},
    [PSCustomObject]@{Time=$gapStart.AddMinutes(1);Status='ok';Kind='Cpu';TotalMiB=$null;DetailNote='';Users=@($gapUser)},
    [PSCustomObject]@{Time=$gapStart.AddMinutes(10);Status='ok';Kind='Cpu';TotalMiB=$null;DetailNote='';Users=@($gapUser)},
    [PSCustomObject]@{Time=$gapStart.AddMinutes(11);Status='ok';Kind='Cpu';TotalMiB=$null;DetailNote='';Users=@($gapUser)}
)
$gapSelection=@{'gap:cpu'=@('uid:gap')}
$gapUserCard=New-HistoryChartCard -Title '用户缺失采样' -Subtitle '' -Series $gapSeries -Start $gapStart -End $gapStart.AddMinutes(12) -UserPoints $gapUserPoints -UserKind Cpu -UserParentSeries GPU -ChartKey 'gap:cpu' -SelectionStore $gapSelection
Assert-Equal @($gapUserCard.Tag.UserLineShapes).Count 2 '历史用户曲线同样不跨越缺失分钟直接连线'

$colorA = Get-HistoryUserColor 'Alpha'
$colorB = Get-HistoryUserColor 'alpha'
Assert-Equal $colorA $colorB '历史用户颜色按身份稳定且忽略大小写'
$historyUserTime = [datetime]'2026-08-11 10:00'
$historyCpuUsage = [PSCustomObject]@{
    Status='ok'; ValidSamples=1; UnattributedPercent=5; OverlapPercent=0; AttributedPercent=50; SkippedProcesses=0
    Users=@(
        [PSCustomObject]@{Uid='1';Name='alpha';Percent=20},
        [PSCustomObject]@{Uid='2';Name='beta';Percent=15},
        [PSCustomObject]@{Uid='3';Name='gamma';Percent=10},
        [PSCustomObject]@{Uid='4';Name='delta';Percent=5}
    )
}
$historyCpuPoint = ConvertTo-HistoryUserPoint -Time $historyUserTime -Usage $historyCpuUsage -Kind Cpu -TotalMiB $null
Assert-Equal @($historyCpuPoint.Users).Count 5 '历史 CPU 用户点包含用户与系统未归属'
Assert-Equal (@($historyCpuPoint.Users | Where-Object IsSystem).Count) 1 '历史用户点明确标记系统未归属'
$historyVramUsage = [PSCustomObject]@{Status='ok';ValidSamples=1;UnattributedMiB=256;AttributedMiB=1024;UnmappedProcesses=0;Users=@([PSCustomObject]@{Uid='1';Name='alpha';UsedMiB=1024})}
$historyVramPoint = ConvertTo-HistoryUserPoint -Time $historyUserTime -Usage $historyVramUsage -Kind GpuMemory -TotalMiB 2048
Assert-Equal $historyVramPoint.Users[0].PlotValue 50 '历史显存用户曲线按单卡总显存换算百分比'
Assert-Equal (Format-HistoryUserValue $historyVramPoint.Users[0] 'GpuMemory') '1.0 GB · 50.0%' '历史显存用户浮窗同时显示绝对值与容量百分比'

$selectionStore = @{}
$userSeries = @([PSCustomObject]@{Name='CPU';Suffix='%';Color='#A7D948';Latest=50;Points=@([PSCustomObject]@{Time=$historyUserTime;Value=50})})
$historyUserWindow=[Windows.Window]::new()
$historyUserCard=New-HistoryChartCard -Title 'CPU 用户' -Subtitle '' -Series $userSeries -Start $historyUserTime.AddMinutes(-1) -End $historyUserTime.AddMinutes(1) -UserPoints @($historyCpuPoint) -UserKind Cpu -UserParentSeries CPU -ChartKey 'server:cpu' -SelectionStore $selectionStore
$historyUserWindow.Content=$historyUserCard; $historyUserWindow.Show(); $historyUserWindow.UpdateLayout()
$historyUserCard.Tag.IsLocked=$true; $historyUserCard.Tag.LockedTime=$historyUserTime
Show-HistoryChartSample -State $historyUserCard.Tag -Time $historyUserTime
Assert-Equal $historyUserCard.Tag.PopupHint.Text '双击曲线解除固定' '历史固定详情浮窗显示双击解除提示'
$historyFirstUserRow=@($historyUserCard.Tag.UserPanel.Children | Where-Object { $null -ne $_.Tag -and $null -ne $_.Tag.User -and -not $_.Tag.User.IsSystem } | Select-Object -First 1)[0]
Assert-Equal $historyFirstUserRow.Child.Children[0].Children.Count 2 '历史用户行在用户名后显示曲线提示'
$systemPopupRows = @($historyUserCard.Tag.UserPanel.Children | Where-Object { $null -ne $_.Tag -and $null -ne $_.Tag.User -and $_.Tag.User.IsSystem })
Assert-Equal $systemPopupRows.Count 1 '历史系统未归属始终单列展示'
Assert-Equal $systemPopupRows[0].Tag.User.Name '系统/未归属' '历史系统未归属保持专用末行身份'
$taggedPopupRows = @($historyUserCard.Tag.UserPanel.Children | Where-Object { $null -ne $_.Tag -and $_.Tag.PSObject.Properties.Name -contains 'User' })
Assert-Equal $taggedPopupRows[-1].Tag.User.IsSystem $true '历史系统未归属固定为用户列表末行'
foreach($identity in @('uid:1','uid:2','uid:3','uid:4')) { Toggle-HistoryChartUserSelection $historyUserCard.Tag $identity }
Assert-Equal $historyUserCard.Tag.SelectedUsers.Count 3 '历史用户曲线最多固定三名用户'
Assert-Equal ($historyUserCard.Tag.SelectedUsers -contains 'uid:1') $false '固定第四名用户时移除最早选择'
Assert-Equal @($historyUserCard.Tag.UserLineShapes).Count 3 '三名已选用户分别绘制独立颜色曲线'
Assert-Equal @($selectionStore['server:cpu']).Count 3 '历史用户选择按稳定图表锚点保存'
$zeroUserPoint = [PSCustomObject]@{Time=$historyUserTime;Status='ok';Kind='Cpu';TotalMiB=$null;DetailNote='';Users=@([PSCustomObject]@{Identity='uid:zero';Uid='zero';Name='zero';RawValue=0.0;PlotValue=0.0;Color='#F07178';IsSystem=$false})}
$historyUserCard.Tag.UserPoints=@($zeroUserPoint); $historyUserCard.Tag.SelectedUsers.Clear(); $historyUserCard.Tag.SelectedUsers.Add('uid:zero'); $historyUserCard.Tag.IsLocked=$true; $historyUserCard.Tag.LockedTime=$historyUserTime
Show-HistoryChartSample -State $historyUserCard.Tag -Time $historyUserTime
Assert-Equal @($historyUserCard.Tag.UserPanel.Children | Where-Object { $null -ne $_.Tag -and $null -ne $_.Tag.User -and $_.Tag.User.Identity -eq 'uid:zero' }).Count 1 '历史浮窗保留已选中的零值用户'
$manyUsers = 1..10 | ForEach-Object { [PSCustomObject]@{Identity="uid:many-$_";Uid="many-$_";Name="user$_";RawValue=[double](20-$_);PlotValue=[double](20-$_);Color=(Get-HistoryUserColor "user$_");IsSystem=$false} }
$manyUsers += [PSCustomObject]@{Identity='system';Uid='';Name='系统/未归属';RawValue=99.0;PlotValue=99.0;Color='#9AA39D';IsSystem=$true}
$historyUserCard.Tag.UserPoints=@([PSCustomObject]@{Time=$historyUserTime;Status='ok';Kind='Cpu';TotalMiB=$null;DetailNote='';Users=@($manyUsers)}); $historyUserCard.Tag.SelectedUsers.Clear(); $historyUserCard.Tag.Expanded=$false
Show-HistoryChartSample -State $historyUserCard.Tag -Time $historyUserTime
$collapsedRows=@($historyUserCard.Tag.UserPanel.Children | Where-Object { $null -ne $_.Tag })
Assert-Equal @($collapsedRows | Where-Object { $_.Tag.Other }).Count 1 '历史用户超过八名时显示其他折叠入口'
Assert-Equal $collapsedRows[-1].Tag.User.IsSystem $true '系统未归属高值也不占用前八用户名额并保持末行'
$otherRow=@($collapsedRows | Where-Object { $_.Tag.Other } | Select-Object -First 1)[0]; $otherClick=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $otherClick.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent; $otherRow.RaiseEvent($otherClick)
Assert-Equal $historyUserCard.Tag.Expanded $true '点击其他入口展开全部历史用户'
$expandedOther=@($historyUserCard.Tag.UserPanel.Children | Where-Object { $null -ne $_.Tag -and $_.Tag.Other } | Select-Object -First 1)[0]; $collapseClick=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $collapseClick.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent; $expandedOther.RaiseEvent($collapseClick)
Assert-Equal $historyUserCard.Tag.Expanded $false '展开后再次点击其他入口收起用户列表'
$historyUserCard.Tag.IsLocked=$true; $historyUserCard.Tag.LockedTime=$historyUserTime
$historyEscape=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($historyUserWindow),[Environment]::TickCount,[Windows.Input.Key]::Escape); $historyEscape.RoutedEvent=[Windows.UIElement]::PreviewKeyDownEvent
$historyUserCard.RaiseEvent($historyEscape)
Assert-Equal $historyUserCard.Tag.IsLocked $false 'Esc 解除历史图表固定浮窗'
$historyUserCard.Tag.IsLocked=$true; $historyUserCard.Tag.LockedTime=$historyUserTime
$historyUserCard.Tag.Views[0].IsVisible=$false
Update-HistoryChartUserSeries $historyUserCard.Tag
Assert-Equal @($historyUserCard.Tag.UserLineShapes).Count 0 '隐藏父指标时同步隐藏用户曲线'
Show-HistoryChartSample -State $historyUserCard.Tag -Time $historyUserTime
Assert-Equal $historyUserCard.Tag.UserPanel.Children.Count 0 '隐藏父指标时用户明细面板可清空'
$historyUserWindow.Close()

$collectorSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Collect-Metrics.ps1') -Raw
$mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ServerPulse.ps1') -Raw
$historySource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.History.ps1') -Raw
$launcherSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start Server Pulse.vbs') -Raw
$hostSourcePath = Join-Path $PSScriptRoot '..\src\ServerPulse.Host.cs'
$hostExecutablePath = Join-Path $PSScriptRoot '..\ServerPulse.exe'
Assert-Equal ([bool]($collectorSource -notmatch '\bStart-Job\b')) $true '长期采集器不得为每台服务器创建 PowerShell 进程'
Assert-Equal ([bool]($collectorSource -match 'CreateRunspacePool')) $true '长期采集器使用 Runspace Pool 并行采集'
Assert-Equal ([bool]($collectorSource -match '\[Console\]::In\.ReadLine\(\)')) $true '长期采集器以逐行协议复用标准输入'
Assert-Equal ([bool]($collectorSource -match 'Invoke-ServerPulsePersistentCollection')) $true 'Worker 使用每服务器长期 SSH 会话而非逐轮启动 ssh.exe'
Assert-Equal ([bool]($mainSource -match '\$info\.Arguments=.*?-Worker')) $true '主窗口启动长期采集器而非逐轮采集进程'
Assert-Equal ([bool]($mainSource -match '\$historyJsonWriterCommand = Get-Command Write-ServerPulseJsonAtomic')) $true '历史设置回调预先捕获 JSON 写入函数'
Assert-Equal ([bool]($mainSource -match '& \$historyJsonWriterCommand -Path \$script:settingsPath')) $true '历史设置回调使用已捕获的 JSON 写入函数'
Assert-Equal ([bool]($mainSource -match '\$historyAskPassCommand = Get-Command Ensure-ServerPulseAskPassHelper')) $true '历史目录切换回调预先捕获 SSH 辅助函数'
Assert-Equal ([bool]($mainSource -match '& \$historyAskPassCommand -Directory')) $true '历史目录切换回调使用已捕获的 SSH 辅助函数'
Assert-Equal ([bool]($mainSource -match '\$historyContextSetterCommand = Get-Command Set-HistoryStorageContextValue')) $true '历史目录切换回调预先捕获上下文属性函数'
Assert-Equal ([bool]($mainSource -match '\$historyStorageContext = \[PSCustomObject\]@\{')) $true '历史上下文先完成对象初始化'
Assert-Equal ([bool]($mainSource -match '\$historyStorageContext\.ApplyRoot\s*=')) $true '历史目录切换回调在对象初始化后注册'
Assert-Equal ([bool]($mainSource -match '& \$historyContextSetterCommand -Context \$historyStorageContext')) $true '历史目录切换回调捕获稳定上下文对象'
Assert-Equal ([bool]($mainSource -notmatch 'ApplyRoot=.*-Context \$script:historyStorageContext')) $true '历史目录切换回调不捕获尚未赋值的脚本上下文'
Assert-Equal ([bool]($historySource -match '<Window[^>]+xmlns:x="http://schemas\.microsoft\.com/winfx/2006/xaml"[^>]+Width="540"')) $true '首次记录配置弹窗声明 WPF x 命名空间'
Assert-Equal ([bool]($historySource -match '<Window[^>]+xmlns:x="http://schemas\.microsoft\.com/winfx/2006/xaml"[^>]+Width="450"')) $true '清理确认弹窗声明 WPF x 命名空间'
Assert-Equal ([bool]($historySource -match '<Window[^>]+xmlns:x="http://schemas\.microsoft\.com/winfx/2006/xaml"[^>]+Width="470"')) $true '迁移冲突弹窗声明 WPF x 命名空间'
Assert-Equal ([bool]($historySource -match 'Get-Command Get-ServerPulseText')) $true '历史模块可自补载本地化函数'
Assert-Equal ([bool]($historySource -match 'function Get-HistorySetupText')) $true '首次记录配置错误提示具有本地化兜底'
Assert-Equal ([bool]($historySource -match 'function Set-HistoryStorageContextValue')) $true '历史上下文支持补齐缺失属性'
Assert-Equal ([bool]($historySource -match 'function Ensure-HistoryStorageContext')) $true '记录窗口初始化时规范化历史上下文'
Assert-Equal ([bool]($historySource -notmatch '\$Context\.ActiveRoot=')) $true '历史上下文不直接写入可能缺失的属性'
Assert-Equal ([bool]($historySource -match '\$setupInvalidPathTemplate')) $true '首次记录配置点击事件捕获错误文案'
Assert-Equal ([bool]($historySource -notmatch "Save'.*Get-HistorySetupText")) $true '首次记录配置点击事件不依赖动态本地化函数'
Assert-Equal ([bool]($historySource -match 'Get-Command ConvertTo-ServerPulseRetentionSettings')) $true '历史模块可自补载存储策略函数'
Assert-Equal ([bool]($historySource -match '\$applyStorageCommand = Get-Command Invoke-HistoryStorageContextApply')) $true '首次记录配置预先捕获存储应用函数'
Assert-Equal ([bool]($historySource -match '& \$convertRetentionCommand -Days')) $true '首次记录配置点击事件使用已捕获的保留策略函数'
Assert-Equal ([bool]($historySource -match '& \$testDataRootCommand -Path')) $true '首次记录配置点击事件使用已捕获的目录校验函数'
Assert-Equal ([bool]($historySource -match '& \$applyStorageCommand -Context \$Context -TargetRoot \$path\.Path')) $true '首次记录配置保存成功后才关闭弹窗'
Assert-Equal ([bool]($historySource -match '-CleanupPaused:\(\[bool\]\$Retention\.CleanupPaused\)')) $true '应用历史设置时布尔参数显式加括号'
Assert-Equal ([bool]($historySource -notmatch '-CleanupPaused:\[bool\]\$Retention\.CleanupPaused')) $true '应用历史设置不把布尔转换表达式当成字符串'
Assert-Equal ([bool]($launcherSource -match 'ServerPulse\.exe')) $true '兼容启动器优先启动 EXE 宿主'
Assert-Equal (Test-Path -LiteralPath $hostSourcePath) $true '仓库包含可重复构建的 EXE 宿主源码'
Assert-Equal (Test-Path -LiteralPath $hostExecutablePath) $true '仓库包含 ServerPulse.exe 宿主'
if (Test-Path -LiteralPath $hostSourcePath) {
    $hostSource = Get-Content -LiteralPath $hostSourcePath -Raw
    Assert-Equal ([bool]($hostSource -match 'SetCurrentProcessExplicitAppUserModelID')) $true 'EXE 宿主设置固定 AppUserModelID'
    Assert-Equal ([bool]($hostSource -match 'CreateJobObject')) $true 'EXE 宿主创建 Windows Job Object'
    Assert-Equal ([bool]($hostSource -match 'CreateJobObject\(IntPtr\.Zero, null\)')) $true '每个 EXE 实例使用独立未命名 Job Object'
    Assert-Equal ([bool]($hostSource -match 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE')) $true 'Job Object 在宿主退出时清理全部后代进程'
    Assert-Equal ([bool]($hostSource -match 'RunspaceFactory')) $true 'EXE 宿主在进程内运行 PowerShell WPF 脚本'
}
if (Test-Path -LiteralPath $hostExecutablePath) {
    $hostVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($hostExecutablePath)
    Assert-Equal $hostVersion.ProductName 'Server Pulse' 'EXE 产品名称统一为 Server Pulse'
    $hostIcon = [Drawing.Icon]::ExtractAssociatedIcon($hostExecutablePath)
    Assert-Equal ($null -ne $hostIcon) $true 'EXE 嵌入 Server Pulse 应用图标'
    if ($null -ne $hostIcon) { $hostIcon.Dispose() }
}

$workerInfo=[Diagnostics.ProcessStartInfo]::new();$workerInfo.FileName='powershell.exe';$workerInfo.Arguments="-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot '..\src\Collect-Metrics.ps1')`" -ConfigPath `"$(Join-Path $PSScriptRoot '..\config\servers.json')`" -Worker";$workerInfo.UseShellExecute=$false;$workerInfo.CreateNoWindow=$true;$workerInfo.RedirectStandardInput=$true;$workerInfo.RedirectStandardOutput=$true;$workerInfo.RedirectStandardError=$true
$workerProcess=$null
try {
    $workerProcess=[Diagnostics.Process]::Start($workerInfo)
    $emptyRequest=[PSCustomObject]@{SshTimeoutMs=1000;AskPassPath='';Servers=@()}|ConvertTo-Json -Compress
    $workerProcess.StandardInput.WriteLine($emptyRequest);$workerProcess.StandardInput.Flush();$workerFirst=$workerProcess.StandardOutput.ReadLine()|ConvertFrom-Json
    $workerProcess.StandardInput.WriteLine($emptyRequest);$workerProcess.StandardInput.Flush();$workerSecond=$workerProcess.StandardOutput.ReadLine()|ConvertFrom-Json
    Assert-Equal $workerProcess.HasExited $false '同一长期采集器连续处理两轮请求而不退出'
    Assert-Equal @($workerFirst.Servers).Count 0 '长期采集器返回第一轮快照'
    Assert-Equal @($workerSecond.Servers).Count 0 '长期采集器返回第二轮快照'
    Assert-Equal ([bool]($workerFirst.PSObject.Properties.Name -contains 'WorkerError')) $false '兼容旧请求时长期采集器不返回内部错误'
} finally {
    if($null-ne$workerProcess){try{$workerProcess.StandardInput.Close()}catch{};if(-not$workerProcess.WaitForExit(3000)){$workerProcess.Kill()};$workerProcess.Dispose()}
}

$retry=New-ServerPulseRetryState -CircuitThreshold 6
$retryOne=Register-ServerPulseConnectionFailure -State $retry -Now ([datetime]'2026-08-13T00:00:00Z') -JitterFactor 1.0
Assert-Equal $retryOne.DelaySeconds 5 '首次断线退避 5 秒'
Assert-Equal $retryOne.CircuitOpen $false '首次断线不熔断'
$retryTwo=Register-ServerPulseConnectionFailure -State $retry -Now ([datetime]'2026-08-13T00:00:05Z') -JitterFactor 1.0
$retryThree=Register-ServerPulseConnectionFailure -State $retry -Now ([datetime]'2026-08-13T00:00:20Z') -JitterFactor 1.0
$retryFour=Register-ServerPulseConnectionFailure -State $retry -Now ([datetime]'2026-08-13T00:00:50Z') -JitterFactor 1.0
Assert-Equal (($retryTwo.DelaySeconds,$retryThree.DelaySeconds,$retryFour.DelaySeconds)-join ',') '15,30,60' '连续断线按 15、30、60 秒指数退避'
$retryFive=Register-ServerPulseConnectionFailure -State $retry -Now ([datetime]'2026-08-13T00:01:50Z') -JitterFactor 1.0
Assert-Equal $retryFive.DelaySeconds 300 '第五次断线退避 5 分钟'
$retrySix=Register-ServerPulseConnectionFailure -State $retry -Now ([datetime]'2026-08-13T00:06:50Z') -JitterFactor 1.0
Assert-Equal $retrySix.CircuitOpen $true '退避仍连续失败后熔断暂停'
Assert-Equal $retrySix.NextRetryAt $null '熔断后停止自动重试'
Reset-ServerPulseRetryState $retry
Assert-Equal "$($retry.FailureCount):$($retry.CircuitOpen):$($null-eq$retry.NextRetryAt)" '0:False:True' '手动重新检测可清除熔断和退避'

$persistentCountFile=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-persistent-count-'+[guid]::NewGuid().ToString('N'))
$persistentWorker=$null
try{
    $persistentInfo=[Diagnostics.ProcessStartInfo]::new();$persistentInfo.FileName='powershell.exe';$persistentInfo.Arguments="-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot '..\src\Collect-Metrics.ps1')`" -ConfigPath `"$(Join-Path $PSScriptRoot '..\config\servers.json')`" -Worker";$persistentInfo.UseShellExecute=$false;$persistentInfo.CreateNoWindow=$true;$persistentInfo.RedirectStandardInput=$true;$persistentInfo.RedirectStandardOutput=$true;$persistentInfo.RedirectStandardError=$true
    $persistentInfo.EnvironmentVariables['SERVERPULSE_MOCK_PERSISTENT']='1';$persistentInfo.EnvironmentVariables['SERVERPULSE_MOCK_BATCH']='ok';$persistentInfo.EnvironmentVariables['SERVERPULSE_MOCK_COUNT_FILE']=$persistentCountFile
    $persistentWorker=[Diagnostics.Process]::Start($persistentInfo)
    $persistentServer=[PSCustomObject]@{Id='persistent';Label='Persistent';Source='manual';SshTarget='mock';HostName='mock';Port=22;User='tester';AuthMode='passwordless';Password=$null}
    $persistentRequest=[PSCustomObject]@{SshTimeoutMs=2000;PollIntervalSeconds=1;AskPassPath='';SshPath=(Join-Path $PSScriptRoot 'Mock-Ssh.cmd');Servers=@($persistentServer);ForceReconnect=@()}|ConvertTo-Json -Depth 5 -Compress
    $persistentWorker.StandardInput.WriteLine($persistentRequest);$persistentWorker.StandardInput.Flush();$persistentFirst=$persistentWorker.StandardOutput.ReadLine()|ConvertFrom-Json
    Start-Sleep -Milliseconds 350
    $persistentWorker.StandardInput.WriteLine($persistentRequest);$persistentWorker.StandardInput.Flush();$persistentSecond=$persistentWorker.StandardOutput.ReadLine()|ConvertFrom-Json
    $persistentWorker.StandardInput.WriteLine($persistentRequest);$persistentWorker.StandardInput.Flush();$persistentThird=$persistentWorker.StandardOutput.ReadLine()|ConvertFrom-Json
    Assert-Equal $persistentSecond.Servers[0].Status 'online' '长期 SSH 会话读取远端完整采样帧'
    Assert-Equal $persistentThird.Servers[0].Status 'online' '后续刷新复用同一会话的最新采样'
    Assert-Equal @([IO.File]::ReadAllLines($persistentCountFile)).Count 1 '多轮刷新只启动一次 ssh.exe'
    $forcedRequest=[PSCustomObject]@{SshTimeoutMs=2000;PollIntervalSeconds=1;AskPassPath='';SshPath=(Join-Path $PSScriptRoot 'Mock-Ssh.cmd');Servers=@($persistentServer);ForceReconnect=@('persistent')}|ConvertTo-Json -Depth 5 -Compress
    $persistentWorker.StandardInput.WriteLine($forcedRequest);$persistentWorker.StandardInput.Flush();[void]($persistentWorker.StandardOutput.ReadLine());Start-Sleep -Milliseconds 150
    Assert-Equal @([IO.File]::ReadAllLines($persistentCountFile)).Count 2 '手动重新检测立即终止旧会话并建立新 SSH 会话'
}finally{
    if($null-ne$persistentWorker){try{$persistentWorker.StandardInput.Close()}catch{};if(-not$persistentWorker.WaitForExit(3000)){$persistentWorker.Kill()};$persistentWorker.Dispose()}
    if(Test-Path -LiteralPath $persistentCountFile){Remove-Item -LiteralPath $persistentCountFile -Force}
}

$passwordCountFile=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-password-count-'+[guid]::NewGuid().ToString('N'))
$passwordWorker=$null;$passwordAskPassDirectory=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-password-askpass-'+[guid]::NewGuid().ToString('N'))
try{
    $passwordAskPass=Ensure-ServerPulseAskPassHelper $passwordAskPassDirectory
    $passwordInfo=[Diagnostics.ProcessStartInfo]::new();$passwordInfo.FileName='powershell.exe';$passwordInfo.Arguments="-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot '..\src\Collect-Metrics.ps1')`" -ConfigPath `"$(Join-Path $PSScriptRoot '..\config\servers.json')`" -Worker";$passwordInfo.UseShellExecute=$false;$passwordInfo.CreateNoWindow=$true;$passwordInfo.RedirectStandardInput=$true;$passwordInfo.RedirectStandardOutput=$true;$passwordInfo.RedirectStandardError=$true
    $passwordInfo.EnvironmentVariables['SERVERPULSE_MOCK_PERSISTENT']='password';$passwordInfo.EnvironmentVariables['SERVERPULSE_MOCK_COUNT_FILE']=$passwordCountFile
    $passwordWorker=[Diagnostics.Process]::Start($passwordInfo)
    $passwordServer=[PSCustomObject]@{Id='password-persistent';Label='Password';Source='manual';SshTarget='mock';HostName='mock';Port=22;User='tester';AuthMode='password';Password='mock-password'}
    $passwordRequest=[PSCustomObject]@{SshTimeoutMs=4000;PollIntervalSeconds=1;AskPassPath=$passwordAskPass;SshPath=(Join-Path $PSScriptRoot 'Mock-Ssh.cmd');Servers=@($passwordServer);ForceReconnect=@()}|ConvertTo-Json -Depth 5 -Compress
    $passwordWorker.StandardInput.WriteLine($passwordRequest);$passwordWorker.StandardInput.Flush();[void]($passwordWorker.StandardOutput.ReadLine());Start-Sleep -Milliseconds 350
    $passwordWorker.StandardInput.WriteLine($passwordRequest);$passwordWorker.StandardInput.Flush();$passwordSnapshot=$passwordWorker.StandardOutput.ReadLine()|ConvertFrom-Json
    Assert-Equal $passwordSnapshot.Servers[0].Status 'online' '密码认证同样进入长期 SSH 会话'
    Assert-Equal @([IO.File]::ReadAllLines($passwordCountFile)).Count 1 '密码模式多轮采集也只启动一个 ssh.exe'
}finally{
    if($null-ne$passwordWorker){try{$passwordWorker.StandardInput.Close()}catch{};if(-not$passwordWorker.WaitForExit(3000)){$passwordWorker.Kill()};$passwordWorker.Dispose()}
    if(Test-Path -LiteralPath $passwordCountFile){Remove-Item -LiteralPath $passwordCountFile -Force}
    if(Test-Path -LiteralPath $passwordAskPassDirectory){Get-ChildItem -LiteralPath $passwordAskPassDirectory -File|Remove-Item -Force;Remove-Item -LiteralPath $passwordAskPassDirectory -Force}
}

$failureCountFile=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-failure-count-'+[guid]::NewGuid().ToString('N'))
$failureWorker=$null
try{
    $failureInfo=[Diagnostics.ProcessStartInfo]::new();$failureInfo.FileName='powershell.exe';$failureInfo.Arguments="-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot '..\src\Collect-Metrics.ps1')`" -ConfigPath `"$(Join-Path $PSScriptRoot '..\config\servers.json')`" -Worker";$failureInfo.UseShellExecute=$false;$failureInfo.CreateNoWindow=$true;$failureInfo.RedirectStandardInput=$true;$failureInfo.RedirectStandardOutput=$true;$failureInfo.RedirectStandardError=$true
    $failureInfo.EnvironmentVariables['SERVERPULSE_MOCK_PERSISTENT']='fail';$failureInfo.EnvironmentVariables['SERVERPULSE_MOCK_COUNT_FILE']=$failureCountFile
    $failureWorker=[Diagnostics.Process]::Start($failureInfo)
    $failureServer=[PSCustomObject]@{Id='failure';Label='Failure';Source='manual';SshTarget='mock';HostName='mock';Port=22;User='tester';AuthMode='passwordless';Password=$null}
    $failureRequest=[PSCustomObject]@{SshTimeoutMs=2000;PollIntervalSeconds=1;AskPassPath='';SshPath=(Join-Path $PSScriptRoot 'Mock-Ssh.cmd');Servers=@($failureServer);ForceReconnect=@()}|ConvertTo-Json -Depth 5 -Compress
    $failureWorker.StandardInput.WriteLine($failureRequest);$failureWorker.StandardInput.Flush();[void]($failureWorker.StandardOutput.ReadLine())
    Start-Sleep -Milliseconds 250
    $failureWorker.StandardInput.WriteLine($failureRequest);$failureWorker.StandardInput.Flush();$failedSecond=$failureWorker.StandardOutput.ReadLine()|ConvertFrom-Json
    $failureWorker.StandardInput.WriteLine($failureRequest);$failureWorker.StandardInput.Flush();$failedThird=$failureWorker.StandardOutput.ReadLine()|ConvertFrom-Json
    Assert-Equal $failedSecond.Servers[0].Status 'retry_wait' '网络断线进入退避等待而不是每轮重连'
    Assert-Equal ([string]::IsNullOrWhiteSpace([string]$failedSecond.Servers[0].RetryAt)) $false '退避状态返回下一次重试时间'
    Assert-Equal @([IO.File]::ReadAllLines($failureCountFile)).Count 1 '退避到期前不再启动新的 ssh.exe'
}finally{
    if($null-ne$failureWorker){try{$failureWorker.StandardInput.Close()}catch{};if(-not$failureWorker.WaitForExit(3000)){$failureWorker.Kill()};$failureWorker.Dispose()}
    if(Test-Path -LiteralPath $failureCountFile){Remove-Item -LiteralPath $failureCountFile -Force}
}

$retentionValid=ConvertTo-ServerPulseRetentionSettings -Days 1 -LastRetentionDays 7
Assert-Equal $retentionValid.IsValid $true '历史保留最小值 1 天有效'
Assert-Equal (ConvertTo-ServerPulseRetentionSettings -Days 3650).IsValid $true '历史保留最大值 3650 天有效'
Assert-Equal (ConvertTo-ServerPulseRetentionSettings -Days 0).IsValid $false '历史保留拒绝 0 天'
Assert-Equal (ConvertTo-ServerPulseRetentionSettings -Days 3651).IsValid $false '历史保留拒绝超过 3650 天'
$neverRetention=ConvertTo-ServerPulseRetentionSettings -Days $null -NeverCleanup $true -LastRetentionDays 42
Assert-Equal "$($neverRetention.NeverCleanup):$($neverRetention.RetentionDays)" 'True:42' '永不清理保留上一次有效天数'
$missingHistoryContext=[pscustomobject]@{}
Set-HistoryStorageContextValue -Context $missingHistoryContext -Name 'ActiveRoot' -Value 'C:\ServerPulse'
Assert-Equal $missingHistoryContext.ActiveRoot 'C:\ServerPulse' '历史上下文缺少 ActiveRoot 时可安全补齐'
$historyContextMap=@{}
Set-HistoryStorageContextValue -Context $historyContextMap -Name 'ActiveRoot' -Value 'C:\ServerPulse'
Assert-Equal $historyContextMap['ActiveRoot'] 'C:\ServerPulse' '哈希表历史上下文可安全写入'
$contextRecorderRoot=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-context-'+[guid]::NewGuid().ToString('N'))
try {
    $contextRecorder=New-ServerPulseHistoryRecorder -Directory (Join-Path $contextRecorderRoot 'history') -RetentionDays 7 -StorageConfigured $true
    $normalizedContext=Ensure-HistoryStorageContext -Context $null -Recorder $contextRecorder
    Assert-Equal ([string]$normalizedContext.ActiveRoot) ([string]$contextRecorderRoot) '空历史上下文可自动建立活动目录'
    Assert-Equal ([bool]$normalizedContext.Settings.HistoryStorageConfigured) $true '空历史上下文自动标记存储已配置'
    $normalizedMap=Ensure-HistoryStorageContext -Context @{} -Recorder $contextRecorder
    Assert-Equal ([string]$normalizedMap['ActiveRoot']) ([string]$contextRecorderRoot) '哈希表历史上下文可自动规范化'
    $incompleteContext=[pscustomobject]@{Recorder=$contextRecorder;Settings=[pscustomobject]@{HistoryStorageConfigured=$true}}
    $incompleteRetention=ConvertTo-ServerPulseRetentionSettings -Days 7 -LastRetentionDays 7 -Configured $true
    $incompleteApply=Invoke-HistoryStorageContextApply -Context $incompleteContext -TargetRoot $contextRecorderRoot -Retention $incompleteRetention
    Assert-Equal $incompleteApply.Applied $true '缺少活动目录字段的上下文仍可应用记录设置'
    Assert-Equal ([string]$incompleteContext.ActiveRoot) ([string]$contextRecorderRoot) '应用记录设置后补齐活动目录字段'
    $capturedContext=$incompleteContext
    $contextCallback={param($root);[void](Set-HistoryStorageContextValue -Context $capturedContext -Name 'ActiveRoot' -Value $root)}.GetNewClosure()
    $capturedContext=$null
    & $contextCallback $contextRecorderRoot
    Assert-Equal ([string]$incompleteContext.ActiveRoot) ([string]$contextRecorderRoot) '历史目录回调闭包持有稳定上下文而非空脚本变量'
} finally { if(Test-Path -LiteralPath $contextRecorderRoot){Remove-Item -LiteralPath $contextRecorderRoot -Recurse -Force -ErrorAction SilentlyContinue} }
$cutoff=Get-ServerPulseRetentionCutoffDate -Now ([datetime]'2026-08-14T12:34:00') -RetentionDays 7
Assert-Equal $cutoff.ToString('yyyy-MM-dd') '2026-08-08' '保留天数按自然日计算截止日期'
Assert-Equal (Get-ServerPulseCleanupDecision -PreviousDays 30 -NewDays 7) 'prompt' '缩短保留时长需要清理确认'
Assert-Equal (Get-ServerPulseCleanupDecision -PreviousDays 30 -NewDays 7 -NewNeverCleanup $true) 'none' '永不清理跳过清理确认'
$retentionApplyRoot=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-retention-apply-'+[guid]::NewGuid().ToString('N'))
try {
    $retentionApplyRecorder=New-ServerPulseHistoryRecorder -Directory (Join-Path $retentionApplyRoot 'history') -RetentionDays 7 -StorageConfigured $true
    $retentionApplied=Set-ServerPulseHistoryRetention -Recorder $retentionApplyRecorder -Days 7 -NeverCleanup:$false -CleanupPaused:([bool]$true) -StorageConfigured:$true
    Assert-Equal $retentionApplied.CleanupPaused $true '应用记录设置时清理暂停布尔参数可正常绑定'
} finally { if(Test-Path -LiteralPath $retentionApplyRoot){Remove-Item -LiteralPath $retentionApplyRoot -Recurse -Force -ErrorAction SilentlyContinue} }

$storageRoot=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-storage-test-'+[guid]::NewGuid().ToString('N'));$storageSource=Join-Path $storageRoot 'source';$storageTarget=Join-Path $storageRoot 'target'
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $storageSource 'history') -Force)
    [IO.File]::WriteAllText((Join-Path $storageSource 'settings.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $storageSource 'history\2026-01-01.v2.jsonl'),'sample`n')
    $pointerPath=Join-Path $storageRoot 'ServerPulse.location.json'
    $pointer=New-ServerPulseLocationPointer -PreferredDataRootPath $storageSource
    Write-ServerPulseLocationPointer -Path $pointerPath -Pointer $pointer
    Assert-Equal (Read-ServerPulseLocationPointer -Path $pointerPath).PreferredDataRootPath $storageSource 'location 指针可原子写入并读取'
    $resolvedPreferred=Resolve-ServerPulseDataRoot -DefaultRoot $storageSource -PointerPath $pointerPath -CreateDefault
    Assert-Equal "$($resolvedPreferred.IsFallback):$($resolvedPreferred.ActiveRoot -eq [IO.Path]::GetFullPath($storageSource))" 'False:True' '有效 location 指针可解析首选目录'
    [IO.File]::WriteAllText($pointerPath,'{ broken')
    Assert-Equal (Read-ServerPulseLocationPointer -Path $pointerPath).Invalid $true '损坏的 location 指针安全标记无效'
    Write-ServerPulseLocationPointer -Path $pointerPath -Pointer $pointer
    $missingPreferred=Join-Path $storageRoot 'missing-preferred';Write-ServerPulseLocationPointer -Path $pointerPath -Pointer (New-ServerPulseLocationPointer -PreferredDataRootPath $missingPreferred)
    $resolvedFallback=Resolve-ServerPulseDataRoot -DefaultRoot $storageSource -PointerPath $pointerPath -CreateDefault
    Assert-Equal "$($resolvedFallback.IsFallback):$($resolvedFallback.ActiveRoot -eq [IO.Path]::GetFullPath($storageSource))" 'True:True' '首选目录不可用时只回退默认目录'
    Write-ServerPulseLocationPointer -Path $pointerPath -Pointer $pointer
    $envPath='%TEMP%\ServerPulse-storage-env-test'
    $envResolved=Test-ServerPulseDataRootPath -Path $envPath -Create
    Assert-Equal $envResolved.IsValid $true '数据目录支持环境变量并自动创建'
    Assert-Equal (Test-ServerPulseDataRootPath -Path 'relative\ServerPulse').ErrorCode 'relative' '数据目录拒绝相对路径'
    Assert-Equal (Test-ServerPulseDataRootPath -Path '\\server\share').ErrorCode 'unc' '数据目录拒绝 UNC 路径'
    $storageBomBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\src\ServerPulse.Storage.ps1'))
    Assert-Equal ("{0},{1},{2}" -f $storageBomBytes[0],$storageBomBytes[1],$storageBomBytes[2]) '239,187,191' '存储模块保持 UTF-8 BOM'
    $migration=Invoke-ServerPulseDataRootMigration -SourceRoot $storageSource -TargetRoot $storageTarget -ConflictMode Cancel
    Assert-Equal $migration.Status 'Migrated' '数据根目录迁移成功'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $storageTarget 'history\2026-01-01.v2.jsonl')) $true '迁移包含历史 JSONL'
    Assert-Equal (Test-Path -LiteralPath $migration.BackupPath) $true '迁移成功后保留源目录备份'
    $rec=New-ServerPulseHistoryRecorder -Directory (Join-Path $storageTarget 'history') -RetentionDays 1 -StorageConfigured $true
    $oldFile=Join-Path $rec.Directory '2020-01-01.v2.jsonl';[IO.File]::WriteAllText($oldFile,'old`n')
    $rec.CleanupPaused=$true;$paused=Remove-ExpiredServerPulseHistory -Recorder $rec -Now ([datetime]'2026-08-14')
    Assert-Equal $paused.Reason 'paused' '不清理选项暂停自动删除'
    $rec.CleanupPaused=$false;$cleaned=Remove-ExpiredServerPulseHistory -Recorder $rec -Now ([datetime]'2026-08-14')
    Assert-Equal $cleaned.Removed 2 '恢复自动清理后删除过期 JSONL'
} finally {
    if(Test-Path -LiteralPath $storageRoot){Remove-Item -LiteralPath $storageRoot -Recurse -Force -ErrorAction SilentlyContinue}
    $envTest=Join-Path $env:TEMP 'ServerPulse-storage-env-test';if(Test-Path -LiteralPath $envTest){Remove-Item -LiteralPath $envTest -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- server-side agent module ---

$agentSample = Get-ServerPulseSampleScript
Assert-Equal ([bool]($agentSample -match 'GPU_USER_STATUS')) $true '共享采样脚本包含 GPU 用户状态'
Assert-Equal ([bool]($agentSample -match "`r")) $false '采样脚本保持 LF 行尾（远端 sh 拒绝 CRLF）'
# LF normalization must not depend on ServerPulse.Core.ps1 being loaded:
# the Manage-window and startup background runspaces dot-source the agent
# modules directly.  Start-Job gives the same isolated runspace, and it is
# already used by the authentication-batch tests in this suite.
$guardJob=Start-Job -ScriptBlock {
    param($AgentPath,$SshPath,$SamplePath)
    $ErrorActionPreference='Stop'
    . $AgentPath
    . $SshPath
    . $SamplePath
    $sample=Get-ServerPulseSampleScript
    $script=New-ServerPulseAgentScript -ServerId 'guard-1' -Label 'L' -ServerHost 'h' -SampleScript $sample
    [PSCustomObject]@{ SampleCrlf=([regex]::Matches($sample,"`r`n")).Count; AgentCrlf=([regex]::Matches($script,"`r`n")).Count }
} -ArgumentList (Join-Path $PSScriptRoot '..\src\ServerPulse.Agent.ps1'),(Join-Path $PSScriptRoot '..\src\ServerPulse.Ssh.ps1'),(Join-Path $PSScriptRoot '..\src\ServerPulse.Sample.ps1')
try {
    $guardResult=@(Receive-Job -Job $guardJob -Wait)
    Assert-Equal $guardResult.Count 1 '独立作业可加载代理模块生成脚本'
    Assert-Equal $guardResult[0].SampleCrlf 0 '无 Core 的作业采样脚本仍为 LF'
    Assert-Equal $guardResult[0].AgentCrlf 0 '无 Core 的作业代理脚本仍为 LF'
} finally { Remove-Job -Job $guardJob -Force -ErrorAction SilentlyContinue }
$serverManagerSourceText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.ServerManager.ps1') -Raw
Assert-Equal ([bool]($serverManagerSourceText -match '\. \$CoreModulePath')) $true '管理窗口代理后台任务显式加载 Core 模块'
$mainSourceText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ServerPulse.ps1') -Raw
Assert-Equal ([bool]($mainSourceText -match '\. \$CoreModulePath')) $true '启动后台任务显式加载 Core 模块'
$agentLoopScript = New-ServerPulseRemoteLoopScript -SampleScript $agentSample -IntervalSeconds 5
Assert-Equal ([bool]($agentLoopScript -match "`r")) $false '长期会话循环脚本保持 LF 行尾'
$agentScript = New-ServerPulseAgentScript -ServerId 'agent-test-1' -Label 'Label "X"' -ServerHost 'host1' -SampleScript $agentSample -IntervalSeconds 7 -RetentionDays 40
Assert-Equal ([bool]($agentScript -match "`r")) $false '代理脚本保持 LF 行尾'
Assert-Equal ([bool]($agentScript -match 'sp_interval=7')) $true '代理脚本注入采样间隔'
Assert-Equal ([bool]($agentScript -match 'sp_retention_days=40')) $true '代理脚本注入保留天数'
Assert-Equal ([bool]($agentScript -match 'Label  X')) $true '代理脚本消毒引号标签'
Assert-Equal ([bool]($agentScript -match '__SP_SAMPLE__')) $true '代理脚本包含采样标记'
Assert-Equal ([bool]($agentScript -match 'trap .sp_finish. TERM INT')) $true '代理脚本安装退出清理陷阱'
$agentAwkStart=$agentScript.IndexOf('awk -v sp_minute')
$agentAwkOpen=$agentScript.IndexOf([char]39,$agentAwkStart)
$agentAwkClose=$agentScript.IndexOf("' `"`$sp_state",$agentAwkStart)
$agentAwkBody=$agentScript.Substring($agentAwkOpen+1,$agentAwkClose-$agentAwkOpen-1)
Assert-Equal ([bool]($agentAwkBody.Contains([char]39))) $false '代理聚合 awk 不含单引号'
$agentConfig=New-ServerPulseAgentConfigText -ServerId 'agent-test-1' -Label 'L' -ServerHost 'h' -IntervalSeconds 7 -RetentionDays 40
Assert-Equal ([bool]($agentConfig -match "interval=7`n")) $true '代理配置包含采样间隔'
Assert-Equal ([bool]($agentConfig -match "retention_days=40`n")) $true '代理配置包含保留天数'
Assert-Equal (Get-ServerPulseAgentFolder) '.serverpulse' '代理目录固定为隐藏目录'
Assert-Equal ([bool]((Get-ServerPulseAgentStatusScript) -match "`r")) $false '代理状态脚本保持 LF 行尾'
Assert-Equal ([bool]((Get-ServerPulseAgentStopScript) -match "`r")) $false '代理停止脚本保持 LF 行尾'
Assert-Equal ([bool]((Get-ServerPulseAgentMergePullScript -CursorUtc $null) -match "`r")) $false '代理拉取脚本保持 LF 行尾'

# status detection and control via a mocked SSH connection
# The mock is installed here, after all earlier tests that use the real one;
# the remaining agent tests are the last section of the suite.
function Invoke-ServerPulseServerConnection {
    param($Server,[string]$Script,[string]$AuthMode='auto',[string]$Password,[int]$TimeoutMs=8000,[string]$AskPassPath,[string]$SshPath='ssh.exe')
    if ($Script -match 'SP_AGENT_INSTALLED=1') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output=$script:ServerPulseTestStatusOutput;Error=$null} }
    if ($Script -match 'rm -rf "\$sp"') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output='SP_AGENT_RESULT=uninstalled';Error=$null} }
    if ($Script -match 'SERVERPULSE_AGENT_EOF') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output='SP_AGENT_RESULT=started';Error=$null} }
    if ($Script -match 'kill -TERM') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output='SP_AGENT_RESULT=stopped';Error=$null} }
    if ($Script -match 'SP_AGENT_RUNNING=') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output="SP_AGENT_RESULT=config_updated`nSP_AGENT_RUNNING=1";Error=$null} }
    if ($Script -match 'SP_AGENT_CLEANED=') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output="SP_AGENT_CLEANED=2026-08-10`n__SP_DONE__";Error=$null} }
    if ($Script -match '__SP_FILE__') { return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output=$script:ServerPulseTestPullOutput;Error=$null} }
    return [PSCustomObject]@{Status='offline';AuthMode='passwordless';Output='';Error='mock connection not matched'}
}
$mockAgentServer=[PSCustomObject]@{Id='agent-test-1';Label='Agent';Source='manual';SshTarget='mock-agent';HostName='mock-agent';Port=22;User='alice';Identity='alice@mock-agent:22'}
$script:ServerPulseTestStatusOutput="SP_AGENT_INSTALLED=1`nSP_AGENT_STATUS=running`nSP_AGENT_PID=1234`nSP_AGENT_HB_AGE=5"
$agentStatus=Get-ServerPulseAgentStatus -Server $mockAgentServer -IntervalSeconds 5
Assert-Equal $agentStatus.Status 'running' '代理状态检测识别运行中'
$script:ServerPulseTestStatusOutput="SP_AGENT_INSTALLED=1`nSP_AGENT_STATUS=running`nSP_AGENT_PID=1234`nSP_AGENT_HB_AGE=200"
$agentStatus=Get-ServerPulseAgentStatus -Server $mockAgentServer -IntervalSeconds 5
Assert-Equal $agentStatus.Status 'stale' '心跳过期识别为卡顿'
$script:ServerPulseTestStatusOutput="SP_AGENT_INSTALLED=0`nSP_AGENT_STATUS=stopped"
$agentStatus=Get-ServerPulseAgentStatus -Server $mockAgentServer -IntervalSeconds 5
Assert-Equal $agentStatus.Status 'not_installed' '未注入状态识别'
$script:ServerPulseTestStatusOutput="SP_AGENT_INSTALLED=1`nSP_AGENT_STATUS=stopped"
$agentStatus=Get-ServerPulseAgentStatus -Server $mockAgentServer -IntervalSeconds 5
Assert-Equal $agentStatus.Status 'stopped' '已停止状态识别'
$agentControl=Invoke-ServerPulseAgentControl -Server $mockAgentServer -Action inject -IntervalSeconds 7 -RetentionDays 40
Assert-Equal "$($agentControl.Status):$($agentControl.Result)" 'ok:started' '代理注入返回已启动'
$agentControl=Invoke-ServerPulseAgentControl -Server $mockAgentServer -Action stop
Assert-Equal "$($agentControl.Status):$($agentControl.Result)" 'ok:stopped' '代理停止返回已停止'
$agentControl=Invoke-ServerPulseAgentControl -Server $mockAgentServer -Action update-config
Assert-Equal "$($agentControl.Status):$($agentControl.Result)" 'ok:config_updated' '代理配置更新成功'
$agentControl=Invoke-ServerPulseAgentControl -Server $mockAgentServer -Action uninstall
Assert-Equal "$($agentControl.Status):$($agentControl.Result)" 'ok:uninstalled' '代理卸载成功'

# UTC to local minute conversion
$agentUtcMinute=ConvertTo-ServerPulseLocalMinute '2026-08-11T04:05:00'
$agentExpectedLocal=([datetime]::ParseExact('2026-08-11T04:05:00','yyyy-MM-ddTHH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)).ToLocalTime()
Assert-Equal $agentUtcMinute.ToString('yyyy-MM-ddTHH:mm') $agentExpectedLocal.ToString('yyyy-MM-ddTHH:mm') 'UTC 分钟转换本地时区'

# merge pull parsing
$agentPullOutput=@(
'__SP_FILE__2026-08-11'
'{"Version":2,"Record":{"Timestamp":"2026-08-11T04:05:00","SampleCount":10,"Servers":[{"Id":"agent-test-1","Label":"A","Host":"h","OnlineSamples":10,"CpuPercent":12.3,"Gpus":[]}]}}'
'{"Version":2,"Record":{"Timestamp":"2026-08-11T04:06:00","SampleCount":10,"Servers":[{"Id":"unknown","OnlineSamples":10}]}}'
'not json'
'__SP_DONE__'
) -join "`n"
$agentPulled=ConvertFrom-ServerPulseAgentPull -Output $agentPullOutput -KnownServerIds @('agent-test-1') -CursorUtc $null
Assert-Equal "$($agentPulled.PulledLines):$($agentPulled.Entries.Count):$($agentPulled.DroppedUnknown):$($agentPulled.CorruptLines)" '3:1:1:1' '合并拉取解析统计正确'
$agentPulledCursor=ConvertFrom-ServerPulseAgentPull -Output $agentPullOutput -KnownServerIds @('agent-test-1') -CursorUtc '2026-08-11T04:05'
Assert-Equal $agentPulledCursor.Entries.Count 0 '合并游标跳过已合并分钟'
Assert-Equal (Resolve-ServerPulseAgentConflict ([PSCustomObject]@{Id='x';OnlineSamples=5}) ([PSCustomObject]@{Id='x';OnlineSamples=8})) 'server' '冲突规则样本多者胜'
Assert-Equal (Resolve-ServerPulseAgentConflict ([PSCustomObject]@{Id='x';OnlineSamples=5}) ([PSCustomObject]@{Id='x';OnlineSamples=5})) 'local' '冲突规则平局保留本地'

# merge into local history through the mocked connection
$agentMergeRoot=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-agent-merge-'+[guid]::NewGuid().ToString('N'))
$agentMergeHistory=Join-Path $agentMergeRoot 'history'
try {
    $script:ServerPulseTestPullOutput=$agentPullOutput
    $agentMerge=Merge-ServerPulseAgentRecords -Server $mockAgentServer -HistoryDirectory $agentMergeHistory -KnownServerIds @('agent-test-1') -CursorUtc $null -TimeoutMs 3000
    Assert-Equal "$($agentMerge.Added):$($agentMerge.DroppedUnknown):$($agentMerge.CorruptLines)" '1:1:1' '合并引擎写入历史目录'
    $agentMergeDayFile=Join-Path $agentMergeHistory '2026-08-11.v2.jsonl'
    Assert-Equal (Test-Path -LiteralPath $agentMergeDayFile) $true '合并创建本地日文件'
    $agentMergeLine=(Get-Content -LiteralPath $agentMergeDayFile -First 1)|ConvertFrom-Json
    Assert-Equal ([string]$agentMergeLine.Record.Servers[0].Id) 'agent-test-1' '合并记录包含服务器条目'
    Assert-Equal ([string]$agentMergeLine.Record.SampleCount) '10' '合并记录保留服务器端样本数'
    $agentMerge2=Merge-ServerPulseAgentRecords -Server $mockAgentServer -HistoryDirectory $agentMergeHistory -KnownServerIds @('agent-test-1') -CursorUtc $agentMerge.MaxUtcMinute.ToString('yyyy-MM-ddTHH:mm') -TimeoutMs 3000
    Assert-Equal $agentMerge2.Added 0 '增量合并不重复写入'
} finally { if(Test-Path -LiteralPath $agentMergeRoot){Remove-Item -LiteralPath $agentMergeRoot -Recurse -Force -ErrorAction SilentlyContinue} }

# agent state round trip and startup tasks
$agentStateRoot=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-agent-state-'+[guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $agentStateRoot -Force)
    $agentStatePath=Join-Path $agentStateRoot 'agent-state.json'
    $agentState=New-ServerPulseAgentState
    Set-ServerPulseAgentServerEntry -State $agentState -Id 'agent-test-1' -IntervalSeconds 9 -RetentionDays 33 -AutoRestoreOnStartup $true
    Save-ServerPulseAgentState $agentStatePath $agentState
    $agentState2=Read-ServerPulseAgentState $agentStatePath
    $agentEntry2=Get-ServerPulseAgentServerEntry $agentState2 'agent-test-1'
    Assert-Equal "$($agentEntry2.IntervalSeconds):$($agentEntry2.RetentionDays):$($agentEntry2.AutoRestoreOnStartup)" '9:33:True' '代理状态文件往返'
    $script:ServerPulseTestStatusOutput="SP_AGENT_INSTALLED=1`nSP_AGENT_STATUS=stopped"
    $script:ServerPulseTestPullOutput=$agentPullOutput
    $agentStartupStore=[PSCustomObject]@{Servers=@($mockAgentServer)}
    $agentStartup=Invoke-ServerPulseStartupAgentTasks -AgentStatePath $agentStatePath -HistoryDirectory (Join-Path $agentStateRoot 'history') -ServerStore $agentStartupStore -SessionSecrets @{} -TimeoutMs 3000 -AutoMergeOnStartup $true
    $agentRestoreTask=@($agentStartup.Tasks|Where-Object{$_.Task-eq'restore'})[0]
    $agentMergeTask=@($agentStartup.Tasks|Where-Object{$_.Task-eq'merge'})[0]
    Assert-Equal $agentRestoreTask.Result 'started' '启动自动恢复注入已停止代理'
    Assert-Equal $agentMergeTask.Result 'ok' '启动自动合并成功'
    $agentState3=Read-ServerPulseAgentState $agentStatePath
    $agentEntry3=Get-ServerPulseAgentServerEntry $agentState3 'agent-test-1'
    Assert-Equal ([bool]$agentEntry3.MergeCursorUtc) $true '启动自动合并推进游标'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $agentStateRoot 'history\2026-08-11.v2.jsonl')) $true '启动自动合并写入历史目录'
} finally { if(Test-Path -LiteralPath $agentStateRoot){Remove-Item -LiteralPath $agentStateRoot -Recurse -Force -ErrorAction SilentlyContinue} }

$agentBomBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\src\ServerPulse.Agent.ps1'))
Assert-Equal ("{0},{1},{2}" -f $agentBomBytes[0],$agentBomBytes[1],$agentBomBytes[2]) '239,187,191' '代理模块保持 UTF-8 BOM'
$sampleBomBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\src\ServerPulse.Sample.ps1'))
Assert-Equal ("{0},{1},{2}" -f $sampleBomBytes[0],$sampleBomBytes[1],$sampleBomBytes[2]) '239,187,191' '采样脚本模块保持 UTF-8 BOM'

$agentClean=Merge-ServerPulseAgentRecords -Server $mockAgentServer -HistoryDirectory (Join-Path ([IO.Path]::GetTempPath()) 'serverpulse-agent-clean-check') -KnownServerIds @('agent-test-1') -CursorUtc '2026-08-11T04:05' -TimeoutMs 3000 -CleanMerged
Assert-Equal $agentClean.CleanedFiles 1 '合并后清理服务器端旧记录文件'
$agentCleanTemp=Join-Path ([IO.Path]::GetTempPath()) 'serverpulse-agent-clean-check';if(Test-Path -LiteralPath $agentCleanTemp){Remove-Item -LiteralPath $agentCleanTemp -Recurse -Force -ErrorAction SilentlyContinue}

Write-Output "PASS: $passed assertions"
