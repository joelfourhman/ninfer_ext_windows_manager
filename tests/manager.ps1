#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../ninfer-manager.ps1')
$testRoot=Join-Path $script:Root ('temp/powershell-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:State=$testRoot
$script:Runtime=Join-Path $testRoot 'runtime'
[void][IO.Directory]::CreateDirectory($script:Runtime)
$script:Compose=Join-Path $script:Runtime 'compose.json'
$script:SettingsFile=Join-Path $testRoot 'settings.json'
$script:KeysFile=Join-Path $script:Runtime 'clients.json'
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
try {
 Write-Json $script:KeysFile @{clients=@()}
 $one=New-ClientKey 'test' 1
 $two=New-ClientKey 'test' 0
 Assert ($one.token -ne $two.token) 'Client keys must be unique.'
 Assert (((Read-Json $script:KeysFile).clients | Where-Object id -eq $one.id).sha256 -eq (Get-Digest $one.token)) 'Key hash mismatch.'
 Assert (-not([IO.File]::ReadAllText($script:KeysFile).Contains($one.token))) 'Registry contains plaintext key.'
 Revoke-ClientKey $one.id
 Assert ([bool]((Read-Json $script:KeysFile).clients | Where-Object id -eq $one.id).revokedUtc) 'Revocation was not persisted.'
 Assert (-not((Read-Json $script:KeysFile).clients | Where-Object id -eq $two.id).revokedUtc) 'Revoking one key affected another.'
 $policy=Get-Policy
 Assert ($policy.compressionTriggerTokens + $policy.maxOutputTokens -lt $policy.contextLength) 'Compaction has no output headroom.'
 Write-Json $script:SettingsFile @{modelArtifact='test.ninfer';runtime=@{maxContext=262144;kvDtype='k8v4';memoryHeadroom='512MiB';hostCapacity='8GiB';draftTokens=5};network=@{enabled=$false;localPort=8080;httpsPort=8443;address='';hostname='';trustedSubnet=''}}
 [IO.File]::WriteAllText((Join-Path $testRoot 'backend-secret.txt'),'synthetic-backend-secret')
 Write-Runtime
 $renderedCompose=Read-Json $script:Compose
 Assert (-not($renderedCompose.services.ninfer.PSObject.Properties.Name -contains 'ports')) 'Raw engine port is exposed.'
 Assert ($renderedCompose.services.gateway.ports[0] -eq '127.0.0.1:8080:8080') 'Local gateway must bind loopback.'
 Assert (-not([IO.File]::ReadAllText($script:Compose).Contains('synthetic-backend-secret'))) 'Secret leaked into Compose.'
 Assert ($renderedCompose.networks.backend.internal) 'Backend network must be internal.'
 $firstConfigDigest=$renderedCompose.services.ninfer.labels.'com.ninfer-manager.config-sha256'
 $changedSettings=Get-Settings;$changedSettings.runtime.draftTokens=3;Write-Json $script:SettingsFile $changedSettings
 Write-Runtime
 Assert ((Read-Json $script:Compose).services.ninfer.labels.'com.ninfer-manager.config-sha256' -ne $firstConfigDigest) 'Changing startup configuration must recreate the engine.'
 $settings=Get-Settings;$settings.network.enabled=$true;$settings.network.address='192.168.50.115';$settings.network.hostname='192.168.50.115';Write-Json $script:SettingsFile $settings
 Write-Runtime;$renderedCompose=Read-Json $script:Compose
 Assert ($renderedCompose.services.caddy.ports[0] -eq '192.168.50.115:8443:8443') 'HTTPS must bind the selected interface.'
 Assert ((Get-Content (Join-Path $script:Runtime 'Caddyfile') -Raw).Contains('tls internal')) 'LAN TLS missing.'
 Write-Host 'PASS manager key lifecycle, isolation, secret handling, context budgets, and runtime generation.'
} finally {
 # Only this freshly created test directory may be removed.
 $expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../temp'))+[IO.Path]::DirectorySeparatorChar
 if([IO.Path]::GetFullPath($testRoot).StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
