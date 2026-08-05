#!/usr/bin/env bash
# S2 checkpoint tests. Usage: bash scripts/test.sh [A|B|C]
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.generated"

submit() {  # name product amount notes
  curl -s -X POST "$API_URL" -H "Content-Type: application/json" \
    -d "{\"customerName\":\"$1\",\"product\":\"$2\",\"amount\":$3,\"notes\":\"$4\"}"
}

show() {  # orderId
  aws dynamodb get-item --table-name Orders --region "$AWS_REGION" \
    --key "{\"orderId\":{\"S\":\"$1\"}}" \
    --query 'Item.{status:status.S,amount:amount.N,reason:failureReason.S,completedAt:completedAt.S,failedAt:failedAt.S}' \
    --output json
}

depth() {
  echo "  main=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names ApproximateNumberOfMessages --region "$AWS_REGION" --query 'Attributes.ApproximateNumberOfMessages' --output text)" \
       "dlq=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages --region "$AWS_REGION" --query 'Attributes.ApproximateNumberOfMessages' --output text)" \
       "hv=$(aws sqs get-queue-attributes --queue-url "$HV_URL" --attribute-names ApproximateNumberOfMessages --region "$AWS_REGION" --query 'Attributes.ApproximateNumberOfMessages' --output text)"
}

case "${1:-all}" in
  A) submit "Alice Johnson" "Wireless Headphones" 1200 "Normal order" ;;
  B) submit "Bob Reyes" "Server Rack" 20000 "High value order" ;;
  C) submit "Carol Vance" "Docking Station" 1500 "Please FAIL this order" ;;
  depth) depth ;;
  show) show "$2" ;;
  *) echo "usage: test.sh [A|B|C|depth|show <orderId>]" ;;
esac
