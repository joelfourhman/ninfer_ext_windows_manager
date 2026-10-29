#requires -Version 7.2
<#
.SYNOPSIS
Install and manage NInfer on Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Start','Stop','Restart','Status','Connection','EnableHttps','DisableHttps','NewKey','Keys','CopyKey','RevokeKey','Logs','Rollback','SelfTest')]
    [string]$Action = 'Menu',
    [ValidatePattern('^[a-zA-Z0-9_-]{1,40}$')][string]$Name = 'device',
    [string]$KeyId = 'local',
    [string]$Address,
    [string]$ServerName,
    [ValidateRange(1,65535)][int]$Port = 8443
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:State = Join-Path $PSScriptRoot '.ninfer'
$script:Project = 'ninfer-windows-manager'
$script:Owner = 'ninfer-windows-manager-v2'
$script:Revision = '1882c6adbc98043fcf89f3589aa5addb3742777a'
$script:EngineImage = 'ninfer-manager:' + $script:Revision.Substring(0,12)
$script:CaddyImage = 'caddy:2.11.2-alpine@sha256:6d125e80883be8a2bef5f088c7535945b42cdbb8a0f5471bf36eaf18dc0638f1'
$script:CudaBuild = 'nvidia/cuda:13.3.1-devel-ubuntu26.04@sha256:0ee41c7eac41d2579b268be60db1012ad23b0d4f3222b76566128fe28881a8f8'
$script:CudaRuntime = 'nvidia/cuda:13.3.1-runtime-ubuntu26.04@sha256:b9321b748007329ae6a63261eb041612d18b802e23a485717cfa3584d640dd57'
$script:ModelName = 'qwen3_8_27b_nvfp4.ninfer'
$script:ModelUrl = 'https://huggingface.co/neroued/Qwen3.8-27B-nvfp4-NInfer/resolve/a107ba1b5b0609d9ca90d5ed61439f5f5cc7d64d/qwen3_8_27b_nvfp4.ninfer?download=true'
$script:ModelHash = '74d2c57145e6ff11d1d2faa79594477f9bc903a611af1fb20218189fbbb77d82'
$script:ModelBytes = 23719715844

