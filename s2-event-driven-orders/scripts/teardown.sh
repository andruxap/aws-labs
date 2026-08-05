#!/usr/bin/env bash
# S2 teardown — deletes every resource deploy.sh creates.
# Order matters: consumers before producers. The Pipe goes first because it
# holds a poller on the main queue. Safe to run twice.
set -uo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
say() { echo ""; echo "==> $*"; }
ok()  { echo "    $*"; }

say "1/8 EventBridge Pipe"
# stop-pipe is async: delete-pipe fails while the pipe is still STOPPING, so
# wait for a settled state before deleting, then wait for the delete to finish.
if aws pipes describe-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1; then
  aws pipes stop-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1 || true
  for _ in $(seq 1 24); do
    state="$(aws pipes describe-pipe --name HighValueOrderPipe --region "$REGION" \
      --query CurrentState --output text 2>/dev/null)" || break
    case "$state" in STOPPED|RUNNING|CREATE_FAILED|UPDATE_FAILED|START_FAILED|STOP_FAILED) break;; esac
    sleep 5
  done
  aws pipes delete-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1 && ok "deleted"
  for _ in $(seq 1 24); do
    aws pipes describe-pipe --name HighValueOrderPipe --region "$REGION" >/dev/null 2>&1 || break
    sleep 5
  done
else ok "absent"; fi

say "2/8 Lambda functions (removes their event source mappings)"
for fn in CreateOrderFunction ProcessOrderFunction OrderWorkerFunction HighValueWorkerFunction; do
  for uuid in $(aws lambda list-event-source-mappings --function-name "$fn" --region "$REGION" \
      --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
    [ "$uuid" = "None" ] && continue
    aws lambda delete-event-source-mapping --uuid "$uuid" --region "$REGION" >/dev/null 2>&1 || true
  done
  aws lambda delete-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1 \
    && ok "$fn deleted" || ok "$fn absent"
done

say "3/8 API Gateway"
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='order-api'].ApiId | [0]" --output text 2>/dev/null)"
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  aws apigatewayv2 delete-api --api-id "$API_ID" --region "$REGION" && ok "order-api deleted"
else ok "absent"; fi

say "4/8 SQS queues"
for q in order-processing-queue high-value-orders-queue order-processing-dlq; do
  url="$(aws sqs get-queue-url --queue-name "$q" --region "$REGION" --query QueueUrl --output text 2>/dev/null)"
  if [ -n "$url" ] && [ "$url" != "None" ]; then
    aws sqs delete-queue --queue-url "$url" --region "$REGION" && ok "$q deleted"
  else ok "$q absent"; fi
done

say "5/8 DynamoDB table Orders (stream goes with it)"
aws dynamodb delete-table --table-name Orders --region "$REGION" >/dev/null 2>&1 && ok "deleted" || ok "absent"

say "6/8 CloudWatch alarm + Lambda log groups"
aws cloudwatch delete-alarms --alarm-names order-processing-alarm --region "$REGION" 2>/dev/null && ok "alarm deleted"
for fn in CreateOrderFunction ProcessOrderFunction OrderWorkerFunction HighValueWorkerFunction; do
  aws logs delete-log-group --log-group-name "/aws/lambda/$fn" --region "$REGION" >/dev/null 2>&1 \
    && ok "log group $fn deleted"
done

say "7/8 SNS"
TOPIC_ARN="arn:aws:sns:$REGION:$ACCOUNT_ID:order-processing-alerts"
for sub in $(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$REGION" \
    --query 'Subscriptions[].SubscriptionArn' --output text 2>/dev/null); do
  case "$sub" in arn:*) aws sns unsubscribe --subscription-arn "$sub" --region "$REGION" 2>/dev/null && ok "unsubscribed";; esac
done
aws sns delete-topic --topic-arn "$TOPIC_ARN" --region "$REGION" 2>/dev/null && ok "topic deleted"

say "8/8 IAM roles"
aws iam delete-role-policy --role-name OrderServiceLambdaRole --policy-name OrderServiceAccess 2>/dev/null
aws iam detach-role-policy --role-name OrderServiceLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
aws iam delete-role --role-name OrderServiceLambdaRole 2>/dev/null && ok "OrderServiceLambdaRole deleted"
aws iam delete-role-policy --role-name HighValueOrderPipeRole --policy-name PipeSqsAccess 2>/dev/null
aws iam delete-role --role-name HighValueOrderPipeRole 2>/dev/null && ok "HighValueOrderPipeRole deleted"

say "9/9 fan-out fix resources (scripts/fix-race.sh)"
url="$(aws sqs get-queue-url --queue-name pipe-source-queue --region "$REGION" --query QueueUrl --output text 2>/dev/null)"
if [ -n "$url" ] && [ "$url" != "None" ]; then
  aws sqs delete-queue --queue-url "$url" --region "$REGION" && ok "pipe-source-queue deleted"
fi
aws sns delete-topic --topic-arn "arn:aws:sns:$REGION:$ACCOUNT_ID:order-events" --region "$REGION" 2>/dev/null && ok "order-events deleted"
aws iam delete-role-policy --role-name OrderServiceLambdaRole --policy-name OrderEventsPublish 2>/dev/null
aws iam delete-role --role-name OrderServiceLambdaRole 2>/dev/null && ok "OrderServiceLambdaRole deleted"

say "Verify nothing is left"
echo "  lambdas:  $(aws lambda list-functions --region "$REGION" --query "length(Functions[?contains(FunctionName,'Order')])" --output text)"
echo "  queues:   $(aws sqs list-queues --region "$REGION" --query 'length(QueueUrls)' --output text 2>/dev/null || echo 0)"
echo "  pipes:    $(aws pipes list-pipes --region "$REGION" --query 'length(Pipes)' --output text 2>/dev/null || echo 0)"
echo ""
echo "Teardown complete. Check Billing tomorrow morning to confirm no ongoing charge."

