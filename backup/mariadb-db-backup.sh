#!/usr/bin/env bash
set -Eeuo pipefail

MARIADB_BACKUP_BIN="${MARIADB_BACKUP_BIN:-mariadb-backup}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mariadb}"
DATADIR="${DATADIR:-/var/lib/mysql}"
SOCKET="${SOCKET:-/run/mysqld/mysqld.sock}"
HOST="${HOST:-localhost}"
PORT="${PORT:-3306}"
USER_NAME="${USER_NAME:-backup}"
PASSWORD="${PASSWORD:-}"
PASSWORD_FILE="${PASSWORD_FILE:-}"

PARALLEL="${PARALLEL:-2}"
USE_MEMORY="${USE_MEMORY:-512M}"
TMPDIR="${TMPDIR:-/tmp}"
OPEN_FILES_LIMIT="${OPEN_FILES_LIMIT:-65535}"
FTWRL_WAIT_TIMEOUT="${FTWRL_WAIT_TIMEOUT:-30}"
FTWRL_WAIT_THRESHOLD="${FTWRL_WAIT_THRESHOLD:-10}"
FTWRL_WAIT_QUERY_TYPE="${FTWRL_WAIT_QUERY_TYPE:-ALL}"

RETENTION_DAYS="${RETENTION_DAYS:-7}"
FULL_PREFIX="${FULL_PREFIX:-full}"
INCR_PREFIX="${INCR_PREFIX:-inc}"
LOG_DIR="${LOG_DIR:-$BACKUP_ROOT/logs}"
META_DIR_NAME="${META_DIR_NAME:-meta}"
TIMESTAMP="${TIMESTAMP:-$(date '+%F_%H-%M-%S')}"
SERVICE_NAME="${SERVICE_NAME:-mariadb}"
MYSQL_OWNER="${MYSQL_OWNER:-mysql:mysql}"

ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-tar.zst}"   # tar.zst կամ tar.gz
KEEP_UNCOMPRESSED="${KEEP_UNCOMPRESSED:-false}"
AUTO_EXTRACT_FOR_ACTIONS="${AUTO_EXTRACT_FOR_ACTIONS:-true}"
EXTRACT_ROOT="${EXTRACT_ROOT:-$TMPDIR/mariadb-backup-extract}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"

TARGET_DIR="${TARGET_DIR:-}"
INCREMENTAL_DIR="${INCREMENTAL_DIR:-}"
BASE_DIR="${BASE_DIR:-}"
FORCE_NON_EMPTY_DIRECTORIES="${FORCE_NON_EMPTY_DIRECTORIES:-false}"
STOP_SERVICE_ON_RESTORE="${STOP_SERVICE_ON_RESTORE:-true}"
CHOWN_AFTER_RESTORE="${CHOWN_AFTER_RESTORE:-true}"

MODE=""
LOG_FILE=""
MARIADB_ARGS=()
WORK_DIRS_TO_CLEANUP=()

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%F %T')] $*"
}

cleanup() {
  local d
  for d in "${WORK_DIRS_TO_CLEANUP[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  backup_full_and_incrimental.sh <mode> [options]

Modes:
  full
  incr
  prepare-full
  prepare-incr
  chain-prepare
  restore
  info

Options:
  --backup-root PATH
  --target-dir PATH
  --incremental-dir PATH
  --base-dir PATH
  --datadir PATH
  --socket PATH
  --host HOST
  --port PORT
  --user USER
  --password PASS
  --password-file PATH
  --parallel N
  --use-memory SIZE
  --tmpdir PATH
  --open-files-limit N
  --retention-days N
  --service-name NAME
  --mysql-owner USER:GROUP
  --force-non-empty-directories true|false
  --stop-service-on-restore true|false
  --chown-after-restore true|false
  --timestamp VALUE

Archive/compress:
  --archive-format tar.zst|tar.gz
  --keep-uncompressed true|false
  --auto-extract-for-actions true|false
  --extract-root PATH
  --zstd-level N
  --gzip-level N
EOF
}

bool_is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Required binary not found: $1"
}

ensure_dir() {
  mkdir -p "$1"
}

read_password_from_file() {
  [[ -n "$PASSWORD_FILE" ]] || return 0
  [[ -f "$PASSWORD_FILE" ]] || die "Password file not found: $PASSWORD_FILE"
  PASSWORD="$(<"$PASSWORD_FILE")"
}

