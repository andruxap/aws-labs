#!/usr/bin/env bash
# Session 0 — account-wide cost guardrail.
#
# The andruxa.dev AWS Budget (infra/prod/budget.tf, $5/mo) updates roughly daily.
# These CloudWatch billing alarms fire within hours, which is what you want while
# clicking through labs. Billing metrics only exist in us-east-1.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="us-east-1"   # billing metrics live nowhere else
EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL to the address that should receive alerts}"
TOPIC="billing-alerts"

TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --region "$REGION" --query TopicArn --output text)"
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$REGION" \
     --query "Subscriptions[?Endpoint=='$EMAIL']" --output text | grep -q .; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
    --notification-endpoint "$EMAIL" --region "$REGION" >/dev/null
  echo "Subscription created for $EMAIL — confirm it from your inbox."
fi

for threshold in 10 25; do
  aws cloudwatch put-metric-alarm \
    --alarm-name "billing-estimated-charges-over-${threshold}usd" \
    --alarm-description "Estimated AWS charges exceeded \$${threshold} this month" \
    --namespace AWS/Billing --metric-name EstimatedCharges \
    --dimensions Name=Currency,Value=USD \
    --statistic Maximum --period 21600 --evaluation-periods 1 \
    --threshold "$threshold" --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN" --region "$REGION"
  echo "alarm at \$${threshold} created"
done

echo ""
echo "Note: AWS/Billing metrics only publish if 'Receive Billing Alerts' is enabled"
echo "in Billing -> Billing preferences. Enable it once, in the console."
