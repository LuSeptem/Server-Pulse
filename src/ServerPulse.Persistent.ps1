# Self-contained LF normalization (see ServerPulse.Core.ps1); lets this
# module serve runspaces that do not dot-source Core.
if ($null -eq (Get-Command ConvertTo-ServerPulseShText -ErrorAction SilentlyContinue)) {
    function ConvertTo-ServerPulseShText {
        param([AllowNull()][string]$Text)
        if ($null -eq $Text) { return '' }
        return $Text.Replace("`r`n", "`n")
    }
}

function New-ServerPulseRetryState {
    param([int]$CircuitThreshold=6,[int[]]$ScheduleSeconds=@(5,15,30,60,300),[int]$RandomSeed=0)
    return [PSCustomObject]@{
        FailureCount=0;CircuitOpen=$false;NextRetryAt=$null;LastDelaySeconds=0
        CircuitThreshold=[Math]::Max(2,$CircuitThreshold);ScheduleSeconds=@($ScheduleSeconds);Random=[Random]::new($RandomSeed)
    }
}

function Reset-ServerPulseRetryState {
    param($State)
    $State.FailureCount=0;$State.CircuitOpen=$false;$State.NextRetryAt=$null;$State.LastDelaySeconds=0
}

function Register-ServerPulseConnectionFailure {
    param($State,[datetime]$Now=[datetime]::UtcNow,[Nullable[double]]$JitterFactor=$null)
    $State.FailureCount++
    if($State.FailureCount -ge $State.CircuitThreshold){
        $State.CircuitOpen=$true;$State.NextRetryAt=$null;$State.LastDelaySeconds=0
        return [PSCustomObject]@{FailureCount=$State.FailureCount;CircuitOpen=$true;NextRetryAt=$null;DelaySeconds=0}
    }
    $index=[Math]::Min($State.FailureCount-1,$State.ScheduleSeconds.Count-1);$base=[double]$State.ScheduleSeconds[$index]
    $factor=if($null-ne$JitterFactor){[double]$JitterFactor}else{0.8+($State.Random.NextDouble()*0.4)}
    $delay=[Math]::Max(1,[int][Math]::Round($base*$factor));$State.LastDelaySeconds=$delay;$State.NextRetryAt=$Now.ToUniversalTime().AddSeconds($delay)
    return [PSCustomObject]@{FailureCount=$State.FailureCount;CircuitOpen=$false;NextRetryAt=$State.NextRetryAt;DelaySeconds=$delay}
}

function New-ServerPulseRemoteLoopScript {
    param([Parameter(Mandatory)][string]$SampleScript,[int]$IntervalSeconds=5)
    $interval=[Math]::Max(1,[Math]::Min(3600,$IntervalSeconds))
    $script = @"
serverpulse_interval=$interval
while :; do
  printf '%s\n' '__SERVERPULSE_SAMPLE_BEGIN__'
  (
$SampleScript
  )
  serverpulse_status=`$?
  printf '__SERVERPULSE_SAMPLE_END__ %s\n' "`$serverpulse_status"
  sleep "`$serverpulse_interval" || exit 0
done
"@
    return ConvertTo-ServerPulseShText $script
}

function Start-ServerPulsePersistentSshProcess {
    param($Server,[string]$Script,[ValidateSet('passwordless','password')][string]$Mode,[string]$Password,[int]$TimeoutMs,[string]$AskPassPath,[string]$SshPath='ssh.exe')
    $args=Get-ServerPulseSshArguments -Server $Server -Mode $Mode -TimeoutMs $TimeoutMs
    $quote = {
        param([string]$Value)
        if ($Value -notmatch '[\s"]') { return $Value }
        return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$SshPath;$info.Arguments=(($args|ForEach-Object{&$quote([string]$_)})-join' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8
    $pipe=$null;$wait=$null;$token=$null
    if($Mode-eq'password'){
        if([string]::IsNullOrEmpty($Password)){throw '未提供密码'}
        $pipeName='ServerPulse-'+[guid]::NewGuid().ToString('N');$random=[byte[]]::new(32);$generator=[Security.Cryptography.RandomNumberGenerator]::Create()
        try{$generator.GetBytes($random)}finally{$generator.Dispose()};$token=[Convert]::ToBase64String($random);$pipe=New-ServerPulseSecurePipe $pipeName;$wait=$pipe.BeginWaitForConnection($null,$null)
        $info.EnvironmentVariables['SSH_ASKPASS']=$AskPassPath;$info.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force';$info.EnvironmentVariables['DISPLAY']='ServerPulse';$info.EnvironmentVariables['SERVERPULSE_AUTH_PIPE']=$pipeName;$info.EnvironmentVariables['SERVERPULSE_AUTH_TOKEN']=$token
    }
    $process=$null
    try{
        $process=[Diagnostics.Process]::Start($info)
        if($Mode-eq'password'){
            $deadline=[datetime]::UtcNow.AddMilliseconds($TimeoutMs)
            while(-not$wait.AsyncWaitHandle.WaitOne(25)-and-not$process.HasExited-and[datetime]::UtcNow-lt$deadline){}
            if($wait.IsCompleted){
                $pipe.EndWaitForConnection($wait);$reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,1024,$true);$writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),1024,$true);$writer.AutoFlush=$true
                try{if($reader.ReadLine()-ne$token){throw'ASKPASS 认证令牌无效'};$writer.WriteLine($Password)}finally{$reader.Dispose();$writer.Dispose()}
            }elseif(-not$process.HasExited){try{$process.Kill()}catch{};throw'SSH 密码认证超时'}
        }
        if(-not$process.HasExited){$process.StandardInput.Write($Script);$process.StandardInput.Close()}
        return $process
    }catch{
        if($null-ne$process){try{if(-not$process.HasExited){$process.Kill()}}catch{};$process.Dispose()}
        throw
    }finally{if($null-ne$pipe){$pipe.Dispose()};$Password=$null;$token=$null}
}

