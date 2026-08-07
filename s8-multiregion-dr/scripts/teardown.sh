#!/usr/bin/env bash
# S8 teardown, both regions.
#
# Route 53 HEALTH CHECKS go first. They are the only thing here that bills
# monthly (~$0.50 each), they are global so they appear in no regional view,
# and they outlive every other resource. A DNS record cannot be deleted while
# it references a health check, so records go before the checks themselves.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
PRIMARY="us-east-1"; SECONDARY="us-west-2"
TABLE="HighAvailabilityTable"; FQDN="api.lab.andruxa.dev"
ZONE_ID="Z01678051OM322HGI9E5G"; FN="lab-s8-api"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/8 Route 53 failover records (must go before the health checks)"
for setid in PRIMARY SECONDARY; do
  rr="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$FQDN.' && SetIdentifier=='$setid'] | [0]" --output json 2>/dev/null)"
  [ "$rr" = "null" ] || [ -z "$rr" ] && { ok "$setid absent"; continue; }
  printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$rr" > "$BUILD/del.json"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$(w "$BUILD/del.json")" >/dev/null 2>&1 && ok "$setid deleted"
done

say "2/8 ACM validation CNAME"
rr="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='CNAME' && contains(Name,'$FQDN')] | [0]" --output json 2>/dev/null)"
if [ "$rr" != "null" ] && [ -n "$rr" ]; then
  printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$rr" > "$BUILD/del.json"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$(w "$BUILD/del.json")" >/dev/null 2>&1 && ok "validation record deleted"
else ok "absent"; fi

say "3/8 health checks (the monthly biller)"
for id in $(aws route53 list-health-checks \
    --query "HealthChecks[?contains(HealthCheckConfig.FullyQualifiedDomainName,'execute-api')].Id" --output text); do
  aws route53 delete-health-check --health-check-id "$id" 2>/dev/null && ok "$id deleted"
done

say "4/8 API Gateway custom domains + APIs, both regions"
for R in "$PRIMARY" "$SECONDARY"; do
  for mid in $(aws apigatewayv2 get-api-mappings --domain-name "$FQDN" --region "$R" \
      --query 'Items[].ApiMappingId' --output text 2>/dev/null); do
    aws apigatewayv2 delete-api-mapping --api-mapping-id "$mid" --domain-name "$FQDN" --region "$R" 2>/dev/null
  done
  aws apigatewayv2 delete-domain-name --domain-name "$FQDN" --region "$R" 2>/dev/null && ok "$R domain deleted"
  aid="$(aws apigatewayv2 get-apis --region "$R" --query "Items[?Name=='lab-s8-api'].ApiId | [0]" --output text)"
  [ "$aid" != "None" ] && [ -n "$aid" ] && \
    aws apigatewayv2 delete-api --api-id "$aid" --region "$R" 2>/dev/null && ok "$R api deleted"
done

say "5/8 Lambda + log groups, both regions"
for R in "$PRIMARY" "$SECONDARY"; do
  aws lambda delete-function --function-name "$FN" --region "$R" 2>/dev/null && ok "$R lambda deleted"
  aws logs delete-log-group --log-group-name "/aws/lambda/$FN" --region "$R" 2>/dev/null && ok "$R logs deleted"
done

say "6/8 ACM certificates, both regions"
for R in "$PRIMARY" "$SECONDARY"; do
  for arn in $(aws acm list-certificates --region "$R" \
      --query "CertificateSummaryList[?DomainName=='$FQDN'].CertificateArn" --output text); do
    for _ in $(seq 1 10); do
      aws acm delete-certificate --certificate-arn "$arn" --region "$R" 2>/dev/null && { ok "$R cert deleted"; break; }
      sleep 10   # in-use association lingers after the domain name is deleted
    done
  done
done

say "7/8 DynamoDB global table (delete the replica, then the table)"
if aws dynamodb describe-table --table-name "$TABLE" --region "$PRIMARY" >/dev/null 2>&1; then
  if aws dynamodb describe-table --table-name "$TABLE" --region "$SECONDARY" >/dev/null 2>&1; then
    aws dynamodb update-table --table-name "$TABLE" --region "$PRIMARY" \
      --replica-updates "[{\"Delete\":{\"RegionName\":\"$SECONDARY\"}}]" >/dev/null 2>&1 && ok "replica removal started"
    for _ in $(seq 1 40); do
      aws dynamodb describe-table --table-name "$TABLE" --region "$SECONDARY" >/dev/null 2>&1 || { ok "replica gone"; break; }
      sleep 15
    done
  fi
  for _ in $(seq 1 20); do
    aws dynamodb delete-table --table-name "$TABLE" --region "$PRIMARY" >/dev/null 2>&1 && { ok "table deleted"; break; }
    sleep 15
  done
else ok "absent"; fi

say "8/8 IAM"
aws iam delete-role-policy --role-name lab-s8-lambda-role --policy-name TableAccess 2>/dev/null
aws iam detach-role-policy --role-name lab-s8-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
aws iam delete-role --role-name lab-s8-lambda-role 2>/dev/null && ok "role deleted"

say "verify"
echo "  health checks:     $(aws route53 list-health-checks --query 'length(HealthChecks)' --output text)"
echo "  lab DNS records:   $(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --query "length(ResourceRecordSets[?contains(Name,'lab.andruxa.dev')])" --output text)"
for R in "$PRIMARY" "$SECONDARY"; do
  echo "  $R  apis=$(aws apigatewayv2 get-apis --region "$R" --query "length(Items[?Name=='lab-s8-api'])" --output text) lambdas=$(aws lambda list-functions --region "$R" --query "length(Functions[?FunctionName=='$FN'])" --output text) tables=$(aws dynamodb list-tables --region "$R" --query "length(TableNames[?@=='$TABLE'])" --output text) certs=$(aws acm list-certificates --region "$R" --query "length(CertificateSummaryList[?DomainName=='$FQDN'])" --output text)"
done
echo ""
echo "Teardown complete. Check Billing tomorrow morning."
