$script:ServerPulseCredentialTypeReady = $false

function Initialize-ServerPulseCredentialType {
    if ($script:ServerPulseCredentialTypeReady -or ('ServerPulse.NativeCredential' -as [type])) {
        $script:ServerPulseCredentialTypeReady = $true
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ServerPulse {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NativeCredentialData {
        public UInt32 Flags;
        public UInt32 Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static class NativeCredential {
        [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool CredWrite(ref NativeCredentialData credential, UInt32 flags);

        [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool CredRead(string target, UInt32 type, UInt32 flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool CredDelete(string target, UInt32 type, UInt32 flags);

        [DllImport("advapi32.dll", SetLastError=false)]
        public static extern void CredFree(IntPtr credential);
    }
}
'@
    $script:ServerPulseCredentialTypeReady = $true
}

function Test-ServerPulseServerField {
    param([string]$Value, [ValidateSet('Host','User','Alias')][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    switch ($Kind) {
        'Host' { return $Value -match '^[A-Za-z0-9._:-]+$' }
        'User' { return $Value -match '^[A-Za-z0-9._-]+$' }
        'Alias' { return $Value -match '^[A-Za-z0-9._-]+$' }
    }
}

function ConvertTo-ServerPulseCanonicalIdentity {
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$HostName, [int]$Port = 22)
    if (-not (Test-ServerPulseServerField $User User)) { throw 'SSH 用户名格式无效' }
    if (-not (Test-ServerPulseServerField $HostName Host)) { throw 'SSH 主机名或 IP 格式无效' }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'SSH 端口必须为 1–65535' }
    $hostPart = $HostName.Trim().ToLowerInvariant()
    if ($hostPart.Contains(':') -and -not $hostPart.StartsWith('[')) { $hostPart = "[$hostPart]" }
    return ('{0}@{1}:{2}' -f $User.Trim(), $hostPart, $Port)
}

function Get-ServerPulseCredentialTarget {
    param([Parameter(Mandatory)][string]$Identity)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity)) }
    finally { $sha.Dispose() }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return "ServerPulse:ssh:$hex"
}

function Set-ServerPulseStoredCredential {
    param([Parameter(Mandatory)][string]$Identity, [Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][string]$Password)
    Initialize-ServerPulseCredentialType
    $target = Get-ServerPulseCredentialTarget $Identity
    $blob = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($Password)
    try {
        $credential = [ServerPulse.NativeCredentialData]::new()
        $credential.Type = 1
        $credential.TargetName = $target
        $credential.Comment = "Server Pulse SSH credential for $Identity"
        $credential.CredentialBlobSize = [uint32]([Text.Encoding]::Unicode.GetByteCount($Password))
        $credential.CredentialBlob = $blob
        $credential.Persist = 2
        $credential.UserName = $UserName
        if (-not [ServerPulse.NativeCredential]::CredWrite([ref]$credential, 0)) {
            throw "写入 Windows 凭据管理器失败（Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())）"
        }
    } finally {
        if ($blob -ne [IntPtr]::Zero) {
            for ($offset = 0; $offset -lt [Text.Encoding]::Unicode.GetByteCount($Password); $offset += 2) { [Runtime.InteropServices.Marshal]::WriteInt16($blob, $offset, 0) }
            [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($blob)
        }
    }
}

function Get-ServerPulseStoredCredential {
    param([Parameter(Mandatory)][string]$Identity)
    Initialize-ServerPulseCredentialType
    $pointer = [IntPtr]::Zero
    $target = Get-ServerPulseCredentialTarget $Identity
    if (-not [ServerPulse.NativeCredential]::CredRead($target, 1, 0, [ref]$pointer)) { return $null }
    try {
        $credential = [Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type][ServerPulse.NativeCredentialData])
        $password = if ($credential.CredentialBlobSize -gt 0) { [Runtime.InteropServices.Marshal]::PtrToStringUni($credential.CredentialBlob, [int]($credential.CredentialBlobSize / 2)) } else { '' }
        return [PSCustomObject]@{ Identity=$Identity; Target=$target; UserName=[string]$credential.UserName; Password=$password }
    } finally { [ServerPulse.NativeCredential]::CredFree($pointer) }
}

function Test-ServerPulseStoredCredential {
    param([Parameter(Mandatory)][string]$Identity)
    Initialize-ServerPulseCredentialType
    $pointer=[IntPtr]::Zero
    if(-not[ServerPulse.NativeCredential]::CredRead((Get-ServerPulseCredentialTarget $Identity),1,0,[ref]$pointer)){return $false}
    try{return $true}finally{[ServerPulse.NativeCredential]::CredFree($pointer)}
}

function Remove-ServerPulseStoredCredential {
    param([Parameter(Mandatory)][string]$Identity)
    Initialize-ServerPulseCredentialType
    $target = Get-ServerPulseCredentialTarget $Identity
    if ([ServerPulse.NativeCredential]::CredDelete($target, 1, 0)) { return $true }
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($errorCode -eq 1168) { return $false }
    throw "删除 Windows 凭据失败（Win32 $errorCode）"
}

function ConvertTo-ServerPulseSecureStringText {
    param([Security.SecureString]$SecureString)
    if ($null -eq $SecureString) { return $null }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function New-ServerPulseSessionSecretStore { return @{} }

function Set-ServerPulseSessionSecret {
    param([hashtable]$Store, [string]$Identity, [string]$Password)
    if ($null -eq $Store) { throw '会话密码存储不可用' }
    if($Store.ContainsKey($Identity)-and$null-ne$Store[$Identity]){$Store[$Identity].Dispose()}
    $Store[$Identity] = ConvertTo-SecureString $Password -AsPlainText -Force
}

function Get-ServerPulseSessionSecret {
    param([hashtable]$Store, [string]$Identity)
    if ($null -eq $Store -or -not $Store.ContainsKey($Identity)) { return $null }
    return ConvertTo-ServerPulseSecureStringText $Store[$Identity]
}

function Remove-ServerPulseSessionSecret {
    param([hashtable]$Store, [string]$Identity)
    if ($null -ne $Store -and $Store.ContainsKey($Identity)) {
        $Store[$Identity].Dispose()
        $Store.Remove($Identity)
    }
}

function Clear-ServerPulseSessionSecrets {
    param([hashtable]$Store)
    if ($null -eq $Store) { return }
    foreach ($secret in @($Store.Values)) { if ($null -ne $secret) { $secret.Dispose() } }
    $Store.Clear()
}

function Invoke-ServerPulseProcess {
    param([string]$FileName, [string[]]$Arguments, [int]$TimeoutMs = 8000, [string]$StandardInput = $null, [hashtable]$Environment = $null)
    $quote = {
        param([string]$Value)
        if ($Value -notmatch '[\s"]') { return $Value }
        return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName
    $info.Arguments = (($Arguments | ForEach-Object { & $quote ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($null -ne $Environment) { foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[[string]$key] = [string]$Environment[$key] } }
    $process = [Diagnostics.Process]::Start($info)
    # Drain stdout/stderr asynchronously while the process runs; reading them
    # only after WaitForExit would block the child once the pipe buffer fills
    # (large merge pulls), so the wait would always time out.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $StandardInput) { $process.StandardInput.Write($StandardInput) }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutMs)) { try { $process.Kill() } catch { }; return [PSCustomObject]@{ExitCode=$null;Stdout='';Stderr='操作超时';TimedOut=$true;Arguments=$info.Arguments} }
    $stdout = if ($null -ne $stdoutTask) { try { $stdoutTask.Result } catch { '' } } else { '' }
    $stderr = if ($null -ne $stderrTask) { try { $stderrTask.Result } catch { '' } } else { '' }
    return [PSCustomObject]@{ExitCode=$process.ExitCode;Stdout=$stdout;Stderr=$stderr.Trim();TimedOut=$false;Arguments=$info.Arguments}
}

function Get-ServerPulseSshResolvedTarget {
    param([Parameter(Mandatory)][string]$Target, [string]$SshPath = 'ssh.exe')
    if (-not (Test-ServerPulseServerField $Target Alias)) { throw 'SSH 主机别名格式无效' }
    $result = Invoke-ServerPulseProcess -FileName $SshPath -Arguments @('-G','--',$Target) -TimeoutMs 5000
    if ($result.ExitCode -ne 0) { throw "无法解析 SSH 配置：$($result.Stderr)" }
    $values = @{}
    foreach ($line in ($result.Stdout -split "`r?`n")) {
        if ($line -match '^(hostname|user|port)\s+(.+)$') { $values[$matches[1]] = $matches[2].Trim() }
    }
    if (-not $values.hostname -or -not $values.user -or -not $values.port) { throw 'ssh -G 未返回完整的 hostname、user 和 port' }
    $identity = ConvertTo-ServerPulseCanonicalIdentity -User $values.user -HostName $values.hostname -Port ([int]$values.port)
    return [PSCustomObject]@{SshTarget=$Target;HostName=$values.hostname;User=$values.user;Port=[int]$values.port;Identity=$identity}
}

function Get-ServerPulseSshConfigAliases {
    param([string]$Path = (Join-Path $env:USERPROFILE '.ssh\config'))
    try { if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return @() } }
    catch { return @() }
    $aliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $clean = ($line -replace '\s+#.*$','').Trim()
        if ($clean -notmatch '^(?i)Host\s+(.+)$') { continue }
        foreach ($token in ($matches[1] -split '\s+')) {
            if ($token.StartsWith('!') -or $token -match '[*?]' -or -not (Test-ServerPulseServerField $token Alias)) { continue }
            [void]$aliases.Add($token)
        }
    }
    return @($aliases | Sort-Object)
}

function New-ServerPulseManagedServer {
    param([string]$Id, [string]$Label, [string]$Source, [string]$SshTarget, [string]$HostName, [int]$Port, [string]$User, [bool]$Monitored = $false)
    if (-not $Id) { $Id = [guid]::NewGuid().ToString('N') }
    $identity = ConvertTo-ServerPulseCanonicalIdentity -User $User -HostName $HostName -Port $Port
    return [PSCustomObject]@{Id=$Id;Label=$Label;Source=$Source;SshTarget=$SshTarget;HostName=$HostName;Port=$Port;User=$User;Identity=$identity;Monitored=$Monitored}
}

function Initialize-ServerPulseServerStore {
    param([Parameter(Mandatory)]$SeedConfig, [Parameter(Mandatory)][string]$Path, [string]$SshPath = 'ssh.exe')
    if (Test-Path -LiteralPath $Path) {
        try {
            $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $servers = foreach ($item in @($saved.Servers)) {
                $source=[string]$item.Source;$hostName=[string]$item.HostName;$port=[int]$item.Port;$user=[string]$item.User
                if($source-ne'manual'){try{$resolved=Get-ServerPulseSshResolvedTarget -Target ([string]$item.SshTarget) -SshPath $SshPath;$hostName=$resolved.HostName;$port=$resolved.Port;$user=$resolved.User}catch{}}
                New-ServerPulseManagedServer -Id ([string]$item.Id) -Label ([string]$item.Label) -Source $source -SshTarget ([string]$item.SshTarget) -HostName $hostName -Port $port -User $user -Monitored ([bool]$item.Monitored)
            }
            return [PSCustomObject]@{Version=1;Path=$Path;Servers=@($servers)}
        } catch { }
    }
    $servers = foreach ($seed in @($SeedConfig.Servers)) {
        try { $resolved = Get-ServerPulseSshResolvedTarget -Target ([string]$seed.host) -SshPath $SshPath }
        catch {
            $fallbackUser=if($env:USERNAME){$env:USERNAME}else{'unknown'}
            $resolved=[PSCustomObject]@{HostName=[string]$seed.host;Port=22;User=$fallbackUser}
        }
        New-ServerPulseManagedServer -Id ([string]$seed.id) -Label ([string]$seed.label) -Source 'seed' -SshTarget ([string]$seed.host) -HostName $resolved.HostName -Port $resolved.Port -User $resolved.User -Monitored $true
    }
    return [PSCustomObject]@{Version=1;Path=$Path;Servers=@($servers)}
}

function Save-ServerPulseServerStore {
    param([Parameter(Mandatory)]$Store)
    $directory = Split-Path -Parent $Store.Path
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $temporary = Join-Path $directory ('.servers-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ('.servers-{0}.bak' -f [guid]::NewGuid().ToString('N'))
    try {
        [PSCustomObject]@{Version=1;Servers=@($Store.Servers | Select-Object Id,Label,Source,SshTarget,HostName,Port,User,Monitored)} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if(Test-Path -LiteralPath $Store.Path){[IO.File]::Replace($temporary,$Store.Path,$backup)}else{[IO.File]::Move($temporary,$Store.Path)}
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Ensure-ServerPulseAskPassHelper {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { [void](New-Item -ItemType Directory -Path $Directory -Force) }
    $path = Join-Path $Directory 'ServerPulse.AskPass.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    $source = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;

public static class ServerPulseAskPass {
    public static int Main(string[] args) {
        string pipeName = Environment.GetEnvironmentVariable("SERVERPULSE_AUTH_PIPE");
        string token = Environment.GetEnvironmentVariable("SERVERPULSE_AUTH_TOKEN");
        if (String.IsNullOrEmpty(pipeName) || String.IsNullOrEmpty(token)) return 2;
        using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.None)) {
            pipe.Connect(5000);
            using (var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 1024, true))
            using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true)) {
                writer.AutoFlush = true;
                writer.WriteLine(token);
                string secret = reader.ReadLine();
                if (secret == null) return 3;
                Console.OutputEncoding = new UTF8Encoding(false);
                Console.WriteLine(secret);
            }
        }
        return 0;
    }
}
'@
    $sourcePath = Join-Path $Directory 'ServerPulse.AskPass.cs'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $compiler)) { throw '找不到 Windows 内置 C# 编译器，无法创建 SSH ASKPASS 辅助程序' }
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($true))
    try {
        $compile = Invoke-ServerPulseProcess -FileName $compiler -Arguments @('/nologo','/target:exe',("/out:$path"),$sourcePath) -TimeoutMs 15000
        if ($compile.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $path)) { throw "ASKPASS 辅助程序生成失败：$($compile.Stderr)$($compile.Stdout)" }
    } finally { if (Test-Path -LiteralPath $sourcePath) { Remove-Item -LiteralPath $sourcePath -Force } }
    return $path
}

