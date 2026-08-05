#!/usr/bin/env bash
# Fixes the Pipe/worker race that deploy.sh reproduces.
#
# Problem: the course puts the EventBridge Pipe and OrderWorkerFunction on the
# SAME queue. Both are pollers, so each message goes to exactly one of them —
# and a Pipe DELETES the messages its filter rejects. The worker starves.
#
# Fix (SNS fan-out): ProcessOrderFunction publishes to an SNS topic. The worker
# queue and a new pipe-source-queue each subscribe, so both consumers get their
# own copy of every message and neither can starve the other.
#
#   before:  ProcessOrder -> order-processing-queue -> { worker | pipe }   (race)
#   after:   ProcessOrder -> order-events (SNS) -+-> order-processing-queue -> worker
#                                                +-> pipe-source-queue     -> pipe -> high-value-queue
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }
retry() { local n=0 max="$1"; shift; until "$@" >/dev/null 2>&1; do n=$((n+1)); [ "$n" -ge "$max" ] && { "$@"; return 1; }; sleep 5; done; }

EVENTS_TOPIC="order-events"
PIPE_QUEUE="pipe-source-queue"
QUEUE="order-processing-queue"
HV_QUEUE="high-value-orders-queue"

say "SNS topic $EVENTS_TOPIC"
EVENTS_ARN="$(aws sns create-topic --name "$EVENTS_TOPIC" --region "$REGION" --query TopicArn --output text)"

say "SQS queue $PIPE_QUEUE"
aws sqs create-queue --queue-name "$PIPE_QUEUE" --region "$REGION" >/dev/null
PIPE_URL="$(aws sqs get-queue-url --queue-name "$PIPE_QUEUE" --region "$REGION" --query QueueUrl --output text)"
PIPE_ARN="$(aws sqs get-queue-attributes --queue-url "$PIPE_URL" --attribute-names QueueArn --region "$REGION" --query 'Attributes.QueueArn' --output text)"
QUEUE_URL="$(aws sqs get-queue-url --queue-name "$QUEUE" --region "$REGION" --query QueueUrl --output text)"
QUEUE_ARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --region "$REGION" --query 'Attributes.QueueArn' --output text)"
HV_ARN="arn:aws:sqs:$REGION:$ACCOUNT_ID:$HV_QUEUE"

say "Queue policies: let SNS deliver into both queues"
for pair in "$QUEUE_URL|$QUEUE_ARN" "$PIPE_URL|$PIPE_ARN"; do
  url="${pair%%|*}"; arn="${pair##*|}"
  cat > "$BUILD/qpolicy.json" <<JSON
{"Policy":"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"$arn\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"$EVENTS_ARN\"}}}]}"}
JSON
  aws sqs set-queue-attributes --queue-url "$url" --attributes "file://$(w "$BUILD/qpolicy.json")" --region "$REGION"
  echo "    $(basename "$arn")"
done

say "Subscriptions (RawMessageDelivery=true so the body stays the original JSON)"
for arn in "$QUEUE_ARN" "$PIPE_ARN"; do
  sub="$(aws sns list-subscriptions-by-topic --topic-arn "$EVENTS_ARN" --region "$REGION" \
    --query "Subscriptions[?Endpoint=='$arn'].SubscriptionArn | [0]" --output text)"
  if [ "$sub" = "None" ] || [ -z "$sub" ]; then
    sub="$(aws sns subscribe --topic-arn "$EVENTS_ARN" --protocol sqs \
      --notification-endpoint "$arn" --region "$REGION" --query SubscriptionArn --output text)"
  fi
  aws sns set-subscription-attributes --subscription-arn "$sub" \
    --attribute-name RawMessageDelivery --attribute-value true --region "$REGION"
  echo "    $(basename "$arn") subscribed"
done

say "Grant ProcessOrderFunction sns:Publish"
cat > "$BUILD/publish-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sns:Publish","Resource":"$EVENTS_ARN"}]}
JSON
aws iam put-role-policy --role-name OrderServiceLambdaRole --policy-name OrderEventsPublish \
  --policy-document "file://$(w "$BUILD/publish-policy.json")"

say "Point ProcessOrderFunction at the topic"
aws lambda update-function-configuration --function-name ProcessOrderFunction \
  --environment "Variables={ORDERS_TABLE_NAME=Orders,ORDER_QUEUE_URL=$QUEUE_URL,ORDER_TOPIC_ARN=$EVENTS_ARN}" \
  --region "$REGION" >/dev/null
aws lambda wait function-updated --function-name ProcessOrderFunction --region "$REGION"

say "Recreate the Pipe against $PIPE_QUEUE (a pipe's source is immutable)"
if aws pipes describe-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1; then
  aws pipes stop-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1 || true
  aws pipes delete-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null
  until ! aws pipes describe-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1; do sleep 5; done
fi
cat > "$BUILD/pipes-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
      "Resource": "$PIPE_ARN" },
    { "Effect": "Allow", "Action": ["sqs:SendMessage"], "Resource": "$HV_ARN" }
  ]
}
JSON
aws iam put-role-policy --role-name HighValueOrderPipeRole --policy-name PipeSqsAccess \
  --policy-document "file://$(w "$BUILD/pipes-policy.json")"

retry 12 aws pipes create-pipe --name HighValueOrderPipe \
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/HighValueOrderPipeRole" \
  --source "$PIPE_ARN" --target "$HV_ARN" \
  --source-parameters "file://$(w "$BUILD/pipe-source.json")" \
  --target-parameters "file://$(w "$BUILD/pipe-target.json")" \
  --region "$REGION"

cat >> "$HERE/.env.generated" <<ENV
export EVENTS_ARN=$EVENTS_ARN
export PIPE_URL=$PIPE_URL
ENV

say "Done. Worker and Pipe now have independent copies of every order."
