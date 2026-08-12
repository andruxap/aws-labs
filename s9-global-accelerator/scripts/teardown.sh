#!/usr/bin/env bash
# S9 teardown.
#
# The accelerator goes FIRST and is confirmed gone, because it is the only
# resource here that:
#   - bills a flat ~$18/month whether or not anyone uses it
#   - appears in NO per-region console view or region sweep
#   - must be DISABLED before it can be deleted, and disabling is not instant
#
# Everything else is ordinary regional teardown.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="lab-s9"
PRIMARY="${PRIMARY_REGION:-us-east-1}"
SECONDARY="${SECONDARY_REGION:-us-west-2}"
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/3 Global Accelerator (control plane us-west-2)"
ACC="$(aws globalaccelerator list-accelerators --region us-west-2 \
  --query "Accelerators[?Name=='$NAME'].AcceleratorArn | [0]" --output text 2>/dev/null)"
if [ "$ACC" != "None" ] && [ -n "$ACC" ]; then
  for l in $(aws globalaccelerator list-listeners --accelerator-arn "$ACC" --region us-west-2 \
      --query 'Listeners[].ListenerArn' --output text 2>/dev/null); do
    for g in $(aws globalaccelerator list-endpoint-groups --listener-arn "$l" --region us-west-2 \
        --query 'EndpointGroups[].EndpointGroupArn' --output text 2>/dev/null); do
      aws globalaccelerator delete-endpoint-group --endpoint-group-arn "$g" --region us-west-2 && ok "endpoint group deleted"
    done
    aws globalaccelerator delete-listener --listener-arn "$l" --region us-west-2 && ok "listener deleted"
  done

  # Must be disabled before delete, and the state change takes a minute or two.
  aws globalaccelerator update-accelerator --accelerator-arn "$ACC" --no-enabled \
    --region us-west-2 >/dev/null && ok "disabling..."
  for _ in $(seq 1 40); do
    st="$(aws globalaccelerator describe-accelerator --accelerator-arn "$ACC" --region us-west-2 \
      --query 'Accelerator.[Enabled,Status]' --output text 2>/dev/null)"
    echo "      $st"
    case "$st" in "False	DEPLOYED") break;; esac
    sleep 15
  done
  for _ in $(seq 1 12); do
    aws globalaccelerator delete-accelerator --accelerator-arn "$ACC" --region us-west-2 2>/dev/null \
      && { ok "accelerator deleted"; break; }
    sleep 15
  done
  if aws globalaccelerator describe-accelerator --accelerator-arn "$ACC" --region us-west-2 >/dev/null 2>&1; then
    echo "    !! ACCELERATOR STILL PRESENT — delete by hand, it bills ~\$18/month"
  else
    ok "confirmed gone"
  fi
else ok "absent"; fi

say "2/3 per-region teardown"
for R in "$PRIMARY" "$SECONDARY"; do
  echo "    --- $R"
  ALB="$(aws elbv2 describe-load-balancers --names "$NAME-alb" --region "$R" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || ALB=""
  if [ -n "$ALB" ] && [ "$ALB" != "None" ]; then
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$R" && ok "ALB deleting"
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB" --region "$R" 2>/dev/null
  fi

  TG="$(aws elbv2 describe-target-groups --names "$NAME-tg" --region "$R" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  if [ -n "$TG" ] && [ "$TG" != "None" ]; then
    done_it=""
    for _ in $(seq 1 12); do
      aws elbv2 delete-target-group --target-group-arn "$TG" --region "$R" 2>/dev/null \
        && { ok "target group deleted"; done_it=1; break; }
      sleep 10
    done
    [ -z "$done_it" ] && echo "      !! target group still present"
  fi

  IDS="$(aws ec2 describe-instances --region "$R" --filters "Name=tag:Lab,Values=s9" \
    "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [ -n "$IDS" ]; then
    aws ec2 terminate-instances --instance-ids $IDS --region "$R" >/dev/null && ok "terminating $IDS"
    aws ec2 wait instance-terminated --instance-ids $IDS --region "$R"
    ok "terminated"
  fi

  VPC="$(aws ec2 describe-vpcs --region "$R" --filters "Name=tag:Name,Values=$NAME-vpc" \
    --query 'Vpcs[0].VpcId' --output text)"
  [ "$VPC" = "None" ] || [ -z "$VPC" ] && { ok "vpc absent"; continue; }

  for g in $(aws ec2 describe-security-groups --region "$R" --filters "Name=vpc-id,Values=$VPC" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    for _ in $(seq 1 10); do
      aws ec2 delete-security-group --group-id "$g" --region "$R" 2>/dev/null && { ok "sg $g"; break; }
      sleep 10
    done
  done

  IGW="$(aws ec2 describe-internet-gateways --region "$R" \
    --filters "Name=attachment.vpc-id,Values=$VPC" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [ "$IGW" != "None" ] && [ -n "$IGW" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" --region "$R" 2>/dev/null
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$R" 2>/dev/null && ok "igw"
  fi

  for s in $(aws ec2 describe-subnets --region "$R" --filters "Name=vpc-id,Values=$VPC" \
      --query 'Subnets[].SubnetId' --output text); do
    for _ in $(seq 1 10); do
      aws ec2 delete-subnet --subnet-id "$s" --region "$R" 2>/dev/null && { ok "subnet $s"; break; }
      sleep 10
    done
  done

  for _ in $(seq 1 10); do
    aws ec2 delete-vpc --vpc-id "$VPC" --region "$R" 2>/dev/null && { ok "vpc $VPC deleted"; break; }
    sleep 10
  done
done

say "3/3 verify"
echo "  accelerators (global): $(aws globalaccelerator list-accelerators --region us-west-2 --query 'length(Accelerators)' --output text 2>/dev/null)"
for R in "$PRIMARY" "$SECONDARY"; do
  printf "  %-11s ec2=%s alb=%s vpc=%s eip=%s\n" "$R" \
    "$(aws ec2 describe-instances --region "$R" --filters "Name=tag:Lab,Values=s9" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text)" \
    "$(aws elbv2 describe-load-balancers --region "$R" --query "length(LoadBalancers[?contains(LoadBalancerName,'$NAME')])" --output text)" \
    "$(aws ec2 describe-vpcs --region "$R" --filters "Name=tag:Name,Values=$NAME-vpc" --query 'length(Vpcs)' --output text)" \
    "$(aws ec2 describe-addresses --region "$R" --query 'length(Addresses)' --output text)"
done
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