function New-ServerPulseSecurePipe {
    param([string]$Name)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $security = [IO.Pipes.PipeSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $rule = [IO.Pipes.PipeAccessRule]::new($identity.User, [IO.Pipes.PipeAccessRights]::ReadWrite, [Security.AccessControl.AccessControlType]::Allow)
    [void]$security.AddAccessRule($rule)
    $aclType=[type]::GetType('System.IO.Pipes.NamedPipeServerStreamAcl, System.IO.Pipes.AccessControl',$false)
    if($null-ne$aclType){
        return $aclType::Create($Name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,0,0,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]::ChangePermissions)
    }
    $types=[type[]]@([string],[IO.Pipes.PipeDirection],[int],[IO.Pipes.PipeTransmissionMode],[IO.Pipes.PipeOptions],[int],[int],[IO.Pipes.PipeSecurity])
    $constructor=[IO.Pipes.NamedPipeServerStream].GetConstructor($types)
    if($null-eq$constructor){throw '当前 .NET 运行时不支持安全命名管道 ACL'}
    return $constructor.Invoke([object[]]@($Name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,0,0,$security))
}

function Get-ServerPulseSshArguments {
    param($Server, [ValidateSet('passwordless','password')][string]$Mode, [int]$TimeoutMs)
    $seconds = [Math]::Max(1, [Math]::Ceiling($TimeoutMs / 1000))
    $args = @('-T','-o',"ConnectTimeout=$seconds",'-o','StrictHostKeyChecking=yes','-o','NumberOfPasswordPrompts=1')
    if ($Mode -eq 'passwordless') { $args += @('-o','BatchMode=yes') }
    else { $args += @('-o','BatchMode=no','-o','PubkeyAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','PreferredAuthentications=password') }
    if ([string]$Server.Source -eq 'manual') {
        $destinationHost=[string]$Server.HostName
        if($destinationHost.Contains(':')-and-not$destinationHost.StartsWith('[')){$destinationHost="[$destinationHost]"}
        $args += @('-p',[string][int]$Server.Port,'--',("{0}@{1}" -f $Server.User,$destinationHost))
    } else { $args += @('--',[string]$Server.SshTarget) }
    $args += @('sh','-s')
    return $args
}

