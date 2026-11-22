[CmdletBinding()]
param(
    [ValidateSet('install', 'sync', 'status', 'test', 'uninstall', 'rules')]
    [string]$Command = 'status',
    [string]$Target,
    [string]$ConfigUrl = 'https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/direct-sites.json',
    [string]$StateDir = "$env:ProgramData\LanproDirectRouting",
    [string]$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts",
    [switch]$DryRun
)

$script:BeginMarker = '# BEGIN LANPRO DIRECT ROUTING'
$script:EndMarker = '# END LANPRO DIRECT ROUTING'

function Test-IPv4([string]$Value) {
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-Domain([string]$Value) {
    return $Value -match '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
}

function Test-RuleValue([string]$Type, [string]$Value) {
    if (Test-Domain $Value) { return $true }
    return $Type -eq 'DOMAIN-SUFFIX' -and $Value -match '^[a-z]{2,63}$'
}

function Test-DirectConfig($Config) {
    if ($null -eq $Config -or $Config.version -ne 1) { return $false }
    if ($null -eq $Config.rules -or @($Config.rules).Count -eq 0) { return $false }
    if ($null -eq $Config.fixed_routes -or @($Config.fixed_routes).Count -eq 0) { return $false }

    $seenRules = @{}
    foreach ($rule in @($Config.rules)) {
        if (@('DOMAIN', 'DOMAIN-SUFFIX') -notcontains [string]$rule.type) { return $false }
        if (-not (Test-RuleValue ([string]$rule.type) ([string]$rule.value))) { return $false }
        if ([string]$rule.policy -ne 'DIRECT') { return $false }
        $key = "$( [string]$rule.type ),$( [string]$rule.value )"
        if ($seenRules.ContainsKey($key)) { return $false }
        $seenRules[$key] = $true
    }

    $seenIPs = @{}
    $seenDomains = @{}
    foreach ($route in @($Config.fixed_routes)) {
        $ip = [string]$route.ipv4
        if (-not (Test-IPv4 $ip) -or $seenIPs.ContainsKey($ip)) { return $false }
        $seenIPs[$ip] = $true
        if ($route.include_www -isnot [bool] -or $route.enabled -isnot [bool]) { return $false }
        foreach ($domain in @($route.domains)) {
            $name = [string]$domain
            if (-not (Test-Domain $name) -or $seenDomains.ContainsKey($name)) { return $false }
            $seenDomains[$name] = $ip
        }
    }
    return $true
}

function Get-StashRuleLines($Config) {
    return @($Config.rules | ForEach-Object { "$($_.type),$($_.value),$($_.policy)" })
}

function Get-ManagedHostsBlock($Config, [hashtable]$ResolvedDomains = @{}) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($script:BeginMarker)
    foreach ($route in @($Config.fixed_routes | Where-Object { $_.enabled })) {
        foreach ($domain in @($route.domains)) {
            $lines.Add("$($route.ipv4) $domain")
            if ($route.include_www -and -not $domain.StartsWith('www.')) {
                $lines.Add("$($route.ipv4) www.$domain")
            }
        }
    }
    foreach ($domain in @($ResolvedDomains.Keys | Sort-Object)) {
        $ips = @($ResolvedDomains[$domain])
        if ($ips.Count -gt 0) { $lines.Add("$($ips[0]) $domain") }
    }
    $lines.Add($script:EndMarker)
    return ($lines -join "`r`n")
}

function Set-ManagedHostsContent([string]$Existing, [string]$Block) {
    $pattern = '(?ms)^' + [regex]::Escape($script:BeginMarker) + '.*?^' + [regex]::Escape($script:EndMarker) + '\s*'
    $clean = [regex]::Replace($Existing, $pattern, '').TrimEnd("`r", "`n")
    if ($clean.Length -eq 0) { return "$Block`r`n" }
    return "$clean`r`n$Block`r`n"
}

function Get-RouteCommands($Config, [string]$Gateway, [string[]]$ResolvedIPs = @()) {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($route in @($Config.fixed_routes | Where-Object { $_.enabled })) { $all.Add([string]$route.ipv4) }
    foreach ($ip in @($ResolvedIPs)) { if (Test-IPv4 $ip) { $all.Add($ip) } }
    return @($all | Sort-Object -Unique | ForEach-Object {
        "route.exe -p add $_ mask 255.255.255.255 $Gateway metric 1"
    })
}

function Get-PhysicalGateway {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceMetric)
    foreach ($route in $routes) {
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if ($null -eq $adapter) { continue }
        if ($adapter.Name -match 'Tailscale|Meta|Mihomo|Clash|v2Ray|Tunnel|WireGuard') { continue }
        return [pscustomobject]@{ Gateway = $route.NextHop; InterfaceIndex = $route.InterfaceIndex; Adapter = $adapter.Name }
    }
    throw 'Physical IPv4 gateway was not found.'
}

function Resolve-PublicIPv4([string]$Domain) {
    $uri = 'https://cloudflare-dns.com/dns-query?name=' + [uri]::EscapeDataString($Domain) + '&type=A'
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Accept = 'application/dns-json' } -TimeoutSec 15
        return @($response.Answer | Where-Object { $_.type -eq 1 -and (Test-IPv4 ([string]$_.data)) } | ForEach-Object { [string]$_.data } | Sort-Object -Unique)
    } catch {
        try {
            return @([System.Net.Dns]::GetHostAddresses($Domain) | Where-Object {
                $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
            } | ForEach-Object { $_.IPAddressToString } | Sort-Object -Unique)
        } catch { return @() }
    }
}

