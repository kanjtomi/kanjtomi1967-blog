<#
  Push the strongSwan (swanctl) connection for the home Cisco to the aws-vpn-lab Linux.
  Creates the pre-shared key on first run in aws-vpn-lab\secrets\psk.txt (gitignored) and
  reuses it afterwards. Type that same key on the Cisco yourself (see README).
  Safe to re-run.
#>
$ErrorActionPreference = 'Stop'
$LabDir = Split-Path $PSScriptRoot -Parent
$Secrets = Join-Path $LabDir 'secrets'
$PskFile = Join-Path $Secrets 'psk.txt'
$Key = Join-Path $HOME '.ssh\aws-vpn-lab'

if (-not (Test-Path $PskFile)) {
  New-Item -ItemType Directory -Force $Secrets | Out-Null
  $bytes = New-Object byte[] 24
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  # alphanumeric only, so it can be typed on the Cisco without quoting issues
  $psk = ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', '').Substring(0, 28)
  [IO.File]::WriteAllText($PskFile, $psk)
  Write-Host "created $PskFile"
}
$psk = (Get-Content $PskFile -Raw).Trim()

$ip = aws ec2 describe-instances --region ap-northeast-1 `
  --filters 'Name=tag:Name,Values=aws-vpn-lab' 'Name=instance-state-name,Values=running' `
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
if ($ip -eq 'None' -or -not $ip) { throw 'aws-vpn-lab is not running - run vm.ps1 start' }

# IKE identities: the EC2 side presents its Elastic IP (it sits behind AWS 1:1 NAT),
# the Cisco presents its own Gi0/4 address 192.168.0.100 (it sits behind the home router's NAT).
$conf = @"
connections {
  cisco {
    version = 2
    local_addrs = %any
    remote_addrs = %any
    proposals = aes256-sha256-modp2048
    mobike = no
    dpd_delay = 30s
    local {
      auth = psk
      id = $ip
    }
    remote {
      auth = psk
      id = 192.168.0.100
    }
    children {
      vti {
        local_ts = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        if_id_in = 42
        if_id_out = 42
        esp_proposals = aes256-sha256-modp2048
        dpd_action = clear
      }
    }
  }
}
secrets {
  ike-cisco {
    id-1 = 192.168.0.100
    secret = "$psk"
  }
}
"@ -replace "`r", ''

# PS 5.1 prefixes text piped to a native exe with a UTF-8 BOM, which swanctl cannot
# parse (it then silently loads no connection), so strip it on the far side.
$conf | ssh -i $Key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "ubuntu@$ip" `
  'LC_ALL=C sed ''1s/^\xEF\xBB\xBF//'' | sudo install -m 600 /dev/stdin /etc/swanctl/conf.d/cisco.conf && sudo swanctl --load-all --noprompt 2>/dev/null | grep -e loaded -e failed; sudo swanctl --list-conns 2>/dev/null | head -2'
