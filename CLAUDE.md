# CLAUDE.md — aws-labs

Hands-on AWS course projects (Tech With Lucy + Digital Cloud Training), built for the portfolio.
Plan and sequencing live in `resume_website/docs/aws-projects-twl/00-merged-track.md`.

---

## 🔴 Hard Stops

- **Never work on `main`.** Every change happens on `develop` or a branch cut from it. `main` is only ever updated by merging `develop` into it, and only when asked. Check `git rev-parse --abbrev-ref HEAD` before the first edit of a session.
- **Never leave AWS resources running past the session.** Every project has a `scripts/teardown.sh` and it runs the same day the project is built. A forgotten ALB is $16/month; a forgotten Global Accelerator is $18/month.
- **Spend credits, never the credit card.** $158.03 of credits as of 2026-08-05; the whole track is ~$5.30. A Budget Action freezes creation of hourly-billed resources at $5 of post-credit spend — see [docs/spending-guardrail.md](docs/spending-guardrail.md). AWS has **no true hard cap**, so the automation is a backstop, not permission to be careless. Never start a project there isn't time to finish and tear down.
- **Never commit AWS account IDs, API endpoint URLs, ARNs, or credentials.** Account-specific values come from `aws sts get-caller-identity` at runtime or from an untracked `.env`. Scripts must be safe to publish.
- **No `*FullAccess` IAM policies.** The courses use them for convenience; this repo writes scoped policies. It's the difference between a lab and a portfolio piece.
- **One region unless the project is explicitly multi-region:** `us-east-1`, with `us-west-2` as the only secondary. Mixing regions inside a project is the #1 cause of "the trigger just doesn't work."

## Standard operating procedure

- Every project folder: `README.md` (Goal → Architecture → What I built → What broke → What I learned → Cost → Teardown proof), `scripts/deploy.sh`, `scripts/teardown.sh`.
- **The "What broke" section is the point.** Do not sanitize it — it's the only part of a tutorial project an interviewer can't get elsewhere.
- Deploy scripts are idempotent and re-runnable. Teardown scripts delete in dependency order and are safe to run twice.
- Record real costs in `docs/cost-log.md` after every session, and verify the bill the next morning.

## Environment

- Windows 11, Git Bash. **Prefix AWS CLI commands that take leading-slash arguments with `MSYS_NO_PATHCONV=1`** — MSYS rewrites `/aws/lambda/...` into a Windows path and the call fails.
- No `zip` binary. Use `powershell -NoProfile -Command "Compress-Archive ..."` for Lambda bundles.
- Node 20, AWS CLI v2, default region `us-east-1`.

### Bugs that have bitten more than once — do not reintroduce

1. **`MSYS_NO_PATHCONV=1` + `curl -o /dev/null`.** With path conversion off, `/dev/null` does not resolve, so curl fails writing the body and exits non-zero *even on a 200*. Under `set -o pipefail` any `|| echo 000` fallback then fires and the output reads `200000`. Write the body to a real file (`-o "$BUILD/.body"`) instead. **Only applies on the workstation** — the same flag inside an instance (via `ssm send-command`) is running real Linux, where `/dev/null` is fine.
2. **`file://` arguments need Windows paths.** The AWS CLI is a native Windows binary, so `file:///c/Users/...` fails. Convert with `cygpath -m` — every script defines `w() { cygpath -m "$1"; }` for this. Same for `aws s3 sync` source paths.
3. **A `retry` helper must not swallow stdout.** The original piped every attempt to `/dev/null`, so `id="$(retry 12 aws ec2 run-instances ...)"` returned empty *while the instance had actually launched* — a silent duplicate-resource trap that cost two orphaned instances in S3. The current helper captures and replays stdout.
4. **Never `|| continue` past a delete failure in a teardown.** Target groups return `ResourceInUse` for a while after their ALB is deleted; S3's first teardown skipped silently and left both behind. Retry in a loop, and print a loud warning if it gives up. A teardown that quietly half-works is worse than one that fails.
5. **Always end a teardown with a resource count**, including `available` EBS volumes and `stopped` instances. Those survive most teardowns and keep billing.
