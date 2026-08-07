#!/usr/bin/env bash
# S2 — Event-Driven Order Processing System
# Creates all 12 resources. Idempotent: safe to re-run.
# Teardown: scripts/teardown.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash rewrites /aws/lambda/... into a Windows path

REGION="${AWS_REGION:-us-east-1}"
ALERT_EMAIL="${ALERT_EMAIL:-$ALERT_EMAIL}"
RUNTIME="nodejs22.x"

TABLE="Orders"
ROLE="OrderServiceLambdaRole"
PIPE_ROLE="HighValueOrderPipeRole"
DLQ="order-processing-dlq"
QUEUE="order-processing-queue"
HV_QUEUE="high-value-orders-queue"
API="order-api"
PIPE="HighValueOrderPipe"
ALARM="order-processing-alarm"
TOPIC="order-processing-alerts"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"
mkdir -p "$BUILD"
ENV_OUT="$HERE/.env.generated"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# The AWS CLI is a native Windows binary: file:// args need C:/... not /c/...
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
# Retry a command, PRESERVING its stdout. The original version piped every
# attempt to /dev/null, so `x="$(retry 12 aws ec2 run-instances ...)"` came back
# empty while the instance really had launched — a silent duplicate-resource
# trap. Capture the output and replay it instead.
retry() {
  local n=0 max="$1"; shift
  local out
  while :; do
    if out="$("$@" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
    n=$((n+1))
    if [ "$n" -ge "$max" ]; then "$@"; return 1; fi   # last try: let errors show
    sleep 5
  done
}

say "Account $ACCOUNT_ID / region $REGION"

# ---------------------------------------------------------------- 1. SNS ----
say "SNS topic $TOPIC"
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --region "$REGION" --query TopicArn --output text)"
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$REGION" \
     --query "Subscriptions[?Endpoint=='$ALERT_EMAIL']" --output text | grep -q .; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" \
    --region "$REGION" >/dev/null
  echo "    subscription created — CONFIRM THE EMAIL or no alerts will arrive"
fi

# ----------------------------------------------------------- 2. DynamoDB ----
say "DynamoDB table $TABLE (on-demand, streams NEW_AND_OLD_IMAGES)"
if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=orderId,AttributeType=S \
    --key-schema AttributeName=orderId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --region "$REGION" >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
fi
STREAM_ARN="$(aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" \
  --query 'Table.LatestStreamArn' --output text)"
echo "    stream: $STREAM_ARN"

# ----------------------------------------------------------------- 3. IAM ---
say "IAM role $ROLE (least-privilege, not the course's *FullAccess)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document "file://$(w "$HERE/policies/lambda-trust.json")" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > "$BUILD/lambda-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "OrdersTableAccess", "Effect": "Allow",
      "Action": ["dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:GetItem"],
      "Resource": "arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$TABLE" },
    { "Sid": "OrdersStreamRead", "Effect": "Allow",
      "Action": ["dynamodb:DescribeStream","dynamodb:GetRecords","dynamodb:GetShardIterator","dynamodb:ListStreams"],
      "Resource": "arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$TABLE/stream/*" },
    { "Sid": "QueueAccess", "Effect": "Allow",
      "Action": ["sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
      "Resource": [
        "arn:aws:sqs:$REGION:$ACCOUNT_ID:$QUEUE",
        "arn:aws:sqs:$REGION:$ACCOUNT_ID:$HV_QUEUE",
        "arn:aws:sqs:$REGION:$ACCOUNT_ID:$DLQ"
      ] }
  ]
}
JSON
aws iam put-role-policy --role-name "$ROLE" --policy-name OrderServiceAccess \
  --policy-document "file://$(w "$BUILD/lambda-policy.json")"
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE"

# ----------------------------------------------------------------- 4. SQS ---
say "SQS queues"
aws sqs create-queue --queue-name "$DLQ" --region "$REGION" >/dev/null
DLQ_URL="$(aws sqs get-queue-url --queue-name "$DLQ" --region "$REGION" --query QueueUrl --output text)"
DLQ_ARN="$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn \
  --region "$REGION" --query 'Attributes.QueueArn' --output text)"

