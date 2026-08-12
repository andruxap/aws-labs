# Lessons

Findings from nine builds, grouped by what they're actually about rather than which lab produced them. Each one was observed, not read.

---

## Queues, streams and fan-out

**A queue is not a broadcast.** Point two consumers at one SQS queue and you haven't built fan-out, you've built a race. Each message goes to exactly one of them. ([S2](../s2-event-driven-orders/))

**A filtering consumer on a shared queue is a silent message sink.** EventBridge Pipes doesn't leave the messages its filter rejects — it deletes them. So a Pipe sharing a queue with a worker doesn't just occasionally win; it eats everything that doesn't match its filter and drops it on the floor. The worker starves and nothing reports an error. Real fan-out needs SNS, EventBridge, or a stream that supports multiple independent consumers.

**Business failure and technical failure need opposite handling.**

| | Business failure | Technical failure |
|---|---|---|
| Example | `amount > 10000` | DynamoDB timeout, malformed JSON |
| Handling | consume the message, mark `FAILED` | `throw` — let the queue retry |
| Retried? | No — retrying can't change the answer | Yes |
| Ends in the DLQ? | No | Yes, after N attempts |

Get this backwards and you either retry forever or lose errors silently.

**The DLQ is the cheapest failure signal in an event-driven system.** One alarm on `ApproximateNumberOfMessagesVisible >= 1` covers every failure mode downstream of the queue.

**A stream handler that writes back to its own table will re-trigger itself.** The `eventName != "INSERT"` guard is what stops the loop.

**SNS→SQS needs `RawMessageDelivery=true`** or the body arrives wrapped in an envelope and every downstream parser and filter breaks.

---

## Load balancers and deployment

**Planned changes drain; unplanned ones don't.** Measured on one fleet: ([S4](../s4-blue-green/))

| Change | Requests | Failed |
|---|---|---|
| Blue→green listener swap | 62 | **0** |
| Rolling instance refresh | 43 | **0** |
| Abrupt `terminate-instances` | 638 | **26** (19× 502) |

A planned change deregisters the target and lets connections finish. An out-of-band termination gives the load balancer no warning, so it keeps routing to a dead host until its own health checks fail — which matched the observed 16-sample delay before the first 502. This is what `deregistration_delay` and lifecycle hooks are for.

**"Instant rollback" is instant to issue, not to take effect.** 44 requests were served by the old environment after the cutover was issued; a listener change propagates over ~40 s.

**Rolling deploys serve mixed versions by definition.** Both `v1.0` and `v1.1` answered during a 430 s refresh. That's not a defect — it's the constraint blue/green doesn't have. Consecutive versions must be backward compatible, or you can't roll.

**Pointing an ASG at a new launch template version changes nothing** until a refresh runs. The template is *desired* state, not running state.

**Health checks should ask for something specific.** A check on `/` passes while the app is broken; `/whoami.txt` or `/red/index.html` proves the thing you actually care about is being served.

---

## Networking

**Security groups are stateful per *flow*, not per *host pair*.** A could ping B while B couldn't ping A — same two machines. A's ping and its reply are one flow; B initiating its own is a new flow needing its own inbound rule. ([S1](../s1-ec2-and-sgnacl/))

**NACLs are stateless, and it's observable rather than theoretical.** Deny only *outbound* to one address, leave inbound wide open, and the server logs `200 55` while the client hangs forever. The request arrives, the app answers, the reply is dropped leaving the subnet. The same rule in a security group does nothing, because an SG auto-permits return traffic for an established flow. This is why NACL rules must account for **ephemeral ports** on the return path.

**A NACL deny outranks any security group allow.** Subnet-level, evaluated first.

**Source-group rules only match on the private path.** "Allow HTTP from SGA" lets A reach B's *private* address but not its public one — traffic that leaves via the internet gateway comes back as an address, with no group left to match. This is the answer to "I allowed that security group, why is it still refused?"

**Narrowing a rule to "my IP" cuts internal traffic too.** Obvious in hindsight; easy to cause an outage with.

**PrivateLink is one-directional exposure, not connectivity.** Peering joins two networks and both sides gain routes. PrivateLink gives the consumer an ENI representing *one service* — it never learns a route to the provider's CIDR and can't reach anything else there. Verified: the provider's own IP was unreachable from a consumer happily using its service. That asymmetry is the security property, and why CIDR overlap doesn't matter. ([S6](../s6-privatelink/))

| | Exposes | CIDR overlap | Cost shape |
|---|---|---|---|
| PrivateLink | one service, one direction | fine | per endpoint-hour + per GB |
| Peering | the whole VPC, both ways | breaks | data transfer only |
| Transit Gateway | whole VPCs via a hub | breaks | attachment-hour + per GB |

**A private instance needs a deliberate path for its own bootstrap.** No NAT and no IGW also means no package repositories. Options: NAT gateway (~$32/mo), gateway endpoint (free for S3 and DynamoDB), interface endpoint (~$0.01/hr/AZ), or bake an AMI. AL2023's `dnf` repos are in S3, so a **free** gateway endpoint solves it.

**Interface endpoints for `ssm`/`ssmmessages`/`ec2messages` are PrivateLink used on yourself** — how you administer a genuinely isolated instance.

---

## Data and migration

**DMS migrates data, not databases.** Every row arrived; zero users, grants, stored procedures, triggers or events did. The app failed on the first connection after cutover until the credentials were recreated by hand. "The migration succeeded" and "the application works" are different claims. ([S7](../s7-onprem-migration/))

