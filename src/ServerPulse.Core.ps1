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

function ConvertTo-RefreshIntervalSeconds {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    $seconds = 0
    if (-not [int]::TryParse(([string]$Value).Trim(), [ref]$seconds)) { return $null }
    if ($seconds -lt 1 -or $seconds -gt 300) { return $null }
    return $seconds
}

function Format-Memory {
    param([AllowNull()]$MiB)

    if ($null -eq $MiB) { return '—' }
    if ([double]$MiB -ge 1024) { return ('{0:0.0} GB' -f ([double]$MiB / 1024)) }
    return ('{0:0} MB' -f [double]$MiB)
}

function Format-MemoryUsage {
    param(
        [AllowNull()]$Percent,
        [AllowNull()]$UsedMiB,
        [AllowNull()]$TotalMiB
    )

    if ($null -eq $Percent) { return '—' }
    if ($null -eq $UsedMiB -or $null -eq $TotalMiB) { return ('{0:0}%' -f [double]$Percent) }
    if ([double]$TotalMiB -ge 1024) {
        return ('{0:0}% · {1:0.0}/{2:0.0} GB' -f [double]$Percent, ([double]$UsedMiB / 1024), ([double]$TotalMiB / 1024))
    }
    return ('{0:0}% · {1:0}/{2:0} MB' -f [double]$Percent, [double]$UsedMiB, [double]$TotalMiB)
}

function Format-ServerPulseGpuModel {
    param([AllowNull()][string]$Name)

    $model = if ($null -eq $Name) { '' } else { $Name.Trim() }
    if ([string]::IsNullOrWhiteSpace($model)) { return '' }
    $model = [Text.RegularExpressions.Regex]::Replace($model, '\s+', ' ')
    return [Text.RegularExpressions.Regex]::Replace($model, '(?i)^NVIDIA\s+GeForce\s+', 'NVIDIA ')
}

