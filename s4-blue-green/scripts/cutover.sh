#!/usr/bin/env bash
# Shift live traffic between environments by changing ONE thing: the listener's
# default action. Nothing is created, destroyed, or restarted.
#
#   bash scripts/cutover.sh green    # or blue
#
# Polls the ALB continuously across the switch and reports how many requests
# were lost. "Zero downtime" is a claim; this measures it.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.generated"
TARGET="${1:?blue or green}"

case "$TARGET" in
  blue)  TG="$TG_BLUE";;
  green) TG="$TG_GREEN";;
  *) echo "usage: cutover.sh blue|green"; exit 1;;
esac

POLL="$HERE/build/poll.log"; : > "$POLL"
STOP="$HERE/build/.stop"; rm -f "$STOP"

echo "current: $(curl -s --max-time 5 "http://$ALB_DNS/whoami.txt")"
echo "cutting over to ${TARGET^^} — polling until the switch settles"

# One curl per sample: body and status in a single request. Writing the body to
# stdout (not -o /dev/null, which MSYS_NO_PATHCONV breaks) keeps curl's exit
# code meaningful, so a real failure is distinguishable from a 200.
poll() {
  while [ ! -f "$STOP" ]; do
    out="$(curl -s -m 3 -w '|%{http_code}' "http://$ALB_DNS/whoami.txt" 2>/dev/null)"
    code="${out##*|}"; body="${out%%|*}"
    env_seen="$(echo "$body" | awk '{print $1}')"
    echo "${code:-000} ${env_seen:-NONE}" >> "$POLL"
  done
}
poll & POLLER=$!

sleep 4
SWITCH_AT="$(wc -l < "$POLL")"
aws elbv2 modify-listener --listener-arn "$LISTENER" \
  --default-actions "Type=forward,TargetGroupArn=$TG" --region "$AWS_REGION" >/dev/null
echo "listener modified after request #$SWITCH_AT"

# Keep polling until the new environment has been serving steadily, or give up.
for _ in $(seq 1 60); do
  sleep 1
  tail -5 "$POLL" | grep -qc "${TARGET^^}" && \
    [ "$(tail -5 "$POLL" | grep -c "${TARGET^^}")" -eq 5 ] && break
done
sleep 2
touch "$STOP"; wait "$POLLER" 2>/dev/null; rm -f "$STOP"

TOTAL="$(wc -l < "$POLL")"
OK="$(grep -c '^200 ' "$POLL")"
BAD="$(grep -vc '^200 ' "$POLL")"
FLIP="$(grep -n " ${TARGET^^}$" "$POLL" | head -1 | cut -d: -f1)"

echo ""
echo "  requests sent    : $TOTAL"
echo "  HTTP 200         : $OK"
echo "  failed / non-200 : $BAD"
echo "  switch issued at : request #$SWITCH_AT"
echo "  first ${TARGET^^} at  : request #${FLIP:-never}"
[ -n "$FLIP" ] && echo "  requests spanning the switch: $((FLIP - SWITCH_AT))"
echo ""
echo "  transition window:"
awk -v s="$SWITCH_AT" 'NR>=s-2 && NR<=s+8 {printf "    #%-4d %s\n", NR, $0}' "$POLL"
echo ""
echo "now: $(curl -s --max-time 5 "http://$ALB_DNS/whoami.txt")"
