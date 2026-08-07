# Cost log

Account `$ACCOUNT_ID`. Baseline before these labs: **$0.00/month** — andruxa.dev runs inside Always Free allowances, and credits absorb the rest.

## Credits — checked 2026-08-05

**$158.03 remaining, $1.97 used.** The whole ten-project track is ~$5.30, so it is comfortably covered.

| Credit | Amount | Issued |
|---|---|---|
| AWS Free Tier | $100.00 | 2026-01-09 |
| Explore AWS: cost budget with AWS Budgets | $20.00 | 2026-01-19 |
| Explore AWS: launch an instance using EC2 | $20.00 | 2026-02-17 |
| Explore AWS: create a web app using AWS Lambda | $20.00 | 2026-06-17 |

This account is on the post-2025 **credit-based free plan**, not the old 12-month allowances — which is why `aws freetier get-free-tier-usage` returns only `Always Free` types. There are no free EC2/RDS/ELB hours; there is a credit pool instead. Those services bill at full on-demand rate and draw the pool down.

**Credits expire, and unused credits are worth nothing.** Check the expiration column before deciding to skip a project on cost grounds — the expensive ones (S9's Global Accelerator, S7's RDS+DMS) are the best use of a balance with a deadline.

| Date | Session | Resources | Est. cost | Torn down | Bill verified |
|---|---|---|---|---|---|
| 2026-08-07 | S6 PrivateLink | 3 VPCs, 1 NLB (~2h), 5 interface endpoints, 1 S3 gateway endpoint (free), 3x t3.micro | **~$0.23** | ✅ same day | ☐ check 2026-08-08 |
| 2026-08-05 | S5 Broken web app | CloudFormation stack: 1 ALB (~1h), 2x t3.micro, ASG, VPC | **~$0.10** | ✅ same day | ☐ check 2026-08-06 |
| 2026-08-05 | S4 Blue/green | 1 ALB (~2h), 4x t3.micro across 2 ASGs, 2 target groups, launch template | **~$0.20** | ✅ same day | ☐ check 2026-08-06 |
| 2026-08-05 | S3 ALB routing | 1 ALB (~2h), 2x t3.micro, 2 target groups, S3 bucket, 3 Route 53 records | **~$0.14** | ✅ same day | ☐ check 2026-08-06 |
| 2026-08-05 | S1 EC2 + SG/NACL | 3x t3.micro (~90 min), custom VPC, 2 SGs, IGW, no NAT | **~$0.13** | ✅ same day | ☐ check 2026-08-06 |
| 2026-08-05 | S2 Event-driven orders | DynamoDB on-demand, 4 Lambdas, HTTP API, 4 SQS queues, EventBridge Pipe, 2 SNS topics, 1 alarm | **< $0.01** | ✅ same day | ☐ check 2026-08-06 |

## S2 detail

Everything used is pay-per-request and almost all of it sits inside Always Free allowances:

| Service | Free tier | Lab usage |
|---|---|---|
| Lambda | 1M requests + 400k GB-s/mo, always free | ~40 invocations |
| DynamoDB | 25 GB + 25 RCU/WCU, always free | 9 items, on-demand |
| SQS | 1M requests/mo, always free | ~100 |
| SNS | 1k email notifications/mo, always free | 3 |
| CloudWatch | 10 alarms + 5 GB logs, always free | 3 alarms |
| API Gateway (HTTP) | **not free** — $1.00/M requests | ~10 requests ≈ $0.00001 |
| EventBridge Pipes | **not free** — $0.40/M requests | ~30 ≈ $0.00001 |

Persisting after teardown: two CloudWatch billing alarms ($10 / $25) — inside the always-free 10-alarm allowance, so $0.00/month.
