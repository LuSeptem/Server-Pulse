$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Core.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.History.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Ssh.ps1')
. (Join-Path $PSScriptRoot '..\src\ServerPulse.ServerManager.ps1')

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
Assert-Equal $metrics.ProtocolVersion 1 '旧协议输出识别为 v1'
Assert-Equal $metrics.Cpu.UserUsage.Status 'unavailable' 'v1 CPU 用户归属不可用'
Assert-Equal $metrics.Memory.UserUsage.Status 'unavailable' 'v1 内存用户归属不可用'
Assert-Equal $metrics.Gpus[0].UserMemory.Status 'unavailable' 'v1 GPU 用户归属不可用'

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
Assert-Equal ([bool]($mainScript -match '\[Windows\.Forms\.NotifyIcon\]::new\(\)')) $true '创建 Windows 托盘图标'
Assert-Equal ([bool]($mainScript -match 'Join-Path \$scriptRoot ''assets\\server-pulse\.ico''')) $true '托盘加载 Server Pulse 多分辨率图标'
Assert-Equal ([bool]($mainScript -match '\$script:trayOwnedIcon\.Dispose\(\)')) $true '退出时释放自定义托盘图标句柄'
Assert-Equal ([bool]($mainScript -match '\[Windows\.Forms\.ContextMenuStrip\]::new\(\)')) $true '托盘图标提供操作菜单'
Assert-Equal ([bool]($mainScript -match 'function Show-ServerPulseFromTray')) $true '托盘可恢复主窗口'
Assert-Equal ([bool]($mainScript -match 'function Hide-ServerPulseToTray')) $true '托盘可隐藏主窗口'
Assert-Equal ([bool]($mainScript -match '(?s)\$ui\.MinimizeButton\.Add_Click.+?Hide-ServerPulseToTray')) $true '最小化按钮隐藏到托盘'
Assert-Equal ([bool]($mainScript -match '(?s)\$window\.Add_Closing.+?\$script:trayIcon\.Dispose\(\)')) $true '退出时释放托盘图标'
Assert-Equal ([bool]($mainScript -match 'Show-ServerPulseSshManager')) $true '主窗口和托盘可打开 SSH 服务器管理窗口'
Assert-Equal ([bool]($mainScript -match 'if\(\$script:sshManagerOpen\)\{return\}')) $true 'SSH 管理窗口具有单实例门闩'
Assert-Equal ([bool]($mainScript -match 'if\(\$script:sshManagerOpen-or\$script:sshManagerOpenQueued\)\{return\}')) $true '自动打开 SSH 管理窗口不会重复排队'
Assert-Equal ([bool]($mainScript -match 'Show-ServerPulseSshManager -Queued')) $true '排队的管理窗口调用可被手动打开取消'
Assert-Equal ([bool]($mainScript -match 'Clear-ServerPulseSessionSecrets')) $true '退出程序时清除全部会话密码'
Assert-Equal ([bool]($mainScript -match '\$runtimePayload=\$null;foreach\(\$item in \$runtimeServers\)\{\$item\.Password=\$null\}')) $true '采集输入写入标准输入后清除主进程密码副本'
$sshScript=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.Ssh.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($sshScript -match 'SERVERPULSE_AUTH_TOKEN=\$token')) $true 'ASKPASS 仅通过环境传递随机令牌'
Assert-Equal ([bool]($sshScript -match 'EnvironmentVariables\[[^\]]+\]\s*=\s*\$Password')) $false '密码不得写入子进程环境变量'
$managerScript=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ServerPulse.ServerManager.ps1') -Raw -Encoding UTF8
Assert-Equal ([bool]($managerScript -match 'InheritHistory=\[bool\]\$w\.Tag\.Inherit\.IsChecked')) $true '编辑连接身份时由用户选择是否继承历史'
Assert-Equal ([bool]($managerScript -match 'DeleteCredentialButton')) $true '服务器管理窗口允许独立删除 Windows 凭据'
Assert-Equal ([bool]($managerScript -match '\.BeginStop\(')) $true '关闭管理窗口时异步停止 SSH 发现而不阻塞 UI'
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
Assert-Equal ([bool]($historyScript -match 'HistoryCloseButton\.Add_Click\(\{\s*\$historyWindow\.Close')) $false '历史关闭回调不得依赖动态窗口变量'
Assert-Equal ([bool]($historyScript -match '\[Windows\.Window\]::GetWindow\(\$sender\)')) $true '历史关闭回调从按钮解析所属窗口'
Assert-Equal ([bool]($historyScript -match 'HistoryDragArea\.Add_Mouse[^\r\n]+\$drag')) $false '历史拖拽回调不得依赖动态拖拽变量'
Assert-Equal ([bool]($historyScript -match 'Register-HistoryWindowDragArea')) $true '历史拖拽事件使用独立注册函数'
Assert-Equal ([bool]($historyScript -match '(?m)^\s*\$ui\s*=\s*@\{\}')) $false '历史窗口不得覆盖主窗口 UI 动态变量'
Assert-Equal ([bool]($historyScript -match 'ChartKey "\$ServerId/gpu/\$gpuIndex/vram"')) $true '历史 GPU 用户选择以服务器和稳定 GPU 索引为锚点'
Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
$managerOwner=[Windows.Window]::new();$managerOwner.Show()
$managerServer=New-ServerPulseManagedServer -Id 'manager-test' -Label 'Manager Test' -Source manual -SshTarget 'gpu.example' -HostName 'gpu.example' -Port 22 -User alice -Monitored $true
$managerStore=[PSCustomObject]@{Version=1;Path=(Join-Path ([IO.Path]::GetTempPath()) 'serverpulse-manager-unused.json');Servers=@($managerServer)}
$managerSecrets=New-ServerPulseSessionSecretStore
Set-ServerPulseSessionSecret $managerSecrets $managerServer.Identity 'manager-session-secret'
$managerConstruction=[Diagnostics.Stopwatch]::StartNew();$managerSmoke=Show-ServerPulseServerManager -Owner $managerOwner -Store $managerStore -SessionSecrets $managerSecrets -AskPassPath 'unused' -TimeoutMs 1000 -OnApplied {} -SmokeTest;$managerConstruction.Stop()
Assert-Equal ($managerSmoke -is [PSCustomObject]) $true '服务器管理窗口冒烟入口只返回一个状态对象'
Assert-Equal ($managerConstruction.ElapsedMilliseconds-lt1000) $true 'SSH 配置发现不阻塞管理窗口构造'
Assert-Equal ($managerSmoke.Context.DiscoveryAsync -ne $null) $true 'SSH 配置发现运行在后台而非阻塞窗口构造'
$managerRow=$managerSmoke.Context.Rows[0]
Assert-Equal $managerRow.Monitor.IsChecked $true '服务器管理窗口显示监视选择'
Assert-Equal $managerRow.Passwordless.IsHitTestVisible $false '免密复选框只读并由检测结果控制'
Assert-Equal ([string]$managerRow.Passwordless.Parent.Children[1].ToolTip -match '终端 ssh 不会自动读取') $true '免密感叹号悬停解释凭据边界'
Assert-Equal $managerRow.SaveCredential.IsChecked $false '存入 Windows 凭据管理器默认不勾选'
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
Assert-Equal @($wpfHoverCard.Tag.Views | Where-Object { $null -ne $_.Toggle }).Count 3 'GPU 图表提供三个指标显示开关'
$wpfHoverMove=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $wpfHoverMove.RoutedEvent=[Windows.UIElement]::MouseMoveEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverMove)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count 3 'WPF 悬停同时标记同分钟三条曲线'
Assert-Equal $wpfHoverCard.Tag.TimeBlock.Text '2026-08-11 09:45' 'WPF 悬停显示完整具体时间'
Assert-Equal @($wpfHoverCard.Tag.Views | Where-Object { $_.PopupRow.Visibility -eq 'Visible' }).Count 3 '悬停浮窗将三个指标分行显示'
Assert-Equal $wpfHoverCard.Tag.Views[0].PopupText.Text 'GPU  55%' '悬停行显示 GPU 数值'
Assert-Equal $wpfHoverCard.Tag.Views[1].PopupDot.Fill.ToString() '#FF79C8D8' '悬停行使用对应曲线颜色标记'
$wpfToggleDown=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $wpfToggleDown.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent; $wpfHoverCard.Tag.Views[1].Toggle.RaiseEvent($wpfToggleDown)
Assert-Equal $wpfHoverCard.Tag.Views[1].IsVisible $false '点击 VRAM 开关隐藏指标'
Assert-Equal $wpfHoverCard.Tag.Views[1].Line.Visibility 'Collapsed' '隐藏指标同时隐藏对应曲线'
$wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverMove)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count 2 '隐藏后仅标记其余可见曲线'
Assert-Equal @($wpfHoverCard.Tag.Views | Where-Object { $_.PopupRow.Visibility -eq 'Visible' }).Count 2 '隐藏后浮窗不显示该指标行'
$wpfHoverLeave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $wpfHoverLeave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent; $wpfHoverCard.Tag.Canvas.RaiseEvent($wpfHoverLeave)
Assert-Equal @($wpfHoverCard.Tag.Markers | Where-Object { $_.Shape.Visibility -ne 'Collapsed' }).Count 0 '鼠标移出后隐藏全部悬停标记'
$wpfHoverWindow.Close()

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

Write-Output "PASS: $passed assertions"
