$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}

$url = 'https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/windows/direct-sites.ps1'
$temp = Join-Path $env:TEMP 'lanpro-direct-sites.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $temp
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $temp install
Remove-Item -Force $temp -ErrorAction SilentlyContinue
