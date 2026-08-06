#!/usr/bin/env bash
# S4 teardown. Safe to run twice.
#
# ASGs go first: deleting one with --force-delete terminates its instances, and
# nothing else can be removed while they hold ENIs. Then the ALB (the meter),
# then target groups, then the shared plumbing.
set -uo pipefail
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/7 auto scaling groups (force-delete terminates their instances)"
for c in blue green; do
  n="lab-s4-$c-asg"
  if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$n" \
      --region "$REGION" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null | grep -q "$n"; then
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$n" \
      --force-delete --region "$REGION" && ok "$n deleting"
  else ok "$n absent"; fi
done

say "waiting for s4 instances to terminate"
for _ in $(seq 1 40); do
  n="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Lab,Values=s4" "Name=instance-state-name,Values=running,pending,stopping,stopped,shutting-down" \
    --query 'length(Reservations[].Instances[])' --output text)"
  echo "    remaining: $n"
  [ "$n" = "0" ] && break
  sleep 15
done

say "2/7 load balancer (the meter)"
ALB_ARN="$(aws elbv2 describe-load-balancers --names lab-s4-alb --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || ALB_ARN=""
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" && ok "deleting"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$REGION" 2>/dev/null
  ok "gone — billing stopped"
else ok "absent"; fi

say "3/7 target groups (retry: they stay attached briefly after the ALB goes)"
for c in blue green; do
  arn="$(aws elbv2 describe-target-groups --names "s4-$c-tg" --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then ok "s4-$c-tg absent"; continue; fi
  done_it=""
  for _ in $(seq 1 12); do
    aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null \
      && { ok "s4-$c-tg deleted"; done_it=1; break; }
    sleep 10
  done
  [ -z "$done_it" ] && echo "    !! s4-$c-tg STILL PRESENT — delete by hand"
done

say "4/7 launch template (all versions)"
aws ec2 delete-launch-template --launch-template-name lab-s4-lt --region "$REGION" >/dev/null 2>&1 \
  && ok "lab-s4-lt deleted" || ok "absent"

say "5/7 security group"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=lab-s4-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  for _ in $(seq 1 12); do
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null && { ok "deleted"; break; }
    sleep 10
  done
else ok "absent"; fi

say "6/7 IAM"
aws iam remove-role-from-instance-profile --instance-profile-name lab-s4-ec2-role --role-name lab-s4-ec2-role 2>/dev/null
aws iam delete-instance-profile --instance-profile-name lab-s4-ec2-role 2>/dev/null && ok "instance profile deleted"
for p in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do
  aws iam detach-role-policy --role-name lab-s4-ec2-role --policy-arn "arn:aws:iam::aws:policy/$p" 2>/dev/null
done
aws iam delete-role --role-name lab-s4-ec2-role 2>/dev/null && ok "role deleted"

say "7/7 orphan check — EBS volumes and stopped instances"
echo "  available volumes: $(aws ec2 describe-volumes --region "$REGION" --query "length(Volumes[?State=='available'])" --output text)"
echo "  stopped instances: $(aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=stopped" --query 'length(Reservations[].Instances[])' --output text)"

say "Verify"
echo "  s4 ASGs:          $(aws autoscaling describe-auto-scaling-groups --region "$REGION" --query "length(AutoScalingGroups[?contains(AutoScalingGroupName,'lab-s4')])" --output text)"
echo "  s4 load balancers:$(aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[?contains(LoadBalancerName,'lab-s4')])" --output text)"
echo "  s4 target groups: $(aws elbv2 describe-target-groups --region "$REGION" --query "length(TargetGroups[?contains(TargetGroupName,'s4-')])" --output text)"
echo "  s4 instances:     $(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Lab,Values=s4" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
