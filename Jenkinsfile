pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    choice(
      name: 'ACTION',
      choices: ['backup', 'cleanup'],
      description: 'AMI backup or cleanup'
    )
    choice(
      name: 'MODE',
      choices: ['dry-run', 'run'],
      description: 'Execution mode'
    )
    string(
      name: 'REGION',
      defaultValue: 'us-east-1',
      description: 'AWS Region'
    )
  }

  environment {
    AWS_DEFAULT_REGION = "${params.REGION}"
  }

  stages {

    stage('Checkout Code') {
      steps {
        checkout scm
      }
    }

    stage('Validate Environment') {
      steps {
        sh '''
          aws --version
          python3 --version
          jq --version
          chmod +x aws_ami_backup_V2.sh aws_ami_cleanup_V2.sh
          echo "Workspace contents:"
          ls -l
        '''
      }
    }

    stage('AMI Backup') {
      when {
        expression { params.ACTION == 'backup' }
      }
      steps {
        withAWS(credentials: 'aws-cicd-creds', region: params.REGION) {
          sh """
            ./aws_ami_backup_V2.sh serverlist.txt ${params.MODE}
          """
        }
      }
    }

    stage('AMI Cleanup') {
      when {
        expression { params.ACTION == 'cleanup' }
      }
      steps {
        withAWS(credentials: 'aws-cicd-creds', region: params.REGION) {
          sh """
            ./aws_ami_cleanup_V2.sh ${params.MODE} ${params.REGION}
          """
        }
      }
    }
  }

  post {
    success {
      echo "✅ AMI ${params.ACTION} completed successfully"
    }
    failure {
      echo "❌ AMI ${params.ACTION} failed"
    }
  }
}
