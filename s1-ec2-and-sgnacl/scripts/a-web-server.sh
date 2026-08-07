#!/usr/bin/env bash
# Part A (DCT project 1) — Apache web server on EC2, configured entirely by User Data.
#
# Deviation from the course guide: it says "proceed without a key pair" AND opens
# port 22. That combination is unusable — without a key you cannot SSH. This uses
# SSM Session Manager instead (agent is preinstalled on AL2023) and does not open
# 22 at all, which is also the better security posture.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
NAME="Custom-Apache-Web-Server"
SG="lab-s1a-web-sg"
ROLE="lab-s1-ssm-role"
say() { echo ""; echo "==> $*"; }

MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" \
  --query 'Vpcs[0].VpcId' --output text)"
say "default VPC $VPC_ID / your IP $MY_IP"

say "IAM role $ROLE (SSM only — no key pair, no port 22)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true

say "security group $SG (HTTP 80 from anywhere; no SSH)"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG" --vpc-id "$VPC_ID" \
    --description "S1 part A - public web server" --region "$REGION" --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
echo "    $SG_ID"

say "launching $NAME (AL2023, t3.micro)"
AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query 'Parameter.Value' --output text)"
IID="$(aws ec2 run-instances \
  --image-id "$AMI" --instance-type t3.micro --count 1 \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$ROLE" \
  --associate-public-ip-address \
  --user-data "file://$(cygpath -m "$HERE/user-data/web-server.sh")" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Lab,Value=s1}]" \
  --region "$REGION" --query 'Instances[0].InstanceId' --output text)"
echo "    $IID (ami $AMI)"

aws ec2 wait instance-running --instance-ids "$IID" --region "$REGION"
PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$IID" --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

say "waiting for Apache on http://$PUBLIC_IP"
for i in $(seq 1 30); do
  # MSYS_NO_PATHCONV=1 stops /dev/null resolving, so curl fails writing the body
  # and exits non-zero even on a 200. Under `set -o pipefail` the `|| echo 000`
  # then fired and the output read "200000". Discard the body to a real file.
  code="$(curl -s -o "$BUILD/.body" -w '%{http_code}' --max-time 5 "http://$PUBLIC_IP" 2>/dev/null)"
  code="${code:-000}"
  echo "    t=$((i*10))s HTTP $code"
  [ "$code" = "200" ] && break
  sleep 10
done

cat > "$HERE/.env.generated" <<ENV
export AWS_REGION=$REGION
export A_INSTANCE_ID=$IID
export A_PUBLIC_IP=$PUBLIC_IP
export A_SG_ID=$SG_ID
export SSM_ROLE=$ROLE
export MY_IP=$MY_IP
ENV

say "Part A up: http://$PUBLIC_IP"
