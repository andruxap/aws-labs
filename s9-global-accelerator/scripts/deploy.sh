#!/usr/bin/env bash
# S9 — Global Accelerator multi-region failover.
#
# The same app in two regions, each with its own VPC + ALB, fronted by AWS
# Global Accelerator as a single anycast entry point. Break one region and
# traffic moves without DNS changing at all — which is the difference between
# this and S8's Route 53 failover.
#
# COST, and this one matters:
#   Global Accelerator  ~$0.025/hr FIXED, whether or not anyone uses it
#   2 x ALB             ~$0.045/hr
#   2 x t3.micro        ~$0.021/hr
#   ~$0.10/hr total. Trivial for an afternoon, ~$70/month if forgotten.
#
# The accelerator is GLOBAL — it appears in no per-region console view, so a
# region sweep will not find it. Teardown deletes it FIRST and confirms.
set -euo pipefail
export MSYS_NO_PATHCONV=1

PRIMARY="${PRIMARY_REGION:-us-east-1}"
SECONDARY="${SECONDARY_REGION:-us-west-2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
NAME="lab-s9"

tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Lab,Value=s9}]"; }

# Build one complete region: VPC, 2 public subnets, IGW, route, SG, EC2, ALB.
# Everything here is regional, so every call carries --region "$1".
build_region() {  # $1 region, $2 cidr, $3 label, $4 colour
  local R="$1" CIDR="$2" LABEL="$3" COLOR="$4"
  local vpc sa sb igw rt sg ami inst alb tg listener

  say "[$R] VPC $CIDR"
  vpc="$(aws ec2 describe-vpcs --region "$R" --filters "Name=tag:Name,Values=$NAME-vpc" \
    --query 'Vpcs[0].VpcId' --output text)"
  if [ "$vpc" = "None" ] || [ -z "$vpc" ]; then
    vpc="$(aws ec2 create-vpc --cidr-block "$CIDR" --region "$R" \
      --tag-specifications "$(tag vpc "$NAME-vpc")" --query 'Vpc.VpcId' --output text)"
    aws ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames --region "$R"
  fi

  sa="$(aws ec2 describe-subnets --region "$R" --filters "Name=vpc-id,Values=$vpc" \
        "Name=tag:Name,Values=$NAME-a" --query 'Subnets[0].SubnetId' --output text)"
  if [ "$sa" = "None" ] || [ -z "$sa" ]; then
    sa="$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "${CIDR%.*.*}.1.0/24" \
      --availability-zone "${R}a" --region "$R" --tag-specifications "$(tag subnet "$NAME-a")" \
      --query 'Subnet.SubnetId' --output text)"
    aws ec2 modify-subnet-attribute --subnet-id "$sa" --map-public-ip-on-launch --region "$R"
  fi
  sb="$(aws ec2 describe-subnets --region "$R" --filters "Name=vpc-id,Values=$vpc" \
        "Name=tag:Name,Values=$NAME-b" --query 'Subnets[0].SubnetId' --output text)"
  if [ "$sb" = "None" ] || [ -z "$sb" ]; then
    sb="$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "${CIDR%.*.*}.2.0/24" \
      --availability-zone "${R}b" --region "$R" --tag-specifications "$(tag subnet "$NAME-b")" \
      --query 'Subnet.SubnetId' --output text)"
    aws ec2 modify-subnet-attribute --subnet-id "$sb" --map-public-ip-on-launch --region "$R"
  fi

  igw="$(aws ec2 describe-internet-gateways --region "$R" \
    --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [ "$igw" = "None" ] || [ -z "$igw" ]; then
    igw="$(aws ec2 create-internet-gateway --region "$R" \
      --tag-specifications "$(tag internet-gateway "$NAME-igw")" \
      --query 'InternetGateway.InternetGatewayId' --output text)"
    aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$R"
  fi
  rt="$(aws ec2 describe-route-tables --region "$R" --filters "Name=vpc-id,Values=$vpc" \
        "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)"
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$igw" --region "$R" >/dev/null 2>&1 || true

  sg="$(aws ec2 describe-security-groups --region "$R" \
    --filters "Name=group-name,Values=$NAME-sg" "Name=vpc-id,Values=$vpc" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ "$sg" = "None" ] || [ -z "$sg" ]; then
    sg="$(aws ec2 create-security-group --group-name "$NAME-sg" --vpc-id "$vpc" \
      --description "S9 - HTTP 80" --region "$R" --query GroupId --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 80 \
      --cidr 0.0.0.0/0 --region "$R" >/dev/null
  fi

  say "[$R] instance ($LABEL)"
  ami="$(aws ssm get-parameter --region "$R" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text)"
  sed -e "s|__REGION__|$LABEL|g" -e "s|__COLOR__|$COLOR|g" "$HERE/user-data/app.sh" > "$BUILD/ud-$R.sh"
  inst="$(aws ec2 describe-instances --region "$R" \
    --filters "Name=tag:Name,Values=$NAME-web" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [ "$inst" = "None" ] || [ -z "$inst" ]; then
    inst="$(aws ec2 run-instances --image-id "$ami" --instance-type t3.micro --count 1 \
      --subnet-id "$sa" --security-group-ids "$sg" --associate-public-ip-address \
      --user-data "file://$(w "$BUILD/ud-$R.sh")" \
      --tag-specifications "$(tag instance "$NAME-web")" \
      --region "$R" --query 'Instances[0].InstanceId' --output text)"
  fi

  say "[$R] ALB + target group"
  tg="$(aws elbv2 describe-target-groups --names "$NAME-tg" --region "$R" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)" || tg=""
  if [ -z "$tg" ] || [ "$tg" = "None" ]; then
    tg="$(aws elbv2 create-target-group --name "$NAME-tg" --protocol HTTP --port 80 \
      --vpc-id "$vpc" --target-type instance --health-check-path /health \
      --health-check-interval-seconds 10 --healthy-threshold-count 2 \
      --unhealthy-threshold-count 2 --region "$R" \
      --query 'TargetGroups[0].TargetGroupArn' --output text)"
  fi
  aws ec2 wait instance-running --instance-ids "$inst" --region "$R"
  aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$inst" --region "$R"

  alb="$(aws elbv2 describe-load-balancers --names "$NAME-alb" --region "$R" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || alb=""
  if [ -z "$alb" ] || [ "$alb" = "None" ]; then
    alb="$(aws elbv2 create-load-balancer --name "$NAME-alb" --type application \
      --scheme internet-facing --subnets "$sa" "$sb" --security-groups "$sg" \
      --tags "Key=Lab,Value=s9" --region "$R" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  fi
  aws elbv2 wait load-balancer-available --load-balancer-arns "$alb" --region "$R"
  if ! aws elbv2 describe-listeners --load-balancer-arn "$alb" --region "$R" \
       --query 'Listeners[0].ListenerArn' --output text 2>/dev/null | grep -q arn; then
    aws elbv2 create-listener --load-balancer-arn "$alb" --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=$tg" --region "$R" >/dev/null
  fi

  local dns; dns="$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb" \
    --region "$R" --query 'LoadBalancers[0].DNSName' --output text)"
  echo "    $LABEL: $dns"

  cat >> "$BUILD/regions.env" <<ENV
