# S8 — Serverless Cross-Region Disaster Recovery

A serverless API running in two regions over a DynamoDB Global Table, fronted by one DNS name that fails over automatically when a region dies — and fails back when it recovers.

Built 2026-08-07 · `us-east-1` + `us-west-2` · **cost ~$0.06** · torn down same day.

Source: DCT *5 AWS Cloud Projects*, project 5.

---

## Architecture

```
                    https://api.lab.andruxa.dev
                     Route 53 failover routing
                    ┌───────────┴────────────┐
             health check              health check
                    │                        │
      ┌─────────────▼──────────┐  ┌──────────▼─────────────┐
      │ us-east-1  PRIMARY     │  │ us-west-2  SECONDARY   │
      │ ACM cert (regional)    │  │ ACM cert (regional)    │
      │ HTTP API + custom dom. │  │ HTTP API + custom dom. │
      │ Lambda (python3.12)    │  │ Lambda (python3.12)    │
      └───────────┬────────────┘  └───────────┬────────────┘
                  └──── DynamoDB Global Table ┘
                     replicated, BOTH writable
```

A global table is not two tables that sync. It is **one table with replicas**, and every replica accepts writes.

---

## Measured results

`scripts/test.sh` — all seven assertions passed.

### Replication is bidirectional

```
write ItemId=east-54586 to us-east-1  ->  us-west-2 returns it 6s later    PASS
write ItemId=west-54586 to us-west-2  ->  us-east-1 returns it 6s later    PASS
```

Both regions are live and writable simultaneously. That is what separates this from S9 — the data is genuinely in both places, not just the compute.

### Failover on a real outage

The primary was broken for real, not simulated: Lambda **reserved concurrency set to 0**, so every invocation is throttled and the API returns 503. Actual compute failure, fully reversible.

```
t=0     primary Lambda concurrency = 0;  direct call to primary -> 503
t=20s   primary-hc=[Success]   api.lab.andruxa.dev -> <error>
t=40s   primary-hc=[Success]   api.lab.andruxa.dev -> <error>
t=60s   primary-hc=[Failure: HTTP 50x]   api.lab.andruxa.dev -> <error>
t=80s   primary-hc=[Failure]   api.lab.andruxa.dev -> us-west-2      FAILED OVER
```

**Clients saw errors for roughly 60–80 seconds.** That is the honest headline. The health check is configured at a 30-second interval with a failure threshold of 2, so ~60 s is the detection floor before Route 53 even begins serving the secondary, and DNS caching adds more on top.

Data survived the failover — the item written in `us-east-1` was still served, now from `us-west-2`.

### Failback is automatic

```
primary Lambda concurrency restored
t=80s   api.lab.andruxa.dev -> us-east-1      FAILED BACK
```

Nothing was touched but the fault itself. Route 53 returns to the primary as soon as its health check recovers, which is worth knowing: if a region is flapping, traffic flaps with it.

---

## What I learned

**DNS failover has a floor, and it is not fast.** Detection is `RequestInterval x FailureThreshold` at best — 60 seconds here — and resolver caching adds more. There is no configuration that makes this instant, because the mechanism is "stop answering with the old address" and clients hold addresses. For an RTO measured in seconds rather than a minute, DNS is the wrong tool; that is precisely the gap S9's anycast fills.

**The failover window is an outage, not a degradation.** Between the primary breaking and Route 53 reacting, requests didn't get slower — they failed. Any RTO claim has to include this window, and a health check tuned for fast detection (30 s × 2) is already near the practical limit.

**Regional API Gateway domains need a certificate in their own region.** This is *not* the CloudFront rule where everything must live in `us-east-1`. Both certs validated against the **same** DNS CNAME, because ACM's validation record is deterministic per domain name — so one record satisfies both regions.

**Alias records to API Gateway cannot use `EvaluateTargetHealth`**, so each failover record needs an explicit health check. And the health check must target the `execute-api` hostname rather than the custom domain, because a health check sends its configured FQDN as the `Host` header and the custom domain would reject an unexpected one.

**`servedBy` in every response is what made this debuggable.** Having each region stamp its own identity into the payload turned "did failover happen?" from a guess into a string comparison. Same principle as the instance-ID stamp in S3 and the environment stamp in S4.

---

## Corrections to the course code

All five are real defects in the published material:

1. **Runtime** — the guide specifies Python 3.9, which is EOL in Lambda. Runs 3.12.
2. **`Decimal`** — `json.dumps()` on a DynamoDB scan raises `TypeError` the moment any attribute is numeric, because boto3 returns `Decimal`. Fixed with a `JSONEncoder` subclass.
3. **CORS on the write path** — the guide returns `Access-Control-Allow-Origin` on read but not write, so preflight passes and the real POST fails in a browser.
4. **IAM** — `AmazonDynamoDBFullAccess` replaced with four actions scoped to the one table ARN in both regions.
5. **Input validation** — `body['ItemId']` unguarded means a malformed POST is a 500 instead of a 400.

---

## What broke during the build

**`UnrecognizedClientException: The security token included in the request is invalid`** when creating the replica, immediately after `create-table`.

Misleading on every axis: nothing is wrong with the credentials, `us-west-2` is enabled, and `AWSServiceRoleForDynamoDBReplication` already existed. It is DynamoDB calling the second region on your behalf before the new table's stream has propagated. Pure transient — the identical command succeeded on retry. The deploy script now retries rather than treating it as a credentials problem, which is where that error message sends you first.

---

## Running it

```bash
bash scripts/deploy.sh        # global table, Lambda + API + ACM cert per region
bash scripts/failover-dns.sh  # health checks + failover records
bash scripts/test.sh          # replication both ways, break primary, watch failover
bash scripts/teardown.sh
```

## Teardown notes

**Health checks go first**, and the DNS records go before them — a record cannot be deleted while it references a health check. They are the only thing here that bills monthly (~$0.50 each), they are global so they appear in no regional console view, and they outlive every other resource in the project.

Then: API mappings → custom domains → APIs → Lambdas → certificates (retried; the in-use association lingers after the domain is deleted) → **replica before table** on the global table → IAM.

Verified after teardown: **0 health checks**, 0 lab DNS records, and 0 APIs / 0 Lambdas / 0 tables / 0 certificates in *both* regions.
