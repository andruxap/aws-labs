#!/usr/bin/env bash
# S3 — Load-balanced architecture with advanced request routing.
#
# Builds: S3 bucket holding the site code, an instance profile scoped to that
# bucket, Red + Blue instances in two AZs, two target groups, and an ALB with
# PATH-BASED listener rules. Host-based routing is scripts/host-routing.sh.
#
# The ALB bills ~$0.0225/hr from creation. Run scripts/teardown.sh the same day.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
# Retry a command, PRESERVING its stdout. The original version piped every
# attempt to /dev/null, so `x="$(retry 12 aws ec2 run-instances ...)"` came back
# empty while the instance really had launched — a silent duplicate-resource
# trap. Capture the output and replay it instead.
retry() {
  local n=0 max="$1"; shift
  local out
  while :; do
    if out="$("$@" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
    n=$((n+1))
    if [ "$n" -ge "$max" ]; then "$@"; return 1; fi   # last try: let errors show
    sleep 5
  done
}

BUCKET="arr-bucket-${ACCT}-s3lab"
ROLE="lab-s3-arr-role"
SG="lab-s3-alb-sg"
ALB="lab-s3-alb"

say "account $ACCT / region $REGION"

# ------------------------------------------------------------- 1. S3 code ---
say "S3 bucket $BUCKET"
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
fi
# cygpath again: MSYS_NO_PATHCONV=1 leaves /c/... which the Windows CLI cannot open
aws s3 sync "$(w "$HERE/app")" "s3://$BUCKET/" --delete --only-show-errors
echo "    $(aws s3 ls "s3://$BUCKET/" --recursive | wc -l) objects uploaded"

# --------------------------------------------------------------- 2. IAM -----
say "instance profile $ROLE (scoped to this bucket only, not S3FullAccess)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
sed "s|__BUCKET__|$BUCKET|g" "$HERE/policies/bucket-read.json" > "$BUILD/bucket-read.json"
aws iam put-role-policy --role-name "$ROLE" --policy-name S3ArrRead \
  --policy-document "file://$(w "$BUILD/bucket-read.json")"
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true
echo "    ready"

# --------------------------------------------------- 3. Network + SG --------
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" \
  --query 'Vpcs[0].VpcId' --output text)"
SUBNET_A="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}a" \
  --query 'Subnets[0].SubnetId' --output text)"
SUBNET_B="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}b" \
  --query 'Subnets[0].SubnetId' --output text)"
say "default VPC $VPC_ID (subnets $SUBNET_A / $SUBNET_B)"

SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG" --vpc-id "$VPC_ID" \
    --description "S3 lab - ALB and instances, HTTP 80" --region "$REGION" \
    --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
echo "    SG $SG_ID"

# ---------------------------------------------------------- 4. Instances ----
AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query 'Parameter.Value' --output text)"

launch() {  # $1 color, $2 subnet
  local existing name; name="lab-s3-$1"
  existing="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [ "$existing" != "None" ] && [ -n "$existing" ]; then echo "$existing"; return; fi
  sed -e "s|__COLOR__|$1|g" -e "s|__BUCKET__|$BUCKET|g" \
    "$HERE/user-data/color.sh" > "$BUILD/ud-$1.sh"
  # Not the retry helper: it discards stdout, and here stdout IS the instance id.
  # The retry exists because a freshly created instance profile takes a few
  # seconds to become usable by RunInstances.
  local id=""
  for _ in $(seq 1 12); do
    id="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1 \
      --subnet-id "$2" --security-group-ids "$SG_ID" \
      --iam-instance-profile "Name=$ROLE" --associate-public-ip-address \
      --user-data "file://$(w "$BUILD/ud-$1.sh")" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Lab,Value=s3}]" \
      --region "$REGION" --query 'Instances[0].InstanceId' --output text 2>/dev/null)" || id=""
    [ -n "$id" ] && [ "$id" != "None" ] && break
    sleep 5
  done
  echo "$id"
}
say "launching Red (${REGION}a) and Blue (${REGION}b)"
RED="$(launch red "$SUBNET_A")"
BLUE="$(launch blue "$SUBNET_B")"
echo "    red=$RED  blue=$BLUE"
aws ec2 wait instance-running --instance-ids "$RED" "$BLUE" --region "$REGION"

