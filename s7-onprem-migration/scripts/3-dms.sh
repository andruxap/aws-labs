#!/usr/bin/env bash
# S7 step 3 — AWS DMS: replication instance, source/target endpoints, and a
# full-load migration task. Then validate that what arrived matches what left.
#
# The replication instance bills hourly FROM CREATION, whether or not a task is
# running. It is the thing to delete first at teardown.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

REPL="lab-s7-repl"
TASK="lab-s7-task"

# DMS requires a role named EXACTLY dms-vpc-role before any subnet group can be
# created. The console creates it silently the first time you use DMS; the CLI
# and IaC do not. The error when it is missing is misleading — it says the role
# "is not configured properly" for a role that does not exist at all.
say "dms-vpc-role (prerequisite the console hides)"
if ! aws iam get-role --role-name dms-vpc-role >/dev/null 2>&1; then
  aws iam create-role --role-name dms-vpc-role --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"dms.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name dms-vpc-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole
  sleep 15   # IAM propagation, or the next call fails with the same message
  echo "    created"
else
  echo "    exists"
fi

say "DMS replication subnet group"
aws dms create-replication-subnet-group \
  --replication-subnet-group-identifier lab-s7-repl-subnets \
  --replication-subnet-group-description "S7" \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" --region "$AWS_REGION" >/dev/null 2>&1 || echo "    exists"

# The course specifies dms.t3.micro. That class is no longer orderable —
# describe-orderable-replication-instances lists t3.small as the smallest
# t-family option, so the guide's "free-tier eligible" note is stale.
say "replication instance dms.t3.small (bills hourly from now)"
if ! aws dms describe-replication-instances --region "$AWS_REGION" \
     --filters "Name=replication-instance-id,Values=$REPL" >/dev/null 2>&1; then
  aws dms create-replication-instance \
    --replication-instance-identifier "$REPL" \
    --replication-instance-class dms.t3.small \
    --allocated-storage 20 \
    --replication-subnet-group-identifier lab-s7-repl-subnets \
    --vpc-security-group-ids "$DMS_SG" \
    --no-publicly-accessible \
    --tags Key=Lab,Value=s7 \
    --region "$AWS_REGION" --query 'ReplicationInstance.ReplicationInstanceIdentifier' --output text
fi
for i in $(seq 1 60); do
  st="$(aws dms describe-replication-instances --region "$AWS_REGION" \
    --filters "Name=replication-instance-id,Values=$REPL" \
    --query 'ReplicationInstances[0].ReplicationInstanceStatus' --output text 2>/dev/null || echo creating)"
  echo "    t=$((i*20))s $st"
  [ "$st" = "available" ] && break
  sleep 20
done
REPL_ARN="$(aws dms describe-replication-instances --region "$AWS_REGION" \
  --filters "Name=replication-instance-id,Values=$REPL" \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text)"

say "endpoints"
mk_ep() {  # $1 id, $2 source|target, $3 host, $4 user, $5 pass
  local arn
  arn="$(aws dms describe-endpoints --region "$AWS_REGION" \
    --filters "Name=endpoint-id,Values=$1" --query 'Endpoints[0].EndpointArn' --output text 2>/dev/null)" || arn=""
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    arn="$(aws dms create-endpoint --endpoint-identifier "$1" --endpoint-type "$2" \
      --engine-name mysql --server-name "$3" --port 3306 \
      --username "$4" --password "$5" \
      --tags Key=Lab,Value=s7 --region "$AWS_REGION" \
      --query 'Endpoint.EndpointArn' --output text)"
  fi
  echo "$arn"
}
SRC_ARN="$(mk_ep lab-s7-source source "$ONPREM_PRIV" employee_user StrongPassword123)"
TGT_ARN="$(mk_ep lab-s7-target target "$RDS_HOST" admin "$DB_PASS")"
echo "    source -> $ONPREM_PRIV"
echo "    target -> $RDS_HOST"

say "testing endpoint connections"
for pair in "lab-s7-source|$SRC_ARN" "lab-s7-target|$TGT_ARN"; do
  id="${pair%%|*}"; arn="${pair##*|}"
  aws dms test-connection --replication-instance-arn "$REPL_ARN" --endpoint-arn "$arn" \
    --region "$AWS_REGION" >/dev/null 2>&1 || true
done
for i in $(seq 1 20); do
  out="$(aws dms describe-connections --region "$AWS_REGION" \
    --filters "Name=replication-instance-arn,Values=$REPL_ARN" \
    --query 'Connections[].[EndpointIdentifier,Status]' --output text | tr '\n' ' ')"
  echo "    t=$((i*15))s $out"
  [ "$(echo "$out" | grep -o successful | wc -l)" -ge 2 ] && break
  sleep 15
done

say "migration task (full load: employee_db.employees)"
cat > "$BUILD/table-mappings.json" <<'JSON'
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "select-employee-db",
      "object-locator": { "schema-name": "employee_db", "table-name": "%" },
      "rule-action": "include"
    }
  ]
}
JSON
TASK_ARN="$(aws dms describe-replication-tasks --region "$AWS_REGION" \
  --filters "Name=replication-task-id,Values=$TASK" \
  --query 'ReplicationTasks[0].ReplicationTaskArn' --output text 2>/dev/null)" || TASK_ARN=""
if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  TASK_ARN="$(aws dms create-replication-task --replication-task-identifier "$TASK" \
    --source-endpoint-arn "$SRC_ARN" --target-endpoint-arn "$TGT_ARN" \
    --replication-instance-arn "$REPL_ARN" --migration-type full-load \
    --table-mappings "file://$(w "$BUILD/table-mappings.json")" \
    --tags Key=Lab,Value=s7 --region "$AWS_REGION" \
    --query 'ReplicationTask.ReplicationTaskArn' --output text)"
fi
for i in $(seq 1 20); do
  st="$(aws dms describe-replication-tasks --region "$AWS_REGION" \
    --filters "Name=replication-task-id,Values=$TASK" \
    --query 'ReplicationTasks[0].Status' --output text)"
  echo "    t=$((i*10))s $st"
  [ "$st" = "ready" ] || [ "$st" = "stopped" ] && break
  sleep 10
done

say "starting the migration"
aws dms start-replication-task --replication-task-arn "$TASK_ARN" \
  --start-replication-task-type start-replication --region "$AWS_REGION" \
  --query 'ReplicationTask.Status' --output text 2>/dev/null || \
aws dms start-replication-task --replication-task-arn "$TASK_ARN" \
  --start-replication-task-type reload-target --region "$AWS_REGION" \
  --query 'ReplicationTask.Status' --output text

for i in $(seq 1 40); do
  read -r st pct <<< "$(aws dms describe-replication-tasks --region "$AWS_REGION" \
    --filters "Name=replication-task-id,Values=$TASK" \
    --query 'ReplicationTasks[0].[Status,ReplicationTaskStats.FullLoadProgressPercent]' --output text)"
  echo "    t=$((i*15))s $st ${pct:-0}%"
  [ "$st" = "stopped" ] || [ "$st" = "failed" ] && break
  sleep 15
done

cat >> "$HERE/.env.generated" <<ENV
export REPL_ARN=$REPL_ARN
export SRC_ARN=$SRC_ARN
export TGT_ARN=$TGT_ARN
export TASK_ARN=$TASK_ARN
ENV

say "table statistics"
aws dms describe-table-statistics --replication-task-arn "$TASK_ARN" --region "$AWS_REGION" \
  --query 'TableStatistics[].{Schema:SchemaName,Table:TableName,Rows:FullLoadRows,State:TableState}' --output table
