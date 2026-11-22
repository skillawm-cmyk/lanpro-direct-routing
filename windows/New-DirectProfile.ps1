[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SocksAddress,
    [ValidateRange(1, 65535)][int]$SocksPort = 1080,
    [string]$ProfileDirectory = (Join-Path $env:LOCALAPPDATA 'LANPRO-Mihomo')
)

$ErrorActionPreference = 'Stop'
$ip = $null
if (-not [Net.IPAddress]::TryParse($SocksAddress, [ref]$ip) -or
    $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $ip.ToString() -cne $SocksAddress) {
    throw 'Enter the canonical IPv4 address of the SOCKS server in Tailscale.'
}
$octets = $ip.GetAddressBytes()
if ($octets[0] -ne 100 -or $octets[1] -lt 64 -or $octets[1] -gt 127) {
    throw 'The SOCKS server must be in the Tailnet IPv4 range (100.64.0.0/10).'
}

$profile = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'profile.template.json') | ConvertFrom-Json
$socks = $profile.proxies | Where-Object name -CEQ 'USA-SOCKS'
$socks.server = $SocksAddress
$socks.port = $SocksPort
$json = $profile | ConvertTo-Json -Depth 16
$seed = Join-Path (Split-Path -Parent $PSScriptRoot) 'stash/direct-rules.yaml'
if (-not (Test-Path -LiteralPath $seed -PathType Leaf)) { throw 'Bundled direct rules are missing.' }

$path = [IO.Path]::GetFullPath($ProfileDirectory)
$null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
$providers = New-Item -ItemType Directory -Path (Join-Path $path 'rule-providers') -ErrorAction Stop
[IO.File]::Copy($seed, (Join-Path $providers.FullName 'lanpro-direct.yaml'), $false)
[IO.File]::WriteAllText((Join-Path $path 'config.json'), $json, [Text.UTF8Encoding]::new($false))
Write-Host "Prepared Mihomo profile: $path"
