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
