#!/usr/bin/env bash
# Terminate an in-service instance out of band and measure what clients see.
#
# The contrast with cutover.sh and refresh.sh is the point: a PLANNED change
# (listener swap, instance refresh) loses nothing, because the ALB deregisters
# the target and drains connections first. An UNPLANNED termination does not get
# that courtesy — the ALB keeps sending traffic to a dead target until its own
# health check notices.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"
ASG="lab-s4-blue-asg"
LOG="$BUILD/kill-poll.log"; : > "$LOG"
STOP="$BUILD/.killstop"; rm -f "$STOP"

VICTIM="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService']|[0].InstanceId" --output text)"
echo "victim: $VICTIM"

poll() {
  while [ ! -f "$STOP" ]; do
    o="$(curl -s -m 2 -w '|%{http_code}' "http://$ALB_DNS/whoami.txt" 2>/dev/null)"
    echo "${o##*|}" >> "$LOG"
  done
}
poll & POLLER=$!

sleep 5
KILL_AT="$(wc -l < "$LOG")"
aws ec2 terminate-instances --instance-ids "$VICTIM" --region "$AWS_REGION" >/dev/null
echo "terminated after sample #$KILL_AT — polling for 2 minutes"

sleep 120
touch "$STOP"; wait "$POLLER" 2>/dev/null; rm -f "$STOP"

TOTAL="$(wc -l < "$LOG")"; OK="$(grep -c '^200' "$LOG")"; BAD="$(grep -vc '^200' "$LOG")"
echo ""
echo "  samples          : $TOTAL"
echo "  HTTP 200         : $OK"
echo "  failed / non-200 : $BAD"
echo "  codes seen       : $(sort "$LOG" | uniq -c | tr '\n' ' ')"
if [ "$BAD" -gt 0 ]; then
  FIRST="$(grep -n -v '^200' "$LOG" | head -1 | cut -d: -f1)"
  LAST="$(grep -n -v '^200' "$LOG" | tail -1 | cut -d: -f1)"
  echo "  first failure    : sample #$FIRST (#$((FIRST - KILL_AT)) after termination)"
  echo "  last failure     : sample #$LAST"
  echo "  failure window   : $((LAST - FIRST + 1)) samples"
fi
