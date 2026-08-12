Set-StrictMode -Version Latest

function Get-HistoryObjectValue {
    param($InputObject, [string[]]$Path)

    $value = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $value) { return $null }
        $property = $value.PSObject.Properties[$name]
        if ($null -eq $property) { return $null }
        $value = $property.Value
    }
    return $value
}

function Get-HistoryAverage {
    param([object[]]$Items, [string[]]$Path)

    $values = [Collections.Generic.List[double]]::new()
    foreach ($item in $Items) {
        $value = Get-HistoryObjectValue $item $Path
        if ($null -ne $value) {
            $number = 0.0
            if ([double]::TryParse([string]$value, [ref]$number)) { $values.Add($number) }
        }
    }
    if ($values.Count -eq 0) { return $null }
    return [Math]::Round(($values | Measure-Object -Average).Average, 2)
}

function Get-HistoryLastValue {
    param([object[]]$Items, [string[]]$Path)

    for ($index = $Items.Count - 1; $index -ge 0; $index--) {
        $value = Get-HistoryObjectValue $Items[$index] $Path
        if ($null -ne $value) { return $value }
    }
    return $null
}

function Get-HistoryUserUsageState {
    param(
        $InputObject,
        [string[]]$Path,
        [ValidateSet('Cpu','Memory','GpuMemory')][string]$Kind
    )

    $source = Get-HistoryObjectValue $InputObject $Path
    $status = if ($null -eq $source) { 'unavailable' } else { [string](Get-HistoryObjectValue $source @('Status')) }
    if ($status -notin @('ok','partial')) { return [PSCustomObject]@{Status='unavailable';Users=@();System=$null;Overlap=$null;Attributed=$null;Skipped=$null;Weight=0} }
    $users = foreach ($user in @(Get-HistoryObjectValue $source @('Users'))) {
        if ($null -eq $user) { continue }
        $name = [string](Get-HistoryObjectValue $user @('Name')); if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $uid = [string](Get-HistoryObjectValue $user @('Uid'))
        $value = switch ($Kind) {
            'Cpu' { Get-HistoryObjectValue $user @('Percent') }
            default { Get-HistoryObjectValue $user @('UsedMiB') }
        }
        if ($null -eq $value) { continue }
        $percent=Get-HistoryObjectValue $user @('Percent')
        [PSCustomObject]@{Uid=$uid;Name=$name;Value=[double]$value;Percent=if($null -eq $percent){$null}else{[double]$percent}}
    }
    $system = switch ($Kind) {
        'Cpu' { Get-HistoryObjectValue $source @('UnattributedPercent') }
        default { Get-HistoryObjectValue $source @('UnattributedMiB') }
    }
    $overlap=if($Kind -eq 'Cpu'){Get-HistoryObjectValue $source @('OverlapPercent')}elseif($Kind -eq 'Memory'){Get-HistoryObjectValue $source @('OverlapMiB')}else{$null}
    $attributed=if($Kind -eq 'Cpu'){Get-HistoryObjectValue $source @('AttributedPercent')}else{Get-HistoryObjectValue $source @('AttributedMiB')}
    $skipped=if($Kind -eq 'GpuMemory'){Get-HistoryObjectValue $source @('UnmappedProcesses')}else{Get-HistoryObjectValue $source @('SkippedProcesses')}
    return [PSCustomObject]@{Status=$status;Users=@($users);System=$system;Overlap=$overlap;Attributed=$attributed;Skipped=$skipped;Weight=1}
}

function Merge-HistoryUserUsageSamples {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Samples,
        [ValidateSet('Cpu','Memory','GpuMemory')][string]$Kind
    )

    $valid = @($Samples | Where-Object { $_.Status -in @('ok','partial') })
    if ($valid.Count -eq 0) { return [PSCustomObject]@{Status='unavailable';ValidSamples=0;Users=@()} }
    $identities = @{}
    foreach ($sample in $valid) {
        foreach ($user in @($sample.Users)) {
            $key = if (-not [string]::IsNullOrWhiteSpace([string]$user.Uid)) { "uid:$($user.Uid)" } else { "name:$($user.Name)" }
            if (-not $identities.ContainsKey($key)) { $identities[$key]=[PSCustomObject]@{Key=$key;Uid=[string]$user.Uid;Name=[string]$user.Name} }
        }
    }
    $users = foreach ($identity in $identities.Values) {
        $sum=0.0;$percentSum=0.0;$hasPercent=$false
        foreach ($sample in $valid) {
            $match=@($sample.Users | Where-Object {
                if ($identity.Uid) { [string]$_.Uid -eq $identity.Uid } else { [string]::IsNullOrWhiteSpace([string]$_.Uid) -and [string]$_.Name -eq $identity.Name }
            } | Select-Object -First 1)
            if ($match.Count -gt 0) { $sum += [double]$match[0].Value;if($null -ne $match[0].Percent){$percentSum += [double]$match[0].Percent;$hasPercent=$true} }
        }
        $average=[Math]::Round($sum/$valid.Count,2)
        if ($Kind -eq 'Cpu') { [PSCustomObject]@{Uid=$identity.Uid;Name=$identity.Name;Percent=$average} }
        else { [PSCustomObject]@{Uid=$identity.Uid;Name=$identity.Name;UsedMiB=$average;Percent=if($hasPercent){[Math]::Round($percentSum/$valid.Count,2)}else{$null}} }
    }
    $systemValues=@($valid | Where-Object { $null -ne $_.System } | ForEach-Object { [double]$_.System })
    $status=if(@($valid | Where-Object {$_.Status -eq 'partial'}).Count -gt 0){'partial'}else{'ok'}
    $result=[ordered]@{Status=$status;ValidSamples=$valid.Count;Users=@($users | Sort-Object @{Expression={if($Kind -eq 'Cpu'){$_.Percent}else{$_.UsedMiB}};Descending=$true},Name)}
    if ($systemValues.Count -gt 0) {
        if ($Kind -eq 'Cpu') { $result.UnattributedPercent=[Math]::Round(($systemValues|Measure-Object -Average).Average,2) }
        else { $result.UnattributedMiB=[Math]::Round(($systemValues|Measure-Object -Average).Average,2) }
    }
    $overlapValues=@($valid|Where-Object{$null -ne $_.Overlap}|ForEach-Object{[double]$_.Overlap});$attributedValues=@($valid|Where-Object{$null -ne $_.Attributed}|ForEach-Object{[double]$_.Attributed});$skippedValues=@($valid|Where-Object{$null -ne $_.Skipped}|ForEach-Object{[double]$_.Skipped})
    if($overlapValues.Count){if($Kind -eq 'Cpu'){$result.OverlapPercent=[Math]::Round(($overlapValues|Measure-Object -Average).Average,2)}else{$result.OverlapMiB=[Math]::Round(($overlapValues|Measure-Object -Average).Average,2)}}
    if($attributedValues.Count){if($Kind -eq 'Cpu'){$result.AttributedPercent=[Math]::Round(($attributedValues|Measure-Object -Average).Average,2)}else{$result.AttributedMiB=[Math]::Round(($attributedValues|Measure-Object -Average).Average,2)}}
    if($skippedValues.Count){if($Kind -eq 'GpuMemory'){$result.UnmappedProcesses=[Math]::Round(($skippedValues|Measure-Object -Average).Average,2)}else{$result.SkippedProcesses=[Math]::Round(($skippedValues|Measure-Object -Average).Average,2)}}
    return [PSCustomObject]$result
}

function ConvertTo-HistoryMinuteRecord {
    param(
        [Parameter(Mandatory)][object[]]$Snapshots,
        [Parameter(Mandatory)][datetime]$Minute
    )

    $serverSamples = @($Snapshots | ForEach-Object { @($_.Servers) })
    $servers = foreach ($serverGroup in ($serverSamples | Group-Object { [string]$_.Id })) {
        $samples = @($serverGroup.Group)
        $latest = $samples[-1]
        $onlineSamples = @($samples | Where-Object { $_.Status -eq 'online' -and $null -ne $_.Metrics })
        $gpuSamples = @($onlineSamples | ForEach-Object { @($_.Metrics.Gpus) })
        $gpus = foreach ($gpuGroup in ($gpuSamples | Group-Object { [int]$_.Index })) {
            $items = @($gpuGroup.Group)
            $last = $items[-1]
            $gpuUserSamples=@($items | ForEach-Object { Get-HistoryUserUsageState $_ @('UserMemory') 'GpuMemory' })
            $gpuUserUsage=Merge-HistoryUserUsageSamples -Samples $gpuUserSamples -Kind 'GpuMemory'
            [PSCustomObject]@{
                Index          = [int]$last.Index
                ValidSamples   = $items.Count
                Name           = [string]$last.Name
                Uuid           = [string]$last.Uuid
                Utilization    = Get-HistoryAverage $items @('Utilization')
                MemoryUsedMiB  = Get-HistoryAverage $items @('MemoryUsedMiB')
                MemoryTotalMiB = Get-HistoryAverage $items @('MemoryTotalMiB')
                TemperatureC   = Get-HistoryAverage $items @('TemperatureC')
                PowerDrawW     = Get-HistoryAverage $items @('PowerDrawW')
                PowerLimitW    = Get-HistoryAverage $items @('PowerLimitW')
                FanPercent     = Get-HistoryAverage $items @('FanPercent')
                UserMemory     = $gpuUserUsage
            }
        }
        $cpuUserSamples=@($onlineSamples | ForEach-Object { Get-HistoryUserUsageState $_ @('Metrics','Cpu','UserUsage') 'Cpu' })
        $memoryUserSamples=@($onlineSamples | ForEach-Object { Get-HistoryUserUsageState $_ @('Metrics','Memory','UserUsage') 'Memory' })
        [PSCustomObject]@{
            Id            = [string]$latest.Id
            Label         = [string]$latest.Label
            Host          = [string]$latest.Host
            OnlineSamples = $onlineSamples.Count
            TotalSamples  = $samples.Count
            LatencyMs     = Get-HistoryAverage $onlineSamples @('LatencyMs')
            Hostname      = [string](Get-HistoryLastValue $onlineSamples @('Metrics','Hostname'))
            CpuPercent    = Get-HistoryAverage $onlineSamples @('Metrics','Cpu','Utilization')
            CpuUserUsage  = Merge-HistoryUserUsageSamples -Samples $cpuUserSamples -Kind 'Cpu'
            MemoryUsedMiB = Get-HistoryAverage $onlineSamples @('Metrics','Memory','UsedMiB')
            MemoryTotalMiB= Get-HistoryAverage $onlineSamples @('Metrics','Memory','TotalMiB')
            MemoryPercent = Get-HistoryAverage $onlineSamples @('Metrics','Memory','Percent')
            MemoryUserUsage= Merge-HistoryUserUsageSamples -Samples $memoryUserSamples -Kind 'Memory'
            LoadOne       = Get-HistoryAverage $onlineSamples @('Metrics','Load','One')
            LoadFive      = Get-HistoryAverage $onlineSamples @('Metrics','Load','Five')
            LoadFifteen   = Get-HistoryAverage $onlineSamples @('Metrics','Load','Fifteen')
            UptimeSeconds = Get-HistoryLastValue $onlineSamples @('Metrics','UptimeSeconds')
            Gpus          = @($gpus | Sort-Object Index)
        }
    }
    return [PSCustomObject]@{
        Timestamp   = $Minute.ToString('yyyy-MM-ddTHH:mm:00')
        SampleCount = $Snapshots.Count
        Servers     = @($servers)
    }
}

function New-ServerPulseHistoryRecorder {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$RetentionDays = 30
    )

    return [PSCustomObject]@{
        Directory     = $Directory
        RetentionDays = [Math]::Max(1, $RetentionDays)
        Minute        = $null
        Snapshots     = [Collections.Generic.List[object]]::new()
        ReadErrors    = [Collections.Generic.List[string]]::new()
    }
}

function Write-HistoryReadError {
    param([Parameter(Mandatory)]$Recorder,[Parameter(Mandatory)][string]$Message)
    if ($Recorder.PSObject.Properties.Name -contains 'ReadErrors') { $Recorder.ReadErrors.Add($Message) }
    $logger=Get-Command Write-ServerPulseErrorLog -ErrorAction SilentlyContinue
    if ($null -ne $logger) {
        try { [void](Write-ServerPulseErrorLog -Exception ([IO.InvalidDataException]::new($Message)) -Context 'History JSONL read') } catch { }
    }
}

