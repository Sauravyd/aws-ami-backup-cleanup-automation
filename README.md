# AWS AMI Backup & Cleanup Automation

## Overview
This project automates:
- AMI creation (backup)
- Retention-based AMI cleanup

Automation is designed with:
- Dry-run safety
- Jenkins CI/CD
- Multi-account readiness
- Audit-friendly logging

## Scripts Used
- aws_ami_backup_V2.sh   → AMI creation
- aws_ami_cleanup_V2.sh  → AMI cleanup

## Configuration
File: ami_config.txt

Format:
AccountId,Region,EC2_InstanceId,RetentionDays,BackupReason

Example:
881892164822,us-east-1,i-0bbc889ced72fd3d4,3,Pre-patch backup

## Jenkins Parameters
- ACTION  → backup | cleanup
- MODE    → dry-run | run
- REGION  → AWS region

## Usage
### Dry-run Backup
ACTION=backup
MODE=dry-run

### Actual Backup
ACTION=backup
MODE=run

### Dry-run Cleanup
ACTION=cleanup
MODE=dry-run

### Actual Cleanup
ACTION=cleanup
MODE=run

## Safety
- No instance reboot
- Only AMIs with tag AutomatedBackup=true are cleaned
- RetentionDays tag controls deletion

## Logs
All logs are stored under:
ami_logs/

## Author
Saurav Yadav

