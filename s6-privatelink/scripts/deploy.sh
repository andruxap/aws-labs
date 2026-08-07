#!/usr/bin/env bash
# S6 — Multi-VPC networking with PrivateLink.
#
# Three isolated VPCs. Shared Services runs an internal app on a PRIVATE subnet
# instance with no public IP, fronted by an internal NLB and published as a VPC
# Endpoint Service. Payments and Analytics each consume it through an Interface
# Endpoint. No peering, no transit gateway, no internet path on the provider.
#
#   Shared Services 10.30.0.0/16   app 10.30.1.x (private) -> internal NLB -> endpoint service
#   Payments        10.10.0.0/16   client + interface endpoint ─┐
#   Analytics       10.20.0.0/16   client + interface endpoint ─┴─> PrivateLink
#
# COST: interface endpoints bill ~$0.01/hr PER ENDPOINT PER AZ and are invisible
# in the EC2 console. The NLB bills ~$0.0225/hr. NO NAT GATEWAY anywhere.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
AZ1="${REGION}a"; AZ2="${REGION}b"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
ROLE="lab-s6-ssm-role"

tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Lab,Value=s6}]"; }

# ---------------------------------------------------------------- helpers ----
mk_vpc() {  # $1 name, $2 cidr  -> vpc id
  local id
  id="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'Vpcs[0].VpcId' --output text)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-vpc --cidr-block "$2" --region "$REGION" \
      --tag-specifications "$(tag vpc "$1")" --query 'Vpc.VpcId' --output text)"
    aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-hostnames --region "$REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-support --region "$REGION"
  fi
  echo "$id"
}

mk_subnet() {  # $1 vpc, $2 cidr, $3 az, $4 name, $5 public(yes|no) -> subnet id
  local id
  id="$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$1" "Name=tag:Name,Values=$4" \
    --query 'Subnets[0].SubnetId' --output text)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-subnet --vpc-id "$1" --cidr-block "$2" --availability-zone "$3" \
      --region "$REGION" --tag-specifications "$(tag subnet "$4")" \
      --query 'Subnet.SubnetId' --output text)"
    [ "$5" = "yes" ] && aws ec2 modify-subnet-attribute --subnet-id "$id" \
      --map-public-ip-on-launch --region "$REGION"
  fi
  echo "$id"
}

mk_igw() {  # $1 vpc, $2 name -> igw id (attached, with a public route table)
  local igw
  igw="$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$1" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [ "$igw" = "None" ] || [ -z "$igw" ]; then
    igw="$(aws ec2 create-internet-gateway --region "$REGION" \
      --tag-specifications "$(tag internet-gateway "$2")" \
      --query 'InternetGateway.InternetGatewayId' --output text)"
    aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$1" --region "$REGION"
  fi
  echo "$igw"
}

mk_sg() {  # $1 vpc, $2 name, $3 desc -> sg id
  local id
  id="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$2" "Name=vpc-id,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-security-group --group-name "$2" --description "$3" \
      --vpc-id "$1" --region "$REGION" --query GroupId --output text)"
  fi
  echo "$id"
}

AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query 'Parameter.Value' --output text)"

say "account $ACCT / region $REGION"

# ------------------------------------------------------------------- IAM -----
say "SSM role $ROLE"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true
echo "    ready"

# =================================================== SHARED SERVICES (provider)
say "VPC 1/3 — Shared Services 10.30.0.0/16 (the provider)"
SS_VPC="$(mk_vpc lab-s6-shared 10.30.0.0/16)"
# The provider app lives in PRIVATE subnets across two AZs: the endpoint service
# must offer every AZ its consumers will use.
SS_PRIV_A="$(mk_subnet "$SS_VPC" 10.30.1.0/24 "$AZ1" lab-s6-shared-private-a no)"
SS_PRIV_B="$(mk_subnet "$SS_VPC" 10.30.2.0/24 "$AZ2" lab-s6-shared-private-b no)"
echo "    $SS_VPC  private: $SS_PRIV_A $SS_PRIV_B"

# SSM needs to reach the AWS API. With no NAT and no IGW, that is done with
# interface endpoints for ssm/ssmmessages/ec2messages — the same PrivateLink
# mechanism this lab is about, used on ourselves.
SS_EP_SG="$(mk_sg "$SS_VPC" lab-s6-shared-endpoint-sg "allow 443 from the VPC")"
aws ec2 authorize-security-group-ingress --group-id "$SS_EP_SG" --protocol tcp --port 443 \
  --cidr 10.30.0.0/16 --region "$REGION" >/dev/null 2>&1 || true
