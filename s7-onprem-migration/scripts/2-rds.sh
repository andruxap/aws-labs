#!/usr/bin/env bash
# S7 step 2 — the migration target: RDS MySQL 8.0.
#
# Deliberately NOT publicly accessible. The course sets PubliclyAccessible=yes
# with a wide-open security group "so the EC2 box can reach it" — that is not
# needed. Both the app and DMS live in the same VPC, so private is correct and
# the security group references the source groups rather than a CIDR.
#
# Deletion protection is turned ON on purpose, to walk into the trap the course
# warns about at teardown time.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.generated"
say() { echo ""; echo "==> $*"; }

DB_ID="lab-s7-rds"
DB_PASS="StrongPassword123"

say "DB subnet group"
aws rds create-db-subnet-group --db-subnet-group-name lab-s7-subnets \
  --db-subnet-group-description "S7 migration target" \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" --region "$AWS_REGION" >/dev/null 2>&1 || echo "    exists"

say "RDS MySQL 8.0 db.t3.micro (private, deletion protection ON)"
if ! aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class db.t3.micro \
    --engine mysql --engine-version 8.0 \
    --master-username admin --master-user-password "$DB_PASS" \
    --allocated-storage 20 --storage-type gp2 \
    --db-subnet-group-name lab-s7-subnets \
    --vpc-security-group-ids "$RDS_SG" \
    --no-publicly-accessible \
    --backup-retention-period 0 \
    --deletion-protection \
    --tags Key=Lab,Value=s7 \
    --region "$AWS_REGION" --query 'DBInstance.DBInstanceIdentifier' --output text
else
  echo "    exists"
fi

say "waiting for available (this takes several minutes)"
for i in $(seq 1 60); do
  st="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$AWS_REGION" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo pending)"
  echo "    t=$((i*20))s $st"
  [ "$st" = "available" ] && break
  sleep 20
done

RDS_HOST="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$AWS_REGION" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
cat >> "$HERE/.env.generated" <<ENV
export DB_ID=$DB_ID
export RDS_HOST=$RDS_HOST
export DB_PASS=$DB_PASS
ENV

say "target ready: $RDS_HOST"
