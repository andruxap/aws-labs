# S4 — Blue/Green and Rolling Deployments

Two Auto Scaling Groups behind one ALB. Traffic moves between them by changing a single listener action; then the live environment is upgraded in place with an Instance Refresh. Every claim below is measured rather than asserted.

Built 2026-08-05 · `us-east-1` · **cost ~$0.20** (1 ALB + 4 `t3.micro`, ~2 h) · torn down same day.

Source: Tech With Lucy *5 AWS Projects*, project 2.

---

## Architecture

```
                    ┌── ALB listener :80 ──┐
   client ────────► │  default action ──┐  │
                    └───────────────────┼──┘
                                        │
              ┌─────────────────────────┴─────────────────────────┐
              ▼                                                   ▼
      s4-blue-tg                                          s4-green-tg
      lab-s4-blue-asg  (desired 2)                lab-s4-green-asg  (desired 2)
      launch template v1  BLUE v1.0               launch template v2  GREEN v2.0
```

One launch template, one version per (environment, app version). The ASGs differ only in which version they point at. **The cutover is one `modify-listener` call** — nothing is created, destroyed, or restarted.

Each instance serves `/whoami.txt` containing `ENVIRONMENT VERSION INSTANCE-ID`, which is what makes all of this measurable from a shell loop.

---

## Measured results

### 1. Blue/green cutover — zero loss, but not instant

Polled continuously across a green→blue switch:

```
requests sent    : 62
HTTP 200         : 62
failed / non-200 : 0
switch issued at : request #4
first BLUE at    : request #48
```

**Nothing failed.** But 44 requests were served by the *old* environment after the switch was issued. A listener change is not atomic from the client's point of view — it propagates across the ALB's nodes over roughly 40 seconds.

That reframes "instant rollback": what's instant is *issuing* it. If you're rolling back because production is broken, users keep hitting the broken version for another half-minute or so. Worth knowing before you promise a number in an incident review.

### 2. Rolling refresh — zero loss, mixed versions in flight

New launch template version (`BLUE v1.1`), ASG repointed, `start-instance-refresh` with `MinHealthyPercentage=50`:

```
requests during refresh : 43
HTTP 200                : 43
failed / non-200        : 0
versions observed       : v1.0  v1.1
duration                : ~430 s for 2 instances
```

**Both versions served traffic simultaneously.** That is not a defect, it is what a rolling deploy *is* — and it is the constraint blue/green doesn't have. If v1.1 changes an API contract, writes a new database column, or alters a session format, then for seven minutes clients randomly get one version or the other. Rolling deploys require backward compatibility between consecutive versions; blue/green does not.

Also worth noting: repointing the ASG at the new version changed nothing on its own. Existing instances kept serving v1.0 until the refresh actually replaced them. The launch template is the *desired* state, not the running one.

### 3. Abrupt termination — this one does lose requests

Same fleet, same ALB. An in-service instance terminated out of band, polled ~5/s for two minutes:

```
samples          : 638
HTTP 200         : 612
failed / non-200 : 26        (19x HTTP 502, 7x connection failure)
first failure    : 16 samples after termination
failure window   : 52 samples
```

**~4% of requests failed.** Compare against 0% for both planned changes above.

The difference is deregistration. In a planned cutover or refresh, the ALB is told to stop using a target and drains existing connections first. An out-of-band `terminate-instances` gives it no warning, so the ALB keeps routing to a dead target until its own health check notices — two consecutive failed checks at a 10-second interval here, which matches the ~16-sample delay before the first 502.

This is the argument for connection draining, health-check tuning, and ASG lifecycle hooks, and it's the one result of the three that a diagram wouldn't have told you.

### 4. Self-healing

The ASG replaced the terminated instance without intervention, back to `desired=2` and both `InService` within about a minute. `health-check-type=ELB` means the ASG trusts the load balancer's opinion of health, not just whether the VM is powered on.

---

## Blue/green vs rolling — the actual trade-off

| | Blue/Green | Rolling |
|---|---|---|
| Capacity during deploy | **2×** — both environments full | 1× |
| Cost | Double, for the deploy window | Flat |
| Switch | One listener action | Gradual, instance by instance |
| Rollback | Switch back (~40 s to take effect) | Roll forward again (~7 min here) |
| Mixed versions live | **Never** | **Always, during the roll** |
| Needs backward-compatible versions | No | **Yes** |

Blue/green buys version isolation and fast rollback with money. Rolling buys cheapness with a compatibility requirement and a slower reverse gear. Neither is "better" — the question is whether your v(n) and v(n+1) can coexist, and whether you can afford double capacity.

---

## Departures from the guide

**No key pair.** Lesson 2.2 has you create `ztc-project2-key`. Instances use SSM instead, as in S1 and S3 — no inbound SSH anywhere.

**One parameterised User Data script**, substituted per launch template version, rather than separate blue and green files.

**Health check on `/whoami.txt`**, a plain-text endpoint, so scripts assert on content without parsing HTML.

**Not done: warm pools and lifecycle hooks.** The guide covers both. I skipped them deliberately — a warm pool keeps *stopped* instances whose EBS volumes still bill, and the teardown-verification value didn't justify it here. The teardown script does check for stray stopped instances and available volumes for exactly that reason. This is a gap in coverage, not a claim they aren't useful.

---

## Running it

```bash
bash scripts/deploy.sh          # launch template, 2 target groups, ALB, 2 ASGs
bash scripts/cutover.sh green   # measured blue -> green
bash scripts/cutover.sh blue    # measured rollback
bash scripts/refresh.sh v1.1    # new LT version + rolling instance refresh
bash scripts/kill-test.sh       # terminate an instance, measure what clients see
bash scripts/teardown.sh
```

## Teardown notes

ASGs first with `--force-delete` — that terminates their instances, and nothing else can be removed while those hold ENIs. Then the ALB (billing stops there), then target groups, launch template, security group, IAM.

The target-group retry carried over from S3, where the first version of that teardown silently skipped a `ResourceInUse` failure and left both groups behind. Here it worked first time.

Verified after teardown: 0 ASGs, 0 load balancers, 0 `s4-*` target groups, 0 instances, **0 available EBS volumes, 0 stopped instances**. Those last two matter because warm pools and detached root volumes are the classic things that survive a teardown and keep billing.