export ${COLOR^^}_REGION=$R
export ${COLOR^^}_VPC=$vpc
export ${COLOR^^}_INSTANCE=$inst
export ${COLOR^^}_ALB=$alb
export ${COLOR^^}_ALB_DNS=$dns
export ${COLOR^^}_TG=$tg
ENV
}

: > "$BUILD/regions.env"
build_region "$PRIMARY"   10.90.0.0/16 "$PRIMARY"   blue
build_region "$SECONDARY" 10.91.0.0/16 "$SECONDARY" green
source "$BUILD/regions.env"

# ------------------------------------------------------- Global Accelerator --
# Control plane lives in us-west-2 regardless of where the endpoints are. This
# is why a per-region sweep never finds an accelerator.
say "Global Accelerator (control plane: us-west-2)"
ACC_ARN="$(aws globalaccelerator list-accelerators --region us-west-2 \
  --query "Accelerators[?Name=='$NAME'].AcceleratorArn | [0]" --output text 2>/dev/null)"
if [ "$ACC_ARN" = "None" ] || [ -z "$ACC_ARN" ]; then
  ACC_ARN="$(aws globalaccelerator create-accelerator --name "$NAME" --enabled \
    --region us-west-2 --query 'Accelerator.AcceleratorArn' --output text)"
