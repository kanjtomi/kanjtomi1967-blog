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