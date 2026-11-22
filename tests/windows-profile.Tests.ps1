$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path ([IO.Path]::GetTempPath()) ('lanpro-test-' + [guid]::NewGuid())
$makeProfile = Join-Path $root 'windows/New-DirectProfile.ps1'
try {
    & $makeProfile -SocksAddress '100.64.0.10' -SocksPort 2080 -ProfileDirectory $target
    $profile = Get-Content -Raw -LiteralPath (Join-Path $target 'config.json')
    $socks = ($profile | ConvertFrom-Json).proxies | Where-Object name -eq 'USA-SOCKS'
    if ($socks.server -cne '100.64.0.10' -or $socks.port -ne 2080 -or $profile.Contains('__USA_')) {
        throw 'Profile did not substitute the validated endpoint.'
    }
    $provider = Join-Path $target 'rule-providers/lanpro-direct.yaml'
    if ((Get-FileHash $provider).Hash -ne (Get-FileHash (Join-Path $root 'stash/direct-rules.yaml')).Hash) {
        throw 'Seed rules did not match the published package.'
    }
    $changed = $false
    try { & $makeProfile -SocksAddress '100.64.0.11' -ProfileDirectory $target; $changed = $true } catch {}
    if ($changed -or (Get-Content -Raw (Join-Path $target 'config.json')) -ne $profile) {
        throw 'Existing profile was replaced.'
    }
    foreach ($invalid in @('8.8.8.8', '100.128.0.1', '100.64.1', '100.064.0.1', "100.64.0.10`nmode: direct")) {
        $accepted = $false
        try { & $makeProfile -SocksAddress $invalid -ProfileDirectory (Join-Path $target 'invalid'); $accepted = $true } catch {}
        if ($accepted -or (Test-Path (Join-Path $target 'invalid'))) { throw 'Accepted an invalid Tailnet address.' }
    }
    Write-Host 'PASS Windows profile preparation (no privileged changes)'
} finally {
    if (Test-Path -LiteralPath $target) { Remove-Item -Recurse -Force -LiteralPath $target }
}
