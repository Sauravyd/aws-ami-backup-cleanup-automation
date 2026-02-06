pipeline {
  agent any

  options {
    // 🔒 Keep all builds forever
    buildDiscarder(logRotator(numToKeepStr: ''))

    timestamps()
    disableConcurrentBuilds()
    timeout(time: 2, unit: 'HOURS')
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
    string(
      name: 'MAX_PARALLEL_JOBS',
      defaultValue: '5',
      description: 'Max parallel AMI jobs (recommended: 2–5)'
    )
  }

  environment {
    MAX_PARALLEL_JOBS = "${params.MAX_PARALLEL_JOBS}"
  }

  stages {

    stage('Initialize Build Metadata') {
      steps {
        script {
          currentBuild.displayName =
            "#${currentBuild.number} | ${params.ACTION.toUpperCase()} | ${params.MODE} | ${params.REGION}"

          currentBuild.description = """
Action   : ${params.ACTION}
Mode     : ${params.MODE}
Region   : ${params.REGION}
Parallel : ${params.MAX_PARALLEL_JOBS}
Script   : aws_ami_backup_V3_3_parallel_slot_based_stable.sh
""".stripIndent()
        }
      }
    }

    stage('Checkout Code') {
      steps {
        checkout scm
      }
    }

    stage('Validate Environment') {
      steps {
        sh '''
          set -e

          echo "Validating AWS CLI and tools..."
          aws --version
          jq --version

          echo "Verifying AWS identity (IAM Role on Jenkins agent):"
          aws sts get-caller-identity

          echo "Workspace contents:"
          ls -l

          # HARD GUARD: Only V3.3 script is allowed
          if [ ! -f aws_ami_backup_V3_3_parallel_slot_based_stable.sh ]; then
            echo "❌ Required script aws_ami_backup_V3_3_parallel_slot_based_stable.sh not found"
            exit 1
          fi

          chmod +x aws_ami_backup_V3_3_parallel_slot_based_stable.sh aws_ami_cleanup_V2.sh
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
            echo "❌ No matching servers found for REGION=${params.REGION}"
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

Action   : ${params.ACTION}
Mode     : ${params.MODE}
Region   : ${params.REGION}
Parallel : ${params.MAX_PARALLEL_JOBS}

This operation will modify AWS resources.
Do you want to proceed?
"""
      }
    }

    stage('AMI Backup (V3.3 Slot-Based Stable)') {
      when {
        expression { params.ACTION == 'backup' }
      }
      steps {
        sh """
          echo "############################################################"
          echo "### RUNNING aws_ami_backup_V3_3_parallel_slot_based_stable.sh ###"
          echo "############################################################"

          ./aws_ami_backup_V3_3_parallel_slot_based_stable.sh \
            serverlist_filtered.txt \
            ${MODE}
        """
      }
    }

    stage('AMI Cleanup') {
      when {
        expression { params.ACTION == 'cleanup' }
      }
      steps {
        sh """
          echo "############################################################"
          echo "### RUNNING aws_ami_cleanup_V2.sh ###"
          echo "############################################################"

          ./aws_ami_cleanup_V2.sh serverlist_filtered.txt ${MODE}
        """
      }
    }
  }

  post {
    success {
      echo "✅ AMI ${params.ACTION} completed successfully"
    }
    unstable {
      echo "⚠️ AMI ${params.ACTION} completed with partial failures"
    }
    failure {
      echo "❌ AMI ${params.ACTION} failed"
    }
    always {
      cleanWs()
    }
  }
}
