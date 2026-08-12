#!/usr/bin/env bash
# Break the primary region and measure how long the accelerator takes to move
# traffic — then let it recover and measure the way back.
#
# The failure is injected by deregistering the instance from its target group,
# so the ALB has no healthy target and answers 503. Global Accelerator's own
# health check on /health then fails, and it withdraws that endpoint.
#
# Nothing about DNS changes. The client keeps resolving the same two anycast
# IPs throughout — which is exactly what makes this different from S8.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"

LOG="$BUILD/failover.log"; : > "$LOG"
STOP="$BUILD/.stop"; rm -f "$STOP"

poll() {
  while [ ! -f "$STOP" ]; do
    o="$(curl -s -m 3 -w '|%{http_code}' "http://$ACC_DNS/whoami.txt" 2>/dev/null)"
    code="${o##*|}"; body="${o%%|*}"
    printf '%s %s %s\n' "$(date +%s)" "${code:-000}" "$(echo "$body" | awk '{print $1}')" >> "$LOG"
  done
}

mark() { echo "$(date +%s) --- $* ---" >> "$LOG"; echo ""; echo "==> $*"; }

echo "accelerator : $ACC_DNS"
echo "anycast IPs : $ACC_IPS"
echo "serving now : $(curl -s -m 8 "http://$ACC_DNS/whoami.txt")"

poll & POLLER=$!
sleep 8

# ------------------------------------------------------------------ break ---
mark "BREAKING $BLUE_REGION (deregistering its only target)"
BREAK_AT=$(date +%s)
aws elbv2 deregister-targets --target-group-arn "$BLUE_TG" \
  --targets "Id=$BLUE_INSTANCE" --region "$BLUE_REGION" >/dev/null

for _ in $(seq 1 40); do
  sleep 5
  last="$(tail -3 "$LOG" | awk '$3!="" && $3!="---"{print $3}' | tail -1)"
  [ "$last" = "$GREEN_REGION" ] && break
done
FLIP_AT=$(date +%s)
mark "traffic now on $(curl -s -m 8 "http://$ACC_DNS/whoami.txt" | awk '{print $1}')"

# ---------------------------------------------------------------- recover ---
sleep 5
mark "RECOVERING $BLUE_REGION (re-registering the target)"
RECOVER_AT=$(date +%s)
aws elbv2 register-targets --target-group-arn "$BLUE_TG" \
  --targets "Id=$BLUE_INSTANCE" --region "$BLUE_REGION" >/dev/null

for _ in $(seq 1 48); do
  sleep 5
  last="$(tail -3 "$LOG" | awk '$3!="" && $3!="---"{print $3}' | tail -1)"
  [ "$last" = "$BLUE_REGION" ] && break
done
BACK_AT=$(date +%s)

sleep 5
touch "$STOP"; wait "$POLLER" 2>/dev/null; rm -f "$STOP"

# ----------------------------------------------------------------- report ---
TOTAL=$(grep -c '^[0-9]* [0-9]' "$LOG")
OK=$(awk '$2=="200"' "$LOG" | wc -l)
BAD=$(awk '$2!="200" && $2!="---" && NF==3' "$LOG" | wc -l)

echo ""
echo "======================================================================"
echo "  requests           : $TOTAL"
echo "  HTTP 200           : $OK"
echo "  failed             : $BAD"
echo "  failover  (break -> $GREEN_REGION serving) : $((FLIP_AT - BREAK_AT))s"
echo "  failback  (recover -> $BLUE_REGION serving) : $((BACK_AT - RECOVER_AT))s"
echo ""
echo "  codes seen: $(awk 'NF==3{print $2}' "$LOG" | sort | uniq -c | tr '\n' ' ')"
echo ""
echo "  transition (first 12 samples after the break):"
awk -v t="$BREAK_AT" 'NF==3 && $1>=t {n++; if(n<=12) printf "    +%-3ds  %s  %s\n", $1-t, $2, $3}' "$LOG"
echo "======================================================================"
