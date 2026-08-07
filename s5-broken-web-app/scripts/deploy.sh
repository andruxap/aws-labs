#!/usr/bin/env bash
# S5 — deploy the broken web app challenge stack.
#
# us-east-1 is mandatory; the template hardcodes region-specific values.
#
# Do NOT read the template before the site returns 200. It is the answer key,
# and reading it turns a debugging exercise into a diffing exercise.
set -euo pipefail
export MSYS_NO_PATHCONV=1
REGION="us-east-1"
STACK="${1:-andrey}"
URL="https://cloud-mastery-bootcamp.s3.amazonaws.com/lab-guides/solutions-architecture/broken-web-app-challenge.json"

echo "==> creating stack $STACK in $REGION"
aws cloudformation create-stack --stack-name "$STACK" --template-url "$URL" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --region "$REGION" \
  --query StackId --output text

for i in $(seq 1 40); do
  s="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"
  echo "    t=$((i*15))s $s"
  case "$s" in CREATE_COMPLETE|CREATE_FAILED|ROLLBACK_*) break;; esac
  sleep 15
done

echo ""
aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs' --output table

echo ""
echo "The site is broken by design. Start here and work outside-in:"
echo "  curl -m 15 -w '\\nHTTP %{http_code}\\n' <the URL above>"
echo ""
echo "  HTTP 000 -> nothing routable is listening: subnets, SG, scheme"
echo "  HTTP 503 -> ALB is fine; no healthy target"
echo "  unhealthy targets -> health check config, or the ALB->instance SG hop"
