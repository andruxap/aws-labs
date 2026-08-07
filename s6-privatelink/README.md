# S6 — Multi-VPC Networking with PrivateLink

Three isolated VPCs. An internal app in **Shared Services** — private subnet, no public IP, no internet gateway — published through an internal NLB as a **VPC Endpoint Service**, and consumed from **Payments** and **Analytics** through Interface Endpoints. No peering, no transit gateway, no NAT.

Built 2026-08-07 · `us-east-1` · **cost ~$0.23** (1 NLB + 5 interface endpoints + 3 `t3.micro`, ~2 h) · torn down same day.

Source: Tech With Lucy *5 AWS Projects*, project 3. **Lesson 3.6 (final testing) is missing from the export** — the validation below is written from scratch, which turned out to be the most valuable part.

---

## Architecture

```
  Payments 10.10.0.0/16                          Shared Services 10.30.0.0/16
  ┌─────────────────────────┐                    ┌──────────────────────────────────┐
  │ client 10.10.0.x        │                    │  NO internet gateway             │
  │ interface endpoint ─────┼──── PrivateLink ──►│  internal NLB (10.30.1/2.x)      │
  │   ENI 10.10.1.217       │                    │       │                          │
  └─────────────────────────┘                    │       ▼                          │
                                                 │  app 10.30.1.7                   │
  Analytics 10.20.0.0/16                         │  private subnet, no public IP    │
  ┌─────────────────────────┐                    │                                  │
  │ client 10.20.0.x        │                    │  + S3 gateway endpoint (free)    │
  │ interface endpoint ─────┼──── PrivateLink ──►│  + SSM interface endpoints x3    │
  └─────────────────────────┘                    └──────────────────────────────────┘
```

The consumer never learns a route to `10.30.0.0/16`. It talks to an **ENI inside its own VPC** that projects the provider's service locally.

---

## Validation — the missing lesson 3.6

Proving a consumer *can* reach the provider is the easy half. PrivateLink's actual claim is stronger: it reaches it **without the traffic touching the internet and without the VPCs being connected**. So [`scripts/test.sh`](scripts/test.sh) asserts the negatives too.

```
== 1. Consumers can reach the provider through PrivateLink ==
     payments  -> shared-services-app i-084c592d646a4a00f 10.30.1.7 public=NONE   PASS
     analytics -> shared-services-app i-084c592d646a4a00f 10.30.1.7 public=NONE   PASS

== 2. The provider has no public identity ==
     provider public IP: None                                                     PASS

== 3. The provider's subnet has no internet route ==
     10.30.0.0/16 local | pl-63a5400a -> vpce (S3 gateway)                        PASS
     internet gateways attached to the provider VPC: 0                            PASS

== 4. The VPCs are not connected to each other ==
     active peering connections: 0   transit gateways: 0                          PASS

== 5. A consumer cannot reach the provider's private IP directly ==
     payments -> http://10.30.1.7 : UNREACHABLE                                   PASS

== 6. What the consumer actually talks to ==
     endpoint DNS resolves to 10.10.1.217  — an ENI in the PAYMENTS VPC
```

Seven assertions. Tests 4 and 5 are what make test 1 mean anything: both consumers reach a service whose VPC has **no internet gateway at all**, and neither can reach that provider's own address.

---

## What broke

**The provider instance couldn't install its own web server.**

The first validation run failed test 1 while every negative passed. The NLB target was `unhealthy`, and my first instinct — the security group, since NLB client-IP preservation makes targets see the *consumer's* address rather than the load balancer's — was wrong. Checking the instance first:

```
$ systemctl is-active httpd
inactive
$ tail /var/log/cloud-init-output.log
/var/lib/cloud/instance/scripts/part-001: line 30: /var/www/html/whoami.txt: No such file or directory
Failed to restart httpd.service: Unit httpd.service not found.
```

`dnf install -y httpd` had failed silently. Of course it had — the instance sits in a private subnet with no NAT and no IGW **by design**, and package repositories are on the internet. The architecture that makes the lab's point also prevents the lab from building.