build_common_args() {
  MARIADB_ARGS=()
  MARIADB_ARGS+=("--user=$USER_NAME")

  if [[ -n "$PASSWORD" ]]; then
    MARIADB_ARGS+=("--password=$PASSWORD")
  fi

  if [[ -n "$SOCKET" ]]; then
    MARIADB_ARGS+=("--socket=$SOCKET")
  else
    MARIADB_ARGS+=("--host=$HOST" "--port=$PORT")
  fi

  MARIADB_ARGS+=("--parallel=$PARALLEL")
  MARIADB_ARGS+=("--open-files-limit=$OPEN_FILES_LIMIT")
  MARIADB_ARGS+=("--tmpdir=$TMPDIR")
  MARIADB_ARGS+=("--ftwrl-wait-timeout=$FTWRL_WAIT_TIMEOUT")
  MARIADB_ARGS+=("--ftwrl-wait-threshold=$FTWRL_WAIT_THRESHOLD")
  MARIADB_ARGS+=("--ftwrl-wait-query-type=$FTWRL_WAIT_QUERY_TYPE")
}

write_meta() {
  local dir="$1"
  local meta_dir="$dir/$META_DIR_NAME"
  ensure_dir "$meta_dir"

  cat > "$meta_dir/script.env" <<EOF
MODE=$MODE
TIMESTAMP=$TIMESTAMP
BACKUP_ROOT=$BACKUP_ROOT
DATADIR=$DATADIR
SOCKET=$SOCKET
HOST=$HOST
PORT=$PORT
USER_NAME=$USER_NAME
PARALLEL=$PARALLEL
USE_MEMORY=$USE_MEMORY
TMPDIR=$TMPDIR
OPEN_FILES_LIMIT=$OPEN_FILES_LIMIT
RETENTION_DAYS=$RETENTION_DAYS
SERVICE_NAME=$SERVICE_NAME
MYSQL_OWNER=$MYSQL_OWNER
ARCHIVE_FORMAT=$ARCHIVE_FORMAT
KEEP_UNCOMPRESSED=$KEEP_UNCOMPRESSED
AUTO_EXTRACT_FOR_ACTIONS=$AUTO_EXTRACT_FOR_ACTIONS
EXTRACT_ROOT=$EXTRACT_ROOT
ZSTD_LEVEL=$ZSTD_LEVEL
GZIP_LEVEL=$GZIP_LEVEL
EOF
}

archive_path_for_dir() {
  local dir="$1"
  case "$ARCHIVE_FORMAT" in
    tar.zst) echo "${dir}.tar.zst" ;;
    tar.gz)  echo "${dir}.tar.gz" ;;
    *) die "Unsupported ARCHIVE_FORMAT: $ARCHIVE_FORMAT" ;;
  esac
}

compress_backup_dir() {
  local dir="$1"
  local parent base archive
  parent="$(dirname "$dir")"
  base="$(basename "$dir")"
  archive="$(archive_path_for_dir "$dir")"

  log "Compressing backup directory: $dir -> $archive"

  case "$ARCHIVE_FORMAT" in
    tar.zst)
      tar -C "$parent" -cf - "$base" | zstd -"${ZSTD_LEVEL}" -T0 -o "$archive"
      ;;
    tar.gz)
      tar -C "$parent" -cf - "$base" | gzip -"${GZIP_LEVEL}" > "$archive"
      ;;
    *)
      die "Unsupported archive format: $ARCHIVE_FORMAT"
      ;;
  esac

  if ! bool_is_true "$KEEP_UNCOMPRESSED"; then
    log "Removing uncompressed backup directory: $dir"
    rm -rf -- "$dir"
  fi

  log "Compressed backup created: $archive"
}

extract_archive_to_temp() {
  local archive="$1"
  local workdir outdir name
  ensure_dir "$EXTRACT_ROOT"
  workdir="$(mktemp -d "$EXTRACT_ROOT/extract.XXXXXX")"
  WORK_DIRS_TO_CLEANUP+=("$workdir")
  name="$(basename "$archive")"

  log "Extracting archive: $archive -> $workdir"

  case "$archive" in
    *.tar.zst)
      zstd -dc "$archive" | tar -C "$workdir" -xf -
      ;;
    *.tar.gz)
      gzip -dc "$archive" | tar -C "$workdir" -xf -
      ;;
    *)
      die "Unsupported archive extension: $archive"
      ;;
  esac

  outdir="$(find "$workdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$outdir" ]] || die "Failed to find extracted backup directory inside $archive"
  echo "$outdir"
}

