#!/usr/bin/env bash
# S8 — Serverless cross-region disaster recovery.
#
#   DynamoDB Global Table   us-east-1 <-> us-west-2   (data replicated both ways)
#   Lambda + HTTP API       in each region             (compute in each region)
#   ACM + custom domain     in each region             (regional certs)
#   Route 53 failover       api.lab.andruxa.dev        (DNS decides who is live)
#
# Almost all of this is Always Free. The only real cost is two Route 53 health
# checks at ~$0.50/month each — and they survive every other teardown, so they
# are deleted first.
set -euo pipefail
export MSYS_NO_PATHCONV=1

PRIMARY="us-east-1"
SECONDARY="us-west-2"
TABLE="HighAvailabilityTable"
FQDN="api.lab.andruxa.dev"
ZONE_ID="Z01678051OM322HGI9E5G"
ROLE="lab-s8-lambda-role"
FN="lab-s8-api"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

# ---------------------------------------------------- 1. Global Table --------
say "DynamoDB global table $TABLE ($PRIMARY <-> $SECONDARY)"
if ! aws dynamodb describe-table --table-name "$TABLE" --region "$PRIMARY" >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=ItemId,AttributeType=S \
    --key-schema AttributeName=ItemId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --tags Key=Lab,Value=s8 --region "$PRIMARY" >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$PRIMARY"
fi
# A global table is the SAME table with replicas — not two tables that sync.
if ! aws dynamodb describe-table --table-name "$TABLE" --region "$SECONDARY" >/dev/null 2>&1; then
  # Immediately after create-table this fails with a confusing
  # "UnrecognizedClientException: The security token ... is invalid" — DynamoDB
  # calling the second region on your behalf before the stream has propagated.
  # It is transient; retry rather than chasing credentials or the SLR.
  for _ in $(seq 1 10); do
    aws dynamodb update-table --table-name "$TABLE" --region "$PRIMARY" \
      --replica-updates "[{\"Create\":{\"RegionName\":\"$SECONDARY\"}}]" >/dev/null 2>&1 && break
    echo "      replica create rejected, retrying..."
    sleep 15
  done
  echo "    creating replica in $SECONDARY..."
  for i in $(seq 1 40); do
    st="$(aws dynamodb describe-table --table-name "$TABLE" --region "$PRIMARY" \
      --query "Table.Replicas[?RegionName=='$SECONDARY'].ReplicaStatus | [0]" --output text 2>/dev/null || echo CREATING)"
    echo "      t=$((i*15))s $st"
    [ "$st" = "ACTIVE" ] && break
    sleep 15
  done
fi
echo "    replicas: $(aws dynamodb describe-table --table-name "$TABLE" --region "$PRIMARY" --query 'Table.Replicas[].RegionName' --output text)"

# ------------------------------------------------------------- 2. IAM -------
say "IAM role $ROLE (four actions on one table, not DynamoDBFullAccess)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
cat > "$BUILD/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["dynamodb:PutItem","dynamodb:GetItem","dynamodb:UpdateItem","dynamodb:Scan"],
 "Resource":["arn:aws:dynamodb:$PRIMARY:$ACCT:table/$TABLE",
             "arn:aws:dynamodb:$SECONDARY:$ACCT:table/$TABLE"]}]}
JSON
aws iam put-role-policy --role-name "$ROLE" --policy-name TableAccess \
  --policy-document "file://$(w "$BUILD/policy.json")"
ROLE_ARN="arn:aws:iam::$ACCT:role/$ROLE"
echo "    ready"

powershell -NoProfile -Command \
  "Compress-Archive -Path '$(cygpath -w "$HERE/src")\\*' -DestinationPath '$(cygpath -w "$BUILD/fn.zip")' -Force" >/dev/null

# ------------------------------------- 3. Per-region: Lambda, API, cert ------
: > "$BUILD/regions.env"

