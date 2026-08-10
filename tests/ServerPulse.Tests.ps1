$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\ServerPulse.Core.ps1')

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
Assert-Equal $metrics.Gpus[1].PowerDrawW $null '无效数值转换'

$threw = $false
try { ConvertFrom-ServerMetricsOutput -Output 'HOSTNAME=node-only' | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true '不完整输出校验'

$config = Get-ServerPulseConfig -Path (Join-Path $PSScriptRoot '..\config\servers.json')
Assert-Equal @($config.Servers).Count 2 '服务器配置数量'
Assert-Equal $config.Servers[0].host '3090' '第一台 SSH 别名'
Assert-Equal $config.Servers[1].host 'a6000' '第二台 SSH 别名'

Write-Output "PASS: $passed assertions"

