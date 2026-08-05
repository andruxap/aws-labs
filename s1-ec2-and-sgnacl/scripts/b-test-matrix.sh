#!/usr/bin/env bash
# Part B connectivity matrix. Run once per phase; every cell is an observed
# result, never an assumed one.
#
#   bash scripts/b-test-matrix.sh "<phase label>"
#
# In-instance commands go through SSM Send Command — no SSH, no key pair.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.b"
PHASE="${1:-unlabelled}"

# Run a shell command on an instance, print its output (or TIMEOUT/ERROR).
on() {  # $1 instance-id, $2 command
  local cid out
  cid="$(aws ssm send-command --instance-ids "$1" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"$2\"]" \
    --region "$AWS_REGION" --query 'Command.CommandId' --output text 2>/dev/null)" || { echo "SSM-ERROR"; return; }
  for _ in $(seq 1 20); do
    sleep 3
    status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$1" \
      --region "$AWS_REGION" --query Status --output text 2>/dev/null)" || continue
    case "$status" in Success|Failed|TimedOut|Cancelled) break;; esac
  done
  out="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$1" \
    --region "$AWS_REGION" --query 'StandardOutputContent' --output text 2>/dev/null)"
  echo "${out:-<no output>}" | tr -d '\r' | tr '\n' ' '
}

from_here() {  # $1 url — curl from the workstation (i.e. "from your home IP")
  # MSYS_NO_PATHCONV=1 stops /dev/null resolving, so curl exits non-zero on the
  # write even when the request succeeded; with pipefail that looked like a
  # timeout next to a valid 200. Discard the body with a real file instead.
  local code
  code="$(curl -s -o "$HERE/build/.body" -w '%{http_code}' --max-time 8 "$1" 2>/dev/null)"
  case "$code" in ""|000) echo "NO RESPONSE (timeout/refused)";; *) echo "$code";; esac
}

echo ""
echo "======================================================================"
echo " PHASE: $PHASE"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)   your IP: $MY_IP"
echo "======================================================================"

printf '%-42s %s\n' "1. home -> A public (SGA) http://$PUB_A" "$(from_here "http://$PUB_A")"
printf '%-42s %s\n' "2. home -> B public (SGB) http://$PUB_B" "$(from_here "http://$PUB_B")"
printf '%-42s %s\n' "3. SSM reachable on A" \
  "$(on "$INST_A" 'echo OK')"
printf '%-42s %s\n' "4. SSM reachable on B" \
  "$(on "$INST_B" 'echo OK')"
printf '%-42s %s\n' "5. A -> ping B private ($PRIV_B)" \
  "$(on "$INST_A" "ping -c 2 -W 2 $PRIV_B | tail -2")"
printf '%-42s %s\n' "6. B -> curl A public ($PUB_A)" \
  "$(on "$INST_B" "curl -s -o /dev/null -w '%{http_code}' -m 8 http://$PUB_A || echo FAILED")"
printf '%-42s %s\n' "7. B -> curl A private ($PRIV_A)" \
  "$(on "$INST_B" "curl -s -o /dev/null -w '%{http_code}' -m 8 http://$PRIV_A || echo FAILED")"
printf '%-42s %s\n' "8. B -> ping A private ($PRIV_A)" \
  "$(on "$INST_B" "ping -c 2 -W 2 $PRIV_A | tail -2")"
printf '%-42s %s\n' "9. A -> curl B private ($PRIV_B)" \
  "$(on "$INST_A" "curl -s -o /dev/null -w '%{http_code}' -m 8 http://$PRIV_B || echo FAILED")"
printf '%-42s %s\n' "10. A -> curl B public ($PUB_B)" \
  "$(on "$INST_A" "curl -s -o /dev/null -w '%{http_code}' -m 8 http://$PUB_B || echo FAILED")"
echo ""
