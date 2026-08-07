# aws-labs

Hands-on AWS projects, built and torn down in a real account. Console and CLI, then Terraform where the resource graph is worth learning.

Sequencing and cost analysis: `resume_website/docs/aws-projects-twl/00-merged-track.md`.

| # | Project | Services | Cost | Status |
|---|---|---|---|---|
| **S1** | **[EC2 web server + SG/NACL challenge](s1-ec2-and-sgnacl/)** | EC2, VPC, Security Groups, NACLs, SSM | **$0.13** | ✅ built, tested, torn down |
| **S2** | **[Event-driven order processing](s2-event-driven-orders/)** | API Gateway, Lambda, DynamoDB Streams, SQS, EventBridge Pipes, CloudWatch, SNS | **<$0.01** | ✅ built, tested, torn down |
| **S3** | **[ALB advanced request routing](s3-alb-routing/)** | EC2, ALB, Target Groups, S3, IAM, Route 53 | **$0.14** | ✅ built, tested, torn down |
| **S4** | **[Blue/green + rolling deployments](s4-blue-green/)** | ASG, Launch Templates, Instance Refresh, ALB | **$0.20** | ✅ built, tested, torn down |
| **S5** | **[Broken web app challenge](s5-broken-web-app/)** | CloudFormation, ALB, ASG, VPC routing, Security Groups | **$0.10** | ✅ 4/4 faults found, fixed, deleted |
| **S6** | **[Multi-VPC PrivateLink](s6-privatelink/)** | VPC x3, NLB, Endpoint Service, Interface + Gateway Endpoints | **$0.23** | ✅ built, 7/7 assertions, torn down |
| **S7** | **[On-prem migration (DMS)](s7-onprem-migration/)** | EC2, RDS MySQL, AWS DMS, SSM | **$0.15** | ✅ migrated, cut over, torn down |
| **S8** | **[Serverless cross-region DR](s8-multiregion-dr/)** | DynamoDB Global Tables, Lambda, API GW, ACM, Route 53 failover | **$0.06** | ✅ 7/7 assertions, failover + failback, torn down |
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