aws sqs create-queue --queue-name "$QUEUE" --region "$REGION" >/dev/null
QUEUE_URL="$(aws sqs get-queue-url --queue-name "$QUEUE" --region "$REGION" --query QueueUrl --output text)"
printf '{"RedrivePolicy":"{\\"deadLetterTargetArn\\":\\"%s\\",\\"maxReceiveCount\\":\\"3\\"}"}' "$DLQ_ARN" \
  > "$BUILD/redrive.json"
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" \
  --attributes "file://$(w "$BUILD/redrive.json")" --region "$REGION"
QUEUE_ARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn \
  --region "$REGION" --query 'Attributes.QueueArn' --output text)"

aws sqs create-queue --queue-name "$HV_QUEUE" --region "$REGION" >/dev/null
HV_URL="$(aws sqs get-queue-url --queue-name "$HV_QUEUE" --region "$REGION" --query QueueUrl --output text)"
HV_ARN="$(aws sqs get-queue-attributes --queue-url "$HV_URL" --attribute-names QueueArn \
  --region "$REGION" --query 'Attributes.QueueArn' --output text)"
echo "    main=$QUEUE_ARN"
echo "    dlq=$DLQ_ARN  (maxReceiveCount 3)"
echo "    high-value=$HV_ARN"

# ------------------------------------------------------------- 5. Lambdas ---
zip_fn() {  # no `zip` binary on this box — PowerShell does it
  local fn="$1" src dst
  src="$(cygpath -w "$HERE/src/$fn")"; dst="$(cygpath -w "$BUILD/$fn.zip")"
  powershell -NoProfile -Command \
    "Compress-Archive -Path '$src\\*' -DestinationPath '$dst' -Force" >/dev/null
}

deploy_fn() {
  local fn="$1" envs="$2"
  zip_fn "$fn"
  if aws lambda get-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$fn" \
      --zip-file "fileb://$(w "$BUILD/$fn.zip")" --region "$REGION" >/dev/null
    aws lambda wait function-updated --function-name "$fn" --region "$REGION"
    aws lambda update-function-configuration --function-name "$fn" \
      --environment "$envs" --region "$REGION" >/dev/null
  else
    retry 12 aws lambda create-function --function-name "$fn" \
      --runtime "$RUNTIME" --handler index.handler --role "$ROLE_ARN" \
      --zip-file "fileb://$(w "$BUILD/$fn.zip")" --environment "$envs" \
      --timeout 30 --region "$REGION"
  fi
  aws lambda wait function-updated --function-name "$fn" --region "$REGION"
  echo "    $fn deployed"
}

say "Lambda functions"
deploy_fn CreateOrderFunction      "Variables={ORDERS_TABLE_NAME=$TABLE}"
deploy_fn ProcessOrderFunction     "Variables={ORDERS_TABLE_NAME=$TABLE,ORDER_QUEUE_URL=$QUEUE_URL}"
deploy_fn OrderWorkerFunction      "Variables={ORDERS_TABLE_NAME=$TABLE}"
deploy_fn HighValueWorkerFunction  "Variables={ORDERS_TABLE_NAME=$TABLE}"

# --------------------------------------------------- 6. Event source maps ---
map() {  # $1 source arn, $2 function, $3 batch size, [$4 starting position]
  local existing
  existing="$(aws lambda list-event-source-mappings --function-name "$2" \
    --event-source-arn "$1" --region "$REGION" --query 'EventSourceMappings[0].UUID' --output text)"
  if [ "$existing" = "None" ] || [ -z "$existing" ]; then
    if [ -n "${4:-}" ]; then
      retry 12 aws lambda create-event-source-mapping --event-source-arn "$1" \
        --function-name "$2" --batch-size "$3" --starting-position "$4" --region "$REGION"
    else
      retry 12 aws lambda create-event-source-mapping --event-source-arn "$1" \
        --function-name "$2" --batch-size "$3" --region "$REGION"
    fi
    echo "    $2 <- $(basename "$1")"
  else
    echo "    $2 mapping already exists"
  fi
}

say "Event source mappings"
map "$STREAM_ARN" ProcessOrderFunction 5 LATEST
map "$QUEUE_ARN"  OrderWorkerFunction 5
map "$HV_ARN"     HighValueWorkerFunction 5

