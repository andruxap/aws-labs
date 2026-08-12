# S9 — Global Accelerator Multi-Region Failover

The same app in two regions, each behind its own ALB, fronted by AWS Global Accelerator as a single anycast entry point. Break a region and traffic moves — without DNS changing at all.

Built 2026-08-12 · `us-east-1` + `us-west-2` · **cost ~$0.30** · torn down same day.

Source: Tech With Lucy *5 AWS Projects*, project 5. This is the counterpart to [S8](../s8-multiregion-dr/), which solves the same problem with DNS.

---

## Architecture

```
                    client
                      │
        ┌─────────────┴─────────────┐
        │  15.197.135.241            │   two static anycast IPs
        │  166.117.161.57            │   they never change, in any region
        └─────────────┬─────────────┘
              AWS Global Accelerator
              listener :80, health check /health every 10s
                      │
         ┌────────────┴────────────┐
         ▼                         ▼
  endpoint group             endpoint group
  us-east-1                  us-west-2
  ALB → EC2 (blue)           ALB → EC2 (green)
  10.90.0.0/16               10.91.0.0/16
```

Both endpoint groups run at `TrafficDialPercentage=100`, so **health decides where traffic goes**, not weighting.

---

## Measured

The primary was broken by deregistering its only target, so the ALB had no healthy backend and answered 503. Global Accelerator's health check then failed and it withdrew the endpoint. Polled continuously throughout at ~5 req/s.

```
requests           : 233
HTTP 200           : 154
failed (503)       :  79
failover  (break    -> us-west-2 serving) : 25s
failback  (recover  -> us-east-1 serving) : 22s
```

> The test script reported 28 s; recomputing from the raw samples in
> [`data/s9-failover.log`](../data/s9-failover.log) gives **25 s**. The script
> polled on a 5-second sleep, so its figure carried that granularity. The
> smaller number is the accurate one and the log is committed so anyone can
> check it.

**Failover took 25 seconds and 34% of requests failed during it.**

The transition, second by second:

```
+0s .. +3s    200  us-east-1     ALB still draining, target already deregistered
+4s           503                ALB has no healthy target
+4s .. +25s   503                GA still routing here — its own check hasn't tripped yet
+25s          200  us-west-2     endpoint withdrawn, traffic moved
+30s          last 503           a 5s tail still reaching the withdrawn endpoint
```

That 26-second block of 503s (+4s to +30s) is the important part, and it isn't a misconfiguration. Global Accelerator's health check was already at its tightest useful setting: 10-second interval, threshold 2. That's a **20-second detection floor** before it can possibly know the region is unhealthy, and during detection it keeps sending traffic to the broken region.

---

## The three-way comparison

This is what running S4, S8 and S9 was for.

| | Mechanism | Failover | Errors during | Data | Cost floor |
|---|---|---|---|---|---|
| **[S4](../s4-blue-green/)** Blue/green | listener rule swap, one region | ~40 s to propagate | **0** — target drained first | shared | one ALB |
| **[S8](../s8-multiregion-dr/)** DNS failover | Route 53 stops answering with the primary | **60–80 s** | yes, the whole window | **replicated** (Global Table) | ~$1/mo health checks |
| **S9** Anycast | GA withdraws an unhealthy endpoint | **25 s** | yes, 26 s of it | none — stateless | **~$18/mo fixed** |

**Anycast is roughly 2.5-3× faster than DNS, and neither prevents the outage.**

The reason is that they fail for different parts of the same total. Both have a detection floor of `interval × threshold`:

- **S8**: 30 s × 2 = **60 s floor**, *plus* resolver caching on top, because the mechanism is "stop handing out the old address" and clients hold addresses they've already been given.
- **S9**: 10 s × 2 = **20 s floor**, plus nothing. The client never re-resolves anything — the same two anycast IPs stay valid, and AWS changes what those IPs route to inside its own network.

So anycast eliminates the DNS-caching penalty entirely and permits a tighter health-check interval. What it cannot do is detect a failure faster than it checks. **You cannot get below detection time with either mechanism**, and any RTO claim that ignores the detection window is wrong.

If you need genuinely zero errors, failover isn't the tool — you need both regions serving simultaneously, which is a different and more expensive architecture.

### What each one is actually for

- **S4 blue/green** — deploying without downtime, one region. Not a DR mechanism at all; it just looks like one.
- **S8 DNS failover** — cheap, works with any endpoint type, carries replicated data. Correct when a ~60–90 s RTO is acceptable and you don't want a fixed monthly cost.
- **S9 anycast** — faster and gives clients static IPs (which matters when a partner has firewalled your addresses). But $18/month before a single request, and here it moved *stateless* traffic. Combining it with S8's Global Table is what a real design does.

---

## What I learned

**Static anycast IPs are a feature in their own right**, separate from failover speed. Two IPs that never change, ever, in any region — that's what lets a client with a firewall allowlist or an IoT fleet with baked-in addresses survive a region migration. DNS failover cannot offer this at all.

**The accelerator is invisible in every per-region view.** Its control plane lives in `us-west-2` regardless of where the endpoints are, so `aws globalaccelerator list-accelerators --region us-west-2` is the *only* query that finds it. A per-region sweep across every region you used will not.

**It must be disabled before it can be deleted**, and disabling takes a minute or two to reach `DEPLOYED`+`Enabled=false`. A teardown script that calls delete immediately fails, and if it fails quietly you're left paying $18/month for something you believe is gone. That's why [`teardown.sh`](scripts/teardown.sh) polls for the disabled state, retries the delete, and then re-checks and shouts if it's still there.

**Deregistering a target is a clean, reversible way to break a region.** No instance is harmed, the failure is real from the load balancer's perspective, and recovery is one `register-targets` call — which is what made measuring failback as easy as failover.

**Failback was faster than failover** (22 s vs 25 s), and it's worth knowing why: a target becoming healthy needs 2 passing checks at 10 s, while the failure path also had to wait for the ALB's own draining behaviour before it started returning 503.

---

## Running it

```bash
bash scripts/deploy.sh          # 2 regions, 2 ALBs, accelerator, ~4 min
bash scripts/failover-test.sh   # break, measure, recover, measure
bash scripts/teardown.sh        # accelerator FIRST, confirmed
```

## Cost, and why this was the last project built

~$0.10/hr while running: Global Accelerator **$0.025/hr fixed**, two ALBs $0.045/hr, two `t3.micro` $0.021/hr. Trivial for an afternoon; **~$70/month if forgotten**, and the accelerator's share of that keeps accruing in a console view nobody looks at.

That combination — highest hourly cost of the nine, and the easiest to leave running by accident — is why this one was deliberately built last, in one sitting, with the teardown script written before the failover test was run.

Verified after teardown: **0 accelerators**, and `ec2=0 alb=0 vpc=0 eip=0` in both regions.