# ------------------------------------------------------- 5. Target groups ---
say "target groups (health check is the colour's own page, not /)"
mk_tg() {  # $1 color
  local arn
  arn="$(aws elbv2 describe-target-groups --names "s3-$1-tg" --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)" || arn=""
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    arn="$(aws elbv2 create-target-group --name "s3-$1-tg" --protocol HTTP --port 80 \
      --vpc-id "$VPC_ID" --target-type instance \
      --health-check-path "/$1/index.html" --health-check-interval-seconds 15 \
      --healthy-threshold-count 2 --region "$REGION" \
      --query 'TargetGroups[0].TargetGroupArn' --output text)"
  fi
  echo "$arn"
}
TG_RED="$(mk_tg red)"
TG_BLUE="$(mk_tg blue)"
aws elbv2 register-targets --target-group-arn "$TG_RED" --targets "Id=$RED" --region "$REGION"
aws elbv2 register-targets --target-group-arn "$TG_BLUE" --targets "Id=$BLUE" --region "$REGION"
echo "    red  -> /red/index.html"
echo "    blue -> /blue/index.html"

# --------------------------------------------------------------- 6. ALB -----
say "application load balancer $ALB"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB" --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || ALB_ARN=""
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB" --type application --scheme internet-facing \
    --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$SG_ID" \
    --tags "Key=Lab,Value=s3" --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi
echo "    provisioning..."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" --region "$REGION"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)"
ALB_ZONE="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$REGION" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)"
echo "    $ALB_DNS"

# ---------------------------------------------- 7. Listener + path rules ----
say "listener :80 with a fixed-response default, then path rules"
LISTENER="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)"
if [ "$LISTENER" = "None" ] || [ -z "$LISTENER" ]; then
  # Default action returns 404 so an unmatched request is unambiguous — the
  # course forwards to a target group by default, which hides rule misses.
  LISTENER="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 --region "$REGION" \
    --default-actions 'Type=fixed-response,FixedResponseConfig={MessageBody="no rule matched",StatusCode=404,ContentType=text/plain}' \
    --query 'Listeners[0].ListenerArn' --output text)"
fi

add_path_rule() {  # $1 color, $2 priority, $3 tg-arn
  aws elbv2 describe-rules --listener-arn "$LISTENER" --region "$REGION" \
    --query "Rules[?Priority=='$2']" --output text | grep -q . && return 0
  aws elbv2 create-rule --listener-arn "$LISTENER" --priority "$2" \
    --conditions "Field=path-pattern,Values=/$1*" \
    --actions "Type=forward,TargetGroupArn=$3" --region "$REGION" >/dev/null
}
add_path_rule red 1 "$TG_RED"
add_path_rule blue 2 "$TG_BLUE"
echo "    /red*  -> red   (priority 1)"
echo "    /blue* -> blue  (priority 2)"

cat > "$HERE/.env.generated" <<ENV
export AWS_REGION=$REGION
export BUCKET=$BUCKET
export VPC_ID=$VPC_ID
export SG_ID=$SG_ID
export RED=$RED
export BLUE=$BLUE
export TG_RED=$TG_RED
export TG_BLUE=$TG_BLUE
export ALB_ARN=$ALB_ARN
export ALB_DNS=$ALB_DNS
export ALB_ZONE=$ALB_ZONE
export LISTENER=$LISTENER
export ZONE_ID=Z01678051OM322HGI9E5G
ENV

say "waiting for targets to pass health checks"
for i in $(seq 1 30); do
  r="$(aws elbv2 describe-target-health --target-group-arn "$TG_RED" --region "$REGION" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
  b="$(aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" --region "$REGION" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
  echo "    t=$((i*15))s red=$r blue=$b"
  [ "$r" = "healthy" ] && [ "$b" = "healthy" ] && break
  sleep 15
done

say "Path-based routing is live"
echo "  http://$ALB_DNS/red/"
echo "  http://$ALB_DNS/blue/"
