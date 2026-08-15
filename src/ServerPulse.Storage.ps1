Set-StrictMode -Version Latest

<#+
    Storage policy helpers are intentionally independent from WPF.  The main
    window and the history page use this module for the data-root pointer,
    retention validation, cleanup decisions, and transactional root moves.
    Passwords, SSH tokens, and metric samples are never written here.
#>

function Get-ServerPulseDefaultDataRoot {
    param(
        [string]$LocalAppDataPath = $env:LOCALAPPDATA,
        [switch]$SmokeTest,
        [string]$SmokeRoot
    )

    if ($SmokeTest -and -not [string]::IsNullOrWhiteSpace($SmokeRoot)) { return [IO.Path]::GetFullPath($SmokeRoot) }
    if ([string]::IsNullOrWhiteSpace($LocalAppDataPath)) { $LocalAppDataPath = [Environment]::GetFolderPath('LocalApplicationData') }
    return [IO.Path]::GetFullPath((Join-Path $LocalAppDataPath 'ServerPulse'))
}

function Get-ServerPulseLocationPointerPath {
    param(
        [string]$LocalAppDataPath = $env:LOCALAPPDATA,
        [switch]$SmokeTest,
        [string]$SmokeRoot
    )

    if ($SmokeTest -and -not [string]::IsNullOrWhiteSpace($SmokeRoot)) {
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($SmokeRoot))
        return Join-Path $parent 'ServerPulse.location.json'
    }
    if ([string]::IsNullOrWhiteSpace($LocalAppDataPath)) { $LocalAppDataPath = [Environment]::GetFolderPath('LocalApplicationData') }
    return Join-Path ([IO.Path]::GetFullPath($LocalAppDataPath)) 'ServerPulse.location.json'
}

function ConvertTo-ServerPulseAbsoluteLocalPath {
    param(
        [AllowNull()][string]$Path,
        [switch]$Create,
        [switch]$TestWrite
    )

    $raw = if ($null -eq $Path) { '' } else { $Path.Trim() }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ IsValid=$false; Path=$null; Reason='路径不能为空'; ErrorCode='empty' }
    }
    try { $expanded = [Environment]::ExpandEnvironmentVariables($raw) } catch {
        return [PSCustomObject]@{ IsValid=$false; Path=$null; Reason='环境变量无法解析'; ErrorCode='environment' }
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        return [PSCustomObject]@{ IsValid=$false; Path=$null; Reason='必须使用本地绝对路径'; ErrorCode='relative' }
    }
    if ($expanded.StartsWith('\\') -or $expanded.StartsWith('//')) {
        return [PSCustomObject]@{ IsValid=$false; Path=$null; Reason='不允许使用 UNC 网络路径'; ErrorCode='unc' }
    }
    try { $full = [IO.Path]::GetFullPath($expanded) } catch {
        return [PSCustomObject]@{ IsValid=$false; Path=$null; Reason='路径格式无效'; ErrorCode='format' }
    }
    try {
        if (-not (Test-Path -LiteralPath $full)) {
            if (-not $Create) { return [PSCustomObject]@{ IsValid=$false; Path=$full; Reason='目录不存在'; ErrorCode='missing' } }
            [void](New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop)
        }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [PSCustomObject]@{ IsValid=$false; Path=$full; Reason='路径不是目录'; ErrorCode='file' } }
        if ($TestWrite) {
            $probe = Join-Path $full ('.serverpulse-write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
            try { [IO.File]::WriteAllText($probe, 'Server Pulse write test', [Text.UTF8Encoding]::new($false)) }
            finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } }
        }
        return [PSCustomObject]@{ IsValid=$true; Path=$full; Reason=$null; ErrorCode=$null }
    } catch {
        return [PSCustomObject]@{ IsValid=$false; Path=$full; Reason=('无法读写目录：{0}' -f $_.Exception.Message); ErrorCode='permission' }
    }
}

