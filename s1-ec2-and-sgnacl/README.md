# S1 — EC2 web server + security group / NACL challenge

Two Digital Cloud Training projects run as one session: a User Data-bootstrapped Apache server, then a custom VPC used to test what can actually reach what.

Built 2026-08-05 · `us-east-1` · **cost: ~$0.13** · torn down same day.

Source: DCT *5 AWS Cloud Projects*, projects 1 and 4.

---

## Part A — Apache from User Data

One `t3.micro` on Amazon Linux 2023 in the default VPC. Apache installed, enabled, and serving a custom page that reports the instance ID and AZ pulled from **IMDSv2** — nothing configured by hand after launch.

```
Apache is serving
Instance  i-0b046228ef63245dc
AZ        us-east-1c
Built     2026-08-05T02:53:05Z
```

`HTTP 200` on the public IP roughly 90 seconds after `run-instances` returned.

### Deviation from the guide, deliberately

The course says **"proceed without a key pair"** and in the same breath tells you to open **port 22 from your IP**. Those instructions contradict each other: with no key pair there is no way to use SSH, so the rule only widens the attack surface.

I attached an instance profile with `AmazonSSMManagedInstanceCore` and used **Session Manager** instead — the agent ships preinstalled on AL2023. Port 22 is never opened anywhere in this project. That is both the working answer and the better one: no key material to manage, no inbound SSH, and every command is logged.

---

## Part B — the connectivity challenge

Custom VPC `10.20.0.0/16`, built component by component rather than through the "VPC and more" wizard, so nothing is implicit:

```
VPC 10.20.0.0/16
├── IGW + 0.0.0.0/0 route on the main route table
├── subnet 10.20.1.0/24  us-east-1a  auto-assign public IPv4   -> instance A (SGA)
└── subnet 10.20.2.0/24  us-east-1b  auto-assign public IPv4   -> instance B (SGB)

SGA  inbound: HTTP 80 from 0.0.0.0/0
SGB  inbound: HTTP 80 from 0.0.0.0/0 + all ICMP from SGA        <- source is the GROUP
```

**No NAT gateway.** The guide says so and it matters — a NAT gateway is ~$32/month and this design has no private subnet that would need one. Verified `0` at both build and teardown.

Ten tests, five phases, every result observed rather than assumed:
**→ [test-matrix.md](test-matrix.md)**

---

## What I learned

**Security groups are stateful per *flow*, not per *pair of hosts*.** At baseline A could ping B but B could not ping A, from the same two machines. A's ping gets its reply back automatically because that's the same flow; B initiating a ping is a brand-new flow that needs its own inbound rule on SGA. Rule direction is the whole story.

**Source-group rules only work on the private path.** Allowing "HTTP from SGA" on SGB lets A reach B on `10.20.2.29` but *not* on B's public address. Traffic sent to a public IP leaves the VPC and comes back through the internet gateway, arriving from an address rather than a group — there is nothing left for the rule to match. This is the answer to "I allowed that security group, why is it still refused?"

**Narrowing a rule to "my IP" cuts internal traffic too.** Restricting SGA to `99.230.7.23/32` broke B's access to A over the *private* address as well. Obvious in hindsight, easy to cause an outage with.

**A NACL deny outranks any security group allow.** One subnet-level rule made both instances unreachable from home while SGB still permitted HTTP from `0.0.0.0/0`. NACLs are evaluated first and apply subnet-wide.

**The real difference is statelessness, and inbound rules don't show it.** Denying *outbound* to my IP while leaving inbound completely open produced the sharpest result of the session: Apache logged `"GET / HTTP/1.1" 200 55` while my client hung and timed out. The server answered; the reply was dropped leaving the subnet. A security group with an identical outbound deny would have done nothing, because it auto-permits return traffic for an established flow. A NACL evaluates every packet alone, in both directions.

That is why NACL rules must account for **ephemeral ports**: allow inbound `:80` but forget outbound `1024–65535` and you will accept every request and answer none of them. It is also the most common wrong answer on the exam.

**SSM kept working through every restriction**, because Session Manager is an *outbound* connection from the instance to the AWS API. Locking down inbound doesn't lock you out — worth knowing before you tighten a rule on something you still need to administer.

---

## Running it

```bash
bash scripts/a-web-server.sh              # Part A: instance + Apache, prints the URL
bash scripts/b-vpc-sgnacl.sh              # Part B: VPC, subnets, SGA/SGB, 2 instances
bash scripts/b-test-matrix.sh "baseline"  # 10 tests, label the phase
bash scripts/b-changes.sh 1               # 1 SGA->home IP  2 NACL deny  3 SGB from SGA
bash scripts/b-changes.sh 4               # 4 ICMP both ways  5 undo NACL  6 outbound deny
bash scripts/teardown.sh                  # everything, dependency order
```

In-instance commands go through `ssm send-command`, so there is no key pair and no SSH anywhere in this project.

## Cost

Three `t3.micro` instances (one in Part A, two in Part B) for about 90 minutes, plus public IPv4 addressing at $0.005/hr each. **≈ $0.13.** No NAT gateway, no load balancer, no EBS beyond the root volumes.

## Teardown

Order is dependency-enforced: instances must reach **`terminated`** (not `shutting-down`) before their ENIs release the subnets, and SGA and SGB reference each other so their rules are revoked before either can be deleted. `scripts/teardown.sh` handles both and is safe to re-run.

Verified after teardown: `s1 instances: 0 · lab VPCs: 0 · NAT gateways: 0 · elastic IPs: 0`.
