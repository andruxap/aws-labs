#!/usr/bin/env bash
# Rolling deployment: publish a new launch template version, point the ASG at
# it, and let Instance Refresh replace the fleet in place while it serves.
#
# This is the other half of the lesson. Blue/green swaps between two full
# environments (double capacity, instant switch back). A rolling refresh keeps
# one environment and replaces its instances gradually — cheaper, slower,
# and rollback means rolling forward again.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"
ASG="lab-s4-blue-asg"
NEW_VERSION="${1:-v1.1}"

w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$AWS_REGION" --query 'Parameter.Value' --output text)"

say "publishing launch template version for BLUE $NEW_VERSION"
sed -e "s|__ENVIRONMENT__|BLUE|g" -e "s|__APP_VERSION__|$NEW_VERSION|g" \
  "$HERE/user-data/app.sh" > "$BUILD/ud.sh"
B64="$(base64 -w0 < "$BUILD/ud.sh")"
cat > "$BUILD/lt-data.json" <<JSON
{
  "ImageId": "$AMI",
  "InstanceType": "t3.micro",
  "IamInstanceProfile": { "Name": "lab-s4-ec2-role" },
  "SecurityGroupIds": ["$SG_ID"],
  "UserData": "$B64",
  "TagSpecifications": [{ "ResourceType": "instance",
    "Tags": [{"Key":"Lab","Value":"s4"},{"Key":"Env","Value":"BLUE"},{"Key":"AppVersion","Value":"$NEW_VERSION"}] }]
}
JSON
VER="$(aws ec2 create-launch-template-version --launch-template-name "$LT" \
  --version-description "BLUE-$NEW_VERSION" --launch-template-data "file://$(w "$BUILD/lt-data.json")" \
  --region "$AWS_REGION" --query 'LaunchTemplateVersion.VersionNumber' --output text)"
echo "    version $VER"

say "pointing $ASG at version $VER"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --launch-template "LaunchTemplateName=$LT,Version=$VER" --region "$AWS_REGION"
echo "    done — existing instances still run the OLD version until refreshed"
echo "    serving now: $(curl -s -m 5 "http://$ALB_DNS/whoami.txt")"

say "starting instance refresh (MinHealthyPercentage=50, so it replaces one at a time)"
ID="$(aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG" \
  --preferences 'MinHealthyPercentage=50,InstanceWarmup=60' \
  --region "$AWS_REGION" --query InstanceRefreshId --output text)"
echo "    refresh $ID"

say "watching (the console lies about progress; describe-instance-refreshes does not)"
LOSS="$BUILD/refresh-poll.log"; : > "$LOSS"
for i in $(seq 1 60); do
  out="$(curl -s -m 3 -w '|%{http_code}' "http://$ALB_DNS/whoami.txt" 2>/dev/null)"
  echo "${out##*|} $(echo "${out%%|*}" | awk '{print $2}')" >> "$LOSS"
  read -r STATUS PCT <<< "$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG" --instance-refresh-ids "$ID" --region "$AWS_REGION" \
    --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text)"
  echo "    t=$((i*10))s  $STATUS ${PCT:-0}%   serving: $(tail -1 "$LOSS")"
  case "$STATUS" in Successful|Failed|Cancelled) break;; esac
  sleep 10
done

echo ""
echo "  requests during refresh : $(wc -l < "$LOSS")"
echo "  HTTP 200                : $(grep -c '^200 ' "$LOSS")"
echo "  failed / non-200        : $(grep -vc '^200 ' "$LOSS")"
echo "  versions observed       : $(awk '{print $2}' "$LOSS" | sort -u | tr '\n' ' ')"
echo ""
echo "final: $(curl -s -m 5 "http://$ALB_DNS/whoami.txt")"
