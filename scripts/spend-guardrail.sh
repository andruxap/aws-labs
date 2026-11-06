#!/usr/bin/env bash
# Spending guardrail — stop lab spend before it reaches the credit card.
#
# READ docs/spending-guardrail.md FIRST. Short version: AWS has no true hard
# spending cap. This is the closest mechanism that exists — an AWS Budget Action
# that automatically attaches a Deny policy to an IAM role the moment real
# (post-credit) charges appear.
#
# Three layers:
#   1. credit-burn-annual   $150/yr, credits EXCLUDED -> tracks the credit pool
#   2. real-money-warning   alerts at $1 and $3 of post-credit spend
#   3. real-money-hard-stop $5 post-credit -> ACTION: freeze resource creation
#
# Safe by construction: the freeze blocks CREATING billable resources but never
# blocks deleting them, so teardown always works. It also does not touch iam:*,
# so you can remove the freeze yourself. Root can always override.
#
# ADMIN-ONLY since resume-website plan 020: creating or running a budget action
# is denied to the daily Builder login (a budget action executes as a role that
# is denied to the daily Builder login). Run this through the admin wrapper.
#
# The freeze targets an IAM ROLE, FREEZE_ROLE (plan 020 F2, 2026-11-05):
#   - not the user that ran it: daily work is an Identity Center sign-in now;
#   - not the Identity Center role itself: AWS refuses changes to AWSReservedSSO_*
#     roles ("only modifiable by AWS"), so freezing that sign-in is a manual
#     permission-set change (resume-website scripts/builder-spend-freeze.ps1).
# The execution role gets an inline policy allowing exactly one attach: the
# AWS managed AWSBudgetsActionsWithAWSResourceControlAccess has NO iam:Attach*,
# so with it alone an IAM-policy action fails when it fires.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="us-east-1"
EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL to the address that should receive alerts}"
FREEZE_ROLE="${FREEZE_ROLE:?set FREEZE_ROLE to the IAM role name the freeze attaches to}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

FREEZE_POLICY="LabSpendFreeze"
ACTION_ROLE="BudgetsActionRole-LabSpendFreeze"

say "account $ACCT / freeze target role $FREEZE_ROLE"
aws iam get-role --role-name "$FREEZE_ROLE" >/dev/null

# ---------------------------------------------------------- 1. Deny policy ---
# Denies creation of everything that bills by the hour. Deliberately does NOT
# deny Delete/Terminate/Release (teardown must keep working), iam:* (you must be
# able to lift the freeze), or the services andruxa.dev runs on.
say "IAM policy $FREEZE_POLICY"
cat > "$BUILD/freeze-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyCreationOfHourlyBilledResources",
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances",
        "ec2:StartInstances",
        "ec2:CreateNatGateway",
        "ec2:AllocateAddress",
        "ec2:CreateVpcEndpoint",
        "ec2:CreateVolume",
        "elasticloadbalancing:CreateLoadBalancer",
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:UpdateAutoScalingGroup",
        "autoscaling:SetDesiredCapacity",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster",
        "rds:RestoreDBInstanceFromDBSnapshot",
        "dms:CreateReplicationInstance",
        "globalaccelerator:CreateAccelerator",
        "eks:CreateCluster",
        "elasticache:CreateCacheCluster",
        "elasticache:CreateReplicationGroup",
        "redshift:CreateCluster",
        "sagemaker:CreateNotebookInstance",
        "sagemaker:CreateEndpoint"
      ],
      "Resource": "*"
    }
  ]
}
JSON
POLICY_ARN="arn:aws:iam::$ACCT:policy/$FREEZE_POLICY"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "$FREEZE_POLICY" \
    --description "Attached automatically by AWS Budgets when post-credit spend hits the limit. Blocks creating hourly-billed resources; deletion still works." \
    --policy-document "file://$(w "$BUILD/freeze-policy.json")" >/dev/null
  echo "    created"
else
  echo "    already exists"
fi

# ------------------------------------------------------- 2. Execution role ---
say "execution role $ACTION_ROLE (assumed by AWS Budgets)"
cat > "$BUILD/budgets-trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "budgets.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "aws:SourceAccount": "$ACCT" } }
  }]
}
JSON
if ! aws iam get-role --role-name "$ACTION_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ACTION_ROLE" \
    --assume-role-policy-document "file://$(w "$BUILD/budgets-trust.json")" >/dev/null