function New-ServerPulsePersistentStore {
    param([int]$CircuitThreshold=6)
    return [PSCustomObject]@{Sessions=@{};CircuitThreshold=$CircuitThreshold}
}

function Stop-ServerPulsePersistentSession {
    param($Session)
    if($null-eq$Session){return}
    if($null-ne$Session.Process){try{if(-not$Session.Process.HasExited){$Session.Process.Kill();[void]$Session.Process.WaitForExit(1000)}}catch{};try{$Session.Process.Dispose()}catch{};$Session.Process=$null}
    $Session.ReadTask=$null;$Session.ErrorTask=$null;$Session.Frame.Clear()
}

function Remove-ServerPulsePersistentStore {
    param($Store)
    foreach($session in @($Store.Sessions.Values)){Stop-ServerPulsePersistentSession $session;$session.Password=$null}
    $Store.Sessions.Clear()
}

function New-ServerPulsePersistentSession {
    param($Server,[int]$IntervalSeconds,[int]$TimeoutMs,[string]$AskPassPath,[string]$SshPath,[int]$CircuitThreshold)
    $mode=if([string]$Server.AuthMode-in@('passwordless','password')){[string]$Server.AuthMode}else{'auto'}
    return [PSCustomObject]@{
        Id=[string]$Server.Id;Server=$Server;Signature='';RequestedAuthMode=$mode;CurrentMode=$(if($mode-eq'password'){'password'}else{'passwordless'});Password=[string]$Server.Password
        IntervalSeconds=$IntervalSeconds;TimeoutMs=$TimeoutMs;AskPassPath=$AskPassPath;SshPath=$SshPath;Process=$null;ReadTask=$null;ErrorTask=$null
        Frame=[Collections.Generic.List[string]]::new();InFrame=$false;FrameStartedAt=$null;Latest=$null;StartedAt=$null;LastSampleAt=$null
        Status='connecting';Error='';PasswordFallbackTried=$false;Retry=(New-ServerPulseRetryState -CircuitThreshold $CircuitThreshold)
    }
}

function Get-ServerPulsePersistentSignature {
    param($Server,[int]$IntervalSeconds,[string]$SshPath)
    return '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}'-f$Server.Source,$Server.SshTarget,$Server.HostName,$Server.Port,$Server.User,$Server.AuthMode,$IntervalSeconds,$SshPath
}

function Start-ServerPulsePersistentSession {
    param($Session,[string]$SampleScript)
    $loopScript=New-ServerPulseRemoteLoopScript -SampleScript $SampleScript -IntervalSeconds $Session.IntervalSeconds
    $Session.Process=Start-ServerPulsePersistentSshProcess -Server $Session.Server -Script $loopScript -Mode $Session.CurrentMode -Password $Session.Password -TimeoutMs $Session.TimeoutMs -AskPassPath $Session.AskPassPath -SshPath $Session.SshPath
    $Session.ReadTask=$Session.Process.StandardOutput.ReadLineAsync();$Session.ErrorTask=$Session.Process.StandardError.ReadToEndAsync();$Session.StartedAt=[datetime]::UtcNow;$Session.LastSampleAt=$null;$Session.Status='connecting';$Session.Error='';$Session.InFrame=$false;$Session.Frame.Clear()
}