resolve_backup_path() {
  local path="$1"

  if [[ -d "$path" ]]; then
    echo "$path"
    return 0
  fi

  if [[ -f "$path" ]]; then
    if bool_is_true "$AUTO_EXTRACT_FOR_ACTIONS"; then
      extract_archive_to_temp "$path"
      return 0
    else
      die "Archive given but AUTO_EXTRACT_FOR_ACTIONS is disabled: $path"
    fi
  fi

  if [[ -f "${path}.tar.zst" ]]; then
    if bool_is_true "$AUTO_EXTRACT_FOR_ACTIONS"; then
      extract_archive_to_temp "${path}.tar.zst"
      return 0
    fi
  fi

  if [[ -f "${path}.tar.gz" ]]; then
    if bool_is_true "$AUTO_EXTRACT_FOR_ACTIONS"; then
      extract_archive_to_temp "${path}.tar.gz"
      return 0
    fi
  fi

  die "Backup path not found as directory or archive: $path"
}

get_latest_full_backup() {
  local latest_dir latest_zst latest_gz latest
  latest_dir="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name "${FULL_PREFIX}_*" 2>/dev/null | sort | tail -n 1 || true)"
  latest_zst="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f -name "${FULL_PREFIX}_*.tar.zst" 2>/dev/null | sort | tail -n 1 || true)"
  latest_gz="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f -name "${FULL_PREFIX}_*.tar.gz" 2>/dev/null | sort | tail -n 1 || true)"

  latest="$(printf '%s\n%s\n%s\n' "$latest_dir" "$latest_zst" "$latest_gz" | sed '/^$/d' | sort | tail -n 1 || true)"
  [[ -n "$latest" ]] && echo "$latest"
}

get_incrementals_for_base_name() {
  local base_name="$1"

  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) | sort | while read -r item; do
    local resolved meta_file
    resolved="$(resolve_backup_path "$item")"
    meta_file="$resolved/$META_DIR_NAME/base_name"
    if [[ -f "$meta_file" ]] && [[ "$(cat "$meta_file")" == "$base_name" ]]; then
      echo "$item"
    fi
  done
}

get_latest_incremental_or_base() {
  local base_path="$1"
  local base_dir base_name last
  base_dir="$(resolve_backup_path "$base_path")"
  base_name="$(basename "$base_dir")"
  last="$base_path"

  while read -r inc; do
    [[ -n "$inc" ]] && last="$inc"
  done < <(get_incrementals_for_base_name "$base_name")

  echo "$last"
}

assert_target_exists() {
  [[ -n "$TARGET_DIR" ]] || die "--target-dir is required"
}

assert_incremental_exists() {
  [[ -n "$INCREMENTAL_DIR" ]] || die "--incremental-dir is required"
}

cleanup_old_backups() {
  local now epoch_cutoff
  now="$(date +%s)"
  epoch_cutoff=$(( now - RETENTION_DAYS * 86400 ))

  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) | while read -r item; do
    [[ "$item" == "$LOG_DIR" ]] && continue
    local mtime
    mtime="$(stat -c %Y "$item")"
    if (( mtime < epoch_cutoff )); then
      log "Deleting old backup item: $item"
      rm -rf -- "$item"
    fi
  done
}

