Set-StrictMode -Version Latest

function ConvertTo-MetricNumber {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $number = 0.0
    $style = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ([double]::TryParse($Value.Trim(), $style, $culture, [ref]$number)) {
        return $number
    }
    return $null
}

function Split-MetricCsvLine {
    param([Parameter(Mandatory)][string]$Line)

    $parts = [Text.RegularExpressions.Regex]::Split(
        $Line,
        ',(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)'
    )
    return @($parts | ForEach-Object {
        $value = $_.Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2).Replace('""', '"')
        }
        $value
    })
}

function ConvertFrom-ServerMetricsOutput {
    param([Parameter(Mandatory)][string]$Output)

    $values = @{}
    $gpuLines = [Collections.Generic.List[string]]::new()
    $readingGpus = $false

    foreach ($rawLine in ($Output -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ($line -eq 'GPUS_BEGIN') {
            $readingGpus = $true
            continue
        }
        if ($line -eq 'GPUS_END') {
            $readingGpus = $false
            continue
        }
        if ($readingGpus -and $line) {
            $gpuLines.Add($line)
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
        }
    }

    $cpu = ConvertTo-MetricNumber $values['CPU_PERCENT']
    if (-not $values.ContainsKey('HOSTNAME') -or $null -eq $cpu) {
        throw '远程指标输出不完整'
    }

    $gpus = foreach ($line in $gpuLines) {
        $fields = @(Split-MetricCsvLine $line)
        if ($fields.Count -lt 10) { continue }
        [PSCustomObject]@{
            Index          = ConvertTo-MetricNumber $fields[0]
            Name           = if ($fields[1]) { $fields[1] } else { 'NVIDIA GPU' }
            Uuid           = if ($fields[2]) { $fields[2] } else { $null }
            Utilization    = ConvertTo-MetricNumber $fields[3]
            MemoryUsedMiB  = ConvertTo-MetricNumber $fields[4]
            MemoryTotalMiB = ConvertTo-MetricNumber $fields[5]
            TemperatureC   = ConvertTo-MetricNumber $fields[6]
            PowerDrawW     = ConvertTo-MetricNumber $fields[7]
            PowerLimitW    = ConvertTo-MetricNumber $fields[8]
            FanPercent     = ConvertTo-MetricNumber $fields[9]
        }
    }

    $memoryUsedKiB = ConvertTo-MetricNumber $values['MEM_USED_KIB']
    $memoryTotalKiB = ConvertTo-MetricNumber $values['MEM_TOTAL_KIB']
    [PSCustomObject]@{
        Hostname      = $values['HOSTNAME']
        Cpu           = [PSCustomObject]@{ Utilization = $cpu }
        Memory        = [PSCustomObject]@{
            UsedMiB  = if ($null -eq $memoryUsedKiB) { $null } else { $memoryUsedKiB / 1024 }
            TotalMiB = if ($null -eq $memoryTotalKiB) { $null } else { $memoryTotalKiB / 1024 }
            Percent  = ConvertTo-MetricNumber $values['MEM_PERCENT']
        }
        Load          = [PSCustomObject]@{
            One     = ConvertTo-MetricNumber $values['LOAD_1']
            Five    = ConvertTo-MetricNumber $values['LOAD_5']
            Fifteen = ConvertTo-MetricNumber $values['LOAD_15']
        }
        UptimeSeconds = ConvertTo-MetricNumber $values['UPTIME_SECONDS']
        Gpus           = @($gpus)
    }
}

function Get-ServerPulseConfig {
    param([Parameter(Mandatory)][string]$Path)

    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $servers = @($config.servers)
    if ($servers.Count -eq 0) { throw 'config.servers 必须是非空数组' }
    $ids = @{}
    foreach ($server in $servers) {
        if (-not $server.id -or -not $server.label -or -not $server.host) {
            throw '每台服务器都必须配置 id、label 和 host'
        }
        if ($server.host -notmatch '^[a-zA-Z0-9._-]+$') {
            throw "SSH 主机别名不安全: $($server.host)"
        }
        if ($ids.ContainsKey([string]$server.id)) {
            throw "服务器 id 重复: $($server.id)"
        }
        $ids[[string]$server.id] = $true
    }
    return [PSCustomObject]@{
        PollIntervalMs = if ($config.pollIntervalMs) { [int]$config.pollIntervalMs } else { 5000 }
        SshTimeoutMs   = if ($config.sshTimeoutMs) { [int]$config.sshTimeoutMs } else { 8000 }
        Servers        = $servers
    }
}

