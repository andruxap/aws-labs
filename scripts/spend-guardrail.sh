#!/usr/bin/env bash
# Spending guardrail — stop lab spend before it reaches the credit card.
#
# READ docs/spending-guardrail.md FIRST. Short version: AWS has no true hard
# spending cap. This is the closest mechanism that exists — an AWS Budget Action
# that automatically attaches a Deny policy to the IAM user the moment real
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
# can attach any policy — admin by proxy). Run this through the admin wrapper.
# The freeze target is the IAM user that ran it; after 020 step 9 that user has
# no active key, so re-targeting the freeze is tracked as plan flag F2.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="us-east-1"
EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL to the address that should receive alerts}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
USER_NAME="$(aws sts get-caller-identity --query Arn --output text | sed 's|.*user/||')"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
w() { cygpath -m "$1"; }
say() { echo ""; echo "==> $*"; }

FREEZE_POLICY="LabSpendFreeze"
ACTION_ROLE="BudgetsActionRole-LabSpendFreeze"

say "account $ACCT / IAM user $USER_NAME"

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
echo "    ready"

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
{ "IamActionDefinition": { "PolicyArn": "$POLICY_ARN", "Users": ["$USER_NAME"] } }
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
  echo "    action already exists: $EXISTING"
fi

say "Done"
echo "  Gross usage tracked against \$150/yr  -> email at 25/50/80/95%"
echo "  Real money tracked against \$5/mo     -> email at \$1 and \$3"
echo "  At \$5 real money: creation of hourly-billed resources is BLOCKED"
echo ""
echo "  To lift the freeze:  aws iam detach-user-policy --user-name $USER_NAME \\"
echo "                         --policy-arn $POLICY_ARN"
