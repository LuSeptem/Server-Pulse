Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:serverPulseThemeMode = 'dark'
$script:serverPulseResolvedTheme = 'dark'
$script:serverPulseThemeBrushes = [Collections.Generic.Dictionary[string,Windows.Media.SolidColorBrush]]::new([StringComparer]::OrdinalIgnoreCase)
$script:serverPulseDarkToLight = @{}
$script:serverPulseLightToDark = @{}

function Normalize-ServerPulseThemeMode {
    param([string]$Mode)
    $normalized = if ($null -eq $Mode) { '' } else { $Mode.Trim().ToLowerInvariant() }
    if ($normalized -notin @('light','dark','system')) { return 'dark' }
    return $normalized
}

function Get-ServerPulseSystemTheme {
    try {
        $value = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ([int]$value -eq 1) { return 'light' }
    } catch { }
    return 'dark'
}

function Resolve-ServerPulseTheme {
    param([string]$Mode, [ValidateSet('light','dark')][string]$SystemTheme)
    $normalized = Normalize-ServerPulseThemeMode $Mode
    if ($normalized -ne 'system') { return $normalized }
    if (-not [string]::IsNullOrWhiteSpace($SystemTheme)) { return $SystemTheme }
    return Get-ServerPulseSystemTheme
}

function Get-ServerPulseLightAccentColor {
    param([string]$Rgb)
    $accents = @{
        '#A7D948'='#5D8B18'; '#BCEB62'='#6B9820'; '#B9EC58'='#65941B'; '#91C235'='#4E7912'
        '#79C8D8'='#147B8E'; '#88C0D0'='#15778B'; '#81A1C1'='#356B98'; '#5E81AC'='#385F8C'
        '#E4B64B'='#9B6800'; '#E9C46A'='#9A6A0A'; '#F4A261'='#A65A18'; '#D08770'='#A14E38'
        '#FF6B6B'='#C43E43'; '#FF7B72'='#C7433C'; '#FF5E5E'='#C52F36'; '#FF8A80'='#C94E47'; '#FF9B93'='#B94D47'
        '#F07178'='#B83B49'; '#C678DD'='#8745A0'; '#B48EAD'='#76516F'; '#A3BE8C'='#4F7A3D'
    }
    return $accents[$Rgb]
}

function New-ServerPulseLightNeutralColor {
    param([Windows.Media.Color]$Color)
    $average = ([double]$Color.R + [double]$Color.G + [double]$Color.B) / 3.0
    if ($average -lt 80.0) {
        $base = 250.0 - ($average / 80.0 * 38.0)
        $scale = 0.13
    } else {
        $base = [Math]::Max(26.0,140.0 - (($average - 80.0) * 0.75))
        $scale = 0.15
    }
    $r = [byte][Math]::Max(0,[Math]::Min(255,[Math]::Round($base + (($Color.R - $average) * $scale))))
    $g = [byte][Math]::Max(0,[Math]::Min(255,[Math]::Round($base + (($Color.G - $average) * $scale))))
    $b = [byte][Math]::Max(0,[Math]::Min(255,[Math]::Round($base + (($Color.B - $average) * $scale))))
    return [Windows.Media.Color]::FromArgb(255,$r,$g,$b)
}

function Add-ServerPulseThemeColorPair {
    param([Parameter(Mandatory)][string]$DarkRgb)
    $key = $DarkRgb.ToUpperInvariant()
    if ($script:serverPulseDarkToLight.ContainsKey($key)) { return }
    $dark = [Windows.Media.ColorConverter]::ConvertFromString($key)
    $accent = Get-ServerPulseLightAccentColor $key
    $light = if ($accent) { [Windows.Media.ColorConverter]::ConvertFromString($accent) } else { New-ServerPulseLightNeutralColor $dark }
    $lightKey = '#{0:X2}{1:X2}{2:X2}' -f $light.R,$light.G,$light.B
    while ($script:serverPulseLightToDark.ContainsKey($lightKey) -and $script:serverPulseLightToDark[$lightKey] -ne $key) {
        $light = [Windows.Media.Color]::FromArgb(255,$light.R,$light.G,[byte](($light.B + 1) % 256))
        $lightKey = '#{0:X2}{1:X2}{2:X2}' -f $light.R,$light.G,$light.B
    }
    $script:serverPulseDarkToLight[$key] = $lightKey
    $script:serverPulseLightToDark[$lightKey] = $key
}

