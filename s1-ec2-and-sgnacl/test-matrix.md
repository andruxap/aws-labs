# Part B — connectivity matrix

Every cell is an **observed** result from `scripts/b-test-matrix.sh`, run once per phase. Nothing here is assumed.

Topology: custom VPC `10.20.0.0/16`, two public subnets in different AZs, **no NAT gateway**.
Instance A `10.20.1.201` in **SGA** (`us-east-1a`) · Instance B `10.20.2.29` in **SGB** (`us-east-1b`) · home IP `99.230.7.23`.

| # | Test | 1 Baseline | 2 SGA→home IP only | 3 + NACL deny inbound | 4 + SGB HTTP from SGA | 5 + ICMP both ways |
|---|---|---|---|---|---|---|
| 1 | home → A public | `200` | `200` | **no response** | no response | no response |
| 2 | home → B public | `200` | `200` | **no response** | no response | no response |
| 3 | SSM → A | OK | OK | OK | OK | OK |
| 4 | SSM → B | OK | OK | OK | OK | OK |
| 5 | A → ping B private | **0% loss** | 0% loss | 0% loss | 0% loss | 0% loss |
| 6 | B → curl A public | `200` | **failed** | failed | failed | failed |
| 7 | B → curl A private | `200` | **failed** | failed | failed | failed |
| 8 | B → ping A private | **100% loss** | 100% loss | 100% loss | 100% loss | **0% loss** |
| 9 | A → curl B private | — | — | — | **`200`** | `200` |
| 10 | A → curl B public | — | — | — | **failed** | failed |

## What each phase proves

**Phase 1 — baseline.** Tests 5 and 8 are the interesting pair. A can ping B (SGB allows ICMP sourced from SGA) but B cannot ping A (SGA has no ICMP rule at all). Security groups are stateful *per flow* — the reply to A's ping is allowed automatically, but B initiating its own ping is a **new flow** needing its own inbound rule on SGA. Same two hosts, opposite results, purely because of rule direction.

**Phase 2 — SGA restricted to the home IP.** Tests 6 and 7 both break. Test 6 is obvious. Test 7 is the one worth noticing: B reaching A over the *private* address also fails, because the SG rule now matches a single source CIDR and B's private IP isn't it. Narrowing a rule to "my IP" silently severs intra-VPC traffic too.

**Phase 3 — NACL deny.** One rule at the subnet level darkens **both** instances from home, even though SGB still allowed HTTP from `0.0.0.0/0` at that point. NACLs are evaluated before security groups and apply to the whole subnet, so a NACL deny beats any SG allow. SSM (tests 3–4) keeps working because those sessions are initiated *outbound* from the instances and the deny only covered inbound from one address.

**Phase 4 — SGB accepts HTTP from SGA only.** Tests 9 and 10 are the same request to the same host by two different addresses:

- `A → 10.20.2.29` (private) → **200**. Traffic stays inside the VPC, so AWS still sees the source security group, and the source-group rule matches.
- `A → 44.203.117.47` (public) → **failed**. The packet leaves the VPC and returns through the internet gateway, arriving from a public *address*. There is no group to match, so the rule rejects it.

Source-group references only work on the private path. This is the trap behind "but I allowed that security group, why is it refused?"

**Phase 5 — ICMP in both directions.** Adding "all ICMP from SGB" to SGA flips test 8 from 100% loss to 0%. Confirms the phase-1 reading: it was a missing inbound rule, not anything about statefulness.

## The stateless proof

The above blocks traffic *inbound*, which a security group could also do. This is the experiment that separates the two mechanisms — deny **outbound** to the home IP only, leaving inbound wide open:

```
NACL rule 50: DENY egress -> 99.230.7.23/32     (no inbound rule at all)

client:  curl http://<A public>  ->  hangs, then times out
server:  /var/log/httpd/access_log
         99.230.7.23 - - [05/Aug/2026:03:38:05 +0000] "GET / HTTP/1.1" 200 55 "-" "curl/8.11.0"
```

**Apache received the request and answered `200` with 55 bytes. The client never saw a single byte.** The reply was dropped on the way out.

An identical outbound deny in a security group would have changed nothing, because a security group automatically permits return traffic for an established flow. A NACL has no idea the flow exists — it evaluates every packet in isolation, in both directions, independently.

That is the whole difference, and it is why NACL rules must account for **ephemeral ports** on the return path: a NACL that allows inbound `:80` but not outbound `1024–65535` will accept your request and silently swallow the response.
