#!/usr/bin/env bash
# Host-level security spot check for the RHEL machine running the k8s
# learning/staging comments-service replica (see lambda-comments/k8s/).
# Companion to the Windows equivalent, scripts/security-check-windows.ps1,
# and to the repo-level Trivy scan in the Jenkinsfile's `Security Scan`
# stage — that stage covers source/dependencies/IaC; this script covers
# the OS the container host itself runs on.
#
# Not wired into Jenkins: Jenkins runs on the Windows machine and has no
# configured access (SSH credential / agent) to this RHEL host today. Run
# this manually (or have the Claude session on this machine run it) after
# pulling the repo. See CLAUDE.md's "Security Scanning (Host-level)"
# section for how to wire this into Jenkins later if that access gets set
# up.
#
# Usage:
#   bash scripts/security-check-rhel.sh [output-file]
#
# Default output file matches the Trivy report location convention used by
# the Jenkins `Security Scan` stage: security-reports/host-rhel-report.txt
# Report-only: every section is best-effort and never aborts the script,
# same philosophy as the Trivy Security Scan stage (findings are
# surfaced, not gating). Exits 0 unless the script itself is misused.

set -u
OUT_FILE="${1:-security-reports/host-rhel-report.txt}"
mkdir -p "$(dirname "$OUT_FILE")"

{
    echo "RHEL host security check"
    echo "Host: $(hostname)"
    echo "OS: $(cat /etc/redhat-release 2>/dev/null || echo unknown)"
    echo "Run at: $(date '+%Y-%m-%d %H:%M:%S %z')"

    echo ""
    echo "=== Pending Security Updates (dnf) ==="
    if command -v dnf >/dev/null 2>&1; then
        sec_updates="$(dnf updateinfo list security 2>&1)"
        sec_count="$(echo "$sec_updates" | grep -cE '^[A-Za-z0-9._-]+-[0-9]' || true)"
        if [ "$sec_count" -eq 0 ] 2>/dev/null; then
            echo "[PASS] No pending security updates."
        else
            echo "[WARN] $sec_count pending security update(s):"
            echo "$sec_updates" | sed 's/^/    /'
        fi
    else
        echo "[INFO] dnf not found — skipping (is this actually a dnf-based RHEL/Fedora/CentOS system?)"
    fi

    echo ""
    echo "=== OS Package Vulnerabilities (trivy rootfs) ==="
    if command -v trivy >/dev/null 2>&1; then
        echo "[INFO] Running: trivy rootfs / --scanners vuln --severity CRITICAL,HIGH,MEDIUM,LOW"
        echo "[INFO] Requires read access to the RPM database; run as root/sudo for a complete result."
        # This host also carries large, unrelated dev workspaces (e.g. Xilinx/Eclipse
        # projects with hundreds of thousands of small files under /home and /work) that
        # aren't OS packages and aren't what this section cares about — walking them blew
        # past trivy's default 5m timeout in practice ("context deadline exceeded", no
        # results at all). Skip them and raise the timeout as a second line of defense.
        trivy rootfs / --scanners vuln --severity CRITICAL,HIGH,MEDIUM,LOW --format table \
            --timeout 15m --skip-dirs /home,/work,/glide 2>&1
    else
        echo "[INFO] trivy not found on this host — skipping. Install: https://trivy.dev/latest/getting-started/installation/"
    fi

    echo ""
    echo "=== Container Images Used by the k8s Staging Replica ==="
    if command -v trivy >/dev/null 2>&1; then
        for img in \
            docker.io/library/maven:3.9-eclipse-temurin-17 \
            docker.io/library/eclipse-temurin:17-jre-alpine
        do
            echo "--- $img ---"
            trivy image --severity CRITICAL,HIGH,MEDIUM,LOW --format table "$img" 2>&1
        done
    else
        echo "[INFO] trivy not found — skipping container image scan."
    fi

    echo ""
    echo "=== CIS Baseline (OpenSCAP, optional/best-effort) ==="
    if command -v oscap >/dev/null 2>&1; then
        ds_file="$(find /usr/share/xml/scap/ssg/content -iname 'ssg-rhel*-ds.xml' 2>/dev/null | sort | tail -1)"
        if [ -n "$ds_file" ]; then
            profile="$(oscap info "$ds_file" 2>/dev/null | grep -i 'cis' | grep -oE 'xccdf_org\.ssgproject\.content_profile_[A-Za-z0-9_]*' | head -1)"
            if [ -n "$profile" ]; then
                echo "[INFO] Evaluating CIS profile '$profile' from $ds_file (this can take several minutes - it's a single-threaded pass over hundreds of rules)..."
                out_dir="$(dirname "$OUT_FILE")"
                report_html="$out_dir/host-rhel-cis-report.html"
                results_xml="$out_dir/host-rhel-cis-results.xml"
                full_log="$out_dir/host-rhel-cis-full.log"
                # A full run prints one Title/Rule/Ident/Result block per rule (hundreds of
                # lines) - capture all of it to full_log rather than truncating, and derive
                # pass/fail counts from that instead of eyeballing a tail. --report's HTML
                # render can itself fail on a result set this large (seen in practice: a
                # libxml2 "growing nodeset hit limit" XSLT error) without that meaning the
                # evaluation failed - --results keeps the raw XML as a fallback either way.
                oscap xccdf eval --profile "$profile" --results "$results_xml" --report "$report_html" "$ds_file" \
                    > "$full_log" 2>&1
                oscap_exit=$?
                pass_count="$(grep -cE '^Result[[:space:]]+pass' "$full_log" || true)"
                fail_count="$(grep -cE '^Result[[:space:]]+fail' "$full_log" || true)"
                echo "[INFO] CIS evaluation finished (oscap exit code $oscap_exit): $pass_count pass, $fail_count fail"
                echo "[INFO] Full rule-by-rule output: $full_log"
                if [ -s "$report_html" ]; then
                    echo "[INFO] HTML report: $report_html"
                else
                    echo "[INFO] HTML report generation failed (see $full_log for the error) — raw XML results: $results_xml"
                fi
            else
                echo "[INFO] No CIS profile found in $ds_file — skipping."
            fi
        else
            echo "[INFO] scap-security-guide content not found. Install: dnf install -y openscap-scanner scap-security-guide"
        fi
    else
        echo "[INFO] oscap not found on this host — skipping. Install: dnf install -y openscap-scanner scap-security-guide"
    fi

} | tee "$OUT_FILE"

echo ""
echo "Report written to $OUT_FILE"
exit 0