$knownThemeColors = @(
    '#000000','#0B0E0C','#0D100E','#101411','#111512','#131714','#151A17','#171A18','#171B18','#171C19','#1A1F1C','#1B201D',
    '#202521','#202622','#222724','#242925','#252A27','#252B27','#252C27','#263029','#281718','#29312B','#2B302D','#2B312D','#2C332E',
    '#303632','#303731','#303732','#343A36','#343B36','#353C37','#38413B','#39413C','#3A423D','#3A433C','#3A443D','#455047','#505A54',
    '#56605A','#59635D','#5F6963','#626C66','#657069','#66716A','#68736C','#69736D','#6C7770','#6E7972','#6F7A73','#6F7B73',
    '#707B74','#78827C','#78837C','#7A857E','#7B857F','#7B867F','#7C8780','#87928B','#8A958E','#8C9690','#8C9790','#939D97',
    '#98A39C','#99A39D','#9AA39D','#9DA7A0','#AAB3AD','#AAB4AE','#B5BDB8','#BAC3BD','#C5CDC8','#D4DBD7','#D7DDD9','#D8DEDA',
    '#D9E0DB','#DCE3DE','#DCE3DF','#E1E6E3','#E7EBE8','#E7ECE8','#EDF1EF','#EDF2EE','#EDF2EF','#F0F3F1','#F2F5F3','#F4F7F5','#FFFFFF',
    '#A7D948','#BCEB62','#B9EC58','#91C235','#79C8D8','#88C0D0','#81A1C1','#5E81AC','#E4B64B','#E9C46A','#F4A261','#D08770',
    '#FF6B6B','#FF7B72','#FF5E5E','#FF8A80','#FF9B93','#F07178','#C678DD','#B48EAD','#A3BE8C','#FFE2E2'
)
foreach ($knownColor in $knownThemeColors) { Add-ServerPulseThemeColorPair $knownColor }

function ConvertTo-ServerPulseThemeColor {
    param([Parameter(Mandatory)]$Color, [ValidateSet('light','dark')][string]$Theme = $script:serverPulseResolvedTheme)
    $source = if ($Color -is [Windows.Media.Color]) { $Color } else { [Windows.Media.ColorConverter]::ConvertFromString([string]$Color) }
    $rgb = '#{0:X2}{1:X2}{2:X2}' -f $source.R,$source.G,$source.B
    if ($Theme -eq 'light') {
        if ($script:serverPulseLightToDark.ContainsKey($rgb)) { $targetRgb = $rgb }
        elseif ($script:serverPulseDarkToLight.ContainsKey($rgb)) { $targetRgb = $script:serverPulseDarkToLight[$rgb] }
        else { $targetRgb = $rgb }
    } else {
        $targetRgb = if ($script:serverPulseLightToDark.ContainsKey($rgb)) { $script:serverPulseLightToDark[$rgb] } else { $rgb }
    }
    $target = [Windows.Media.ColorConverter]::ConvertFromString($targetRgb)
    return [Windows.Media.Color]::FromArgb($source.A,$target.R,$target.G,$target.B)
}

function Get-ServerPulseThemeBrushKey {
    param([Parameter(Mandatory)]$Color)

    return ('{0:X2}{1:X2}{2:X2}{3:X2}' -f [int]$Color.A,[int]$Color.R,[int]$Color.G,[int]$Color.B)
}

function Register-ServerPulseThemeBrush {
    param($Brush,[string]$CacheKey)

    if ($Brush -isnot [Windows.Media.SolidColorBrush]) { return $Brush }
    $key = if ([string]::IsNullOrWhiteSpace($CacheKey)) { Get-ServerPulseThemeBrushKey $Brush.Color } else { $CacheKey }
    if ($script:serverPulseThemeBrushes.ContainsKey($key)) { return $script:serverPulseThemeBrushes[$key] }
    $script:serverPulseThemeBrushes[$key] = $Brush
    return $Brush
}

function New-ServerPulseThemeBrush {
    param([Parameter(Mandatory)][string]$Color)
    $source = [Windows.Media.ColorConverter]::ConvertFromString($Color)
    $cacheKey = Get-ServerPulseThemeBrushKey $source
    if ($script:serverPulseThemeBrushes.ContainsKey($cacheKey)) {
        return Set-ServerPulseBrushTheme $script:serverPulseThemeBrushes[$cacheKey] $script:serverPulseResolvedTheme
    }
    $rgb = '#{0:X2}{1:X2}{2:X2}' -f $source.R,$source.G,$source.B
    if (-not $script:serverPulseDarkToLight.ContainsKey($rgb) -and -not $script:serverPulseLightToDark.ContainsKey($rgb)) { Add-ServerPulseThemeColorPair $rgb }
    $value = ConvertTo-ServerPulseThemeColor $source $script:serverPulseResolvedTheme
    return Register-ServerPulseThemeBrush ([Windows.Media.SolidColorBrush]::new($value)) $cacheKey
}

