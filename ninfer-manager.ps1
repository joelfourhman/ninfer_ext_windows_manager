#requires -Version 7.2
<# .SYNOPSIS
Install and operate upstream NInfer with a private Hermes qwen API on Windows.
#>
[CmdletBinding()]
param(
 [ValidateSet('Menu','Install','Start','Stop','Restart','Status','CheckUpdates','Update','Rebuild','Logs','Diagnostics','Repair','EnableLan','DisableLan','CreateKey','ListKeys','RevokeKey','RotateKey','ExportHermes','ExportCertificate','TrustCertificate','Benchmark','ValidateQwen','VerifyRollback','SelfTest','Rollback','Uninstall')][string]$Action='Menu',
 [switch]$NonInteractive,[switch]$Yes,[string]$LanAddress,[string]$HostName,[string]$TrustedRemoteAddress,
 [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')][string]$ClientName='qwen',
 [string]$KeyId,[ValidateRange(0,3650)][int]$ExpiresDays=0,[string]$OutputDirectory,
 [string]$BenchmarkContexts='2048,32768,131000,248000',
 [ValidateRange(16,16384)][int]$BenchmarkOutputTokens=256,[ValidateRange(1,5)][int]$BenchmarkRuns=1
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$script:Root=[IO.Path]::GetFullPath($PSScriptRoot)
$script:State=Join-Path $script:Root 'config/manager'
$script:Runtime=Join-Path $script:State 'runtime'
$script:Models=Join-Path $script:Root 'models'
$script:Source=Join-Path $script:Root 'source/ninfer'
$script:Lock=Get-Content (Join-Path $script:Root 'deployment/runtime.lock.json') -Raw | ConvertFrom-Json
$script:Owner='ninfer-windows-manager-v2'
$script:Project='ninfer-windows-manager'
$script:Compose=Join-Path $script:Runtime 'compose.json'
$script:SettingsFile=Join-Path $script:State 'settings.json'
$script:KeysFile=Join-Path $script:Runtime 'clients.json'
$script:EngineImage='ninfer-manager:'+$script:Lock.upstreamCommit.Substring(0,12)
$script:Firewall='NInfer Windows Manager HTTPS'

function Write-Json($Path,$Value) {
 $temporary="$Path.$PID.tmp"
 [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Read-Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Protect-Directory($Path) {
 $account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
 & icacls.exe $Path /inheritance:r /grant:r "${account}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' | Out-Null
 if($LASTEXITCODE -ne 0){throw "Could not restrict access to $Path"}
}
function New-Token { 'nwm_'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant() }
function Get-Digest([string]$Value) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant() }
function Get-Settings { Read-Json $script:SettingsFile }
function Get-Policy { [ordered]@{contextLength=262144;compressionTriggerPercent=75;compressionTriggerTokens=196608;recommendedInputCeiling=229376;defaultOutputTokens=8192;maxOutputTokens=16384;summaryMaxTokens=8192;targetAfterCompression=65536;compaction='Hermes client';profile='qwen';model='qwen3.8-27b'} }
function Get-GatewayImage {
 $identity=$script:Lock.python+"`n"+[IO.File]::ReadAllText((Join-Path $script:Root 'deployment/Dockerfile.gateway')).Replace("`r`n","`n")+"`n"+[IO.File]::ReadAllText((Join-Path $script:Root 'gateway/server.py')).Replace("`r`n","`n")
 'ninfer-manager-gateway:'+(Get-Digest $identity).Substring(0,16)
}
function Build-Gateway {
 $image=Get-GatewayImage;$existing=Get-DockerJson @('image','inspect',$image)
 if($existing){if($existing[0].Config.Labels.'com.ninfer-manager.owner' -ne $script:Owner){throw 'Gateway image ownership mismatch.'};return}
 Invoke-External docker @('build','--build-arg',"PYTHON_IMAGE=$($script:Lock.python)",'--label',"com.ninfer-manager.owner=$script:Owner",'-f',(Join-Path $script:Root 'deployment/Dockerfile.gateway'),'-t',$image,$script:Root)
}
function Protect-SecretFile($Path) {
 $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 Invoke-External icacls @($Path,'/inheritance:r','/grant:r',"*$($user):(F)",'*S-1-5-18:(F)')
}
function Initialize-Manager {
 foreach($path in @($script:State,$script:Runtime,$script:Models,(Join-Path $script:Root 'logs'),(Join-Path $script:Root 'temp'))){[void][IO.Directory]::CreateDirectory($path)}
 Protect-Directory (Join-Path $script:Root 'config')
 if(-not(Test-Path $script:SettingsFile)) { Write-Json $script:SettingsFile ([ordered]@{schemaVersion=2;network=@{enabled=$false;address='';hostname='';trustedSubnet='';httpsPort=8443;localPort=8080};runtime=@{maxContext=262144;kvDtype='k8v4';hostCapacity='8GiB';draftTokens=5;memoryHeadroom='512MiB'};modelArtifact='qwen3_8_27b_nvfp4.v3.ninfer'}) }
 if(-not(Test-Path $script:KeysFile)){Write-Json $script:KeysFile @{schemaVersion=1;clients=@()}}
 foreach($file in @('backend-secret.txt','admin-secret.txt')){if(-not(Test-Path (Join-Path $script:State $file))){[IO.File]::WriteAllText((Join-Path $script:State $file),(New-Token))}}
 $keys=Read-Json $script:KeysFile
 if(-not(@($keys.clients | Where-Object id -eq 'manager-local').Count)){
  $keys.clients=@($keys.clients)+@([pscustomobject]@{id='manager-local';name='manager-local';sha256=(Get-Digest ([IO.File]::ReadAllText((Join-Path $script:State 'admin-secret.txt'))));createdUtc=[datetime]::UtcNow.ToString('o');expiresUtc=$null;revokedUtc=$null})
  Write-Json $script:KeysFile $keys
 }
}
function Invoke-External([string]$File,[string[]]$Arguments) { & $File @Arguments; if($LASTEXITCODE -ne 0){throw "$File failed (exit $LASTEXITCODE). See output above."} }
function Get-DockerJson([string[]]$Arguments) { $output=& docker @Arguments 2>$null; if($LASTEXITCODE -ne 0){return $null}; ($output -join "`n") | ConvertFrom-Json -NoEnumerate }
function Invoke-Compose([string[]]$Arguments) { Invoke-External docker (@('compose','--project-name',$script:Project,'--file',$script:Compose)+$Arguments) }
function Assert-Owned($Container) { $info=Get-DockerJson @('inspect',$Container); if($info -and $info[0].Config.Labels.'com.ninfer-manager.owner' -ne $script:Owner){throw "Container $Container is not owned by this manager."} }
function Test-Prerequisites {
 if(-not[OperatingSystem]::IsWindows()){throw 'Windows 11 and PowerShell 7.2+ are required.'}
 foreach($command in @('git','docker','curl.exe')){if(-not(Get-Command $command -ErrorAction SilentlyContinue)){throw "$command is missing. See docs/installation.md."}}
 $dockerType=& docker info --format '{{.OSType}}' 2>$null
 if($LASTEXITCODE -ne 0 -or $dockerType -ne 'linux'){throw 'Start Docker Desktop using WSL2/Linux containers, then run Install again.'}
 Invoke-External docker @('compose','version','--short')
 $gpu=& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
 if($LASTEXITCODE -ne 0 -or $gpu -notmatch 'RTX 5090'){throw 'The tested qwen profile requires an RTX 5090 (32GB).'}
 if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:Root))).AvailableFreeSpace -lt 60GB){throw 'Allow at least 60 GiB free for model migration and Docker builds, plus build-cache space.'}
 $os=Get-CimInstance Win32_OperatingSystem
 if([int64]$os.TotalVisibleMemorySize -lt 48GB/1KB){throw 'At least 48 GiB RAM is required; 64 GiB is the tested target.'}
}
function Sync-Upstream {
 if(-not(Test-Path (Join-Path $script:Source '.git'))){Invoke-External git @('clone',$script:Lock.upstreamUrl,$script:Source)}
 $remote=& git -C $script:Source remote get-url origin
 if($remote.TrimEnd('/') -ne $script:Lock.upstreamUrl.TrimEnd('/')){throw 'Managed source has an unexpected origin.'}
 if((& git -C $script:Source status --porcelain)){throw 'Managed upstream source has local edits. Preserve them before installing.'}
 & git -C $script:Source cat-file -e "$($script:Lock.upstreamCommit)^{commit}" 2>$null
 if($LASTEXITCODE -ne 0){Invoke-External git @('-C',$script:Source,'fetch','origin',$script:Lock.upstreamCommit)}
 Invoke-External git @('-C',$script:Source,'checkout','--detach',$script:Lock.upstreamCommit)
}
function Build-Engine([switch]$Force) {
 $info=Get-DockerJson @('image','inspect',$script:EngineImage)
 if($info -and -not $Force){if($info[0].Config.Labels.'com.ninfer-manager.commit' -ne $script:Lock.upstreamCommit){throw 'Engine image provenance mismatch.'};return}
 Sync-Upstream
 Invoke-External docker @('build','--progress','plain','--build-context',"upstream=$script:Source",'--build-arg',"CUDA_BUILD=$($script:Lock.cudaBuild)",'--build-arg',"CUDA_RUNTIME=$($script:Lock.cudaRuntime)",'--label',"com.ninfer-manager.owner=$script:Owner",'--label',"com.ninfer-manager.commit=$($script:Lock.upstreamCommit)",'-f',(Join-Path $script:Root 'deployment/Dockerfile.ninfer'),'-t',$script:EngineImage,$script:Root)
}
function Install-Model {
 $model=$script:Lock.model;$input=Join-Path $script:Models $model.artifact
 if(-not(Test-Path $input)){
  $partial="$input.partial";$url="https://huggingface.co/$($model.repository)/resolve/$($model.revision)/$($model.artifact)?download=true"
  Invoke-External curl.exe @('--location','--fail','--retry','5','--continue-at','-','--output',$partial,$url)
  if((Get-Item $partial).Length -ne $model.bytes -or (Get-FileHash $partial).Hash.ToLowerInvariant() -ne $model.sha256){throw 'Model verification failed; partial download retained.'}
  Move-Item -LiteralPath $partial -Destination $input
 }
 if((Get-Item $input).Length -ne $model.bytes -or (Get-FileHash $input).Hash.ToLowerInvariant() -ne $model.sha256){throw 'Original model failed verification. It was not modified.'}
 $stream=[IO.File]::OpenRead($input)
 try{$header=[byte[]]::new(8);$null=$stream.Read($header,0,8)}finally{$stream.Dispose()}
 if([Text.Encoding]::ASCII.GetString($header,0,6) -eq 'NINFER' -and $header[7] -eq 3){
  $settings=Get-Settings;$settings.modelArtifact=$model.artifact;Write-Json $script:SettingsFile $settings
  Write-Host 'Verified original artifact is already v3; reusing it without conversion or modification.'
  return
 }
 if($header[7] -ne 2){throw 'Unsupported artifact version; original file was preserved.'}
 $output=Join-Path $script:Models (Get-Settings).modelArtifact;$marker="$output.manager.json"
 if(Test-Path $marker){$record=Read-Json $marker;if((Test-Path $output) -and (Get-FileHash $output).Hash.ToLowerInvariant() -eq $record.sha256 -and $record.upstreamCommit -eq $script:Lock.upstreamCommit){return};throw 'Upgraded model provenance changed. Preserve it before retrying.'}
 if(Test-Path $output){throw 'An unverified migration output exists. Preserve it before retrying.'}
 Sync-Upstream
 Write-Host 'Upgrading into a separate v3 file; the original model is retained for rollback.'
 Invoke-External docker @('run','--rm','--mount',"type=bind,source=$script:Models,target=/models",'--mount',"type=bind,source=$script:Source,target=/source,readonly",$script:Lock.python,'python','/source/tools/upgrade_ninfer_v2_to_v3.py',('/models/'+$model.artifact),('/models/'+(Get-Settings).modelArtifact))
 Write-Json $marker @{upstreamCommit=$script:Lock.upstreamCommit;sourceSha256=$model.sha256;sha256=(Get-FileHash $output).Hash.ToLowerInvariant();bytes=(Get-Item $output).Length}
}

