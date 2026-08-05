#!/usr/bin/env bash
# S1 teardown — Part A and Part B. Safe to run twice.
#
# Dependency order for a VPC is strict: instances must be fully TERMINATED (not
# just shutting-down) before their ENIs release, and the security groups cannot
# be deleted while they reference each other, so cross-references are revoked
# first.
set -uo pipefail
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/7 instances (all tagged Lab=s1)"
IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Lab,Values=s1" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS --region "$REGION" >/dev/null
  ok "terminating: $IDS"
  aws ec2 wait instance-terminated --instance-ids $IDS --region "$REGION"
  ok "terminated"
else ok "none"; fi

VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=lab-s1-vpc" --query 'Vpcs[0].VpcId' --output text)"

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  say "2/7 NACL entries added by the lab"
  NACL_ID="$(aws ec2 describe-network-acls --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
    --query 'NetworkAcls[0].NetworkAclId' --output text)"
  aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 --ingress --region "$REGION" 2>/dev/null && ok "inbound rule 50 removed"
  aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 --egress --region "$REGION" 2>/dev/null && ok "outbound rule 50 removed"

  say "3/7 security groups (revoke cross-references first)"
  for g in SGA SGB; do
    gid="$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=$g" "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
    [ "$gid" = "None" ] && continue
    perms="$(aws ec2 describe-security-groups --group-ids "$gid" --region "$REGION" \
      --query 'SecurityGroups[0].IpPermissions' --output json)"
    [ "$perms" != "[]" ] && aws ec2 revoke-security-group-ingress --group-id "$gid" \
      --ip-permissions "$perms" --region "$REGION" >/dev/null 2>&1 && ok "$g rules revoked"
  done
  for g in SGA SGB; do
    gid="$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=$g" "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
    [ "$gid" = "None" ] && continue
    aws ec2 delete-security-group --group-id "$gid" --region "$REGION" 2>/dev/null && ok "$g deleted"
  done

  say "4/7 subnets"
  for s in $(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$s" --region "$REGION" 2>/dev/null && ok "$s deleted"
  done

  say "5/7 internet gateway"
  IGW_ID="$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [ "$IGW_ID" != "None" ] && [ -n "$IGW_ID" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" 2>/dev/null && ok "$IGW_ID deleted"
  fi

  say "6/7 VPC"
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null && ok "$VPC_ID deleted" || ok "still has dependencies"
else
  say "2-6/7 VPC already gone"
fi

say "7/7 Part A security group + SSM role"
DEF_VPC="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" --query 'Vpcs[0].VpcId' --output text)"
SGA_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=lab-s1a-web-sg" "Name=vpc-id,Values=$DEF_VPC" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
[ "$SGA_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SGA_ID" --region "$REGION" 2>/dev/null && ok "lab-s1a-web-sg deleted"
aws iam remove-role-from-instance-profile --instance-profile-name lab-s1-ssm-role --role-name lab-s1-ssm-role 2>/dev/null
aws iam delete-instance-profile --instance-profile-name lab-s1-ssm-role 2>/dev/null && ok "instance profile deleted"
aws iam detach-role-policy --role-name lab-s1-ssm-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name lab-s1-ssm-role 2>/dev/null && ok "lab-s1-ssm-role deleted"

say "Verify"
echo "  s1 instances: $(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Lab,Values=s1" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text)"
echo "  lab VPCs:     $(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=lab-s1-vpc" --query 'length(Vpcs)' --output text)"
echo "  NAT gateways: $(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=state,Values=available" --query 'length(NatGateways)' --output text)"
echo "  elastic IPs:  $(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