**RDS deletion protection blocks deletion, and the button just greys out.** The classic "why is my bill still running" trap.

**A kept final snapshot keeps billing** after the instance is gone.

**DynamoDB `Decimal` isn't JSON-serializable.** `json.dumps()` on a scan result raises `TypeError` the moment any attribute is numeric.

**`status` is a DynamoDB reserved word** — hence `ExpressionAttributeNames: {"#s": "status"}` in every update.

---

## Multi-region

**TTL is the floor on failover speed.** However fast the health check notices, a resolver holding a cached answer keeps using it until the TTL expires. Worst case is `threshold × interval + TTL`; measured was 60–80 s against a 150 s worst case. ([S8](../s8-multiregion-dr/))

**Never point a health check at the record it controls.** The primary fails, DNS moves to secondary, the primary's check now resolves to the *secondary* and reports healthy, traffic flaps back to a broken region. A DR setup that can't fail back is worse than one that can't fail over, because it looks fine.

**Failback is a separate thing from failover and needs its own test.** Plenty of setups fail over correctly and never come home.

**Regional API Gateway needs its certificate in its own region** — not the us-east-1 rule that applies to CloudFront.

**Anycast is faster than DNS failover, and neither prevents the outage.** Measured: DNS 60–80 s, anycast 28 s. Anycast removes the resolver-caching penalty entirely — the client never re-resolves, the same static IPs stay valid, and AWS changes what they route to internally. What it cannot do is detect a failure faster than it checks. Both have a floor of `interval × threshold`, and ~34% of requests failed during S9's 28 s window. Zero-error failover isn't a failover configuration; it needs both regions serving simultaneously. ([S9](../s9-global-accelerator/))

**Static anycast IPs are a feature independent of failover speed.** Two addresses that never change in any region are what let a partner's firewall allowlist or an IoT fleet with baked-in addresses survive a region migration. DNS failover cannot offer this at all.

**Global Accelerator must be disabled before it can be deleted**, and disabling isn't instant. A teardown that calls delete immediately fails — and if it fails quietly you keep paying ~$18/month for something you believe is gone. Poll for the disabled state, retry the delete, then re-check and shout.

---

## Terraform

**A provider block is per-region; there is no `region` argument on a resource.** Multi-region means multiple providers distinguished by `alias`, with every regional resource naming its own. Get it wrong and the resource is built in the wrong region and nothing complains. ([S8 terraform](../s8-multiregion-dr/terraform/))

**Terraform can't `for_each` over providers** — an alias isn't a value. Production puts the regional half in a module and calls it twice with different `providers = {}`.

**IaC turns a procedure into a value.** The blue/green cutover stops being a `modify-listener` call and becomes `-var active_environment=green`, read by exactly one resource. The property stops depending on executing steps correctly. ([S4 terraform](../s4-blue-green/terraform/))

**`create_before_destroy` where a resource is referenced while in use** — a launch template a running ASG points at can't be destroyed. This is the ordering hand-written scripts get wrong.

**`templatefile()` and shell scripts collide on `$`.** Terraform reads `${VAR}` as its own interpolation, so every shell variable needs `$${VAR}`. Miss one and the error points at the template, not the line.

**`terraform destroy` replaces a 100-line teardown script** and its hand-maintained dependency ordering. The strongest practical argument for IaC in this repo.

---

## Operations and cost

**AWS has no hard spending cap.** Budgets alert; they don't stop. The closest mechanism is a Budget Action attaching a deny policy — and it must never block `Delete`/`Terminate` (a freeze that traps you with running resources makes the bill worse) or `iam:*` (so you can lift it).

**The expensive mistakes are invisible in the console you're looking at.** Interface endpoints appear only under VPC → Endpoints. Global Accelerator appears in no per-region view at all. Warm-pool instances sit in `Stopped` and don't show under a "running" filter. Elastic IPs bill while detached.

**Teardown order is dependency-enforced and unforgiving.** Instances must reach `terminated`, not `shutting-down`, before their ENIs release. Security groups that reference each other need their rules revoked before either can go. Target groups return `ResourceInUse` for a while after the load balancer is deleted.

**A teardown that quietly half-works is worse than one that fails loudly.** An early version used `|| continue` past a delete failure and left two target groups behind. Every teardown now retries, warns if it gives up, and ends by *counting* what remains — including `available` EBS volumes and `stopped` instances.

**Debug outside-in, and check the cheapest thing first.** In [S6](../s6-privatelink/) the target was unhealthy and my first instinct was NLB client-IP preservation and security groups. The actual cause was that the web server had never installed. One `systemctl is-active httpd` would have saved twenty minutes of theorising.

**Isolate one variable to prove a cause.** The Pipe race was confirmed by stopping the Pipe and changing nothing else — the same orders then completed. That's the difference between a diagnosis and a guess.

---

## The courses themselves

Both course exports had defects worth cataloguing, because catching them is the actual skill:

- **Code that doesn't compile as published.** Every template literal in one course's Lambda code lost its backticks in export; nothing ran.
- **CommonJS in a file the console creates as ESM** — `exports is not defined in ES module scope`.
- **`*FullAccess` policies throughout**, replaced here with scoped ones.
- **A transformer that omits a field the consumer logs** → `Routed At: undefined`.
- **Python 3.9**, which is EOL in Lambda.
- **A missing lesson** — the PrivateLink final-testing page wasn't in the export, so the validation was written from scratch. It became the most valuable part of that project, because asserting the *negatives* (no IGW, no peering, provider unreachable directly) is what makes "it works" mean anything.
