# Diagnosis log — broken web app challenge

Four faults planted in a CloudFormation-deployed stack. Fixed in the **live environment**, not the template. The template was not opened until the site returned 200 — reading it first is reading the answer key.

Method: work outside-in. Each step narrows where the failure can be, and the observation at each layer decides the next question.

---

## Symptom

```
$ curl -m 15 http://andrey-Appli-JOoC7aA1uw9T-682085237.us-east-1.elb.amazonaws.com
HTTP 000   (connect 0.000000s, total 15.007508s)
```

`connect` never completed. Not a 500, not a 503 — nothing answered at the TCP layer. That rules out the application entirely and points at the network edge.

---

## Fault 1 — internet-facing ALB in private subnets

**Hypothesis chain.** DNS resolved (`44.218.216.100`), so the ALB exists and is registered. A TCP timeout with a valid DNS answer means either the security group is dropping the packet or nothing routable is listening.

**Evidence gathered:**

| Check | Result | Verdict |
|---|---|---|
| ALB scheme | `internet-facing` | fine |
| ALB state | `active` | fine |
| Listener | HTTP :80 exists | fine |
| ALB security group ingress | TCP 80 from `0.0.0.0/0` | fine — **not the firewall** |
| ALB subnets | `10.0.1.0/24`, `10.0.3.0/24`, both named `private-…` | suspicious |
| Their route table `rtb-0e14899611bdb25b4` | **only** `10.0.0.0/16 -> local` | **found it** |

The subnets had no `0.0.0.0/0` route. An internet-facing ALB places its nodes in the subnets you give it; with no internet gateway route, those nodes cannot receive traffic from the internet no matter how open the security group is.

The VPC did contain correct public subnets — `10.0.0.0/24` and `10.0.2.0/24`, associated with `rtb-03124bb561a552c3a`, which has `0.0.0.0/0 -> igw-0a7f45c3434696a46`.

**Fix**

```bash
aws elbv2 set-subnets --load-balancer-arn "$ALB" \
  --subnets subnet-091edb0047eebbd74 subnet-0dd33fa297a56c409
```

**Result:** `HTTP 000` → `HTTP 503`. Took ~105 s, because moving subnets gives the ALB new node IPs and the DNS record has to catch up.

> Worth noting the reasoning that avoided a wrong fix: adding an IGW route to the *private* route table would also have produced a 200. It would also have made every private subnet in the VPC public, including whatever else lives there. The fault was the ALB's placement, not the route table's contents.

---

## Fault 2 — health check path typo

A 503 from an ALB means the listener matched but no target was available. So the question moves from "can traffic reach the ALB" to "can the ALB reach anything".

**Evidence:**

```
TargetGroup andrey-ALBTa-AZWQYJHTDFED
  HealthCheckPath : /healthcheck.hmtl     <-- hmtl
  Matcher         : 200
  Registered      : []                    <-- and nothing is registered at all
```

Two separate faults visible in one output. `.hmtl` is a transposition of `.html`; the health check would request a path that does not exist, get 404, and never match the required 200.

**Fix**

```bash
aws elbv2 modify-target-group --target-group-arn "$TG" \
  --health-check-path /healthcheck.html
```

---

## Fault 3 — ASG never attached to the target group

The empty target list was the second finding above, and it is a different fault from the typo — a wrong health check makes targets *unhealthy*, it does not make them *absent*.

**Evidence:**

```
AutoScalingGroup andrey-AutoScalingGroup-e7c646urZwBW
  DesiredCapacity : 2
  Instances       : i-0712fd14cfc6251dc  InService  Healthy
                    i-0a0ea71ccae01b9a0  InService  Healthy
  TargetGroupARNs : []            <-- nothing to register with
```

Two perfectly healthy instances that the load balancer had never been told about. The ASG's own health checks were green because `HealthCheckType: EC2` only asks whether the VM is running — it says nothing about whether the app works or whether anyone can reach it.

**Fix**

```bash
aws autoscaling attach-load-balancer-target-groups \
  --auto-scaling-group-name "$ASG" --target-group-arns "$TG"
```

**Result:** both instances registered, then went `unhealthy` with `Target.FailedHealthChecks` — progress, and the next fault.

---

## Fault 4 — instance security group open on the wrong port

Registered targets failing health checks means the ALB is now trying and being refused. Either the app isn't serving, or something is blocking the ALB→instance hop.

**Evidence:**

```
Instance SG andrey-WebSG-Qs2sr276YUEY
  Ingress: tcp 22-22 from sg-02b924c9eb36f760c   (the ALB's security group)
```

That is the only ingress rule. It references exactly the right source — the ALB security group — on exactly the wrong port. Health checks and traffic go to :80, which nothing permitted.

This is the fault most likely to be misread: the rule *looks* correct at a glance because the source is right, and "SSH from the load balancer" is meaningless in a way that's easy to skim past.

**Fix**

```bash
aws ec2 authorize-security-group-ingress --group-id sg-0e31c11f114d9499b \
  --protocol tcp --port 80 --source-group sg-02b924c9eb36f760c
```

**Result:** both targets `healthy`, site returns 200.

```
Congratulations, you did it!
Welcome to the Website!
Availability Zone = us-east-1b
```

---

## Confirmation against the template

Only after the site worked. Parsed from the CloudFormation JSON:

| # | Template value | Correct value | Found? |
|---|---|---|---|
| 1 | `ApplicationLoadBalancer.Subnets = [PrivateSubnet, PrivateSubnet2]` | public subnets | ✅ |
| 2 | `ALBTargetGroup.HealthCheckPath = /healthcheck.hmtl` | `/healthcheck.html` | ✅ |
| 3 | `AutoScalingGroup.TargetGroupARNs = None` | the target group | ✅ |
| 4 | `WebSG` ingress `FromPort 22, ToPort 22` from `LoadBalancerSecurityGroup` | port 80 | ✅ |

**4 found, 4 planted, 0 things "fixed" that were never broken.**

---

## What the error codes were actually telling me

The single most useful thing in this exercise: each failure mode has a distinct signature, and reading it correctly skipped whole categories of investigation.

| Observed | Means | Do not bother checking |
|---|---|---|
| `HTTP 000`, connect never completes | Nothing routable is listening — subnets, SG, or scheme | the application, the instances |
| `HTTP 503` | ALB reached, no healthy target available | networking to the ALB — that part works |
| Targets `unhealthy` after registering | The ALB is reaching them and being refused, or the check path is wrong | whether the ASG is attached |
| Targets absent entirely | Nothing was ever told to register | health check configuration |

A 503 proves the edge is fine. A connection timeout proves the edge is not. Those two facts alone split the search space in half before any resource is inspected.

The other lesson worth keeping: **`HealthCheckType: EC2` on an ASG is close to worthless for a web app.** It reported both instances `Healthy` for the entire outage. `ELB` is what makes the ASG defer to the load balancer's opinion, which is the only opinion that reflects whether users can reach the site.
