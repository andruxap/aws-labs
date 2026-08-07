#!/usr/bin/env bash
# S6 teardown. Order is dependency-enforced and unusually strict:
#
#   interface endpoints -> endpoint service -> NLB -> target group -> instances
#   -> per VPC: security groups, IGW, subnets, VPC
#
# You cannot delete a VPC while an endpoint lives in it, and you cannot delete
# an endpoint service while a consumer endpoint is still connected to it.
#
# Interface endpoints are the thing to care about: ~$0.01/hr per endpoint per AZ,
# and they appear in NO EC2 console view. Five of them here.
set -uo pipefail
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/8 VPC endpoints (interface AND gateway) — the hourly billers"
EPS="$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=tag:Lab,Values=s6" --query 'VpcEndpoints[].VpcEndpointId' --output text)"
if [ -n "$EPS" ]; then
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS --region "$REGION" >/dev/null && ok "deleting: $EPS"
  for _ in $(seq 1 30); do
    n="$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=tag:Lab,Values=s6" \
      --query "length(VpcEndpoints[?State!='deleted'])" --output text)"
    [ "$n" = "0" ] && { ok "all gone"; break; }
    sleep 10
  done
else ok "none"; fi

say "2/8 endpoint service"
SVC="$(aws ec2 describe-vpc-endpoint-service-configurations --region "$REGION" \
  --filters "Name=tag:Lab,Values=s6" --query 'ServiceConfigurations[0].ServiceId' --output text 2>/dev/null)"
if [ "$SVC" != "None" ] && [ -n "$SVC" ]; then
  for _ in $(seq 1 12); do
    aws ec2 delete-vpc-endpoint-service-configurations --service-ids "$SVC" --region "$REGION" \
      --query 'Unsuccessful' --output text 2>/dev/null | grep -q . || { ok "$SVC deleted"; break; }
    sleep 10
  done
else ok "absent"; fi

say "3/8 network load balancer"
NLB="$(aws elbv2 describe-load-balancers --names lab-s6-nlb --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || NLB=""
if [ -n "$NLB" ] && [ "$NLB" != "None" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$NLB" --region "$REGION" && ok "deleting"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$NLB" --region "$REGION" 2>/dev/null
  ok "gone"
else ok "absent"; fi

say "4/8 target group"
TG="$(aws elbv2 describe-target-groups --names lab-s6-tg --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
if [ -n "$TG" ] && [ "$TG" != "None" ]; then
  done_it=""
  for _ in $(seq 1 12); do
    aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION" 2>/dev/null \
      && { ok "deleted"; done_it=1; break; }
    sleep 10
  done
  [ -z "$done_it" ] && echo "    !! lab-s6-tg STILL PRESENT — delete by hand"
else ok "absent"; fi

say "5/8 instances"
IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Lab,Values=s6" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS --region "$REGION" >/dev/null && ok "terminating $IDS"
  aws ec2 wait instance-terminated --instance-ids $IDS --region "$REGION"
  ok "terminated"
else ok "none"; fi

say "6/8 per-VPC teardown"
for name in lab-s6-payments lab-s6-analytics lab-s6-shared; do
  VPC="$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$name" \
    --query 'Vpcs[0].VpcId' --output text)"
  [ "$VPC" = "None" ] || [ -z "$VPC" ] && { ok "$name absent"; continue; }
  echo "    --- $name ($VPC)"

  for g in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    perms="$(aws ec2 describe-security-groups --group-ids "$g" --region "$REGION" \
      --query 'SecurityGroups[0].IpPermissions' --output json)"
    [ "$perms" != "[]" ] && aws ec2 revoke-security-group-ingress --group-id "$g" \
      --ip-permissions "$perms" --region "$REGION" >/dev/null 2>&1
  done
  for g in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    for _ in $(seq 1 10); do
      aws ec2 delete-security-group --group-id "$g" --region "$REGION" 2>/dev/null && { ok "sg $g"; break; }
      sleep 10   # endpoint ENIs linger briefly
    done
  done

  IGW="$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC" --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [ "$IGW" != "None" ] && [ -n "$IGW" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" --region "$REGION" 2>/dev/null
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" 2>/dev/null && ok "igw $IGW"
  fi

  for s in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC" \
      --query 'Subnets[].SubnetId' --output text); do
    for _ in $(seq 1 10); do
      aws ec2 delete-subnet --subnet-id "$s" --region "$REGION" 2>/dev/null && { ok "subnet $s"; break; }
      sleep 10
    done
  done

  for _ in $(seq 1 10); do
    aws ec2 delete-vpc --vpc-id "$VPC" --region "$REGION" 2>/dev/null && { ok "vpc $VPC deleted"; break; }
    sleep 10
  done
done

say "7/8 IAM"
aws iam remove-role-from-instance-profile --instance-profile-name lab-s6-ssm-role --role-name lab-s6-ssm-role 2>/dev/null
aws iam delete-instance-profile --instance-profile-name lab-s6-ssm-role 2>/dev/null && ok "instance profile deleted"
aws iam detach-role-policy --role-name lab-s6-ssm-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name lab-s6-ssm-role 2>/dev/null && ok "role deleted"

say "8/8 verify"
echo "  s6 VPC endpoints:  $(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=tag:Lab,Values=s6" --query "length(VpcEndpoints[?State!='deleted'])" --output text)"
echo "  endpoint services: $(aws ec2 describe-vpc-endpoint-service-configurations --region "$REGION" --filters "Name=tag:Lab,Values=s6" --query 'length(ServiceConfigurations)' --output text)"
echo "  s6 VPCs:           $(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Lab,Values=s6" --query 'length(Vpcs)' --output text)"
echo "  s6 instances:      $(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Lab,Values=s6" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text)"
echo "  load balancers:    $(aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[?contains(LoadBalancerName,'lab-s6')])" --output text)"
echo "  NAT gateways:      $(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=state,Values=available" --query 'length(NatGateways)' --output text)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
