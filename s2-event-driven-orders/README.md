# S2 — Event-Driven Order Processing System

Serverless order pipeline on AWS: HTTP API → Lambda → DynamoDB → Streams → Lambda → SQS → worker, with a dead-letter queue, a CloudWatch alarm on the DLQ, and an EventBridge Pipe routing high-value orders to a separate queue.

Built 2026-08-05 · `us-east-1` · **cost: under $0.01** — every service is pay-per-request, nothing bills hourly.

Source course: Tech With Lucy, *5 AWS Projects to Become a Cloud Engineer*, lessons 4.2–4.7.

---

## Architecture

As the course teaches it:

```
Browser ──POST /order──> API Gateway (HTTP API)
                              │
                              ▼
                     CreateOrderFunction ──> DynamoDB "Orders"    status=PENDING
                                                  │
                                                  │ Streams (NEW_AND_OLD_IMAGES)
                                                  ▼
                                         ProcessOrderFunction     status=PROCESSING
                                                  │
                                                  ▼
                                    SQS order-processing-queue
                                          │              │
                              ┌───────────┘              └───────────┐
                              ▼                                      ▼
                     OrderWorkerFunction                    EventBridge Pipe
                  status=COMPLETED | FAILED               filter: amount > 10000
                              │                                      │
                       3 failed receives                             ▼
                              ▼                          high-value-orders-queue
                     order-processing-dlq                            │
                              │                                      ▼
                      CloudWatch alarm                   HighValueWorkerFunction
                              │
                              ▼
                        SNS ──> email
```

**That topology does not work.** See below.

---

## What broke

### The EventBridge Pipe starves the worker

The course puts the Pipe's source and `OrderWorkerFunction`'s event-source mapping on **the same SQS queue**. Both are pollers. A standard queue delivers each message to exactly one consumer — and a Pipe **deletes the messages its filter rejects** rather than returning them.

So the Pipe doesn't just occasionally win a race. It eats normal orders and drops them on the floor.

First run, three orders submitted:

| Test | Amount | Notes | Expected | Actual |
|---|---|---|---|---|
| A | 1200 | `Normal order` | `COMPLETED` | **stuck `PROCESSING`** — worker never logged it |
| B | 20000 | `High value order` | `FAILED` + routed | routed to high-value queue, but **DynamoDB never reached `FAILED`** |
| C | 1500 | `Please FAIL this order` | retry ×3 → DLQ | **stuck `PROCESSING`**, DLQ empty, alarm never fired |

All three queues read `main=0 dlq=0 hv=0`. The messages were gone. `OrderWorkerFunction` had logged exactly one receive across the whole run, with `ApproximateReceiveCount: 1` — it saw C once, threw as designed, and the retry never came back to it.

### Isolating it

Stopped the Pipe. Changed nothing else. Resubmitted the same two orders:

```
A2 (1200)  -> COMPLETED   completedAt 2026-08-05T01:59:08.879Z
C2 (1500)  -> PROCESSING, retried 3x, DLQ=1 at t≈70s
              alarm OK -> ALARM at t≈125s
              "Threshold Crossed: 1 datapoint [1.0] was >= the threshold (1.0)"
```

One variable changed, both failures resolved. The Pipe was the cause.

---

## The fix — SNS fan-out

The Pipe and the worker are two independent consumers of the same event. They should not be competing for one queue; they should each get their own copy.

```
ProcessOrderFunction ──> SNS "order-events"
                              ├──> order-processing-queue ──> OrderWorkerFunction
                              └──> pipe-source-queue ──────> Pipe (filter) ──> high-value-orders-queue
```

Both subscriptions use **`RawMessageDelivery=true`**, so the message body stays the original JSON. Without it SNS wraps the payload in an envelope, and both the worker's `JSON.parse(record.body)` and the Pipe's `$.body.amount` filter would break.

Applied by [`scripts/fix-race.sh`](scripts/fix-race.sh). `ProcessOrderFunction` switches topology on config alone — publish to SNS when `ORDER_TOPIC_ARN` is set, otherwise straight to the queue — so the broken version stays reproducible for comparison.

A Pipe's source is immutable, so the fix deletes and recreates it rather than updating in place.

### Verified after the fix

All three cases, same run, no stopping anything:

| Test | Amount | DynamoDB | High-value queue |
|---|---|---|---|
| A | 1200 | `COMPLETED` @ 02:07:55 | — |
| B | 20000 | `FAILED`, `AMOUNT_ABOVE_LIMIT` @ 02:08:01 | **also routed** @ 02:08:01 |
| C | 1500 | `PROCESSING` → DLQ at t≈60s → alarm `ALARM` | — |