function Complete-ServerPulsePersistentFrame {
    param($Session,[int]$ExitCode)
    if($ExitCode-ne0){$Session.Error="远端采样返回状态 $ExitCode";return}
    try{
        $output=$Session.Frame.ToArray()-join"`n";$metrics=ConvertFrom-ServerMetricsOutput -Output $output;$now=[datetime]::UtcNow
        $latency=if($null-ne$Session.FrameStartedAt){[int][Math]::Max(0,($now-$Session.FrameStartedAt).TotalMilliseconds)}else{$null}
        $Session.Latest=[PSCustomObject]@{Id=$Session.Id;Label=[string]$Session.Server.Label;Host=[string]$Session.Server.SshTarget;Status='online';AuthMode=$Session.CurrentMode;CheckedAt=$now.ToString('o');LatencyMs=$latency;Metrics=$metrics;Error=$null;RetryAt=$null;ConsecutiveFailures=0;CircuitOpen=$false}
        $Session.LastSampleAt=$now;$Session.Status='online';$Session.Error='';Reset-ServerPulseRetryState $Session.Retry
    }catch{$Session.Error="采样解析失败：$($_.Exception.Message)"}
}

function Read-ServerPulsePersistentOutput {
    param($Session)
    while($null-ne$Session.ReadTask){
        if(-not$Session.ReadTask.IsCompleted){try{if(-not$Session.ReadTask.Wait(2)){break}}catch{break}}
        try{$line=$Session.ReadTask.Result}catch{$line=$null;$Session.Error=$_.Exception.Message}
        if($null-eq$line){$Session.ReadTask=$null;break}
        $Session.ReadTask=$Session.Process.StandardOutput.ReadLineAsync()
        if($line-eq'__SERVERPULSE_SAMPLE_BEGIN__'){$Session.Frame.Clear();$Session.InFrame=$true;$Session.FrameStartedAt=[datetime]::UtcNow;continue}
        if($line-match'^__SERVERPULSE_SAMPLE_END__\s+(-?\d+)$'){
            if($Session.InFrame){Complete-ServerPulsePersistentFrame -Session $Session -ExitCode ([int]$matches[1])};$Session.InFrame=$false;$Session.Frame.Clear();continue
        }
        if($Session.InFrame){$Session.Frame.Add([string]$line)}
    }
}

function Set-ServerPulsePersistentFailure {
    param($Session,[string]$ErrorText,[datetime]$Now=[datetime]::UtcNow)
    Stop-ServerPulsePersistentSession $Session;$retry=Register-ServerPulseConnectionFailure -State $Session.Retry -Now $Now
    $Session.Error=if([string]::IsNullOrWhiteSpace($ErrorText)){'SSH 长期会话意外断开'}else{$ErrorText}
    $Session.Status=if($retry.CircuitOpen){'circuit_open'}else{'retry_wait'}
}

function Update-ServerPulsePersistentSession {
    param($Session,[string]$SampleScript,[datetime]$Now=[datetime]::UtcNow,[switch]$ForceReconnect)
    if($ForceReconnect){Stop-ServerPulsePersistentSession $Session;Reset-ServerPulseRetryState $Session.Retry;$Session.Latest=$null;$Session.PasswordFallbackTried=$false;$Session.CurrentMode=if($Session.RequestedAuthMode-eq'password'){'password'}else{'passwordless'};$Session.Status='connecting';$Session.Error=''}
    if($null-ne$Session.Process){
        Read-ServerPulsePersistentOutput $Session
        $timedOut=$false
        if(-not$Session.Process.HasExited){
            if($null-eq$Session.LastSampleAt){$timedOut=($Now-$Session.StartedAt).TotalMilliseconds-gt$Session.TimeoutMs}
            else{$maximumSilence=[Math]::Max(15.0,($Session.IntervalSeconds*4.0)+($Session.TimeoutMs/1000.0));$timedOut=($Now-$Session.LastSampleAt).TotalSeconds-gt$maximumSilence}
        }
        if($timedOut){Set-ServerPulsePersistentFailure $Session 'SSH 长期会话采样超时' $Now}
        elseif($Session.Process.HasExited){
            if($null-ne$Session.ReadTask){try{[void]$Session.ReadTask.Wait(100)}catch{};Read-ServerPulsePersistentOutput $Session}
            $stderr=if($null-ne$Session.ErrorTask-and$Session.ErrorTask.IsCompleted){[string]$Session.ErrorTask.Result}else{[string]$Session.Error};$kind=Get-ServerPulseSshFailureKind $stderr
            if($kind-eq'authentication'-and$Session.CurrentMode-eq'passwordless'-and$Session.RequestedAuthMode-eq'auto'-and-not[string]::IsNullOrEmpty($Session.Password)-and-not$Session.PasswordFallbackTried){
                Stop-ServerPulsePersistentSession $Session;$Session.PasswordFallbackTried=$true;$Session.CurrentMode='password';Start-ServerPulsePersistentSession $Session $SampleScript
            }elseif($kind-eq'authentication'){
                Stop-ServerPulsePersistentSession $Session;$Session.Status=if($Session.CurrentMode-eq'password'){'authentication_failed'}else{'authentication_required'};$Session.Error=$stderr
            }elseif($kind-in@('host_key_unknown','host_key_changed')){Stop-ServerPulsePersistentSession $Session;$Session.Status=$kind;$Session.Error=$stderr}
            else{Set-ServerPulsePersistentFailure $Session $stderr $Now}
        }
    }
    if($null-eq$Session.Process-and$Session.Status-notin@('authentication_required','authentication_failed','host_key_unknown','host_key_changed','circuit_open')){
        if($null-eq$Session.Retry.NextRetryAt-or$Now.ToUniversalTime()-ge$Session.Retry.NextRetryAt){
            try{Start-ServerPulsePersistentSession $Session $SampleScript}catch{Set-ServerPulsePersistentFailure $Session $_.Exception.Message $Now}
        }else{$Session.Status='retry_wait'}
    }
}

