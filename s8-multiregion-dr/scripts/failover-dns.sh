#!/usr/bin/env bash
# S8 step 2 — Route 53 health checks + failover records.
#
# Alias records pointing at API Gateway regional domains cannot use
# EvaluateTargetHealth, so each record carries an EXPLICIT health check. The
# health checks target the execute-api hostname directly (not the custom domain)
# because a health check sends the FQDN it is configured with as the Host
# header, and the custom domain would reject an unexpected one.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

mk_hc() {  # $1 label, $2 fqdn -> health check id
  local existing id
  existing="$(aws route53 list-health-checks \
    --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='$2'].Id | [0]" --output text)"
  if [ "$existing" != "None" ] && [ -n "$existing" ]; then echo "$existing"; return; fi
  cat > "$BUILD/hc.json" <<JSON
{"Type":"HTTPS","FullyQualifiedDomainName":"$2","Port":443,"ResourcePath":"/",
 "RequestInterval":30,"FailureThreshold":2,"MeasureLatency":false}
JSON
  id="$(aws route53 create-health-check --caller-reference "lab-s8-$1-$(date +%s)" \
    --health-check-config "file://$(w "$BUILD/hc.json")" \
    --query 'HealthCheck.Id' --output text)"
  aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$id" \
    --add-tags "Key=Name,Value=lab-s8-$1" "Key=Lab,Value=s8" >/dev/null
  echo "$id"
}

say "health checks (~\$0.50/month each — deleted first at teardown)"
HC_P="$(mk_hc primary   "$PRIMARY_API.execute-api.$PRIMARY.amazonaws.com")"
HC_S="$(mk_hc secondary "$SECONDARY_API.execute-api.$SECONDARY.amazonaws.com")"
echo "    primary=$HC_P  secondary=$HC_S"

say "failover records for $FQDN"
mk_record() {  # $1 PRIMARY|SECONDARY, $2 alias target, $3 alias zone, $4 hc id
  cat > "$BUILD/rr.json" <<JSON
{"Comment":"aws-labs S8 failover","Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"$FQDN","Type":"A","SetIdentifier":"$1","Failover":"$1",
  "HealthCheckId":"$4",
  "AliasTarget":{"HostedZoneId":"$3","DNSName":"$2","EvaluateTargetHealth":false}}}]}
JSON
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$(w "$BUILD/rr.json")" --query 'ChangeInfo.Status' --output text
  echo "    $1 -> $2"
}
mk_record PRIMARY   "$P_TGT" "$P_ZONE" "$HC_P"
mk_record SECONDARY "$S_TGT" "$S_ZONE" "$HC_S"

cat >> "$HERE/.env.generated" <<ENV
export HC_P=$HC_P
export HC_S=$HC_S
ENV

say "waiting for both health checks to report healthy"
for i in $(seq 1 30); do
  a="$(aws route53 get-health-check-status --health-check-id "$HC_P" \
    --query 'HealthCheckObservations[0].StatusReport.Status' --output text 2>/dev/null || echo pending)"
  b="$(aws route53 get-health-check-status --health-check-id "$HC_S" \
    --query 'HealthCheckObservations[0].StatusReport.Status' --output text 2>/dev/null || echo pending)"
  echo "    t=$((i*20))s primary=${a:0:30} secondary=${b:0:30}"
  case "$a$b" in *Success*Success*) break;; esac
  sleep 20
done

# ------------------------------------------------------------- alarming ----
# No canary needed. These health checks already probe both regions every 30s
# and publish HealthCheckStatus — paying a second mechanism to ask the same
# question would be waste. The metric is only emitted in us-east-1, whatever
# region the endpoint lives in.
#
# Alarm on the PRIMARY only. The secondary going unhealthy while the primary
# serves is not a user-visible outage, and alarming on it would page for a
# condition nobody needs to act on at 2am.
say "alarm on the primary health check"
ALERT_EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL to the address that should receive alerts}"
TOPIC_ARN="$(aws sns create-topic --name lab-demo-alerts --region us-east-1 \
  --query TopicArn --output text)"
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region us-east-1 \
     --query "Subscriptions[?Endpoint=='$ALERT_EMAIL']" --output text | grep -q .; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
    --notification-endpoint "$ALERT_EMAIL" --region us-east-1 >/dev/null
  echo "    subscription created — CONFIRM THE EMAIL or no alert will arrive"
fi

aws cloudwatch put-metric-alarm \
  --alarm-name lab-s8-primary-unhealthy \
  --alarm-description "api.lab.andruxa.dev primary is failing its health check. Its page claims status: live — see docs/runbook-live-demos.md in resume_website." \
  --namespace AWS/Route53 --metric-name HealthCheckStatus \
  --dimensions "Name=HealthCheckId,Value=$HC_P" \
  --statistic Minimum --period 60 --evaluation-periods 2 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN" \
  --region us-east-1
echo "    lab-s8-primary-unhealthy armed (2 x 60s below healthy)"

say "https://$FQDN is live"
