#!/usr/bin/env bash
# S5 teardown. CloudFormation removes everything it created, including the live
# changes made while fixing the faults — a resource modified out of band is
# still deleted, it just no longer matches the template.
set -uo pipefail
export MSYS_NO_PATHCONV=1
REGION="us-east-1"
STACK="${1:-andrey}"

echo "==> deleting stack $STACK"
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"

for i in $(seq 1 40); do
  s="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)"
  echo "    t=$((i*15))s $s"
  [ "$s" = "GONE" ] || [ "$s" = "DELETE_COMPLETE" ] && break
  sleep 15
done

echo ""
echo "==> verify"
echo "  stacks:          $(aws cloudformation list-stacks --region "$REGION" --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "length(StackSummaries[?StackName=='$STACK'])" --output text)"
echo "  load balancers:  $(aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[?contains(LoadBalancerName,'$STACK')])" --output text)"
echo "  ASGs:            $(aws autoscaling describe-auto-scaling-groups --region "$REGION" --query "length(AutoScalingGroups[?contains(AutoScalingGroupName,'$STACK')])" --output text)"
echo "  target groups:   $(aws elbv2 describe-target-groups --region "$REGION" --query "length(TargetGroups[?contains(TargetGroupName,'$STACK')])" --output text)"
echo "  running EC2:     $(aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=running,pending" --query 'length(Reservations[].Instances[])' --output text)"
echo "  free volumes:    $(aws ec2 describe-volumes --region "$REGION" --query "length(Volumes[?State=='available'])" --output text)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
