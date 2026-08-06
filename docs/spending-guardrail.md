# Spending guardrail

**Goal: spend the credits, never the credit card.**

Set up 2026-08-05 by [`scripts/spend-guardrail.sh`](../scripts/spend-guardrail.sh). Re-runnable.

---

## The thing you have to know first

**AWS has no hard spending cap.** There is no setting that suspends an account at $X. Budgets *alert*; they do not stop. Anyone who says otherwise is describing something that doesn't exist.

The closest real mechanism is an **AWS Budget Action**: when a budget threshold is crossed, AWS automatically attaches an IAM policy to your user. That policy can deny the creation of anything expensive. It is not instant — budgets evaluate roughly every few hours and AWS cost data itself lags — so **a small overshoot is possible**. Expect the freeze to catch you within single-digit dollars, not within cents.

That limitation is why the layers below exist: automation for the hard stop, plus habits that keep you far away from the threshold.

---

## What is set up

### Layer 1 — credit burn tracker (visibility)

| | |
|---|---|
| Budget | `credit-burn-annual` |
| Limit | $150/year |
| Credits | **excluded** — measures gross usage, i.e. how fast the pool drains |
| Alerts | 25% / 50% / 80% / 95% → $ALERT_EMAIL |

This answers "how much of the $158 have I used?"

### Layer 2 — real-money warnings

| | |
|---|---|
| Budget | `real-money-hard-stop` |
| Limit | $5/month |
| Credits | **included** — measures what actually reaches your card |
| Alerts | $1 (20%) and $3 (60%) |

While credits are covering everything, this budget reads **$0.00**. The moment it moves, credits have stopped covering something and you are paying.

### Layer 3 — the hard stop

At **$5 of post-credit spend in a month**, a Budget Action automatically attaches the IAM policy `LabSpendFreeze` to user `Andrey`. Status: `STANDBY`, `AUTOMATIC` (no approval step — it just fires).

**What the freeze blocks** — creation of everything that bills by the hour:

`ec2:RunInstances` · `ec2:StartInstances` · `ec2:CreateNatGateway` · `ec2:AllocateAddress` · `ec2:CreateVpcEndpoint` · `ec2:CreateVolume` · `elasticloadbalancing:CreateLoadBalancer` · `autoscaling:CreateAutoScalingGroup` / `UpdateAutoScalingGroup` / `SetDesiredCapacity` · `rds:CreateDBInstance` / `CreateDBCluster` / `RestoreDBInstanceFromDBSnapshot` · `dms:CreateReplicationInstance` · `globalaccelerator:CreateAccelerator` · `eks:CreateCluster` · `elasticache:CreateCacheCluster` / `CreateReplicationGroup` · `redshift:CreateCluster` · `sagemaker:CreateNotebookInstance` / `CreateEndpoint`

**What it deliberately does NOT block:**

- **Anything that deletes.** No `Delete*`, `Terminate*`, or `Release*` is denied — a freeze that stopped you tearing down running resources would make the bill worse, not better.
- **`iam:*`** — so you can lift the freeze yourself.
- **Lambda, DynamoDB, S3, CloudFront, Route 53** — Always Free or negligible, and andruxa.dev depends on them.

**It does not affect andruxa.dev.** The policy attaches to the IAM *user* `Andrey`. The site's CI deploys through OIDC *roles*, which are separate principals, and running infrastructure is untouched regardless. Production keeps working while you're frozen.

**Root always overrides.** IAM policies don't apply to the account root user, so you can never lock yourself out.

### To lift the freeze

```bash
aws iam detach-user-policy --user-name Andrey \
  --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/LabSpendFreeze
```

---

## Known false positive: the domain renewal

Credits do **not** cover everything. In June 2026 the account was charged **$19.21** in real money — $17.00 Amazon Registrar + $2.21 tax — for the andruxa.dev renewal, while credits applied only $0.54 that month.

So around **each January renewal, the freeze will fire** on a charge that has nothing to do with labs. That is a false positive. Detach the policy, note it, move on. This is also why credits remaining ($158.03) and gross annual spend ($21.85) don't reconcile: most of that $21.85 was the domain, paid by card.

---

## The habits that matter more than the automation

The automation is a backstop for the case where something is forgotten. These are what actually keep spend near zero:

1. **Every project runs `scripts/teardown.sh` the same day.** Not tomorrow.
2. **Verify after teardown**, don't assume — every teardown script ends by counting what's left.
3. **Check the bill the next morning.** `docs/cost-log.md` has a "bill verified" column and it is the only column that proves anything.
4. **Never start a project you don't have time to finish.** S3 through S9 all create hourly billers; a half-built ALB left overnight costs more than the whole project.
5. **Sweep across regions after multi-region work** (S8, S9). Global Accelerator is invisible in every per-region console view — query it separately.

## Quick status check

```bash
# what have I actually paid this month (after credits)?
aws budgets describe-budgets --account-id $ACCOUNT_ID \
  --query "Budgets[?BudgetName=='real-money-hard-stop'].CalculatedSpend.ActualSpend.Amount" --output text

# how much of the credit pool is gone?
aws budgets describe-budgets --account-id $ACCOUNT_ID \
  --query "Budgets[?BudgetName=='credit-burn-annual'].CalculatedSpend.ActualSpend.Amount" --output text

# is the freeze armed or fired?
aws budgets describe-budget-actions-for-budget --account-id $ACCOUNT_ID \
  --budget-name real-money-hard-stop --query 'Actions[].Status' --output text
#   STANDBY = armed, nothing wrong.  EXECUTION_SUCCESS = you are frozen.
```

Credit balance itself has no API — read it at **Billing → Credits** in the console.

## Still outstanding (console-only, one click each)

- **Billing → Billing preferences → Receive Billing Alerts.** The CloudWatch billing alarms at $10/$25 do not publish their metric until this is on.
- **Confirm the SNS subscription emails** sent to $ALERT_EMAIL.
