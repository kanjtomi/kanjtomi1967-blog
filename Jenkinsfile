pipeline {
    agent any

    triggers {
        pollSCM('H/5 * * * *')
    }

    environment {
        // Replace with values from `terraform output` after infra is provisioned
        BUCKET_NAME = 'www.kanjtomi1967.net'
        DIST_ID     = 'E1E2XGWP46PS1T'
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