B is the proof: the worker marked it `FAILED` **and** the Pipe routed it, from one submission. Under the course topology only one of those could ever happen.

```
HighValueWorkerFunction:
  Order ID: f6e2318b-daa2-475f-899c-1d88c57db0e3
  Amount: 20000
  Priority: HIGH_VALUE
  Routed At: 2026-08-05T02:08:01.355Z
```

### Two alternatives I did not pick

- **Route from the worker** — drop the Pipe, have `OrderWorkerFunction` send high-value orders onward itself. Simplest and fully deterministic, but it re-introduces the glue code Pipes exists to remove.
- **Move the Pipe onto the DynamoDB stream** — a stream supports multiple independent consumers, so no competition. Architecturally the cleanest, but it doesn't work here: stream images type numbers as strings (`"amount":{"N":"20000"}`), and EventBridge `numeric` matching requires a real JSON number. The filter would never match without an enrichment step.

SNS fan-out keeps Pipes doing real filtering work and needs no code in the routing path.

---

## Other defects in the course material

Verified against the lesson HTML, all corrected here:

1. **Every template literal is broken.** Lessons 4.3–4.6 contain zero backtick characters — the course platform stripped them. None of the published Lambda code compiles.
2. **CommonJS in an ESM file.** 4.3 gives `require`/`exports.handler`, but the Lambda console creates `index.mjs`, which is an ES module. Fails with `exports is not defined in ES module scope`.
3. **The transformer omits `routedAt`** while `HighValueWorkerFunction` logs it → `Routed At: undefined`. Fixed with the Pipes reserved variable `<aws.pipes.event.ingestion-time>`.
4. **Three `*FullAccess` policies.** Replaced with a scoped policy — the table, its stream (`/stream/*` is a **separate statement**; the table ARN alone does not grant stream access, and that's the usual reason a stream trigger silently never fires), and the three queues.

---

## What I learned

**A queue is not a broadcast.** Point two consumers at one SQS queue and you have not built fan-out, you have built a race — and if one of them filters, it becomes a silent message sink. Fan-out needs SNS, EventBridge, or a stream.

**Business failure and technical failure need opposite handling.** `amount > 10000` is a decision — mark it `FAILED` and consume the message, because retrying cannot change the answer. A DynamoDB timeout is a technical failure — throw, let SQS retry three times, then let the DLQ catch it. Getting this backwards either retries forever or loses errors.

**The DLQ is the best failure signal in an event-driven system.** Nothing else tells you as cheaply that something is broken. One alarm on `ApproximateNumberOfMessagesVisible >= 1` covers every failure mode downstream of the queue.

**`status` is a DynamoDB reserved word** — hence `ExpressionAttributeNames: {"#s": "status"}` in every update.

**A DynamoDB stream handler that writes back to its own table will re-trigger itself.** The `eventName !== "INSERT"` guard is what stops the loop.

---

## Running it

```bash
bash scripts/deploy.sh        # 12 resources, course topology (reproduces the race)
bash scripts/fix-race.sh      # SNS fan-out — adds 2 resources, recreates the Pipe
bash scripts/test.sh A        # normal | B high-value | C technical failure
bash scripts/test.sh depth    # queue depths
bash scripts/test.sh show <orderId>
bash scripts/teardown.sh      # deletes everything, dependency order
```

Frontend: set `API_URL` in `frontend/index.html` from `.env.generated`, then `python -m http.server 5500`. Serve over HTTP — a `file://` origin is `null` and produces confusing CORS failures.

## Resources created

DynamoDB `Orders` (on-demand + streams) · Lambdas `CreateOrderFunction`, `ProcessOrderFunction`, `OrderWorkerFunction`, `HighValueWorkerFunction` · IAM `OrderServiceLambdaRole`, `HighValueOrderPipeRole` · HTTP API `order-api` · SQS `order-processing-queue`, `order-processing-dlq`, `high-value-orders-queue`, `pipe-source-queue` · SNS `order-processing-alerts`, `order-events` · Pipe `HighValueOrderPipe` · Alarm `order-processing-alarm`

## Teardown

Order matters — the Pipe goes first because it holds a poller on the source queue, and Lambda deletion removes the event-source mappings. `scripts/teardown.sh` handles it and is safe to run twice.