build_region() {  # $1 region, $2 PRIMARY|SECONDARY
  local R="$1" ROLE_TAG="$2" api_id cert_arn fn_arn
  say "region $R ($ROLE_TAG)"

  if aws lambda get-function --function-name "$FN" --region "$R" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$FN" \
      --zip-file "fileb://$(w "$BUILD/fn.zip")" --region "$R" >/dev/null
    aws lambda wait function-updated --function-name "$FN" --region "$R"
    aws lambda update-function-configuration --function-name "$FN" \
      --environment "Variables={TABLE_NAME=$TABLE,REGION_ROLE=$ROLE_TAG}" --region "$R" >/dev/null
  else
    for _ in $(seq 1 12); do
      aws lambda create-function --function-name "$FN" --runtime python3.12 \
        --handler handler.handler --role "$ROLE_ARN" \
        --zip-file "fileb://$(w "$BUILD/fn.zip")" \
        --environment "Variables={TABLE_NAME=$TABLE,REGION_ROLE=$ROLE_TAG}" \
        --timeout 15 --tags Lab=s8 --region "$R" >/dev/null 2>&1 && break
      sleep 5
    done
  fi
  aws lambda wait function-updated --function-name "$FN" --region "$R"
  fn_arn="arn:aws:lambda:$R:$ACCT:function:$FN"
  echo "    lambda ready"

  api_id="$(aws apigatewayv2 get-apis --region "$R" \
    --query "Items[?Name=='lab-s8-api'].ApiId | [0]" --output text)"
  if [ "$api_id" = "None" ] || [ -z "$api_id" ]; then
    api_id="$(aws apigatewayv2 create-api --name lab-s8-api --protocol-type HTTP \
      --target "$fn_arn" --cors-configuration AllowOrigins='*',AllowMethods='*',AllowHeaders='*' \
      --region "$R" --query ApiId --output text)"
    aws lambda add-permission --function-name "$FN" --statement-id apigw \
      --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
      --source-arn "arn:aws:execute-api:$R:$ACCT:$api_id/*" --region "$R" >/dev/null 2>&1 || true
  fi
  echo "    api $api_id"

  # Regional API Gateway custom domains need a cert in their OWN region —
  # this is not the CloudFront us-east-1 rule.
  cert_arn="$(aws acm list-certificates --region "$R" \
    --query "CertificateSummaryList[?DomainName=='$FQDN'].CertificateArn | [0]" --output text)"
  if [ "$cert_arn" = "None" ] || [ -z "$cert_arn" ]; then
    cert_arn="$(aws acm request-certificate --domain-name "$FQDN" \
      --validation-method DNS --region "$R" --query CertificateArn --output text)"
    sleep 10
  fi
  echo "    cert $cert_arn"

  echo "export ${ROLE_TAG}_REGION=$R"   >> "$BUILD/regions.env"
  echo "export ${ROLE_TAG}_API=$api_id" >> "$BUILD/regions.env"
  echo "export ${ROLE_TAG}_CERT=$cert_arn" >> "$BUILD/regions.env"
}

build_region "$PRIMARY"   PRIMARY
build_region "$SECONDARY" SECONDARY
source "$BUILD/regions.env"

# --------------------------------------------- 4. Validate both certs --------
say "DNS validation records (both certs validate against the same name)"
add_validation() {  # $1 cert arn, $2 region
  local name value
  for _ in $(seq 1 20); do
    read -r name value <<< "$(aws acm describe-certificate --certificate-arn "$1" --region "$2" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text 2>/dev/null)"
    [ -n "${name:-}" ] && [ "$name" != "None" ] && break
    sleep 10
  done
  cat > "$BUILD/val.json" <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"$name","Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":"$value"}]}}]}
JSON
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://$(w "$BUILD/val.json")" >/dev/null
  echo "    $2 -> $name"
}
add_validation "$PRIMARY_CERT" "$PRIMARY"
add_validation "$SECONDARY_CERT" "$SECONDARY"

say "waiting for both certificates to issue"
for i in $(seq 1 40); do
  a="$(aws acm describe-certificate --certificate-arn "$PRIMARY_CERT" --region "$PRIMARY" --query 'Certificate.Status' --output text)"
  b="$(aws acm describe-certificate --certificate-arn "$SECONDARY_CERT" --region "$SECONDARY" --query 'Certificate.Status' --output text)"
  echo "    t=$((i*20))s $PRIMARY=$a  $SECONDARY=$b"
  [ "$a" = "ISSUED" ] && [ "$b" = "ISSUED" ] && break
  sleep 20
done

# ------------------------------------------ 5. Custom domains per region -----
say "regional custom domain $FQDN in each region"
mk_domain() {  # $1 region, $2 cert
  local tgt zone
  if ! aws apigatewayv2 get-domain-name --domain-name "$FQDN" --region "$1" >/dev/null 2>&1; then
    aws apigatewayv2 create-domain-name --domain-name "$FQDN" \
      --domain-name-configurations "CertificateArn=$2,EndpointType=REGIONAL,SecurityPolicy=TLS_1_2" \
      --region "$1" >/dev/null
  fi
  read -r tgt zone <<< "$(aws apigatewayv2 get-domain-name --domain-name "$FQDN" --region "$1" \
    --query 'DomainNameConfigurations[0].[ApiGatewayDomainName,HostedZoneId]' --output text)"
  echo "$tgt $zone"
}
read -r P_TGT P_ZONE <<< "$(mk_domain "$PRIMARY" "$PRIMARY_CERT")"
read -r S_TGT S_ZONE <<< "$(mk_domain "$SECONDARY" "$SECONDARY_CERT")"
echo "    $PRIMARY   -> $P_TGT"
echo "    $SECONDARY -> $S_TGT"

for pair in "$PRIMARY|$PRIMARY_API" "$SECONDARY|$SECONDARY_API"; do
  r="${pair%%|*}"; a="${pair##*|}"
  aws apigatewayv2 create-api-mapping --domain-name "$FQDN" --api-id "$a" \
    --stage '$default' --region "$r" >/dev/null 2>&1 || true
done
echo "    api mappings created"

cat > "$HERE/.env.generated" <<ENV
export PRIMARY=$PRIMARY
export SECONDARY=$SECONDARY
export TABLE=$TABLE
export FQDN=$FQDN
export ZONE_ID=$ZONE_ID
export PRIMARY_API=$PRIMARY_API
export SECONDARY_API=$SECONDARY_API
export PRIMARY_CERT=$PRIMARY_CERT
export SECONDARY_CERT=$SECONDARY_CERT
export P_TGT=$P_TGT
export P_ZONE=$P_ZONE
export S_TGT=$S_TGT
export S_ZONE=$S_ZONE
ENV

say "Built. Next: bash scripts/failover-dns.sh"
