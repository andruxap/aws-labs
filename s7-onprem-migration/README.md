# S7 — On-Premises Application Migration to AWS

An Employee Directory app backed by MySQL, migrated to RDS with **AWS DMS**, then cut over — and proven cut over by killing the old database and watching the app keep serving.

Built 2026-08-07 · `us-east-1` · **cost ~$0.15** (RDS + DMS + 1 `t3.micro`, ~2 h) · torn down same day.

Source: Tech With Lucy *5 AWS Projects*, project 1.

---

## Architecture

```
  BEFORE                                    AFTER
  ┌──────────────────────────┐              ┌──────────────────────────┐
  │ "on-prem" EC2            │              │ "on-prem" EC2            │
  │   Node app  ──► MariaDB  │              │   Node app ──┐  MariaDB  │
  │             127.0.0.1    │              │              │  (STOPPED)│
  └──────────────────────────┘              └──────────────┼───────────┘
                                                           ▼
              AWS DMS ─── full load ───►         RDS MySQL 8.0 (private)
              dms.t3.small                       lab-s7-rds
```

The app's entire dependency on its database is one line in `/opt/app/db.env`. That is deliberate — a cutover should be a config change, not a code change.

---

## The cutover, proven

`scripts/4-cutover.sh` — every line is an observed result:

```
1. BEFORE
   {"source":"127.0.0.1","engine":"10.5.29-MariaDB","count":8}          PASS

2. Row counts agree
   on-prem: 8    rds: 8                                                 PASS

2b. Recreate the application user on RDS (DMS does not migrate users)   PASS

3. CUTOVER — one line in db.env
   {"source":"lab-s7-rds...rds.amazonaws.com","engine":"8.0.46","count":8}
                                                                        PASS
4. THE PROOF — stop MariaDB on the on-prem box
   on-prem mariadb: inactive
   {"source":"lab-s7-rds...","engine":"8.0.46","count":8}               PASS

5. First three names from RDS: Ada Lovelace, Grace Hopper, Alan Turing  PASS
```

**Step 4 is the whole point.** Copying rows into RDS is not a migration — it's a backup. The migration is complete only when the old database can be switched off and nobody notices. Anything short of that is a claim, not a result.

Rollback is symmetrical and was never needed: put `127.0.0.1` back, start MariaDB. DMS never wrote to the source, which is what makes a full-load migration safe to reverse.

---

## What broke

### 1. DMS migrates data. It does not migrate users.

The first cutover failed:

```
DB ERROR: Access denied for user 'employee_user'@'172.31.9.183'
host=lab-s7-rds.ce72aqy6wv6d.us-east-1.rds.amazonaws.com
```

Every row had migrated perfectly. The row counts matched. And the app still couldn't connect, because **`employee_user` didn't exist on the target** — DMS moves table data, not MySQL accounts, grants, stored procedures, triggers, or views.

This is the most transferable thing in the project. A migration plan that only verifies row counts will pass validation and fail at cutover. Users, grants, and schema objects are a separate migration you have to do yourself.

### 2. My own test gave a false pass

Worse than the bug: my assertion said `PASS` on that failure. It checked whether the RDS hostname appeared in the response — and the hostname appears in the *error message* too:

```bash
case "$AFTER" in *"$RDS_HOST"*) ok "app now reads from RDS";; ...   # wrong
```

Both step 3 and step 4 scored green against a completely broken cutover. Fixed to assert on a successful payload (`"count":8`) and to fail explicitly on `DB ERROR`.

A test that can't fail isn't a test. This one was checking that a string existed somewhere in the output, which was true whether or not anything worked.

### 3. `dms-vpc-role` — the prerequisite the console hides

```
AccessDeniedFault: The IAM Role arn:aws:iam::...:role/dms-vpc-role
is not configured properly.

$ aws iam get-role --role-name dms-vpc-role
NoSuchEntity: The role with name dms-vpc-role cannot be found.
```

DMS requires a role named **exactly** `dms-vpc-role` before any replication subnet group can exist. The console creates it silently the first time you open DMS; the CLI and IaC do not. The error is actively misleading — it reports a role as misconfigured when the role doesn't exist at all.

### 4. The course's instance class is stale

`dms.t3.micro` is no longer orderable. `describe-orderable-replication-instances` lists `dms.t3.small` as the smallest t-family option, so the guide's "may be free-tier eligible" note no longer applies — roughly $0.036/hr instead of $0.018.

### 5. Docker was the wrong tool, for a structural reason

The course starts with MySQL on your own laptop. That cannot work: **DMS runs inside AWS and has no route to a database behind home NAT.** Exposing a home MySQL to the internet to fix that would be worse than the lab is worth. An EC2 instance standing in for the on-prem server is what the course itself moves to, and the migration behaves identically.

---

## What I learned

**Validation is not verification.** Row counts matching told me the data was there. It told me nothing about whether the application could use it. Those are different questions and only the second one matters on cutover night.

**A migration is defined by what you can turn off.** Every intermediate state — data copied, endpoints tested, task `stopped` at 100% — looks like progress and proves nothing about the dependency. Stopping the source is the only test that does.

**Make the dependency a config value before you need to move it.** The cutover was `sed -i 's|^DB_HOST=.*|DB_HOST=<rds>|'` and a service restart. Had the connection string been compiled into the app, the same step would have been a rebuild and a deploy, under time pressure, at the least forgiving moment.

**Deletion protection is a bill, not a safety feature, if you forget it.** RDS refused `delete-db-instance` until `--no-deletion-protection` was applied. In the console the Delete button is simply greyed out with no explanation — the classic "why is my bill still going?" trap. Related: `--skip-final-snapshot`, because a retained snapshot outlives the instance and keeps charging for storage.

**Both metered services bill from creation, not from use.** The DMS replication instance charges whether or not a task runs, and the actual migration of 8 rows took under a minute. Provisioning is the cost, not the work.

---

## Departures from the guide

| Guide | Here | Why |
|---|---|---|
| MySQL on your laptop | MySQL on EC2 | DMS cannot reach a database behind home NAT |
| RDS `PubliclyAccessible: yes` | private, no public access | app and DMS are both in the VPC; public access is unnecessary exposure |
| Security group open wide | scoped to the DMS and app **security groups** | the guide admits this is an anti-pattern |
| `dms.t3.micro` | `dms.t3.small` | t3.micro is no longer orderable |
| Key pair + SSH | SSM Session Manager | no key material, no inbound port 22 |

---

## Running it

```bash
bash scripts/1-onprem.sh    # "on-prem" EC2: MariaDB + seeded data + the app
bash scripts/2-rds.sh       # RDS MySQL 8.0 target (deletion protection ON)
bash scripts/3-dms.sh       # dms-vpc-role, replication instance, endpoints, task
bash scripts/4-cutover.sh   # repoint, then kill the source and prove it
bash scripts/teardown.sh
```

## Teardown notes

Two hourly billers, both deleted first: the **DMS replication instance** and the **RDS instance**.

Order is dependency-enforced: DMS task → replication instance → endpoints → subnet group, then RDS (disable deletion protection → delete with `--skip-final-snapshot` → subnet group), then EC2, security groups, IAM.

`dms-vpc-role` is deliberately kept — it's an account-level DMS prerequisite, costs nothing, and deleting it only means recreating it next time.

Verified after teardown: 0 RDS instances, **0 RDS snapshots**, 0 DMS instances, 0 DMS endpoints, 0 EC2 instances, 0 available EBS volumes.
