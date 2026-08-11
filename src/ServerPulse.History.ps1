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
            [PSCustomObject]@{
                Index          = [int]$last.Index
                Name           = [string]$last.Name
                Uuid           = [string]$last.Uuid
                Utilization    = Get-HistoryAverage $items @('Utilization')
                MemoryUsedMiB  = Get-HistoryAverage $items @('MemoryUsedMiB')
                MemoryTotalMiB = Get-HistoryAverage $items @('MemoryTotalMiB')
                TemperatureC   = Get-HistoryAverage $items @('TemperatureC')
                PowerDrawW     = Get-HistoryAverage $items @('PowerDrawW')
                PowerLimitW    = Get-HistoryAverage $items @('PowerLimitW')
                FanPercent     = Get-HistoryAverage $items @('FanPercent')
            }
        }
        [PSCustomObject]@{
            Id            = [string]$latest.Id
            Label         = [string]$latest.Label
            Host          = [string]$latest.Host
            OnlineSamples = $onlineSamples.Count
            TotalSamples  = $samples.Count
            LatencyMs     = Get-HistoryAverage $onlineSamples @('LatencyMs')
            Hostname      = [string](Get-HistoryLastValue $onlineSamples @('Metrics','Hostname'))
            CpuPercent    = Get-HistoryAverage $onlineSamples @('Metrics','Cpu','Utilization')
            MemoryUsedMiB = Get-HistoryAverage $onlineSamples @('Metrics','Memory','UsedMiB')
            MemoryTotalMiB= Get-HistoryAverage $onlineSamples @('Metrics','Memory','TotalMiB')
            MemoryPercent = Get-HistoryAverage $onlineSamples @('Metrics','Memory','Percent')
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
    }
}

