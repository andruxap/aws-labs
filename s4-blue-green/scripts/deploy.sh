#!/usr/bin/env bash
# S4 — Blue/Green and rolling deployments.
#
# Builds a launch template, two ASGs (Blue and Green) each behind its own target
# group, and one ALB whose listener default action decides which environment is
# live. Cutover is scripts/cutover.sh; the rolling refresh is scripts/refresh.sh.
#
# The ALB bills ~$0.0225/hr and four t3.micro add ~$0.042/hr. Tear down today.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/../scripts/lib/workload-iam.sh"  # /workload/ path + BuilderBoundary (plan 020)
BUILD="$HERE/build"; mkdir -p "$BUILD"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

LT="lab-s4-lt"
ROLE="lab-s4-ec2-role"
SG="lab-s4-sg"
ALB="lab-s4-alb"
CAPACITY=2

say "account $ACCT / region $REGION"

say "IAM role $ROLE (SSM + CloudWatch agent, as lesson 2.2 asks — no key pair)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --path "$WORKLOAD_PATH" --permissions-boundary "$(workload_boundary_arn)" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
for p in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn "arn:aws:iam::aws:policy/$p"
done
aws iam create-instance-profile --instance-profile-name "$ROLE" --path "$WORKLOAD_PATH" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true
echo "    ready"

VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" --query 'Vpcs[0].VpcId' --output text)"
SUBNET_A="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}a" --query 'Subnets[0].SubnetId' --output text)"
SUBNET_B="$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}b" --query 'Subnets[0].SubnetId' --output text)"

say "security group $SG"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG" --vpc-id "$VPC_ID" \
    --description "S4 blue/green - HTTP 80" --region "$REGION" --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
echo "    $SG_ID"

AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query 'Parameter.Value' --output text)"

# --------------------------------------------------------- launch template ---
# One template, one version per (environment, app version). Versions are the
# unit a rolling refresh moves between — that is the whole point of the feature.
mk_lt_version() {  # $1 environment, $2 app version
  sed -e "s|__ENVIRONMENT__|$1|g" -e "s|__APP_VERSION__|$2|g" \
    "$HERE/user-data/app.sh" > "$BUILD/ud.sh"
  local b64; b64="$(base64 -w0 < "$BUILD/ud.sh")"
  cat > "$BUILD/lt-data.json" <<JSON
{
  "ImageId": "$AMI",
  "InstanceType": "t3.micro",
  "IamInstanceProfile": { "Name": "$ROLE" },
  "SecurityGroupIds": ["$SG_ID"],
  "UserData": "$b64",
  "TagSpecifications": [{ "ResourceType": "instance",
    "Tags": [{"Key":"Lab","Value":"s4"},{"Key":"Env","Value":"$1"},{"Key":"AppVersion","Value":"$2"}] }]
}
JSON
  if ! aws ec2 describe-launch-templates --launch-template-names "$LT" --region "$REGION" >/dev/null 2>&1; then
    aws ec2 create-launch-template --launch-template-name "$LT" \
      --version-description "$1-$2" --launch-template-data "file://$(w "$BUILD/lt-data.json")" \
      --region "$REGION" --query 'LaunchTemplate.LatestVersionNumber' --output text
  else
    aws ec2 create-launch-template-version --launch-template-name "$LT" \
      --version-description "$1-$2" --launch-template-data "file://$(w "$BUILD/lt-data.json")" \
      --region "$REGION" --query 'LaunchTemplateVersion.VersionNumber' --output text
  fi
}
say "launch template $LT"
V_BLUE="$(mk_lt_version BLUE v1.0)"
V_GREEN="$(mk_lt_version GREEN v2.0)"
echo "    v$V_BLUE = BLUE  v1.0"
echo "    v$V_GREEN = GREEN v2.0"

# ------------------------------------------------------------ target groups ---
say "target groups"
mk_tg() {
  local arn
  arn="$(aws elbv2 describe-target-groups --names "s4-$1-tg" --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)" || arn=""
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    arn="$(aws elbv2 create-target-group --name "s4-$1-tg" --protocol HTTP --port 80 \
      --vpc-id "$VPC_ID" --target-type instance --health-check-path /whoami.txt \
      --health-check-interval-seconds 10 --healthy-threshold-count 2 \
      --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text)"
  fi
  echo "$arn"
}
TG_BLUE="$(mk_tg blue)"; TG_GREEN="$(mk_tg green)"
echo "    blue + green (health check /whoami.txt)"

# -------------------------------------------------------------------- ALB ----
say "load balancer $ALB"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB" --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || ALB_ARN=""
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB" --type application --scheme internet-facing \
    --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$SG_ID" --tags "Key=Lab,Value=s4" \
    --region "$REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" --region "$REGION"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)"
LISTENER="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)"
if [ "$LISTENER" = "None" ] || [ -z "$LISTENER" ]; then
  # Blue is live to begin with. The cutover is a single modify-listener call.
  LISTENER="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_BLUE" --region "$REGION" \
    --query 'Listeners[0].ListenerArn' --output text)"
fi
echo "    $ALB_DNS  (default -> blue)"

# ------------------------------------------------------------------ ASGs -----
say "auto scaling groups (desired $CAPACITY each)"
mk_asg() {  # $1 color, $2 lt-version, $3 tg-arn
  local name="lab-s4-$1-asg"
  if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$name" \
      --region "$REGION" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null | grep -q "$name"; then
    echo "    $name exists"; return
  fi
  aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$name" \
    --launch-template "LaunchTemplateName=$LT,Version=$2" \
    --min-size 1 --max-size 4 --desired-capacity "$CAPACITY" \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$3" \
    --health-check-type ELB --health-check-grace-period 120 \
    --tags "Key=Lab,Value=s4,PropagateAtLaunch=true" \
    --region "$REGION"
  echo "    $name created (template v$2)"
}
mk_asg blue "$V_BLUE" "$TG_BLUE"
mk_asg green "$V_GREEN" "$TG_GREEN"

cat > "$HERE/.env.generated" <<ENV
export AWS_REGION=$REGION
export LT=$LT
export V_BLUE=$V_BLUE
export V_GREEN=$V_GREEN
export SG_ID=$SG_ID
export TG_BLUE=$TG_BLUE
export TG_GREEN=$TG_GREEN
export ALB_ARN=$ALB_ARN
export ALB_DNS=$ALB_DNS
export LISTENER=$LISTENER
export VPC_ID=$VPC_ID
ENV

say "waiting for both environments to become healthy"
for i in $(seq 1 40); do
  b="$(aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" --region "$REGION" --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  g="$(aws elbv2 describe-target-health --target-group-arn "$TG_GREEN" --region "$REGION" --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  echo "    t=$((i*15))s healthy: blue=$b/$CAPACITY green=$g/$CAPACITY"
  [ "$b" -ge "$CAPACITY" ] && [ "$g" -ge "$CAPACITY" ] && break
  sleep 15
done

say "Live at http://$ALB_DNS"
curl -s --max-time 10 "http://$ALB_DNS/whoami.txt" || true