function ConvertTo-ServerPulsePersistentResult {
    param($Session,[datetime]$Now=[datetime]::UtcNow)
    if($Session.Status-eq'online'-and$null-ne$Session.Latest){return $Session.Latest}
    $retryAt=if($null-ne$Session.Retry.NextRetryAt){$Session.Retry.NextRetryAt.ToString('o')}else{$null}
    return [PSCustomObject]@{
        Id=$Session.Id;Label=[string]$Session.Server.Label;Host=[string]$Session.Server.SshTarget;Status=[string]$Session.Status;AuthMode=[string]$Session.CurrentMode
        CheckedAt=$Now.ToUniversalTime().ToString('o');LatencyMs=$null;Metrics=$null;Error=[string]$Session.Error;RetryAt=$retryAt
        ConsecutiveFailures=[int]$Session.Retry.FailureCount;CircuitOpen=[bool]$Session.Retry.CircuitOpen
    }
}

function Invoke-ServerPulsePersistentCollection {
    param($Runtime,$Store,[string]$SampleScript)
    $runtimeProperties=@($Runtime.PSObject.Properties.Name);$now=[datetime]::UtcNow
    $interval=if('PollIntervalSeconds'-in$runtimeProperties-and$Runtime.PollIntervalSeconds){[Math]::Max(1,[int]$Runtime.PollIntervalSeconds)}else{5}
    $timeout=if('SshTimeoutMs'-in$runtimeProperties-and$Runtime.SshTimeoutMs){[int]$Runtime.SshTimeoutMs}else{8000}
    $askPass=if('AskPassPath'-in$runtimeProperties){[string]$Runtime.AskPassPath}else{''};$sshPath=if('SshPath'-in$runtimeProperties-and$Runtime.SshPath){[string]$Runtime.SshPath}else{'ssh.exe'}
    $forced=@{};if('ForceReconnect'-in$runtimeProperties){foreach($id in @($Runtime.ForceReconnect)){$forced[[string]$id]=$true}};$active=@{}
    $results=foreach($server in @($Runtime.Servers)){
        $id=[string]$server.Id;$active[$id]=$true;$signature=Get-ServerPulsePersistentSignature $server $interval $sshPath
        if(-not$Store.Sessions.ContainsKey($id)){$Store.Sessions[$id]=New-ServerPulsePersistentSession $server $interval $timeout $askPass $sshPath $Store.CircuitThreshold;$Store.Sessions[$id].Signature=$signature}
        $session=$Store.Sessions[$id]
        if($session.Signature-ne$signature){Stop-ServerPulsePersistentSession $session;$Store.Sessions[$id]=New-ServerPulsePersistentSession $server $interval $timeout $askPass $sshPath $Store.CircuitThreshold;$session=$Store.Sessions[$id];$session.Signature=$signature}
        $session.Server=$server;$session.Password=[string]$server.Password;$session.TimeoutMs=$timeout;$session.AskPassPath=$askPass
        Update-ServerPulsePersistentSession -Session $session -SampleScript $SampleScript -Now $now -ForceReconnect:$forced.ContainsKey($id)
        ConvertTo-ServerPulsePersistentResult $session $now
    }
    foreach($id in @($Store.Sessions.Keys)){if(-not$active.ContainsKey([string]$id)){Stop-ServerPulsePersistentSession $Store.Sessions[$id];$Store.Sessions[$id].Password=$null;$Store.Sessions.Remove($id)}}
    return [PSCustomObject]@{GeneratedAt=$now.ToString('o');Servers=@($results)}
}
