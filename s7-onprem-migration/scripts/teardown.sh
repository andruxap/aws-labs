#!/usr/bin/env bash
# S7 teardown. Two metered services here, both billing hourly from creation:
# the DMS replication instance and the RDS instance. They go first.
#
# Order is dependency-enforced:
#   DMS task -> replication instance -> endpoints -> subnet group
#   RDS: disable deletion protection -> delete (skip final snapshot) -> subnet group
#   then EC2, security groups, IAM.
set -uo pipefail
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/9 DMS replication task"
TASK_ARN="$(aws dms describe-replication-tasks --region "$REGION" \
  --filters "Name=replication-task-id,Values=lab-s7-task" \
  --query 'ReplicationTasks[0].ReplicationTaskArn' --output text 2>/dev/null)" || TASK_ARN=""
if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
  aws dms stop-replication-task --replication-task-arn "$TASK_ARN" --region "$REGION" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    s="$(aws dms describe-replication-tasks --region "$REGION" \
      --filters "Name=replication-task-id,Values=lab-s7-task" \
      --query 'ReplicationTasks[0].Status' --output text 2>/dev/null || echo gone)"
    case "$s" in stopped|failed|ready|gone) break;; esac
    sleep 10
  done
  aws dms delete-replication-task --replication-task-arn "$TASK_ARN" --region "$REGION" >/dev/null 2>&1 && ok "deleted"
  for _ in $(seq 1 20); do
    aws dms describe-replication-tasks --region "$REGION" \
      --filters "Name=replication-task-id,Values=lab-s7-task" >/dev/null 2>&1 || break
    sleep 10
  done
else ok "absent"; fi

say "2/9 DMS replication instance (hourly biller)"
REPL_ARN="$(aws dms describe-replication-instances --region "$REGION" \
  --filters "Name=replication-instance-id,Values=lab-s7-repl" \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text 2>/dev/null)" || REPL_ARN=""
if [ -n "$REPL_ARN" ] && [ "$REPL_ARN" != "None" ]; then
  aws dms delete-replication-instance --replication-instance-arn "$REPL_ARN" --region "$REGION" >/dev/null 2>&1 && ok "deleting"
  for _ in $(seq 1 40); do
    aws dms describe-replication-instances --region "$REGION" \
      --filters "Name=replication-instance-id,Values=lab-s7-repl" >/dev/null 2>&1 || { ok "gone — billing stopped"; break; }
    sleep 15
  done
else ok "absent"; fi

say "3/9 DMS endpoints"
for id in lab-s7-source lab-s7-target; do
  arn="$(aws dms describe-endpoints --region "$REGION" --filters "Name=endpoint-id,Values=$id" \
    --query 'Endpoints[0].EndpointArn' --output text 2>/dev/null)" || continue
  [ -n "$arn" ] && [ "$arn" != "None" ] && \
    aws dms delete-endpoint --endpoint-arn "$arn" --region "$REGION" >/dev/null 2>&1 && ok "$id deleted"
done
aws dms delete-replication-subnet-group --replication-subnet-group-identifier lab-s7-repl-subnets \
  --region "$REGION" >/dev/null 2>&1 && ok "repl subnet group deleted"

say "4/9 RDS — deletion protection first"
if aws rds describe-db-instances --db-instance-identifier lab-s7-rds --region "$REGION" >/dev/null 2>&1; then
  # This is the classic "why is my bill still going" trap: Delete is refused,
  # and in the console the button is simply greyed out with no explanation.
  if ! aws rds delete-db-instance --db-instance-identifier lab-s7-rds \
       --skip-final-snapshot --region "$REGION" >/dev/null 2>&1; then
    ok "delete refused (deletion protection ON) — disabling it"
    aws rds modify-db-instance --db-instance-identifier lab-s7-rds \
      --no-deletion-protection --apply-immediately --region "$REGION" >/dev/null
    sleep 20
  fi
  # --skip-final-snapshot matters: a kept final snapshot outlives the instance
  # and keeps billing for storage.
  aws rds delete-db-instance --db-instance-identifier lab-s7-rds \
    --skip-final-snapshot --delete-automated-backups --region "$REGION" >/dev/null 2>&1 && ok "deleting"
  for _ in $(seq 1 60); do
    aws rds describe-db-instances --db-instance-identifier lab-s7-rds --region "$REGION" >/dev/null 2>&1 \
      || { ok "gone — billing stopped"; break; }
    sleep 15
  done