function Get-ResolvedRuleTargets($Config) {
    $map = @{}
    foreach ($rule in @($Config.rules)) {
        $domain = [string]$rule.value
        if ($domain -notmatch '\.') { continue }
        $names = @($domain)
        if ($rule.type -eq 'DOMAIN-SUFFIX') { $names += "www.$domain" }
        foreach ($name in $names | Sort-Object -Unique) {
            $ips = @(Resolve-PublicIPv4 $name)
            if ($ips.Count -gt 0) { $map[$name] = $ips }
        }
    }
    return $map
}

function Save-AtomicText([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$Path.tmp.$PID"
    [System.IO.File]::WriteAllText($temp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $temp $Path
}

function Get-RemoteConfig {
    $text = (Invoke-WebRequest -UseBasicParsing -Uri $ConfigUrl -TimeoutSec 20).Content
    $config = $text | ConvertFrom-Json
    if (-not (Test-DirectConfig $config)) { throw 'Downloaded direct routing config is invalid.' }
    Save-AtomicText (Join-Path $StateDir 'direct-sites.json') $text
    return $config
}

function Get-CachedConfig {
    $path = Join-Path $StateDir 'direct-sites.json'
    if (-not (Test-Path $path)) { throw 'No valid cached configuration is available.' }
    $config = Get-Content -Raw $path | ConvertFrom-Json
    if (-not (Test-DirectConfig $config)) { throw 'Cached direct routing config is invalid.' }
    return $config
}

function Invoke-Sync {
    try { $config = Get-RemoteConfig } catch { Write-Warning $_; $config = Get-CachedConfig }
    $physical = Get-PhysicalGateway
    $resolved = Get-ResolvedRuleTargets $config
    $resolvedIPs = @($resolved.Values | ForEach-Object { $_ } | Sort-Object -Unique)
    $commands = @(Get-RouteCommands $config $physical.Gateway $resolvedIPs)
    $newIPs = @($config.fixed_routes | Where-Object { $_.enabled } | ForEach-Object { $_.ipv4 }) + $resolvedIPs | Sort-Object -Unique
    $statePath = Join-Path $StateDir 'state.json'
    $oldIPs = @()
    if (Test-Path $statePath) { try { $oldIPs = @((Get-Content -Raw $statePath | ConvertFrom-Json).ips) } catch {} }

    if ($DryRun) {
        Write-Host "Physical gateway: $($physical.Gateway) ($($physical.Adapter))"
        $commands | ForEach-Object { Write-Host $_ }
        return
    }

    foreach ($ip in @($oldIPs | Where-Object { $newIPs -notcontains $_ })) {
        & route.exe delete $ip mask 255.255.255.255 | Out-Null
    }
    foreach ($line in $commands) {
        $parts = $line -split ' '
        & route.exe @($parts[1..($parts.Count - 1)]) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & route.exe -p change $parts[3] mask 255.255.255.255 $physical.Gateway metric 1 | Out-Null
        }
    }
    $block = Get-ManagedHostsBlock $config $resolved
    $existing = if (Test-Path $HostsPath) { Get-Content -Raw $HostsPath } else { '' }
    Save-AtomicText $HostsPath (Set-ManagedHostsContent $existing $block)
    $state = [ordered]@{ synced_at = (Get-Date).ToString('o'); gateway = $physical.Gateway; adapter = $physical.Adapter; ips = @($newIPs); domains = @($resolved.Keys) }
    Save-AtomicText $statePath ($state | ConvertTo-Json -Depth 5)
    ipconfig.exe /flushdns | Out-Null
    Write-Host "Direct routing synchronized: $($newIPs.Count) IPs, $($resolved.Keys.Count) resolved names."
}

function Install-DirectRouting {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $installed = Join-Path $StateDir 'direct-sites.ps1'
    Copy-Item -Force $PSCommandPath $installed
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$installed`" sync"
    $triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30)))
    Register-ScheduledTask -TaskName 'LANPRO Direct Routing' -Action $action -Trigger $triggers -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
    Invoke-Sync
}

function Uninstall-DirectRouting {
    $statePath = Join-Path $StateDir 'state.json'
    if (Test-Path $statePath) {
        $state = Get-Content -Raw $statePath | ConvertFrom-Json
        foreach ($ip in @($state.ips)) { if (-not $DryRun) { & route.exe delete $ip mask 255.255.255.255 | Out-Null } }
    }
    if (Test-Path $HostsPath) {
        $clean = Set-ManagedHostsContent (Get-Content -Raw $HostsPath) ''
        $clean = $clean -replace '(?ms)^\s*' + [regex]::Escape($script:BeginMarker) + '\s*' + [regex]::Escape($script:EndMarker) + '\s*', ''
        if (-not $DryRun) { Save-AtomicText $HostsPath $clean }
    }
    if (-not $DryRun) {
        Unregister-ScheduledTask -TaskName 'LANPRO Direct Routing' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
    }
    Write-Host 'LANPRO Direct Routing removed.'
}

function Show-Status {
    $statePath = Join-Path $StateDir 'state.json'
    if (-not (Test-Path $statePath)) { Write-Host 'Not installed or not synchronized.'; return }
    Get-Content -Raw $statePath
}

function Test-DirectTarget([string]$Domain) {
    if (-not $Domain) { throw 'Provide a domain after test.' }
    Resolve-PublicIPv4 $Domain | ForEach-Object { Write-Host "Public IPv4: $_" }
    & curl.exe -4 -I -L --connect-timeout 10 "https://$Domain/"
}

function Invoke-DirectRoutingCommand {
    switch ($Command) {
        'install' { Install-DirectRouting }
        'sync' { Invoke-Sync }
        'status' { Show-Status }
        'test' { Test-DirectTarget $Target }
        'uninstall' { Uninstall-DirectRouting }
        'rules' { $config = try { Get-RemoteConfig } catch { Get-CachedConfig }; Get-StashRuleLines $config }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-DirectRoutingCommand }
