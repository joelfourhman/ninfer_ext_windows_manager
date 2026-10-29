#requires -Version 7.2
# Called through Windows' normal UAC elevation. No credentials are passed.
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$Address,
 [Parameter(Mandatory)][string]$TrustedSubnet,
 [ValidateRange(1,65535)][int]$Port=8443,
 [Parameter(Mandatory)][string]$ResultFile,
 [switch]$Remove
)
$ErrorActionPreference='Stop'
try {
 $null=[Net.IPAddress]::Parse($Address)
 if($Address -in @('0.0.0.0','127.0.0.1')){throw 'A specific LAN address is required.'}
 if($TrustedSubnet -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$'){throw 'Invalid trusted subnet.'}
 $null=[Net.IPAddress]::Parse(($TrustedSubnet -split '/')[0])
 if($TrustedSubnet.Contains('/') -and [int]($TrustedSubnet -split '/')[1] -notin 8..32){throw 'Subnet must use prefix 8..32.'}
 $name='ninfer-manager-https-v2';$owner='ninfer-windows-manager-v2'
 $existing=Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
 if($existing -and $existing.Description -ne $owner){throw 'A firewall rule with this name belongs to another owner.'}
 if($existing){$existing | Remove-NetFirewallRule}
 if(-not $Remove){New-NetFirewallRule -Name $name -DisplayName 'NInfer Windows Manager HTTPS' -Description $owner -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $Address -LocalPort $Port -RemoteAddress $TrustedSubnet -Profile Any | Out-Null}
 @{ok=$true;address=$Address;trustedSubnet=$TrustedSubnet;port=$Port;removed=[bool]$Remove} | ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding utf8
} catch {
 @{ok=$false;error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding utf8
 exit 1
}
