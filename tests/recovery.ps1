#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../ninfer-manager.ps1')
$projectRoot=$script:Root
$fixture=Join-Path $projectRoot ('temp/review-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$script:State=$fixture;$script:Runtime=Join-Path $fixture 'runtime'
[void][IO.Directory]::CreateDirectory($script:Runtime)
$script:SettingsFile=Join-Path $fixture 'settings.json';$script:KeysFile=Join-Path $script:Runtime 'clients.json'
$script:Compose=Join-Path $script:Runtime 'compose.json';$script:Models=Join-Path $fixture 'models'
[void][IO.Directory]::CreateDirectory($script:Models)
[IO.File]::WriteAllText((Join-Path $script:Models 'test.ninfer'),'synthetic-model')
[IO.File]::WriteAllText((Join-Path $script:State 'backend-secret.txt'),'synthetic-backend')
Write-Json $script:SettingsFile @{modelArtifact='test.ninfer';runtime=@{maxContext=262144;kvDtype='k8v4';memoryHeadroom='512MiB';hostCapacity='8GiB';draftTokens=5};network=@{enabled=$true;localPort=8080;httpsPort=8443;address='192.168.50.115';hostname='192.168.50.115';trustedSubnet='192.168.50.0/24'}}
Write-Json $script:KeysFile @{clients=@()}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Protect-Directory($Path){}
$script:MarkHidden=$false
function Protect-SecretFile($Path){
 $script:BeforeProtection=[IO.File]::ReadAllText($Path)
 if($script:MarkHidden -and $IsWindows){[IO.File]::SetAttributes($Path,([IO.File]::GetAttributes($Path) -bor [IO.FileAttributes]::Hidden))}
}
function Get-HermesCommand {'fixture-hermes'}
function Export-Certificate($Destination){[IO.File]::WriteAllText($Destination,'new-public-ca')}
$script:Calls=[Collections.Generic.List[object]]::new();$script:FailHermes=$false
function Invoke-External([string]$File,[string[]]$Arguments){
 $script:Calls.Add(@{file=$File;arguments=$Arguments;home=$env:HERMES_HOME})
 if($File -eq 'fixture-hermes'){
  Assert ($Arguments[0] -eq '--profile' -and $Arguments[1] -eq 'default') 'Sticky profiles can redirect Hermes setup.'
  $configFile=Join-Path $env:HERMES_HOME 'config.yaml'
  [IO.File]::AppendAllText($configFile,"`n# fixture setter")
  if($script:FailHermes){throw 'Synthetic Hermes failure'}
 }
}
$previousHome=$env:HERMES_HOME
try {
 $OutputDirectory=Join-Path $fixture 'hermes-existing';[void][IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'certs'))
 $originalConfig="model:`n  default: chatgpt-fixture`ncompression:`n  threshold: 0.5`n"
 $originalEnvironment="UNRELATED_KEY=keep`n`n# preserve comment`n"
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'config.yaml'),$originalConfig)
 [IO.File]::WriteAllText((Join-Path $OutputDirectory '.env'),$originalEnvironment)
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'certs/ninfer-root-ca.crt'),'old-public-ca')
 $env:HERMES_HOME=Join-Path $fixture 'another-home'
 Export-Hermes
 Assert ($env:HERMES_HOME -eq (Join-Path $fixture 'another-home')) 'Export changed the caller home.'
 Assert ($script:BeforeProtection -eq $originalEnvironment) 'Secret was written before access restriction.'
 $configCalls=@($script:Calls | Where-Object file -eq 'fixture-hermes')
 Assert ($configCalls.Count -eq 7) 'Unexpected Hermes mutation count.'
 Assert (-not(@($configCalls | Where-Object {$_.arguments[4] -in @('model.default','model.provider','compression.threshold','compression.threshold_tokens')}).Count)) 'Export overwrites a default model/compaction policy.'
 $provider=$configCalls[0].arguments[5]|ConvertFrom-Json
 Assert ($provider.ssl_verify -and $provider.context_length -eq 262144 -and $provider.base_url.StartsWith('https://')) 'Qwen connection lost context/TLS settings.'
 Assert ($configCalls[1].arguments[4] -eq 'compression.model_thresholds.qwen' -and $configCalls[1].arguments[5] -eq '0.75') 'Qwen compaction is not model-specific.'
 Assert ([IO.File]::ReadAllText((Join-Path $OutputDirectory 'config.yaml')).Contains('default: chatgpt-fixture')) 'Default model was replaced.'
 $configuredEnv=[IO.File]::ReadAllText((Join-Path $OutputDirectory '.env'))
 Assert ($configuredEnv.Contains('UNRELATED_KEY=keep') -and $configuredEnv.Contains('# preserve comment')) 'Unrelated environment content was lost.'
 $configuredToken=([regex]::Match($configuredEnv,'HERMES_CUSTOM_QWEN_API_KEY=(\S+)')).Groups[1].Value
 Assert (-not(($script:Calls|ConvertTo-Json -Depth 5).Contains($configuredToken))) 'API key leaked into command arguments.'
 # Failure restores the previous working model, key ID, environment, and public trust anchor.
 $beforeConfig=[IO.File]::ReadAllText((Join-Path $OutputDirectory 'config.yaml'))
 $beforeId=[IO.File]::ReadAllText((Join-Path $OutputDirectory 'ninfer-client-key-id.txt'))
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'certs/ninfer-root-ca.crt'),'working-public-ca')
 $script:FailHermes=$true;$caught=$false
 try{Export-Hermes}catch{$caught=$_.Exception.Message -eq 'Synthetic Hermes failure'}
 Assert $caught 'Export did not propagate the setup failure.'
 Assert ([IO.File]::ReadAllText((Join-Path $OutputDirectory 'config.yaml')) -eq $beforeConfig) 'Failed export changed config.'
 Assert ([IO.File]::ReadAllText((Join-Path $OutputDirectory '.env')) -eq $configuredEnv) 'Failed export changed credentials.'
 Assert ([IO.File]::ReadAllText((Join-Path $OutputDirectory 'ninfer-client-key-id.txt')) -eq $beforeId) 'Failed export changed key ID.'
 Assert ([IO.File]::ReadAllText((Join-Path $OutputDirectory 'certs/ninfer-root-ca.crt')) -eq 'working-public-ca') 'Failed export changed CA trust.'
 $keys=Read-Json $script:KeysFile
 Assert (-not $keys.clients[0].revokedUtc -and [bool]$keys.clients[-1].revokedUtc) 'Failure revoked the wrong client key.'
 # A home with no prior key or certificate must not retain failed setup files.
 $script:MarkHidden=$true
 $OutputDirectory=Join-Path $fixture 'hermes-new';[void][IO.Directory]::CreateDirectory($OutputDirectory)
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'config.yaml'),$originalConfig)
 try{Export-Hermes}catch{}
 foreach($name in @('.env','ninfer-client-key-id.txt','certs/ninfer-root-ca.crt')){Assert (-not(Test-Path -LiteralPath (Join-Path $OutputDirectory $name))) "Failed setup retained $name."}
 Assert ($script:BeforeProtection -eq '') 'New secret file was not restricted before writing.'
 # Every gateway revision gets its own image identity; old Compose snapshots remain usable.
 $imageRoot=Join-Path $fixture 'image';[void][IO.Directory]::CreateDirectory((Join-Path $imageRoot 'gateway'));[void][IO.Directory]::CreateDirectory((Join-Path $imageRoot 'deployment'))
 Copy-Item (Join-Path $projectRoot 'gateway/server.py') (Join-Path $imageRoot 'gateway/server.py')
 Copy-Item (Join-Path $projectRoot 'deployment/Dockerfile.gateway') (Join-Path $imageRoot 'deployment/Dockerfile.gateway')
 $script:Root=$imageRoot;$firstImage=Get-GatewayImage
 [IO.File]::AppendAllText((Join-Path $imageRoot 'gateway/server.py'),"`n# changed fixture")
 Assert ((Get-GatewayImage) -ne $firstImage) 'Gateway revisions overwrite the same image identity.'
 $script:Root=$projectRoot
 # A stale upstream snapshot must not prevent recovery of the running legacy deployment.
 $script:Calls.Clear();$script:LegacyRunning=$true;$script:FailBuild=$false
 function Get-DockerJson([string[]]$Arguments){if($Arguments[0] -eq 'inspect' -and $Arguments[1] -eq 'ninfer-ext'){return [pscustomobject]@{Config=@{Labels=@{'com.ninfer-manager.owner'='ninfer-ext-windows-manager-v1'}};State=@{Running=$script:LegacyRunning}}};return $null}
 function Build-Gateway {if($script:FailBuild){throw 'Synthetic build failure'}}
 function Invoke-Compose([string[]]$Arguments){$script:Calls.Add(@{file='compose';arguments=$Arguments})}
 function Wait-Engine {throw 'Synthetic startup failure'}
 Write-Json (Join-Path $script:State 'deployment.json') @{previous=$true}
 [IO.File]::WriteAllText($script:Compose,'previous-upstream-compose')
 try{Start-Stack}catch{}
 Assert ([bool]@($script:Calls|Where-Object {$_.file -eq 'docker' -and ($_.arguments -join ' ') -eq 'start ninfer-ext'}).Count) 'Running legacy deployment was not restored.'
 $script:LegacyRunning=$false;$script:Calls.Clear()
 [IO.File]::WriteAllText($script:Compose,'previous-upstream-compose')
 $keyDigest=(Get-FileHash $script:KeysFile).Hash
 try{Start-Stack}catch{}
 Assert ([IO.File]::ReadAllText($script:Compose) -eq 'previous-upstream-compose') 'Previous upstream runtime was not restored.'
 Assert ((Get-FileHash $script:KeysFile).Hash -eq $keyDigest) 'Runtime recovery rolled back client revocations.'
 Assert (-not(@($script:Calls|Where-Object {$_.file -eq 'docker' -and ($_.arguments -join ' ') -eq 'start ninfer-ext'}).Count)) 'Recovery started a previously stopped legacy deployment.'
 $script:LegacyRunning=$true;$script:FailBuild=$true;$script:Calls.Clear()
 try{Start-Stack}catch{}
 Assert ($script:Calls.Count -eq 0) 'A failed gateway build interrupted the running deployment.'
 # Failed LAN startup restores both the saved address and the previous owned firewall scope.
 $script:FirewallCalls=[Collections.Generic.List[object]]::new()
 function Get-NetIPAddress([string]$AddressFamily){[pscustomobject]@{IPAddress='192.168.50.116'}}
 function Set-ManagedFirewall($Settings,[switch]$Remove){$script:FirewallCalls.Add(@{address=$Settings.network.address;removed=[bool]$Remove})}
 function Start-Stack {throw 'Synthetic LAN startup failure'}
 $LanAddress='192.168.50.116';$HostName='';$TrustedRemoteAddress='192.168.50.0/24'
 try{Enable-Lan}catch{}
 Assert ((Get-Settings).network.address -eq '192.168.50.115') 'Failed LAN setup retained the new address.'
 Assert ($script:FirewallCalls.Count -eq 2 -and $script:FirewallCalls[-1].address -eq '192.168.50.115' -and -not $script:FirewallCalls[-1].removed) 'Failed LAN setup lost the original firewall scope.'
 $settings=Get-Settings;$settings.network.enabled=$false;Write-Json $script:SettingsFile $settings
 $script:FirewallCalls.Clear()
 try{Enable-Lan}catch{}
 Assert (-not (Get-Settings).network.enabled) 'Failed LAN setup enabled a previously disabled listener.'
 Assert ($script:FirewallCalls.Count -eq 2 -and $script:FirewallCalls[-1].removed) 'Failed LAN setup retained its new firewall rule.'
 Write-Host 'PASS Hermes setup, scoped credentials, gateway identities, deployment recovery, and LAN settings recovery.'

}finally{
 $env:HERMES_HOME=$previousHome;$script:Root=$projectRoot
 $expected=[IO.Path]::GetFullPath((Join-Path $projectRoot 'temp'))+[IO.Path]::DirectorySeparatorChar
 if([IO.Path]::GetFullPath($fixture).StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force}
}