function Get-ServerPulseSshFailureKind {
    param([string]$ErrorText)
    if ($ErrorText -match 'REMOTE HOST IDENTIFICATION HAS CHANGED') { return 'host_key_changed' }
    if ($ErrorText -match 'Host key verification failed|No .* host key is known') { return 'host_key_unknown' }
    if ($ErrorText -match 'Permission denied|Authentication failed|Too many authentication failures') { return 'authentication' }
    return 'connection'
}

function Invoke-ServerPulseSsh {
    param($Server, [string]$Script, [ValidateSet('passwordless','password')][string]$Mode, [string]$Password, [int]$TimeoutMs, [string]$AskPassPath, [string]$SshPath='ssh.exe')
    $args = Get-ServerPulseSshArguments -Server $Server -Mode $Mode -TimeoutMs $TimeoutMs
    if ($Mode -eq 'passwordless') { return Invoke-ServerPulseProcess -FileName $SshPath -Arguments $args -TimeoutMs $TimeoutMs -StandardInput $Script }
    if ([string]::IsNullOrEmpty($Password)) { return [PSCustomObject]@{ExitCode=255;Stdout='';Stderr='未提供密码';TimedOut=$false;Arguments=''} }

    $pipeName = 'ServerPulse-' + [guid]::NewGuid().ToString('N')
    $random = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($random) } finally { $generator.Dispose() }
    $token = [Convert]::ToBase64String($random)
    $pipe = New-ServerPulseSecurePipe $pipeName
    $wait = $pipe.BeginWaitForConnection($null, $null)
    $environment = @{SSH_ASKPASS=$AskPassPath;SSH_ASKPASS_REQUIRE='force';DISPLAY='ServerPulse';SERVERPULSE_AUTH_PIPE=$pipeName;SERVERPULSE_AUTH_TOKEN=$token}
    $quote = { param([string]$Value); if($Value -notmatch '[\s"]'){return $Value}; return '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"' }
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName=$SshPath; $info.Arguments=(($args|ForEach-Object{& $quote ([string]$_)}) -join ' ')
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8; $info.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach($key in $environment.Keys){$info.EnvironmentVariables[$key]=$environment[$key]}
    $process=$null
    try {
        $process=[Diagnostics.Process]::Start($info)
        # Drain stdout/stderr while the process runs (see Invoke-ServerPulseProcess).
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $deadline=[DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while(-not $wait.AsyncWaitHandle.WaitOne(25) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { }
        if($wait.IsCompleted){
            $pipe.EndWaitForConnection($wait)
            $reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,1024,$true)
            $writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),1024,$true);$writer.AutoFlush=$true
            try { if($reader.ReadLine() -ne $token){throw 'ASKPASS 认证令牌无效'}; $writer.WriteLine($Password) }
            finally {$reader.Dispose();$writer.Dispose()}
        }
        if(-not $process.HasExited){$process.StandardInput.Write($Script);$process.StandardInput.Close()}
        if(-not $process.WaitForExit([Math]::Max(1,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds))){try{$process.Kill()}catch{};return [PSCustomObject]@{ExitCode=$null;Stdout='';Stderr='SSH 采集超时';TimedOut=$true;Arguments=$info.Arguments}}
        $stdout=if($null-ne$stdoutTask){try{$stdoutTask.Result}catch{''}}else{''}
        $stderr=if($null-ne$stderrTask){try{$stderrTask.Result}catch{''}}else{''}
        return [PSCustomObject]@{ExitCode=$process.ExitCode;Stdout=$stdout;Stderr=$stderr.Trim();TimedOut=$false;Arguments=$info.Arguments}
    } finally { $pipe.Dispose(); if($null -ne $process){$process.Dispose()} }
}

