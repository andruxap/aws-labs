#!/usr/bin/env bash
# Lesson 3.6 replacement — the course export is missing its final-testing page.
#
# It is not enough to show that a consumer can reach the provider. The claim
# PrivateLink makes is stronger: the consumer reaches it WITHOUT the traffic
# ever touching the internet, and without the two VPCs being connected at all.
# So this asserts the negatives too.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.generated"

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head_() { echo ""; echo "== $* =="; }

on() {  # $1 instance, $2 command -> stdout
  local cid out
  cid="$(aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript \
    --parameters "commands=[\"$2\"]" --region "$AWS_REGION" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || { echo "SSM-ERROR"; return; }
  for _ in $(seq 1 20); do
    sleep 3
    s="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$1" \
      --region "$AWS_REGION" --query Status --output text 2>/dev/null)" || continue
    case "$s" in Success|Failed|TimedOut|Cancelled) break;; esac
  done
  out="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$1" \
    --region "$AWS_REGION" --query StandardOutputContent --output text 2>/dev/null)"
  echo "${out:-<no output>}" | tr -d '\r' | tr '\n' ' '
}

ep_dns() {  # $1 endpoint id -> its regional private DNS name
  aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$1" --region "$AWS_REGION" \
    --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text
}

PAY_DNS="$(ep_dns "$PAYMENTS_EP")"
ANA_DNS="$(ep_dns "$ANALYTICS_EP")"

echo "======================================================================"
echo " PrivateLink validation — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " service  : $SVC_NAME"
echo " payments : $PAY_DNS"
echo " analytics: $ANA_DNS"
echo "======================================================================"

# ---------------------------------------------------------- the positives ----
head_ "1. Consumers can reach the provider through PrivateLink"

R="$(on "$PAYMENTS_CLIENT" "curl -s -m 10 http://$PAY_DNS/whoami.txt || echo FAILED")"
echo "     payments  -> $R"
case "$R" in *shared-services-app*) ok "Payments reaches Shared Services";; *) bad "Payments could not reach it";; esac

R="$(on "$ANALYTICS_CLIENT" "curl -s -m 10 http://$ANA_DNS/whoami.txt || echo FAILED")"
echo "     analytics -> $R"
case "$R" in *shared-services-app*) ok "Analytics reaches Shared Services";; *) bad "Analytics could not reach it";; esac

# ---------------------------------------------------------- the negatives ----
head_ "2. The provider has no public identity"

PUB="$(aws ec2 describe-instances --instance-ids "$SS_APP" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "     provider public IP: $PUB"
[ "$PUB" = "None" ] && ok "no public IP on the provider instance" || bad "provider has a public IP: $PUB"

head_ "3. The provider's subnet has no internet route"

SUB="$(aws ec2 describe-instances --instance-ids "$SS_APP" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].SubnetId' --output text)"
RT="$(aws ec2 describe-route-tables --region "$AWS_REGION" \
  --filters "Name=association.subnet-id,Values=$SUB" --query 'RouteTables[0].RouteTableId' --output text)"
[ "$RT" = "None" ] && RT="$(aws ec2 describe-route-tables --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$SS_VPC" "Name=association.main,Values=true" \
  --query 'RouteTables[0].RouteTableId' --output text)"
ROUTES="$(aws ec2 describe-route-tables --route-table-ids "$RT" --region "$AWS_REGION" \
  --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId]' --output text | tr '\n' ' ')"
echo "     $SUB via $RT: $ROUTES"
case "$ROUTES" in *igw-*|*nat-*) bad "provider subnet has an internet path";; *) ok "no IGW, no NAT — local routes only";; esac

IGW="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
  --filters "Name=attachment.vpc-id,Values=$SS_VPC" --query 'length(InternetGateways)' --output text)"
echo "     internet gateways attached to the provider VPC: $IGW"
[ "$IGW" = "0" ] && ok "the provider VPC has no internet gateway at all" || bad "an IGW is attached"

head_ "4. The VPCs are not connected to each other"

PEER="$(aws ec2 describe-vpc-peering-connections --region "$AWS_REGION" \
  --filters "Name=status-code,Values=active" --query 'length(VpcPeeringConnections)' --output text)"
TGW="$(aws ec2 describe-transit-gateways --region "$AWS_REGION" \
  --query "length(TransitGateways[?State=='available'])" --output text 2>/dev/null || echo 0)"
echo "     active peering connections: $PEER   transit gateways: $TGW"
[ "$PEER" = "0" ] && [ "$TGW" = "0" ] && ok "no peering, no transit gateway — PrivateLink is the only path" \
  || bad "another connection exists; the test is not conclusive"

head_ "5. A consumer cannot reach the provider's private IP directly"

PRIV="$(aws ec2 describe-instances --instance-ids "$SS_APP" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
R="$(on "$PAYMENTS_CLIENT" "curl -s -m 6 http://$PRIV/whoami.txt || echo UNREACHABLE")"
echo "     payments -> http://$PRIV : $R"
case "$R" in *UNREACHABLE*|*"<no output>"*) ok "provider's own IP is unreachable — only the endpoint works";; \
  *) bad "the private IP answered directly, so the VPCs are connected somehow";; esac

head_ "6. What the consumer actually talks to"

R="$(on "$PAYMENTS_CLIENT" "getent hosts $PAY_DNS | head -1 || echo none")"
echo "     $PAY_DNS resolves to: $R"
echo "     (an ENI inside the Payments VPC — the provider's service, projected locally)"

echo ""
echo "======================================================================"
