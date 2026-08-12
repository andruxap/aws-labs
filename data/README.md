# Raw measurement data

The actual samples behind the numbers quoted in the project write-ups. Committed so the claims are auditable — every figure on the case-study pages can be recomputed from these files.

The infrastructure they describe was torn down the same day it was built. These logs and the write-ups are the only surviving evidence, which is why they are tracked (`git add -f`; `build/` is otherwise gitignored).

Checked before committing: no account ids, IP addresses, ARNs, endpoints or instance ids — only timestamps, HTTP status codes and environment labels.

| File | Samples | Format | From |
|---|---|---|---|
| `s4-cutover.log` | 62 | `<code> <ENV>` | Blue→green listener swap, polled across the switch |
| `s4-rolling-refresh.log` | 43 | `<code> <version>` | Instance refresh, ~430 s, polled throughout |
| `s4-abrupt-termination.log` | 638 | `<code>` | An in-service instance terminated out of band, ~5 samples/s |
| `s9-failover.log` | **233** (636 lines) | `<epoch> <code> <region>` | Global Accelerator failover and failback |

> `s9-failover.log` has more lines than samples: the poller wrote the response body, and a 503 from an ALB is a multi-line HTML page. Filter with `awk 'NF==3'` to get the 233 actual samples. Left as captured rather than cleaned, so the file is what the run produced.

## Recomputing the headline numbers

```bash
# S4 — planned changes lost nothing
awk '$1!=200' s4-cutover.log | wc -l          # 0 of 62
awk '$1!=200' s4-rolling-refresh.log | wc -l  # 0 of 43

# S4 — an abrupt termination did
grep -c 200 s4-abrupt-termination.log         # 612
grep -vc 200 s4-abrupt-termination.log        # 26  (19x 502, 7x connection failure)

# S9 — failover moved regions in 28s, and 503s ran for ~24s of it
awk 'NF==3 && $2!=200' s9-failover.log | wc -l   # 79 of 233 samples
awk 'NF==3' s9-failover.log | wc -l              # 233
awk '$3=="us-west-2"{print $1; exit}' s9-failover.log   # first sample served by the secondary
```

The S4 rolling-refresh log is also where "mixed versions in flight" comes from — `awk '{print $2}' s4-rolling-refresh.log | sort -u` returns both `v1.0` and `v1.1`.
