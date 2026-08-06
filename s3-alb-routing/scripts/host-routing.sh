#!/usr/bin/env bash
# Swap the path-based rules for host-header rules, and point DNS at the ALB.
#
# All lab records live under lab.andruxa.dev in the existing production hosted
# zone. They are created here by hand and deleted by teardown.sh — infra/prod
# never learns about them, and Terraform does not prune records outside its own
# state, so the nightly drift check stays clean.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

DOMAIN="lab.andruxa.dev"

say "removing the path-based rules"
for arn in $(aws elbv2 describe-rules --listener-arn "$LISTENER" --region "$AWS_REGION" \
    --query "Rules[?Priority!='default'].RuleArn" --output text); do
  aws elbv2 delete-rule --rule-arn "$arn" --region "$AWS_REGION"
done
echo "    gone"

say "adding host-header rules"
add_host_rule() {  # $1 color, $2 priority, $3 tg
  aws elbv2 create-rule --listener-arn "$LISTENER" --priority "$2" \
    --conditions "Field=host-header,Values=$1.$DOMAIN" \
    --actions "Type=forward,TargetGroupArn=$3" --region "$AWS_REGION" >/dev/null
  echo "    $1.$DOMAIN -> $1 (priority $2)"
}
add_host_rule red 1 "$TG_RED"
add_host_rule blue 2 "$TG_BLUE"

say "Route 53 alias records in the andruxa.dev zone"
mk_record() {  # $1 fqdn
  cat > "$BUILD/rr.json" <<JSON
{ "Comment": "aws-labs S3 host-based routing (temporary)",
  "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": {
    "Name": "$1", "Type": "A",
    "AliasTarget": { "HostedZoneId": "$ALB_ZONE", "DNSName": "$ALB_DNS",
                     "EvaluateTargetHealth": false } } } ] }
JSON
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$(w "$BUILD/rr.json")" --query 'ChangeInfo.Status' --output text
  echo "    $1"
}
mk_record "red.$DOMAIN"
mk_record "blue.$DOMAIN"
mk_record "$DOMAIN"

say "waiting for DNS to resolve"
for i in $(seq 1 20); do
  if nslookup "red.$DOMAIN" >/dev/null 2>&1; then echo "    resolving after $((i*10))s"; break; fi
  sleep 10
done

say "Host-based routing is live"
echo "  http://red.$DOMAIN"
echo "  http://blue.$DOMAIN"
echo "  http://$DOMAIN            (no rule matches -> 404 by design)"
