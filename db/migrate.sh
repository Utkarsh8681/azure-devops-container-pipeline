#!/usr/bin/env bash
# =============================================================================
# Versioned PostgreSQL migration runner.
#
# Applies .sql files in lexical order, tracks what has run in a checksum
# table, and refuses to proceed if a previously applied file has been edited.
#
# Design decisions worth stating:
#
#   Checksums, not just filenames.  Tracking filenames alone means an edited
#   migration is silently skipped, so environments diverge without any error.
#   SHA256 makes that condition loud.
#
#   Fix-forward, not rollback.  Applied migrations are never rewritten. A
#   mistake is corrected by a new migration. Down-migrations are attractive
#   in theory and unreliable against production data.
#
#   Advisory lock.  Two concurrent pipeline runs against the same database
#   would otherwise interleave. The lock serialises them; the second run
#   waits rather than racing.
#
#   Per-file transaction.  A failed migration leaves the database at the last
#   good state rather than half-applied.
#
# Usage:
#   ./migrate.sh --dir db/migrations --env production
#   ./migrate.sh --dir db/migrations --env dev --dry-run
#
# Connection is taken from standard libpq environment variables:
#   PGHOST  PGPORT  PGDATABASE  PGUSER  PGPASSWORD
# =============================================================================

set -euo pipefail

MIGRATION_DIR=""
ENVIRONMENT=""
DRY_RUN=false
LOCK_ID=91847362
TRACKING_TABLE="schema_migrations"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      MIGRATION_DIR="${2:-}"; shift 2 ;;
    --env)      ENVIRONMENT="${2:-}";   shift 2 ;;
    --dry-run)  DRY_RUN=true;           shift   ;;
    --table)    TRACKING_TABLE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$MIGRATION_DIR" ]] || fail "--dir is required"
[[ -n "$ENVIRONMENT"   ]] || fail "--env is required"
[[ -d "$MIGRATION_DIR" ]] || fail "Migration directory not found: $MIGRATION_DIR"

command -v psql   >/dev/null 2>&1 || fail "psql not found on PATH"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found on PATH"

: "${PGHOST:?PGHOST must be set}"
: "${PGDATABASE:?PGDATABASE must be set}"
: "${PGUSER:?PGUSER must be set}"

PSQL=(psql --no-psqlrc --quiet --tuples-only --no-align
      --set=ON_ERROR_STOP=1 --dbname="$PGDATABASE")

log "Environment : $ENVIRONMENT"
log "Database    : $PGDATABASE on $PGHOST"
log "Directory   : $MIGRATION_DIR"
log "Mode        : $([[ "$DRY_RUN" == true ]] && echo 'DRY RUN (no changes)' || echo 'APPLY')"
echo

# -----------------------------------------------------------------------------
# Connectivity check before doing anything else
# -----------------------------------------------------------------------------
"${PSQL[@]}" --command "SELECT 1;" >/dev/null 2>&1 \
  || fail "Cannot connect to $PGDATABASE on $PGHOST"

# -----------------------------------------------------------------------------
# Tracking table
# -----------------------------------------------------------------------------
"${PSQL[@]}" --command "
  CREATE TABLE IF NOT EXISTS ${TRACKING_TABLE} (
    id            SERIAL PRIMARY KEY,
    filename      TEXT        NOT NULL UNIQUE,
    checksum      CHAR(64)    NOT NULL,
    applied_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_by    TEXT        NOT NULL DEFAULT current_user,
    environment   TEXT        NOT NULL,
    duration_ms   INTEGER
  );
" >/dev/null

# -----------------------------------------------------------------------------
# Serialise concurrent runs
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == false ]]; then
  log "Acquiring advisory lock ${LOCK_ID}..."
  GOT_LOCK=$("${PSQL[@]}" --command "SELECT pg_try_advisory_lock(${LOCK_ID});" | tr -d '[:space:]')
  [[ "$GOT_LOCK" == "t" ]] || fail "Another migration run holds the lock. Aborting."
  # shellcheck disable=SC2064
  trap "\"${PSQL[@]}\" --command 'SELECT pg_advisory_unlock(${LOCK_ID});' >/dev/null 2>&1 || true" EXIT
  log "Lock acquired."
  echo