function Write-Runtime {
 $s=Get-Settings;$backend=[IO.File]::ReadAllText((Join-Path $script:State 'backend-secret.txt'))
 if([int]$s.runtime.maxContext -ne 262144){throw 'The Hermes qwen profile requires a 262144-token backend. Do not change one side independently.'}
 if($s.runtime.kvDtype -notin @('bf16','int8','fp8','nvfp4','k8v4') -or [int]$s.runtime.draftTokens -notin 1..5){throw 'Unsupported qwen KV or MTP settings.'}
 $engine=@"
[model]
path = "/models/$($s.modelArtifact)"
vision = false
[engine]
max_context = $($s.runtime.maxContext)
kv_dtype = "$($s.runtime.kvDtype)"
context_capacity = "auto"
memory_headroom = "$($s.runtime.memoryHeadroom)"
max_concurrency = 1
max_pending_requests = 4
pending_timeout = "1800s"
prefill_chunk = 1024
cuda_graph = true
[context_cache]
prefix_reuse = true
checkpoint_interval = 8192
host_capacity = "$($s.runtime.hostCapacity)"
[speculative]
backend = "mtp"
draft_tokens = $($s.runtime.draftTokens)
proposal_head = "optimized"
[generation]
max_tokens = 8192
[server]
host = "0.0.0.0"
port = 8080
api_key = "$backend"
model_id = "qwen3.8-27b"
cors = false
[logging]
level = "info"
request_jsonl = ""
"@
 [IO.File]::WriteAllText((Join-Path $script:Runtime 'ninfer.toml'),$engine,[Text.UTF8Encoding]::new($false))
 Write-Json (Join-Path $script:Runtime 'gateway.json') @{backendHost='ninfer';backendPort=8080;backendKey=$backend;backendTimeoutSeconds=1800;maxRequestBytes=16777216;qwen=(Get-Policy)}
 $labels=@{'com.ninfer-manager.owner'=$script:Owner}
 $services=[ordered]@{
  ninfer=@{image=$script:EngineImage;container_name='ninfer';labels=@{'com.ninfer-manager.owner'=$script:Owner;'com.ninfer-manager.config-sha256'=(Get-Digest $engine)};gpus='all';restart='unless-stopped';command=@('ninfer-serve','--config','/run/manager/ninfer.toml');networks=@('backend');volumes=@(@{type='bind';source=$script:Models;target='/models';read_only=$true},@{type='bind';source=(Join-Path $script:Runtime 'ninfer.toml');target='/run/manager/ninfer.toml';read_only=$true},@{type='bind';source=(Join-Path $script:Root 'logs');target='/logs'})}
  gateway=@{image=(Get-GatewayImage);container_name='ninfer-gateway';labels=$labels;restart='unless-stopped';read_only=$true;cap_drop=@('ALL');security_opt=@('no-new-privileges:true');networks=@('backend','edge');ports=@("127.0.0.1:$($s.network.localPort):8080");volumes=@(@{type='bind';source=$script:Runtime;target='/run/manager';read_only=$true});depends_on=@('ninfer')}
 }
 if($s.network.enabled){
  $caddy=@"
{
    admin off
    auto_https disable_redirects
    default_sni $($s.network.hostname)
}
https://$($s.network.hostname):8443 {
    tls internal
    reverse_proxy gateway:8080
}
"@
  [IO.File]::WriteAllText((Join-Path $script:Runtime 'Caddyfile'),$caddy,[Text.UTF8Encoding]::new($false))
  $services.caddy=@{image=$script:Lock.caddy;container_name='ninfer-https';labels=@{'com.ninfer-manager.owner'=$script:Owner;'com.ninfer-manager.config-sha256'=(Get-Digest $caddy)};restart='unless-stopped';networks=@('edge');ports=@("$($s.network.address):$($s.network.httpsPort):8443");volumes=@(@{type='bind';source=(Join-Path $script:Runtime 'Caddyfile');target='/etc/caddy/Caddyfile';read_only=$true},'caddy-data:/data','caddy-config:/config')}
 }
 Write-Json $script:Compose @{name=$script:Project;services=$services;networks=@{backend=@{internal=$true};edge=@{}};volumes=@{'caddy-data'=@{};'caddy-config'=@{}}}
}
function Invoke-Api($Path,$Body=$null,[int]$Timeout=1800) {
 $s=Get-Settings;$parameters=@{Uri="http://127.0.0.1:$($s.network.localPort)$Path";Headers=@{Authorization=('Bearer '+[IO.File]::ReadAllText((Join-Path $script:State 'admin-secret.txt')))};TimeoutSec=$Timeout}
 if($null -ne $Body){$parameters.Method='POST';$parameters.ContentType='application/json';$parameters.Body=$Body|ConvertTo-Json -Depth 40 -Compress}
 Invoke-RestMethod @parameters
}
function Test-Inference {
 $models=Invoke-Api '/v1/models'
 if($models.data[0].id -ne 'qwen3.8-27b'){throw 'Unexpected model ID.'}
 $reply=Invoke-Api '/v1/chat/completions' @{model='qwen3.8-27b';messages=@(@{role='user';content='Reply with exactly READY.'});max_tokens=16;temperature=0;enable_thinking=$false}
 if(-not $reply.choices[0].message.content){throw 'Inference returned no answer.'}
 Write-Host 'PASS authenticated model discovery and inference.'
}
function Wait-Engine {
 $deadline=[datetime]::UtcNow.AddMinutes(20)
 while([datetime]::UtcNow -lt $deadline){
  try{$health=Invoke-Api '/health' $null 5;if($health.status -eq 'ok'){return}}catch{}
  $engine=Get-DockerJson @('inspect','ninfer')
  if($engine -and $engine[0].State.Status -in @('exited','dead','restarting')){throw 'NInfer did not stay running. Run Logs; the old deployment remains available.'}
  Start-Sleep -Seconds 3
 }
 throw 'Model startup timed out. Run Diagnostics.'
}
function Start-Stack {
 if(-not(Test-Path (Join-Path $script:Models ((Get-Settings).modelArtifact)))){throw 'Upgraded model missing. Run Install.'}
 foreach($container in @('ninfer','ninfer-gateway','ninfer-https')){Assert-Owned $container}
 Build-Gateway
 $legacy=Get-DockerJson @('inspect','ninfer-ext')
 $legacyWasRunning=$legacy -and $legacy[0].State.Running
 if($legacy){if($legacy[0].Config.Labels.'com.ninfer-manager.owner' -ne 'ninfer-ext-windows-manager-v1'){throw 'Existing ninfer-ext container has an unexpected owner.'};if($legacy[0].State.Running){Invoke-External docker @('stop','ninfer-ext')}}
 $snapshot=$null
 if(Test-Path (Join-Path $script:State 'deployment.json')){
  $snapshot=Join-Path $script:State ('snapshots/'+(Get-Date -Format 'yyyyMMdd-HHmmss-ffff'))
  [void][IO.Directory]::CreateDirectory($snapshot)
  foreach($name in @('compose.json','ninfer.toml','gateway.json','Caddyfile')){if(Test-Path (Join-Path $script:Runtime $name)){Copy-Item -LiteralPath (Join-Path $script:Runtime $name) -Destination $snapshot}}
 }
 try{
  Write-Runtime;Invoke-Compose @('up','-d','--remove-orphans');Wait-Engine;Test-Inference
  Write-Json (Join-Path $script:State 'deployment.json') @{schemaVersion=2;upstreamCommit=$script:Lock.upstreamCommit;engineImage=$script:EngineImage;profile='qwen';startedUtc=[datetime]::UtcNow.ToString('o');legacyContainerPreserved=[bool]$legacy;configuredContext=262144}
 }catch{
  $failure=$_.Exception.Message
  if($legacyWasRunning){try{Invoke-Compose @('stop');Invoke-External docker @('start','ninfer-ext')}catch{Write-Warning 'Automatic legacy recovery failed; stop the new stack, then docker start ninfer-ext.'}}
  elseif($snapshot){try{Invoke-Compose @('stop');Get-ChildItem -LiteralPath $snapshot -File | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $script:Runtime -Force};Invoke-Compose @('up','-d','--remove-orphans')}catch{Write-Warning "Previous upstream runtime could not be restored automatically; snapshot: $snapshot"}}
  throw "New deployment failed: $failure. Previous settings, image, and model were preserved."
 }
 Show-Status
}
function Install-Stack([switch]$Force) {
 Test-Prerequisites;Build-Engine -Force:$Force;Install-Model
 Start-Stack
}
function New-ClientKey([string]$Name,[int]$Days=0) {
 $registry=Read-Json $script:KeysFile;$token=New-Token;$id=$Name+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
 $expiry=if($Days){[datetime]::UtcNow.AddDays($Days).ToString('o')}else{$null}
 $registry.clients=@($registry.clients)+@([pscustomobject]@{id=$id;name=$Name;sha256=(Get-Digest $token);createdUtc=[datetime]::UtcNow.ToString('o');expiresUtc=$expiry;revokedUtc=$null})
 Write-Json $script:KeysFile $registry
 [pscustomobject]@{id=$id;token=$token;expiresUtc=$expiry}
}
function Revoke-ClientKey([string]$Id) {
 if($Id -eq 'manager-local'){throw 'The manager-local credential cannot be revoked through client actions.'}
 $registry=Read-Json $script:KeysFile;$entry=@($registry.clients | Where-Object id -eq $Id)
 if($entry.Count -ne 1){throw 'Specify an existing client KeyId (ListKeys).'}
 $entry[0].revokedUtc=[datetime]::UtcNow.ToString('o');Write-Json $script:KeysFile $registry
 Write-Host "Revoked $Id. New requests are rejected immediately; active streams may finish."
}
function Export-Certificate([string]$Destination) {
 if(-not (Get-Settings).network.enabled){throw 'EnableLan first to issue the certificate.'}
 if(-not $Destination){$Destination=Join-Path $script:State 'ninfer-root-ca.crt'}
 Invoke-External docker @('cp','ninfer-https:/data/caddy/pki/authorities/local/root.crt',$Destination)
 $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($Destination)
 Write-Host "Public root certificate: $Destination"
 Write-Host "SHA256 fingerprint: $($certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256))"
}
function Get-HermesCommand { (Get-Command hermes -ErrorAction Stop).Source }
function Export-Hermes {
 $s=Get-Settings
 if(-not $s.network.enabled){throw 'EnableLan first. The Hermes connection requires HTTPS.'}
 $destination=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path $env:LOCALAPPDATA 'hermes'}
 if(-not(Test-Path (Join-Path $destination 'config.yaml') -PathType Leaf)){throw 'Install Hermes and finish its default setup first. ExportHermes adds a model to that existing setup.'}
 $hermes=Get-HermesCommand
 $backup=Join-Path $script:State ('hermes-backups/'+(Get-Date -Format 'yyyyMMdd-HHmmss-ffff'))
 [void][IO.Directory]::CreateDirectory($backup);Protect-Directory $backup
 $tracked=@('config.yaml','.env','ninfer-client-key-id.txt','certs/ninfer-root-ca.crt')
 $existed=@{}
 foreach($name in $tracked){
  $original=Join-Path $destination $name;$existed[$name]=Test-Path -LiteralPath $original
  if($existed[$name]){$saved=Join-Path $backup $name;[void][IO.Directory]::CreateDirectory((Split-Path $saved));Copy-Item -LiteralPath $original -Destination $saved}
 }
 $envFile=Join-Path $destination '.env';$key=$null;$previousHome=$env:HERMES_HOME
 try {
  $certs=Join-Path $destination 'certs';[void][IO.Directory]::CreateDirectory($certs)
  $ca=Join-Path $certs 'ninfer-root-ca.crt';Export-Certificate $ca
  $key=New-ClientKey $ClientName $ExpiresDays
  $url="https://$($s.network.hostname):$($s.network.httpsPort)/v1"
  $provider=@{extra_body=@{enable_thinking=$false};name='Qwen (NInfer)';base_url=$url;api_mode='chat_completions';model='qwen3.8-27b';discover_models=$false;models=@{'qwen3.8-27b'=@{context_length=262144}};context_length=262144;key_env='HERMES_CUSTOM_QWEN_API_KEY';ssl_ca_cert=$ca.Replace('\','/');ssl_verify=$true}
  $oldEnvironment=if($existed['.env']){[IO.File]::ReadAllText($envFile)}else{[IO.File]::WriteAllText($envFile,'');''}
  $keptEnvironment=@($oldEnvironment -split '\r?\n' | Where-Object {$_ -notmatch '^\s*HERMES_CUSTOM_QWEN_API_KEY='})
  $updatedEnvironment=($keptEnvironment -join "`n").TrimEnd("`r","`n")+"`nHERMES_CUSTOM_QWEN_API_KEY=$($key.token)`n"
  Protect-SecretFile $envFile
  [IO.File]::WriteAllText($envFile,$updatedEnvironment,[Text.UTF8Encoding]::new($false))
  $env:HERMES_HOME=$destination
  Invoke-External $hermes @('--profile','default','config','set','providers.qwen',($provider|ConvertTo-Json -Depth 8 -Compress))
  Invoke-External $hermes @('--profile','default','config','set','compression.model_thresholds.qwen','0.75')
  Invoke-External $hermes @('--profile','default','config','set','auxiliary.compression.provider','main')
  Invoke-External $hermes @('--profile','default','config','set','auxiliary.compression.model','""')
  Invoke-External $hermes @('--profile','default','config','set','auxiliary.compression.base_url','""')
  Invoke-External $hermes @('--profile','default','config','set','auxiliary.compression.extra_body','{}')
  Invoke-External $hermes @('--profile','default','config','set','model.persist_switch_by_default','false')
  [IO.File]::WriteAllText((Join-Path $destination 'ninfer-client-key-id.txt'),$key.id)
 }catch {
  $failure=$_
  foreach($name in $tracked){
   try {
    if($existed[$name]){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $destination $name) -Force}
    elseif(Test-Path -LiteralPath (Join-Path $destination $name)){Remove-Item -LiteralPath (Join-Path $destination $name)}
   }catch{Write-Warning "Restore $name manually from $backup; automatic restoration failed."}
  }
  if($key){try{Revoke-ClientKey $key.id}catch{Write-Warning "Revoke the failed setup's key $($key.id) manually."}}
  throw $failure
 }finally{$env:HERMES_HOME=$previousHome}
 Write-Host "Qwen added to the existing Hermes model picker. The default model is unchanged. Backup: $backup"
}
function Enable-Lan {
 if(-not $LanAddress -or -not $TrustedRemoteAddress){throw 'Supply -LanAddress <this PC IPv4> and -TrustedRemoteAddress <trusted IPv4/CIDR>.'}
 $address=[Net.IPAddress]::Parse($LanAddress)
 if($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $LanAddress -in @('0.0.0.0','127.0.0.1')){throw 'Use a specific LAN IPv4 address.'}
 if(-not(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $LanAddress)){throw 'LanAddress is not assigned to this computer.'}
 if($TrustedRemoteAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$'){throw 'Use a narrow trusted IPv4 address or subnet.'}
 $null=[Net.IPAddress]::Parse(($TrustedRemoteAddress -split '/')[0])
 if($TrustedRemoteAddress.Contains('/') -and [int]($TrustedRemoteAddress -split '/')[1] -notin 8..32){throw 'Trusted prefix must be between 8 and 32.'}
 $name=if($HostName){$HostName}else{$LanAddress};if($name -notmatch '^[a-zA-Z0-9.-]+$'){throw 'Hostname must be a DNS name or IPv4 address.'}
 $previous=Get-Settings
 $s=Get-Settings;$s.network.enabled=$true;$s.network.address=$LanAddress;$s.network.hostname=$name;$s.network.trustedSubnet=$TrustedRemoteAddress
 $firewallApplied=$false
 try {
  Set-ManagedFirewall $s;$firewallApplied=$true
  Write-Json $script:SettingsFile $s;Start-Stack
 }catch {
  $failure=$_
  Write-Json $script:SettingsFile $previous
  if($firewallApplied){
   try{if($previous.network.enabled){Set-ManagedFirewall $previous}else{Set-ManagedFirewall $s -Remove}}
   catch{Write-Warning 'The previous firewall scope could not be restored; inspect the owned HTTPS rule before enabling LAN again.'}
  }
  throw $failure
 }
 Export-Certificate ''
}
function Set-ManagedFirewall($Settings,[switch]$Remove) {
 $result=Join-Path $script:State 'firewall-result.json'
 if(Test-Path $result){Remove-Item -LiteralPath $result}
 $helper=Join-Path $script:Root 'deployment/configure-firewall.ps1'
 if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  & $helper -Address $Settings.network.address -TrustedSubnet $Settings.network.trustedSubnet -Port $Settings.network.httpsPort -ResultFile $result -Remove:$Remove
 } else {
  Write-Host 'Windows needs one-time Administrator approval for the narrowly scoped HTTPS firewall rule.'
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$helper+'"'),'-Address',$Settings.network.address,'-TrustedSubnet',$Settings.network.trustedSubnet,'-Port',[string]$Settings.network.httpsPort,'-ResultFile',('"'+$result+'"'))
  if($Remove){$arguments+='-Remove'}
  $process=Start-Process -FilePath (Get-Command pwsh.exe).Source -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
  if($process.ExitCode -ne 0){throw 'Firewall configuration failed or Administrator approval was declined. LAN settings were not applied.'}
 }
 if(-not(Test-Path $result) -or -not(Read-Json $result).ok){throw 'Could not confirm the restricted firewall rule. LAN settings were not applied.'}
}
function Show-Status {
 $s=Get-Settings
 Write-Host "NInfer Windows Manager | upstream $($script:Lock.upstreamCommit.Substring(0,12)) | Hermes qwen"
 Write-Host "Local API: http://127.0.0.1:$($s.network.localPort)/v1 (API key required)"
 if($s.network.enabled){Write-Host "LAN API: https://$($s.network.hostname):$($s.network.httpsPort)/v1 | trusted subnet $($s.network.trustedSubnet)"}
 Write-Host 'Context: configured 262144; Hermes compaction at 75%; output default 8192.'
 if(Test-Path (Join-Path $script:State 'validation.json')){$validation=Read-Json (Join-Path $script:State 'validation.json');$validation.profile='qwen';$validation|ConvertTo-Json -Depth 8}
 Write-Host 'Client credentials: CreateKey / ExportHermes; keys are never printed by Status.'
 & docker ps -a --filter "label=com.ninfer-manager.owner=$script:Owner" --format '{{.Names}} | {{.Status}} | {{.Ports}}'
}
function Invoke-Benchmark {
 $results=@()
 foreach($text in $BenchmarkContexts.Split(',')){
  $target=[int]$text;if($target -lt 128 -or $target+$BenchmarkOutputTokens+256 -gt 262144){throw 'Benchmark context leaves insufficient output/template headroom.'}
  for($run=1;$run -le $BenchmarkRuns;$run++){
   $prompt='Qwen benchmark nonce '+[Guid]::NewGuid().ToString('N')+"`n"+('data ' * $target)+"`nWrite a detailed numbered qwen checklist. Continue until the output limit."
   $watch=[Diagnostics.Stopwatch]::StartNew()
   $response=Invoke-Api '/v1/chat/completions' @{model='qwen3.8-27b';messages=@(@{role='user';content=$prompt});max_tokens=$BenchmarkOutputTokens;enable_thinking=$false;temperature=0}
   $watch.Stop();$timings=if($response.PSObject.Properties.Name -contains 'timings'){$response.timings}else{$null}
   $results+=@{target=$target;run=$run;promptTokens=$response.usage.prompt_tokens;completionTokens=$response.usage.completion_tokens;elapsedSeconds=$watch.Elapsed.TotalSeconds;timings=$timings}
   Write-Host "PASS target $target; actual prompt $($response.usage.prompt_tokens), output $($response.usage.completion_tokens), $([math]::Round($watch.Elapsed.TotalSeconds,2)) seconds"
  }
 }
 $path=Join-Path $script:Root ('logs/benchmark-upstream-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
 Write-Json $path @{upstreamCommit=$script:Lock.upstreamCommit;settings=(Get-Settings).runtime;results=$results;createdUtc=[datetime]::UtcNow.ToString('o')}
 $maximum=($results | ForEach-Object promptTokens | Measure-Object -Maximum).Maximum
 Write-Json (Join-Path $script:State 'validation.json') @{configuredContext=262144;largestValidatedInput=$maximum;outputBudgetTokens=$BenchmarkOutputTokens;report=$path;profile='qwen';upstreamCommit=$script:Lock.upstreamCommit}
}
function Invoke-Rollback {
 $old=Get-DockerJson @('inspect','ninfer-ext')
 if(-not $old -or $old[0].Config.Labels.'com.ninfer-manager.owner' -ne 'ninfer-ext-windows-manager-v1'){throw 'No owned legacy container exists. See docs/migration.md.'}
 if(Test-Path $script:Compose){Invoke-Compose @('stop')};Invoke-External docker @('start','ninfer-ext')
 Write-Host 'Legacy NInfer-Ext restored with original credentials/network settings. New key revocations remain intact.'
}
function Test-LegacyRollback {
 $legacy=Get-DockerJson @('inspect','ninfer-ext')
 if(-not $legacy -or $legacy[0].Config.Labels.'com.ninfer-manager.owner' -ne 'ninfer-ext-windows-manager-v1'){throw 'No owned legacy deployment is available to test.'}
 if(Get-DockerJson @('inspect','ninfer-rollback-check')){throw 'The rollback-check container name is already in use.'}
 $modelMount=@($legacy[0].Mounts | Where-Object Destination -eq '/models')
 if($modelMount.Count -ne 1){throw 'Legacy model mount is ambiguous.'}
 $cleanArguments=[Collections.Generic.List[string]]::new()
 $oldArguments=@($legacy[0].Config.Cmd)
 for($i=0;$i -lt $oldArguments.Count;$i++){if($oldArguments[$i] -eq '--api-key'){$i++;continue};$cleanArguments.Add([string]$oldArguments[$i])}
 $created=$false;$passed=$false
 try {
  Invoke-Compose @('stop')
  Invoke-External docker (@('run','--detach','--name','ninfer-rollback-check','--label','com.ninfer-manager.owner=ninfer-windows-manager-test','--gpus','all','--network',($script:Project+'_backend'),'--mount',"type=bind,source=$($modelMount[0].Source),target=/models,readonly",$legacy[0].Config.Image)+$cleanArguments.ToArray())
  $created=$true
  $probe=@'
import json,time,urllib.request
url='http://ninfer-rollback-check:8080'
for attempt in range(240):
    try:
        with urllib.request.urlopen(url+'/health',timeout=5) as r:
            if json.load(r).get('status')=='ok': break
    except Exception: time.sleep(2)
else: raise RuntimeError('Legacy readiness timeout')
body=json.dumps({'model':'qwen3.8-27b','messages':[{'role':'user','content':'Reply with exactly READY.'}],'max_tokens':16,'temperature':0,'enable_thinking':False}).encode()
with urllib.request.urlopen(urllib.request.Request(url+'/v1/chat/completions',body,{'Content-Type':'application/json'}),timeout=180) as r:
    reply=json.load(r)
    assert reply['choices'][0]['message']['content']
print('PASS preserved legacy image, original model mount, and original runtime options: inference succeeded on an unpublished private-network probe.')
'@
  Invoke-External docker @('run','--rm','--network',($script:Project+'_backend'),$script:Lock.python,'python','-c',$probe)
  $passed=$true
 } finally {
  if($created){Invoke-External docker @('rm','--force','ninfer-rollback-check')}
  Start-Stack
 }
 if($passed){Write-Json (Join-Path $script:Root 'logs/rollback-validation.json') @{legacyImage=$legacy[0].Config.Image;originalModelMount=$modelMount[0].Source;legacyInference=$true;upstreamRestored=$true;scope='Unpublished probe using preserved legacy image/model/options. Original container and its network bindings were not changed or exposed.';createdUtc=[datetime]::UtcNow.ToString('o')}}
}
function Invoke-SelfTest {
 Invoke-External python @('-m','unittest','discover','-s',(Join-Path $script:Root 'tests'),'-v')
 Invoke-External pwsh @('-NoProfile','-File',(Join-Path $script:Root 'tests/manager.ps1'))
 Invoke-External pwsh @('-NoProfile','-File',(Join-Path $script:Root 'tests/recovery.ps1'))
}
function Show-Menu {
 while($true){
  Write-Host "`nNInfer Windows Manager`n1 Install / Start   2 Status   3 Stop   4 Restart`n5 Export Hermes   6 List keys   7 Diagnostics   8 Rollback   0 Exit"
  switch(Read-Host 'Select'){'1'{Install-Stack};'2'{Show-Status};'3'{Invoke-Compose @('stop')};'4'{Invoke-Compose @('stop');Start-Stack};'5'{Export-Hermes};'6'{(Read-Json $script:KeysFile).clients | Select-Object id,name,createdUtc,expiresUtc,revokedUtc | Format-Table};'7'{Show-Status;Invoke-Compose @('logs','--tail','50')};'8'{Invoke-Rollback};'0'{return}}
 }
}
function Invoke-Main {
 Initialize-Manager
 switch($Action){
  'Menu'{if($NonInteractive){throw 'Choose an explicit Action for non-interactive use.'};Show-Menu}
  'Install'{Install-Stack};'Start'{if(-not(Test-Path $script:Compose)){Install-Stack}else{Start-Stack}}
  'Stop'{Invoke-Compose @('stop')};'Restart'{Invoke-Compose @('stop');Start-Stack};'Status'{Show-Status}
  'CheckUpdates'{Write-Host "Tested pin: $($script:Lock.upstreamCommit)";Invoke-External git @('ls-remote',$script:Lock.upstreamUrl,'HEAD');Write-Host 'Update applies the checked-in lock file; upstream HEAD is informational.'}
  'Update'{Install-Stack};'Rebuild'{Install-Stack -Force};'Repair'{Install-Stack}
  'Logs'{Invoke-Compose @('logs','--tail','100','--follow')}
  'Diagnostics'{Show-Status;Invoke-Compose @('config','--quiet');Invoke-Compose @('logs','--tail','70');Test-Inference}
  'EnableLan'{Enable-Lan}
  'DisableLan'{$s=Get-Settings;if($s.network.address){Set-ManagedFirewall $s -Remove};$s.network.enabled=$false;Write-Json $script:SettingsFile $s;Start-Stack}
  'CreateKey'{$created=New-ClientKey $ClientName $ExpiresDays;Write-Host "Key ID: $($created.id)`nAPI key (shown once): $($created.token)"}
  'ListKeys'{(Read-Json $script:KeysFile).clients | Select-Object id,name,createdUtc,expiresUtc,revokedUtc | Format-Table}
  'RevokeKey'{Revoke-ClientKey $KeyId}
  'RotateKey'{if(-not $KeyId){throw 'Specify the old -KeyId. Update your client before revoking it.'};$existing=@((Read-Json $script:KeysFile).clients | Where-Object id -eq $KeyId);if($existing.Count -ne 1 -or $KeyId -eq 'manager-local'){throw 'Select an existing client key.'};$created=New-ClientKey $existing[0].name $ExpiresDays;Write-Host "Replacement ID: $($created.id)`nAPI key (shown once): $($created.token)`nOld key remains valid until RevokeKey -KeyId $KeyId."}
  'ExportHermes'{Export-Hermes};'ExportCertificate'{Export-Certificate ''}
  'TrustCertificate'{Export-Certificate '';Import-Certificate -FilePath (Join-Path $script:State 'ninfer-root-ca.crt') -CertStoreLocation Cert:\CurrentUser\Root | Select-Object Subject,Thumbprint}
  'Benchmark'{Invoke-Benchmark};'ValidateQwen'{Test-Inference;Invoke-Benchmark;Write-Host 'Also run the Hermes multi-compaction acceptance test (docs/hermes-qwen.md).'}
  'SelfTest'{Invoke-SelfTest};'Rollback'{Invoke-Rollback}
  'VerifyRollback'{Test-LegacyRollback}
  'Uninstall'{if(-not $Yes){throw 'Use -Yes to remove only the managed stack. Models, legacy setup, certificates, and settings are retained.'};foreach($c in @('ninfer','ninfer-gateway','ninfer-https')){Assert-Owned $c};Invoke-Compose @('down');$s=Get-Settings;if($s.network.address){Set-ManagedFirewall $s -Remove}}
 }
}
if($MyInvocation.InvocationName -ne '.') {
 $managerLock=$null
 try {
  [void][IO.Directory]::CreateDirectory($script:State)
  try{$managerLock=[IO.File]::Open((Join-Path $script:State 'manager.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{throw 'Another manager action is running. Wait for it to finish, then retry.'}
  Invoke-Main
 } catch { Write-Error $_; exit 1 } finally { if($managerLock){$managerLock.Dispose()} }
}
