<#
  Turn the aws-vpn-lab Linux on and off from this PC.

    .\aws-vpn-lab\scripts\vm.ps1 status   # state, IPs, VPN tunnel (when running)
    .\aws-vpn-lab\scripts\vm.ps1 start    # start and wait until SSH answers
    .\aws-vpn-lab\scripts\vm.ps1 stop     # stop (compute billing stops; EIP + disk still billed)
    .\aws-vpn-lab\scripts\vm.ps1 ssh      # log in as ubuntu

  Uses the AWS CLI credentials of the current Windows user.
#>
param(
  [Parameter(Mandatory)][ValidateSet('status', 'start', 'stop', 'ssh')][string]$Action
)
$ErrorActionPreference = 'Stop'
$Region = 'ap-northeast-1'
$Key = Join-Path $HOME '.ssh\aws-vpn-lab'
$SshOpts = @('-i', $Key, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=5')

function Get-Lab {
  $json = aws ec2 describe-instances --region $Region `
    --filters 'Name=tag:Name,Values=aws-vpn-lab' 'Name=instance-state-name,Values=pending,running,stopping,stopped' `
    --query 'Reservations[0].Instances[0].{id:InstanceId,state:State.Name,ip:PublicIpAddress,type:InstanceType,sg:SecurityGroups[0].GroupId}' --output json
  $i = $json | ConvertFrom-Json
  if ($null -eq $i) { throw 'aws-vpn-lab instance not found (run terraform apply in aws-vpn-lab\terraform first)' }
  $i
}

function Test-HomeIp($sg) {
  $now = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 5).Trim() + '/32'
  $allowed = aws ec2 describe-security-groups --region $Region --group-ids $sg `
    --query "SecurityGroups[0].IpPermissions[?FromPort==``4500``].IpRanges[].CidrIp" --output text
  if ($allowed -notmatch [regex]::Escape($now)) {
    Write-Warning "Home public IP is now $now, but the security group allows $allowed. Re-run terraform apply with home_cidr=$now, or the VPN and SSH will not connect."
  }
}

$lab = Get-Lab
switch ($Action) {
  'status' {
    "instance : $($lab.id) ($($lab.type))"
    "state    : $($lab.state)"
    "public IP: $($lab.ip)"
    Test-HomeIp $lab.sg
    if ($lab.state -eq 'running') {
      '--- VPN (swanctl --list-sas)'
      ssh @SshOpts "ubuntu@$($lab.ip)" 'sudo swanctl --list-sas 2>/dev/null | grep -e ESTABLISHED -e INSTALLED || echo no tunnel up'  # no inner quotes: PS 5.1 strips them for native exes
    }
  }
  'start' {
    if ($lab.state -ne 'running') {
      aws ec2 start-instances --region $Region --instance-ids $lab.id --query 'StartingInstances[0].CurrentState.Name' --output text
      aws ec2 wait instance-running --region $Region --instance-ids $lab.id
    }
    $lab = Get-Lab
    Test-HomeIp $lab.sg
    Write-Host "running at $($lab.ip); waiting for SSH..."
    for ($n = 0; $n -lt 30; $n++) {
      ssh @SshOpts -o BatchMode=yes "ubuntu@$($lab.ip)" true 2>$null
      if ($LASTEXITCODE -eq 0) { Write-Host 'SSH is up. The Cisco reconnects the VPN by itself within about a minute.'; break }
      Start-Sleep -Seconds 5
    }
  }
  'stop' {
    if ($lab.state -eq 'stopped') { 'already stopped'; break }
    aws ec2 stop-instances --region $Region --instance-ids $lab.id --query 'StoppingInstances[0].CurrentState.Name' --output text
    aws ec2 wait instance-stopped --region $Region --instance-ids $lab.id
    'stopped'
  }
  'ssh' {
    if ($lab.state -ne 'running') { throw "instance is $($lab.state) - run: vm.ps1 start" }
    ssh @SshOpts "ubuntu@$($lab.ip)"
  }
}