function Get-HistoryStoredUsageState {
    param($Source,[ValidateSet('Cpu','Memory','GpuMemory')][string]$Kind)
    if ($null -eq $Source) { return [PSCustomObject]@{Status='unavailable';ValidSamples=0;Users=@();System=0.0;Overlap=0.0;Attributed=0.0;Skipped=0.0} }
    $status=[string](Get-HistoryObjectValue $Source @('Status'))
    if ($status -notin @('ok','partial')) { return [PSCustomObject]@{Status='unavailable';ValidSamples=0;Users=@();System=0.0;Overlap=0.0;Attributed=0.0;Skipped=0.0} }
    $validSamples=Get-HistoryObjectValue $Source @('ValidSamples'); if($null -eq $validSamples){$validSamples=1}
    $users=foreach($user in @(Get-HistoryObjectValue $Source @('Users'))){
        $name=[string](Get-HistoryObjectValue $user @('Name'));if([string]::IsNullOrWhiteSpace($name)){continue}
        $value=if($Kind -eq 'Cpu'){Get-HistoryObjectValue $user @('Percent')}else{Get-HistoryObjectValue $user @('UsedMiB')}
        if($null -eq $value){continue}
        $percent=Get-HistoryObjectValue $user @('Percent')
        [PSCustomObject]@{Uid=[string](Get-HistoryObjectValue $user @('Uid'));Name=$name;Value=[double]$value;Percent=if($null -eq $percent){$null}else{[double]$percent}}
    }
    $system=if($Kind -eq 'Cpu'){Get-HistoryObjectValue $Source @('UnattributedPercent')}else{Get-HistoryObjectValue $Source @('UnattributedMiB')}
    if($null -eq $system){$system=0.0}
    $overlap=if($Kind -eq 'Cpu'){Get-HistoryObjectValue $Source @('OverlapPercent')}elseif($Kind -eq 'Memory'){Get-HistoryObjectValue $Source @('OverlapMiB')}else{0.0};if($null -eq $overlap){$overlap=0.0}
    $attributed=if($Kind -eq 'Cpu'){Get-HistoryObjectValue $Source @('AttributedPercent')}else{Get-HistoryObjectValue $Source @('AttributedMiB')};if($null -eq $attributed){$attributed=0.0}
    $skipped=if($Kind -eq 'GpuMemory'){Get-HistoryObjectValue $Source @('UnmappedProcesses')}else{Get-HistoryObjectValue $Source @('SkippedProcesses')};if($null -eq $skipped){$skipped=0.0}
    return [PSCustomObject]@{Status=$status;ValidSamples=[int]$validSamples;Users=@($users);System=[double]$system;Overlap=[double]$overlap;Attributed=[double]$attributed;Skipped=[double]$skipped}
}

function Merge-HistoryStoredUserUsage {
    param([object[]]$Usages,[ValidateSet('Cpu','Memory','GpuMemory')][string]$Kind)
    $states=@($Usages|ForEach-Object{Get-HistoryStoredUsageState $_ $Kind}|Where-Object{$_.ValidSamples -gt 0})
    $total=($states|Measure-Object ValidSamples -Sum).Sum
    if($null -eq $total -or $total -le 0){return [PSCustomObject]@{Status='unavailable';ValidSamples=0;Users=@()}}
    $identities=@{}
    foreach($state in $states){foreach($user in $state.Users){$key=if($user.Uid){"uid:$($user.Uid)"}else{"name:$($user.Name)"};if(-not $identities.ContainsKey($key)){$identities[$key]=[PSCustomObject]@{Uid=$user.Uid;Name=$user.Name}}}}
    $users=foreach($identity in $identities.Values){
        $sum=0.0;$percentSum=0.0;$hasPercent=$false
        foreach($state in $states){$match=@($state.Users|Where-Object{if($identity.Uid){$_.Uid -eq $identity.Uid}else{-not $_.Uid -and $_.Name -eq $identity.Name}}|Select-Object -First 1);if($match.Count){$sum += [double]$match[0].Value*$state.ValidSamples;if($null -ne $match[0].Percent){$percentSum += [double]$match[0].Percent*$state.ValidSamples;$hasPercent=$true}}}
        $average=[Math]::Round($sum/$total,2)
        if($Kind -eq 'Cpu'){[PSCustomObject]@{Uid=$identity.Uid;Name=$identity.Name;Percent=$average}}else{[PSCustomObject]@{Uid=$identity.Uid;Name=$identity.Name;UsedMiB=$average;Percent=if($hasPercent){[Math]::Round($percentSum/$total,2)}else{$null}}}
    }
    $system=0.0;$overlap=0.0;$attributed=0.0;$skipped=0.0;foreach($state in $states){$system += $state.System*$state.ValidSamples;$overlap += $state.Overlap*$state.ValidSamples;$attributed += $state.Attributed*$state.ValidSamples;$skipped += $state.Skipped*$state.ValidSamples};$system=[Math]::Round($system/$total,2);$overlap=[Math]::Round($overlap/$total,2);$attributed=[Math]::Round($attributed/$total,2);$skipped=[Math]::Round($skipped/$total,2)
    $result=[ordered]@{Status=if(@($states|Where-Object{$_.Status -eq 'partial'}).Count){'partial'}else{'ok'};ValidSamples=[int]$total;Users=@($users)}
    if($Kind -eq 'Cpu'){$result.UnattributedPercent=$system}else{$result.UnattributedMiB=$system}
    if($Kind -eq 'Cpu'){$result.OverlapPercent=$overlap;$result.AttributedPercent=$attributed;$result.SkippedProcesses=$skipped}elseif($Kind -eq 'Memory'){$result.OverlapMiB=$overlap;$result.AttributedMiB=$attributed;$result.SkippedProcesses=$skipped}else{$result.AttributedMiB=$attributed;$result.UnmappedProcesses=$skipped}
    return [PSCustomObject]$result
}

function Get-HistoryWeightedAverage {
    param([object[]]$Rows,[string[]]$Path,[string]$WeightProperty='OnlineSamples')
    $sum=0.0;$weightSum=0.0
    foreach($row in $Rows){$value=Get-HistoryObjectValue $row $Path;if($null -eq $value){continue};$weight=Get-HistoryObjectValue $row @($WeightProperty);if($null -eq $weight -or [double]$weight -le 0){$weight=1};$sum += [double]$value*[double]$weight;$weightSum += [double]$weight}
    if($weightSum -le 0){return $null};return [Math]::Round($sum/$weightSum,2)
}

function Get-HistoryNumberSum {
    param([object[]]$Rows,[string]$Property,[double]$Default=0)
    $sum=0.0
    foreach($row in $Rows){$value=Get-HistoryObjectValue $row @($Property);if($null -eq $value){$sum += $Default}else{$sum += [double]$value}}
    return $sum
}

function Merge-HistoryMinuteRecords {
    param([Parameter(Mandatory)][object[]]$Records)
    if($Records.Count -eq 1){$Records[0].Timestamp=(ConvertTo-HistoryRecordTime $Records[0]).ToString('yyyy-MM-ddTHH:mm:ss');return $Records[0]}
    $servers=foreach($serverGroup in (@($Records|ForEach-Object{@($_.Servers)})|Group-Object{[string]$_.Id})){
        $rows=@($serverGroup.Group);$last=$rows[-1]
        $gpuRows=@($rows|ForEach-Object{@($_.Gpus)})
        $gpus=foreach($gpuGroup in ($gpuRows|Group-Object{[int]$_.Index})){
            $items=@($gpuGroup.Group);$gpuLast=$items[-1]
            [PSCustomObject]@{Index=[int]$gpuLast.Index;ValidSamples=[int](Get-HistoryNumberSum $items 'ValidSamples' 1);Name=[string]$gpuLast.Name;Uuid=[string]$gpuLast.Uuid;Utilization=Get-HistoryWeightedAverage $items @('Utilization') 'ValidSamples';MemoryUsedMiB=Get-HistoryWeightedAverage $items @('MemoryUsedMiB') 'ValidSamples';MemoryTotalMiB=Get-HistoryWeightedAverage $items @('MemoryTotalMiB') 'ValidSamples';TemperatureC=Get-HistoryWeightedAverage $items @('TemperatureC') 'ValidSamples';PowerDrawW=Get-HistoryWeightedAverage $items @('PowerDrawW') 'ValidSamples';PowerLimitW=Get-HistoryWeightedAverage $items @('PowerLimitW') 'ValidSamples';FanPercent=Get-HistoryWeightedAverage $items @('FanPercent') 'ValidSamples';UserMemory=Merge-HistoryStoredUserUsage @($items|ForEach-Object{Get-HistoryObjectValue $_ @('UserMemory')}) 'GpuMemory'}
        }
        [PSCustomObject]@{Id=[string]$last.Id;Label=[string]$last.Label;Host=[string]$last.Host;OnlineSamples=[int](Get-HistoryNumberSum $rows 'OnlineSamples');TotalSamples=[int](Get-HistoryNumberSum $rows 'TotalSamples');LatencyMs=Get-HistoryWeightedAverage $rows @('LatencyMs');Hostname=[string]$last.Hostname;CpuPercent=Get-HistoryWeightedAverage $rows @('CpuPercent');CpuUserUsage=Merge-HistoryStoredUserUsage @($rows|ForEach-Object{Get-HistoryObjectValue $_ @('CpuUserUsage')}) 'Cpu';MemoryUsedMiB=Get-HistoryWeightedAverage $rows @('MemoryUsedMiB');MemoryTotalMiB=Get-HistoryWeightedAverage $rows @('MemoryTotalMiB');MemoryPercent=Get-HistoryWeightedAverage $rows @('MemoryPercent');MemoryUserUsage=Merge-HistoryStoredUserUsage @($rows|ForEach-Object{Get-HistoryObjectValue $_ @('MemoryUserUsage')}) 'Memory';LoadOne=Get-HistoryWeightedAverage $rows @('LoadOne');LoadFive=Get-HistoryWeightedAverage $rows @('LoadFive');LoadFifteen=Get-HistoryWeightedAverage $rows @('LoadFifteen');UptimeSeconds=Get-HistoryLastValue $rows @('UptimeSeconds');Gpus=@($gpus|Sort-Object Index)}
    }
    return [PSCustomObject]@{Timestamp=(ConvertTo-HistoryRecordTime $Records[0]).ToString('yyyy-MM-ddTHH:mm:ss');SampleCount=[int](Get-HistoryNumberSum $Records 'SampleCount');Servers=@($servers)}
}