function Save-HistoryMinuteRecord {
    param(
        [Parameter(Mandatory)]$Recorder,
        [Parameter(Mandatory)]$Record
    )

    if (-not (Test-Path -LiteralPath $Recorder.Directory)) {
        [void](New-Item -ItemType Directory -Path $Recorder.Directory)
    }
    $date = [datetime]::ParseExact([string]$Record.Timestamp, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $path = Join-Path $Recorder.Directory ($date.ToString('yyyy-MM-dd') + '.json')
    $records = @()
    if (Test-Path -LiteralPath $path) {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $records = @($saved.Records | Where-Object { $_.Timestamp -ne $Record.Timestamp })
    }
    $records = @($records + $Record | Sort-Object Timestamp)
    [PSCustomObject]@{ Version=1; Date=$date.ToString('yyyy-MM-dd'); Records=$records } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
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
    foreach ($file in (Get-ChildItem -LiteralPath $Recorder.Directory -File -Filter '*.json')) {
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact($file.BaseName, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date) -and $date -lt $cutoff) {
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
        $path = Join-Path $Recorder.Directory ($date.ToString('yyyy-MM-dd') + '.json')
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($record in @($saved.Records)) { $byMinute[[string]$record.Timestamp] = $record }
    }
    $current = Get-CurrentHistoryMinuteRecord $Recorder
    if ($null -ne $current) { $byMinute[[string]$current.Timestamp] = $current }
    return @($byMinute.Values | Where-Object {
        $timestamp = [datetime]::ParseExact([string]$_.Timestamp, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
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
    return [datetime]::ParseExact([string]$Record.Timestamp, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-HistoryNearestChartPoint {
    param(
        [Parameter(Mandatory)][object[]]$Series,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End,
        [Parameter(Mandatory)][double]$CursorX,
        [Parameter(Mandatory)][double]$CursorY,
        [double]$Width=242,
        [double]$Height=76
    )

    $duration=[Math]::Max(60.0,($End-$Start).TotalSeconds)
    $plotBottom=[Math]::Max(4.0,$Height-2.0)
    $plotHeight=[Math]::Max(1.0,$Height-6.0)
    $nearest=$null; $nearestDistance=[double]::PositiveInfinity
    foreach ($item in $Series) {
        foreach ($point in @($item.Points)) {
            if ($null -eq $point.Value) { continue }
            $x=[Math]::Max(0,[Math]::Min($Width,(($point.Time-$Start).TotalSeconds/$duration)*$Width))
            $value=[Math]::Max(0,[Math]::Min(100,[double]$point.Value))
            $y=$plotBottom-($value/100*$plotHeight)
            $distance=[Math]::Pow($x-$CursorX,2)+[Math]::Pow($y-$CursorY,2)
            if ($distance -lt $nearestDistance) {
                $suffix=if($item.PSObject.Properties.Name -contains 'Suffix'){[string]$item.Suffix}else{''}
                $nearestDistance=$distance
                $nearest=[PSCustomObject]@{Name=[string]$item.Name;Suffix=$suffix;Color=[string]$item.Color;Time=[datetime]$point.Time;Value=[double]$point.Value;X=$x;Y=$y;DistanceSquared=$distance}
            }
        }
    }
    return $nearest
}

function New-HistoryChartCard {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle,
        [Parameter(Mandatory)][object[]]$Series,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End
    )

    $card = [Windows.Controls.Border]::new()
    $card.Width = 264; $card.Height = 142
    $card.Margin = [Windows.Thickness]::new(0,0,8,8)
    $card.Padding = [Windows.Thickness]::new(10,8,10,8)
    $card.Background = New-HistoryBrush '#1B201D'
    $card.BorderBrush = New-HistoryBrush '#303732'
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(7)

    $layout = [Windows.Controls.Grid]::new()
    $row1 = [Windows.Controls.RowDefinition]::new(); $row1.Height = 'Auto'
    $row2 = [Windows.Controls.RowDefinition]::new(); $row2.Height = '*'
    $row3 = [Windows.Controls.RowDefinition]::new(); $row3.Height = 'Auto'
    [void]$layout.RowDefinitions.Add($row1); [void]$layout.RowDefinitions.Add($row2); [void]$layout.RowDefinitions.Add($row3)

    $header = [Windows.Controls.Grid]::new()
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $rightColumn = [Windows.Controls.ColumnDefinition]::new(); $rightColumn.Width = 'Auto'; [void]$header.ColumnDefinitions.Add($rightColumn)
    $titleBlock = New-HistoryText $Title 10 '#E1E6E3'; $titleBlock.FontWeight = 'SemiBold'
    $latestParts = @($Series | ForEach-Object {
        if ($null -ne $_.Latest) {
            $suffix = if ($_.PSObject.Properties.Name -contains 'Suffix') { [string]$_.Suffix } else { '' }
            "{0} {1:0}{2}" -f $_.Name, [double]$_.Latest, $suffix
        }
    })
    $latestBlock = New-HistoryText ($latestParts -join ' · ') 8 '#98A39C'; $latestBlock.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($latestBlock,1)
    [void]$header.Children.Add($titleBlock); [void]$header.Children.Add($latestBlock)
    [Windows.Controls.Grid]::SetRow($header,0); [void]$layout.Children.Add($header)

    $canvas = [Windows.Controls.Canvas]::new(); $canvas.Width = 242; $canvas.Height = 76; $canvas.Margin = [Windows.Thickness]::new(0,7,0,5)
    $canvas.Background=New-HistoryBrush '#00131714'; $canvas.Cursor='Cross'; $canvas.ClipToBounds=$false
    foreach ($y in @(2.0,38.0,74.0)) {
        $line = [Windows.Shapes.Line]::new(); $line.X1=0; $line.X2=242; $line.Y1=$y; $line.Y2=$y
        $line.Stroke = New-HistoryBrush '#2B312D'; $line.StrokeThickness=1
        [void]$canvas.Children.Add($line)
    }
    $duration = [Math]::Max(60.0, ($End - $Start).TotalSeconds)
    foreach ($item in $Series) {
        $polyline = [Windows.Shapes.Polyline]::new()
        $polyline.Stroke = New-HistoryBrush ([string]$item.Color)
        $polyline.StrokeThickness = 1.8
        $polyline.StrokeLineJoin = 'Round'
        $points = [Windows.Media.PointCollection]::new()
        foreach ($point in @($item.Points)) {
            if ($null -eq $point.Value) { continue }
            $x = [Math]::Max(0, [Math]::Min(242, (($point.Time - $Start).TotalSeconds / $duration) * 242))
            $value = [Math]::Max(0, [Math]::Min(100, [double]$point.Value))
            $y = 74 - ($value / 100 * 70)
            $points.Add([Windows.Point]::new($x,$y))
        }
        $polyline.Points = $points
        [void]$canvas.Children.Add($polyline)
        if ($points.Count -eq 1) {
            $dot = [Windows.Shapes.Ellipse]::new(); $dot.Width=4; $dot.Height=4; $dot.Fill=New-HistoryBrush ([string]$item.Color)
            [Windows.Controls.Canvas]::SetLeft($dot,$points[0].X-2); [Windows.Controls.Canvas]::SetTop($dot,$points[0].Y-2)
            [void]$canvas.Children.Add($dot)
        }
    }
    $hoverGuide=[Windows.Shapes.Line]::new(); $hoverGuide.Y1=2; $hoverGuide.Y2=74; $hoverGuide.Stroke=New-HistoryBrush '#6F7B73'; $hoverGuide.StrokeThickness=1; $hoverGuide.Opacity=0.7; $hoverGuide.Visibility='Collapsed'; $hoverGuide.IsHitTestVisible=$false
    $hoverDashes=[Windows.Media.DoubleCollection]::new(); $hoverDashes.Add(2.0); $hoverDashes.Add(3.0); $hoverGuide.StrokeDashArray=$hoverDashes; [Windows.Controls.Panel]::SetZIndex($hoverGuide,20); [void]$canvas.Children.Add($hoverGuide)
    $hoverMarker=[Windows.Shapes.Ellipse]::new(); $hoverMarker.Width=9; $hoverMarker.Height=9; $hoverMarker.Fill=New-HistoryBrush '#131714'; $hoverMarker.StrokeThickness=2; $hoverMarker.Visibility='Collapsed'; $hoverMarker.IsHitTestVisible=$false
    [Windows.Controls.Panel]::SetZIndex($hoverMarker,22); [void]$canvas.Children.Add($hoverMarker)
    $hoverPopup=[Windows.Controls.Border]::new(); $hoverPopup.Width=118; $hoverPopup.Height=37; $hoverPopup.Padding=[Windows.Thickness]::new(7,4,7,4); $hoverPopup.Background=New-HistoryBrush '#F20D110F'; $hoverPopup.BorderBrush=New-HistoryBrush '#455047'; $hoverPopup.BorderThickness=[Windows.Thickness]::new(1); $hoverPopup.CornerRadius=[Windows.CornerRadius]::new(5); $hoverPopup.Visibility='Collapsed'; $hoverPopup.IsHitTestVisible=$false
    $hoverPopup.Effect=[Windows.Media.Effects.DropShadowEffect]@{Color=[Windows.Media.Colors]::Black;BlurRadius=8;ShadowDepth=2;Opacity=0.45}
    $hoverStack=[Windows.Controls.StackPanel]::new(); $hoverTime=New-HistoryText '' 7 '#77837B'; $hoverValue=New-HistoryText '' 9 '#EDF2EF'; $hoverValue.FontWeight='SemiBold'; [void]$hoverStack.Children.Add($hoverTime); [void]$hoverStack.Children.Add($hoverValue); $hoverPopup.Child=$hoverStack
    [Windows.Controls.Panel]::SetZIndex($hoverPopup,24); [void]$canvas.Children.Add($hoverPopup)
    $hoverState=[PSCustomObject]@{Kind='HistoryChart';Canvas=$canvas;Guide=$hoverGuide;Marker=$hoverMarker;Popup=$hoverPopup;TimeBlock=$hoverTime;ValueBlock=$hoverValue;Series=$Series;Start=$Start;End=$End;Resolver=${function:Get-HistoryNearestChartPoint};BrushConverter=[Windows.Media.BrushConverter]::new()}
    $canvas.Tag=$hoverState; $card.Tag=$hoverState
    $canvas.Add_MouseMove({
        param($sender,$event)
        $cursor=$event.GetPosition($sender)
        $point=& $hoverState.Resolver -Series $hoverState.Series -Start $hoverState.Start -End $hoverState.End -CursorX $cursor.X -CursorY $cursor.Y -Width $sender.Width -Height $sender.Height
        if ($null -eq $point) { return }
        $hoverState.Guide.X1=$point.X; $hoverState.Guide.X2=$point.X
        [Windows.Controls.Canvas]::SetLeft($hoverState.Marker,$point.X-4.5); [Windows.Controls.Canvas]::SetTop($hoverState.Marker,$point.Y-4.5)
        $hoverState.Marker.Stroke=$hoverState.BrushConverter.ConvertFromString($point.Color)
        $hoverState.TimeBlock.Text=$point.Time.ToString('MM-dd HH:mm')
        $hoverState.ValueBlock.Text=("{0}  {1:0.##}{2}" -f $point.Name,$point.Value,$point.Suffix)
        $popupLeft=if($point.X -gt 120){$point.X-124}else{$point.X+7}; [Windows.Controls.Canvas]::SetLeft($hoverState.Popup,[Math]::Max(0,[Math]::Min(124,$popupLeft))); [Windows.Controls.Canvas]::SetTop($hoverState.Popup,4)
        $hoverState.Guide.Visibility='Visible'; $hoverState.Marker.Visibility='Visible'; $hoverState.Popup.Visibility='Visible'
    }.GetNewClosure())
    $canvas.Add_MouseLeave({ $hoverState.Guide.Visibility='Collapsed'; $hoverState.Marker.Visibility='Collapsed'; $hoverState.Popup.Visibility='Collapsed' }.GetNewClosure())
    [Windows.Controls.Grid]::SetRow($canvas,1); [void]$layout.Children.Add($canvas)

    $footer = [Windows.Controls.Grid]::new()
    $subtitleBlock = New-HistoryText $Subtitle 7 '#66716A'; $subtitleBlock.TextTrimming = 'CharacterEllipsis'
    $endBlock = New-HistoryText ($End.ToString('MM-dd HH:mm')) 7 '#505A54'; $endBlock.HorizontalAlignment = 'Right'
    [void]$footer.Children.Add($subtitleBlock); [void]$footer.Children.Add($endBlock)
    [Windows.Controls.Grid]::SetRow($footer,2); [void]$layout.Children.Add($footer)
    $card.Child = $layout
    return $card
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
        [Parameter(Mandatory)][datetime]$End
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
    $cpuSeries = @([PSCustomObject]@{Name='CPU';Suffix='%';Color='#A7D948';Points=$cpuPoints;Latest=$latest.CpuPercent})
    $memorySeries = @([PSCustomObject]@{Name='MEM';Suffix='%';Color='#A7D948';Points=$memoryPoints;Latest=$latest.MemoryPercent})
    [void]$wrap.Children.Add((New-HistoryChartCard -Title 'CPU' -Subtitle ("LOAD 1/5/15 {0:0.00}/{1:0.00}/{2:0.00} · SSH {3:0} ms" -f $latest.LoadOne,$latest.LoadFive,$latest.LoadFifteen,$latest.LatencyMs) -Series $cpuSeries -Start $Start -End $End))
    [void]$wrap.Children.Add((New-HistoryChartCard -Title 'MEM' -Subtitle ("{0:0.0}/{1:0.0} GB · UPTIME {2:0.0} d" -f ([double]$latest.MemoryUsedMiB/1024),([double]$latest.MemoryTotalMiB/1024),([double]$latest.UptimeSeconds/86400)) -Series $memorySeries -Start $Start -End $End))

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
        $series = @(
            [PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Points=$utilPoints;Latest=$gpuLatest.Utilization},
            [PSCustomObject]@{Name='VRAM';Suffix='%';Color='#79C8D8';Points=$vramPoints;Latest=$vramLatest},
            [PSCustomObject]@{Name='TEMP';Suffix='°C';Color='#E4B64B';Points=$tempPoints;Latest=$gpuLatest.TemperatureC}
        )
        $subtitle = "显存 {0:0.0}/{1:0.0} GB · 功耗 {2:0}/{3:0} W · 风扇 {4:0}%" -f ([double]$gpuLatest.MemoryUsedMiB/1024),([double]$gpuLatest.MemoryTotalMiB/1024),$gpuLatest.PowerDrawW,$gpuLatest.PowerLimitW,$gpuLatest.FanPercent
        [void]$wrap.Children.Add((New-HistoryChartCard -Title ("GPU {0}" -f $gpuIndex) -Subtitle $subtitle -Series $series -Start $Start -End $End))
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
      <Grid x:Name="HistoryDragArea" Margin="14,5,8,3">
        <TextBlock Text="占用记录" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock Text="MINUTE ARCHIVE" FontSize="8" Foreground="#66716A" Margin="76,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="HistoryCloseButton" Content="×" Width="34" Height="30" HorizontalAlignment="Right" Background="Transparent" BorderThickness="0" Foreground="#8C9690" FontSize="14" Cursor="Hand"/>
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
    $ui = @{}; foreach ($name in $names) { $ui[$name] = $historyWindow.FindName($name) }
    foreach ($prefix in @('HistoryStart','HistoryEnd')) {
        $ui["${prefix}YearBox"].ToolTip='2000–9999'; $ui["${prefix}MonthBox"].ToolTip='1–12'
        $ui["${prefix}DayBox"].ToolTip='按年、月校验实际天数'; $ui["${prefix}HourBox"].ToolTip='0–23'; $ui["${prefix}MinuteBox"].ToolTip='0–59'
    }

    $end = [DateTime]::Now; $end = [datetime]::new($end.Year,$end.Month,$end.Day,$end.Hour,$end.Minute,0)
    $start = $end.AddHours(-1)
    Set-HistoryDateFields -Ui $ui -Prefix 'HistoryStart' -Value $start
    Set-HistoryDateFields -Ui $ui -Prefix 'HistoryEnd' -Value $end

    $renderCore = {
        $startResult = Set-HistoryDateInputValidation -Ui $ui -Prefix 'HistoryStart'
        $endResult = Set-HistoryDateInputValidation -Ui $ui -Prefix 'HistoryEnd'
        if ($null -eq $startResult.Value -or $null -eq $endResult.Value) {
            $ui.HistoryRangeStatus.Text='请修正红色时间字段'; $ui.HistoryRangeStatus.Foreground=New-HistoryBrush '#FF5E5E'; return
        }
        $rangeStart = $startResult.Value; $rangeEnd = $endResult.Value
        if ($rangeEnd -lt $rangeStart) {
            $ui.HistoryRangeStatus.Text='结束时间不能早于开始时间'; $ui.HistoryRangeStatus.Foreground=New-HistoryBrush '#FF7B72'; return
        }
        $records = @(Get-ServerPulseHistoryRecords -Recorder $Recorder -Start $rangeStart -End $rangeEnd)
        $ui.HistoryPanel.Children.Clear()
        if ($records.Count -eq 0) {
            $empty = New-HistoryText '所选时间段暂无记录' 14 '#7B867F'; $empty.HorizontalAlignment='Center'; $empty.Margin=[Windows.Thickness]::new(0,90,0,0)
            [void]$ui.HistoryPanel.Children.Add($empty)
        } else {
            $serverIds = @($records | ForEach-Object { @($_.Servers) } | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
            foreach ($serverId in $serverIds) { Add-HistoryServerSection -Panel $ui.HistoryPanel -Records $records -ServerId $serverId -Start $rangeStart -End $rangeEnd }
        }
        $minutes = [Math]::Max(0,[int][Math]::Round(($rangeEnd-$rangeStart).TotalMinutes))
        $ui.HistoryRangeStatus.Text="$($records.Count) 个分钟点 · $minutes 分钟"; $ui.HistoryRangeStatus.Foreground=New-HistoryBrush '#78837C'
        $ui.HistoryFooterText.Text='本地按分钟平均保存 CPU、MEM、LOAD、GPU、显存、温度、功耗与风扇'
    }.GetNewClosure()
    $render = {
        try { & $renderCore }
        catch {
            $message=[string]$_.Exception.Message
            if ($message.Length -gt 140) { $message=$message.Substring(0,137) + '...' }
            $ui.HistoryPanel.Children.Clear()
            $errorText=New-HistoryText ("无法读取占用记录`n{0}" -f $message) 12 '#FF8A80'
            $errorText.TextAlignment='Center'; $errorText.TextWrapping='Wrap'; $errorText.HorizontalAlignment='Center'; $errorText.Margin=[Windows.Thickness]::new(18,90,18,0)
            [void]$ui.HistoryPanel.Children.Add($errorText)
            $ui.HistoryRangeStatus.Text='查询失败'; $ui.HistoryRangeStatus.Foreground=New-HistoryBrush '#FF5E5E'
            $ui.HistoryFooterText.Text='请检查本地历史记录文件后重试'
        }
    }.GetNewClosure()
    $drag = [PSCustomObject]@{Active=$false;Cursor=$null;Left=0.0;Top=0.0;ScaleX=1.0;ScaleY=1.0}
    $ui.HistoryDragArea.Add_MouseLeftButtonDown({ param($sender,$event); if($event.ChangedButton -eq 'Left'){$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($historyWindow);$drag.Active=$true;$drag.Cursor=[Windows.Forms.Cursor]::Position;$drag.Left=$historyWindow.Left;$drag.Top=$historyWindow.Top;$drag.ScaleX=$dpi.DpiScaleX;$drag.ScaleY=$dpi.DpiScaleY;[void][Windows.Input.Mouse]::Capture($ui.HistoryDragArea);$event.Handled=$true} })
    $ui.HistoryDragArea.Add_MouseMove({ if($drag.Active -and [Windows.Input.Mouse]::LeftButton -eq 'Pressed'){$cursor=[Windows.Forms.Cursor]::Position;$historyWindow.Left=$drag.Left+(($cursor.X-$drag.Cursor.X)/$drag.ScaleX);$historyWindow.Top=$drag.Top+(($cursor.Y-$drag.Cursor.Y)/$drag.ScaleY)} })
    $ui.HistoryDragArea.Add_MouseLeftButtonUp({ $drag.Active=$false;[void][Windows.Input.Mouse]::Capture($null) })
    $ui.HistoryCloseButton.Add_Click({ $historyWindow.Close() })
    $ui.HistoryQueryButton.Add_Click($render)
    $ui.HistoryHourButton.Add_Click({ $now=[DateTime]::Now;$now=[datetime]::new($now.Year,$now.Month,$now.Day,$now.Hour,$now.Minute,0);Set-HistoryDateFields -Ui $ui -Prefix 'HistoryStart' -Value $now.AddHours(-1);Set-HistoryDateFields -Ui $ui -Prefix 'HistoryEnd' -Value $now;&$render }.GetNewClosure())
    foreach ($prefix in @('HistoryStart','HistoryEnd')) {
        foreach ($field in @('Year','Month','Day','Hour','Minute')) {
            $currentPrefix = $prefix
            $box = $ui["${prefix}${field}Box"]
            $box.Add_TextChanged({ [void](Set-HistoryDateInputValidation -Ui $ui -Prefix $currentPrefix) }.GetNewClosure())
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
        $queryState=[PSCustomObject]@{Button=$ui.HistoryQueryButton;Completed=$false;Passed=$true;Error=$null}
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
            $queryFailureContained=($queryClickPassed -and $ui.HistoryRangeStatus.Text -eq '查询失败' -and $ui.HistoryPanel.Children.Count -eq 1)
        } finally {
            $Recorder.Directory=$originalHistoryDirectory
            Remove-Item -LiteralPath $invalidHistoryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-HistoryDateFields -Ui $ui -Prefix 'HistoryStart' -Value $start.AddMinutes(1)
        Set-HistoryDateFields -Ui $ui -Prefix 'HistoryEnd' -Value $end
        $changedQueryState=[PSCustomObject]@{Button=$ui.HistoryQueryButton;Completed=$false;Passed=$true;Error=$null}
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
        $ui.HistoryStartMonthBox.Text='13'; $invalidResult=Set-HistoryDateInputValidation -Ui $ui -Prefix 'HistoryStart'
        $validationPassed=($null -eq $invalidResult.Value -and $ui.HistoryStartMonthError.Visibility -eq 'Visible' -and $ui.HistoryStartMonthBox.BorderBrush.ToString() -eq '#FFFF5E5E')
        Set-HistoryDateFields -Ui $ui -Prefix 'HistoryStart' -Value $start; &$render; $historyWindow.UpdateLayout()
        $normalRenderPassed=($ui.HistoryRangeStatus.Text -ne '查询失败')
        $hoverTestSeries=@([PSCustomObject]@{Name='GPU';Suffix='%';Color='#A7D948';Latest=72;Points=@([PSCustomObject]@{Time=$start.AddMinutes(30);Value=72})})
        $hoverTestCard=New-HistoryChartCard -Title 'HOVER TEST' -Subtitle '' -Series $hoverTestSeries -Start $start -End $end
        [void]$ui.HistoryPanel.Children.Add($hoverTestCard); $historyWindow.UpdateLayout()
        $hoverInteractionPassed=$false; $hoverInteractionError=$null
        try {
            $mouseMove=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $mouseMove.RoutedEvent=[Windows.UIElement]::MouseMoveEvent
            $hoverTestCard.Tag.Canvas.RaiseEvent($mouseMove)
            $shown=($hoverTestCard.Tag.Marker.Visibility -eq 'Visible' -and $hoverTestCard.Tag.Popup.Visibility -eq 'Visible' -and $hoverTestCard.Tag.ValueBlock.Text -match '^GPU')
            $mouseLeave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount); $mouseLeave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent
            $hoverTestCard.Tag.Canvas.RaiseEvent($mouseLeave)
            $hidden=($hoverTestCard.Tag.Marker.Visibility -eq 'Collapsed' -and $hoverTestCard.Tag.Popup.Visibility -eq 'Collapsed')
            $hoverInteractionPassed=($shown -and $hidden)
        } catch { $hoverInteractionError=$_.Exception.Message }
        [void]$ui.HistoryPanel.Children.Remove($hoverTestCard)
        if ($ScreenshotPath) { Save-HistoryWindowScreenshot -Window $historyWindow -Path $ScreenshotPath }
        $startValue=(Set-HistoryDateInputValidation -Ui $ui -Prefix 'HistoryStart').Value; $endValue=(Set-HistoryDateInputValidation -Ui $ui -Prefix 'HistoryEnd').Value
        $result=[PSCustomObject]@{PanelCount=$ui.HistoryPanel.Children.Count;Status=[string]$ui.HistoryRangeStatus.Text;Start=$startValue.ToString('yyyy-MM-dd HH:mm');End=$endValue.ToString('yyyy-MM-dd HH:mm');ValidationPassed=$validationPassed;QueryClickPassed=$queryClickPassed;QueryClickError=$queryClickError;QueryFailureContained=$queryFailureContained;ChangedRangeQueryPassed=$changedRangeQueryPassed;ChangedRangeQueryError=$changedQueryState.Error;NormalRenderPassed=$normalRenderPassed;HoverInteractionPassed=$hoverInteractionPassed;HoverInteractionError=$hoverInteractionError}
        $historyWindow.Close(); return $result
    }
    [void]$historyWindow.ShowDialog()
}
