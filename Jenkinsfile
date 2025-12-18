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

    // 🔐 APPROVAL GATE (ONLY FOR RUN MODE)
    stage('Approval') {
      when {
        expression { params.MODE == 'run' }
      }
      steps {
        input message: """
        ⚠️ MANUAL APPROVAL REQUIRED ⚠️

        Action : ${params.ACTION}
        Mode   : ${params.MODE}
        Region : ${params.REGION}

        This operation will MODIFY AWS resources.
        Do you want to proceed?
        """
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