print_info() {
  assert_target_exists
  local real_target
  real_target="$(resolve_backup_path "$TARGET_DIR")"

  log "Backup info for: $TARGET_DIR"
  [[ -f "$real_target/xtrabackup_info" ]] && { echo "----- xtrabackup_info -----"; cat "$real_target/xtrabackup_info"; }
  [[ -f "$real_target/xtrabackup_checkpoints" ]] && { echo "----- xtrabackup_checkpoints -----"; cat "$real_target/xtrabackup_checkpoints"; }
  [[ -d "$real_target/$META_DIR_NAME" ]] && { echo "----- script metadata -----"; find "$real_target/$META_DIR_NAME" -maxdepth 1 -type f -print -exec cat {} \;; }
}

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  MODE="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
      --target-dir) TARGET_DIR="$2"; shift 2 ;;
      --incremental-dir) INCREMENTAL_DIR="$2"; shift 2 ;;
      --base-dir) BASE_DIR="$2"; shift 2 ;;
      --datadir) DATADIR="$2"; shift 2 ;;
      --socket) SOCKET="$2"; shift 2 ;;
      --host) HOST="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --user) USER_NAME="$2"; shift 2 ;;
      --password) PASSWORD="$2"; shift 2 ;;
      --password-file) PASSWORD_FILE="$2"; shift 2 ;;
      --parallel) PARALLEL="$2"; shift 2 ;;
      --use-memory) USE_MEMORY="$2"; shift 2 ;;
      --tmpdir) TMPDIR="$2"; shift 2 ;;
      --open-files-limit) OPEN_FILES_LIMIT="$2"; shift 2 ;;
      --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
      --service-name) SERVICE_NAME="$2"; shift 2 ;;
      --mysql-owner) MYSQL_OWNER="$2"; shift 2 ;;
      --force-non-empty-directories) FORCE_NON_EMPTY_DIRECTORIES="$2"; shift 2 ;;
      --stop-service-on-restore) STOP_SERVICE_ON_RESTORE="$2"; shift 2 ;;
      --chown-after-restore) CHOWN_AFTER_RESTORE="$2"; shift 2 ;;
      --timestamp) TIMESTAMP="$2"; shift 2 ;;
      --archive-format) ARCHIVE_FORMAT="$2"; shift 2 ;;
      --keep-uncompressed) KEEP_UNCOMPRESSED="$2"; shift 2 ;;
      --auto-extract-for-actions) AUTO_EXTRACT_FOR_ACTIONS="$2"; shift 2 ;;
      --extract-root) EXTRACT_ROOT="$2"; shift 2 ;;
      --zstd-level) ZSTD_LEVEL="$2"; shift 2 ;;
      --gzip-level) GZIP_LEVEL="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

run_full_backup() {
  ensure_dir "$BACKUP_ROOT"
  ensure_dir "$LOG_DIR"
  read_password_from_file
  build_common_args

  TARGET_DIR="${TARGET_DIR:-$BACKUP_ROOT/${FULL_PREFIX}_${TIMESTAMP}}"
  LOG_FILE="$LOG_DIR/full_${TIMESTAMP}.log"

  ensure_dir "$TARGET_DIR"
  ensure_dir "$TARGET_DIR/$META_DIR_NAME"

  log "Starting full backup: $TARGET_DIR"
  "$MARIADB_BACKUP_BIN" \
    "${MARIADB_ARGS[@]}" \
    --backup \
    --target-dir="$TARGET_DIR" \
    2>&1 | tee "$LOG_FILE"

  write_meta "$TARGET_DIR"
  echo "$(basename "$TARGET_DIR")" > "$TARGET_DIR/$META_DIR_NAME/base_name"
  echo "full" > "$TARGET_DIR/$META_DIR_NAME/backup_type"

  compress_backup_dir "$TARGET_DIR"
  cleanup_old_backups

  log "Full backup completed"
}

run_incremental_backup() {
  ensure_dir "$BACKUP_ROOT"
  ensure_dir "$LOG_DIR"
  read_password_from_file
  build_common_args

  local base last_ref real_last_ref
  base="${BASE_DIR:-$(get_latest_full_backup)}"
  [[ -n "$base" ]] || die "No full backup found. Create a full backup first."

  last_ref="$(get_latest_incremental_or_base "$base")"
  real_last_ref="$(resolve_backup_path "$last_ref")"

  TARGET_DIR="${TARGET_DIR:-$BACKUP_ROOT/${INCR_PREFIX}_${TIMESTAMP}}"
  LOG_FILE="$LOG_DIR/incr_${TIMESTAMP}.log"

  ensure_dir "$TARGET_DIR"
  ensure_dir "$TARGET_DIR/$META_DIR_NAME"

  log "Starting incremental backup: $TARGET_DIR"
  log "Base backup item: $base"
  log "Incremental basedir resolved: $real_last_ref"

  "$MARIADB_BACKUP_BIN" \
    "${MARIADB_ARGS[@]}" \
    --backup \
    --target-dir="$TARGET_DIR" \
    --incremental-basedir="$real_last_ref" \
    2>&1 | tee "$LOG_FILE"

  write_meta "$TARGET_DIR"
  echo "$(basename "$(resolve_backup_path "$base")")" > "$TARGET_DIR/$META_DIR_NAME/base_name"
  echo "$last_ref" > "$TARGET_DIR/$META_DIR_NAME/parent_ref"
  echo "incremental" > "$TARGET_DIR/$META_DIR_NAME/backup_type"

  compress_backup_dir "$TARGET_DIR"
  cleanup_old_backups

  log "Incremental backup completed"
}

