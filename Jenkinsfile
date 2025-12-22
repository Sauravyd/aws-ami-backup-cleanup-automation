pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'ACTION', choices: ['backup', 'cleanup'], description: 'AMI backup or cleanup')
    choice(name: 'MODE', choices: ['dry-run', 'run'], description: 'Execution mode')
    choice(name: 'REGION', choices: ['ALL', 'us-east-1', 'ap-south-1'], description: 'Target region')
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
        '''
      }
    }

    stage('Prepare Config') {
      steps {
        sh '''
          if [ "${REGION}" = "ALL" ]; then
            cp serverlist.txt serverlist_filtered.txt
          else
            grep -i ",${REGION}," serverlist.txt > serverlist_filtered.txt || true
          fi

          echo "Using configuration:"
          cat serverlist_filtered.txt
        '''
      }
    }

    stage('Approval') {
      when { expression { params.MODE == 'run' } }
      steps {
        input message: """
⚠️ MANUAL APPROVAL REQUIRED ⚠️
Action : ${params.ACTION}
Mode   : ${params.MODE}
Region : ${params.REGION}
Proceed?
"""
      }
    }

    stage('AMI Backup') {
      when { expression { params.ACTION == 'backup' } }
      steps {
        withAWS(credentials: 'aws-cicd-creds') {
          sh "./aws_ami_backup_V2.sh serverlist_filtered.txt ${params.MODE}"
        }
      }
    }

    stage('AMI Cleanup') {
      when { expression { params.ACTION == 'cleanup' } }
      steps {
        withAWS(credentials: 'aws-cicd-creds') {
          sh "./aws_ami_cleanup_V2.sh serverlist_filtered.txt ${params.MODE}"
        }
      }
    }
  }

  post {
    success { echo "✅ AMI ${params.ACTION} completed successfully" }
    unstable { echo "⚠️ AMI ${params.ACTION} completed with partial failures" }
    failure { echo "❌ AMI ${params.ACTION} failed" }
  }
}
