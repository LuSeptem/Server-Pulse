param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'ServerPulse.Core.ps1')

$config = Get-ServerPulseConfig -Path $ConfigPath
$remoteScript = @'
#!/bin/sh
read _ u1 n1 s1 i1 w1 q1 sq1 st1 rest < /proc/stat
t1=$((u1+n1+s1+i1+w1+q1+sq1+st1))
z1=$((i1+w1))
sleep 0.2
read _ u2 n2 s2 i2 w2 q2 sq2 st2 rest < /proc/stat
t2=$((u2+n2+s2+i2+w2+q2+sq2+st2))
z2=$((i2+w2))
cpu=$(awk -v dt=$((t2-t1)) -v di=$((z2-z1)) 'BEGIN { if (dt > 0) printf "%.1f", (dt-di)*100/dt; else print "0.0" }')
mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
mem_used=$((mem_total-mem_available))
mem_percent=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN { if (t > 0) printf "%.1f", u*100/t; else print "0.0" }')
set -- $(cat /proc/loadavg)
echo "HOSTNAME=$(hostname)"
echo "CPU_PERCENT=$cpu"
echo "MEM_TOTAL_KIB=$mem_total"
echo "MEM_USED_KIB=$mem_used"
echo "MEM_PERCENT=$mem_percent"
echo "LOAD_1=$1"
echo "LOAD_5=$2"
echo "LOAD_15=$3"
echo "UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)"
echo "GPUS_BEGIN"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null || true
fi
echo "GPUS_END"
'@

$corePath = Join-Path $PSScriptRoot 'ServerPulse.Core.ps1'
$jobs = foreach ($server in $config.Servers) {
    $serverJson = $server | ConvertTo-Json -Compress
    Start-Job -ScriptBlock {
        param($ServerJson, $Script, $TimeoutMs, $CorePath)
        $ErrorActionPreference = 'Stop'
        . $CorePath
        $server = $ServerJson | ConvertFrom-Json
        $started = [Diagnostics.Stopwatch]::StartNew()
        try {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = 'ssh.exe'
            $timeoutSeconds = [Math]::Max(1, [Math]::Ceiling($TimeoutMs / 1000))
            $info.Arguments = "-T -o BatchMode=yes -o ConnectTimeout=$timeoutSeconds $($server.host) sh -s"
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.StandardOutputEncoding = [Text.Encoding]::UTF8
            $info.StandardErrorEncoding = [Text.Encoding]::UTF8
            $process = [Diagnostics.Process]::Start($info)
            $process.StandardInput.Write($Script)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit($TimeoutMs)) {
                $process.Kill()
                throw "SSH 采集超时（$TimeoutMs ms）"
            }
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd().Trim()
            if ($process.ExitCode -ne 0) {
                if (-not $stderr) { $stderr = "SSH 退出码 $($process.ExitCode)" }
                throw $stderr
            }
            [PSCustomObject]@{
                Id        = [string]$server.id
                Label     = [string]$server.label
                Host      = [string]$server.host
                Status    = 'online'
                CheckedAt = [DateTime]::UtcNow.ToString('o')
                LatencyMs = [int]$started.ElapsedMilliseconds
                Metrics   = ConvertFrom-ServerMetricsOutput -Output $stdout
                Error     = $null
            }
        } catch {
            [PSCustomObject]@{
                Id        = [string]$server.id
                Label     = [string]$server.label
                Host      = [string]$server.host
                Status    = 'offline'
                CheckedAt = [DateTime]::UtcNow.ToString('o')
                LatencyMs = $null
                Metrics   = $null
                Error     = $_.Exception.Message
            }
        }
    } -ArgumentList $serverJson, $remoteScript, $config.SshTimeoutMs, $corePath
}

$results = foreach ($job in $jobs) {
    Receive-Job -Job $job -Wait -AutoRemoveJob
}

[PSCustomObject]@{
    GeneratedAt = [DateTime]::UtcNow.ToString('o')
    Servers     = @($results)
} | ConvertTo-Json -Depth 8 -Compress