function Invoke-ServerPulseServerConnection {
    param($Server, [string]$Script, [ValidateSet('auto','passwordless','password')][string]$AuthMode='auto', [string]$Password, [int]$TimeoutMs=8000, [string]$AskPassPath, [string]$SshPath='ssh.exe')
    if($AuthMode -in @('auto','passwordless')){
        $batch=Invoke-ServerPulseSsh -Server $Server -Script $Script -Mode passwordless -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -SshPath $SshPath
        if($batch.ExitCode -eq 0){return [PSCustomObject]@{Status='online';AuthMode='passwordless';Output=$batch.Stdout;Error=$null}}
        $kind=Get-ServerPulseSshFailureKind $batch.Stderr
        if($kind -ne 'authentication' -or $AuthMode -eq 'passwordless'){return [PSCustomObject]@{Status=$(if($kind -eq 'authentication'){'authentication_required'}else{$kind});AuthMode='passwordless';Output=$null;Error=$batch.Stderr}}
    }
    if([string]::IsNullOrEmpty($Password)){return [PSCustomObject]@{Status='authentication_required';AuthMode='password';Output=$null;Error='需要输入 SSH 密码'}}
    $passwordResult=Invoke-ServerPulseSsh -Server $Server -Script $Script -Mode password -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -SshPath $SshPath
    if($passwordResult.ExitCode -eq 0){return [PSCustomObject]@{Status='online';AuthMode='password';Output=$passwordResult.Stdout;Error=$null}}
    $kind=Get-ServerPulseSshFailureKind $passwordResult.Stderr
    return [PSCustomObject]@{Status=$(if($kind -eq 'authentication'){'authentication_failed'}else{$kind});AuthMode='password';Output=$null;Error=$passwordResult.Stderr}
}

