param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'ServerPulse.exe')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source = Join-Path $root 'src\ServerPulse.Host.cs'
$icon = Join-Path $root 'assets\server-pulse.ico'
$automation = [Management.Automation.PowerShell].Assembly.Location
foreach ($path in @($compiler,$source,$icon,$automation)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing EXE build dependency: $path" }
}

& $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 "/win32icon:$icon" "/out:$OutputPath" "/reference:$automation" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) { throw 'ServerPulse.exe build failed' }

$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($OutputPath)
if ($version.ProductName -ne 'Server Pulse') { throw 'ServerPulse.exe version resource validation failed' }
Write-Output "BUILT: $OutputPath"
