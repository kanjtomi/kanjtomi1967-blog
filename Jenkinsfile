pipeline {
    agent any

    triggers {
        pollSCM('H/5 * * * *')
    }

    environment {
        // Replace with values from `terraform output` after infra is provisioned
        BUCKET_NAME     = 'www.kanjtomi1967.net'
        DIST_ID         = 'E1E2XGWP46PS1T'
        RAG_BUCKET_NAME = 'www.kanjtomi1967.net-rag-index'
        // rag-index uses the AWS Java SDK, which only reads AWS_REGION (not
        // AWS_DEFAULT_REGION, which the aws CLI in the Deploy stage relies on).
        AWS_REGION      = 'ap-northeast-1'
        // Home RHEL k8s learning/staging cluster (see lambda-comments/k8s/ and
        // site-monitor/k8s/) — local network address, not secret.
        RHEL_HOST_IP    = '192.168.0.200'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                // Standard checkout does NOT fetch git submodules (the PaperMod
                // theme lives in themes/PaperMod as a submodule) — fetch explicitly.
                bat 'git submodule update --init --recursive'
            }
        }

        stage('Build') {
            steps {
                bat 'hugo --minify'
            }
        }

        stage('Rebuild RAG Index') {
            steps {
                bat 'mvn -f rag-index\\pom.xml -q package'
                withCredentials([
                    string(credentialsId: 'voyage-api-key', variable: 'VOYAGE_API_KEY'),
                    [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-blog-deploy-creds']
                ]) {
                    bat 'java -jar rag-index\\target\\rag-index.jar'
                }
            }
        }

        stage('Security Scan') {
            steps {
                bat 'if not exist security-reports mkdir security-reports'
                // Trivy's Java analyzer resolves transitive dependency versions by
                // querying remote Maven repos for any pom not already in the local
                // ~/.m2 cache. Done from cold, that's enough rapid-fire requests to
                // Maven Central to get the whole Jenkins host 429-blocked (seen in
                // practice: FATAL error, no report written). Warm the cache first so
                // `--offline-scan` below has everything it needs without touching the
                // network. rag-index is already resolved by the `mvn package` in the
                // previous stage; the other three Lambda modules aren't built by this
                // pipeline otherwise, so resolve them explicitly. catchError here too:
                // a resolve failure should degrade to an incomplete scan, not block deploy.
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat 'mvn -f lambda-comments\\pom.xml -q dependency:resolve'
                }
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat 'mvn -f lambda-rag\\pom.xml -q dependency:resolve'
                }
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat 'mvn -f lambda-photo-upload\\pom.xml -q dependency:resolve'
                }
                // Single Trivy pass covers dependency vulnerabilities (Maven pom.xml
                // across lambda-comments/lambda-rag/lambda-photo-upload/rag-index and
                // npm package-lock.json in mcp-server), IaC misconfigurations
                // (terraform/ and lambda-comments/Dockerfile), and hardcoded secrets.
                // Vendored/build output dirs are skipped as noise, not as a security
                // exception. --offline-scan relies on the ~/.m2 cache warmed above
                // instead of querying Maven Central directly (see comment above).
                // Report-only for now: no --exit-code/--severity gate, so findings
                // never fail the build. To start gating on Critical/High once the
                // report has been reviewed a few times, add
                // `--exit-code 1 --severity CRITICAL,HIGH` (remove the trailing `bat`
                // catchError wrapper below at the same time, since it would otherwise
                // swallow that failure too).
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat '''
                        trivy fs --scanners vuln,misconfig,secret --offline-scan ^
                            --skip-dirs public,themes,hugo-PaperMod,**/target,**/node_modules,**/dist ^
                            --format table --output security-reports\\trivy-report.txt .
                    '''
                }
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat '''
                        trivy fs --scanners vuln,misconfig,secret --offline-scan ^
                            --skip-dirs public,themes,hugo-PaperMod,**/target,**/node_modules,**/dist ^
                            --format json --output security-reports\\trivy-report.json .
                    '''
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'security-reports/**', allowEmptyArchive: true
                }
            }
        }

        stage('Host Security Scan (Windows)') {
            steps {
                // Covers the OS the Jenkins agent itself runs on (pending updates,
                // Defender status, a handful of CIS-inspired baseline checks) —
                // complements the repo-level Trivy scan above, which only looks at
                // source/dependencies/IaC, not the host. Report-only, same as
                // Security Scan: the script always exits 0, and catchError here is
                // belt-and-suspenders in case the script itself can't run at all
                // (e.g. execution policy blocks it).
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    powershell '& "scripts\\security-check-windows.ps1"'
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'security-reports/host-windows-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                   credentialsId: 'aws-blog-deploy-creds']]) {
                    bat "aws s3 sync .\\public s3://%BUCKET_NAME% --delete"
                    bat "aws cloudfront create-invalidation --distribution-id %DIST_ID% --paths \"/*\""
                }
            }
        }

        stage('Deploy Site Monitor (RHEL k8s)') {
            steps {
                // Builds and deploys site-monitor/ (uptime/response-time checker for
                // the blog's public URLs) to the home RHEL k8s learning/staging
                // cluster — same registry-free podman-build -> ctr-import pattern as
                // the manual comments-service replica (lambda-comments/k8s/), but
                // automated here since this component carries no secrets. See
                // site-monitor/README.md for details and the manual equivalent.
                // Report-only in spirit like Security Scan / Host Security Scan
                // above: cluster being unreachable, or this stage failing outright,
                // never blocks the actual blog deploy above.
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    // Belt-and-suspenders alongside the icacls fix below: if ssh/scp
                    // ever hang again for some other reason, fail this stage after 5
                    // minutes instead of stalling the whole build (as happened once
                    // in practice — see the icacls comment).
                    timeout(time: 5, unit: 'MINUTES') {
                        withCredentials([sshUserPrivateKey(credentialsId: 'rhel-host-ssh-key',
                                                            keyFileVariable: 'SSH_KEY',
                                                            usernameVariable: 'SSH_USER')]) {
                            // Windows' OpenSSH client refuses a private key file that's
                            // readable by more than its owner ("bad permissions") — the
                            // temp file this credential binding writes isn't locked down
                            // enough by default. In practice this made `ssh` fail fast
                            // but `scp` hang indefinitely waiting on a fallback prompt
                            // despite -o BatchMode=yes, stalling the build for 27+
                            // minutes until the hung process was killed manually. Strip
                            // inherited ACLs and grant read-only to the Jenkins service
                            // account (LocalSystem, well-known SID S-1-5-18) only.
                            bat 'icacls %SSH_KEY% /inheritance:r /grant:r *S-1-5-18:R'
                            bat '''
                                ssh -i %SSH_KEY% -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes %SSH_USER%@%RHEL_HOST_IP% "rm -rf /opt/site-monitor-src"
                                scp -i %SSH_KEY% -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -r site-monitor %SSH_USER%@%RHEL_HOST_IP%:/opt/site-monitor-src
                            '''
                            bat '''
                                ssh -i %SSH_KEY% -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes %SSH_USER%@%RHEL_HOST_IP% "cd /opt/site-monitor-src && podman build -t site-monitor:local . && rm -f /tmp/site-monitor.tar && podman save site-monitor:local -o /tmp/site-monitor.tar && ctr -n k8s.io images import /tmp/site-monitor.tar && rm -f /tmp/site-monitor.tar && kubectl apply -f k8s/namespace.yaml -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml && kubectl -n blog-staging rollout status deployment/site-monitor --timeout=60s"
                            '''
                        }
                    }
                }
            }
        }
    }
}