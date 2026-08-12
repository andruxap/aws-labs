# aws-labs

Nine AWS architectures built in a real account, measured, and torn down the same day. Total spend: **$1.32**.

The projects come from two courses. What's here isn't the courses' output — it's what happened when their instructions were followed exactly and then checked. **Three of the nine didn't work as taught.** Those are the interesting ones.

---

## What was found

**The event-driven course architecture is broken, not merely imperfect.** [S2](s2-event-driven-orders/) puts an EventBridge Pipe and a worker Lambda on the same SQS queue. Both are pollers, and a Pipe *deletes* the messages its filter rejects — so the worker starves. Normal orders never completed and failed orders never reached the dead-letter queue. Isolated by stopping the Pipe and changing nothing else, then fixed with SNS fan-out so both consumers get their own copy.

**"Instant rollback" isn't instant.** [S4](s4-blue-green/) measured a blue/green cutover: 62 of 62 requests served `200`, zero lost — but **44 requests were still answered by the old environment after the switch was issued**. A listener change propagates over ~40 s. What's instant is *issuing* the rollback, which matters when you're rolling back because production is broken.

**Only unplanned changes lose requests.** Same fleet, three scenarios: planned cutover **0%** loss, rolling refresh **0%**, abrupt instance termination **~4%** (19× HTTP 502). The difference is deregistration — a planned change drains the target first; `terminate-instances` doesn't, so the load balancer keeps routing to a dead host until two health checks fail.

**A private instance can't bootstrap itself.** [S6](s6-privatelink/)'s provider sits in a private subnet with no NAT and no internet gateway — by design. It also couldn't `dnf install httpd`, because package repositories are on the internet. The architecture that makes the lab's point prevents the lab from building. Fixed with a free S3 gateway endpoint.

**DMS migrates data, not databases.** [S7](s7-onprem-migration/) moved every row and zero users, grants, or stored procedures. The application only worked after the credentials were recreated by hand. Proven by killing the source database after cutover.

**NACLs are stateless, and it's observable.** [S1](s1-ec2-and-sgnacl/) denied *outbound* traffic to one IP while leaving inbound wide open. Apache logged `"GET / HTTP/1.1" 200 55` while the client hung and timed out. The server answered; the reply was dropped on the way out. An identical rule in a security group would have done nothing.

---

## The projects

| # | Project | Services | Cost | Status |
|---|---|---|---|---|
| [S1](s1-ec2-and-sgnacl/) | EC2 web server + SG/NACL challenge | EC2, VPC, Security Groups, NACLs, SSM | $0.13 | ✅ 10-test matrix, 5 phases |
| [S2](s2-event-driven-orders/) | Event-driven order processing | API Gateway, Lambda, DynamoDB Streams, SQS, EventBridge Pipes, SNS | <$0.01 | ✅ race diagnosed + fixed |
| [S3](s3-alb-routing/) | ALB advanced request routing | EC2, ALB, Target Groups, S3, IAM, Route 53 | $0.14 | ✅ path- then host-based |
| [S4](s4-blue-green/) | Blue/green + rolling deployments | ASG, Launch Templates, Instance Refresh, ALB | $0.20 | ✅ 3 scenarios measured · **+ Terraform** |
| [S5](s5-broken-web-app/) | Broken web app challenge | CloudFormation, ALB, ASG, VPC routing | $0.10 | ✅ 4/4 faults, 0 false positives |
| [S6](s6-privatelink/) | Multi-VPC PrivateLink | VPC ×3, NLB, Endpoint Service, Interface + Gateway Endpoints | $0.23 | ✅ 7/7 assertions |
| [S7](s7-onprem-migration/) | On-prem → RDS migration | EC2, RDS MySQL, DMS, SSM | $0.15 | ✅ cutover proven |
| [S8](s8-multiregion-dr/) | Serverless cross-region DR | DynamoDB Global Tables, Lambda, API GW, Route 53 failover | $0.06 | ✅ failover + failback · **+ Terraform** |
| [S9](s9-global-accelerator/) | Global Accelerator failover | Global Accelerator, ALB ×2, VPC ×2 | $0.30 | ✅ 25s failover, 22s failback, measured |