function Test-ServerPulseDataRootPath {
    param([AllowNull()][string]$Path, [switch]$Create)
    return ConvertTo-ServerPulseAbsoluteLocalPath -Path $Path -Create:$Create -TestWrite
}

function New-ServerPulseLocationPointer {
    param(
        [Parameter(Mandatory)][string]$PreferredDataRootPath,
        [bool]$PendingSync = $false,
        [string]$ActiveDataRootPath,
        [string]$LastError
    )
    return [PSCustomObject][ordered]@{
        Version = 1
        PreferredDataRootPath = $PreferredDataRootPath
        ActiveDataRootPath = $ActiveDataRootPath
        PendingSync = [bool]$PendingSync
        LastError = $LastError
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
    }
}

function Read-ServerPulseLocationPointer {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value -or $value.PSObject.Properties.Name -notcontains 'PreferredDataRootPath') { throw '缺少 PreferredDataRootPath' }
        return $value
    } catch {
        return [PSCustomObject]@{ Version=1; PreferredDataRootPath=$null; ActiveDataRootPath=$null; PendingSync=$false; LastError=('location.json 损坏：{0}' -f $_.Exception.Message); Invalid=$true }
    }
}

function Write-ServerPulseLocationPointer {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Pointer)

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    try {
        $json = $Pointer | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($true))
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($temp, $Path, $null) }
            catch { Move-Item -LiteralPath $temp -Destination $Path -Force }
        } else { Move-Item -LiteralPath $temp -Destination $Path -Force }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Write-ServerPulseJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 12)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth $Depth), [Text.UTF8Encoding]::new($true))
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($temp, $Path, $null) } catch { Move-Item -LiteralPath $temp -Destination $Path -Force }
        } else { Move-Item -LiteralPath $temp -Destination $Path -Force }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Resolve-ServerPulseDataRoot {
    param(
        [Parameter(Mandatory)][string]$DefaultRoot,
        [Parameter(Mandatory)][string]$PointerPath,
        [switch]$CreateDefault
    )

    $defaultResult = Test-ServerPulseDataRootPath -Path $DefaultRoot -Create:$CreateDefault
    if (-not $defaultResult.IsValid) { throw ('默认数据目录不可用：{0}' -f $defaultResult.Reason) }
    $pointer = Read-ServerPulseLocationPointer -Path $PointerPath
    $pointerInvalid = $null -ne $pointer -and $pointer.PSObject.Properties.Name -contains 'Invalid' -and [bool]$pointer.Invalid
    $preferred = if ($null -ne $pointer -and -not $pointerInvalid) { [string]$pointer.PreferredDataRootPath } else { $defaultResult.Path }
    $preferredResult = if ([string]::IsNullOrWhiteSpace($preferred)) { $defaultResult } else { Test-ServerPulseDataRootPath -Path $preferred }
    if ($preferredResult.IsValid) {
        return [PSCustomObject]@{ DefaultRoot=$defaultResult.Path; PreferredRoot=$preferredResult.Path; ActiveRoot=$preferredResult.Path; IsFallback=$false; Pointer=$pointer; Error=$null }
    }
    $errorText = if ($null -ne $pointer -and $pointer.LastError) { [string]$pointer.LastError } else { [string]$preferredResult.Reason }
    $fallbackPointer = New-ServerPulseLocationPointer -PreferredDataRootPath $preferred -PendingSync $true -ActiveDataRootPath $defaultResult.Path -LastError $errorText
    try { Write-ServerPulseLocationPointer -Path $PointerPath -Pointer $fallbackPointer } catch { }
    return [PSCustomObject]@{ DefaultRoot=$defaultResult.Path; PreferredRoot=$preferred; ActiveRoot=$defaultResult.Path; IsFallback=$true; Pointer=$fallbackPointer; Error=$errorText }
}