function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed (exit $LASTEXITCODE)." }
}
function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText("$Path.new", ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath "$Path.new" -Destination $Path -Force
}
function Get-Settings { Read-Json (Join-Path $script:State 'settings.json') }
function Get-Vault { Read-Json (Join-Path $script:State 'keys.json') }
function New-Token { 'nwm_' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant() }
function Protect-Token([string]$Token) { $Token | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString }
function Read-Token([string]$Secret) {
    [pscredential]::new('key', (ConvertTo-SecureString $Secret)).GetNetworkCredential().Password
}
function Get-Key([string]$Id = 'local') {
    $entry = @((Get-Vault).keys | Where-Object { $_.id -eq $Id -and -not $_.revoked })
    if ($entry.Count -ne 1) { throw "No active key named $Id. Use -Action Keys." }
    Read-Token $entry[0].secret
}
function Initialize-State {
    if (-not [OperatingSystem]::IsWindows()) { throw 'Run this manager on Windows with PowerShell 7.2 or newer.' }
    [void][IO.Directory]::CreateDirectory($script:State)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-Native icacls.exe @($script:State, '/inheritance:r', '/grant:r', "*$($sid):(OI)(CI)F", '*S-1-5-18:(OI)(CI)F') | Out-Null
    [IO.File]::SetAttributes($script:State, ([IO.File]::GetAttributes($script:State) -bor [IO.FileAttributes]::Hidden))
    foreach ($folder in @('run','models','cache','logs','backups')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:State $folder))
    }
    $settingsPath = Join-Path $script:State 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Write-Json $settingsPath @{
            version=1; model=$script:ModelName; contextTokens=262144; kvType='k8v4'
            hostCache='8GiB'; draftTokens=5; memoryReserve='512MiB'; localPort=8080
            https=@{enabled=$false; address=''; hostname=''; port=8443}
        }
    }
    $vaultPath = Join-Path $script:State 'keys.json'
    if (-not (Test-Path -LiteralPath $vaultPath)) {
        Write-Json $vaultPath @{
            version=1; backend=(Protect-Token (New-Token))
            keys=@(@{id='local'; name='This PC'; secret=(Protect-Token (New-Token)); createdUtc=[datetime]::UtcNow.ToString('o'); revoked=$false})
        }
    }
    if ((Get-Settings).version -ne 1 -or (Get-Vault).version -ne 1) {
        throw 'Unsupported settings version. Keep the existing files for recovery.'
    }
}
function Get-Docker([string[]]$Arguments) {
    $output = & docker @Arguments 2>$null
    if ($LASTEXITCODE -eq 0) { ($output -join "`n") | ConvertFrom-Json -NoEnumerate }
}
function Assert-Ownership {
    foreach ($container in @('ninfer','ninfer-https','ninfer-gateway')) {
        $info = Get-Docker @('inspect',$container)
        if ($info -and $info[0].Config.Labels.'com.ninfer-manager.owner' -ne $script:Owner) {
            throw "Container $container belongs to another installation."
        }
    }
}
function Invoke-Compose([string[]]$Arguments, [string]$File = (Join-Path $script:State 'run/compose.json')) {
    Invoke-Native docker (@('compose','--project-name',$script:Project,'--file',$File) + $Arguments)
}
function Test-Requirements {
    foreach ($command in @('docker','git','curl.exe','nvidia-smi')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Install $command first. See README.md." }
    }
    $type = & docker info --format '{{.OSType}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or $type -ne 'linux') { throw 'Start Docker Desktop with Linux containers and WSL2.' }
    $gpu = & nvidia-smi --query-gpu=name --format=csv,noheader
    if ($LASTEXITCODE -ne 0 -or -not ($gpu -match 'RTX 5090')) { throw 'This build targets the RTX 5090.' }
}
function Install-Engine {
    Test-Requirements
    $image = Get-Docker @('image','inspect',$script:EngineImage)
    if ($image) {
        if ($image[0].Config.Labels.'com.ninfer-manager.commit' -ne $script:Revision) { throw 'Existing engine image has unexpected provenance.' }
    } else {
        $source = Join-Path $script:State 'cache/source/ninfer'
        if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
            Invoke-Native git @('clone','https://github.com/Neroued/ninfer.git',$source)
        }
        $origin = & git -C $source remote get-url origin
        if ($origin.TrimEnd('/') -ne 'https://github.com/Neroued/ninfer.git') { throw 'Cached source has an unexpected origin.' }
        if (& git -C $source status --porcelain) { throw 'Cached source has local edits. Preserve them before installing.' }
        Invoke-Native git @('-C',$source,'fetch','origin',$script:Revision)
        Invoke-Native git @('-C',$source,'checkout','--detach',$script:Revision)
        $build = Join-Path $script:State 'cache/build'
        [void][IO.Directory]::CreateDirectory($build)
        $dockerfile = @(
            '# syntax=docker/dockerfile:1'
            'ARG CUDA_BUILD'
            'ARG CUDA_RUNTIME'
            'FROM ${CUDA_BUILD} AS build'
            'RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build pkg-config libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libcurl4-openssl-dev libhwloc-dev libjpeg-dev liburing-dev && rm -rf /var/lib/apt/lists/*'
            'RUN ln -s /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/libcuda.so.1'
            'WORKDIR /src'
            'COPY --from=upstream / /src/'
            'RUN cmake -S . -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release -DNINFER_TARGET=rtx5090 -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF -DNINFER_BUILD_BENCHMARKS=OFF && cmake --build /build --parallel --target ninfer ninfer-serve'
            'FROM ${CUDA_RUNTIME}'
            'RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libcurl4-openssl-dev libhwloc-dev libjpeg-dev liburing-dev && rm -rf /var/lib/apt/lists/*'
            'COPY --from=build /build/apps/ninfer /opt/ninfer/apps/ninfer'
            'COPY --from=build /build/apps/ninfer-serve /opt/ninfer/apps/ninfer-serve'
            'COPY --from=build /build/lib/ /opt/ninfer/lib/'
            'ENV PATH="/opt/ninfer/apps:${PATH}"'
            'WORKDIR /workspace'
        ) -join "`n"
        [IO.File]::WriteAllText((Join-Path $build 'Dockerfile'), $dockerfile)
        Invoke-Native docker @('build','--build-context',"upstream=$source",'--build-arg',"CUDA_BUILD=$script:CudaBuild",'--build-arg',"CUDA_RUNTIME=$script:CudaRuntime",'--label',"com.ninfer-manager.owner=$script:Owner",'--label',"com.ninfer-manager.commit=$script:Revision",'-t',$script:EngineImage,$build)
    }
    $model = Join-Path $script:State ('models/' + (Get-Settings).model)
    if (-not (Test-Path -LiteralPath $model)) {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($model))
        if ($drive.AvailableFreeSpace -lt 60GB) { throw 'Allow at least 60 GB free for the first installation.' }
        Invoke-Native curl.exe @('--location','--fail','--retry','5','--continue-at','-','--output',"$model.partial",$script:ModelUrl)
        if ((Get-Item "$model.partial").Length -ne $script:ModelBytes -or (Get-FileHash "$model.partial").Hash.ToLowerInvariant() -ne $script:ModelHash) {
            throw 'Model verification failed. The partial download was kept.'
        }
        Move-Item -LiteralPath "$model.partial" -Destination $model
    }
    if ((Get-Item $model).Length -ne $script:ModelBytes -or (Get-FileHash $model).Hash.ToLowerInvariant() -ne $script:ModelHash) {
        throw 'Model verification failed. The original file was not changed.'
    }
}
function Write-ApiConfig($Settings = (Get-Settings)) {
    $vault = Get-Vault
    $tokens = @($vault.keys | Where-Object { -not $_.revoked } | ForEach-Object { Read-Token $_.secret })
    if (-not $tokens.Count -or @($tokens | Where-Object { $_ -notmatch '^nwm_[a-f0-9]{64}$' }).Count) { throw 'Invalid API-key storage.' }
    $bearer = ($tokens | ForEach-Object { '"Bearer ' + $_ + '"' }) -join ','
    $alternate = ($tokens | ForEach-Object { '"' + $_ + '"' }) -join ','
    $authRule = '@allowed expression '+[char]96+'{http.request.header.Authorization} in ['+$bearer+'] || {http.request.header.X-Api-Key} in ['+$alternate+']'+[char]96
    $backend = Read-Token $vault.backend
    $sni = if ($Settings.https.enabled) { "default_sni $($Settings.https.hostname)" } else { '' }
    $config = @"
{
    admin localhost:2019
    auto_https disable_redirects
    $sni
}
(upstream) {
    reverse_proxy ninfer:8080 {
        header_up Authorization "Bearer $backend"
        header_up -X-Api-Key
    }
}
(api) {
    request_body {
        max_size 16MB
    }
    @browser header Origin *
    handle @browser {
        respond "Browser origins are not enabled." 403
    }
    @health {
        method GET
        path /health
    }
    handle @health {
        import upstream
    }
    $authRule
    handle @allowed {
        import upstream
    }
    respond "A valid API key is required." 401
}
http://:8080 {
    import api
}
"@
    if ($Settings.https.enabled) {
        $config += @"

https://$($Settings.https.hostname):8443 {
    tls internal
    import api
}
"@
    }
    [IO.File]::WriteAllText((Join-Path $script:State 'run/Caddyfile'), $config, [Text.UTF8Encoding]::new($false))
}
function Write-Runtime {
    $s = Get-Settings
    if ($s.contextTokens -ne 262144) { throw 'This model preset uses a 262144-token window.' }
    $backend = Read-Token (Get-Vault).backend
    $toml = @"
[model]
path = "/models/$($s.model)"
vision = false
[engine]
max_context = 262144
kv_dtype = "$($s.kvType)"
context_capacity = "auto"
memory_headroom = "$($s.memoryReserve)"
max_concurrency = 1
max_pending_requests = 4
pending_timeout = "1800s"
prefill_chunk = 1024
cuda_graph = true
[context_cache]
prefix_reuse = true
checkpoint_interval = 8192
host_capacity = "$($s.hostCache)"
[speculative]
backend = "mtp"
draft_tokens = $($s.draftTokens)
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
    $run = Join-Path $script:State 'run'
    [IO.File]::WriteAllText((Join-Path $run 'ninfer.toml'), $toml, [Text.UTF8Encoding]::new($false))
    Write-ApiConfig $s
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($toml))).ToLowerInvariant()
    $services = [ordered]@{
        ninfer = @{
            image=$script:EngineImage; container_name='ninfer'; restart='unless-stopped'; gpus='all'
            labels=@{'com.ninfer-manager.owner'=$script:Owner; 'com.ninfer-manager.config-sha256'=$digest; 'com.ninfer-manager.native'='true'}
            command=@('ninfer-serve','--config','/run/manager/ninfer.toml'); networks=@('backend')
            volumes=@(@{type='bind';source=(Join-Path $script:State 'models');target='/models';read_only=$true},@{type='bind';source=$run;target='/run/manager';read_only=$true},@{type='bind';source=(Join-Path $script:State 'logs');target='/logs'})
        }
        caddy = @{
            image=$script:CaddyImage; container_name='ninfer-https'; restart='unless-stopped'
            labels=@{'com.ninfer-manager.owner'=$script:Owner}
            command=@('caddy','run','--config','/run/manager/Caddyfile','--adapter','caddyfile')
            networks=@('backend','edge'); depends_on=@('ninfer'); ports=@("127.0.0.1:$($s.localPort):8080")
            volumes=@(@{type='bind';source=$run;target='/run/manager';read_only=$true},'caddy-data:/data','caddy-config:/config')
        }
    }
    if ($s.https.enabled) { $services.caddy.ports += "$($s.https.address):$($s.https.port):8443" }
    Write-Json (Join-Path $run 'compose.json') @{name=$script:Project;services=$services;networks=@{backend=@{internal=$true};edge=@{}};volumes=@{'caddy-data'=@{};'caddy-config'=@{}}}
    Write-Json (Join-Path $run 'settings.json') $s
}
function Save-Runtime {
    $run = Join-Path $script:State 'run'
    if (-not (Test-Path -LiteralPath (Join-Path $run 'compose.json'))) { return }
    $backup = Join-Path $script:State 'backups/last-good'
    [void][IO.Directory]::CreateDirectory($backup)
    foreach ($file in @('compose.json','ninfer.toml','Caddyfile','settings.json')) {
        if (Test-Path -LiteralPath (Join-Path $run $file)) { Copy-Item -LiteralPath (Join-Path $run $file) -Destination $backup -Force }
    }
}
function Restore-Previous([switch]$Original) {
    $backup = Join-Path $script:State 'backups/last-good'
    if ($Original -or -not (Test-Path -LiteralPath (Join-Path $backup 'compose.json'))) { $backup = Join-Path $script:State 'backups/previous' }
    if (-not (Test-Path -LiteralPath (Join-Path $backup 'compose.json'))) { throw 'No previous deployment has been saved.' }
    $registryFile = Join-Path $backup 'clients.json'
    if (Test-Path -LiteralPath $registryFile) {
        $keys = @((Get-Vault).keys | ForEach-Object {
            $plain = Read-Token $_.secret
            @{id=$_.id;name=$_.name;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($plain))).ToLowerInvariant();createdUtc=$_.createdUtc;expiresUtc=$null;revokedUtc=$(if($_.revoked){[datetime]::UtcNow.ToString('o')}else{$null})}
        })
        Write-Json $registryFile @{version=1;clients=$keys}
        Invoke-Compose @('up','-d','--remove-orphans') (Join-Path $backup 'compose.json')
    } else {
        foreach ($file in @('compose.json','ninfer.toml','Caddyfile','settings.json')) { Copy-Item -LiteralPath (Join-Path $backup $file) -Destination (Join-Path $script:State 'run') -Force }
        Copy-Item -LiteralPath (Join-Path $backup 'settings.json') -Destination (Join-Path $script:State 'settings.json') -Force
        Write-ApiConfig
        Invoke-Compose @('up','-d','--remove-orphans')
    }
}
function Invoke-Api([string]$Path, $Body = $null, [int]$Timeout = 1800) {
    $s = Get-Settings
    $request = @{Uri="http://127.0.0.1:$($s.localPort)$Path";Headers=@{Authorization=('Bearer '+(Get-Key))};TimeoutSec=$Timeout}
    if ($null -ne $Body) { $request.Method='POST';$request.ContentType='application/json';$request.Body=$Body|ConvertTo-Json -Depth 12 }
    Invoke-RestMethod @request
}
function Start-Engine {
    Assert-Ownership
    $model = Join-Path $script:State ('models/'+(Get-Settings).model)
    if (-not (Test-Path -LiteralPath $model) -or -not (Get-Docker @('image','inspect',$script:EngineImage))) { Install-Engine }
    $previousEngine = Get-Docker @('inspect','ninfer')
    $wasNative = $previousEngine -and $previousEngine[0].State.Running -and $previousEngine[0].Config.Labels.PSObject.Properties['com.ninfer-manager.native'] -and $previousEngine[0].Config.Labels.'com.ninfer-manager.native' -eq 'true'
    if ($wasNative) { Save-Runtime }
    try {
        Write-Runtime
        Invoke-Compose @('up','-d','--remove-orphans')
        Write-Host 'Loading Qwen. The first start may take a few minutes.' -ForegroundColor Cyan
        $deadline = [datetime]::UtcNow.AddMinutes(20)
        do {
            try { if ((Invoke-Api '/health' $null 5).status -eq 'ok') { break } } catch {}
            $engine = Get-Docker @('inspect','ninfer')
            if ($engine -and $engine[0].State.Status -in @('exited','dead','restarting')) { throw 'NInfer did not stay running. Use -Action Logs.' }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Model startup timed out. Use -Action Logs.' }
            Start-Sleep -Seconds 3
        } while ($true)
        $reply = Invoke-Api '/v1/chat/completions' @{model='qwen3.8-27b';messages=@(@{role='user';content='Reply READY.'});max_tokens=16;enable_thinking=$false}
        if (-not $reply.choices[0].message.content) { throw 'The model returned no answer.' }
        if ((Get-Settings).https.enabled) {
            Invoke-Native docker @('cp','ninfer-https:/data/caddy/pki/authorities/local/root.crt',(Join-Path $script:State 'root-ca.crt'))
        }
        Write-Host 'NInfer is ready.' -ForegroundColor Green
        Show-Connection
    } catch {
        $failure = $_
        try { Restore-Previous -Original:(-not $wasNative) } catch { Write-Warning 'The previous deployment could not be restored automatically. Your files are kept in .ninfer/backups.' }
        throw $failure
    }
}
function Show-Connection {
    $s = Get-Settings
    Write-Host "Local API  http://127.0.0.1:$($s.localPort)/v1"
    if ($s.https.enabled) { Write-Host "HTTPS API  https://$($s.https.hostname):$($s.https.port)/v1" }
    Write-Host 'Model      qwen3.8-27b'
    Write-Host 'Context    262,144 tokens'
    Write-Host 'API key    Use -Action CopyKey to copy it.'
}
function Reload-Keys {
    Write-ApiConfig
    $container = Get-Docker @('inspect','ninfer-https')
    if ($container -and $container[0].State.Running) {
        Invoke-Native docker @('exec','ninfer-https','caddy','reload','--config','/run/manager/Caddyfile','--adapter','caddyfile')
    }
}
function Add-Key {
    $vault = Get-Vault
    $token = New-Token
    $id = $Name+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $vault.keys = @($vault.keys)+@(@{id=$id;name=$Name;secret=(Protect-Token $token);createdUtc=[datetime]::UtcNow.ToString('o');revoked=$false})
    Write-Json (Join-Path $script:State 'keys.json') $vault
    Reload-Keys
    Write-Host "Key ID: $id"
    Write-Host "API key (shown once): $token"
}
function Disable-Key {
    if ($KeyId -eq 'local') { throw 'The local manager key cannot be revoked.' }
    $vault = Get-Vault
    $entry = @($vault.keys | Where-Object id -eq $KeyId)
    if ($entry.Count -ne 1) { throw 'Choose an existing ID from -Action Keys.' }
    $entry[0].revoked = $true
    Write-Json (Join-Path $script:State 'keys.json') $vault
    Reload-Keys
    Write-Host "Revoked $KeyId."
}
function Set-Https([bool]$Enabled) {
    $previous = Get-Settings
    $settings = Get-Settings
    if ($Enabled) {
        if (-not $Address -or -not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $Address)) { throw 'Use -Address with an IPv4 address assigned to this PC.' }
        $hostname = if ($ServerName) { $ServerName } else { $Address }
        if ($hostname -notmatch '^[a-zA-Z0-9.-]+$') { throw 'Use an IP address or a DNS hostname.' }
        $settings.https.address=$Address;$settings.https.hostname=$hostname;$settings.https.port=$Port
    }
    $settings.https.enabled=$Enabled
    Write-Json (Join-Path $script:State 'settings.json') $settings
    try { Start-Engine } catch { Write-Json (Join-Path $script:State 'settings.json') $previous;throw }
}
function Test-Manager {
    $previous = $script:State
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $fixture = Join-Path $tempRoot ('ninfer-check-'+[guid]::NewGuid().ToString('N'))
    try {
        $script:State=$fixture
        Initialize-State
        $token=Get-Key
        if ($token -notmatch '^nwm_[a-f0-9]{64}$') { throw 'Invalid key generation.' }
        if ([IO.File]::ReadAllText((Join-Path $fixture 'keys.json')).Contains($token)) { throw 'Key storage is not encrypted.' }
        $revokedToken=New-Token
        $vault=Get-Vault
        $vault.keys+=@([pscustomobject]@{id='revoked-check';name='Check';secret=(Protect-Token $revokedToken);createdUtc=[datetime]::UtcNow.ToString('o');revoked=$true})
        Write-Json (Join-Path $fixture 'keys.json') $vault
        Write-Runtime
        $compose=Read-Json (Join-Path $fixture 'run/compose.json')
        if ($compose.services.ninfer.PSObject.Properties.Name -contains 'ports') { throw 'The engine must stay private.' }
        if ($compose.services.caddy.ports[0] -ne '127.0.0.1:8080:8080') { throw 'Local access must stay on loopback.' }
        $settings=Get-Settings;$settings.https.enabled=$true;$settings.https.address='192.168.50.115';$settings.https.hostname='192.168.50.115'
        Write-Json (Join-Path $fixture 'settings.json') $settings
        $revokedToken=New-Token
        $vault=Get-Vault
        $vault.keys+=@([pscustomobject]@{id='revoked-check';name='Check';secret=(Protect-Token $revokedToken);createdUtc=[datetime]::UtcNow.ToString('o');revoked=$true})
        Write-Json (Join-Path $fixture 'keys.json') $vault
        Write-Runtime
        $compose=Read-Json (Join-Path $fixture 'run/compose.json')
        if ($compose.services.caddy.ports[1] -ne '192.168.50.115:8443:8443') { throw 'HTTPS address changed.' }
        $config=[IO.File]::ReadAllText((Join-Path $fixture 'run/Caddyfile'))
        if ($config.Contains($revokedToken)) { throw 'A revoked key is still allowed.' }
        if (-not $config.Contains('"Bearer '+$token+'"') -or -not $config.Contains('tls internal')) { throw 'Authentication or HTTPS is missing.' }
        Save-Runtime
        if (-not (Test-Path (Join-Path $fixture 'backups/last-good/compose.json'))) { throw 'Runtime backup failed.' }
        if (196608+8192 -ge $settings.contextTokens) { throw 'Context has no response headroom.' }
        Write-Host 'PASS Windows key protection, API configuration, runtime isolation, HTTPS, and backup checks.' -ForegroundColor Green
    } finally {
        $script:State=$previous
        if ([IO.Path]::GetFullPath($fixture).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $fixture -Leaf) -like 'ninfer-check-*') {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
    }
}
function Show-Menu {
    do {
        Write-Host "`nNInfer Windows Manager" -ForegroundColor Cyan
        Write-Host '1 Start / Install   2 Status   3 Stop   4 Restart'
        Write-Host '5 Copy API key      6 Keys     7 Logs   0 Exit'
        switch (Read-Host 'Choose') {
            '1' { Start-Engine }
            '2' { Show-Connection;Invoke-Native docker @('ps','--filter',"label=com.ninfer-manager.owner=$script:Owner",'--format','{{.Names}}  {{.Status}}') }
            '3' { Assert-Ownership;Invoke-Compose @('stop') }
            '4' { Assert-Ownership;Invoke-Compose @('stop');Start-Engine }
            '5' { Set-Clipboard (Get-Key);Write-Host 'API key copied.' }
            '6' { (Get-Vault).keys | Select-Object id,name,createdUtc,revoked | Format-Table }
            '7' { Invoke-Compose @('logs','--tail','80') }
            '0' { return }
        }
    } while ($true)
}
if ($MyInvocation.InvocationName -ne '.') {
    $lock=$null
    try {
        if ($Action -eq 'SelfTest') { Test-Manager;exit 0 }
        [void][IO.Directory]::CreateDirectory($script:State)
        try { $lock=[IO.File]::Open((Join-Path $script:State 'manager.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch [IO.IOException] { throw 'Another manager action is running. Wait for it to finish.' }
        Initialize-State
        switch ($Action) {
            'Menu' { Show-Menu }
            'Install' { Install-Engine;Start-Engine }
            'Start' { Start-Engine }
            'Stop' { Assert-Ownership;Invoke-Compose @('stop') }
            'Restart' { Assert-Ownership;Invoke-Compose @('stop');Start-Engine }
            'Status' { Show-Connection;Invoke-Native docker @('ps','--filter',"label=com.ninfer-manager.owner=$script:Owner",'--format','{{.Names}}  {{.Status}}') }
            'Connection' { Show-Connection }
            'EnableHttps' { Set-Https $true }
            'DisableHttps' { Set-Https $false }
            'NewKey' { Add-Key }
            'Keys' { (Get-Vault).keys | Select-Object id,name,createdUtc,revoked | Format-Table }
            'CopyKey' { Set-Clipboard (Get-Key $KeyId);Write-Host 'API key copied.' }
            'RevokeKey' { Disable-Key }
            'Logs' { Invoke-Compose @('logs','--tail','100','--follow') }
            'Rollback' { Assert-Ownership;Restore-Previous;Show-Connection }
        }
    } catch { Write-Error $_;exit 1 } finally { if ($lock) { $lock.Dispose() } }
}