run_prepare_full() {
  assert_target_exists
  ensure_dir "$LOG_DIR"
  LOG_FILE="$LOG_DIR/prepare_full_${TIMESTAMP}.log"

  local real_target
  real_target="$(resolve_backup_path "$TARGET_DIR")"

  log "Preparing full backup: $real_target"
  "$MARIADB_BACKUP_BIN" \
    --prepare \
    --use-memory="$USE_MEMORY" \
    --target-dir="$real_target" \
    2>&1 | tee "$LOG_FILE"

  log "Prepare full completed: $real_target"
}

run_prepare_incremental() {
  assert_target_exists
  assert_incremental_exists
  ensure_dir "$LOG_DIR"
  LOG_FILE="$LOG_DIR/prepare_incr_${TIMESTAMP}.log"

  local real_target real_incremental
  real_target="$(resolve_backup_path "$TARGET_DIR")"
  real_incremental="$(resolve_backup_path "$INCREMENTAL_DIR")"

  log "Applying incremental backup"
  log "Base target-dir: $real_target"
  log "Incremental dir : $real_incremental"

  "$MARIADB_BACKUP_BIN" \
    --prepare \
    --use-memory="$USE_MEMORY" \
    --target-dir="$real_target" \
    --incremental-dir="$real_incremental" \
    2>&1 | tee "$LOG_FILE"

  log "Incremental apply completed"
}

run_chain_prepare() {
  assert_target_exists

  local real_target base_name inc
  real_target="$(resolve_backup_path "$TARGET_DIR")"
  base_name="$(basename "$real_target")"

  TARGET_DIR="$real_target"
  run_prepare_full

  while read -r inc; do
    [[ -n "$inc" ]] || continue
    INCREMENTAL_DIR="$inc"
    run_prepare_incremental
  done < <(get_incrementals_for_base_name "$base_name")

  log "Full chain prepared successfully for base: $real_target"
}

run_restore() {
  assert_target_exists
  ensure_dir "$LOG_DIR"
  LOG_FILE="$LOG_DIR/restore_${TIMESTAMP}.log"

  local real_target
  real_target="$(resolve_backup_path "$TARGET_DIR")"

  if bool_is_true "$STOP_SERVICE_ON_RESTORE"; then
    log "Stopping service: $SERVICE_NAME"
    systemctl stop "$SERVICE_NAME"
  fi

  if [[ -d "$DATADIR" ]] && [[ -n "$(find "$DATADIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    if ! bool_is_true "$FORCE_NON_EMPTY_DIRECTORIES"; then
      die "Datadir is not empty: $DATADIR"
    fi
  fi

  log "Restoring backup from $real_target to $DATADIR"
  if bool_is_true "$FORCE_NON_EMPTY_DIRECTORIES"; then
    "$MARIADB_BACKUP_BIN" --copy-back --force-non-empty-directories --target-dir="$real_target" --datadir="$DATADIR" 2>&1 | tee "$LOG_FILE"
  else
    "$MARIADB_BACKUP_BIN" --copy-back --target-dir="$real_target" --datadir="$DATADIR" 2>&1 | tee "$LOG_FILE"
  fi

  if bool_is_true "$CHOWN_AFTER_RESTORE"; then
    chown -R "$MYSQL_OWNER" "$DATADIR"
  fi

  if bool_is_true "$STOP_SERVICE_ON_RESTORE"; then
    systemctl start "$SERVICE_NAME"
  fi

  log "Restore completed"
}

main() {
  parse_args "$@"
  require_bin "$MARIADB_BACKUP_BIN"
  require_bin find
  require_bin sort
  require_bin tee
  require_bin tar
  require_bin mktemp

  case "$ARCHIVE_FORMAT" in
    tar.zst) require_bin zstd ;;
    tar.gz)  require_bin gzip ;;
    *) die "Unsupported ARCHIVE_FORMAT: $ARCHIVE_FORMAT" ;;
  esac

  case "$MODE" in
    full) run_full_backup ;;
    incr) run_incremental_backup ;;
    prepare-full) run_prepare_full ;;
    prepare-incr) run_prepare_incremental ;;
    chain-prepare) run_chain_prepare ;;
    restore) run_restore ;;
    info) print_info ;;
    *) usage; die "Unsupported mode: $MODE" ;;
  esac
}

main "$@"