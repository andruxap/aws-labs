# Cost log

Account `$ACCOUNT_ID`. Baseline before these labs: **$0.00/month** — andruxa.dev runs inside Always Free allowances, and small credits (~$0.55/mo) absorb the rest. The 12-month free tier on this account has **expired**: only `Always Free` types remain, so EC2/RDS/ELB/DMS hours bill at full on-demand rate in every project after S2.

| Date | Session | Resources | Est. cost | Torn down | Bill verified |
|---|---|---|---|---|---|
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