SS_APP_SG="$(mk_sg "$SS_VPC" lab-s6-shared-app-sg "internal app, 80 from the VPC")"
aws ec2 authorize-security-group-ingress --group-id "$SS_APP_SG" --protocol tcp --port 80 \
  --cidr 10.30.0.0/16 --region "$REGION" >/dev/null 2>&1 || true

say "SSM interface endpoints in Shared Services (no NAT, no IGW on the provider)"
for svc in ssm ssmmessages ec2messages; do
  ex="$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$SS_VPC" "Name=service-name,Values=com.amazonaws.$REGION.$svc" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text)"
  if [ "$ex" = "None" ] || [ -z "$ex" ]; then
    aws ec2 create-vpc-endpoint --vpc-id "$SS_VPC" --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.$REGION.$svc" \
      --subnet-ids "$SS_PRIV_A" --security-group-ids "$SS_EP_SG" \
      --private-dns-enabled --region "$REGION" \
      --tag-specifications "$(tag vpc-endpoint "lab-s6-ssm-$svc")" \
      --query 'VpcEndpoint.VpcEndpointId' --output text
  else echo "    $svc exists"; fi
done

say "provider instance (private subnet, NO public IP)"
sed "s|__NAME__|shared-services-app|" "$HERE/user-data/app.sh" > "$BUILD/ud-app.sh"
SS_APP="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=lab-s6-app" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [ "$SS_APP" = "None" ] || [ -z "$SS_APP" ]; then
  SS_APP="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1 \
    --subnet-id "$SS_PRIV_A" --security-group-ids "$SS_APP_SG" \
    --iam-instance-profile "Name=$ROLE" --no-associate-public-ip-address \
    --user-data "file://$(w "$BUILD/ud-app.sh")" \
    --tag-specifications "$(tag instance lab-s6-app)" \
    --region "$REGION" --query 'Instances[0].InstanceId' --output text)"
fi
echo "    $SS_APP"

say "internal NLB + target group"
NLB_ARN="$(aws elbv2 describe-load-balancers --names lab-s6-nlb --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || NLB_ARN=""
if [ -z "$NLB_ARN" ] || [ "$NLB_ARN" = "None" ]; then
  NLB_ARN="$(aws elbv2 create-load-balancer --name lab-s6-nlb --type network --scheme internal \
    --subnets "$SS_PRIV_A" "$SS_PRIV_B" --tags "Key=Lab,Value=s6" --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi
TG_ARN="$(aws elbv2 describe-target-groups --names lab-s6-tg --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)" || TG_ARN=""
if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  TG_ARN="$(aws elbv2 create-target-group --name lab-s6-tg --protocol TCP --port 80 \
    --vpc-id "$SS_VPC" --target-type instance --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
fi
aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=$SS_APP" --region "$REGION"
aws elbv2 wait load-balancer-available --load-balancer-arns "$NLB_ARN" --region "$REGION"
if ! aws elbv2 describe-listeners --load-balancer-arn "$NLB_ARN" --region "$REGION" \
     --query 'Listeners[0].ListenerArn' --output text 2>/dev/null | grep -q arn; then
  aws elbv2 create-listener --load-balancer-arn "$NLB_ARN" --protocol TCP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --region "$REGION" >/dev/null
fi
echo "    internal NLB ready"

say "VPC endpoint service (publishes the NLB to other VPCs)"
SVC_ID="$(aws ec2 describe-vpc-endpoint-service-configurations --region "$REGION" \
  --filters "Name=tag:Lab,Values=s6" --query 'ServiceConfigurations[0].ServiceId' --output text 2>/dev/null)"
if [ "$SVC_ID" = "None" ] || [ -z "$SVC_ID" ]; then
  SVC_ID="$(aws ec2 create-vpc-endpoint-service-configuration \
    --network-load-balancer-arns "$NLB_ARN" --no-acceptance-required \
    --region "$REGION" --tag-specifications "$(tag vpc-endpoint-service lab-s6-service)" \
    --query 'ServiceConfiguration.ServiceId' --output text)"