fi
for _ in $(seq 1 30); do
  st="$(aws globalaccelerator describe-accelerator --accelerator-arn "$ACC_ARN" \
    --region us-west-2 --query 'Accelerator.Status' --output text)"
  echo "    accelerator: $st"
  [ "$st" = "DEPLOYED" ] && break
  sleep 15
done

LISTENER_ARN="$(aws globalaccelerator list-listeners --accelerator-arn "$ACC_ARN" \
  --region us-west-2 --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)"
if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
  LISTENER_ARN="$(aws globalaccelerator create-listener --accelerator-arn "$ACC_ARN" \
    --protocol TCP --port-ranges FromPort=80,ToPort=80 --client-affinity NONE \
    --region us-west-2 --query 'Listener.ListenerArn' --output text)"
fi

# One endpoint group per region. TrafficDialPercentage=100 on both means health,
# not weighting, decides where traffic goes.
add_group() {  # $1 region, $2 alb arn
  local existing
  existing="$(aws globalaccelerator list-endpoint-groups --listener-arn "$LISTENER_ARN" \
    --region us-west-2 --query "EndpointGroups[?EndpointGroupRegion=='$1'].EndpointGroupArn | [0]" \
    --output text 2>/dev/null)"
  if [ "$existing" != "None" ] && [ -n "$existing" ]; then echo "    $1 group exists"; return; fi
  aws globalaccelerator create-endpoint-group --listener-arn "$LISTENER_ARN" \
    --endpoint-group-region "$1" --traffic-dial-percentage 100 \
    --health-check-interval-seconds 10 --threshold-count 2 --health-check-path /health \
    --endpoint-configurations "EndpointId=$2,Weight=100,ClientIPPreservationEnabled=false" \
    --region us-west-2 --query 'EndpointGroup.EndpointGroupArn' --output text >/dev/null
  echo "    $1 endpoint group created"
}
add_group "$PRIMARY"   "$BLUE_ALB"
add_group "$SECONDARY" "$GREEN_ALB"

ACC_DNS="$(aws globalaccelerator describe-accelerator --accelerator-arn "$ACC_ARN" \
  --region us-west-2 --query 'Accelerator.DnsName' --output text)"
ACC_IPS="$(aws globalaccelerator describe-accelerator --accelerator-arn "$ACC_ARN" \
  --region us-west-2 --query 'Accelerator.IpSets[0].IpAddresses' --output text | tr '\t' ' ')"

cat > "$HERE/.env.generated" <<ENV
$(cat "$BUILD/regions.env")
export ACC_ARN=$ACC_ARN
export LISTENER_ARN=$LISTENER_ARN
export ACC_DNS=$ACC_DNS
export ACC_IPS="$ACC_IPS"
ENV

say "Waiting for both endpoint groups to report healthy"
for i in $(seq 1 40); do
  states="$(aws globalaccelerator list-endpoint-groups --listener-arn "$LISTENER_ARN" \
    --region us-west-2 --query 'EndpointGroups[].EndpointDescriptions[].HealthState' \
    --output text | tr '\n' ' ')"
  echo "    t=$((i*15))s  $states"
  [ "$(echo "$states" | grep -o HEALTHY | wc -l)" -ge 2 ] && break
  sleep 15
done

say "Live"
echo "  accelerator DNS : $ACC_DNS"
echo "  static anycast  : $ACC_IPS"
echo "  these two IPs never change, in either region, ever"
curl -s --max-time 15 "http://$ACC_DNS/whoami.txt" || true
