#!/usr/bin/env bash
# Every IAM role / instance profile a lab creates must live under /workload/
# with the BuilderBoundary ceiling (resume-website plan 020, step 12) — the
# daily Builder login can create nothing else. Run before committing a lab:
#
#   bash scripts/check-workload-iam.sh
#
# Fails on:
#   - `aws iam create-role` without --path "$WORKLOAD_PATH" and --permissions-boundary
#   - `aws iam create-instance-profile` without --path
#   - a Terraform aws_iam_role without path = "/workload/" and permissions_boundary
#   - a Terraform aws_iam_instance_profile without path = "/workload/"
#   - a hand-built role ARN ("...:role/$X"), which is wrong for path roles
# The allowlist below is the complete set of deliberate exceptions.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# file:needle — each needs a comment in that file saying why.
ALLOW=(
  "s7-onprem-migration/scripts/3-dms.sh:--role-name dms-vpc-role"         # DMS needs this exact root-path role
  "scripts/spend-guardrail.sh:--role-name \"\$ACTION_ROLE\""               # budget action: admin-only by design
  "scripts/spend-guardrail.sh:role/\$ACTION_ROLE"
)
allowed() {
  local file="$1" line="$2" entry
  for entry in "${ALLOW[@]}"; do
    [[ "$file" == "${entry%%:*}" && "$line" == *"${entry#*:}"* ]] && return 0
  done
  return 1
}

fail=0
report() { echo "  $1:$2: $3"; fail=1; }

# This checker and the shared library quote the patterns in comments and
# strings, so they are not scanned. Only tracked files are scanned: run the
# check again after committing a new script, not just before.
shell_files=$(git ls-files '*.sh' | grep -vx -e scripts/check-workload-iam.sh -e scripts/lib/workload-iam.sh)

# create-role: the flags may continue on the next line, so join continuations.
for f in $shell_files; do
  awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print NR ":" buf $0; buf = "" }' "$f" |
  while IFS= read -r rec; do
    n="${rec%%:*}"; line="${rec#*:}"
    if [[ "$line" == *"aws iam create-role "* ]] && ! allowed "$f" "$line"; then
      [[ "$line" == *'--path "$WORKLOAD_PATH"'* && "$line" == *"--permissions-boundary"* ]] ||
        echo "$f:$n:create-role without /workload/ path + BuilderBoundary"
    fi
    if [[ "$line" == *"aws iam create-instance-profile "* ]] && ! allowed "$f" "$line"; then
      [[ "$line" == *'--path "$WORKLOAD_PATH"'* ]] || echo "$f:$n:create-instance-profile without /workload/ path"
    fi
    if [[ "$line" =~ :role/\$ ]] && ! allowed "$f" "$line"; then
      echo "$f:$n:hand-built role ARN; use \$(role_arn NAME) from scripts/lib/workload-iam.sh"
    fi
  done
done > /tmp/check-workload-iam.$$ 2>&1
while IFS=: read -r f n msg; do report "$f" "$n" "$msg"; done < /tmp/check-workload-iam.$$
rm -f /tmp/check-workload-iam.$$

# Terraform: inspect each aws_iam_role / aws_iam_instance_profile block body.
for f in $(git ls-files '*.tf'); do
  awk -v F="$f" '
    /^resource "aws_iam_(role|instance_profile)" "/ { kind=$2; gsub(/"/, "", kind); name=$3; gsub(/"/, "", name); start=NR; body=""; inblk=1; next }
    inblk { body = body "\n" $0 }
    inblk && /^}/ {
      inblk=0
      if (body !~ /path[ ]*=[ ]*"\/workload\/"/) print F ":" start ":" kind "." name " without path = \"/workload/\""
      if (kind == "aws_iam_role" && body !~ /permissions_boundary[ ]*=.*BuilderBoundary/) print F ":" start ":" kind "." name " without BuilderBoundary"
    }' "$f"
done | while IFS=: read -r f n msg; do echo "  $f:$n: $msg"; done | tee /tmp/check-workload-tf.$$
[[ -s /tmp/check-workload-tf.$$ ]] && fail=1
rm -f /tmp/check-workload-tf.$$

if (( fail )); then
  echo "check-workload-iam: FAILED (see scripts/lib/workload-iam.sh)"
  exit 1
fi
echo "check-workload-iam: all lab IAM roles and instance profiles use /workload/ + BuilderBoundary"
