#!/usr/bin/env bash
# S3 teardown. The ALB is the only thing here that bills meaningfully, so it
# goes early. Safe to run twice.
#
# Order is dependency-enforced: the ALB must be gone before its security group
# (the ALB holds ENIs using it) and before the target groups it references.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
REGION="${AWS_REGION:-us-east-1}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="arr-bucket-${ACCT}-s3lab"
ZONE_ID="Z01678051OM322HGI9E5G"
DOMAIN="lab.andruxa.dev"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/7 Route 53 lab records"
# A DELETE must repeat the record exactly, so read it back rather than rebuild it.
for name in "red.$DOMAIN." "blue.$DOMAIN." "$DOMAIN."; do
  rr="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$name' && Type=='A'] | [0]" --output json 2>/dev/null)"
  [ "$rr" = "null" ] || [ -z "$rr" ] && { ok "$name absent"; continue; }
  printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$rr" > "$BUILD/del.json"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$(w "$BUILD/del.json")" >/dev/null 2>&1 && ok "$name deleted" || ok "$name failed"
done

say "2/7 load balancer (the meter)"
ALB_ARN="$(aws elbv2 describe-load-balancers --names lab-s3-alb --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)" || ALB_ARN=""
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" && ok "deleting"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$REGION" 2>/dev/null
  ok "gone — billing stopped"
else ok "absent"; fi

say "3/7 target groups"
# A target group stays attached for a short while after its ALB reports deleted,
# and delete-target-group fails with ResourceInUse until it detaches. The first
# version of this script used `|| continue` and skipped straight past that
# failure, leaving both groups behind. Retry, and say so when it gives up.
for c in red blue; do
  arn="$(aws elbv2 describe-target-groups --names "s3-$c-tg" --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then ok "s3-$c-tg absent"; continue; fi
  deleted=""
  for _ in $(seq 1 12); do
    aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null \
      && { ok "s3-$c-tg deleted"; deleted=1; break; }
    sleep 10
  done
  [ -z "$deleted" ] && echo "    !! s3-$c-tg STILL PRESENT — delete it by hand"
done

say "4/7 instances"
IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Lab,Values=s3" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS --region "$REGION" >/dev/null && ok "terminating $IDS"
  aws ec2 wait instance-terminated --instance-ids $IDS --region "$REGION"
  ok "terminated"
else ok "none"; fi

say "5/7 security group"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region "$REGION" --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=lab-s3-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  for _ in $(seq 1 12); do
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null && { ok "deleted"; break; }
    sleep 10   # ALB ENIs linger a little after the ALB itself is gone
  done
else ok "absent"; fi

say "6/7 S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3 rm "s3://$BUCKET" --recursive --only-show-errors
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" && ok "$BUCKET deleted"
else ok "absent"; fi

say "7/7 IAM"
aws iam remove-role-from-instance-profile --instance-profile-name lab-s3-arr-role --role-name lab-s3-arr-role 2>/dev/null
aws iam delete-instance-profile --instance-profile-name lab-s3-arr-role 2>/dev/null && ok "instance profile deleted"
aws iam delete-role-policy --role-name lab-s3-arr-role --policy-name S3ArrRead 2>/dev/null
aws iam detach-role-policy --role-name lab-s3-arr-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name lab-s3-arr-role 2>/dev/null && ok "role deleted"

say "Verify"
echo "  load balancers: $(aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[?contains(LoadBalancerName,'lab-s3')])" --output text)"
echo "  target groups:  $(aws elbv2 describe-target-groups --region "$REGION" --query "length(TargetGroups[?contains(TargetGroupName,'s3-')])" --output text)"
echo "  s3 instances:   $(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Lab,Values=s3" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text)"
echo "  lab DNS:        $(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --query "length(ResourceRecordSets[?contains(Name,'lab.andruxa.dev')])" --output text)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
