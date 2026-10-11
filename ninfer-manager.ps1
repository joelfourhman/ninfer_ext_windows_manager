#requires -Version 5.1
<#
.SYNOPSIS
  Installs and manages giveen/ninfer-ext on Windows 11 with Docker Desktop/WSL2.
.DESCRIPTION
  All persistent data is rooted beside this script. The default profile is deliberately strict:
  262144 context, FP8 KV, KV streaming, one active request, and fixed five-token MTP drafting.
  Run without parameters for the interactive menu, or use -Action <name> for automation.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Start','Stop','Restart','Status','CheckUpdates','Update','Rebuild',
        'Logs','Diagnostics','Repair','ModelSettings','PerformanceSettings','NetworkSettings',
        'ResetDefaults','ShowKey','RotateKey','Firewall','StressTest','SelfTest','Uninstall')]
    [string]$Action = 'Menu',
    [switch]$NonInteractive,
    [switch]$Yes,
    [string]$TrustedRemoteAddress,
    [int]$StressTokens = 250000
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ManagerVersion = '1.0.0'
$script:ManagerId = 'ninfer-ext-windows-manager-v1'
$script:Root = [IO.Path]::GetFullPath($PSScriptRoot)
$script:Models = Join-Path $script:Root 'models'
$script:SourceRoot = Join-Path $script:Root 'source'
$script:Source = Join-Path $script:SourceRoot 'ninfer-ext'
$script:Config = Join-Path $script:Root 'config'
$script:Logs = Join-Path $script:Root 'logs'
$script:Temp = Join-Path $script:Root 'temp'
$script:SettingsPath = Join-Path $script:Config 'settings.json'
$script:DeploymentPath = Join-Path $script:Config 'deployment.json'
$script:SecretsPath = Join-Path $script:Config 'secrets.json'
$script:LogPath = Join-Path $script:Logs ('manager-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
$script:ContainerName = 'ninfer-ext'
$script:ImageRepository = 'ninfer-ext-manager'
$script:FirewallRule = 'NInfer-Ext Manager LAN'
$script:SourceUrl = 'https://github.com/giveen/ninfer-ext.git'
$script:CudaImageVersion = '13.3.1'
$script:CudaUbuntu = 'ubuntu26.04'
$script:ModelDefaults = [ordered]@{
    repository = 'neroued/Qwen3.8-27B-nvfp4-NInfer'
    revision = 'a107ba1b5b0609d9ca90d5ed61439f5f5cc7d64d'
    artifact = 'qwen3_8_27b_nvfp4.ninfer'
    modelId = 'qwen3.8-27b'
    bytes = [int64]23719715844
    sha256 = '74d2c57145e6ff11d1d2faa79594477f9bc903a611af1fb20218189fbbb77d82'
    maxPositionEmbeddings = 262144
    fullAttentionLayers = 16
    kvHeads = 4
    headDimension = 256
    mtpLayers = 1
    minimumRuntimeCommit = '98dada0e03cb073fd07f905400b5904bc6e82759'
}

function Test-Interactive { return (-not $NonInteractive) -and [Environment]::UserInteractive }
function Write-Color([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    if ($Host.UI.SupportsVirtualTerminal -or $Host.Name -match 'ConsoleHost') { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
}
function Protect-Text([string]$Text) {
    if (-not $Text) { return $Text }
    if (Test-Path -LiteralPath $script:SecretsPath) {
        try {
            $key = (Get-Content -LiteralPath $script:SecretsPath -Raw | ConvertFrom-Json).apiKey
            if ($key) { $Text = $Text.Replace([string]$key, '<redacted>') }
        } catch {}
    }
    return $Text
}
function Write-Log([string]$Level, [string]$Message, [hashtable]$Data = @{}) {
    $safe = Protect-Text $Message
    $entry = [ordered]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); level = $Level; message = $safe; data = $Data }
    try { Add-Content -LiteralPath $script:LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 8) -Encoding utf8 } catch {}
    if ($Level -eq 'ERROR') { Write-Color $safe Red }
    elseif ($Level -eq 'WARN') { Write-Color $safe Yellow }
    elseif ($Level -eq 'INFO') { Write-Host $safe }
}
function Confirm-Choice([string]$Prompt, [bool]$Default = $false) {
    if ($Yes) { return $true }
    if (-not (Test-Interactive)) { return $false }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if (-not $answer) { return $Default }
    return $answer -match '^(y|yes)$'
}
function New-Directories {
    foreach ($path in @($script:Models,$script:SourceRoot,$script:Config,$script:Logs,$script:Temp)) {
        [void][IO.Directory]::CreateDirectory($path)
    }
}
function Write-JsonAtomic([string]$Path, $Value) {
    $tmp = "$Path.$PID.tmp"
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-Json([string]$Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "Invalid JSON in $Path. Restore or remove that file and retry. $($_.Exception.Message)" }
}
function Get-RandomKey {
    $bytes = [byte[]]::new(36)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return 'ninf_' + [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Protect-SecretsFile {
    if (-not (Test-Path -LiteralPath $script:SecretsPath)) { return }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        # Full control for the creating user is needed for atomic replacement/key rotation; inheritance is removed.
        & icacls.exe $script:SecretsPath '/inheritance:r' '/grant:r' "${user}:(F)" '/c' | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log WARN 'Could not restrict secrets.json ACL. Restrict it manually before enabling LAN access.' }
    }
}
function Get-MemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [pscustomobject]@{ TotalMiB=[math]::Floor([double]$os.TotalVisibleMemorySize/1024); AvailableMiB=[math]::Floor([double]$os.FreePhysicalMemory/1024) }
    } catch {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $ci = [Microsoft.VisualBasic.Devices.ComputerInfo]::new()
        return [pscustomobject]@{ TotalMiB=[math]::Floor($ci.TotalPhysicalMemory/1MB); AvailableMiB=[math]::Floor($ci.AvailablePhysicalMemory/1MB) }
    }
}
function Get-DefaultHostKvMiB {
    param([int64]$TotalMiB, [int64]$AvailableMiB, [int64]$Context = 262144)
    # 16 full-attention layers + one MTP layer, 4 KV heads, d=256, K+V, one byte FP8.
    $bytesPerToken = ($script:ModelDefaults.fullAttentionLayers + $script:ModelDefaults.mtpLayers) *
        $script:ModelDefaults.kvHeads * $script:ModelDefaults.headDimension * 2
    $worstCaseMiB = [math]::Ceiling(($Context * $bytesPerToken) / 1MB)
    $desiredMiB = [math]::Ceiling($worstCaseMiB * 1.10)
    $osReserve = [math]::Max(16384, [math]::Ceiling($TotalMiB * 0.25))
    $dynamicReserve = [math]::Max($osReserve, $TotalMiB - $AvailableMiB + 8192)
    $safeNow = [math]::Max(1024, $TotalMiB - $dynamicReserve)
    return [int][math]::Max(1024, [math]::Min($desiredMiB, $safeNow))
}
function New-DefaultSettings {
    $memory = Get-MemoryInfo
    $model = [ordered]@{}
    foreach ($key in $script:ModelDefaults.Keys) { $model[$key] = $script:ModelDefaults[$key] }
    return [ordered]@{
        schemaVersion = 1
        model = $model
        runtime = [ordered]@{
            maxContext = 262144; kvCapacity = 'auto'; maxConcurrency = 1; kvDtype = 'fp8'
            kvStream = $true; hostKvMiB = (Get-DefaultHostKvMiB $memory.TotalMiB $memory.AvailableMiB)
            hostCacheMiB = 0; spec = 'mtp'; draftTokens = 5; fixedDraft = $true; lmHeadDraft = $true
        }
        network = [ordered]@{ port = 8080; lanEnabled = $false; trustedRemoteAddress = ''; restartPolicy = 'unless-stopped' }
        memory = [ordered]@{ reserveMiB = [math]::Max(16384, [math]::Ceiling($memory.TotalMiB * 0.25)); lastCalculatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }
}
function Initialize-State {
    New-Directories
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { Write-JsonAtomic $script:SettingsPath (New-DefaultSettings) }
    if (-not (Test-Path -LiteralPath $script:DeploymentPath)) {
        Write-JsonAtomic $script:DeploymentPath ([ordered]@{ schemaVersion=1; activeCommit=''; lastBuiltCommit=''; lastKnownGoodImage=''; modelRevision=''; configHash=''; empiricallyValidatedContext=0; lastUpdateCheckUtc=''; firewallRule='' })
    }
    if (-not (Test-Path -LiteralPath $script:SecretsPath)) {
        Write-JsonAtomic $script:SecretsPath ([ordered]@{ schemaVersion=1; apiKey=(Get-RandomKey); createdUtc=(Get-Date).ToUniversalTime().ToString('o') })
    }
    Protect-SecretsFile
}
function Assert-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return }
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Color 'PowerShell 7 is required. Install it with: winget install --id Microsoft.PowerShell --exact' Yellow
        if ((Test-Interactive) -and (Get-Command winget.exe -ErrorAction SilentlyContinue) -and (Confirm-Choice 'Install PowerShell 7 now?')) {
            & winget.exe install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements
            Write-Host 'Installation finished. Re-run this script in PowerShell 7.'
        }
        exit 10
    }
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action',$Action)
    if ($NonInteractive) { $args += '-NonInteractive' }; if ($Yes) { $args += '-Yes' }
    if ($TrustedRemoteAddress) { $args += @('-TrustedRemoteAddress',$TrustedRemoteAddress) }
    & $pwsh.Source @args
    exit $LASTEXITCODE
}
function Invoke-Process {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments=@(), [switch]$AllowFailure, [switch]$Live, [int]$TimeoutSeconds=0)
    $display = Protect-Text (($File + ' ' + (($Arguments | ForEach-Object { if ($_ -match '\s') { '"'+$_+'"' } else { $_ } }) -join ' ')).Trim())
    Write-Log DEBUG $display
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $File; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = -not $Live; $psi.RedirectStandardError = -not $Live
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add([string]$arg) }
    $p = [Diagnostics.Process]::new(); $p.StartInfo = $psi
    if (-not $p.Start()) { throw "Could not start $File" }
    if (-not $Live) { $stdoutTask=$p.StandardOutput.ReadToEndAsync(); $stderrTask=$p.StandardError.ReadToEndAsync() }
    if ($TimeoutSeconds -gt 0 -and -not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill($true) } catch {}; throw "$File timed out after $TimeoutSeconds seconds." }
    $p.WaitForExit()
    $stdout=if($Live){''}else{$stdoutTask.GetAwaiter().GetResult().TrimEnd()};$stderr=if($Live){''}else{$stderrTask.GetAwaiter().GetResult().TrimEnd()}
    $result = [pscustomobject]@{ ExitCode=$p.ExitCode; StdOut=$stdout; StdErr=$stderr; Command=$display }
    if ($p.ExitCode -ne 0 -and -not $AllowFailure) {
        $detail=if($Live){'See the external command output immediately above.'}else{Protect-Text $result.StdErr}
        throw "$File failed with exit code $($p.ExitCode): $detail"
    }
    return $result
}
function Get-CommandPath([string]$Name) { $c=Get-Command $Name -ErrorAction SilentlyContinue; if ($c) { return $c.Source }; return $null }
function Get-ContainerInfo {
    if (-not (Get-CommandPath docker)) { return $null }
    $r=Invoke-Process docker @('inspect',$script:ContainerName,'--format','{{json .}}') -AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    return $r.StdOut | ConvertFrom-Json
}
function Assert-OwnedContainer($Info) {
    if (-not $Info) { return }
    if ($Info.Config.Labels.'com.ninfer-manager.owner' -ne $script:ManagerId) { throw "Container '$($script:ContainerName)' exists but is not owned by this manager. Rename or remove it yourself." }
}
function Get-Settings { return Read-Json $script:SettingsPath $null }
function Get-Deployment { return Read-Json $script:DeploymentPath $null }
function Get-Secrets { return Read-Json $script:SecretsPath $null }
function Get-ConfigHash($Settings) {
    $secretFingerprint=''
    if(Test-Path -LiteralPath $script:SecretsPath){$secretFingerprint=(Get-Secrets).apiKey}
    $json = ($Settings | ConvertTo-Json -Depth 20 -Compress) + "`n" + $secretFingerprint
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).ToLowerInvariant() } finally { $sha.Dispose() }
}
function Assert-DefaultProfile($Settings) {
    $r=$Settings.runtime; $fail=@()
    if ([int]$r.maxContext -ne 262144) {$fail+='--max-context 262144'}; if ([string]$r.kvCapacity -ne 'auto') {$fail+='--kv-capacity auto'}
    if ([int]$r.maxConcurrency -ne 1) {$fail+='--max-concurrency 1'}; if ([string]$r.kvDtype -ne 'fp8') {$fail+='--kv-dtype fp8'}
    if (-not $r.kvStream) {$fail+='--kv-stream'}; if ([int]$r.hostKvMiB -le 0) {$fail+='--host-kv-mib positive'}
    if ([string]$r.spec -ne 'mtp') {$fail+='--spec mtp'}; if ([int]$r.draftTokens -ne 5) {$fail+='--draft-tokens 5'}
    if (-not $r.fixedDraft) {$fail+='--fixed-draft'}; if (-not $r.lmHeadDraft) {$fail+='--lm-head-draft'}
    return ,$fail
}
function Test-PortAvailable([int]$Port) {
    $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return -not $listeners
}
function Get-Hardware {
    $mem=Get-MemoryInfo; $gpuName='Not detected'; $vram=0; $driver=''
    if (Get-CommandPath nvidia-smi) {
        $r=Invoke-Process nvidia-smi @('--query-gpu=name,memory.total,driver_version','--format=csv,noheader,nounits') -AllowFailure
        if ($r.ExitCode -eq 0 -and $r.StdOut) { $p=($r.StdOut -split "`n")[0] -split ','; $gpuName=$p[0].Trim(); $vram=[int]([double]$p[1].Trim()); $driver=$p[2].Trim() }
    }
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:Root))
    return [pscustomobject]@{ GPU=$gpuName; VramMiB=$vram; Driver=$driver; TotalRamMiB=$mem.TotalMiB; AvailableRamMiB=$mem.AvailableMiB; FreeDiskGiB=[math]::Round($drive.AvailableFreeSpace/1GB,1) }
}
function Test-Prerequisites([switch]$ForInstall, [switch]$GpuSmoke) {
    $issues=[Collections.Generic.List[string]]::new(); $h=Get-Hardware
    if (-not [Environment]::Is64BitOperatingSystem) { $issues.Add('64-bit Windows is required.') }
    $build=[Environment]::OSVersion.Version.Build; if ($build -lt 22000) { $issues.Add("Windows 11 build 22000+ is required; detected build $build.") }
    if (-not (Get-CommandPath git)) { $issues.Add('Git is missing (winget install --id Git.Git --exact).') }
    $wsl=Get-CommandPath wsl.exe
    if(-not$wsl){$issues.Add('WSL2 is missing (run wsl --install from an Administrator terminal, then reboot).')}
    else{$ws=Invoke-Process $wsl @('--status') -AllowFailure -TimeoutSeconds 20;if($ws.ExitCode-ne0){$issues.Add('WSL is installed but unhealthy. Run wsl --update and wsl --shutdown, then restart Docker Desktop.')}}
    if (-not (Get-CommandPath docker)) { $issues.Add('Docker Desktop CLI is missing (winget install --id Docker.DockerDesktop --exact).') }
    else {
        $d=Invoke-Process docker @('info','--format','{{.OSType}}') -AllowFailure -TimeoutSeconds 20
        if ($d.ExitCode -ne 0) { $issues.Add('Docker daemon is unavailable. Start Docker Desktop and wait until it is ready.') }
        elseif ($d.StdOut.Trim() -ne 'linux') { $issues.Add('Docker Desktop must use Linux containers.') }
        elseif ($GpuSmoke) {
            Write-Host 'Running Docker GPU smoke test (the CUDA image may download once)...'
            $g=Invoke-Process docker @('run','--rm','--gpus','all',"nvidia/cuda:$($script:CudaImageVersion)-base-$($script:CudaUbuntu)",'nvidia-smi','-L') -AllowFailure -TimeoutSeconds 300
            if($g.StdOut){Write-Host $g.StdOut};if($g.StdErr){Write-Host $g.StdErr}
            if ($g.ExitCode -ne 0 -or $g.StdOut -notmatch 'GPU') { $issues.Add('Docker NVIDIA GPU passthrough smoke test failed. Update the NVIDIA driver and Docker Desktop/WSL2 integration.') }
        }
    }
    if ($h.GPU -notmatch 'RTX 5090') { $issues.Add("NInfer-Ext currently supports only RTX 5090 (sm_120a); detected: $($h.GPU).") }
    if ($ForInstall -and $h.FreeDiskGiB -lt 55) { $issues.Add("At least 55 GiB free is required for source, build layers, and the 22.09 GiB model; only $($h.FreeDiskGiB) GiB is free.") }
    if ($ForInstall -and $h.TotalRamMiB -lt 49152) { $issues.Add('At least 48 GiB system RAM is required for this long-context profile; 64 GiB or more is recommended.') }
    if($ForInstall){$configured=(Get-Settings).runtime.hostKvMiB;if($h.AvailableRamMiB-lt([int]$configured+8192)){$issues.Add("Available RAM is too low for the configured Host KV plus 8 GiB working headroom: $($h.AvailableRamMiB) MiB available, $configured MiB Host KV.")}}
    if($ForInstall){foreach($url in @('https://github.com','https://huggingface.co')){try{$null=Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 15 -UseBasicParsing}catch{$issues.Add("Network check failed for ${url}: $($_.Exception.Message)")}}}
    return [pscustomobject]@{ Ok=($issues.Count -eq 0); Issues=$issues; Hardware=$h }
}
function Invoke-PrerequisiteRepair {
    if(-not(Test-Interactive)){return}
    $winget=Get-CommandPath winget.exe
    if(-not(Get-CommandPath git)-and$winget-and(Confirm-Choice 'Install Git using Winget?')){Invoke-Process $winget @('install','--id','Git.Git','--exact','--source','winget','--accept-package-agreements','--accept-source-agreements') -Live|Out-Null}
    if(-not(Get-CommandPath docker)-and$winget-and(Confirm-Choice 'Install Docker Desktop using Winget?')){Invoke-Process $winget @('install','--id','Docker.DockerDesktop','--exact','--source','winget','--accept-package-agreements','--accept-source-agreements') -Live|Out-Null;Write-Log WARN 'Docker Desktop installation may require sign-out or reboot. Re-run this script afterward.'}
    if(-not(Get-CommandPath wsl.exe)){Write-Log WARN 'WSL2 installation changes Windows features and requires Administrator approval. Run: wsl --install, reboot, then re-run this script.'}
    elseif(Confirm-Choice 'Run the official WSL update command?') {Invoke-Process wsl.exe @('--update') -AllowFailure -Live|Out-Null;Invoke-Process wsl.exe @('--shutdown') -AllowFailure|Out-Null}
}
function Get-RemoteHead {
    $r=Invoke-Process git @('ls-remote','--symref',$script:SourceUrl,'HEAD') -AllowFailure -TimeoutSeconds 30
    if ($r.ExitCode -ne 0) { return $null }
    $branch=''; $sha=''
    foreach($line in $r.StdOut -split "`n") { if ($line -match '^ref:\s+refs/heads/(\S+)\s+HEAD'){$branch=$Matches[1]} elseif($line -match '^([0-9a-f]{40})\s+HEAD'){$sha=$Matches[1]} }
    if (-not $sha) { return $null }; return [pscustomobject]@{ Branch=$branch; Sha=$sha }
}
function Sync-Source([string]$Commit) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:Source '.git'))) {
        Invoke-Process git @('clone',$script:SourceUrl,$script:Source) -Live | Out-Null
    }
    Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'fetch','--prune','origin') -Live | Out-Null
    Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'checkout','--detach',$Commit) -Live | Out-Null
    $actual=(Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'rev-parse','HEAD')).StdOut.Trim()
    if ($actual -ne $Commit) { throw "Source checkout is $actual, expected $Commit." }
    $minimum=(Get-Settings).model.minimumRuntimeCommit
    if($minimum){$compatible=Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'merge-base','--is-ancestor',[string]$minimum,$Commit) -AllowFailure;if($compatible.ExitCode-ne0){throw "Selected NInfer-Ext commit $Commit does not contain the model's minimum runtime revision $minimum."}}
}
function Test-Model([switch]$Quiet) {
    $s=Get-Settings; $path=Join-Path $script:Models ([string]$s.model.artifact)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $file=Get-Item -LiteralPath $path
    if ($file.Length -ne [int64]$s.model.bytes) { if(-not $Quiet){Write-Log WARN "Model size is $($file.Length), expected $($s.model.bytes)."}; return $false }
    $marker="$path.ready.json"; if (Test-Path -LiteralPath $marker) {
        $m=Read-Json $marker $null
        if ($m.sha256 -eq $s.model.sha256 -and [int64]$m.bytes -eq $file.Length -and $m.lastWriteUtc -eq $file.LastWriteTimeUtc.ToString('o')) { return $true }
    }
    Write-Host 'Verifying model SHA-256 (this reads 22 GiB and can take several minutes)...'
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $s.model.sha256) { if(-not $Quiet){Write-Log ERROR "Model SHA-256 mismatch: $hash"}; return $false }
    Write-JsonAtomic $marker ([ordered]@{sha256=$hash;bytes=$file.Length;lastWriteUtc=$file.LastWriteTimeUtc.ToString('o');repository=$s.model.repository;revision=$s.model.revision;verifiedUtc=(Get-Date).ToUniversalTime().ToString('o')})
    return $true
}
function Install-Model {
    if (Test-Model) { Write-Log INFO 'Existing model passed size/checksum verification; reusing it.'; return }
    $s=Get-Settings; $final=Join-Path $script:Models ([string]$s.model.artifact); $partial="$final.partial"
    $url="https://huggingface.co/$($s.model.repository)/resolve/$($s.model.revision)/$($s.model.artifact)?download=true"
    Write-Host "Downloading $($s.model.artifact) (22.09 GiB). Interrupted downloads resume."
    $curl=Get-CommandPath curl.exe
    if (-not $curl) { throw 'curl.exe is required for resumable model downloads and is included with Windows 11.' }
    $r=Invoke-Process $curl @('--location','--fail','--retry','8','--retry-delay','5','--continue-at','-','--output',$partial,$url) -AllowFailure -Live
    if ($r.ExitCode -ne 0) { throw "Model download failed. The partial file was kept for resume. $($r.StdErr)" }
    $f=Get-Item -LiteralPath $partial; if ($f.Length -ne [int64]$s.model.bytes) { throw "Downloaded size $($f.Length) does not match authoritative size $($s.model.bytes). Partial file kept." }
    $hash=(Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $s.model.sha256) { throw "Downloaded model checksum mismatch. Expected $($s.model.sha256), got $hash. Partial file kept for diagnosis." }
    Move-Item -LiteralPath $partial -Destination $final -Force
    $completed=Get-Item -LiteralPath $final
    Write-JsonAtomic "$final.ready.json" ([ordered]@{sha256=$hash;bytes=$completed.Length;lastWriteUtc=$completed.LastWriteTimeUtc.ToString('o');repository=$s.model.repository;revision=$s.model.revision;verifiedUtc=(Get-Date).ToUniversalTime().ToString('o')})
}
function Build-Image([string]$Commit, [switch]$Force) {
    $tag="$($script:ImageRepository):$($Commit.Substring(0,12))"
    $existing=Invoke-Process docker @('image','inspect',$tag,'--format','{{index .Config.Labels "com.ninfer-manager.commit"}}') -AllowFailure
    if (-not $Force -and $existing.ExitCode -eq 0 -and $existing.StdOut.Trim() -eq $Commit) { Write-Log INFO "Reusing image $tag"; return $tag }
    $upstreamDockerfile=Join-Path $script:Source 'Dockerfile'
    $dockerText=Get-Content -LiteralPath $upstreamDockerfile -Raw -Encoding utf8
    $dockerfile=$upstreamDockerfile
    # HEAD currently asks nvcc for C++23 but its checked-in CUDA 13.1 image rejects -std=c++23.
    # Upstream's README validates CUDA 13.3, so derive only this exact, auditable base-image repair.
    if($dockerText.Contains('nvidia/cuda:13.1.2-devel-ubuntu24.04') -and $dockerText.Contains('nvidia/cuda:13.1.2-runtime-ubuntu24.04')){
        $derived=$dockerText.Replace('nvidia/cuda:13.1.2-devel-ubuntu24.04',"nvidia/cuda:$($script:CudaImageVersion)-devel-$($script:CudaUbuntu)").Replace('nvidia/cuda:13.1.2-runtime-ubuntu24.04',"nvidia/cuda:$($script:CudaImageVersion)-runtime-$($script:CudaUbuntu)")
        # Keep runtime package names release-independent; the -dev packages pull the matching shared libraries.
        $derived=$derived.Replace('libavcodec60','libavcodec-dev').Replace('libavformat60','libavformat-dev').Replace('libavutil58','libavutil-dev').Replace('libcurl4t64','libcurl4-openssl-dev').Replace('libswscale7','libswscale-dev')
        $dockerfile=Join-Path $script:Temp "Dockerfile.$($Commit.Substring(0,12)).cuda-$($script:CudaImageVersion)"
        [IO.File]::WriteAllText($dockerfile,$derived,[Text.UTF8Encoding]::new($false))
        Write-Log WARN "Upstream Dockerfile pins CUDA 13.1.2, whose nvcc rejects the source's required C++23 mode. Building the unchanged source with upstream-validated CUDA $($script:CudaImageVersion)."
    } elseif($dockerText -notmatch 'nvidia/cuda:13\.3\.[0-9]+-devel-ubuntu26\.04') {
        throw 'Upstream Dockerfile uses an unrecognized CUDA base. Refusing to rewrite it automatically.'
    }
    Write-Host "Building immutable image $tag. This can take a long time on the first run."
    Invoke-Process docker @('build','--progress','plain','--pull','--file',$dockerfile,'--label',"com.ninfer-manager.owner=$script:ManagerId",'--label',"com.ninfer-manager.commit=$Commit",'--label',"com.ninfer-manager.cuda=$($script:CudaImageVersion)",'--tag',$tag,$script:Source) -Live | Out-Null
    $verify=Invoke-Process docker @('run','--rm','--gpus','all',$tag,'ninfer-serve','--help') -AllowFailure -TimeoutSeconds 60
    foreach($flag in @('--max-context','--kv-stream','--host-kv-mib','--fixed-draft','--lm-head-draft','--api-key')) { if(($verify.StdOut+$verify.StdErr) -notmatch [regex]::Escape($flag)){throw "Built server does not support mandatory flag $flag at commit $Commit."} }
    return $tag
}
function Get-ServeArguments($Settings, [string]$ApiKey) {
    $r=$Settings.runtime; $m=$Settings.model
    $a=@('ninfer-serve',('/models/'+$m.artifact),'--model-id',[string]$m.modelId,'--host','0.0.0.0','--port','8080','--api-key',$ApiKey,
        '--max-context',[string]$r.maxContext,'--kv-capacity',[string]$r.kvCapacity,'--max-concurrency',[string]$r.maxConcurrency,
        '--kv-dtype',[string]$r.kvDtype,'--spec',[string]$r.spec,'--draft-tokens',[string]$r.draftTokens)
    if ($r.kvStream) {$a+='--kv-stream'}; if ([int]$r.hostKvMiB -gt 0) {$a+=@('--host-kv-mib',[string]$r.hostKvMiB)}
    if ([int]$r.hostCacheMiB -gt 0) {$a+=@('--host-cache-mib',[string]$r.hostCacheMiB)}
    if ($r.fixedDraft) {$a+='--fixed-draft'}; if ($r.lmHeadDraft) {$a+='--lm-head-draft'}
    return ,$a
}
function Get-SanitizedInvocation($Args) {
    $copy=[Collections.Generic.List[string]]::new(); for($i=0;$i -lt $Args.Count;$i++){ if($i -gt 0 -and $Args[$i-1] -eq '--api-key'){$copy.Add('<redacted>')}else{$copy.Add([string]$Args[$i])} }
    return ($copy -join ' ')
}
function Remove-OwnedContainer {
    $info=Get-ContainerInfo; if(-not $info){return}; Assert-OwnedContainer $info
    Invoke-Process docker @('rm','--force',$script:ContainerName) | Out-Null
}
function Start-Container([string]$Image, [string]$Commit, [switch]$Replace) {
    $s=Get-Settings; $secret=Get-Secrets; $hash=Get-ConfigHash $s; $existing=Get-ContainerInfo
    if($existing){ Assert-OwnedContainer $existing; $same=($existing.Config.Image -eq $Image -and $existing.Config.Labels.'com.ninfer-manager.config-sha256' -eq $hash)
        if($same -and -not $Replace){ if(-not $existing.State.Running){Invoke-Process docker @('start',$script:ContainerName)|Out-Null}; return }
        Remove-OwnedContainer
    }
    if(-not (Test-PortAvailable ([int]$s.network.port))){throw "Port $($s.network.port) is already in use. Change it in Network Settings or stop the conflicting service."}
    $bind=if($s.network.lanEnabled){'0.0.0.0'}else{'127.0.0.1'}
    $mount="$($script:Models):/models:ro"; $serve=Get-ServeArguments $s $secret.apiKey
    $dockerArgs=@('run','--detach','--name',$script:ContainerName,'--gpus','all','--restart',[string]$s.network.restartPolicy,
        '--label',"com.ninfer-manager.owner=$script:ManagerId",'--label',"com.ninfer-manager.commit=$Commit",'--label',"com.ninfer-manager.config-sha256=$hash",'--label',"com.ninfer-manager.image=$Image",
        '--publish',"${bind}:$($s.network.port):8080",'--mount',"type=bind,source=$($script:Models),target=/models,readonly",$Image)+$serve
    Write-Host ('Launch: docker ' + (Get-SanitizedInvocation $dockerArgs))
    Invoke-Process docker $dockerArgs | Out-Null
}
function Invoke-Api([string]$Path, [string]$Method='GET', $Body=$null, [int]$Timeout=30) {
    $s=Get-Settings; $key=(Get-Secrets).apiKey; $headers=@{Authorization="Bearer $key"}
    $params=@{Uri="http://127.0.0.1:$($s.network.port)$Path";Method=$Method;Headers=$headers;TimeoutSec=$Timeout;UseBasicParsing=$true}
    if($null -ne $Body){$params.ContentType='application/json';$params.Body=($Body|ConvertTo-Json -Depth 10 -Compress)}
    return Invoke-RestMethod @params
}
function Wait-Healthy([int]$TimeoutSeconds=1200) {
    $s=Get-Settings; $end=(Get-Date).AddSeconds($TimeoutSeconds); $last=''
    while((Get-Date)-lt$end){
        $info=Get-ContainerInfo; if(-not $info -or -not $info.State.Running){$logs=(Invoke-Process docker @('logs','--tail','100',$script:ContainerName) -AllowFailure).StdErr;throw "Container stopped during startup. $logs"}
        try{$h=Invoke-RestMethod -Uri "http://127.0.0.1:$($s.network.port)/health" -TimeoutSec 5;if($h.status -eq 'ok'){return}}catch{$last=$_.Exception.Message}
        Write-Host -NoNewline '.'; Start-Sleep -Seconds 5
    }
    throw "Server did not become healthy within $TimeoutSeconds seconds. Last HTTP error: $last"
}
function Test-LiveInvocation([switch]$Detailed) {
    $s=Get-Settings; $info=Get-ContainerInfo; $results=[ordered]@{}
    if(-not $info){foreach($n in @('max-context','kv-capacity','max-concurrency','kv-dtype','kv-stream','host-kv-mib','spec','draft-tokens','fixed-draft','lm-head-draft')){$results[$n]=$false};return $results}
    $args=@($info.Args); $pairs=[ordered]@{'max-context'='262144';'kv-capacity'='auto';'max-concurrency'='1';'kv-dtype'='fp8';'host-kv-mib'=[string]$s.runtime.hostKvMiB;'spec'='mtp';'draft-tokens'='5'}
    foreach($k in $pairs.Keys){$i=[array]::IndexOf($args,"--$k");$results[$k]=($i-ge 0-and $i+1-lt$args.Count-and [string]$args[$i+1]-eq$pairs[$k])}
    foreach($k in @('kv-stream','fixed-draft','lm-head-draft')){$results[$k]=($args -contains "--$k")}
    if($Detailed){foreach($k in $results.Keys){Write-Color ("{0,-20} {1}" -f "--$k",$(if($results[$k]){'PASS'}else{'FAIL'})) $(if($results[$k]){'Green'}else{'Red'})}}
    return $results
}
function Test-LiveConfiguredInvocation {
    $s=Get-Settings;$info=Get-ContainerInfo;$results=[Collections.Generic.List[string]]::new()
    if(-not$info){$results.Add('container missing');return ,$results};$args=@($info.Args);$r=$s.runtime
    $pairs=[ordered]@{'max-context'=[string]$r.maxContext;'kv-capacity'=[string]$r.kvCapacity;'max-concurrency'=[string]$r.maxConcurrency;'kv-dtype'=[string]$r.kvDtype;'spec'=[string]$r.spec;'draft-tokens'=[string]$r.draftTokens}
    if([int]$r.hostKvMiB-gt0){$pairs['host-kv-mib']=[string]$r.hostKvMiB};if([int]$r.hostCacheMiB-gt0){$pairs['host-cache-mib']=[string]$r.hostCacheMiB}
    foreach($k in $pairs.Keys){$i=[array]::IndexOf($args,"--$k");if($i-lt0-or$i+1-ge$args.Count-or[string]$args[$i+1]-ne$pairs[$k]){$results.Add("--$k")}}
    foreach($item in @(@('kv-stream',[bool]$r.kvStream),@('fixed-draft',[bool]$r.fixedDraft),@('lm-head-draft',[bool]$r.lmHeadDraft))){$present=$args-contains("--$($item[0])");if($present-ne$item[1]){$results.Add("--$($item[0])")}}
    return ,$results
}
function Test-ApiSmoke {
    $s=Get-Settings; $models=Invoke-Api '/v1/models'; if(-not $models.data){throw 'Authenticated /v1/models returned no model.'}
    $body=@{model=$s.model.modelId;messages=@(@{role='user';content='Reply with exactly: READY'});max_tokens=8;temperature=0}
    $reply=Invoke-Api '/v1/chat/completions' 'POST' $body 180
    if(-not $reply.choices){throw 'Authenticated inference smoke test returned no choices.'}
    return $models.data[0]
}
function Complete-Start([string]$Image,[string]$Commit,[switch]$Replace) {
    Start-Container $Image $Commit -Replace:$Replace; Write-Host 'Waiting for model load' -NoNewline; Wait-Healthy; Write-Host
    $live=Get-ContainerInfo;if($live.Config.Labels.'com.ninfer-manager.commit'-ne$Commit){throw 'Running container commit label does not match the selected source revision.'}
    $mismatch=Test-LiveConfiguredInvocation;if($mismatch.Count){throw "Running process does not match configured flags: $($mismatch -join ', ')."}
    $model=Test-ApiSmoke; $d=Get-Deployment; $d.activeCommit=$Commit;$d.lastBuiltCommit=$Commit;$d.lastKnownGoodImage=$Image;$d.modelRevision=(Get-Settings).model.revision;$d.configHash=Get-ConfigHash(Get-Settings);Write-JsonAtomic $script:DeploymentPath $d
    Show-Endpoints; Write-Color "Operational: authenticated inference succeeded; configured context $($model.max_model_len)." Green
}
function Show-Endpoints {
    $s=Get-Settings; Write-Host "Local API: http://127.0.0.1:$($s.network.port)/v1"
    if($s.network.lanEnabled){$ips=Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue|Where-Object{$_.IPAddress-notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias-notmatch 'vEthernet|Loopback|VPN|Tailscale'}|Select-Object -ExpandProperty IPAddress
        foreach($ip in $ips){Write-Host "LAN API:   http://${ip}:$($s.network.port)/v1"}}
    Write-Host "Model:     $($s.model.modelId)"; Write-Host 'Auth:      Authorization: Bearer <key from ShowKey>'
    Write-Host "Hermes/OpenAI base URL: http://127.0.0.1:$($s.network.port)/v1 (use the model and bearer key shown by this manager)."
    Write-Host "Anthropic Messages URL: http://127.0.0.1:$($s.network.port)/v1/messages (x-api-key is also accepted)."
}
function Invoke-Install {
    $pre=Test-Prerequisites -ForInstall -GpuSmoke; if(-not $pre.Ok){$pre.Issues|ForEach-Object{Write-Log ERROR $_};Invoke-PrerequisiteRepair;throw 'Prerequisite validation failed; no model download was started. Re-run after completing the guidance above.'}
    $profile=Assert-DefaultProfile(Get-Settings);if($profile.Count){Write-Log WARN "Explicit nondefault performance profile active; default requirements changed: $($profile -join ', ')."}
    $configured=Get-Settings;if([int]$configured.runtime.maxContext-gt[int]$configured.model.maxPositionEmbeddings){throw "Requested context $($configured.runtime.maxContext) exceeds verified model max_position_embeddings $($configured.model.maxPositionEmbeddings). No silent reduction will be made."}
    $remote=Get-RemoteHead;if(-not$remote){throw 'GitHub is unreachable and no source commit can be verified for a fresh install.'}
    Install-Model;Sync-Source $remote.Sha;$image=Build-Image $remote.Sha;Complete-Start $image $remote.Sha -Replace
}
function Invoke-Start {
    $d=Get-Deployment;if(-not$d.lastKnownGoodImage){Invoke-Install;return};if(-not(Test-Model)){Install-Model}
    Complete-Start $d.lastKnownGoodImage $d.activeCommit
}
function Invoke-Stop { $i=Get-ContainerInfo;if($i){Assert-OwnedContainer $i;Invoke-Process docker @('stop',$script:ContainerName)|Out-Null;Write-Log INFO 'NInfer-Ext stopped.'}else{Write-Host 'Managed container does not exist.'} }
function Invoke-Update([switch]$ForceBuild) {
    $d=Get-Deployment;$remote=Get-RemoteHead;if(-not$remote){throw 'GitHub could not be reached. The existing deployment was left untouched.'}
    if(-not$ForceBuild-and$d.activeCommit-eq$remote.Sha){Write-Host 'Installed source is current; no rebuild needed.';return}
    if(-not$ForceBuild-and-not(Confirm-Choice "Build and deploy upstream $($remote.Sha.Substring(0,12))?")){Write-Host 'Update declined.';return}
    $oldImage=$d.lastKnownGoodImage;$oldCommit=$d.activeCommit
    Sync-Source $remote.Sha;$newImage=Build-Image $remote.Sha -Force:$ForceBuild
    try{Complete-Start $newImage $remote.Sha -Replace;Write-Color 'Update validated and committed.' Green}
    catch{Write-Log ERROR "New deployment failed: $($_.Exception.Message)";Write-Log WARN 'Rolling back to the last known-good image.';Remove-OwnedContainer
        if($oldImage){try{Complete-Start $oldImage $oldCommit -Replace;Write-Color 'Rollback succeeded.' Yellow}catch{throw "Update failed and rollback also failed: $($_.Exception.Message)"}}
        throw 'Update failed; the previous deployment was restored.'}
}
function Invoke-CheckUpdates {
    $d=Get-Deployment;$container=Get-ContainerInfo;if($container){try{Assert-OwnedContainer $container;if($container.Config.Labels.'com.ninfer-manager.commit'){$d.activeCommit=$container.Config.Labels.'com.ninfer-manager.commit'}}catch{}}
    $remote=Get-RemoteHead;if(-not$remote){Write-Log WARN 'GitHub unavailable; the existing installation can still run.';return}
    Write-Host "Installed SHA: $($d.activeCommit)";Write-Host "Remote SHA:    $($remote.Sha)"
    if(-not$d.activeCommit){Write-Host 'No deployed commit is recorded. Run Install.';return}
    if($d.activeCommit-eq$remote.Sha){Write-Color 'Up to date.' Green;return}
    if(Test-Path(Join-Path $script:Source '.git')){Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'fetch','origin') -AllowFailure|Out-Null
        $anc=Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'merge-base','--is-ancestor',$d.activeCommit,$remote.Sha) -AllowFailure
        if($anc.ExitCode-eq 0){$count=(Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'rev-list','--count',"$($d.activeCommit)..$($remote.Sha)")).StdOut;Write-Color "Update available: $count new commit(s)." Yellow
            Invoke-Process git @('-c',"safe.directory=$($script:Source.Replace('\','/'))",'-C',$script:Source,'log','--oneline','--no-decorate',"$($d.activeCommit)..$($remote.Sha)",'--max-count=12') -AllowFailure -Live|Out-Null}
        else{Write-Log WARN 'Remote HEAD differs but is not a descendant of the deployed commit (history may have diverged). Review before updating.'}}
}
function Show-Status {
    $h=Get-Hardware;$s=Get-Settings;$d=Get-Deployment;$i=Get-ContainerInfo;$running=$false;$healthy=$false
    if($i){try{Assert-OwnedContainer $i;$running=[bool]$i.State.Running}catch{}}
    if($running){try{$x=Invoke-RestMethod -Uri "http://127.0.0.1:$($s.network.port)/health" -TimeoutSec 3;$healthy=$x.status-eq'ok'}catch{}}
    Write-Host ('='*50);Write-Color '               NINFER-EXT MANAGER' Cyan;Write-Host ('='*50)
    Write-Host ("GPU:          {0} ({1:N1} GiB)" -f $h.GPU,($h.VramMiB/1024));Write-Host ("System RAM:   {0:N1} GiB ({1:N1} GiB available)" -f ($h.TotalRamMiB/1024),($h.AvailableRamMiB/1024))
    Write-Host "Model:        $($s.model.modelId)";Write-Host "Context:      $($s.runtime.maxContext) configured; $($d.empiricallyValidatedContext) empirically validated"
    Write-Host "Container:    $(if($running){'RUNNING'}elseif($i){'STOPPED'}else{'NOT INSTALLED'})";Write-Host "API:          $(if($healthy){'HEALTHY'}else{'NOT VERIFIED'})";Write-Host "Source SHA:   $($d.activeCommit)"
    if($healthy){Show-Endpoints};Write-Host ('-'*50)
}
function Invoke-Diagnostics {
    Show-Status;$s=Get-Settings;$pre=Test-Prerequisites
    foreach($x in $pre.Issues){Write-Color "FAIL prerequisite: $x" Red};if($pre.Ok){Write-Color 'PASS prerequisites (GPU container smoke test not rerun)' Green}
    Write-Host 'Mandatory live flags:';[void](Test-LiveInvocation -Detailed)
    $model=Test-Model -Quiet;Write-Color "$(if($model){'PASS'}else{'FAIL'}) model size and verified checksum marker" $(if($model){'Green'}else{'Red'})
    $i=Get-ContainerInfo;if($i){Write-Host ('Sanitized live argv: '+(Get-SanitizedInvocation @($i.Args)));Write-Host 'Recent container logs:';Invoke-Process docker @('logs','--tail','80',$script:ContainerName) -AllowFailure -Live|Out-Null}
    $bytesPerToken=($script:ModelDefaults.fullAttentionLayers+$script:ModelDefaults.mtpLayers)*$script:ModelDefaults.kvHeads*$script:ModelDefaults.headDimension*2
    $fullMiB=[math]::Ceiling($s.runtime.maxContext*$bytesPerToken/1MB)
    Write-Host "KV calculation: $bytesPerToken bytes/token; worst-case full-window FP8 KV = $fullMiB MiB before GPU-resident pages; Host KV configured = $($s.runtime.hostKvMiB) MiB."
    Write-Host 'Configured context is not empirical proof. Use StressTest to attempt near-limit admission/generation.'
}
function Set-Performance {
    $s=Get-Settings;Write-Color 'Advanced settings can make the server fail. Blank input keeps the current value.' Yellow
    foreach($pair in @(@('maxContext','Maximum context'),@('hostKvMiB','Host KV MiB'),@('hostCacheMiB','Host cache MiB'),@('maxConcurrency','Concurrency'))){$v=Read-Host "$($pair[1]) [$($s.runtime.($pair[0]))]";if($v){$s.runtime.($pair[0])=[int]$v}}
    $dtype=Read-Host "KV dtype [$($s.runtime.kvDtype)]";if($dtype){if($dtype-notin@('bf16','int8','fp8','nvfp4','k8v4')){throw'Invalid KV dtype'};$s.runtime.kvDtype=$dtype}
    if([int]$s.runtime.hostCacheMiB-gt0-and[int]$s.runtime.hostKvMiB-gt0){throw '--host-cache-mib and --host-kv-mib are mutually exclusive upstream. Set one to 0.'}
    Write-JsonAtomic $script:SettingsPath $s;Write-Host 'Saved. Restart recreates the container; no image rebuild is needed.'
}
function Set-Network {
    $s=Get-Settings;$p=Read-Host "Port [$($s.network.port)]";if($p){$n=[int]$p;if($n-lt1-or$n-gt65535){throw'Invalid port'};$s.network.port=$n}
    $lan=Read-Host "Enable authenticated LAN binding? [$($s.network.lanEnabled)] (yes/no)";if($lan){$s.network.lanEnabled=$lan-match'^(y|yes|true)$'}
    Write-JsonAtomic $script:SettingsPath $s;Write-Host 'Saved. Restart required. LAN firewall access remains closed until Firewall is configured.'
}
function Set-Model {
    Write-Color 'Changing models requires exact authoritative metadata; no silent substitution is performed.' Yellow
    $s=Get-Settings;$repo=Read-Host "Hugging Face repository [$($s.model.repository)]";if($repo){$s.model.repository=$repo}
    $artifact=Read-Host "Artifact filename [$($s.model.artifact)]";if($artifact){if([IO.Path]::GetFileName($artifact)-ne$artifact){throw'Artifact must be a filename only'};$s.model.artifact=$artifact}
    $rev=Read-Host "Pinned revision SHA [$($s.model.revision)]";if($rev){if($rev-notmatch'^[0-9a-f]{40}$'){throw'Revision must be a 40-character SHA'};$s.model.revision=$rev}
    $bytes=Read-Host "Exact bytes [$($s.model.bytes)]";if($bytes){$s.model.bytes=[int64]$bytes};$sha=Read-Host "SHA-256 [$($s.model.sha256)]";if($sha){if($sha-notmatch'^[0-9a-fA-F]{64}$'){throw'Invalid SHA-256'};$s.model.sha256=$sha.ToLowerInvariant()}
    $id=Read-Host "Public model ID [$($s.model.modelId)]";if($id){$s.model.modelId=$id}
    $maxPos=Read-Host "Verified max_position_embeddings [$($s.model.maxPositionEmbeddings)]";if($maxPos){$s.model.maxPositionEmbeddings=[int]$maxPos}
    $minimum=Read-Host "Minimum compatible runtime commit [$($s.model.minimumRuntimeCommit)]";if($minimum){if($minimum-notmatch'^[0-9a-f]{40}$'){throw'Runtime commit must be a 40-character SHA'};$s.model.minimumRuntimeCommit=$minimum}
    Write-JsonAtomic $script:SettingsPath $s;Write-Host 'Saved. The new artifact will be downloaded and the container recreated on Install.'
}
function Invoke-Firewall {
    $s=Get-Settings;if(-not$s.network.lanEnabled){throw'Enable LAN access in Network Settings first.'}
    $remote=if($TrustedRemoteAddress){$TrustedRemoteAddress}else{Read-Host 'Trusted remote IP or CIDR (example 192.168.1.0/24)'}
    if(-not$remote-or$remote-eq'Any'){throw'A narrow trusted IP/CIDR is required; Any is refused.'}
    if(-not(Confirm-Choice "Create/update Private-profile firewall rule for $remote on TCP $($s.network.port)?")){throw'Firewall change declined.'}
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not$admin){throw'Re-run PowerShell as Administrator for the Firewall action only.'}
    Remove-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $script:FirewallRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $s.network.port -Profile Private -RemoteAddress $remote|Out-Null
    $d=Get-Deployment;$d.firewallRule=$script:FirewallRule;Write-JsonAtomic $script:DeploymentPath $d;Write-Color 'Restricted firewall rule created.' Green
}
function Invoke-StressTest {
    if($StressTokens-lt1000-or$StressTokens-gt261888){throw'StressTokens must be 1000..261888, reserving output tokens within 262144.'}
    Write-Color "This sends approximately $StressTokens simple tokens and may take many minutes and consume substantial RAM." Yellow
    if(-not(Confirm-Choice 'Run the near-limit admission and 8-token generation test?')){return}
    $s=Get-Settings;$text=('a ' * $StressTokens);$body=@{model=$s.model.modelId;messages=@(@{role='user';content=$text});max_tokens=8;temperature=0}
    try{$null=Invoke-Api '/v1/chat/completions' 'POST' $body 3600;$d=Get-Deployment;$d.empiricallyValidatedContext=$StressTokens;$d.lastStressTestUtc=(Get-Date).ToUniversalTime().ToString('o');Write-JsonAtomic $script:DeploymentPath $d;Write-Color "Stress request was admitted and generated output near $StressTokens input words. Exact tokenizer count may differ." Green}
    catch{Write-Log ERROR "Stress test was not admitted/completed: $($_.Exception.Message)";throw}
}
function Invoke-Repair {
    $pre=Test-Prerequisites -GpuSmoke;if(-not$pre.Ok){$pre.Issues|ForEach-Object{Write-Log ERROR $_};throw'Repair cannot continue until prerequisites pass.'}
    if(-not(Test-Model)){Install-Model};$d=Get-Deployment;if(-not$d.lastKnownGoodImage){Invoke-Install}else{Complete-Start $d.lastKnownGoodImage $d.activeCommit -Replace}
}
function Invoke-SelfTest {
    $fail=[Collections.Generic.List[string]]::new();$mem=Get-DefaultHostKvMiB 65536 50000;if($mem-le0-or$mem-ge65536){$fail.Add('RAM budget bounds')}
    $defaults=New-DefaultSettings;if((Assert-DefaultProfile $defaults).Count){$fail.Add('mandatory default profile')}
    $args=Get-ServeArguments $defaults 'secret-test';$required=@('--max-context','262144','--kv-capacity','auto','--max-concurrency','1','--kv-dtype','fp8','--kv-stream','--host-kv-mib','--spec','mtp','--draft-tokens','5','--fixed-draft','--lm-head-draft')
    foreach($x in $required){if($args-notcontains$x){$fail.Add("argv missing $x")}}
    if((Get-SanitizedInvocation $args)-match'secret-test'){$fail.Add('secret redaction')}
    $altered=New-DefaultSettings;$altered.runtime.maxContext=131072;if((Assert-DefaultProfile $altered)-notcontains'--max-context 262144'){$fail.Add('silent context reduction rejection')}
    $tmp=Join-Path $script:Temp "atomic-$PID.json";Write-JsonAtomic $tmp @{unicode='✓';value=7};if((Read-Json $tmp $null).value-ne7){$fail.Add('atomic JSON')};Remove-Item -LiteralPath $tmp -Force
    if($fail.Count){$fail|ForEach-Object{Write-Color "FAIL $_" Red};throw "$($fail.Count) self-test(s) failed."};Write-Color 'PASS internal self-tests: defaults, argv, redaction, budget bounds, atomic state.' Green
}
function Invoke-Uninstall {
    Write-Color 'This removes only labeled manager container/images and its tracked firewall rule. Models are kept.' Yellow
    if(-not(Confirm-Choice 'Continue with uninstall?')){return};Remove-OwnedContainer
    $images=Invoke-Process docker @('images','--filter',"label=com.ninfer-manager.owner=$script:ManagerId",'--format','{{.Repository}}:{{.Tag}}') -AllowFailure
    foreach($img in $images.StdOut -split"`n"){if($img){Invoke-Process docker @('image','rm',$img) -AllowFailure|Out-Null}}
    $d=Get-Deployment;if($d.firewallRule){$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);if($admin){Remove-NetFirewallRule -DisplayName $d.firewallRule -ErrorAction SilentlyContinue}else{Write-Log WARN "Firewall rule '$($d.firewallRule)' remains; remove it from an Administrator PowerShell."}}
    $d.activeCommit='';$d.lastKnownGoodImage='';$d.configHash='';Write-JsonAtomic $script:DeploymentPath $d;Write-Color 'Managed Docker deployment removed. Models, settings, source, logs, and this script were preserved.' Green
}
function Show-Key { $k=(Get-Secrets).apiKey;Write-Host "API key: $k";Write-Host 'Keep this secret. It grants inference access.' }
function Rotate-Key { if(-not(Confirm-Choice 'Rotate the API key? Existing clients will stop authenticating.')){return};$x=Get-Secrets;$x.apiKey=Get-RandomKey;$x.rotatedUtc=(Get-Date).ToUniversalTime().ToString('o');Write-JsonAtomic $script:SecretsPath $x;Protect-SecretsFile;Write-Host 'Key rotated. Restarting is required.' }
function Show-Menu {
    try{Invoke-CheckUpdates}catch{Write-Log WARN "Startup update check failed: $($_.Exception.Message). Existing deployment remains usable."}
    while($true){
        Show-Status
        $menuRows=@(
            @('[1]  Install / Start',        '[10] Performance Settings'),
            @('[2]  Stop',                   '[11] Network Settings'),
            @('[3]  Restart',                '[12] Repair'),
            @('[4]  Check for Updates',      '[13] Show / Rotate Key'),
            @('[5]  Update',                 '[14] Firewall'),
            @('[6]  Rebuild',                '[15] Stress Test'),
            @('[7]  View Logs',              '[16] Reset Defaults'),
            @('[8]  Diagnostics',             '[17] Uninstall'),
            @('[9]  Model Settings',          '[0]  Exit')
        )
        foreach($row in $menuRows){Write-Host ('{0,-31}{1}' -f $row[0],$row[1])}
        $c=Read-Host 'Select an option';try{switch($c){'1'{Invoke-Install};'2'{Invoke-Stop};'3'{Invoke-Stop;Invoke-Start};'4'{Invoke-CheckUpdates};'5'{Invoke-Update};'6'{Invoke-Update -ForceBuild};'7'{Invoke-Process docker @('logs','--tail','300','--follow',$script:ContainerName) -AllowFailure -Live|Out-Null};'8'{Invoke-Diagnostics};'9'{Set-Model};'10'{Set-Performance};'11'{Set-Network};'12'{Invoke-Repair};'13'{Show-Key;if(Confirm-Choice 'Rotate it?'){Rotate-Key}};'14'{Invoke-Firewall};'15'{Invoke-StressTest};'16'{if(Confirm-Choice 'Reset all settings to the mandatory default profile?'){Write-JsonAtomic $script:SettingsPath (New-DefaultSettings)}};'17'{Invoke-Uninstall};'0'{return};default{Write-Color 'Invalid selection.' Yellow}}}catch{Write-Log ERROR $_.Exception.Message};if($c-ne'0'){Read-Host 'Press Enter to continue'|Out-Null}}
}

