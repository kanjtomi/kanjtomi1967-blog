<#
Host-level security spot check for the Windows machine that runs Jenkins
(BlogDeploy). Companion to the repo-level Trivy scan in the Jenkinsfile's
`Security Scan` stage — that stage covers source/dependencies/IaC; this
script covers the OS the Jenkins agent itself runs on. Report-only: every
check is wrapped so one failure (e.g. Defender managed by another product,
or the account running this lacks rights for a given check) degrades to a
WARN/INFO line instead of aborting the rest of the report.

Usage:
    powershell -File scripts\security-check-windows.ps1 [-OutFile <path>]

Default OutFile matches the Trivy report location convention used by the
Jenkins `Security Scan` stage: security-reports\host-windows-report.txt
#>

param(
    [string]$OutFile = "security-reports\host-windows-report.txt"
)

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]

function Write-Section($title) {
    $lines.Add("")
    $lines.Add("=== $title ===")
}

function Write-Line($status, $text) {
    # status: PASS / WARN / INFO
    $lines.Add("[$status] $text")
}

$lines.Add("Windows host security check")
$lines.Add("Host: $env:COMPUTERNAME")
$lines.Add("Run at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")

# --- Pending Windows Updates (missing patches = CVE exposure) ---
Write-Section "Pending Windows Updates"
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $searchResult = $updateSearcher.Search("IsInstalled=0 and IsHidden=0")
    if ($searchResult.Updates.Count -eq 0) {
        Write-Line "PASS" "No pending updates."
    } else {
        Write-Line "WARN" "$($searchResult.Updates.Count) pending update(s):"
        foreach ($u in $searchResult.Updates) {
            $severity = if ($u.MsrcSeverity) { $u.MsrcSeverity } else { "Unspecified" }
            $lines.Add("    - [$severity] $($u.Title)")
        }
    }
} catch {
    Write-Line "INFO" "Could not query Windows Update (service may be disabled, or this account lacks rights): $($_.Exception.Message)"
}

# --- Recently installed hotfixes (visibility into patch cadence) ---
Write-Section "Recently Installed Hotfixes (last 10)"
try {
    $hotfixes = Get-HotFix | Sort-Object -Property InstalledOn -Descending | Select-Object -First 10
    if ($hotfixes) {
        foreach ($h in $hotfixes) {
            $lines.Add("    - $($h.HotFixID) installed $($h.InstalledOn)")
        }
    } else {
        Write-Line "INFO" "Get-HotFix returned no results."
    }
} catch {
    Write-Line "INFO" "Could not read hotfix history: $($_.Exception.Message)"
}

# --- Windows Defender status ---
Write-Section "Windows Defender Status"
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.RealTimeProtectionEnabled) {
        Write-Line "PASS" "Real-time protection enabled."
    } else {
        Write-Line "WARN" "Real-time protection is disabled."
    }
    $sigAgeDays = $mp.AntivirusSignatureAge
    if ($sigAgeDays -ge 4294967295) {
        # Defender reports this sentinel (uint32 max, i.e. -1) when it has no
        # meaningful signature age to report — typically because real-time
        # protection above is already disabled, or another AV product owns
        # the signature updates. Not a real "4 billion days" finding.
        Write-Line "INFO" "Antivirus signature age unavailable (commonly reported when real-time protection is disabled or another AV product is active)."
    } elseif ($sigAgeDays -le 2) {
        Write-Line "PASS" "Antivirus signatures are $sigAgeDays day(s) old."
    } else {
        Write-Line "WARN" "Antivirus signatures are $sigAgeDays day(s) old (stale)."
    }
} catch {
    Write-Line "INFO" "Get-MpComputerStatus unavailable (Defender may be replaced by another AV product, or this account lacks rights): $($_.Exception.Message)"
}

# --- Lightweight baseline checks (CIS-inspired spot checks, not a full CIS-CAT run) ---
Write-Section "Baseline Configuration Spot Checks"

try {
    $profiles = Get-NetFirewallProfile -ErrorAction Stop
    foreach ($p in $profiles) {
        if ($p.Enabled) {
            Write-Line "PASS" "Firewall profile '$($p.Name)' is enabled."
        } else {
            Write-Line "WARN" "Firewall profile '$($p.Name)' is DISABLED."
        }
    }
} catch {
    Write-Line "INFO" "Could not read firewall profile state: $($_.Exception.Message)"
}

try {
    $smb1 = Get-SmbServerConfiguration -ErrorAction Stop
    if ($smb1.EnableSMB1Protocol) {
        Write-Line "WARN" "SMBv1 server protocol is ENABLED (legacy, vulnerable to EternalBlue-class exploits)."
    } else {
        Write-Line "PASS" "SMBv1 server protocol is disabled."
    }
} catch {
    Write-Line "INFO" "Could not read SMB server configuration: $($_.Exception.Message)"
}

try {
    $uac = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop
    if ($uac.EnableLUA -eq 1) {
        Write-Line "PASS" "User Account Control (UAC) is enabled."
    } else {
        Write-Line "WARN" "User Account Control (UAC) is DISABLED."
    }
} catch {
    Write-Line "INFO" "Could not read UAC registry setting: $($_.Exception.Message)"
}

try {
    $rdp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop
    if ($rdp.fDenyTSConnections -eq 1) {
        Write-Line "PASS" "Remote Desktop is disabled."
    } else {
        try {
            $nla = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction Stop
            if ($nla.UserAuthentication -eq 1) {
                Write-Line "PASS" "Remote Desktop is enabled with Network Level Authentication (NLA) required."
            } else {
                Write-Line "WARN" "Remote Desktop is enabled WITHOUT Network Level Authentication (NLA)."
            }
        } catch {
            Write-Line "INFO" "Remote Desktop is enabled; could not confirm NLA setting: $($_.Exception.Message)"
        }
    }
} catch {
    Write-Line "INFO" "Could not read Remote Desktop registry setting: $($_.Exception.Message)"
}

try {
    $wu = Get-Service -Name wuauserv -ErrorAction Stop
    if ($wu.StartType -eq 'Disabled') {
        Write-Line "WARN" "Windows Update service (wuauserv) startup type is Disabled."
    } else {
        Write-Line "PASS" "Windows Update service (wuauserv) startup type is $($wu.StartType)."
    }
} catch {
    Write-Line "INFO" "Could not read Windows Update service state: $($_.Exception.Message)"
}

# --- Write report ---
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$lines | Out-File -FilePath $OutFile -Encoding utf8

$warnCount = ($lines | Where-Object { $_.StartsWith("[WARN]") }).Count
Write-Host "Report written to $OutFile ($warnCount WARN item(s))"

# Always exit 0 — this is a report-only check, same philosophy as the
# Trivy Security Scan stage: findings are surfaced, not build-blocking.
exit 0
