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
                // Single Trivy pass covers dependency vulnerabilities (Maven pom.xml
                // across lambda-comments/lambda-rag/lambda-photo-upload/rag-index and
                // npm package-lock.json in mcp-server), IaC misconfigurations
                // (terraform/ and lambda-comments/Dockerfile), and hardcoded secrets.
                // Vendored/build output dirs are skipped as noise, not as a security
                // exception. Report-only for now: no --exit-code/--severity gate, so
                // findings never fail the build. To start gating on Critical/High once
                // the report has been reviewed a few times, add
                // `--exit-code 1 --severity CRITICAL,HIGH` (remove the trailing `bat`
                // catchError wrapper below at the same time, since it would otherwise
                // swallow that failure too).
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat '''
                        trivy fs --scanners vuln,misconfig,secret ^
                            --skip-dirs public,themes,hugo-PaperMod,**/target,**/node_modules,**/dist ^
                            --format table --output security-reports\\trivy-report.txt .
                    '''
                }
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    bat '''
                        trivy fs --scanners vuln,misconfig,secret ^
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