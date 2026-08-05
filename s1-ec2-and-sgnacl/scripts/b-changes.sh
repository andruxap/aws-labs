#!/usr/bin/env bash
# Part B step 7 — the four tightening changes, applied one at a time so the
# matrix can be re-run between each.
#
#   bash scripts/b-changes.sh 1   SGA: HTTP from your home IP only
#   bash scripts/b-changes.sh 2   NACL: deny your home IP
#   bash scripts/b-changes.sh 3   SGB: HTTP from SGA only
#   bash scripts/b-changes.sh 4   ICMP allowed in both directions
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.env.b"

case "${1:?which change? 1-4}" in

1) echo "SGA: replace 'HTTP from 0.0.0.0/0' with 'HTTP from $MY_IP/32'"
   aws ec2 revoke-security-group-ingress --group-id "$SGA" --protocol tcp --port 80 \
     --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true
   aws ec2 authorize-security-group-ingress --group-id "$SGA" --protocol tcp --port 80 \
     --cidr "$MY_IP/32" --region "$AWS_REGION" >/dev/null 2>&1 || true
   ;;

2) echo "NACL $NACL_ID: DENY all traffic from $MY_IP/32 inbound, rule 50 (before the allow-all at 100)"
   aws ec2 create-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 \
     --protocol -1 --rule-action deny --ingress --cidr-block "$MY_IP/32" \
     --region "$AWS_REGION" >/dev/null 2>&1 || \
   aws ec2 replace-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 \
     --protocol -1 --rule-action deny --ingress --cidr-block "$MY_IP/32" \
     --region "$AWS_REGION" >/dev/null
   echo "   NACLs are STATELESS: this blocks the inbound packet, so the reply never happens."
   echo "   Note it also outranks the security group — a NACL deny wins regardless of SG rules."
   ;;

3) echo "SGB: replace 'HTTP from 0.0.0.0/0' with 'HTTP from SGA'"
   aws ec2 revoke-security-group-ingress --group-id "$SGB" --protocol tcp --port 80 \
     --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true
   aws ec2 authorize-security-group-ingress --group-id "$SGB" --protocol tcp --port 80 \
     --source-group "$SGA" --region "$AWS_REGION" >/dev/null 2>&1 || true
   echo "   Source-group matching only works on the PRIVATE path. Traffic that leaves"
   echo "   the VPC to a public IP and comes back arrives from an address, not a group."
   ;;

4) echo "ICMP both ways: SGA already lacks a rule; add 'all ICMP from SGB' to SGA"
   aws ec2 authorize-security-group-ingress --group-id "$SGA" --protocol icmp --port -1 \
     --source-group "$SGB" --region "$AWS_REGION" >/dev/null 2>&1 || true
   echo "   SGs are stateful per flow, but a ping in the other direction is a NEW flow,"
   echo "   so each side needs its own inbound rule. That is why test 8 failed at baseline."
   ;;

5) echo "Remove the inbound NACL deny — proves the NACL, not the SG, was blocking"
   aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 \
     --ingress --region "$AWS_REGION" >/dev/null 2>&1 || true
   ;;

6) echo "NACL: deny OUTBOUND to $MY_IP/32 only. Inbound is wide open."
   aws ec2 create-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 \
     --protocol -1 --rule-action deny --egress --cidr-block "$MY_IP/32" \
     --region "$AWS_REGION" >/dev/null 2>&1 || \
   aws ec2 replace-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 50 \
     --protocol -1 --rule-action deny --egress --cidr-block "$MY_IP/32" \
     --region "$AWS_REGION" >/dev/null
   echo "   This is the stateless proof. The request still ARRIVES and Apache still"
   echo "   answers — but the reply is dropped on the way out, so the client hangs."
   echo "   An identical outbound deny in a security group would change nothing at"
   echo "   all, because SGs auto-allow return traffic for an established flow."
   ;;

*) echo "unknown change"; exit 1;;
esac

echo "done — re-run the matrix"
