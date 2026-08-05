#!/usr/bin/env bash
# Part B (DCT project 4) — custom VPC, two security groups, connectivity testing.
#
# Built by hand rather than the "VPC and more" wizard so every component is
# explicit. NO NAT GATEWAY — that is the expensive one (~$32/mo) and this design
# does not need it: both subnets are public.
#
# Instances are reached via SSM Session Manager, not SSH, so no key pair and no
# port 22 anywhere.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CIDR="10.20.0.0/16"
ROLE="lab-s1-ssm-role"
say() { echo ""; echo "==> $*"; }

MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
tagspec() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Lab,Value=s1}]"; }

say "VPC $CIDR"
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=lab-s1-vpc" --query 'Vpcs[0].VpcId' --output text)"
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID="$(aws ec2 create-vpc --cidr-block "$CIDR" --region "$REGION" \
    --tag-specifications "$(tagspec vpc lab-s1-vpc)" --query 'Vpc.VpcId' --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
fi
echo "    $VPC_ID"

say "internet gateway + public route"
IGW_ID="$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)"
if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID="$(aws ec2 create-internet-gateway --region "$REGION" \
    --tag-specifications "$(tagspec internet-gateway lab-s1-igw)" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
fi
RT_ID="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
  --query 'RouteTables[0].RouteTableId' --output text)"
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" --region "$REGION" >/dev/null 2>&1 || true
echo "    $IGW_ID via $RT_ID"

say "two public subnets, different AZs, auto-assign public IPv4"
mk_subnet() {  # $1 cidr, $2 az-suffix, $3 name
  local id
  id="$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$3" \
    --query 'Subnets[0].SubnetId' --output text)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$1" \
      --availability-zone "${REGION}$2" --region "$REGION" \
      --tag-specifications "$(tagspec subnet "$3")" --query 'Subnet.SubnetId' --output text)"
    aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch --region "$REGION"
  fi
  echo "$id"
}
SUBNET_A="$(mk_subnet 10.20.1.0/24 a lab-s1-public-a)"
SUBNET_B="$(mk_subnet 10.20.2.0/24 b lab-s1-public-b)"
echo "    A=$SUBNET_A  B=$SUBNET_B"

say "security groups SGA and SGB"
mk_sg() {  # $1 name, $2 description
  local id
  id="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-security-group --group-name "$1" --description "$2" \
      --vpc-id "$VPC_ID" --region "$REGION" --query GroupId --output text)"
  fi
  echo "$id"
}
SGA="$(mk_sg SGA "S1 SGA - HTTP from anywhere")"
SGB="$(mk_sg SGB "S1 SGB - HTTP from anywhere + ICMP from SGA")"

# SGA: HTTP 80 from anywhere. (Course also opens 22; omitted — SSM instead.)
aws ec2 authorize-security-group-ingress --group-id "$SGA" --protocol tcp --port 80 \
  --cidr 0.0.0.0/0 --region "$REGION" >/dev/null 2>&1 || true
# SGB: HTTP 80 from anywhere + all ICMP from SGA (source is the *group*, not a CIDR)
aws ec2 authorize-security-group-ingress --group-id "$SGB" --protocol tcp --port 80 \
  --cidr 0.0.0.0/0 --region "$REGION" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SGB" --protocol icmp --port -1 \
  --source-group "$SGA" --region "$REGION" >/dev/null 2>&1 || true
echo "    SGA=$SGA  SGB=$SGB"

say "launching one instance per group"
AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query 'Parameter.Value' --output text)"
launch() {  # $1 name, $2 subnet, $3 sg
  local id
  id="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [ "$id" != "None" ] && [ -n "$id" ]; then echo "$id"; return; fi
  aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1 \
    --subnet-id "$2" --security-group-ids "$3" \
    --iam-instance-profile "Name=$ROLE" \
    --user-data "file://$(cygpath -m "$HERE/user-data/apache.sh")" \
    --tag-specifications "$(tagspec instance "$1")" \
    --region "$REGION" --query 'Instances[0].InstanceId' --output text
}
INST_A="$(launch lab-s1-instance-a "$SUBNET_A" "$SGA")"
INST_B="$(launch lab-s1-instance-b "$SUBNET_B" "$SGB")"
echo "    A=$INST_A  B=$INST_B"

aws ec2 wait instance-running --instance-ids "$INST_A" "$INST_B" --region "$REGION"
ips() { aws ec2 describe-instances --instance-ids "$1" --region "$REGION" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text; }
read -r PUB_A PRIV_A <<< "$(ips "$INST_A")"
read -r PUB_B PRIV_B <<< "$(ips "$INST_B")"

NACL_ID="$(aws ec2 describe-network-acls --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
  --query 'NetworkAcls[0].NetworkAclId' --output text)"

cat > "$HERE/.env.b" <<ENV
export AWS_REGION=$REGION
export VPC_ID=$VPC_ID
export SUBNET_A=$SUBNET_A
export SUBNET_B=$SUBNET_B
export SGA=$SGA
export SGB=$SGB
export INST_A=$INST_A
export INST_B=$INST_B
export PUB_A=$PUB_A
export PRIV_A=$PRIV_A
export PUB_B=$PUB_B
export PRIV_B=$PRIV_B
export NACL_ID=$NACL_ID
export MY_IP=$MY_IP
export IGW_ID=$IGW_ID
export RT_ID=$RT_ID
ENV

say "Part B up"
echo "    A  public=$PUB_A  private=$PRIV_A  (SGA)"
echo "    B  public=$PUB_B  private=$PRIV_B  (SGB)"
echo "    NACL=$NACL_ID  your IP=$MY_IP"
echo "    no NAT gateway: $(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" --query 'length(NatGateways)' --output text) (must be 0)"