fi
SVC_NAME="$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "$SVC_ID" \
  --region "$REGION" --query 'ServiceConfigurations[0].ServiceName' --output text)"
# Consumers must be explicitly permitted, even inside the same account.
aws ec2 modify-vpc-endpoint-service-permissions --service-id "$SVC_ID" \
  --add-allowed-principals "arn:aws:iam::$ACCT:root" --region "$REGION" >/dev/null 2>&1 || true
echo "    $SVC_NAME"

# ====================================================== CONSUMERS ============
CONSUMERS=""
build_consumer() {  # $1 name, $2 cidr, $3 priv-cidr, $4 pub-cidr
  local vpc priv pub igw rt sg ep inst
  say "VPC — $1 $2 (consumer)"
  vpc="$(mk_vpc "lab-s6-$1" "$2")"
  priv="$(mk_subnet "$vpc" "$3" "$AZ1" "lab-s6-$1-private-a" no)"
  pub="$(mk_subnet "$vpc" "$4" "$AZ1" "lab-s6-$1-public-a" yes)"
  igw="$(mk_igw "$vpc" "lab-s6-$1-igw")"
  rt="$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$igw" --region "$REGION" >/dev/null 2>&1 || true

  sg="$(mk_sg "$vpc" "lab-s6-$1-sg" "consumer client + endpoint")"
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 443 \
    --cidr "$2" --region "$REGION" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 80 \
    --cidr "$2" --region "$REGION" >/dev/null 2>&1 || true

  # The interface endpoint: this is PrivateLink. It puts an ENI carrying the
  # provider's service into THIS VPC's subnet.
  ep="$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=service-name,Values=$SVC_NAME" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text)"
  if [ "$ep" = "None" ] || [ -z "$ep" ]; then
    ep="$(aws ec2 create-vpc-endpoint --vpc-id "$vpc" --vpc-endpoint-type Interface \
      --service-name "$SVC_NAME" --subnet-ids "$priv" --security-group-ids "$sg" \
      --region "$REGION" --tag-specifications "$(tag vpc-endpoint "lab-s6-$1-endpoint")" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)"
  fi

  # Client goes in the PUBLIC subnet purely so SSM can reach it without more
  # endpoints. It still reaches the provider only via PrivateLink.
  inst="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=lab-s6-$1-client" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [ "$inst" = "None" ] || [ -z "$inst" ]; then
    inst="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1 \
      --subnet-id "$pub" --security-group-ids "$sg" --iam-instance-profile "Name=$ROLE" \
      --associate-public-ip-address \
      --tag-specifications "$(tag instance "lab-s6-$1-client")" \
      --region "$REGION" --query 'Instances[0].InstanceId' --output text)"
  fi
  echo "    vpc=$vpc endpoint=$ep client=$inst"
  echo "export ${1^^}_VPC=$vpc"      >> "$BUILD/consumers.env"
  echo "export ${1^^}_EP=$ep"        >> "$BUILD/consumers.env"
  echo "export ${1^^}_CLIENT=$inst"  >> "$BUILD/consumers.env"
}

: > "$BUILD/consumers.env"
build_consumer payments  10.10.0.0/16 10.10.1.0/24 10.10.0.0/24
build_consumer analytics 10.20.0.0/16 10.20.1.0/24 10.20.0.0/24
source "$BUILD/consumers.env"

cat > "$HERE/.env.generated" <<ENV
export AWS_REGION=$REGION
export SS_VPC=$SS_VPC
export SS_APP=$SS_APP
export SS_APP_SG=$SS_APP_SG
export NLB_ARN=$NLB_ARN
export TG_ARN=$TG_ARN
export SVC_ID=$SVC_ID
export SVC_NAME=$SVC_NAME
$(cat "$BUILD/consumers.env")
ENV

say "waiting for endpoints to become available"
for i in $(seq 1 30); do
  st="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$PAYMENTS_EP" "$ANALYTICS_EP" \
    --region "$REGION" --query 'VpcEndpoints[].State' --output text | tr '\n' ' ')"
  echo "    t=$((i*15))s $st"
  echo "$st" | grep -qv pending && [ "$(echo "$st" | tr ' ' '\n' | grep -c available)" = "2" ] && break
  sleep 15
done

say "Built"
echo "  service : $SVC_NAME"
echo "  provider: $SS_APP (private subnet, no public IP)"
echo "  next    : bash scripts/test.sh"
