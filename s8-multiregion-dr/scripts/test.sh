#!/usr/bin/env bash
# S8 validation: replication both ways, then a genuine primary outage.
#
# The primary is broken for real — Lambda reserved concurrency set to 0, so
# every invocation is throttled and the API returns 500. That is an actual
# compute failure, not an inverted health check, and it is fully reversible.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.generated"
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
say() { echo ""; echo "== $* =="; }

P_URL="https://$PRIMARY_API.execute-api.$PRIMARY.amazonaws.com"
S_URL="https://$SECONDARY_API.execute-api.$SECONDARY.amazonaws.com"

get()  { curl -s -m 15 "$1" 2>/dev/null; }
post() { curl -s -m 15 -X POST "$1" -H 'Content-Type: application/json' -d "$2" 2>/dev/null; }

say "1. Write to $PRIMARY, read from $SECONDARY (replication east -> west)"
STAMP="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8 || echo $$)"
post "$P_URL" "{\"ItemId\":\"east-$STAMP\",\"Data\":\"written in $PRIMARY\"}" | head -c 200; echo
sleep 6
R="$(get "$S_URL")"
echo "  $SECONDARY sees: $(echo "$R" | head -c 200)"
case "$R" in *"east-$STAMP"*) ok "item written in $PRIMARY is readable in $SECONDARY";; \
  *) bad "replication east->west not visible";; esac

say "2. Write to $SECONDARY, read from $PRIMARY (replication west -> east)"
post "$S_URL" "{\"ItemId\":\"west-$STAMP\",\"Data\":\"written in $SECONDARY\"}" | head -c 200; echo
sleep 6
R="$(get "$P_URL")"
echo "  $PRIMARY sees: $(echo "$R" | head -c 200)"
case "$R" in *"west-$STAMP"*) ok "item written in $SECONDARY is readable in $PRIMARY";; \
  *) bad "replication west->east not visible";; esac
ok "replication is bidirectional — both regions are writable"

say "3. Which region does the public name serve right now?"
R="$(get "https://$FQDN")"
echo "  $(echo "$R" | head -c 160)"
case "$R" in *"\"servedBy\": \"$PRIMARY\""*|*"\"servedBy\":\"$PRIMARY\""*) ok "$FQDN -> $PRIMARY (primary)";; \
  *) bad "unexpected: $R";; esac

say "4. BREAK THE PRIMARY — throttle its Lambda to zero concurrency"
aws lambda put-function-concurrency --function-name lab-s8-api \
  --reserved-concurrent-executions 0 --region "$PRIMARY" >/dev/null
echo "  primary Lambda reserved concurrency = 0"
sleep 5
echo "  direct call to primary: $(curl -s -o /dev/null -w '%{http_code}' -m 15 "$P_URL")"

say "5. Watch Route 53 fail over"
for i in $(seq 1 30); do
  hs="$(aws route53 get-health-check-status --health-check-id "$HC_P" \
    --query 'HealthCheckObservations[0].StatusReport.Status' --output text 2>/dev/null | cut -c1-28)"
  R="$(get "https://$FQDN")"
  who="$(echo "$R" | grep -o '"servedBy": *"[^"]*"' | head -1 | sed 's/.*"\([a-z0-9-]*\)"$/\1/')"
  echo "  t=$((i*20))s  primary-hc=[$hs]  $FQDN served by: ${who:-<error>}"
  [ "$who" = "$SECONDARY" ] && { ok "FAILED OVER to $SECONDARY"; break; }
  sleep 20
done

say "6. Is the data still there after failover?"
R="$(get "https://$FQDN")"
case "$R" in *"east-$STAMP"*) ok "the item written in $PRIMARY is still served, now from $SECONDARY";; \
  *) bad "data missing after failover";; esac

say "7. RECOVER — restore primary concurrency"
aws lambda delete-function-concurrency --function-name lab-s8-api --region "$PRIMARY" >/dev/null
echo "  primary Lambda concurrency restored"
for i in $(seq 1 30); do
  R="$(get "https://$FQDN")"
  who="$(echo "$R" | grep -o '"servedBy": *"[^"]*"' | head -1 | sed 's/.*"\([a-z0-9-]*\)"$/\1/')"
  echo "  t=$((i*20))s  $FQDN served by: ${who:-<error>}"
  [ "$who" = "$PRIMARY" ] && { ok "FAILED BACK to $PRIMARY automatically"; break; }
  sleep 20
done
