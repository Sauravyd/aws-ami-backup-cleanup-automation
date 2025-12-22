pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 2, unit: 'HOURS')   // 1️⃣ Pipeline timeout
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
          currentBuild.description = "Action=${params.ACTION}, Mode=${params.MODE}, Region=${params.REGION}"
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
            echo "❌ No matching servers found for REGION=${params.REGION}"
            exit 1
          fi
        """
      }
    }

    // 🔐 MANUAL APPROVAL (ONLY FOR RUN MODE + MAIN BRANCH)
    stage('Approval') {
      when {
        allOf {
          expression { params.MODE == 'run' }
          branch 'main'   // 2️⃣ Restrict run mode to main branch
        }
      }
      steps {