Assert-PowerShell7
Initialize-State
$mutexName='Global\NInferManager-'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:Root))).Substring(0,16))
$script:Mutex=[Threading.Mutex]::new($false,$mutexName)
if(-not$script:Mutex.WaitOne(0)){Write-Color 'Another instance of NInfer Manager is already running.' Red;exit 20}
try {
    switch($Action){
        'Menu'{Show-Menu};'Install'{Invoke-Install};'Start'{Invoke-Start};'Stop'{Invoke-Stop};'Restart'{Invoke-Stop;Invoke-Start};'Status'{Show-Status};'CheckUpdates'{Invoke-CheckUpdates};'Update'{Invoke-Update};'Rebuild'{Invoke-Update -ForceBuild};
        'Logs'{Invoke-Process docker @('logs','--tail','300',$script:ContainerName) -AllowFailure -Live|Out-Null};'Diagnostics'{Invoke-Diagnostics};'Repair'{Invoke-Repair};'ModelSettings'{Set-Model};'PerformanceSettings'{Set-Performance};'NetworkSettings'{Set-Network};
        'ResetDefaults'{if($Yes-or(Confirm-Choice 'Reset settings to mandatory defaults?')){Write-JsonAtomic $script:SettingsPath (New-DefaultSettings)}};'ShowKey'{Show-Key};'RotateKey'{Rotate-Key};'Firewall'{Invoke-Firewall};'StressTest'{Invoke-StressTest};'SelfTest'{Invoke-SelfTest};'Uninstall'{Invoke-Uninstall}
    }
    exit 0
} catch {
    Write-Log ERROR $_.Exception.Message
    if($Action-eq'Menu'){return}else{exit 1}
} finally {
    if($script:Mutex){try{$script:Mutex.ReleaseMutex()}catch{};$script:Mutex.Dispose()}
}