# --------------------------------------------------------- 7. API Gateway ---
say "HTTP API $API"
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='$API'].ApiId | [0]" --output text)"
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  API_ID="$(aws apigatewayv2 create-api --name "$API" --protocol-type HTTP \
    --cors-configuration AllowOrigins='*',AllowMethods='*',AllowHeaders='*' \
    --region "$REGION" --query ApiId --output text)"
fi
CREATE_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:CreateOrderFunction"
INT_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query 'Items[0].IntegrationId | [0]' --output text 2>/dev/null || echo None)"
if [ "$INT_ID" = "None" ] || [ -z "$INT_ID" ]; then
  INT_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$CREATE_ARN" \
    --payload-format-version 2.0 --region "$REGION" --query IntegrationId --output text)"
fi
if ! aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
     --query "Items[?RouteKey=='POST /order']" --output text | grep -q .; then
  aws apigatewayv2 create-route --api-id "$API_ID" --route-key "POST /order" \
    --target "integrations/$INT_ID" --region "$REGION" >/dev/null
fi
if ! aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name prod --region "$REGION" >/dev/null 2>&1; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name prod \
    --auto-deploy --region "$REGION" >/dev/null
fi
aws lambda add-permission --function-name CreateOrderFunction \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/order" \
  --region "$REGION" >/dev/null 2>&1 || true
API_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/prod/order"
echo "    $API_URL"

# --------------------------------------------------- 8. EventBridge Pipe ----
say "EventBridge Pipe $PIPE"
sed "s/ACCOUNT_ID/$ACCOUNT_ID/" "$HERE/policies/pipes-trust.json" > "$BUILD/pipes-trust.json"
if ! aws iam get-role --role-name "$PIPE_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$PIPE_ROLE" \
    --assume-role-policy-document "file://$(w "$BUILD/pipes-trust.json")" >/dev/null
fi
cat > "$BUILD/pipes-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
      "Resource": "$QUEUE_ARN" },
    { "Effect": "Allow", "Action": ["sqs:SendMessage"], "Resource": "$HV_ARN" }
  ]
}
JSON
aws iam put-role-policy --role-name "$PIPE_ROLE" --policy-name PipeSqsAccess \
  --policy-document "file://$(w "$BUILD/pipes-policy.json")"

cat > "$BUILD/pipe-source.json" <<'JSON'
{"FilterCriteria":{"Filters":[{"Pattern":"{\"body\":{\"amount\":[{\"numeric\":[\">\",10000]}]}}"}]}}
JSON
# routedAt uses the Pipes reserved variable — the course's transformer omits it
cat > "$BUILD/pipe-target.json" <<'JSON'
{"InputTemplate":"{\"orderId\": <$.body.orderId>, \"amount\": <$.body.amount>, \"product\": <$.body.product>, \"priority\": \"HIGH_VALUE\", \"routedAt\": <aws.pipes.event.ingestion-time>}"}
JSON

if ! aws pipes describe-pipe --name "$PIPE" --region "$REGION" >/dev/null 2>&1; then
  retry 12 aws pipes create-pipe --name "$PIPE" \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$PIPE_ROLE" \
    --source "$QUEUE_ARN" --target "$HV_ARN" \
    --source-parameters "file://$(w "$BUILD/pipe-source.json")" \
    --target-parameters "file://$(w "$BUILD/pipe-target.json")" \
    --region "$REGION"
  echo "    created"
else
  echo "    already exists"
fi

# ------------------------------------------------------- 9. CloudWatch -----
say "CloudWatch alarm $ALARM"
aws cloudwatch put-metric-alarm --alarm-name "$ALARM" \
  --alarm-description "Any message in the order-processing DLQ means something is broken" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions "Name=QueueName,Value=$DLQ" \
  --statistic Maximum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" --region "$REGION"

# ------------------------------------------------------------- outputs -----
cat > "$ENV_OUT" <<ENV
# generated by deploy.sh — gitignored, contains account-specific values
export AWS_REGION=$REGION
export API_URL=$API_URL
export QUEUE_URL=$QUEUE_URL
export DLQ_URL=$DLQ_URL
export HV_URL=$HV_URL
export TOPIC_ARN=$TOPIC_ARN
ENV

say "Done. Endpoint: $API_URL"
echo "Values written to .env.generated (gitignored)."
echo "Confirm the SNS subscription email before testing the alarm."
