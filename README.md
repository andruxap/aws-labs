# aws-labs

Hands-on AWS projects, built and torn down in a real account. Console and CLI, then Terraform where the resource graph is worth learning.

Sequencing and cost analysis: `resume_website/docs/aws-projects-twl/00-merged-track.md`.

| # | Project | Services | Cost | Status |
|---|---|---|---|---|
| S1 | EC2 web server + SG/NACL challenge | EC2, VPC | $0.13 | planned |
| **S2** | **[Event-driven order processing](s2-event-driven-orders/)** | API Gateway, Lambda, DynamoDB Streams, SQS, EventBridge Pipes, CloudWatch, SNS | **<$0.01** | ✅ built, tested, torn down |
| S3 | ALB advanced request routing | EC2, ALB, S3, IAM, Route 53 | $0.26 | planned |
| S4 | Blue/green + rolling deployments | ASG, Launch Templates, ALB | $0.51 | planned |
| S5 | Broken web app challenge | CloudFormation, EC2, ALB | $0.19 | planned |
| S6 | Multi-VPC PrivateLink | VPC, NLB, Endpoint Services | $0.57 | planned |
| S7 | On-prem migration | EC2, RDS, DMS | $0.36 | planned |
| S8 | Serverless cross-region DR | DynamoDB Global Tables, Lambda, API GW | $0.05 | planned |
| S9 | Global Accelerator failover | Global Accelerator, ALB ×2 | $1.48 | planned |

Each project folder holds a runnable `scripts/deploy.sh` and `scripts/teardown.sh`, the source, and a write-up covering what broke.

## Ground rules

- **Never work on `main`.** Everything happens on `develop`.
- **Teardown the same day.** `docs/cost-log.md` tracks what was created and when it was deleted; the bill is checked the next morning.
- **No `*FullAccess` policies.** The courses use them; this repo writes scoped ones.
- Cost guardrail: `scripts/billing-alarms.sh` sets CloudWatch billing alarms at $10 and $25, on top of the account's $5 AWS Budget.

## Setup

```bash
aws sts get-caller-identity     # confirm the account
bash scripts/billing-alarms.sh  # once
cd s2-event-driven-orders && bash scripts/deploy.sh
```

Windows/Git Bash: the AWS CLI is a native Windows binary, so `file://` arguments need `C:/...` paths (`cygpath -m`), and commands taking leading-slash arguments need `MSYS_NO_PATHCONV=1`. Both are handled in the scripts.
