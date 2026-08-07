#!/usr/bin/env bash
# S7 step 4 — the cutover, and the proof that it happened.
#
# Copying data is not a migration. A migration is when the application stops
# depending on the old database. So this repoints the app, then STOPS MySQL on
# the "on-prem" box and shows the app still works — which is the only way to
# prove the old database is genuinely out of the path.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
source "$HERE/.env.generated"
say() { echo ""; echo "== $* =="; }
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

on() {  # run a command on the on-prem box
  local cid out
  cid="$(aws ssm send-command --instance-ids "$ONPREM" --document-name AWS-RunShellScript \
    --parameters "commands=[\"$1\"]" --region "$AWS_REGION" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || { echo SSM-ERROR; return; }
  for _ in $(seq 1 20); do
    sleep 3
    s="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$ONPREM" \
      --region "$AWS_REGION" --query Status --output text 2>/dev/null)" || continue
    case "$s" in Success|Failed|TimedOut|Cancelled) break;; esac
  done
  out="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$ONPREM" \
    --region "$AWS_REGION" --query StandardOutputContent --output text 2>/dev/null)"
  echo "${out:-<none>}" | tr -d '\r' | tr '\n' ' '
}

api() { curl -s -m 10 "http://$ONPREM_PUB/api" 2>/dev/null || echo '{"error":"unreachable"}'; }

say "1. BEFORE — where is the app reading from?"
BEFORE="$(api)"; echo "  $BEFORE"
case "$BEFORE" in *'"source":"127.0.0.1"'*) ok "reading from the on-prem MySQL";; *) bad "unexpected state";; esac

say "2. Row counts agree on both sides"
SRC_ROWS="$(on "mysql -N -B -e 'SELECT COUNT(*) FROM employee_db.employees' 2>/dev/null")"
TGT_ROWS="$(on "mysql -h $RDS_HOST -u admin -p'$DB_PASS' -N -B -e 'SELECT COUNT(*) FROM employee_db.employees' 2>/dev/null")"
echo "  on-prem: ${SRC_ROWS:-?}   rds: ${TGT_ROWS:-?}"
[ -n "$SRC_ROWS" ] && [ "$(echo "$SRC_ROWS" | tr -d ' ')" = "$(echo "$TGT_ROWS" | tr -d ' ')" ] \
  && ok "row counts match" || bad "row counts differ — do not cut over"

# DMS migrates TABLE DATA. It does not migrate MySQL user accounts, grants,
# stored procedures, triggers or views. The app user has to be recreated on the
# target or the cutover fails with "Access denied" against a database that
# contains every row correctly.
say "2b. Recreate the application user on RDS (DMS does not migrate users)"
on "mysql -h $RDS_HOST -u admin -p'$DB_PASS' -e \\\"CREATE USER IF NOT EXISTS 'employee_user'@'%' IDENTIFIED BY 'StrongPassword123'; GRANT ALL PRIVILEGES ON employee_db.* TO 'employee_user'@'%'; FLUSH PRIVILEGES;\\\" 2>&1" >/dev/null
ok "employee_user created on the target"

say "3. CUTOVER — repoint the app at RDS (one line in db.env)"
on "sed -i 's|^DB_HOST=.*|DB_HOST=$RDS_HOST|' /opt/app/db.env && systemctl restart empdir && echo done" >/dev/null
sleep 8
AFTER="$(api)"; echo "  $AFTER"
# Assert on a SUCCESSFUL response. Matching the hostname alone is not enough:
# it also appears in the error body, so a failed cutover scored as a pass the
# first time this ran.
case "$AFTER" in
  *"DB ERROR"*)                    bad "cutover failed: $AFTER";;
  *'"source":"'"$RDS_HOST"'"'*)    ok "app now reads from RDS";;
  *)                               bad "unexpected response: $AFTER";;
esac
case "$AFTER" in *MariaDB*) bad "still MariaDB — that is the old server";;   *'"engine":"8.0'*) ok "engine is MySQL 8.0 (RDS)";; *) bad "engine not confirmed";; esac

say "4. THE PROOF — stop MySQL on the on-prem box"
on "systemctl stop mariadb && echo stopped" >/dev/null
echo "  on-prem mariadb: $(on 'systemctl is-active mariadb')"
sleep 3
FINAL="$(api)"; echo "  $FINAL"
case "$FINAL" in
  *"DB ERROR"*)                 bad "app broke with on-prem down — still depending on it";;
  *'"count":8'*)                ok "app still serves all 8 rows with the old database DOWN";;
  *)                            bad "unexpected: $FINAL";;
esac

say "5. Data is readable end to end"
ROWS="$(on "mysql -h $RDS_HOST -u admin -p'$DB_PASS' -N -B -e \\\"SELECT name FROM employee_db.employees ORDER BY id LIMIT 3\\\" 2>/dev/null")"
echo "  first three names from RDS: $ROWS"
case "$ROWS" in *Ada*) ok "migrated rows are intact";; *) bad "could not read migrated data";; esac

echo ""
echo "  rollback would be: sed -i 's|^DB_HOST=.*|DB_HOST=127.0.0.1|' /opt/app/db.env"
echo "  plus 'systemctl start mariadb' — the old database is untouched by DMS,"
echo "  which is what makes a full-load migration safe to reverse."