function Get-ServerPulseKnownHostsPath {
    $directory = Join-Path $env:USERPROFILE '.ssh'
    return Join-Path $directory 'known_hosts'
}

function Get-ServerPulseHostKeyProbe {
    param($Server, [int]$TimeoutMs=8000, [string]$SshPath='ssh.exe', [string]$SshKeygenPath='ssh-keygen.exe')
    $runtimeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-hostkey-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $runtimeDirectory -Force)
    $knownHosts = Join-Path $runtimeDirectory 'known_hosts'
    try {
        $seconds=[Math]::Max(1,[Math]::Ceiling($TimeoutMs/1000))
        $args=@('-vv','-T','-o',"ConnectTimeout=$seconds",'-o',"UserKnownHostsFile=$knownHosts",'-o','GlobalKnownHostsFile=NUL','-o','StrictHostKeyChecking=accept-new','-o','BatchMode=yes','-o','PreferredAuthentications=none')
        if([string]$Server.Source -eq 'manual'){
            $hostTarget=[string]$Server.HostName
            if($hostTarget.Contains(':') -and -not $hostTarget.StartsWith('[')){$hostTarget="[$hostTarget]"}
            $args+=@('-p',[string][int]$Server.Port,'--',("{0}@{1}" -f $Server.User,$hostTarget))
        }else{$args+=@('--',[string]$Server.SshTarget)}
        $args+=@('exit')
        $probe=Invoke-ServerPulseProcess -FileName $SshPath -Arguments $args -TimeoutMs $TimeoutMs
        if(-not (Test-Path -LiteralPath $knownHosts)){throw "无法取得服务器主机密钥：$($probe.Stderr)"}
        $lines=@(Get-Content -LiteralPath $knownHosts -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if($lines.Count -eq 0){throw '服务器未返回可确认的 SSH 主机密钥'}
        $fingerprint=Invoke-ServerPulseProcess -FileName $SshKeygenPath -Arguments @('-lf',$knownHosts,'-E','sha256') -TimeoutMs 5000
        if($fingerprint.ExitCode -ne 0){throw "无法计算 SSH 指纹：$($fingerprint.Stderr)"}
        return [PSCustomObject]@{Lines=$lines;Fingerprints=@($fingerprint.Stdout -split "`r?`n" | Where-Object { $_ });Diagnostics=$probe.Stderr}
    } finally {
        if(Test-Path -LiteralPath $knownHosts){Remove-Item -LiteralPath $knownHosts -Force}
        if(Test-Path -LiteralPath $runtimeDirectory){Remove-Item -LiteralPath $runtimeDirectory -Force}
    }
}