function Save-HistoryMinuteRecord {
    param(
        [Parameter(Mandatory)]$Recorder,
        [Parameter(Mandatory)]$Record
    )

    if (-not (Test-Path -LiteralPath $Recorder.Directory)) {
        [void](New-Item -ItemType Directory -Path $Recorder.Directory)
    }
    $date = ConvertTo-HistoryRecordTime $Record
    $path = Join-Path $Recorder.Directory ($date.ToString('yyyy-MM-dd') + '.v2.jsonl')
    # JSONL is append-only: a later entry for the same minute supersedes or is merged with earlier entries at read time.
    $line=[PSCustomObject]@{Version=2;Record=$Record} | ConvertTo-Json -Depth 16 -Compress
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

function Flush-ServerPulseHistoryRecorder {
    param([Parameter(Mandatory)]$Recorder)

    if ($null -eq $Recorder.Minute -or $Recorder.Snapshots.Count -eq 0) { return $null }
    $record = ConvertTo-HistoryMinuteRecord -Snapshots @($Recorder.Snapshots) -Minute $Recorder.Minute
    Save-HistoryMinuteRecord -Recorder $Recorder -Record $record
    $Recorder.Minute = $null
    $Recorder.Snapshots.Clear()
    return $record
}

function Add-ServerPulseHistorySnapshot {
    param(
        [Parameter(Mandatory)]$Recorder,
        [Parameter(Mandatory)]$Snapshot,
        [datetime]$Timestamp = [DateTime]::Now
    )

    $minute = [datetime]::new($Timestamp.Year, $Timestamp.Month, $Timestamp.Day, $Timestamp.Hour, $Timestamp.Minute, 0)
    if ($null -ne $Recorder.Minute -and $Recorder.Minute -ne $minute) {
        [void](Flush-ServerPulseHistoryRecorder $Recorder)
    }
    if ($null -eq $Recorder.Minute) { $Recorder.Minute = $minute }
    $Recorder.Snapshots.Add($Snapshot)
}

function Get-CurrentHistoryMinuteRecord {
    param([Parameter(Mandatory)]$Recorder)

    if ($null -eq $Recorder.Minute -or $Recorder.Snapshots.Count -eq 0) { return $null }
    return ConvertTo-HistoryMinuteRecord -Snapshots @($Recorder.Snapshots) -Minute $Recorder.Minute
}

function Remove-ExpiredServerPulseHistory {
    param([Parameter(Mandatory)]$Recorder, [datetime]$Now = [DateTime]::Now)

    if (-not (Test-Path -LiteralPath $Recorder.Directory)) { return }
    $cutoff = $Now.Date.AddDays(-$Recorder.RetentionDays + 1)
    foreach ($file in (Get-ChildItem -LiteralPath $Recorder.Directory -File | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}(?:\.v2\.jsonl|\.json)$' })) {
        $date = [datetime]::MinValue
        $dateText=$file.Name.Substring(0,10)
        if ([datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date) -and $date -lt $cutoff) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function ConvertFrom-HistoryMinuteText {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $result = [datetime]::MinValue
    if ([datetime]::TryParseExact($Value.Trim(), 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$result)) {
        return $result
    }
    return $null
}

function ConvertFrom-HistoryDateParts {
    param($Year, $Month, $Day, $Hour, $Minute)

    $invalid = [Collections.Generic.List[string]]::new()
    $values = @{}
    foreach ($field in @(
        [PSCustomObject]@{Name='Year';Value=$Year;Minimum=2000;Maximum=9999},
        [PSCustomObject]@{Name='Month';Value=$Month;Minimum=1;Maximum=12},
        [PSCustomObject]@{Name='Day';Value=$Day;Minimum=1;Maximum=31},
        [PSCustomObject]@{Name='Hour';Value=$Hour;Minimum=0;Maximum=23},
        [PSCustomObject]@{Name='Minute';Value=$Minute;Minimum=0;Maximum=59}
    )) {
        $number = 0
        if (-not [int]::TryParse(([string]$field.Value).Trim(), [ref]$number) -or $number -lt $field.Minimum -or $number -gt $field.Maximum) {
            $invalid.Add($field.Name)
        } else { $values[$field.Name] = $number }
    }
    if (-not $invalid.Contains('Year') -and -not $invalid.Contains('Month') -and -not $invalid.Contains('Day')) {
        if ($values.Day -gt [DateTime]::DaysInMonth($values.Year,$values.Month)) { $invalid.Add('Day') }
    }
    $value = if ($invalid.Count -eq 0) {
        [datetime]::new($values.Year,$values.Month,$values.Day,$values.Hour,$values.Minute,0)
    } else { $null }
    return [PSCustomObject]@{ Value=$value; InvalidFields=@($invalid) }
}

function Get-ServerPulseHistoryRecords {
    param(
        [Parameter(Mandatory)]$Recorder,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End
    )

    if ($End -lt $Start) { throw '结束时间不能早于开始时间' }
    $byMinute = @{}
    for ($date = $Start.Date; $date -le $End.Date; $date = $date.AddDays(1)) {
        $legacyPath = Join-Path $Recorder.Directory ($date.ToString('yyyy-MM-dd') + '.json')
        if (Test-Path -LiteralPath $legacyPath) {
            $saved = Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($record in @($saved.Records)) {
                $key=[string]$record.Timestamp;if(-not $byMinute.ContainsKey($key)){$byMinute[$key]=[Collections.Generic.List[object]]::new()};$byMinute[$key].Add($record)
            }
        }
        $jsonlPath = Join-Path $Recorder.Directory ($date.ToString('yyyy-MM-dd') + '.v2.jsonl')
        if (Test-Path -LiteralPath $jsonlPath) {
            $lines=@(Get-Content -LiteralPath $jsonlPath -Encoding UTF8)
            $lastNonBlank=-1;for($lineIndex=0;$lineIndex -lt $lines.Count;$lineIndex++){if(-not [string]::IsNullOrWhiteSpace($lines[$lineIndex])){$lastNonBlank=$lineIndex}}
            for($lineIndex=0;$lineIndex -lt $lines.Count;$lineIndex++){
                if([string]::IsNullOrWhiteSpace($lines[$lineIndex])){continue}
                try{$entry=$lines[$lineIndex]|ConvertFrom-Json -ErrorAction Stop;$record=if($entry.PSObject.Properties.Name -contains 'Record'){$entry.Record}else{$entry};if($null -eq $record.Timestamp){throw '缺少 Timestamp'};$key=[string]$record.Timestamp;if(-not $byMinute.ContainsKey($key)){$byMinute[$key]=[Collections.Generic.List[object]]::new()};$byMinute[$key].Add($record)}
                catch{if($lineIndex -eq $lastNonBlank){Write-HistoryReadError $Recorder ("忽略损坏的 JSONL 末行：{0} 第 {1} 行：{2}" -f $jsonlPath,($lineIndex+1),$_.Exception.Message);continue};throw}
            }
        }
    }
    $current = Get-CurrentHistoryMinuteRecord $Recorder
    if ($null -ne $current) {$key=[string]$current.Timestamp;if(-not $byMinute.ContainsKey($key)){$byMinute[$key]=[Collections.Generic.List[object]]::new()};$byMinute[$key].Add($current)}
    $merged=[Collections.Generic.List[object]]::new()
    foreach($minuteKey in @($byMinute.Keys)) {
        $minuteRecords=[object[]]$byMinute[$minuteKey].ToArray()
        $merged.Add((Merge-HistoryMinuteRecords -Records $minuteRecords))
    }
    return @($merged | Where-Object {
        $timestamp = ConvertTo-HistoryRecordTime $_
        $timestamp -ge $Start -and $timestamp -le $End
    } | Sort-Object Timestamp)
}

function New-HistoryBrush {
    param([Parameter(Mandatory)][string]$Color)
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function New-HistoryText {
    param([string]$Text, [double]$Size, [string]$Color)
    $block = [Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = New-HistoryBrush $Color
    return $block
}

function Set-HistoryDateFields {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][datetime]$Value)

    $Ui["${Prefix}YearBox"].Text = $Value.Year.ToString('D4')
    $Ui["${Prefix}MonthBox"].Text = $Value.Month.ToString('D2')
    $Ui["${Prefix}DayBox"].Text = $Value.Day.ToString('D2')
    $Ui["${Prefix}HourBox"].Text = $Value.Hour.ToString('D2')
    $Ui["${Prefix}MinuteBox"].Text = $Value.Minute.ToString('D2')
}

function Set-HistoryDateInputValidation {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)][string]$Prefix)

    $result = ConvertFrom-HistoryDateParts -Year $Ui["${Prefix}YearBox"].Text -Month $Ui["${Prefix}MonthBox"].Text -Day $Ui["${Prefix}DayBox"].Text -Hour $Ui["${Prefix}HourBox"].Text -Minute $Ui["${Prefix}MinuteBox"].Text
    foreach ($field in @('Year','Month','Day','Hour','Minute')) {
        $box = $Ui["${Prefix}${field}Box"]; $mark = $Ui["${Prefix}${field}Error"]
        if ($result.InvalidFields -contains $field) {
            $box.BorderBrush=New-HistoryBrush '#FF5E5E'; $box.Background=New-HistoryBrush '#281718'; $box.Foreground=New-HistoryBrush '#FFE2E2'
            $mark.Visibility='Visible'
        } else {
            $box.BorderBrush=New-HistoryBrush '#39413C'; $box.Background=New-HistoryBrush '#171C19'; $box.Foreground=New-HistoryBrush '#D4DBD7'
            $mark.Visibility='Collapsed'
        }
    }
    return $result
}

