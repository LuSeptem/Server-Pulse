param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [switch]$RuntimeInput,
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'ServerPulse.Core.ps1')
. (Join-Path $PSScriptRoot 'ServerPulse.Sample.ps1')
. (Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1')
. (Join-Path $PSScriptRoot 'ServerPulse.Persistent.ps1')

$config = Get-ServerPulseConfig -Path $ConfigPath
if ($RuntimeInput -and $Worker) { throw 'RuntimeInput 与 Worker 不能同时使用' }
$runtime = if ($RuntimeInput) {
    $runtimeText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($runtimeText)) { throw '运行时服务器输入为空' }
    $parsedRuntime=$runtimeText | ConvertFrom-Json
    $runtimeText=$null
    $parsedRuntime
} else { $null }
$remoteScript = Get-ServerPulseSampleScript

$corePath = Join-Path $PSScriptRoot 'ServerPulse.Core.ps1'
$sshModulePath = Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1'
$collectorRunspacePool = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1,32)
$collectorRunspacePool.Open()
$persistentStore=New-ServerPulsePersistentStore
$collectorWorkerScript = @'
param($ServerJson, $Script, $TimeoutMs, $CorePath, $SshModulePath, $AskPassPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. $CorePath
. $SshModulePath
$server = $ServerJson | ConvertFrom-Json
$started = [Diagnostics.Stopwatch]::StartNew()
try {
    $authMode = if ([string]$server.AuthMode -in @('auto','passwordless','password')) { [string]$server.AuthMode } else { 'auto' }
    $connection = Invoke-ServerPulseServerConnection -Server $server -Script $Script -AuthMode $authMode -Password ([string]$server.Password) -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath
    $server.Password = $null
    if ($connection.Status -ne 'online') {
        return [PSCustomObject]@{
            Id=[string]$server.Id;Label=[string]$server.Label;Host=[string]$server.SshTarget;Status=[string]$connection.Status
            AuthMode=[string]$connection.AuthMode;CheckedAt=[DateTime]::UtcNow.ToString('o');LatencyMs=$null;Metrics=$null;Error=[string]$connection.Error
        }
    }
    [PSCustomObject]@{
        Id=[string]$server.Id;Label=[string]$server.Label;Host=[string]$server.SshTarget;Status='online';AuthMode=[string]$connection.AuthMode
        CheckedAt=[DateTime]::UtcNow.ToString('o');LatencyMs=[int]$started.ElapsedMilliseconds
        Metrics=ConvertFrom-ServerMetricsOutput -Output $connection.Output;Error=$null
    }
} catch {
    [PSCustomObject]@{
        Id=[string]$server.Id;Label=[string]$server.Label;Host=[string]$server.SshTarget;Status='offline';AuthMode=[string]$server.AuthMode
        CheckedAt=[DateTime]::UtcNow.ToString('o');LatencyMs=$null;Metrics=$null;Error=$_.Exception.Message
    }
} finally {
    if ($null -ne $server) { $server.Password = $null }
}
'@

function Invoke-ServerPulseCollection {
    param($Runtime)

    $servers = if ($null -ne $Runtime) { @($Runtime.Servers) } else {
        @($config.Servers | ForEach-Object {
            [PSCustomObject]@{Id=[string]$_.id;Label=[string]$_.label;Source='seed';SshTarget=[string]$_.host;HostName=[string]$_.host;Port=22;User='';AuthMode='passwordless';Password=$null}
        })
    }
    $timeoutMs = if ($null -ne $Runtime -and $Runtime.SshTimeoutMs) { [int]$Runtime.SshTimeoutMs } else { $config.SshTimeoutMs }
    $askPassPath = if ($null -ne $Runtime) { [string]$Runtime.AskPassPath } else { '' }
    $invocations = [Collections.Generic.List[object]]::new()
    try {
        foreach ($server in $servers) {
            $serverJson = $server | ConvertTo-Json -Compress
            $powerShell = [Management.Automation.PowerShell]::Create()
            $powerShell.RunspacePool = $collectorRunspacePool
            [void]$powerShell.AddScript($collectorWorkerScript).AddArgument($serverJson).AddArgument($remoteScript).AddArgument($timeoutMs).AddArgument($corePath).AddArgument($sshModulePath).AddArgument($askPassPath)
            $async = $powerShell.BeginInvoke()
            $invocations.Add([PSCustomObject]@{PowerShell=$powerShell;Async=$async;Server=$server})
            $server.Password=$null;$serverJson=$null
        }

        $results = foreach ($invocation in $invocations) {
            try {
                $output=@($invocation.PowerShell.EndInvoke($invocation.Async))
                if($output.Count){$output[0]}else{throw '采集任务未返回结果'}
            } catch {
                [PSCustomObject]@{
                    Id=[string]$invocation.Server.Id;Label=[string]$invocation.Server.Label;Host=[string]$invocation.Server.SshTarget
                    Status='offline';AuthMode=[string]$invocation.Server.AuthMode;CheckedAt=[DateTime]::UtcNow.ToString('o')
                    LatencyMs=$null;Metrics=$null;Error=$_.Exception.Message
                }
            }
        }
        [PSCustomObject]@{GeneratedAt=[DateTime]::UtcNow.ToString('o');Servers=@($results)}
    } finally {
        foreach($invocation in $invocations){$invocation.Server.Password=$null;$invocation.PowerShell.Dispose()}
    }
}

try {
    if($Worker){
        while($null -ne ($requestLine=[Console]::In.ReadLine())){
            if([string]::IsNullOrWhiteSpace($requestLine)){continue}
            try {
                $request=$requestLine|ConvertFrom-Json
                $response=Invoke-ServerPulsePersistentCollection -Runtime $request -Store $persistentStore -SampleScript $remoteScript
                $requestLine=$null;$request=$null
                [Console]::Out.WriteLine(($response|ConvertTo-Json -Depth 12 -Compress))
            } catch {
                [Console]::Out.WriteLine(([PSCustomObject]@{GeneratedAt=[DateTime]::UtcNow.ToString('o');Servers=@();WorkerError=$_.Exception.Message}|ConvertTo-Json -Depth 4 -Compress))
            }
            [Console]::Out.Flush()
        }
    } else {
        Invoke-ServerPulseCollection -Runtime $runtime | ConvertTo-Json -Depth 12 -Compress
    }
} finally {
    Remove-ServerPulsePersistentStore $persistentStore
    $collectorRunspacePool.Close()
    $collectorRunspacePool.Dispose()
}