function ConvertTo-ServerPulseRetentionSettings {
    param(
        [AllowNull()]$Days,
        [bool]$NeverCleanup = $false,
        [AllowNull()]$LastRetentionDays = 7,
        [bool]$Configured = $true,
        [bool]$CleanupPaused = $false
    )

    $last = 7
    $lastNumber = 0
    if ([int]::TryParse([string]$LastRetentionDays, [ref]$lastNumber) -and $lastNumber -ge 1 -and $lastNumber -le 3650) { $last = $lastNumber }
    if ($NeverCleanup) {
        return [PSCustomObject]@{ IsValid=$true; RetentionDays=$last; LastRetentionDays=$last; NeverCleanup=$true; CleanupPaused=$false; Configured=$Configured; Error=$null }
    }
    $number = 0
    if (-not [int]::TryParse([string]$Days, [ref]$number) -or $number -lt 1 -or $number -gt 3650) {
        return [PSCustomObject]@{ IsValid=$false; RetentionDays=$null; LastRetentionDays=$last; NeverCleanup=$false; CleanupPaused=$CleanupPaused; Configured=$Configured; Error='保留天数必须是 1–3650 的整数' }
    }
    return [PSCustomObject]@{ IsValid=$true; RetentionDays=$number; LastRetentionDays=$number; NeverCleanup=$false; CleanupPaused=$CleanupPaused; Configured=$Configured; Error=$null }
}

function Get-ServerPulseRetentionCutoffDate {
    param([datetime]$Now = [DateTime]::Now, [int]$RetentionDays = 7)
    if ($RetentionDays -lt 1 -or $RetentionDays -gt 3650) { throw '保留天数必须在 1–3650 之间' }
    return $Now.Date.AddDays(-$RetentionDays + 1)
}

function Get-ServerPulseCleanupDecision {
    param([int]$PreviousDays = 7, [int]$NewDays = 7, [bool]$PreviousNeverCleanup = $false, [bool]$NewNeverCleanup = $false)
    if ($NewNeverCleanup) { return 'none' }
    if ($PreviousNeverCleanup -or $NewDays -lt $PreviousDays) { return 'prompt' }
    return 'none'
}

