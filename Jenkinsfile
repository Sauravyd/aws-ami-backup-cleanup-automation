pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 2, unit: 'HOURS')
  }

  parameters {
    choice(name: 'ACTION', choices: ['backup', 'cleanup'], description: 'AMI backup or cleanup')
    choice(name: 'MODE', choices: ['dry-run', 'run'], description: 'Execution mode')
    choice(name: 'REGION', choices: ['ALL', 'us-east-1', 'ap-south-1'], description: 'Target AWS region')
    string(name: 'MAX_PARALLEL_JOBS', defaultValue: '5', description: 'Max parallel AMI jobs (2–5)')
  }

  environment {
    MAX_PARALLEL_JOBS = "${params.MAX_PARALLEL_JOBS}"
  }

  stages {

    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Validate Environment') {
      steps {
        sh '''
          set -e
          aws --version
          jq --version

          if [ ! -f aws_ami_backup_V3_2_parallel_slot_based.sh ]; then
            echo "❌ V3.2 script not found"
            exit 1
          fi

          chmod +x aws_ami_backup_V3_2_parallel_slot_based.sh aws_ami_cleanup_V2.sh
        '''
      }
    }

    stage('Prepare Config') {
      steps {
        sh """
          if [ "${params.REGION}" = "ALL" ]; then
            cp serverlist.txt serverlist_filtered.txt
          else
            grep -i ",${params.REGION}," serverlist.txt > serverlist_filtered.txt || true
          fi

          [ -s serverlist_filtered.txt ] || exit 1
        """
      }
    }

    stage('Approval') {
      when { expression { params.MODE == 'run' } }
      steps {
        input message: "Approve AMI ${params.ACTION} execution?"
      }
    }

    stage('AMI Backup (V3.2 Slot-Based)') {
      when { expression { params.ACTION == 'backup' } }
      steps {
        withAWS(credentials: 'aws-cicd-creds') {
          sh '''
            echo "### RUNNING aws_ami_backup_V3_2_parallel_slot_based.sh ###"
            ./aws_ami_backup_V3_2_parallel_slot_based.sh serverlist_filtered.txt ${MODE}
          '''
        }
      }
    }

    stage('AMI Cleanup') {
      when { expression { params.ACTION == 'cleanup' } }
      steps {
        withAWS(credentials: 'aws-cicd-creds') {
          sh "./aws_ami_cleanup_V2.sh serverlist_filtered.txt ${MODE}"
        }
      }
    }
  }

  post {
    always { cleanWs() }
    success { echo "✅ Pipeline completed successfully" }
    unstable { echo "⚠️ Pipeline completed with warnings" }
    failure { echo "❌ Pipeline failed" }
  }
}
