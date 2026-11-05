# shellcheck shell=bash
#
# Shared IAM settings for every lab script that creates a role or an
# instance profile. Source it; don't run it.
#
# Why: daily AWS work happens as the Identity Center "Builder" permission set
# (resume-website, plan 020). Builder may create IAM roles ONLY under the
# /workload/ path and ONLY with the BuilderBoundary permissions boundary
# attached, so a role a lab creates can never do more than Builder itself. A
# create-role without these two flags fails with AccessDenied.
#
# Nothing account-specific is committed (CLAUDE.md): the boundary ARN is built
# from the caller's account at runtime.

WORKLOAD_PATH="/workload/"

# arn:aws:iam::<this account>:policy/boundary/BuilderBoundary
workload_boundary_arn() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text)"
  echo "arn:aws:iam::${acct}:policy/boundary/BuilderBoundary"
}

# A role's ARN as IAM reports it. It includes the path, so never build one by
# hand as "arn:aws:iam::$ACCT:role/$NAME": that's wrong for /workload/ roles.
role_arn() {
  aws iam get-role --role-name "$1" --query Role.Arn --output text
}