fi
aws iam attach-role-policy --role-name "$ACTION_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AWSBudgetsActionsWithAWSResourceControlAccess
# The one IAM write the action needs, and nothing wider: this policy onto this role.
cat > "$BUILD/action-role-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "FreezeTargetRoleOnly",
    "Effect": "Allow",
    "Action": ["iam:AttachRolePolicy", "iam:DetachRolePolicy"],
    "Resource": "$(aws iam get-role --role-name "$FREEZE_ROLE" --query Role.Arn --output text)",
    "Condition": { "ArnEquals": { "iam:PolicyARN": "$POLICY_ARN" } }
  }]
}
JSON
aws iam put-role-policy --role-name "$ACTION_ROLE" --policy-name freeze-target-role \
  --policy-document "file://$(w "$BUILD/action-role-policy.json")"
echo "    ready (may attach $FREEZE_POLICY to $FREEZE_ROLE only)"

# ------------------------------------------------------------- 3. Budgets ---
mk_budget() {  # $1 name, $2 limit, $3 time-unit, $4 include-credit(true|false)
  cat > "$BUILD/budget.json" <<JSON
{
  "BudgetName": "$1",
  "BudgetLimit": { "Amount": "$2", "Unit": "USD" },
  "TimeUnit": "$3",
  "BudgetType": "COST",
  "CostTypes": {
    "IncludeCredit": $4,
    "IncludeRefund": false,
    "IncludeUpfront": true,
    "IncludeRecurring": true,
    "IncludeOtherSubscription": true,
    "IncludeSubscription": true,
    "IncludeSupport": true,
    "IncludeTax": true,
    "IncludeDiscount": true,
    "UseAmortized": false,
    "UseBlended": false
  }
}
JSON
  aws budgets delete-budget --account-id "$ACCT" --budget-name "$1" >/dev/null 2>&1 || true
  aws budgets create-budget --account-id "$ACCT" --budget "file://$(w "$BUILD/budget.json")"
}

notify() {  # $1 budget, $2 threshold%
  cat > "$BUILD/notif.json" <<JSON
{ "NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
  "Threshold": $2, "ThresholdType": "PERCENTAGE" }
JSON
  cat > "$BUILD/subs.json" <<JSON
[ { "SubscriptionType": "EMAIL", "Address": "$EMAIL" } ]
JSON
  aws budgets create-notification --account-id "$ACCT" --budget-name "$1" \
    --notification "file://$(w "$BUILD/notif.json")" \
    --subscribers "file://$(w "$BUILD/subs.json")" >/dev/null 2>&1 || true
}

say "budget 1/2: credit-burn-annual (\$150/yr, credits EXCLUDED = gross usage)"
mk_budget "credit-burn-annual" 150 ANNUALLY false
for t in 25 50 80 95; do notify "credit-burn-annual" $t; done
echo "    alerts at 25/50/80/95% of the credit pool"

say "budget 2/2: real-money-hard-stop (\$5/mo, credits INCLUDED = what you actually pay)"
mk_budget "real-money-hard-stop" 5 MONTHLY true
for t in 20 60; do notify "real-money-hard-stop" $t; done
echo "    warns at \$1 and \$3 of post-credit spend"

# ------------------------------------------------------- 4. Budget Action ---
say "Budget Action: freeze resource creation at 100% (\$5 real money)"
cat > "$BUILD/action-def.json" <<JSON
{ "IamActionDefinition": { "PolicyArn": "$POLICY_ARN", "Roles": ["$FREEZE_ROLE"] } }
JSON
EXISTING="$(aws budgets describe-budget-actions-for-budget --account-id "$ACCT" \
  --budget-name real-money-hard-stop --query 'Actions[0].ActionId' --output text 2>/dev/null || echo None)"
if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
  aws budgets create-budget-action --account-id "$ACCT" --budget-name real-money-hard-stop \
    --notification-type ACTUAL --action-type APPLY_IAM_POLICY \
    --action-threshold "ActionThresholdValue=100,ActionThresholdType=PERCENTAGE" \
    --definition "file://$(w "$BUILD/action-def.json")" \
    --execution-role-arn "arn:aws:iam::$ACCT:role/$ACTION_ROLE" \
    --approval-model AUTOMATIC \
    --subscribers "SubscriptionType=EMAIL,Address=$EMAIL" \
    --query 'ActionId' --output text
  echo "    action created — fires automatically, no approval needed"
else
  aws budgets update-budget-action --account-id "$ACCT" --budget-name real-money-hard-stop \
    --action-id "$EXISTING" --definition "file://$(w "$BUILD/action-def.json")" >/dev/null
  echo "    action $EXISTING re-pointed at role $FREEZE_ROLE"
fi

say "Done"
echo "  Gross usage tracked against \$150/yr  -> email at 25/50/80/95%"
echo "  Real money tracked against \$5/mo     -> email at \$1 and \$3"
echo "  At \$5 real money: creation of hourly-billed resources is BLOCKED"
echo ""
echo "  To lift the freeze:  aws iam detach-role-policy --role-name $FREEZE_ROLE \\"
echo "                         --policy-arn $POLICY_ARN"
