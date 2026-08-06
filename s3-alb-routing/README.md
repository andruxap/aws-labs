# S3 — Load-Balanced Architecture with Advanced Request Routing

An Application Load Balancer in front of two EC2 instances in two AZs, routing first by **URL path** and then by **host header** to the same pair of target groups.

Built 2026-08-05 · `us-east-1` · **cost ~$0.14** (ALB ~$0.0225/hr, built and torn down inside two hours) · torn down same day.

Source: DCT *5 AWS Cloud Projects*, project 2.

---

## Architecture

```
                       ┌──────────── ALB (internet-facing, 1a + 1b) ─────────────┐
  client ───────────►  │  listener :80                                           │
                       │    rule 1  ──► target group s3-red-tg  ──► Red   (1a)   │
                       │    rule 2  ──► target group s3-blue-tg ──► Blue  (1b)   │
                       │    default ──► fixed-response 404                       │
                       └────────────────────────────────────────────────────────┘

  Instances pull their page from S3 at boot via an instance profile
  scoped to one bucket.  The servers are disposable; the code is not.
```

Only the **rule conditions** change between the two exercises. Same ALB, same target groups, same instances.

| | Rule condition | Result |
|---|---|---|
| Path-based | `path-pattern = /red*` | `ALB-DNS/red/` → Red |
| Host-based | `host-header = red.lab.andruxa.dev` | `red.lab.andruxa.dev` → Red |

---

## Verified

Each page is stamped at boot with the instance ID and AZ that served it, so routing is proven at the instance level rather than by colour alone.

**Path-based:**

```
/red/       -> RED    i-0a068ea1473cc6f89  us-east-1a
/blue/      -> BLUE   i-07869e5cd07aab046  us-east-1b
/           -> 404 "no rule matched"
```

**Host-based**, after deleting the path rules and adding host-header rules:

```
red.lab.andruxa.dev   -> RED    i-0a068ea1473cc6f89
blue.lab.andruxa.dev  -> BLUE   i-07869e5cd07aab046
lab.andruxa.dev       -> 404 "no rule matched"
```

The clean part is what the raw ALB hostname does *at the same moment*:

```
http://lab-s3-alb-1105599323.us-east-1.elb.amazonaws.com/red/   -> 404
http://lab-s3-alb-1105599323.us-east-1.elb.amazonaws.com/blue/  -> 404
```

Identical path, identical load balancer, identical target groups — and a 404, because the only thing the rules now examine is the `Host` header. Three DNS names resolve to one ALB, and the ALB decides what each one is by reading a header the client didn't know it was sending.

---

## Departures from the guide

**The course's asset bundle is missing** from the exported folder (`advanced-request-routing-code.zip`, referenced but not present). The four files it would have contained are written from scratch here: `app/red/index.html`, `app/blue/index.html`, one parameterised `user-data/color.sh`, and `policies/bucket-read.json`. Having them in the repo is better than a download link anyway.

**One User Data script, not two.** The course ships `user-data-red` and `user-data-blue`, which are the same file with a word changed. `deploy.sh` substitutes `__COLOR__` and `__BUCKET__` before launch.

**Scoped bucket policy.** The guide's policy grants broad S3 access; this one grants `s3:ListBucket` on exactly one bucket and `s3:GetObject` on exactly its contents.

**The default listener action is a 404, not a target group.** The course forwards unmatched traffic to a target group, which makes a broken rule look like a working one — you get a page either way. Returning `404 "no rule matched"` means every test result is unambiguous, and it's what made the comparison above meaningful.

**Health checks target the colour's own page** (`/red/index.html`), not `/`. Nothing is ever served from the document root, so `/` returns 403 and a health check pointed there would fail forever while the app worked perfectly.

**No key pair, no port 22.** Instances use SSM, as in S1.

---

## What I learned

**Host-based and path-based routing are the same feature with a different condition.** Swapping between them touched nothing but two rule conditions — not the ALB, not the target groups, not the instances, not the application. The routing decision is entirely a property of the listener.

**One ALB can serve many domains.** Three DNS names pointed at one load balancer and the host-header rules separated them. This is how you avoid paying $16/month per site — the alternative, one ALB per domain, is the expensive mistake this feature exists to prevent.

**Health check paths must match what the app actually serves.** Pointing a check at `/` when the app lives at `/red/` fails permanently, targets never enter service, and the ALB returns 503 with no obvious cause. This is the most common ALB misconfiguration and worth recognising on sight — it's very likely one of the four planted faults in S5.

**Alias records, not CNAMEs.** An ALB's IP addresses change, so the record type is an A/ALIAS pointing at the ALB's canonical hosted zone ID. An apex domain can't be a CNAME at all, which is why Route 53 aliases exist.

**Rule priority is evaluation order.** Lower number wins, and the default action only runs when nothing matched.

---

## Running it

```bash
bash scripts/deploy.sh          # bucket, IAM, instances, target groups, ALB, PATH rules
bash scripts/host-routing.sh    # swap to HOST rules + Route 53 records
bash scripts/teardown.sh        # everything, including the DNS records
```

DNS records live under `lab.andruxa.dev` in the production hosted zone, created by hand and deleted at teardown. `infra/prod` never learns about them, and Terraform doesn't prune records outside its own state, so the nightly drift check stays clean.

## Teardown notes

Order is dependency-enforced and the ALB comes early because it's the only meaningful cost.

1. Route 53 records — a `DELETE` must repeat the record set **exactly**, so the script reads each one back rather than reconstructing it.
2. ALB, and wait for `load-balancers-deleted` — billing stops here.
3. Target groups. **These failed to delete on the first run**: they stay attached briefly after the ALB reports deleted, `delete-target-group` returns `ResourceInUse`, and the original script's `|| continue` skipped silently past the error. Both were left behind and the verify count caught it. Now retried with an explicit warning if it gives up — a teardown that quietly half-works is worse than one that fails loudly.
4. Instances → security group (ALB ENIs linger, so retried) → bucket → IAM.

Verified after teardown: 0 lab load balancers, 0 `s3-*` target groups, 0 lab instances, 0 `lab.andruxa.dev` records.

> Unrelated pre-existing orphan noticed while verifying: a target group named `demo-tg-alb` with no load balancer attached. Not created by this lab and left alone. Target groups are free, so it costs nothing — but it's the kind of thing worth cleaning up eventually.
