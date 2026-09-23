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
    }
}