else ok "absent"; fi

say "5/9 RDS subnet group"
for _ in $(seq 1 10); do
  aws rds delete-db-subnet-group --db-subnet-group-name lab-s7-subnets --region "$REGION" 2>/dev/null \
    && { ok "deleted"; break; }
  sleep 10
done

say "6/9 snapshots (these outlive the instance and keep billing)"
SNAPS="$(aws rds describe-db-snapshots --region "$REGION" \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier,'lab-s7')].DBSnapshotIdentifier" --output text)"
if [ -n "$SNAPS" ]; then
  for s in $SNAPS; do aws rds delete-db-snapshot --db-snapshot-identifier "$s" --region "$REGION" >/dev/null && ok "$s deleted"; done
else ok "none"; fi

say "7/9 EC2"
IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Lab,Values=s7" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS --region "$REGION" >/dev/null && ok "terminating $IDS"
  aws ec2 wait instance-terminated --instance-ids $IDS --region "$REGION"
  ok "terminated"
else ok "none"; fi

say "8/9 security groups"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" --query 'Vpcs[0].VpcId' --output text)"
for g in lab-s7-onprem-sg lab-s7-dms-sg lab-s7-rds-sg; do
  gid="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$g" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  [ "$gid" = "None" ] && continue
  perms="$(aws ec2 describe-security-groups --group-ids "$gid" --region "$REGION" \
    --query 'SecurityGroups[0].IpPermissions' --output json)"
  [ "$perms" != "[]" ] && aws ec2 revoke-security-group-ingress --group-id "$gid" \
    --ip-permissions "$perms" --region "$REGION" >/dev/null 2>&1
done
for g in lab-s7-onprem-sg lab-s7-dms-sg lab-s7-rds-sg; do
  gid="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$g" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  [ "$gid" = "None" ] && continue
  for _ in $(seq 1 10); do
    aws ec2 delete-security-group --group-id "$gid" --region "$REGION" 2>/dev/null && { ok "$g deleted"; break; }
    sleep 10
  done
done

say "9/9 IAM"
aws iam remove-role-from-instance-profile --instance-profile-name lab-s7-ssm-role --role-name lab-s7-ssm-role 2>/dev/null
aws iam delete-instance-profile --instance-profile-name lab-s7-ssm-role 2>/dev/null && ok "instance profile deleted"
aws iam detach-role-policy --role-name lab-s7-ssm-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name lab-s7-ssm-role 2>/dev/null && ok "role deleted"
# dms-vpc-role is left in place: it is an account-level DMS prerequisite, costs
# nothing, and deleting it only means recreating it next time.
ok "dms-vpc-role kept (account-level prerequisite, no cost)"

say "verify"
echo "  RDS instances:     $(aws rds describe-db-instances --region "$REGION" --query "length(DBInstances[?contains(DBInstanceIdentifier,'lab-s7')])" --output text)"
echo "  RDS snapshots:     $(aws rds describe-db-snapshots --region "$REGION" --query "length(DBSnapshots[?contains(DBSnapshotIdentifier,'lab-s7')])" --output text)"
echo "  DMS instances:     $(aws dms describe-replication-instances --region "$REGION" --query 'length(ReplicationInstances)' --output text 2>/dev/null || echo 0)"
echo "  DMS endpoints:     $(aws dms describe-endpoints --region "$REGION" --query "length(Endpoints[?contains(EndpointIdentifier,'lab-s7')])" --output text 2>/dev/null || echo 0)"
echo "  s7 instances:      $(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Lab,Values=s7" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text)"
echo "  free EBS volumes:  $(aws ec2 describe-volumes --region "$REGION" --query "length(Volumes[?State=='available'])" --output text)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
