# S5 — Broken Web App Challenge

A CloudFormation stack deploys an ALB + Auto Scaling Group web app with **four deliberately planted faults**. The task is to fix the *running environment* — not the template — with nobody telling you where the faults are.

Built 2026-08-05 · `us-east-1` (mandatory) · stack name `andrey` · **cost ~$0.10** (ALB + 2 `t3.micro`, ~1 h) · stack deleted same day.

Source: DCT *5 AWS Cloud Projects*, project 3.

**→ Full working: [diagnosis.md](diagnosis.md)** — symptom, hypothesis, evidence and fix for each fault, in the order they were actually found.

---

## Result

**4 found · 4 planted · 0 false positives.**

| # | Fault | Symptom it produced | Fix |
|---|---|---|---|
| 1 | Internet-facing ALB placed in **private** subnets with no IGW route | `HTTP 000` — TCP never connects | `set-subnets` to the public subnets |
| 2 | Health check path `/healthcheck.**hmtl**` | targets never pass, permanently | `modify-target-group --health-check-path /healthcheck.html` |
| 3 | ASG has **no** `TargetGroupARNs` | zero registered targets → `503` | `attach-load-balancer-target-groups` |
| 4 | Instance SG allows port **22** from the ALB SG, not 80 | targets `unhealthy`, `Target.FailedHealthChecks` | authorize TCP 80 from the ALB SG |

Verified against the template only after the site returned 200. Every fault I fixed was genuinely planted, and I didn't "fix" anything that wasn't.

---

## How I worked it

**Outside-in, and I did not open the template.** That file is the answer key; reading it converts a debugging exercise into a diffing exercise. The rule was: fix it live, then diff to check.

Each layer's response narrowed the next question:

```
HTTP 000, connect timeout   ->  edge is broken. Not the app, not the instances.
    ALB scheme? active, internet-facing.       fine
    ALB listener? :80 exists.                  fine
    ALB security group? 80 from 0.0.0.0/0.     fine  <- so NOT the firewall
    ALB subnets? private, no 0.0.0.0/0 route.  FAULT 1

HTTP 503                    ->  edge is fine now. No healthy target available.
    Target group config? health check /healthcheck.hmtl.   FAULT 2
    Registered targets? none at all.                       FAULT 3

targets unhealthy           ->  ALB is reaching them and being refused.
    Instance SG? tcp/22 from the ALB SG.                   FAULT 4

HTTP 200  "Congratulations, you did it!"
```

---

## What I learned

**Error codes are a search-space filter, and reading them properly skips whole categories of work.** A connection timeout and a 503 look equally broken to a user and mean opposite things to an engineer: `000` says nothing routable is listening, so the application cannot be the problem; `503` says the ALB is healthy and reachable, so the networking to it is already proven correct. Each observation eliminated half the stack before I inspected a single resource.

**`HealthCheckType: EC2` on an ASG is nearly worthless for a web app.** It reported both instances `Healthy` throughout the entire outage, because it only asks whether the VM is powered on. `ELB` makes the ASG defer to the load balancer — the only health opinion that reflects whether users can actually reach the site. This is the same setting I'd set to `ELB` in S4 without thinking hard about why; here I saw what the wrong value looks like.

**Two faults can hide in one output.** The target group description showed both the typo'd health check path and an empty target list. Those are independent faults with different causes — a wrong health check makes targets *unhealthy*, it does not make them *absent* — and stopping at the first one would have left the second.

**A rule can reference the right thing and still be wrong.** Fault 4 pointed at exactly the correct source security group. Only the port was wrong. It reads as correct at a glance, which is precisely why "SSH from a load balancer" is worth noticing as nonsense.

**The plausible fix is not always the right fix.** Fault 1 could have been "fixed" by adding an internet gateway route to the private route table. The site would have returned 200 and I'd have quietly made every private subnet in the VPC internet-routable. The fault was the ALB's *placement*; the route table was correct. Making the symptom disappear is not the same as fixing the cause.

**Moving an ALB between subnets takes ~105 seconds to become visible**, because it gets new node IPs and DNS has to catch up. Long enough to conclude a correct fix didn't work.

---

## Running it

```bash
bash scripts/deploy.sh      # create the stack, print the URL
bash scripts/teardown.sh    # delete the stack, verify nothing survived
```

The template URL is public: `https://cloud-mastery-bootcamp.s3.amazonaws.com/lab-guides/solutions-architecture/broken-web-app-challenge.json`. It is course material, so it is referenced rather than committed — and downloading it before you finish spoils the exercise anyway.

Must be `us-east-1`; the template hardcodes region-specific values.

## Teardown

`delete-stack` removes everything, including the live changes made during the fix — CloudFormation deletes the resources it created regardless of how they were subsequently modified. Took ~195 s.

Verified after teardown: 0 stacks, 0 load balancers, 0 ASGs, 0 target groups, 0 running instances, 0 available EBS volumes.