function Get-ServerPulseDataRootInventory {
    param([Parameter(Mandatory)][string]$Root)
    $items = [Collections.Generic.List[object]]::new()
    foreach ($relative in @('settings.json','servers.json','error.log')) {
        $path = Join-Path $Root $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { $items.Add([PSCustomObject]@{RelativePath=$relative;FullName=$path;Length=(Get-Item -LiteralPath $path).Length}) }
    }
    $history = Join-Path $Root 'history'
    if (Test-Path -LiteralPath $history) {
        foreach ($file in @(Get-ChildItem -LiteralPath $history -File -Recurse -ErrorAction SilentlyContinue)) {
            $relative = Join-Path 'history' ($file.FullName.Substring($history.Length).TrimStart('\','/'))
            $items.Add([PSCustomObject]@{RelativePath=$relative;FullName=$file.FullName;Length=$file.Length})
        }
    }
    $bytes=0L
    if($items.Count -gt 0){$measure=$items | Measure-Object Length -Sum;if($null -ne $measure -and $measure.PSObject.Properties.Name -contains 'Sum' -and $null -ne $measure.Sum){$bytes=[long]$measure.Sum}}
    return [PSCustomObject]@{ Root=$Root; Files=@($items); Count=$items.Count; Bytes=$bytes }
}

function Copy-ServerPulseHistoryMergeFile {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Target)
    $extension = [IO.Path]::GetExtension($Source).ToLowerInvariant()
    if ($extension -eq '.jsonl') {
        $sourceLines=@(if(Test-Path -LiteralPath $Source){Get-Content -LiteralPath $Source -Encoding UTF8}else{@()}) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $targetLines=@(if(Test-Path -LiteralPath $Target){Get-Content -LiteralPath $Target -Encoding UTF8}else{@()}) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $seen=@{}; $all=[Collections.Generic.List[string]]::new()
        foreach($line in @($targetLines)+@($sourceLines)){if(-not $seen.ContainsKey([string]$line)){$seen[[string]$line]=$true;$all.Add([string]$line)}}
        [IO.File]::WriteAllLines($Target,$all.ToArray(),[Text.UTF8Encoding]::new($true)); return
    }
    try {
        $sourceObject=Get-Content -LiteralPath $Source -Raw -Encoding UTF8|ConvertFrom-Json
        $targetObject=if(Test-Path -LiteralPath $Target){Get-Content -LiteralPath $Target -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
        $records=[Collections.Generic.List[object]]::new();$seen=@{}
        foreach($record in @($targetObject.Records)+@($sourceObject.Records)){
            if($null -eq $record){continue};$key=$record|ConvertTo-Json -Depth 20 -Compress;if(-not$seen.ContainsKey($key)){$seen[$key]=$true;$records.Add($record)}
        }
        $output=[ordered]@{Version=1;Records=@($records)}|ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($Target,$output,[Text.UTF8Encoding]::new($true)); return
    } catch { Copy-Item -LiteralPath $Source -Destination $Target -Force }
}

function Invoke-ServerPulseDataRootMigration {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [ValidateSet('Overwrite','Merge','Cancel')][string]$ConflictMode = 'Cancel'
    )

    $sourceResult = Test-ServerPulseDataRootPath -Path $SourceRoot
    if (-not $sourceResult.IsValid) { throw ('源数据目录不可用：{0}' -f $sourceResult.Reason) }
    $source = $sourceResult.Path
    $targetResult = Test-ServerPulseDataRootPath -Path $TargetRoot -Create
    if (-not $targetResult.IsValid) { throw ('目标数据目录不可用：{0}' -f $targetResult.Reason) }
    $target = $targetResult.Path
    if ([string]::Equals($source,$target,[StringComparison]::OrdinalIgnoreCase)) { return [PSCustomObject]@{Status='NoOp';SourceRoot=$source;TargetRoot=$target;BackupPath=$null;Count=0;Bytes=0} }
    $sourcePrefix=$source.TrimEnd('\')+'\';$targetPrefix=$target.TrimEnd('\')+'\'
    if($target.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)-or$source.StartsWith($targetPrefix,[StringComparison]::OrdinalIgnoreCase)){throw '源目录和目标目录不能互相嵌套'}
    $inventory = Get-ServerPulseDataRootInventory -Root $source
    $targetInventory = Get-ServerPulseDataRootInventory -Root $target
    $targetNames=@{}; foreach($item in @($targetInventory.Files)){$targetNames[[string]$item.RelativePath]=$true}
    $conflicts=@($inventory.Files|Where-Object{$targetNames.ContainsKey([string]$_.RelativePath)})
    $conflictNames=@($conflicts | ForEach-Object { [string]$_.RelativePath })
    if ($conflicts.Count -gt 0 -and $ConflictMode -eq 'Cancel') { return [PSCustomObject]@{Status='Cancelled';SourceRoot=$source;TargetRoot=$target;BackupPath=$null;Count=$inventory.Count;Bytes=$inventory.Bytes;Conflicts=$conflictNames} }
    $stamp=[DateTime]::Now.ToString('yyyyMMdd-HHmmss');$backup=Join-Path (Split-Path -Parent $target) ((Split-Path -Leaf $target)+'.backup-'+$stamp)
    while(Test-Path -LiteralPath $backup){$backup=Join-Path (Split-Path -Parent $target) ((Split-Path -Leaf $target)+'.backup-'+$stamp+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
    $sourceBackup=$null;$changed=@();$createdTargetPaths=[Collections.Generic.List[string]]::new()
    try {
        [void](New-Item -ItemType Directory -Path $target -Force)
        if ($conflicts.Count -gt 0) {
            [void](New-Item -ItemType Directory -Path $backup -Force)
            foreach($conflict in $conflicts){$backupPath=Join-Path $backup $conflict.RelativePath;$parent=Split-Path -Parent $backupPath;if(-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)};Copy-Item -LiteralPath $conflict.FullName -Destination $backupPath -Force; $changed += $conflict.RelativePath}
        }
        foreach($item in @($inventory.Files)){
            $destination=Join-Path $target $item.RelativePath;$parent=Split-Path -Parent $destination;if(-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)}
            $destinationExisted=Test-Path -LiteralPath $destination
            if($ConflictMode -eq 'Merge' -and $targetNames.ContainsKey([string]$item.RelativePath) -and $item.RelativePath -match '^history[\\/]\d{4}-\d{2}-\d{2}(?:\.v2\.jsonl|\.json)$'){Copy-ServerPulseHistoryMergeFile -Source $item.FullName -Target $destination}
            elseif($ConflictMode -eq 'Merge' -and $item.RelativePath -eq 'error.log' -and (Test-Path -LiteralPath $destination)){[IO.File]::AppendAllText($destination,"`r`n--- Server Pulse migration $(Get-Date -Format o) ---`r`n" + [IO.File]::ReadAllText($item.FullName),[Text.UTF8Encoding]::new($true))}
            else{Copy-Item -LiteralPath $item.FullName -Destination $destination -Force}
            if(-not $destinationExisted -and (Test-Path -LiteralPath $destination)){$createdTargetPaths.Add($destination)}
        }
        $sourceBackup=$source+'.backup-'+$stamp
        while(Test-Path -LiteralPath $sourceBackup){$sourceBackup=$source+'.backup-'+$stamp+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)}
        Move-Item -LiteralPath $source -Destination $sourceBackup -Force
        return [PSCustomObject]@{Status='Migrated';SourceRoot=$source;TargetRoot=$target;BackupPath=$sourceBackup;TargetBackupPath=if(Test-Path -LiteralPath $backup){$backup}else{$null};Count=$inventory.Count;Bytes=$inventory.Bytes;Conflicts=$conflictNames}
    } catch {
        # Keep the source usable. Restore target conflicts and remove newly copied files.
        try {
            if (Test-Path -LiteralPath $backup) {
                foreach($relative in @($changed)){$from=Join-Path $backup $relative;$to=Join-Path $target $relative;if(Test-Path -LiteralPath $from){Copy-Item -LiteralPath $from -Destination $to -Force}}
            }
            foreach($created in @($createdTargetPaths)){if(Test-Path -LiteralPath $created){Remove-Item -LiteralPath $created -Force -ErrorAction SilentlyContinue}}
            if($null -ne $sourceBackup -and (Test-Path -LiteralPath $sourceBackup) -and -not (Test-Path -LiteralPath $source)){Move-Item -LiteralPath $sourceBackup -Destination $source -Force}
        } catch { }
        throw
    }
}

# History day files are appended by the minute recorder and rewritten in place
# by the server-side agent merge.  A named mutex keeps both writers serialized
# across runspaces (and across processes of the same session); each scope
# creates or attaches to the same named mutex on first use.
function Enter-ServerPulseHistoryWriteLock {
    param([int]$TimeoutMs = 30000)
    $mutex = $null
    try { $mutex = [Threading.Mutex]::new($false, 'Local\ServerPulse.HistoryWrite') } catch { $mutex = $null }
    if ($null -eq $mutex) {
        try { $mutex = [Threading.Mutex]::OpenExisting('Local\ServerPulse.HistoryWrite') } catch { $mutex = $null }
    }
    if ($null -ne $mutex) {
        try { [void]$mutex.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { }
        $script:ServerPulseHistoryWriteMutex = $mutex
    }
}

function Exit-ServerPulseHistoryWriteLock {
    if ($null -ne $script:ServerPulseHistoryWriteMutex) {
        try { $script:ServerPulseHistoryWriteMutex.ReleaseMutex() } catch { }
        try { $script:ServerPulseHistoryWriteMutex.Dispose() } catch { }
        $script:ServerPulseHistoryWriteMutex = $null
    }
}