Every project folder has `scripts/deploy.sh`, `scripts/teardown.sh`, and a write-up with a **What broke** section. That section is the point; it's the part of a tutorial project nobody else can copy.

**S9 was built last on purpose.** Global Accelerator bills a flat ~$18/month whether or not anyone uses it, and it appears in *no* per-region console view — the highest hourly cost of the nine and the easiest to leave running by accident. Its teardown script was written before the failover test was run.

**Three ways to survive a region failure, all measured.** Running S4, S8 and S9 was for this:

| | Mechanism | Failover | Errors during | Data |
|---|---|---|---|---|
| [S4](s4-blue-green/) | listener swap, one region | ~40 s | **0** — target drained first | shared |
| [S8](s8-multiregion-dr/) | Route 53 DNS failover | **60–80 s** | yes, the whole window | **replicated** |
| [S9](s9-global-accelerator/) | anycast withdrawal | **25 s** | yes, 26 s of it | none |

Anycast is ~2.5× faster because it removes the DNS-caching penalty entirely — the client never re-resolves, the same two static IPs stay valid, and AWS changes what they route to internally. But **neither prevents the outage.** Both have a detection floor of `interval × threshold`, and no configuration gets you below the time it takes to notice. Any RTO claim that ignores the detection window is wrong.

---

## Infrastructure as code

Two labs are also written as Terraform — **validated and planned, never applied**, so they cost nothing to keep:

**[S4](s4-blue-green/terraform/)** — `Plan: 14 to add`. The cutover stops being a sequence of API calls and becomes one variable:

```bash
terraform apply -var active_environment=green
```

`var.active_environment` is read by exactly one resource, the listener. Blue/green stops being a procedure you execute correctly and becomes something the configuration guarantees.

**[S8](s8-multiregion-dr/terraform/)** — `Plan: 20 to add`. Multi-region as provider aliases. The shape of those 20 resources *is* the architecture: **1** global table (DynamoDB owns replication), **3** IAM resources (global), **16** regional resources (8 pairs). One replicated data plane, one global identity plane, a compute plane built twice.

---

## Cost discipline

The interesting constraint wasn't money, it was forgetting. Nine architectures for $1.32 required a rule and a backstop.

**The rule:** every project is torn down the same day it's built, every teardown script ends by *counting* what remains, and the bill is checked the next morning. Tracked in [docs/cost-log.md](docs/cost-log.md).

**The backstop:** [docs/spending-guardrail.md](docs/spending-guardrail.md). AWS has no hard spending cap — budgets alert, they don't stop. The closest real mechanism is an AWS Budget Action that attaches a deny policy automatically. Built with two properties that matter: it never blocks `Delete`/`Terminate` (a freeze that traps you with running resources makes the bill worse), and it never blocks `iam:*` (so you can lift it yourself).

What forgetting would have cost, per month: Global Accelerator **$18**, an ALB or NLB **$16 each**, RDS **$15**, a DMS replication instance **$13**, an interface endpoint **$7**. The last one is the trap — [S6](s6-privatelink/) had five, and they appear in *no* EC2 console view.

---

## Layout

```
sN-project/
  README.md          goal → architecture → what broke → what I learned → cost → teardown proof
  scripts/
    deploy.sh        idempotent, re-runnable
    teardown.sh      dependency order, safe twice, ends with a resource count
    test.sh          assertions, where the project has something to assert
  terraform/         S4 and S8 only
docs/
  cost-log.md        what was created, when it was deleted, what it cost
  spending-guardrail.md
scripts/
  spend-guardrail.sh, billing-alarms.sh
```

## Running any of it

```bash
cp .env.example .env && $EDITOR .env    # ALERT_EMAIL is required, not defaulted
source .env
cd sN-project && bash scripts/deploy.sh
bash scripts/teardown.sh                # same day
```

Built on Windows with Git Bash, which contributes its own hazards — the AWS CLI is a native Windows binary, so `file://` arguments need `cygpath -m`, and `MSYS_NO_PATHCONV=1` breaks `curl -o /dev/null`. Both are documented in [CLAUDE.md](CLAUDE.md) alongside three bugs that recurred often enough to be worth writing down.
