pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 2, unit: 'HOURS') // Pipeline timeout
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
    choice(
      name: 'REGION',
      choices: ['ALL', 'us-east-1', 'ap-south-1'],
      description: 'Target AWS region'
    )
  }

  stages {

    stage('Checkout Code') {
      steps {
        checkout scm
      }
    }

    stage('Set Build Description') {
      steps {
        script {
          currentBuild.description =
            "Action=${params.ACTION}, Mode=${params.MODE}, Region=${params.REGION}"
        }
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

    stage('Prepare Config') {
      steps {
        sh """
          echo "Selected REGION: ${params.REGION}"

          if [ "${params.REGION}" = "ALL" ]; then
            cp serverlist.txt serverlist_filtered.txt
          else
            grep -i ",${params.REGION}," serverlist.txt > serverlist_filtered.txt || true
          fi

          echo "Filtered server list:"
          cat serverlist_filtered.txt || true

          if [ ! -s serverlist_filtered.txt ]; then
            echo "No matching servers found for REGION=${params.REGION}"
            exit 1
          fi
        """
      }
    }

    stage('Approval') {
      when {
        expression { params.MODE == 'run' }
      }
      steps {
        input message: """
MANUAL APPROVAL REQUIRED

Action : ${params.ACTION}
Mode   : ${params.MODE}
Region : ${params.REGION}

This operation will modify AWS resources.
Do you want to proceed?
"""
      }
    }

    stage('AMI Backup') {
      when {
        expression { params.ACTION == 'backup' }
      }
      steps {
        withAWS(credentials: 'aws-cicd-creds') {
          sh "./aws_ami_backup_V2.sh serverlist_filtered.txt ${params.MODE}"
        }
      }
    }

    stage('AMI Cleanup') {
      when {
        expression { params.ACTION == 'cleanup' }
      }
      steps {
        withAWS(credentials: 'aws-cicd-creds') {
          sh "./aws_ami_cleanup_V2.sh serverlist_filtered.txt ${params.MODE}"
        }
      }
    }
  }

  post {
    success {
      echo "AMI ${params.ACTION} completed successfully"
    }
    unstable {
      echo "AMI ${params.ACTION} completed with partial failures"
    }
    failure {
      echo "AMI ${params.ACTION} failed"
    }
  }
}