function Get-ServerPulseKnownHostFingerprints {
    param($Server,[string]$KnownHostsPath=(Get-ServerPulseKnownHostsPath),[string]$SshKeygenPath='ssh-keygen.exe')
    if(-not(Test-Path -LiteralPath $KnownHostsPath)){return @()}
    $lookup=if([int]$Server.Port-eq22){[string]$Server.HostName}else{"[$($Server.HostName)]:$([int]$Server.Port)"}
    $found=Invoke-ServerPulseProcess -FileName $SshKeygenPath -Arguments @('-F',$lookup,'-f',$KnownHostsPath) -TimeoutMs 5000
    $keyLines=@($found.Stdout -split "`r?`n"|Where-Object{$_ -and -not$_.StartsWith('#')})
    if($keyLines.Count-eq0){return @()}
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('serverpulse-old-key-'+[guid]::NewGuid().ToString('N'))
    try{
        [IO.File]::WriteAllLines($temporary,$keyLines,[Text.UTF8Encoding]::new($false))
        $fingerprints=Invoke-ServerPulseProcess -FileName $SshKeygenPath -Arguments @('-lf',$temporary,'-E','sha256') -TimeoutMs 5000
        if($fingerprints.ExitCode-ne0){return @()}
        return @($fingerprints.Stdout -split "`r?`n"|Where-Object{$_})
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function Add-ServerPulseTrustedHostKey {
    param([Parameter(Mandatory)][string[]]$Lines, [string]$KnownHostsPath=(Get-ServerPulseKnownHostsPath))
    $directory=Split-Path -Parent $KnownHostsPath
    if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory -Force)}
    $existing=if(Test-Path -LiteralPath $KnownHostsPath){@(Get-Content -LiteralPath $KnownHostsPath -Encoding UTF8)}else{@()}
    $append=@($Lines | Where-Object { $_ -and $_ -notin $existing })
    if($append.Count -gt 0){
        $prefix=''
        if(Test-Path -LiteralPath $KnownHostsPath){$bytes=[IO.File]::ReadAllBytes($KnownHostsPath);if($bytes.Length-gt0-and$bytes[-1]-notin@(10,13)){$prefix="`r`n"}}
        [IO.File]::AppendAllText($KnownHostsPath,$prefix+($append-join"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
    }
    return $append.Count
}
