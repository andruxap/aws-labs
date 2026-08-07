#!/usr/bin/env bash
# S7 step 1 — stand up the "on-premises" server: MySQL + the app that reads it.
set -euo pipefail
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
ROLE="lab-s7-ssm-role"

MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" --query 'Vpcs[0].VpcId' --output text)"
SUBNET_A="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}a" --query 'Subnets[0].SubnetId' --output text)"
SUBNET_B="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}b" --query 'Subnets[0].SubnetId' --output text)"

say "IAM role $ROLE"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true

say "security groups"
mk_sg() {
  local id
  id="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
      --region "$REGION" --query GroupId --output text)"
  fi
  echo "$id"
}
ONPREM_SG="$(mk_sg lab-s7-onprem-sg "on-prem server: HTTP from my IP, MySQL from DMS")"
DMS_SG="$(mk_sg lab-s7-dms-sg "DMS replication instance")"
RDS_SG="$(mk_sg lab-s7-rds-sg "RDS target: 3306 from DMS and the app")"

aws ec2 authorize-security-group-ingress --group-id "$ONPREM_SG" --protocol tcp --port 80 \
  --cidr "$MY_IP/32" --region "$REGION" >/dev/null 2>&1 || true
# DMS reads the source over 3306. Scoped to the DMS security group, not 0.0.0.0/0
# — the course opens this wide, which is the anti-pattern it admits to.
aws ec2 authorize-security-group-ingress --group-id "$ONPREM_SG" --protocol tcp --port 3306 \
  --source-group "$DMS_SG" --region "$REGION" >/dev/null 2>&1 || true
# The app keeps talking to MySQL on localhost pre-cutover and to RDS after.
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" --protocol tcp --port 3306 \
  --source-group "$DMS_SG" --region "$REGION" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" --protocol tcp --port 3306 \
  --source-group "$ONPREM_SG" --region "$REGION" >/dev/null 2>&1 || true
echo "    onprem=$ONPREM_SG dms=$DMS_SG rds=$RDS_SG"

say "launching the on-prem server"
AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query 'Parameter.Value' --output text)"
INST="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=lab-s7-onprem" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [ "$INST" = "None" ] || [ -z "$INST" ]; then
  INST="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1 \
    --subnet-id "$SUBNET_A" --security-group-ids "$ONPREM_SG" \
    --iam-instance-profile "Name=$ROLE" --associate-public-ip-address \
    --user-data "file://$(w "$HERE/user-data/onprem.sh")" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=lab-s7-onprem},{Key=Lab,Value=s7}]" \
    --region "$REGION" --query 'Instances[0].InstanceId' --output text)"
fi
aws ec2 wait instance-running --instance-ids "$INST" --region "$REGION"
read -r PUB PRIV <<< "$(aws ec2 describe-instances --instance-ids "$INST" --region "$REGION" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text)"

cat > "$HERE/.env.generated" <<ENV
export AWS_REGION=$REGION
export VPC_ID=$VPC_ID
export SUBNET_A=$SUBNET_A
export SUBNET_B=$SUBNET_B
export ONPREM_SG=$ONPREM_SG
export DMS_SG=$DMS_SG
export RDS_SG=$RDS_SG
export ONPREM=$INST
export ONPREM_PUB=$PUB
export ONPREM_PRIV=$PRIV
export MY_IP=$MY_IP
ENV

say "waiting for the app (MySQL + Node install takes a few minutes)"
# `|| true` matters: under `set -e`, an assignment whose command substitution
# fails aborts the whole script. Without it this loop exited on the first curl
# that could not connect — which is every iteration until the app is up.
for i in $(seq 1 40); do
  code="$(curl -s -o "$BUILD/.body" -w '%{http_code}' -m 8 "http://$PUB/api" 2>/dev/null || true)"
  echo "    t=$((i*15))s HTTP ${code:-000}"
  [ "$code" = "200" ] && break
  sleep 15
done

say "on-prem is up: http://$PUB   (private $PRIV)"
cat "$BUILD/.body" 2>/dev/null; echo