function Set-ServerPulseBrushTheme {
    param($Brush, [ValidateSet('light','dark')][string]$Theme = $script:serverPulseResolvedTheme)
    if ($Brush -isnot [Windows.Media.SolidColorBrush]) { return $Brush }
    $target = ConvertTo-ServerPulseThemeColor $Brush.Color $Theme
    if (-not $Brush.IsFrozen) { $Brush.Color = $target; return $Brush }
    $cacheKey = $null
    foreach ($entry in @($script:serverPulseThemeBrushes.GetEnumerator())) {
        if ([object]::ReferenceEquals($entry.Value,$Brush)) { $cacheKey = [string]$entry.Key; break }
    }
    $replacement = [Windows.Media.SolidColorBrush]::new($target)
    if (-not [string]::IsNullOrWhiteSpace($cacheKey)) {
        $script:serverPulseThemeBrushes[$cacheKey] = $replacement
        return $replacement
    }
    return Register-ServerPulseThemeBrush $replacement
}

function Set-ServerPulseThemeState {
    param([string]$Mode, [ValidateSet('light','dark')][string]$ResolvedTheme)
    $script:serverPulseThemeMode = Normalize-ServerPulseThemeMode $Mode
    $script:serverPulseResolvedTheme = if ($ResolvedTheme) { $ResolvedTheme } else { Resolve-ServerPulseTheme $script:serverPulseThemeMode }
    foreach ($brush in @($script:serverPulseThemeBrushes.Values)) { [void](Set-ServerPulseBrushTheme $brush $script:serverPulseResolvedTheme) }
    return $script:serverPulseResolvedTheme
}

function Update-ServerPulseThemeResources {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [Windows.Media.SolidColorBrush]) { [void](Set-ServerPulseBrushTheme $Value); return }
    if ($Value -is [Windows.Setter]) { Update-ServerPulseThemeResources $Value.Value; return }
    if ($Value -is [Windows.Style]) {
        foreach ($setter in $Value.Setters) { Update-ServerPulseThemeResources $setter }
        foreach ($trigger in $Value.Triggers) { Update-ServerPulseThemeResources $trigger }
        foreach ($entry in @($Value.Resources.Values)) { Update-ServerPulseThemeResources $entry }
        return
    }
    if ($Value -is [Windows.Controls.ControlTemplate]) {
        foreach ($trigger in $Value.Triggers) { Update-ServerPulseThemeResources $trigger }
        foreach ($entry in @($Value.Resources.Values)) { Update-ServerPulseThemeResources $entry }
        return
    }
    $setters = $Value.PSObject.Properties['Setters']
    if ($null -ne $setters) { foreach ($setter in @($setters.Value)) { Update-ServerPulseThemeResources $setter } }
}

function Update-ServerPulseThemeVisualTree {
    param([Parameter(Mandatory)]$Root)
    if ($Root -isnot [Windows.DependencyObject]) { return }
    foreach ($propertyName in @('Background','Foreground','BorderBrush','Fill','Stroke','CaretBrush','SelectionBrush','OpacityMask')) {
        $property = $Root.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $property.Value -isnot [Windows.Media.SolidColorBrush]) { continue }
        $updated = Set-ServerPulseBrushTheme $property.Value
        if (-not [object]::ReferenceEquals($updated,$property.Value) -and $property.IsSettable) { $property.Value = $updated }
    }
    $styleProperty = $Root.PSObject.Properties['Style']
    if ($null -ne $styleProperty -and $styleProperty.Value -is [Windows.Style]) {
        Update-ServerPulseThemeResources $styleProperty.Value
    }
    $resourcesProperty = $Root.PSObject.Properties['Resources']
    if ($null -ne $resourcesProperty -and $null -ne $resourcesProperty.Value) {
        foreach ($entry in @($resourcesProperty.Value.Values)) { Update-ServerPulseThemeResources $entry }
    }
    foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($Root)) {
        if ($child -is [Windows.DependencyObject]) { Update-ServerPulseThemeVisualTree $child }
    }
}