function ConvertTo-HistoryRecordTime {
    param([Parameter(Mandatory)]$Record)
    $timestamp=Get-HistoryObjectValue $Record @('Timestamp')
    if($timestamp -is [datetime]){return [datetime]$timestamp}
    $result=[datetime]::MinValue
    if([datetime]::TryParseExact(([string]$timestamp).Trim(),'yyyy-MM-ddTHH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$result)){return $result}
    throw "无效历史时间：$timestamp"
}

function Get-HistoryChartHoverSample {
    param(
        [Parameter(Mandatory)][object[]]$Series,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        [Parameter(Mandatory)][double]$CursorX,
        [double]$Width=242,
        [double]$Height=76
    )

    $duration=[Math]::Max(60.0,($End-$Start).TotalSeconds)
    $plotWidth=[Math]::Max(1.0,$Width)
    $targetSeconds=([Math]::Max(0,[Math]::Min($plotWidth,$CursorX))/$plotWidth)*$duration
    $targetTime=$Start.AddSeconds($targetSeconds)
    $nearestTime=$null; $nearestDistance=[double]::PositiveInfinity
    foreach ($item in $Series) {
        foreach ($point in @($item.Points)) {
            if ($null -eq $point.Value) { continue }
            $time=[datetime]$point.Time
            $distance=[Math]::Abs(($time-$targetTime).TotalSeconds)
            if ($distance -lt $nearestDistance) { $nearestTime=$time; $nearestDistance=$distance }
        }
    }
    if ($null -eq $nearestTime) { return $null }

    $x=[Math]::Max(0,[Math]::Min($plotWidth,(($nearestTime-$Start).TotalSeconds/$duration)*$plotWidth))
    $plotBottom=[Math]::Max(4.0,$Height-2.0)
    $plotHeight=[Math]::Max(1.0,$Height-6.0)
    $values=@()
    foreach ($item in $Series) {
        $matchingPoints=@($item.Points | Where-Object { $null -ne $_.Value -and ([datetime]$_.Time).Ticks -eq $nearestTime.Ticks } | Select-Object -First 1)
        if ($matchingPoints.Count -eq 0) { continue }
        $point=$matchingPoints[0]
        $value=[Math]::Max(0,[Math]::Min(100,[double]$point.Value))
        $y=$plotBottom-($value/100*$plotHeight)
        $suffix=if($item.PSObject.Properties.Name -contains 'Suffix'){[string]$item.Suffix}else{''}
        $values += [PSCustomObject]@{Name=[string]$item.Name;Suffix=$suffix;Color=[string]$item.Color;Value=[double]$point.Value;Y=$y}
    }
    return [PSCustomObject]@{Time=$nearestTime;X=$x;Values=@($values)}
}

function Get-HistoryUserColor {
    param([Parameter(Mandatory)][string]$Name)
    $palette=@('#F07178','#F4A261','#E9C46A','#88C0D0','#81A1C1','#B48EAD','#A3BE8C','#D08770','#5E81AC','#C678DD')
    $hash=[uint64]0
    foreach($byte in [Text.Encoding]::UTF8.GetBytes($Name.ToLowerInvariant())){$hash=(($hash*31)+$byte)%2147483647}
    return $palette[[int]($hash % [uint64]$palette.Count)]
}

function ConvertTo-HistoryUserPoint {
    param(
        [Parameter(Mandatory)][datetime]$Time,
        $Usage,
        [ValidateSet('Cpu','Memory','GpuMemory')][string]$Kind,
        [AllowNull()]$TotalMiB
    )
    $state=Get-HistoryStoredUsageState $Usage $Kind
    if($state.Status -eq 'unavailable'){return [PSCustomObject]@{Time=$Time;Status='unavailable';Users=@();DetailNote=''}}
    $users=@(foreach($user in $state.Users){
        $identity=if($user.Uid){"uid:$($user.Uid)"}else{"name:$($user.Name)"}
        $plot=if($Kind -eq 'Cpu'){[double]$user.Value}elseif($null -ne $TotalMiB -and [double]$TotalMiB -gt 0){[double]$user.Value*100/[double]$TotalMiB}else{$null}
        [PSCustomObject]@{Identity=$identity;Uid=$user.Uid;Name=$user.Name;RawValue=[double]$user.Value;PlotValue=$plot;Color=(Get-HistoryUserColor $user.Name);IsSystem=$false}
    })
    if($state.System -ge 0){
        $plot=if($Kind -eq 'Cpu'){$state.System}elseif($null -ne $TotalMiB -and [double]$TotalMiB -gt 0){$state.System*100/[double]$TotalMiB}else{$null}
        $users+= ,[PSCustomObject]@{Identity='system';Uid='';Name='系统/未归属';RawValue=[double]$state.System;PlotValue=$plot;Color='#9AA39D';IsSystem=$true}
    }
    $detailNote=if($Kind -eq 'Cpu'){"归属 {0:0.##}% · 重叠 {1:0.##}% · 跳过 {2:0.##}" -f $state.Attributed,$state.Overlap,$state.Skipped}elseif($Kind -eq 'Memory'){"归属 {0} · 重叠 {1} · 跳过 {2:0.##}" -f (Format-Memory $state.Attributed),(Format-Memory $state.Overlap),$state.Skipped}else{"归属 {0} · 未映射进程 {1:0.##}" -f (Format-Memory $state.Attributed),$state.Skipped}
    return [PSCustomObject]@{Time=$Time;Status=$state.Status;Kind=$Kind;Users=@($users);TotalMiB=$TotalMiB;DetailNote=$detailNote}
}

function Format-HistoryUserValue {
    param($User,[string]$Kind)
    if($Kind -eq 'Cpu'){return ('{0:0.0}%' -f [double]$User.RawValue)}
    $percent=if($null -ne $User.PlotValue){' · {0:0.0}%' -f [double]$User.PlotValue}else{''}
    return (('{0:0.0} GB' -f ([double]$User.RawValue/1024))+$percent)
}

function Get-HistoryChartUserPoint {
    param($State,[datetime]$Time)
    $matches=@($State.UserPoints|Where-Object{([datetime]$_.Time).Ticks -eq $Time.Ticks}|Select-Object -First 1)
    if($matches.Count){return $matches[0]};return $null
}

function Get-HistoryNearestChartTime {
    param($State,[double]$CursorX)
    if(-not $State.Timeline.Count){return $null}
    $target=$State.Start.AddSeconds(([Math]::Max(0,[Math]::Min($State.Canvas.Width,$CursorX))/$State.Canvas.Width)*$State.Duration)
    $nearest=$null;$distance=[double]::PositiveInfinity
    foreach($time in $State.Timeline){$candidate=[datetime]$time;$current=[Math]::Abs(($candidate-$target).TotalSeconds);if($current -lt $distance){$nearest=$candidate;$distance=$current}}
    return $nearest
}

function Set-HistoryChartUnlocked {
    param($State)
    $State.IsLocked=$false;$State.LockedTime=$null;$State.Expanded=$false
    $State.Guide.Visibility='Collapsed';$State.Popup.Visibility='Collapsed'
    foreach($view in $State.Views){$view.Marker.Visibility='Collapsed';$view.PopupRow.Visibility='Collapsed'}
}

function Update-HistoryChartUserSeries {
    param($State)
    foreach($shape in @($State.UserLineShapes)){[void]$State.Canvas.Children.Remove($shape)};$State.UserLineShapes.Clear();$State.UserLegend.Children.Clear()
    $parent=@($State.Views|Where-Object{$_.Name -eq $State.UserParentSeries}|Select-Object -First 1)
    if($parent.Count -and -not $parent[0].IsVisible){return}
    foreach($identity in @($State.SelectedUsers)){
        $known=$null
        foreach($point in $State.UserPoints){$match=@($point.Users|Where-Object{$_.Identity -eq $identity}|Select-Object -First 1);if($match.Count){$known=$match[0];break}}
        if($null -eq $known){continue}
        $segments=[Collections.Generic.List[object]]::new();$current=[Windows.Media.PointCollection]::new()
        foreach($point in $State.UserPoints){
            if($point.Status -eq 'unavailable') { if($current.Count){$segments.Add($current);$current=[Windows.Media.PointCollection]::new()};continue }
            $match=@($point.Users|Where-Object{$_.Identity -eq $identity}|Select-Object -First 1);$value=if($match.Count){$match[0].PlotValue}else{0.0}
            if($null -eq $value){if($current.Count){$segments.Add($current);$current=[Windows.Media.PointCollection]::new()};continue}
            $x=[Math]::Max(0,[Math]::Min($State.Canvas.Width,(([datetime]$point.Time-$State.Start).TotalSeconds/$State.Duration)*$State.Canvas.Width));$y=74-([Math]::Max(0,[Math]::Min(100,[double]$value))/100*70);$current.Add([Windows.Point]::new($x,$y))
        }
        if($current.Count){$segments.Add($current)}
        foreach($segment in $segments){$line=[Windows.Shapes.Polyline]::new();$line.Points=$segment;$line.Stroke=New-HistoryBrush $known.Color;$line.StrokeThickness=1.3;$dashes=[Windows.Media.DoubleCollection]::new();$dashes.Add(3);$dashes.Add(2);$line.StrokeDashArray=$dashes;$line.IsHitTestVisible=$false;[Windows.Controls.Panel]::SetZIndex($line,10);[void]$State.Canvas.Children.Add($line);$State.UserLineShapes.Add($line)}
        $tag=[Windows.Controls.Border]::new();$tag.Padding=[Windows.Thickness]::new(4,1,4,1);$tag.Margin=[Windows.Thickness]::new(0,2,4,0);$tag.BorderBrush=New-HistoryBrush $known.Color;$tag.BorderThickness=[Windows.Thickness]::new(1);$tag.CornerRadius=[Windows.CornerRadius]::new(3);$tag.Cursor='Hand';$tag.ToolTip='点击移除用户曲线';$tag.Tag=[PSCustomObject]@{State=$State;Identity=$identity}
        $tag.Child=New-HistoryText ("● $($known.Name) ×") 7 $known.Color
        $tag.Add_MouseLeftButtonDown({param($sender,$event);$tagState=$sender.Tag;$tagState.State.SelectedUsers.Remove([string]$tagState.Identity);$tagState.State.SelectionStore[$tagState.State.ChartKey]=@($tagState.State.SelectedUsers);Update-HistoryChartUserSeries $tagState.State;$event.Handled=$true})
        [void]$State.UserLegend.Children.Add($tag)
    }
}

function Toggle-HistoryChartUserSelection {
    param($State,[string]$Identity)
    if($State.SelectedUsers.Contains($Identity)){$State.SelectedUsers.Remove($Identity)}else{if($State.SelectedUsers.Count -ge 3){$State.SelectedUsers.RemoveAt(0)};$State.SelectedUsers.Add($Identity)}
    $State.SelectionStore[$State.ChartKey]=@($State.SelectedUsers);Update-HistoryChartUserSeries $State
}

function New-HistoryPopupUserRow {
    param($State,$User,[switch]$Other,[int]$OtherCount=0)
    $border=[Windows.Controls.Border]::new();$border.Padding=[Windows.Thickness]::new(2,2,2,2);$border.Margin=[Windows.Thickness]::new(0,1,0,0);$border.Cursor='Hand';$border.Background=New-HistoryBrush '#01000000'
    $row=[Windows.Controls.Grid]::new();$left=[Windows.Controls.ColumnDefinition]::new();$left.Width='*';[void]$row.ColumnDefinitions.Add($left);$right=[Windows.Controls.ColumnDefinition]::new();$right.Width='Auto';[void]$row.ColumnDefinitions.Add($right)
    if($Other){$name=New-HistoryText $(if($State.Expanded){'收起用户列表'}else{"其他（$OtherCount 用户）"}) 8 '#99A39D';$value=New-HistoryText $(if($State.Expanded){'收起'}else{'展开'}) 8 '#99A39D';$border.Tag=[PSCustomObject]@{State=$State;Other=$true;User=$null}}
    else{$name=New-HistoryText ("● $($User.Name)") 8 $User.Color;$value=New-HistoryText (Format-HistoryUserValue $User $State.UserKind) 8 '#EDF2EF';$border.Tag=[PSCustomObject]@{State=$State;Other=$false;User=$User}}
    $value.HorizontalAlignment='Right';[Windows.Controls.Grid]::SetColumn($value,1);[void]$row.Children.Add($name);[void]$row.Children.Add($value);$border.Child=$row
    $border.Add_MouseLeftButtonDown({param($sender,$event);$data=$sender.Tag;$data.State.IsLocked=$true;if($null -eq $data.State.LockedTime){$data.State.LockedTime=$data.State.HoveredTime};if($data.Other){$data.State.Expanded=-not $data.State.Expanded;Show-HistoryChartSample -State $data.State -Time $data.State.LockedTime}else{Toggle-HistoryChartUserSelection $data.State $data.User.Identity};$event.Handled=$true})
    return $border
}

function Show-HistoryChartSample {
    param($State,[datetime]$Time)
    $visible=@($State.Views|Where-Object{$_.IsVisible});foreach($view in $State.Views){$view.Marker.Visibility='Collapsed';$view.PopupRow.Visibility='Collapsed'}
    $sample=&$State.Resolver -Series @($State.Views|ForEach-Object{$_.Series}) -Start $State.Start -End $State.End -CursorX ((($Time-$State.Start).TotalSeconds/$State.Duration)*$State.Canvas.Width) -Width $State.Canvas.Width -Height $State.Canvas.Height
    if($null -eq $sample){return}
    $State.Guide.X1=$sample.X;$State.Guide.X2=$sample.X
    foreach($value in $sample.Values){$view=@($visible|Where-Object{$_.Name -eq $value.Name}|Select-Object -First 1);if(-not $view.Count){continue};$view=$view[0];[Windows.Controls.Canvas]::SetLeft($view.Marker,$sample.X-4.5);[Windows.Controls.Canvas]::SetTop($view.Marker,$value.Y-4.5);$view.Marker.Visibility='Visible';$view.PopupText.Text=("{0}  {1:0.##}{2}" -f $value.Name,$value.Value,$value.Suffix);$view.PopupRow.Visibility='Visible'}
    $State.TimeBlock.Text=$sample.Time.ToString('yyyy-MM-dd HH:mm');$State.UserPanel.Children.Clear();$userPoint=Get-HistoryChartUserPoint $State $sample.Time
    $parent=@($State.Views|Where-Object{$_.Name -eq $State.UserParentSeries}|Select-Object -First 1);$showUsers=($null -ne $userPoint -and (-not $parent.Count -or $parent[0].IsVisible))
    if($showUsers){if($userPoint.Status -eq 'unavailable'){$text=New-HistoryText '该分钟尚未记录用户明细' 8 '#7C8780';[void]$State.UserPanel.Children.Add($text)}else{$normal=@($userPoint.Users|Where-Object{-not $_.IsSystem -and ($_.RawValue -gt 0 -or $State.SelectedUsers.Contains([string]$_.Identity))}|Sort-Object @{Expression='RawValue';Descending=$true},Name);$system=@($userPoint.Users|Where-Object{$_.IsSystem}|Select-Object -First 1);$take=if($State.Expanded){$normal.Count}else{[Math]::Min(8,$normal.Count)};for($index=0;$index -lt $take;$index++){[void]$State.UserPanel.Children.Add((New-HistoryPopupUserRow $State $normal[$index]))};if(-not $State.Expanded -and $normal.Count -gt 8){[void]$State.UserPanel.Children.Add((New-HistoryPopupUserRow $State $null -Other -OtherCount ($normal.Count-8)))}elseif($State.Expanded -and $normal.Count -gt 8){[void]$State.UserPanel.Children.Add((New-HistoryPopupUserRow $State $null -Other -OtherCount 0))};if($system.Count){[void]$State.UserPanel.Children.Add((New-HistoryPopupUserRow $State $system[0]))};if(-not [string]::IsNullOrWhiteSpace([string]$userPoint.DetailNote)){$noteText=if($userPoint.Status -eq 'partial'){"部分采集 · $($userPoint.DetailNote)"}else{$userPoint.DetailNote};$note=New-HistoryText $noteText 7 '#66716A';$note.Margin=[Windows.Thickness]::new(2,3,0,0);[void]$State.UserPanel.Children.Add($note)}}}
    $rowCount=@($State.Views|Where-Object{$_.PopupRow.Visibility -eq 'Visible'}).Count+$State.UserPanel.Children.Count;$State.Popup.Height=25+(14*$rowCount);$popupLeft=if($sample.X -gt ($State.Canvas.Width/2)){$sample.X-$State.Popup.Width-7}else{$sample.X+7};[Windows.Controls.Canvas]::SetLeft($State.Popup,[Math]::Max(0,[Math]::Min($State.Canvas.Width-$State.Popup.Width,$popupLeft)));[Windows.Controls.Canvas]::SetTop($State.Popup,4);$State.Guide.Visibility='Visible';$State.Popup.Visibility='Visible'
}

function Register-HistoryChartInteractions {
    param($Canvas,$Popup,$Card)
    $Canvas.Add_MouseMove({
        param($sender,$event)
        $state=$sender.Tag;if($state.IsLocked){return};$visible=@($state.Views|Where-Object{$_.IsVisible});if(-not $visible.Count){Set-HistoryChartUnlocked $state;return}
        $cursor=$event.GetPosition($sender);$time=Get-HistoryNearestChartTime $state $cursor.X
        if($null -ne $time){$state.HoveredTime=$time;Show-HistoryChartSample $state $time}
    })
    $Canvas.Add_MouseLeave({param($sender,$event);$state=$sender.Tag;if(-not $state.IsLocked){Set-HistoryChartUnlocked $state}})
    $Canvas.Add_MouseLeftButtonDown({
        param($sender,$event)
        $state=$sender.Tag;$visible=@($state.Views|Where-Object{$_.IsVisible});if(-not $visible.Count){Set-HistoryChartUnlocked $state;$event.Handled=$true;return}
        $cursor=$event.GetPosition($sender);$time=Get-HistoryNearestChartTime $state $cursor.X
        if($null -eq $time -or ($state.IsLocked -and $null -ne $state.LockedTime -and $state.LockedTime.Ticks -eq $time.Ticks)){Set-HistoryChartUnlocked $state}else{$state.IsLocked=$true;$state.LockedTime=$time;$state.HoveredTime=$time;$state.Expanded=$false;Show-HistoryChartSample $state $time;[void]$state.Card.Focus()};$event.Handled=$true
    })
    $Popup.Add_MouseMove({param($sender,$event);$event.Handled=$true})
    $Popup.Add_MouseLeftButtonDown({param($sender,$event);$state=$sender.Tag;if($null -ne $state -and $null -ne $state.HoveredTime){$state.IsLocked=$true;$state.LockedTime=$state.HoveredTime};$event.Handled=$true})
    $Card.Add_PreviewKeyDown({param($sender,$event);if($event.Key -eq 'Escape'){Set-HistoryChartUnlocked $sender.Tag;$event.Handled=$true}})
    $Card.Add_MouseLeftButtonDown({param($sender,$event);if($sender.Tag.IsLocked){Set-HistoryChartUnlocked $sender.Tag;$event.Handled=$true}})
}

function Register-HistoryWindowChartEscape {
    param($Window,$Panel)
    $Window.Add_PreviewKeyDown({
        param($sender,$event)
        if($event.Key -ne 'Escape'){return}
        $root=$sender.Resources['ServerPulse.HistoryPanel'];if($null -eq $root){return}
        foreach($section in @($root.Children)){
            if($section.Child -isnot [Windows.Controls.StackPanel]){continue}
            foreach($child in @($section.Child.Children)){
                if($child -isnot [Windows.Controls.WrapPanel]){continue}
                foreach($card in @($child.Children)){if($null -ne $card.Tag -and (Get-HistoryObjectValue $card.Tag @('Kind')) -eq 'HistoryChart'){Set-HistoryChartUnlocked $card.Tag}}
            }
        }
        $event.Handled=$true
    })
    $Window.Resources['ServerPulse.HistoryPanel']=$Panel
}

function New-HistoryChartCard {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle,
        [Parameter(Mandatory)][object[]]$Series,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        [object[]]$UserPoints=@(),
        [ValidateSet('','Cpu','Memory','GpuMemory')][string]$UserKind='',
        [string]$UserParentSeries='',
        [string]$ChartKey='',
        $SelectionStore
    )

    $card = [Windows.Controls.Border]::new()
    $card.Width = 264; $card.Height = 142
    $card.Margin = [Windows.Thickness]::new(0,0,8,8)
    $card.Padding = [Windows.Thickness]::new(10,8,10,8)
    $card.Background = New-HistoryBrush '#1B201D'
    $card.BorderBrush = New-HistoryBrush '#303732'
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(7);$card.Focusable=$true

    $seriesViews=@($Series | ForEach-Object {
        [PSCustomObject]@{
            Name=[string]$_.Name; Series=$_; IsVisible=$true; Line=$null; SingleDot=$null; Marker=$null; Toggle=$null; ToggleText=$null
            PopupRow=$null; PopupDot=$null; PopupText=$null
            ActiveBackground=(New-HistoryBrush '#263029'); InactiveBackground=(New-HistoryBrush '#171B18')
            ActiveForeground=(New-HistoryBrush ([string]$_.Color)); InactiveForeground=(New-HistoryBrush '#59635D')
            ActiveBorder=(New-HistoryBrush ([string]$_.Color)); InactiveBorder=(New-HistoryBrush '#303732')
        }
    })

    $layout = [Windows.Controls.Grid]::new()
    $row1 = [Windows.Controls.RowDefinition]::new(); $row1.Height = 'Auto'
    $row2 = [Windows.Controls.RowDefinition]::new(); $row2.Height = '*'
    $row3 = [Windows.Controls.RowDefinition]::new(); $row3.Height = 'Auto'
    [void]$layout.RowDefinitions.Add($row1); [void]$layout.RowDefinitions.Add($row2); [void]$layout.RowDefinitions.Add($row3)

    $header = [Windows.Controls.Grid]::new()
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $rightColumn = [Windows.Controls.ColumnDefinition]::new(); $rightColumn.Width = 'Auto'; [void]$header.ColumnDefinitions.Add($rightColumn)
    $titleBlock = New-HistoryText $Title 10 '#E1E6E3'; $titleBlock.FontWeight = 'SemiBold'; $titleBlock.VerticalAlignment='Center'
    [void]$header.Children.Add($titleBlock)
    if ($seriesViews.Count -gt 1) {
        $togglePanel=[Windows.Controls.StackPanel]::new(); $togglePanel.Orientation='Horizontal'; $togglePanel.HorizontalAlignment='Right'
        foreach ($view in $seriesViews) {
            $suffix=if($view.Series.PSObject.Properties.Name -contains 'Suffix'){[string]$view.Series.Suffix}else{''}
            $latestText=if($null -eq $view.Series.Latest){$view.Name}else{"{0} {1:0}{2}" -f $view.Name,[double]$view.Series.Latest,$suffix}
            $toggle=[Windows.Controls.Border]::new(); $toggle.Tag=$view; $toggle.Padding=[Windows.Thickness]::new(4,2,4,2); $toggle.Margin=[Windows.Thickness]::new(2,0,0,0); $toggle.CornerRadius=[Windows.CornerRadius]::new(3)
            $toggleText=New-HistoryText $latestText 7 ([string]$view.Series.Color); $toggleText.FontWeight='SemiBold'; $toggleText.IsHitTestVisible=$false; $toggle.Child=$toggleText
            $toggle.Background=$view.ActiveBackground; $toggle.BorderBrush=$view.ActiveBorder; $toggle.BorderThickness=[Windows.Thickness]::new(1); $toggle.Cursor='Hand'
            $toggle.ToolTip="点击隐藏 $($view.Name)"
            $view.Toggle=$toggle; $view.ToggleText=$toggleText
            $toggle.Add_MouseLeftButtonDown({
                param($sender,$event)
                $view=$sender.Tag; $view.IsVisible=-not $view.IsVisible
                $visibility=if($view.IsVisible){'Visible'}else{'Collapsed'}
                if($null -ne $view.Line){$view.Line.Visibility=$visibility}; if($null -ne $view.SingleDot){$view.SingleDot.Visibility=$visibility}; if($null -ne $view.Marker){$view.Marker.Visibility='Collapsed'}
                $sender.Background=if($view.IsVisible){$view.ActiveBackground}else{$view.InactiveBackground}
                $view.ToggleText.Foreground=if($view.IsVisible){$view.ActiveForeground}else{$view.InactiveForeground}
                $sender.BorderBrush=if($view.IsVisible){$view.ActiveBorder}else{$view.InactiveBorder}
                $sender.ToolTip=if($view.IsVisible){"点击隐藏 $($view.Name)"}else{"点击显示 $($view.Name)"}
                $state=$sender.DataContext
                if($null -ne $state){$state.Guide.Visibility='Collapsed';$state.Popup.Visibility='Collapsed';foreach($itemView in $state.Views){$itemView.Marker.Visibility='Collapsed';$itemView.PopupRow.Visibility='Collapsed'};Update-HistoryChartUserSeries $state}
                $event.Handled=$true
            })
            [void]$togglePanel.Children.Add($toggle)
        }
        [Windows.Controls.Grid]::SetColumn($togglePanel,1); [void]$header.Children.Add($togglePanel)
    } else {
        $latestParts=@($seriesViews | ForEach-Object { if($null -ne $_.Series.Latest){$suffix=if($_.Series.PSObject.Properties.Name -contains 'Suffix'){[string]$_.Series.Suffix}else{''};"{0} {1:0}{2}" -f $_.Name,[double]$_.Series.Latest,$suffix} })
        $latestBlock=New-HistoryText ($latestParts -join ' · ') 8 '#98A39C'; $latestBlock.HorizontalAlignment='Right'; [Windows.Controls.Grid]::SetColumn($latestBlock,1); [void]$header.Children.Add($latestBlock)
    }
    $headerStack=[Windows.Controls.StackPanel]::new();[void]$headerStack.Children.Add($header)
    $userLegend=[Windows.Controls.WrapPanel]::new();$userLegend.Margin=[Windows.Thickness]::new(0,1,0,0);[void]$headerStack.Children.Add($userLegend)
    [Windows.Controls.Grid]::SetRow($headerStack,0); [void]$layout.Children.Add($headerStack)

    $canvas = [Windows.Controls.Canvas]::new(); $canvas.Width = 242; $canvas.Height = 76; $canvas.Margin = [Windows.Thickness]::new(0,7,0,5)
    $canvas.Background=New-HistoryBrush '#00131714'; $canvas.Cursor='Cross'; $canvas.ClipToBounds=$false
    foreach ($y in @(2.0,38.0,74.0)) {
        $gridLine = [Windows.Shapes.Line]::new(); $gridLine.X1=0; $gridLine.X2=242; $gridLine.Y1=$y; $gridLine.Y2=$y
        $gridLine.Stroke = New-HistoryBrush '#2B312D'; $gridLine.StrokeThickness=1; [void]$canvas.Children.Add($gridLine)
    }
    $duration = [Math]::Max(60.0, ($End - $Start).TotalSeconds)
    foreach ($view in $seriesViews) {
        $polyline = [Windows.Shapes.Polyline]::new(); $polyline.Stroke = New-HistoryBrush ([string]$view.Series.Color); $polyline.StrokeThickness = 1.8; $polyline.StrokeLineJoin = 'Round'
        $points = [Windows.Media.PointCollection]::new()
        foreach ($point in @($view.Series.Points)) {
            if ($null -eq $point.Value) { continue }
            $x = [Math]::Max(0, [Math]::Min(242, (($point.Time - $Start).TotalSeconds / $duration) * 242)); $value = [Math]::Max(0, [Math]::Min(100, [double]$point.Value)); $y = 74 - ($value / 100 * 70)
            $points.Add([Windows.Point]::new($x,$y))
        }
        $polyline.Points = $points; $view.Line=$polyline; [void]$canvas.Children.Add($polyline)
        if ($points.Count -eq 1) {
            $dot = [Windows.Shapes.Ellipse]::new(); $dot.Width=4; $dot.Height=4; $dot.Fill=New-HistoryBrush ([string]$view.Series.Color)
            [Windows.Controls.Canvas]::SetLeft($dot,$points[0].X-2); [Windows.Controls.Canvas]::SetTop($dot,$points[0].Y-2); $view.SingleDot=$dot; [void]$canvas.Children.Add($dot)
        }
    }
    $hoverGuide=[Windows.Shapes.Line]::new(); $hoverGuide.Y1=2; $hoverGuide.Y2=74; $hoverGuide.Stroke=New-HistoryBrush '#6F7B73'; $hoverGuide.StrokeThickness=1; $hoverGuide.Opacity=0.7; $hoverGuide.Visibility='Collapsed'; $hoverGuide.IsHitTestVisible=$false
    $hoverDashes=[Windows.Media.DoubleCollection]::new(); $hoverDashes.Add(2.0); $hoverDashes.Add(3.0); $hoverGuide.StrokeDashArray=$hoverDashes; [Windows.Controls.Panel]::SetZIndex($hoverGuide,20); [void]$canvas.Children.Add($hoverGuide)
    $hoverMarkers=@()
    foreach ($view in $seriesViews) {
        $marker=[Windows.Shapes.Ellipse]::new(); $marker.Width=9; $marker.Height=9; $marker.Fill=New-HistoryBrush '#131714'; $marker.Stroke=New-HistoryBrush ([string]$view.Series.Color); $marker.StrokeThickness=2; $marker.Visibility='Collapsed'; $marker.IsHitTestVisible=$false
        [Windows.Controls.Panel]::SetZIndex($marker,22); [void]$canvas.Children.Add($marker); $view.Marker=$marker; $hoverMarkers += [PSCustomObject]@{Name=$view.Name;Shape=$marker}
    }
    $hoverPopup=[Windows.Controls.Border]::new(); $hoverPopup.Width=190; $hoverPopup.Height=67; $hoverPopup.Padding=[Windows.Thickness]::new(7,4,7,4); $hoverPopup.Background=New-HistoryBrush '#F20D110F'; $hoverPopup.BorderBrush=New-HistoryBrush '#455047'; $hoverPopup.BorderThickness=[Windows.Thickness]::new(1); $hoverPopup.CornerRadius=[Windows.CornerRadius]::new(5); $hoverPopup.Visibility='Collapsed'; $hoverPopup.IsHitTestVisible=$true
    $hoverPopup.Effect=[Windows.Media.Effects.DropShadowEffect]@{Color=[Windows.Media.Colors]::Black;BlurRadius=8;ShadowDepth=2;Opacity=0.45}
    $hoverStack=[Windows.Controls.StackPanel]::new(); $hoverTime=New-HistoryText '' 7 '#98A39C'; [void]$hoverStack.Children.Add($hoverTime)
    foreach($view in $seriesViews){
        $popupRow=[Windows.Controls.StackPanel]::new(); $popupRow.Orientation='Horizontal'; $popupRow.Margin=[Windows.Thickness]::new(0,2,0,0); $popupRow.Visibility='Collapsed'
        $popupDot=[Windows.Shapes.Ellipse]::new(); $popupDot.Width=6; $popupDot.Height=6; $popupDot.Fill=New-HistoryBrush ([string]$view.Series.Color); $popupDot.Margin=[Windows.Thickness]::new(0,3,6,0); $popupDot.VerticalAlignment='Top'
        $popupText=New-HistoryText '' 8 '#EDF2EF'; $popupText.FontWeight='SemiBold'
        [void]$popupRow.Children.Add($popupDot); [void]$popupRow.Children.Add($popupText); [void]$hoverStack.Children.Add($popupRow)
        $view.PopupRow=$popupRow; $view.PopupDot=$popupDot; $view.PopupText=$popupText
    }
    $userPanel=[Windows.Controls.StackPanel]::new();$userPanel.Margin=[Windows.Thickness]::new(0,2,0,0);[void]$hoverStack.Children.Add($userPanel)
    $hoverPopup.Child=$hoverStack; [Windows.Controls.Panel]::SetZIndex($hoverPopup,24); [void]$canvas.Children.Add($hoverPopup)
    if($null -eq $SelectionStore){$SelectionStore=@{}};if(-not $SelectionStore.ContainsKey($ChartKey)){$SelectionStore[$ChartKey]=@()}
    $selected=[Collections.Generic.List[string]]::new();foreach($identity in @($SelectionStore[$ChartKey])){if($selected.Count -lt 3){$selected.Add([string]$identity)}}
    $lineShapes=[Collections.Generic.List[object]]::new()
    $timeline=@($UserPoints|ForEach-Object{[datetime]$_.Time}|Sort-Object -Unique);if(-not $timeline.Count){$timeline=@($Series|ForEach-Object{@($_.Points)}|ForEach-Object{[datetime]$_.Time}|Sort-Object -Unique)}
    $hoverState=[PSCustomObject]@{Kind='HistoryChart';Card=$card;ChartKey=$ChartKey;SelectionStore=$SelectionStore;Canvas=$canvas;Guide=$hoverGuide;Markers=@($hoverMarkers);Popup=$hoverPopup;TimeBlock=$hoverTime;Views=@($seriesViews);Start=$Start;End=$End;Duration=$duration;Timeline=@($timeline);Resolver=${function:Get-HistoryChartHoverSample};UserPoints=@($UserPoints);UserKind=$UserKind;UserParentSeries=$UserParentSeries;UserPanel=$userPanel;UserLegend=$userLegend;SelectedUsers=$selected;UserLineShapes=$lineShapes;HoveredTime=$null;LockedTime=$null;IsLocked=$false;Expanded=$false}
    foreach($view in $seriesViews){if($null -ne $view.Toggle){$view.Toggle.DataContext=$hoverState}}
    $canvas.Tag=$hoverState; $card.Tag=$hoverState
    $hoverPopup.Tag=$hoverState
    Register-HistoryChartInteractions $canvas $hoverPopup $card
    Update-HistoryChartUserSeries $hoverState
    [Windows.Controls.Grid]::SetRow($canvas,1); [void]$layout.Children.Add($canvas)

    $footer = [Windows.Controls.Grid]::new(); $subtitleBlock = New-HistoryText $Subtitle 7 '#66716A'; $subtitleBlock.TextTrimming = 'CharacterEllipsis'; $endBlock = New-HistoryText ($End.ToString('MM-dd HH:mm')) 7 '#505A54'; $endBlock.HorizontalAlignment = 'Right'
    [void]$footer.Children.Add($subtitleBlock); [void]$footer.Children.Add($endBlock); [Windows.Controls.Grid]::SetRow($footer,2); [void]$layout.Children.Add($footer)
    $card.Child = $layout; return $card
}

function Get-HistoryServerFromRecord {
    param($Record, [string]$ServerId)
    $matches = @($Record.Servers | Where-Object { [string]$_.Id -eq $ServerId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Add-HistoryServerSection {
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][string]$ServerId,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        $SelectionStore
    )

    $serverRecords = foreach ($record in $Records) {
        $server = Get-HistoryServerFromRecord $record $ServerId
        if ($null -ne $server) { [PSCustomObject]@{Time=(ConvertTo-HistoryRecordTime $record);Server=$server} }
    }
    $serverRecords = @($serverRecords)
    if ($serverRecords.Count -eq 0) { return }
    $latest = $serverRecords[-1].Server

    $surface = [Windows.Controls.Border]::new()
    $surface.Background = New-HistoryBrush '#131714'; $surface.BorderBrush = New-HistoryBrush '#2C332E'
    $surface.BorderThickness = [Windows.Thickness]::new(1); $surface.CornerRadius = [Windows.CornerRadius]::new(9)
    $surface.Padding = [Windows.Thickness]::new(14,11,10,11); $surface.Margin = [Windows.Thickness]::new(0,0,0,12)
    $stack = [Windows.Controls.StackPanel]::new()

    $header = [Windows.Controls.Grid]::new(); [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $headerRight = [Windows.Controls.ColumnDefinition]::new(); $headerRight.Width='Auto'; [void]$header.ColumnDefinitions.Add($headerRight)
    $name = New-HistoryText ([string]$latest.Label) 14 '#EDF1EF'; $name.FontWeight='SemiBold'
    $onlineCount = ($serverRecords | ForEach-Object { [int]$_.Server.OnlineSamples } | Measure-Object -Sum).Sum
    $sampleCount = ($serverRecords | ForEach-Object { [int]$_.Server.TotalSamples } | Measure-Object -Sum).Sum
    $meta = New-HistoryText ("{0} · 在线样本 {1}/{2}" -f $latest.Host,$onlineCount,$sampleCount) 8 '#78837C'; $meta.HorizontalAlignment='Right'; [Windows.Controls.Grid]::SetColumn($meta,1)
    [void]$header.Children.Add($name); [void]$header.Children.Add($meta); [void]$stack.Children.Add($header)

    $legend = New-HistoryText '绿 利用率 / CPU / MEM   ·   蓝 显存   ·   橙 温度' 8 '#6E7972'
    $legend.Margin=[Windows.Thickness]::new(0,3,0,8); [void]$stack.Children.Add($legend)
    $wrap = [Windows.Controls.WrapPanel]::new()

    $cpuPoints = @($serverRecords | ForEach-Object { [PSCustomObject]@{Time=$_.Time;Value=$_.Server.CpuPercent} })
    $memoryPoints = @($serverRecords | ForEach-Object { [PSCustomObject]@{Time=$_.Time;Value=$_.Server.MemoryPercent} })
    $cpuUserPoints=@($serverRecords|ForEach-Object{ConvertTo-HistoryUserPoint -Time $_.Time -Usage (Get-HistoryObjectValue $_.Server @('CpuUserUsage')) -Kind 'Cpu' -TotalMiB $null})
    $memoryUserPoints=@($serverRecords|ForEach-Object{ConvertTo-HistoryUserPoint -Time $_.Time -Usage (Get-HistoryObjectValue $_.Server @('MemoryUserUsage')) -Kind 'Memory' -TotalMiB (Get-HistoryObjectValue $_.Server @('MemoryTotalMiB'))})
    $cpuSeries = @([PSCustomObject]@{Name='CPU';Suffix='%';Color='#A7D948';Points=$cpuPoints;Latest=$latest.CpuPercent})
    $memorySeries = @([PSCustomObject]@{Name='MEM';Suffix='%';Color='#A7D948';Points=$memoryPoints;Latest=$latest.MemoryPercent})
    [void]$wrap.Children.Add((New-HistoryChartCard -Title 'CPU' -Subtitle ("LOAD 1/5/15 {0:0.00}/{1:0.00}/{2:0.00} · SSH {3:0} ms" -f $latest.LoadOne,$latest.LoadFive,$latest.LoadFifteen,$latest.LatencyMs) -Series $cpuSeries -Start $Start -End $End -UserPoints $cpuUserPoints -UserKind Cpu -UserParentSeries CPU -ChartKey "$ServerId/cpu" -SelectionStore $SelectionStore))
    [void]$wrap.Children.Add((New-HistoryChartCard -Title 'MEM' -Subtitle ("{0:0.0}/{1:0.0} GB · UPTIME {2:0.0} d" -f ([double]$latest.MemoryUsedMiB/1024),([double]$latest.MemoryTotalMiB/1024),([double]$latest.UptimeSeconds/86400)) -Series $memorySeries -Start $Start -End $End -UserPoints $memoryUserPoints -UserKind Memory -UserParentSeries MEM -ChartKey "$ServerId/memory" -SelectionStore $SelectionStore))

    $gpuIndexes = @($serverRecords | ForEach-Object { @($_.Server.Gpus) } | ForEach-Object { [int]$_.Index } | Sort-Object -Unique)
    foreach ($gpuIndex in $gpuIndexes) {
        $gpuRows = foreach ($row in $serverRecords) {
            $matches = @($row.Server.Gpus | Where-Object { [int]$_.Index -eq $gpuIndex } | Select-Object -First 1)
            if ($matches.Count -gt 0) { [PSCustomObject]@{Time=$row.Time;Gpu=$matches[0]} }
        }
        $gpuRows = @($gpuRows); if ($gpuRows.Count -eq 0) { continue }
        $gpuLatest = $gpuRows[-1].Gpu
        $utilPoints = @($gpuRows | ForEach-Object { [PSCustomObject]@{Time=$_.Time;Value=$_.Gpu.Utilization} })
        $vramPoints = @($gpuRows | ForEach-Object {
            $percent = if ($_.Gpu.MemoryTotalMiB -and [double]$_.Gpu.MemoryTotalMiB -gt 0) { [double]$_.Gpu.MemoryUsedMiB * 100 / [double]$_.Gpu.MemoryTotalMiB } else { $null }
            [PSCustomObject]@{Time=$_.Time;Value=$percent}
        })
        $tempPoints = @($gpuRows | ForEach-Object { [PSCustomObject]@{Time=$_.Time;Value=$_.Gpu.TemperatureC} })
        $vramLatest = if ($gpuLatest.MemoryTotalMiB -and [double]$gpuLatest.MemoryTotalMiB -gt 0) { [double]$gpuLatest.MemoryUsedMiB * 100 / [double]$gpuLatest.MemoryTotalMiB } else { $null }
        $vramUserPoints=@($gpuRows|ForEach-Object{ConvertTo-HistoryUserPoint -Time $_.Time -Usage (Get-HistoryObjectValue $_.Gpu @('UserMemory')) -Kind 'GpuMemory' -TotalMiB (Get-HistoryObjectValue $_.Gpu @('MemoryTotalMiB'))})
        $series = @(
            [PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Points=$utilPoints;Latest=$gpuLatest.Utilization},
            [PSCustomObject]@{Name='VRAM';Suffix='%';Color='#79C8D8';Points=$vramPoints;Latest=$vramLatest},
            [PSCustomObject]@{Name='TEMP';Suffix='°C';Color='#E4B64B';Points=$tempPoints;Latest=$gpuLatest.TemperatureC}
        )
        $subtitle = "显存 {0:0.0}/{1:0.0} GB · 功耗 {2:0}/{3:0} W · 风扇 {4:0}%" -f ([double]$gpuLatest.MemoryUsedMiB/1024),([double]$gpuLatest.MemoryTotalMiB/1024),$gpuLatest.PowerDrawW,$gpuLatest.PowerLimitW,$gpuLatest.FanPercent
        [void]$wrap.Children.Add((New-HistoryChartCard -Title ("GPU {0}" -f $gpuIndex) -Subtitle $subtitle -Series $series -Start $Start -End $End -UserPoints $vramUserPoints -UserKind GpuMemory -UserParentSeries VRAM -ChartKey "$ServerId/gpu/$gpuIndex/vram" -SelectionStore $SelectionStore))
    }
    [void]$stack.Children.Add($wrap); $surface.Child=$stack; [void]$Panel.Children.Add($surface)
}

function Save-HistoryWindowScreenshot {
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][string]$Path)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($Window)
    $width = [Math]::Max(1,[int]($Window.ActualWidth*$dpi.DpiScaleX)); $height = [Math]::Max(1,[int]($Window.ActualHeight*$dpi.DpiScaleY))
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $visual = [Windows.Media.DrawingVisual]::new(); $context=$visual.RenderOpen()
    $context.PushTransform([Windows.Media.ScaleTransform]::new($dpi.DpiScaleX,$dpi.DpiScaleY))
    $context.DrawRectangle([Windows.Media.VisualBrush]::new($Window),$null,[Windows.Rect]::new(0,0,$Window.ActualWidth,$Window.ActualHeight))
    $context.Pop(); $context.Close(); $bitmap.Render($visual)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($Path); try{$encoder.Save($stream)}finally{$stream.Dispose()}
}

function Register-HistoryWindowCloseButton {
    param([Parameter(Mandatory)]$Button)

    $Button.Add_Click({
        param($sender,$event)
        $targetWindow=[Windows.Window]::GetWindow($sender)
        if ($null -ne $targetWindow) { $targetWindow.Close() }
    })
}

function Register-HistoryWindowDragArea {
    param([Parameter(Mandatory)]$DragArea)

    $DragArea.Tag=[PSCustomObject]@{Active=$false;Cursor=$null;Left=0.0;Top=0.0;ScaleX=1.0;ScaleY=1.0}
    $DragArea.Add_MouseLeftButtonDown({
        param($sender,$event)
        if ($event.ChangedButton -ne 'Left') { return }
        $state=$sender.Tag; $targetWindow=[Windows.Window]::GetWindow($sender)
        if ($null -eq $state -or $null -eq $targetWindow) { return }
        $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($targetWindow)
        $state.Active=$true; $state.Cursor=[Windows.Forms.Cursor]::Position; $state.Left=$targetWindow.Left; $state.Top=$targetWindow.Top; $state.ScaleX=$dpi.DpiScaleX; $state.ScaleY=$dpi.DpiScaleY
        [void][Windows.Input.Mouse]::Capture($sender); $event.Handled=$true
    })
    $DragArea.Add_MouseMove({
        param($sender,$event)
        $state=$sender.Tag
        if ($null -eq $state -or -not $state.Active) { return }
        $targetWindow=[Windows.Window]::GetWindow($sender)
        if ($null -eq $targetWindow) { return }
        $cursor=[Windows.Forms.Cursor]::Position
        $targetWindow.Left=$state.Left+(($cursor.X-$state.Cursor.X)/$state.ScaleX)
        $targetWindow.Top=$state.Top+(($cursor.Y-$state.Cursor.Y)/$state.ScaleY)
    })
    $DragArea.Add_MouseLeftButtonUp({
        param($sender,$event)
        if ($null -ne $sender.Tag) { $sender.Tag.Active=$false }
        [void][Windows.Input.Mouse]::Capture($null)
    })
    $DragArea.Add_LostMouseCapture({ param($sender,$event); if ($null -ne $sender.Tag) { $sender.Tag.Active=$false } })
    return $DragArea.Tag
}

function Show-ServerPulseHistoryWindow {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)]$Recorder,
        [string]$ScreenshotPath,
        [switch]$SmokeTest
    )

    [xml]$historyXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server Pulse · 占用记录" Width="940" Height="710" MinWidth="760" MinHeight="500"
        WindowStyle="None" ResizeMode="CanResizeWithGrip" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterOwner" FontFamily="Bahnschrift, Microsoft YaHei UI" Foreground="#E7EBE8">
  <Window.Resources>
    <Style x:Key="HistoryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#BAC3BD"/><Setter Property="Background" Value="#202622"/>
      <Setter Property="BorderBrush" Value="#38413B"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="26"/><Setter Property="Padding" Value="10,0"/><Setter Property="FontSize" Value="9"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="HistoryInput" TargetType="TextBox">
      <Setter Property="Height" Value="26"/><Setter Property="Foreground" Value="#D4DBD7"/>
      <Setter Property="Background" Value="#171C19"/><Setter Property="BorderBrush" Value="#39413C"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="0"/><Setter Property="TextAlignment" Value="Center"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="FontSize" Value="9"/>
    </Style>
  </Window.Resources>
  <Border Background="#FA0D100E" BorderBrush="#3A423D" BorderThickness="1" CornerRadius="12">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="46"/><RowDefinition Height="94"/><RowDefinition Height="*"/><RowDefinition Height="24"/></Grid.RowDefinitions>
      <Grid Margin="14,5,8,3">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions>
        <Grid x:Name="HistoryDragArea" Grid.Column="0" Background="Transparent">
          <TextBlock Text="占用记录" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock Text="MINUTE ARCHIVE" FontSize="8" Foreground="#66716A" Margin="76,0,0,0" VerticalAlignment="Center"/>
        </Grid>
        <Button x:Name="HistoryCloseButton" Grid.Column="1" Content="×" Width="34" Height="30" Background="Transparent" BorderThickness="0" Foreground="#8C9690" FontSize="14" Cursor="Hand"/>
      </Grid>
      <Border Grid.Row="1" BorderBrush="#252B27" BorderThickness="0,1,0,1" Padding="14,0">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="47"/><RowDefinition Height="47"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="开始" FontSize="9" Foreground="#8C9790" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,9,0"/>
            <TextBox x:Name="HistoryStartYearBox" Style="{StaticResource HistoryInput}" Width="44" MaxLength="4"/>
            <TextBlock x:Name="HistoryStartYearError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="年" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryStartMonthBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryStartMonthError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="月" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryStartDayBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryStartDayError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="日" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryStartHourBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryStartHourError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="时" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryStartMinuteBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryStartMinuteError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="分" FontSize="8" Foreground="#707B74" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Grid.Row="1" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="结束" FontSize="9" Foreground="#8C9790" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,9,0"/>
            <TextBox x:Name="HistoryEndYearBox" Style="{StaticResource HistoryInput}" Width="44" MaxLength="4"/>
            <TextBlock x:Name="HistoryEndYearError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="年" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryEndMonthBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryEndMonthError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="月" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryEndDayBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryEndDayError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="日" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryEndHourBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryEndHourError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="时" FontSize="8" Foreground="#707B74" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="HistoryEndMinuteBox" Style="{StaticResource HistoryInput}" Width="28" MaxLength="2"/>
            <TextBlock x:Name="HistoryEndMinuteError" Text="!" Foreground="#FF5E5E" FontWeight="Bold" FontSize="11" Visibility="Collapsed" VerticalAlignment="Center" Margin="2,0,2,0"/><TextBlock Text="分" FontSize="8" Foreground="#707B74" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Grid.RowSpan="2" VerticalAlignment="Center" Margin="14,0,0,0">
            <TextBlock x:Name="HistoryRangeStatus" Text="" HorizontalAlignment="Right" FontSize="8" Foreground="#78837C" Margin="0,0,0,7"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="HistoryQueryButton" Content="查询" Style="{StaticResource HistoryButton}"/>
              <Button x:Name="HistoryHourButton" Content="最近 1 小时" Style="{StaticResource HistoryButton}" Margin="6,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Border>
      <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="12">
        <StackPanel x:Name="HistoryPanel"/>
      </ScrollViewer>
      <Grid Grid.Row="3" Margin="14,0,8,0">
        <TextBlock x:Name="HistoryFooterText" Text="默认显示最近一小时 · 分钟平均值" FontSize="8" Foreground="#56605A" VerticalAlignment="Center"/>
        <ResizeGrip HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="14" Height="14" Foreground="#69736D"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($historyXaml)
    $historyWindow = [Windows.Markup.XamlReader]::Load($reader)
    $historyWindow.Owner = $Owner; $historyWindow.Topmost = $Owner.Topmost
    $names = @('HistoryDragArea','HistoryCloseButton','HistoryQueryButton','HistoryHourButton','HistoryRangeStatus','HistoryPanel','HistoryFooterText')
    foreach ($prefix in @('HistoryStart','HistoryEnd')) {
        foreach ($field in @('Year','Month','Day','Hour','Minute')) { $names += "${prefix}${field}Box"; $names += "${prefix}${field}Error" }
    }
    $historyUi = @{}; foreach ($name in $names) { $historyUi[$name] = $historyWindow.FindName($name) }
    foreach ($prefix in @('HistoryStart','HistoryEnd')) {
        $historyUi["${prefix}YearBox"].ToolTip='2000–9999'; $historyUi["${prefix}MonthBox"].ToolTip='1–12'
        $historyUi["${prefix}DayBox"].ToolTip='按年、月校验实际天数'; $historyUi["${prefix}HourBox"].ToolTip='0–23'; $historyUi["${prefix}MinuteBox"].ToolTip='0–59'
    }

    $end = [DateTime]::Now; $end = [datetime]::new($end.Year,$end.Month,$end.Day,$end.Hour,$end.Minute,0)
    $start = $end.AddHours(-1)
    Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryStart' -Value $start
    Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryEnd' -Value $end
    $historySelectionStore=@{}

    $renderCore = {
        $startResult = Set-HistoryDateInputValidation -Ui $historyUi -Prefix 'HistoryStart'
        $endResult = Set-HistoryDateInputValidation -Ui $historyUi -Prefix 'HistoryEnd'
        if ($null -eq $startResult.Value -or $null -eq $endResult.Value) {
            $historyUi.HistoryRangeStatus.Text='请修正红色时间字段'; $historyUi.HistoryRangeStatus.Foreground=New-HistoryBrush '#FF5E5E'; return
        }
        $rangeStart = $startResult.Value; $rangeEnd = $endResult.Value
        if ($rangeEnd -lt $rangeStart) {
            $historyUi.HistoryRangeStatus.Text='结束时间不能早于开始时间'; $historyUi.HistoryRangeStatus.Foreground=New-HistoryBrush '#FF7B72'; return
        }
        $records = @(Get-ServerPulseHistoryRecords -Recorder $Recorder -Start $rangeStart -End $rangeEnd)
        $historyUi.HistoryPanel.Children.Clear()
        if ($records.Count -eq 0) {
            $empty = New-HistoryText '所选时间段暂无记录' 14 '#7B867F'; $empty.HorizontalAlignment='Center'; $empty.Margin=[Windows.Thickness]::new(0,90,0,0)
            [void]$historyUi.HistoryPanel.Children.Add($empty)
        } else {
            $serverIds = @($records | ForEach-Object { @($_.Servers) } | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
            foreach ($serverId in $serverIds) { Add-HistoryServerSection -Panel $historyUi.HistoryPanel -Records $records -ServerId $serverId -Start $rangeStart -End $rangeEnd -SelectionStore $historySelectionStore }
        }
        $minutes = [Math]::Max(0,[int][Math]::Round(($rangeEnd-$rangeStart).TotalMinutes))
        $historyUi.HistoryRangeStatus.Text="$($records.Count) 个分钟点 · $minutes 分钟"; $historyUi.HistoryRangeStatus.Foreground=New-HistoryBrush '#78837C'
        $historyUi.HistoryFooterText.Text='本地按分钟平均保存 CPU、MEM、LOAD、GPU、显存、温度、功耗与风扇'
    }.GetNewClosure()
    $render = {
        try { & $renderCore }
        catch {
            $message=[string]$_.Exception.Message
            if ($message.Length -gt 140) { $message=$message.Substring(0,137) + '...' }
            $historyUi.HistoryPanel.Children.Clear()
            $errorText=New-HistoryText ("无法读取占用记录`n{0}" -f $message) 12 '#FF8A80'
            $errorText.TextAlignment='Center'; $errorText.TextWrapping='Wrap'; $errorText.HorizontalAlignment='Center'; $errorText.Margin=[Windows.Thickness]::new(18,90,18,0)
            [void]$historyUi.HistoryPanel.Children.Add($errorText)
            $historyUi.HistoryRangeStatus.Text='查询失败'; $historyUi.HistoryRangeStatus.Foreground=New-HistoryBrush '#FF5E5E'
            $historyUi.HistoryFooterText.Text='请检查本地历史记录文件后重试'
        }
    }.GetNewClosure()
    [void](Register-HistoryWindowDragArea -DragArea $historyUi.HistoryDragArea)
    Register-HistoryWindowCloseButton -Button $historyUi.HistoryCloseButton
    Register-HistoryWindowChartEscape -Window $historyWindow -Panel $historyUi.HistoryPanel
    $historyUi.HistoryQueryButton.Add_Click($render)
    $historyUi.HistoryHourButton.Add_Click({ $now=[DateTime]::Now;$now=[datetime]::new($now.Year,$now.Month,$now.Day,$now.Hour,$now.Minute,0);Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryStart' -Value $now.AddHours(-1);Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryEnd' -Value $now;&$render }.GetNewClosure())
    foreach ($prefix in @('HistoryStart','HistoryEnd')) {
        foreach ($field in @('Year','Month','Day','Hour','Minute')) {
            $currentPrefix = $prefix
            $box = $historyUi["${prefix}${field}Box"]
            $box.Add_TextChanged({ [void](Set-HistoryDateInputValidation -Ui $historyUi -Prefix $currentPrefix) }.GetNewClosure())
            $box.Add_PreviewKeyDown({ param($sender,$event); if($event.Key -eq 'Enter'){&$render;$event.Handled=$true} }.GetNewClosure())
        }
    }
    &$render
    if ($SmokeTest) {
        $historyWindow.Show(); $historyWindow.UpdateLayout()
        $originalHistoryDirectory=$Recorder.Directory
        $invalidHistoryDirectory=Join-Path ([IO.Path]::GetTempPath()) ("serverpulse-invalid-history-{0}" -f [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $invalidHistoryDirectory)
        Set-Content -LiteralPath (Join-Path $invalidHistoryDirectory ($end.ToString('yyyy-MM-dd') + '.json')) -Value '{ invalid json' -Encoding UTF8
        $queryState=[PSCustomObject]@{Button=$historyUi.HistoryQueryButton;Completed=$false;Passed=$true;Error=$null}
        try {
            $Recorder.Directory=$invalidHistoryDirectory
            [void]$historyWindow.Dispatcher.BeginInvoke([Action]{
                try { $queryState.Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                catch { $queryState.Passed=$false; $queryState.Error=$_.Exception.Message }
                finally { $queryState.Completed=$true }
            }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Background)
            $queryDeadline=[DateTime]::UtcNow.AddSeconds(3)
            while (-not $queryState.Completed -and [DateTime]::UtcNow -lt $queryDeadline) {
                $frame=[Windows.Threading.DispatcherFrame]::new()
                [void]$historyWindow.Dispatcher.BeginInvoke([Action]{ $frame.Continue=$false }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::ApplicationIdle)
                [Windows.Threading.Dispatcher]::PushFrame($frame)
            }
            if (-not $queryState.Completed) { $queryState.Passed=$false; $queryState.Error='异步查询点击超时' }
            $queryClickPassed=$queryState.Passed; $queryClickError=$queryState.Error
            $queryFailureContained=($queryClickPassed -and $historyUi.HistoryRangeStatus.Text -eq '查询失败' -and $historyUi.HistoryPanel.Children.Count -eq 1)
        } finally {
            $Recorder.Directory=$originalHistoryDirectory
            Remove-Item -LiteralPath $invalidHistoryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryStart' -Value $start.AddMinutes(1)
        Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryEnd' -Value $end
        $changedQueryState=[PSCustomObject]@{Button=$historyUi.HistoryQueryButton;Completed=$false;Passed=$true;Error=$null}
        [void]$historyWindow.Dispatcher.BeginInvoke([Action]{
            try { $changedQueryState.Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
            catch { $changedQueryState.Passed=$false; $changedQueryState.Error=$_.Exception.Message }
            finally { $changedQueryState.Completed=$true }
        }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Background)
        $changedQueryDeadline=[DateTime]::UtcNow.AddSeconds(3)
        while (-not $changedQueryState.Completed -and [DateTime]::UtcNow -lt $changedQueryDeadline) {
            $changedQueryFrame=[Windows.Threading.DispatcherFrame]::new()
            [void]$historyWindow.Dispatcher.BeginInvoke([Action]{ $changedQueryFrame.Continue=$false }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::ApplicationIdle)
            [Windows.Threading.Dispatcher]::PushFrame($changedQueryFrame)
        }
        if (-not $changedQueryState.Completed) { $changedQueryState.Passed=$false; $changedQueryState.Error='修改时间后的异步查询点击超时' }
        $changedRangeQueryPassed=($changedQueryState.Passed -and $historyWindow.IsVisible)
        $historyUi.HistoryStartMonthBox.Text='13'; $invalidResult=Set-HistoryDateInputValidation -Ui $historyUi -Prefix 'HistoryStart'
        $validationPassed=($null -eq $invalidResult.Value -and $historyUi.HistoryStartMonthError.Visibility -eq 'Visible' -and $historyUi.HistoryStartMonthBox.BorderBrush.ToString() -eq '#FFFF5E5E')
        Set-HistoryDateFields -Ui $historyUi -Prefix 'HistoryStart' -Value $start; &$render; $historyWindow.UpdateLayout()
        $normalRenderPassed=($historyUi.HistoryRangeStatus.Text -ne '查询失败')
        $hoverTestTime=$start.AddMinutes(30)
        $hoverTestSeries=@(
            [PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Latest=72;Points=@([PSCustomObject]@{Time=$hoverTestTime;Value=72})},
            [PSCustomObject]@{Name='VRAM';Suffix='%';Color='#79C8D8';Latest=48;Points=@([PSCustomObject]@{Time=$hoverTestTime;Value=48})},
            [PSCustomObject]@{Name='TEMP';Suffix='°C';Color='#E4B64B';Latest=61;Points=@([PSCustomObject]@{Time=$hoverTestTime;Value=61})}
        )
        $hoverTestCard=New-HistoryChartCard -Title 'HOVER TEST' -Subtitle '' -Series $hoverTestSeries -Start $start -End $end
        [void]$historyUi.HistoryPanel.Children.Add($hoverTestCard); $historyWindow.UpdateLayout()
        $hoverInteractionPassed=$false; $hoverInteractionError=$null
        try {
            $mouseMove=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $mouseMove.RoutedEvent=[Windows.UIElement]::MouseMoveEvent
            $hoverTestCard.Tag.Canvas.RaiseEvent($mouseMove)
            $visibleMarkers=@($hoverTestCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count
            $visibleRows=@($hoverTestCard.Tag.Views | Where-Object { $_.PopupRow.Visibility -eq 'Visible' })
            $shown=($visibleMarkers -eq 3 -and $visibleRows.Count -eq 3 -and $hoverTestCard.Tag.Popup.Visibility -eq 'Visible' -and $hoverTestCard.Tag.TimeBlock.Text -eq $hoverTestTime.ToString('yyyy-MM-dd HH:mm') -and $visibleRows[0].PopupText.Text -match '^GPU' -and $visibleRows[1].PopupText.Text -match '^VRAM' -and $visibleRows[2].PopupText.Text -match '^TEMP')
            $vramView=$hoverTestCard.Tag.Views[1]; $toggleDown=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left); $toggleDown.RoutedEvent=[Windows.UIElement]::MouseLeftButtonDownEvent; $vramView.Toggle.RaiseEvent($toggleDown); $hoverTestCard.Tag.Canvas.RaiseEvent($mouseMove)
            $togglePassed=(-not $vramView.IsVisible -and $vramView.Line.Visibility -eq 'Collapsed' -and @($hoverTestCard.Tag.Markers | Where-Object { $_.Shape.Visibility -eq 'Visible' }).Count -eq 2 -and @($hoverTestCard.Tag.Views | Where-Object { $_.PopupRow.Visibility -eq 'Visible' }).Count -eq 2)
            $mouseLeave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $mouseLeave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent
            $hoverTestCard.Tag.Canvas.RaiseEvent($mouseLeave)
            $hidden=(@($hoverTestCard.Tag.Markers | Where-Object { $_.Shape.Visibility -ne 'Collapsed' }).Count -eq 0 -and $hoverTestCard.Tag.Popup.Visibility -eq 'Collapsed')
            $hoverInteractionPassed=($shown -and $togglePassed -and $hidden)
        } catch { $hoverInteractionError=$_.Exception.Message }
        [void]$historyUi.HistoryPanel.Children.Remove($hoverTestCard)
        if ($ScreenshotPath) { Save-HistoryWindowScreenshot -Window $historyWindow -Path $ScreenshotPath }
        $startValue=(Set-HistoryDateInputValidation -Ui $historyUi -Prefix 'HistoryStart').Value; $endValue=(Set-HistoryDateInputValidation -Ui $historyUi -Prefix 'HistoryEnd').Value
        $closeCenter=$historyUi.HistoryCloseButton.TransformToAncestor($historyWindow).Transform([Windows.Point]::new($historyUi.HistoryCloseButton.ActualWidth/2,$historyUi.HistoryCloseButton.ActualHeight/2))
        $closeHit=$historyWindow.InputHitTest($closeCenter); $closeHitNode=$closeHit
        while ($null -ne $closeHitNode -and $closeHitNode -ne $historyUi.HistoryCloseButton) { $closeHitNode=[Windows.Media.VisualTreeHelper]::GetParent($closeHitNode) }
        $closeHitTestPassed=($closeHitNode -eq $historyUi.HistoryCloseButton)
        $closeHitElement=if($null -ne $closeHit){"$($closeHit.GetType().Name):$($closeHit.Name)"}else{'none'}
        $closeAncestor=$historyUi.HistoryCloseButton; $closeSeparatedFromDragArea=$true
        while ($null -ne $closeAncestor) {
            if ($closeAncestor -eq $historyUi.HistoryDragArea) { $closeSeparatedFromDragArea=$false; break }
            $closeAncestor=[Windows.Media.VisualTreeHelper]::GetParent($closeAncestor)
        }
        $historyWindow.Hide()
        $script:historyCloseSmokeState=[PSCustomObject]@{Button=$historyUi.HistoryCloseButton;Window=$historyWindow;Completed=$false;ClosedByHandler=$false;Error=$null}
        [void]$historyWindow.Dispatcher.BeginInvoke([Action]{
            try { $script:historyCloseSmokeState.Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
            catch { $script:historyCloseSmokeState.Error=$_.Exception.Message }
            finally {
                $script:historyCloseSmokeState.ClosedByHandler=-not $script:historyCloseSmokeState.Window.IsVisible
                $script:historyCloseSmokeState.Completed=$true
                if ($script:historyCloseSmokeState.Window.IsVisible) { $script:historyCloseSmokeState.Window.Close() }
            }
        },[Windows.Threading.DispatcherPriority]::Background)
        [void]$historyWindow.ShowDialog()
        $closeButtonPassed=($script:historyCloseSmokeState.Completed -and $script:historyCloseSmokeState.ClosedByHandler)
        $closeButtonError=$script:historyCloseSmokeState.Error
        Remove-Variable -Name historyCloseSmokeState -Scope Script -ErrorAction SilentlyContinue
        $result=[PSCustomObject]@{PanelCount=$historyUi.HistoryPanel.Children.Count;Status=[string]$historyUi.HistoryRangeStatus.Text;Start=$startValue.ToString('yyyy-MM-dd HH:mm');End=$endValue.ToString('yyyy-MM-dd HH:mm');ValidationPassed=$validationPassed;QueryClickPassed=$queryClickPassed;QueryClickError=$queryClickError;QueryFailureContained=$queryFailureContained;ChangedRangeQueryPassed=$changedRangeQueryPassed;ChangedRangeQueryError=$changedQueryState.Error;NormalRenderPassed=$normalRenderPassed;HoverInteractionPassed=$hoverInteractionPassed;HoverInteractionError=$hoverInteractionError;CloseButtonPassed=$closeButtonPassed;CloseButtonError=$closeButtonError;CloseHitTestPassed=$closeHitTestPassed;CloseHitElement=$closeHitElement;CloseSeparatedFromDragArea=$closeSeparatedFromDragArea}
        return $result
    }
    [void]$historyWindow.ShowDialog()
}