**Fix: an S3 gateway endpoint.** Amazon Linux 2023's dnf repositories are served from S3 in-region, so a gateway endpoint gives the private subnet a route to them:

```bash
aws ec2 create-vpc-endpoint --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.us-east-1.s3 --route-table-ids "$RT"
```

`dnf install` then succeeded with still no NAT and no IGW anywhere. **Gateway endpoints are free** — S3 and DynamoDB only — while interface endpoints bill ~$0.01/hr per AZ. That price difference is worth remembering: reaching S3 privately costs nothing, reaching almost anything else costs money.

The lesson generalises: **a private instance needs a deliberate path for its own bootstrap**, or it can't become the thing you're building. The options are a NAT gateway (~$32/mo), gateway/interface endpoints (free for S3, cheap otherwise), or baking the software into an AMI. The course doesn't mention this, which suggests their environment had a NAT.

---

## What I learned

**PrivateLink is one-directional exposure, not connectivity.** Peering joins two networks and both sides gain routes. PrivateLink gives the consumer an ENI representing *one service* — the consumer never learns a route to `10.30.0.0/16` and cannot reach anything else in it. Test 5 proves it: the provider's own IP is unreachable from a consumer that is happily using its service. That asymmetry is the security property, and the reason CIDR overlap between the two VPCs wouldn't matter.

**SSM through interface endpoints is PrivateLink used on yourself.** The provider instance has no internet path, yet Session Manager reached it via `ssm`, `ssmmessages` and `ec2messages` interface endpoints — the same mechanism the lab is teaching, applied to AWS's own APIs. That is also how you administer genuinely isolated instances in production.

**Client IP preservation changes who the target thinks is calling.** NLB instance targets default to `preserve_client_ip.enabled = true`, so the app sees the *consumer's* address, not the NLB's. A security group scoped to the provider VPC's CIDR would break traffic that arrives correctly. It wasn't the cause here, but it's a real trap and the reason the app SG needed thinking about.

**Endpoint services need explicit consumer permissions**, even inside one account — `modify-vpc-endpoint-service-permissions` with the account principal. Cross-account is the normal case for this feature.

**PrivateLink vs peering vs transit gateway** — the interview question this project exists to answer:

| | Exposes | Scale | CIDR overlap | Cost shape |
|---|---|---|---|---|
| **PrivateLink** | **one service**, one direction | many consumers, no route explosion | **fine** | per endpoint-hour + per GB |
| **Peering** | the whole VPC, both directions | n² connections, no transitivity | **breaks** | data transfer only |
| **Transit Gateway** | whole VPCs via a hub | hub-and-spoke, transitive | breaks | attachment-hour + per GB |

Peering for a few VPCs that trust each other completely. Transit Gateway when many VPCs need general routing. PrivateLink when you want to publish *a service* to consumers you don't want inside your network — a SaaS vendor, another business unit, a regulated boundary.

---

## Running it

```bash
bash scripts/deploy.sh    # 3 VPCs, NLB, endpoint service, 2 interface endpoints
bash scripts/test.sh      # 7 assertions, positives and negatives
bash scripts/teardown.sh
```

## Teardown notes

The strictest dependency order of any lab so far, all of it enforced by AWS:

**interface endpoints → endpoint service → NLB → target group → instances → per VPC: security groups → IGW → subnets → VPC**

A VPC cannot be deleted while an endpoint lives in it, and an endpoint service cannot be deleted while a consumer endpoint is still attached. Security groups need a retry loop because endpoint ENIs linger for a minute after the endpoint reports deleted.

**Interface endpoints are the thing to actually watch.** Five existed here (two consumer + three SSM), each ~$0.01/hr per AZ, and they appear in **no EC2 console view** — only under VPC → Endpoints. That is roughly $36/month of invisible spend if a teardown misses them, which is why teardown step 1 deletes them and step 8 counts them.

Verified after teardown: 0 VPC endpoints, 0 endpoint services, 0 VPCs, 0 instances, 0 load balancers, **0 NAT gateways**.