function Format-ServerPulseGpuTitle {
    param([int]$Index,[AllowNull()][string]$Name)

    $model = Format-ServerPulseGpuModel $Name
    if ([string]::IsNullOrWhiteSpace($model)) { return "GPU $Index" }
    return "GPU $Index · $model"
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
    $cpuUserLines = [Collections.Generic.List[string]]::new()
    $memoryUserLines = [Collections.Generic.List[string]]::new()
    $gpuUserLines = [Collections.Generic.List[string]]::new()
    $gpuUnmappedLines = [Collections.Generic.List[string]]::new()
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
            $key = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            switch ($key) {
                'CPU_USER' { $cpuUserLines.Add($value); continue }
                'MEMORY_USER' { $memoryUserLines.Add($value); continue }
                'GPU_USER' { $gpuUserLines.Add($value); continue }
                'GPU_UNMAPPED' { $gpuUnmappedLines.Add($value); continue }
                default { $values[$key] = $value }
            }
        }
    }

    $cpu = ConvertTo-MetricNumber $values['CPU_PERCENT']
    if (-not $values.ContainsKey('HOSTNAME') -or $null -eq $cpu) {
        throw '远程指标输出不完整'
    }

    $protocolVersion = ConvertTo-MetricNumber $values['PROTOCOL_VERSION']
    $memoryUsedKiB = ConvertTo-MetricNumber $values['MEM_USED_KIB']
    $memoryTotalKiB = ConvertTo-MetricNumber $values['MEM_TOTAL_KIB']
    $cpuUserStatus = if ($protocolVersion -ge 2 -and $values['CPU_USER_STATUS'] -in @('ok', 'partial', 'unavailable')) {
        $values['CPU_USER_STATUS']
    } else { 'unavailable' }
    $memoryUserStatus = if ($protocolVersion -ge 2 -and $values['MEMORY_USER_STATUS'] -in @('ok', 'partial', 'unavailable')) {
        $values['MEMORY_USER_STATUS']
    } else { 'unavailable' }
    $gpuUserStatus = if ($protocolVersion -ge 2 -and $values['GPU_USER_STATUS'] -in @('ok', 'partial', 'unavailable')) {
        $values['GPU_USER_STATUS']
    } else { 'unavailable' }

    $cpuUsers = foreach ($line in $cpuUserLines) {
        $fields = @($line -split "`t", 3)
        if ($fields.Count -ne 3) { continue }
        $percent = ConvertTo-MetricNumber $fields[2]
        if ($null -eq $percent) { continue }
        [PSCustomObject]@{
            Uid     = $fields[0]
            Name    = if ($fields[1]) { $fields[1] } else { "UID $($fields[0])" }
            Percent = [Math]::Min(100.0, [Math]::Max(0.0, $percent))
        }
    }
    $memoryUsers = foreach ($line in $memoryUserLines) {
        $fields = @($line -split "`t", 3)
        if ($fields.Count -ne 3) { continue }
        $usedMiB = ConvertTo-MetricNumber $fields[2]
        if ($null -eq $usedMiB) { continue }
        [PSCustomObject]@{
            Uid     = $fields[0]
            Name    = if ($fields[1]) { $fields[1] } else { "UID $($fields[0])" }
            UsedMiB = [Math]::Max(0.0, $usedMiB)
            Percent = if ($null -eq $memoryTotalKiB -or $memoryTotalKiB -le 0) { $null } else { [Math]::Max(0.0, $usedMiB * 1024 * 100 / $memoryTotalKiB) }
        }
    }

    $gpuUsersByUuid = @{}
    foreach ($line in $gpuUserLines) {
        $fields = @($line -split "`t", 4)
        if ($fields.Count -ne 4) { continue }
        $usedMiB = ConvertTo-MetricNumber $fields[3]
        if ($null -eq $usedMiB) { continue }
        if (-not $gpuUsersByUuid.ContainsKey($fields[0])) {
            $gpuUsersByUuid[$fields[0]] = [Collections.Generic.List[object]]::new()
        }
        $gpuUsersByUuid[$fields[0]].Add([PSCustomObject]@{
            Uid     = $fields[1]
            Name    = if ($fields[2]) { $fields[2] } else { "UID $($fields[1])" }
            UsedMiB = [Math]::Max(0.0, $usedMiB)
        })
    }
    $gpuUnmappedByUuid = @{}
    foreach ($line in $gpuUnmappedLines) {
        $fields = @($line -split "`t", 2)
        if ($fields.Count -ne 2) { continue }
        $count = ConvertTo-MetricNumber $fields[1]
        if ($null -ne $count) { $gpuUnmappedByUuid[$fields[0]] = [int]$count }
    }

    $gpus = foreach ($line in $gpuLines) {
        $fields = @(Split-MetricCsvLine $line)
        if ($fields.Count -lt 10) { continue }
        $uuid = if ($fields[2]) { $fields[2] } else { $null }
        $memoryUsedMiB = ConvertTo-MetricNumber $fields[4]
        $memoryTotalMiB = ConvertTo-MetricNumber $fields[5]
        $gpuUsers = if ($null -ne $uuid -and $gpuUsersByUuid.ContainsKey($uuid)) { @($gpuUsersByUuid[$uuid]) } else { @() }
        $gpuAttributedMiB = 0.0
        foreach ($gpuUser in $gpuUsers) { $gpuAttributedMiB += [double]$gpuUser.UsedMiB }
        $gpuAttributedMiB = [Math]::Round($gpuAttributedMiB, 3)
        $gpuUnattributedMiB = if ($null -eq $memoryUsedMiB) { $null } else { [Math]::Round([Math]::Max(0.0, $memoryUsedMiB - $gpuAttributedMiB), 3) }
        foreach ($gpuUser in $gpuUsers) {
            $gpuUser | Add-Member -NotePropertyName Percent -NotePropertyValue $(if ($null -eq $memoryTotalMiB -or $memoryTotalMiB -le 0) { $null } else { $gpuUser.UsedMiB * 100 / $memoryTotalMiB })
        }
        [PSCustomObject]@{
            Index          = ConvertTo-MetricNumber $fields[0]
            Name           = if ($fields[1]) { $fields[1] } else { 'NVIDIA GPU' }
            Uuid           = $uuid
            Utilization    = ConvertTo-MetricNumber $fields[3]
            MemoryUsedMiB  = $memoryUsedMiB
            MemoryTotalMiB = $memoryTotalMiB
            TemperatureC   = ConvertTo-MetricNumber $fields[6]
            PowerDrawW     = ConvertTo-MetricNumber $fields[7]
            PowerLimitW    = ConvertTo-MetricNumber $fields[8]
            FanPercent     = ConvertTo-MetricNumber $fields[9]
            UserMemory     = [PSCustomObject]@{
                Status            = $gpuUserStatus
                Users             = @($gpuUsers)
                UnattributedMiB   = $gpuUnattributedMiB
                AttributedMiB     = $gpuAttributedMiB
                UnmappedProcesses = if ($null -ne $uuid -and $gpuUnmappedByUuid.ContainsKey($uuid)) { $gpuUnmappedByUuid[$uuid] } else { 0 }
            }
        }
    }

    $cpuAttributedPercent = 0.0
    foreach ($cpuUser in @($cpuUsers)) { $cpuAttributedPercent += [double]$cpuUser.Percent }
    $cpuAttributedPercent = [Math]::Round($cpuAttributedPercent, 3)
    $memoryAttributedMiB = 0.0
    foreach ($memoryUser in @($memoryUsers)) { $memoryAttributedMiB += [double]$memoryUser.UsedMiB }
    $memoryAttributedMiB = [Math]::Round($memoryAttributedMiB, 3)
    $memoryUsedMiB = if ($null -eq $memoryUsedKiB) { $null } else { $memoryUsedKiB / 1024 }
    [PSCustomObject]@{
        Hostname      = $values['HOSTNAME']
        ProtocolVersion = if ($null -eq $protocolVersion) { 1 } else { [int]$protocolVersion }
        Cpu           = [PSCustomObject]@{
            Utilization = $cpu
            Percent     = $cpu
            UserUsage   = [PSCustomObject]@{
                Status              = $cpuUserStatus
                Users               = @($cpuUsers)
                UnattributedPercent = [Math]::Round([Math]::Max(0.0, $cpu - $cpuAttributedPercent), 3)
                OverlapPercent      = [Math]::Round([Math]::Max(0.0, $cpuAttributedPercent - $cpu), 3)
                AttributedPercent   = $cpuAttributedPercent
                SkippedProcesses    = if ($null -eq (ConvertTo-MetricNumber $values['CPU_USER_SKIPPED'])) { 0 } else { [int](ConvertTo-MetricNumber $values['CPU_USER_SKIPPED']) }
            }
        }
        Memory        = [PSCustomObject]@{
            UsedMiB  = $memoryUsedMiB
            TotalMiB = if ($null -eq $memoryTotalKiB) { $null } else { $memoryTotalKiB / 1024 }
            Percent  = ConvertTo-MetricNumber $values['MEM_PERCENT']
            UserUsage = [PSCustomObject]@{
                Status           = $memoryUserStatus
                Users            = @($memoryUsers)
                UnattributedMiB  = if ($null -eq $memoryUsedMiB) { $null } else { [Math]::Round([Math]::Max(0.0, $memoryUsedMiB - $memoryAttributedMiB), 3) }
                OverlapMiB       = if ($null -eq $memoryUsedMiB) { 0.0 } else { [Math]::Round([Math]::Max(0.0, $memoryAttributedMiB - $memoryUsedMiB), 3) }
                AttributedMiB    = $memoryAttributedMiB
                SkippedProcesses = if ($null -eq (ConvertTo-MetricNumber $values['MEMORY_USER_SKIPPED'])) { 0 } else { [int](ConvertTo-MetricNumber $values['MEMORY_USER_SKIPPED']) }
            }
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
    $historyRetentionDays = if ($config.PSObject.Properties.Name -contains 'historyRetentionDays' -and $config.historyRetentionDays) {
        [Math]::Max(1, [int]$config.historyRetentionDays)
    } else { 30 }
    return [PSCustomObject]@{
        PollIntervalMs       = if ($config.pollIntervalMs) { [int]$config.pollIntervalMs } else { 5000 }
        SshTimeoutMs         = if ($config.sshTimeoutMs) { [int]$config.sshTimeoutMs } else { 8000 }
        HistoryRetentionDays = $historyRetentionDays
        Servers              = $servers
    }
}
