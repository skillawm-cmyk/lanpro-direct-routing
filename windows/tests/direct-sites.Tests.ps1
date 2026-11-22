$ErrorActionPreference = 'Stop'
$ScriptPath = Join-Path $PSScriptRoot '..\direct-sites.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT TRUE FAILED: $Message" }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { throw "ASSERT CONTAINS FAILED: $Message`nMissing: $Needle`nText: $Text" }
}

. $ScriptPath

$valid = @'
{"version":1,"rules":[{"type":"DOMAIN-SUFFIX","value":"moysklad.ru","policy":"DIRECT"}],"fixed_routes":[{"ipv4":"83.217.192.28","domains":["maily.life"],"include_www":true,"enabled":true},{"ipv4":"185.171.82.97","domains":[],"include_www":false,"enabled":true}]}
'@ | ConvertFrom-Json
$invalid = @'
{"version":2,"rules":[{"type":"DOMAIN","value":"lanpro.uz","policy":"DIRECT"}],"fixed_routes":[{"ipv4":"83.217.192.28","domains":[],"include_www":false,"enabled":true}]}
'@ | ConvertFrom-Json

Assert-True (Test-DirectConfig $valid) 'valid config should pass'
Assert-True (-not (Test-DirectConfig $invalid)) 'unknown version should fail'

$resolved = @{'moysklad.ru' = @('185.246.65.191')}
$block = Get-ManagedHostsBlock $valid $resolved
Assert-Contains $block '83.217.192.28 maily.life' 'apex host should be rendered'
Assert-Contains $block '83.217.192.28 www.maily.life' 'www host should be rendered'
Assert-True (-not $block.Contains('185.171.82.97 ')) 'IP-only route should not create hosts entry'
Assert-Contains $block '185.246.65.191 moysklad.ru' 'resolved direct rule should be pinned in hosts'

$existing = "127.0.0.1 localhost`r`n# BEGIN LANPRO DIRECT ROUTING`r`nold`r`n# END LANPRO DIRECT ROUTING`r`n"
$updated = Set-ManagedHostsContent $existing $block
Assert-Contains $updated '127.0.0.1 localhost' 'unmanaged hosts content should be preserved'
Assert-True (-not $updated.Contains("`r`nold`r`n")) 'old managed block should be replaced'
Assert-True (($updated.Split('# BEGIN LANPRO DIRECT ROUTING').Count - 1) -eq 1) 'managed block must not duplicate'

$commands = Get-RouteCommands $valid '192.168.0.1' @('185.246.65.191')
Assert-True ($commands.Count -eq 3) 'fixed and resolved IPs should each receive one route'
Assert-Contains ($commands -join "`n") '-p add 83.217.192.28 mask 255.255.255.255 192.168.0.1' 'route must be persistent and use physical gateway'

$ruleLines = Get-StashRuleLines $valid
Assert-True ($ruleLines.Count -eq 1) 'central Stash rules should render'
Assert-Contains $ruleLines[0] 'DOMAIN-SUFFIX,moysklad.ru,DIRECT' 'Stash rule should preserve type and policy'

Write-Host 'PASS windows client tests'