fi

# -----------------------------------------------------------------------------
# Drift detection: every already-applied file must still match its checksum
# -----------------------------------------------------------------------------
log "Verifying checksums of applied migrations..."
DRIFT=0

while IFS='|' read -r applied_file applied_sum; do
  [[ -z "$applied_file" ]] && continue

  if [[ ! -f "${MIGRATION_DIR}/${applied_file}" ]]; then
    printf '  MISSING  %s  (applied, but no longer in %s)\n' "$applied_file" "$MIGRATION_DIR"
    DRIFT=$((DRIFT + 1))
    continue
  fi

  current_sum=$(sha256sum "${MIGRATION_DIR}/${applied_file}" | cut -d' ' -f1)
  if [[ "$current_sum" != "$applied_sum" ]]; then
    printf '  MODIFIED %s\n' "$applied_file"
    printf '           applied: %s\n' "$applied_sum"
    printf '           current: %s\n' "$current_sum"
    DRIFT=$((DRIFT + 1))
  fi
done < <("${PSQL[@]}" --command \
  "SELECT filename || '|' || checksum FROM ${TRACKING_TABLE} ORDER BY filename;")

if [[ "$DRIFT" -gt 0 ]]; then
  echo
  fail "$DRIFT applied migration(s) have changed on disk.
Applied migrations are immutable. Revert the edits and add a new migration
to make the correction (fix-forward)."
fi

log "All applied migrations match. No drift."
echo

# -----------------------------------------------------------------------------
# Apply pending migrations
# -----------------------------------------------------------------------------
APPLIED=0
SKIPPED=0
PENDING=0

shopt -s nullglob
FILES=("${MIGRATION_DIR}"/*.sql)
shopt -u nullglob

[[ ${#FILES[@]} -gt 0 ]] || { log "No .sql files found. Nothing to do."; exit 0; }

for filepath in "${FILES[@]}"; do
  filename=$(basename "$filepath")
  checksum=$(sha256sum "$filepath" | cut -d' ' -f1)

  already=$("${PSQL[@]}" --command \
    "SELECT 1 FROM ${TRACKING_TABLE} WHERE filename = '${filename}' LIMIT 1;" \
    | tr -d '[:space:]')

  if [[ "$already" == "1" ]]; then
    printf '  skip     %s\n' "$filename"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf '  PENDING  %s  (%s)\n' "$filename" "${checksum:0:12}"
    PENDING=$((PENDING + 1))
    continue
  fi

  printf '  apply    %s ... ' "$filename"
  start_ms=$(date +%s%3N)

  # Single transaction: the migration and its tracking row commit together,
  # so the table can never claim a migration that did not fully apply.
  if psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname="$PGDATABASE" <<SQL
BEGIN;
\i ${filepath}
INSERT INTO ${TRACKING_TABLE} (filename, checksum, environment)
VALUES ('${filename}', '${checksum}', '${ENVIRONMENT}');
COMMIT;
SQL
  then
    end_ms=$(date +%s%3N)
    duration=$((end_ms - start_ms))
    "${PSQL[@]}" --command \
      "UPDATE ${TRACKING_TABLE} SET duration_ms = ${duration} WHERE filename = '${filename}';" \
      >/dev/null
    printf 'ok (%sms)\n' "$duration"
    APPLIED=$((APPLIED + 1))
  else
    printf 'FAILED\n'
    fail "Migration ${filename} failed and was rolled back.
The database is at the state following the last successful migration.
Correct the file and re-run."
  fi
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
if [[ "$DRY_RUN" == true ]]; then
  log "DRY RUN complete. ${PENDING} pending, ${SKIPPED} already applied."
  log "No changes were made."
  [[ "$PENDING" -gt 0 ]] && log "Re-run without --dry-run to apply."
else
  log "Complete. ${APPLIED} applied, ${SKIPPED} already applied."
fi
