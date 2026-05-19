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

FULL_PREFIX="${FULL_PREFIX:-full}"
INCR_PREFIX="${INCR_PREFIX:-inc}"
CLEANUP_AFTER_BACKUP="${CLEANUP_AFTER_BACKUP:-false}"
MIN_FULL_BACKUPS="${MIN_FULL_BACKUPS:-3}"
CLEANUP_DRY_RUN="${CLEANUP_DRY_RUN:-false}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_DIR="${LOG_DIR:-$BACKUP_ROOT/logs}"
META_DIR_NAME="${META_DIR_NAME:-meta}"
TIMESTAMP="${TIMESTAMP:-$(date '+%F_%H-%M-%S')}"
SERVICE_NAME="${SERVICE_NAME:-mariadb}"
MYSQL_OWNER="${MYSQL_OWNER:-mysql:mysql}"

ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-tar.zst}"   # tar.zst կամ tar.gz
KEEP_UNCOMPRESSED="${KEEP_UNCOMPRESSED:-false}"
AUTO_EXTRACT_FOR_ACTIONS="${AUTO_EXTRACT_FOR_ACTIONS:-true}"
EXTRACT_ROOT="${EXTRACT_ROOT:-$BACKUP_ROOT/.tmp}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"

TARGET_DIR="${TARGET_DIR:-}"
INCREMENTAL_DIR="${INCREMENTAL_DIR:-}"
BASE_DIR="${BASE_DIR:-}"
FORCE_NON_EMPTY_DIRECTORIES="${FORCE_NON_EMPTY_DIRECTORIES:-false}"
STOP_SERVICE_ON_RESTORE="${STOP_SERVICE_ON_RESTORE:-true}"
CHOWN_AFTER_RESTORE="${CHOWN_AFTER_RESTORE:-true}"


# SSH remote execution
SSH_HOST="${SSH_HOST:-}"
SSH_USER="${SSH_USER:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_CONFIG="${SSH_CONFIG:-}"
SSH_REMOTE_SCRIPT="${SSH_REMOTE_SCRIPT:-/usr/local/bin/backup_full_and_incrimental.sh}"
SSH_SUDO="${SSH_SUDO:-true}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
REMOTE_RUN="${REMOTE_RUN:-false}"
REMOTE_STREAM_MODE="${REMOTE_STREAM_MODE:-true}"
REMOTE_TMPDIR="${REMOTE_TMPDIR:-/tmp/mariadb-restore}"
REMOTE_BACKUP_BIN="${REMOTE_BACKUP_BIN:-}"
MBSTREAM_BIN="${MBSTREAM_BIN:-mbstream}"
SSH_CONFIG="${SSH_CONFIG:-}"

# Zabbix sender
ZBX_ENABLE="${ZBX_ENABLE:-false}"
ZBX_SERVER="${ZBX_SERVER:-}"
ZBX_HOST="${ZBX_HOST:-$(hostname -f 2>/dev/null || hostname)}"
ZBX_SENDER="${ZBX_SENDER:-zabbix_sender}"
ZBX_NOTIFY_ON_FAILURE="${ZBX_NOTIFY_ON_FAILURE:-true}"
ZBX_NOTIFY_FULL_SUCCESS="${ZBX_NOTIFY_FULL_SUCCESS:-true}"
ZBX_NOTIFY_INCR_SUCCESS="${ZBX_NOTIFY_INCR_SUCCESS:-false}"
ZBX_KEY_PREFIX="${ZBX_KEY_PREFIX:-mariadb.backup}"

ORIGINAL_ARGS=("$@")

MODE=""
LOG_FILE=""
MARIADB_ARGS=()
WORK_DIRS_TO_CLEANUP=()

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%F %T')] $*" >&2
}

cleanup_tmp_extracts() {
  [[ -n "${EXTRACT_ROOT:-}" ]] || return 0
  [[ -d "$EXTRACT_ROOT" ]] || return 0

  log "Cleaning old temporary extract directories: $EXTRACT_ROOT"

  find "$EXTRACT_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'extract.*' \
    -mmin +10 \
    -exec rm -rf {} \; 2>/dev/null || true
}

cleanup() {
  local d

  cleanup_tmp_extracts

  for d in "${WORK_DIRS_TO_CLEANUP[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
  done

  # keep only current script temp dirs cleanup by WORK_DIRS_TO_CLEANUP,
  # old failed extracts are cleaned at next run by cleanup_tmp_extracts
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

SSH remote execution:
  --ssh-host HOST
  --ssh-user USER
  --ssh-port PORT
  --ssh-key PATH
  --ssh-remote-script PATH
  --ssh-sudo true|false
  --ssh-strict-host-key-checking yes|no|accept-new
  --ssh-connect-timeout N
  --ssh-config PATH

Zabbix:
  --zbx-enable true|false
  --zbx-server IP_OR_DNS
  --zbx-host HOST_IN_ZABBIX
  --zbx-sender PATH
  --zbx-notify-on-failure true|false
  --zbx-notify-full-success true|false
  --zbx-notify-incr-success true|false
  --zbx-key-prefix PREFIX

Cleanup:
  --cleanup-after-backup true|false
  --min-full-backups N
  --cleanup-dry-run true|false
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
  [[ -w "$1" ]] || die "Directory is not writable by user $(id -un): $1"
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

  [[ -r "$archive" ]] || die "Archive is not readable by user $(id -un): $archive"

  ensure_dir "$EXTRACT_ROOT"
  workdir="$(mktemp -d "$EXTRACT_ROOT/extract.XXXXXX")" || die "Cannot create temp extract directory under: $EXTRACT_ROOT"
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
  local item inc_base_name

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue

    inc_base_name="$(read_meta_file_from_backup_item "$item" "base_name" 2>/dev/null || true)"

    if [[ "$inc_base_name" == "$base_name" ]]; then
      echo "$item"
    fi
  done < <(list_incremental_backup_items)
}

get_latest_incremental_or_base() {
  local base_path="$1"
  local base_name last

  base_name="$(strip_archive_ext "$base_path")"
  last="$base_path"

  while IFS= read -r inc; do
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

strip_archive_ext() {
  local item="$1"
  local base
  base="$(basename "$item")"

  base="${base%.tar.zst}"
  base="${base%.tar.gz}"

  echo "$base"
}

backup_item_mtime() {
  stat -c %Y "$1"
}

read_meta_file_from_backup_item() {
  local item="$1"
  local meta_file="$2"
  local base

  base="$(strip_archive_ext "$item")"

  if [[ -d "$item" ]]; then
    [[ -f "$item/$META_DIR_NAME/$meta_file" ]] || return 1
    cat "$item/$META_DIR_NAME/$meta_file"
    return 0
  fi

  case "$item" in
    *.tar.zst)
      zstd -dc "$item" 2>/dev/null | tar -xOf - "$base/$META_DIR_NAME/$meta_file" 2>/dev/null
      ;;
    *.tar.gz)
      gzip -dc "$item" 2>/dev/null | tar -xOf - "$base/$META_DIR_NAME/$meta_file" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

list_full_backup_items() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) \
    \( -name "${FULL_PREFIX}_*" -o -name "${FULL_PREFIX}_*.tar.zst" -o -name "${FULL_PREFIX}_*.tar.gz" \) \
    ! -path "$LOG_DIR" \
    | sort
}

list_incremental_backup_items() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) \
    \( -name "${INCR_PREFIX}_*" -o -name "${INCR_PREFIX}_*.tar.zst" -o -name "${INCR_PREFIX}_*.tar.gz" \) \
    ! -path "$LOG_DIR" \
    | sort
}

delete_item() {
  local item="$1"

  if bool_is_true "$CLEANUP_DRY_RUN"; then
    log "[DRY-RUN] Would delete: $item"
  else
    log "Deleting: $item"
    rm -rf -- "$item"
  fi
}

delete_related_incrementals_for_full() {
  local full_base_name="$1"
  local inc inc_base_name

  while IFS= read -r inc; do
    [[ -n "$inc" ]] || continue

    inc_base_name="$(read_meta_file_from_backup_item "$inc" "base_name" 2>/dev/null || true)"

    if [[ "$inc_base_name" == "$full_base_name" ]]; then
      delete_item "$inc"
    fi
  done < <(list_incremental_backup_items)
}

cleanup_old_backups() {
  ensure_dir "$BACKUP_ROOT"

  local now cutoff total_full item mtime full_base_name

  now="$(date +%s)"
  cutoff=$(( now - RETENTION_DAYS * 86400 ))

  total_full="$(list_full_backup_items | wc -l | awk '{print $1}')"

  log "Cleanup started"
  log "BACKUP_ROOT=$BACKUP_ROOT"
  log "RETENTION_DAYS=$RETENTION_DAYS"
  log "MIN_FULL_BACKUPS=$MIN_FULL_BACKUPS"
  log "Current full backups count=$total_full"
  log "CLEANUP_DRY_RUN=$CLEANUP_DRY_RUN"

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue

    if (( total_full <= MIN_FULL_BACKUPS )); then
      log "Stop cleanup: full backup count ($total_full) <= MIN_FULL_BACKUPS ($MIN_FULL_BACKUPS)"
      break
    fi

    mtime="$(backup_item_mtime "$item")"

    if (( mtime >= cutoff )); then
      log "Keeping backup because it is not older than retention: $item"
      continue
    fi

    full_base_name="$(strip_archive_ext "$item")"

    log "Old full backup selected for deletion: $item"
    log "Deleting related incrementals for base_name=$full_base_name"

    delete_related_incrementals_for_full "$full_base_name"
    delete_item "$item"

    total_full=$(( total_full - 1 ))

  done < <(list_full_backup_items)

  log "Cleanup finished. Remaining full backups count=$total_full"
}

run_cleanup() {
  cleanup_old_backups
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
  MODE="full"

  if [[ $# -gt 0 ]]; then
    case "$1" in
      full|incr|prepare-full|prepare-incr|chain-prepare|restore|info|cleanup)
        MODE="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        MODE="full"
        ;;
      *)
        die "Unknown mode or argument: $1"
        ;;
    esac
  fi

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

      --ssh-host) SSH_HOST="$2"; shift 2 ;;
      --ssh-user) SSH_USER="$2"; shift 2 ;;
      --ssh-port) SSH_PORT="$2"; shift 2 ;;
      --ssh-key) SSH_KEY="$2"; shift 2 ;;
      --ssh-config) SSH_CONFIG="$2"; shift 2 ;;
      --ssh-remote-script) SSH_REMOTE_SCRIPT="$2"; shift 2 ;;
      --ssh-sudo) SSH_SUDO="$2"; shift 2 ;;
      --ssh-strict-host-key-checking) SSH_STRICT_HOST_KEY_CHECKING="$2"; shift 2 ;;
      --ssh-connect-timeout) SSH_CONNECT_TIMEOUT="$2"; shift 2 ;;
      --remote-run) REMOTE_RUN="$2"; shift 2 ;;
      --remote-stream-mode) REMOTE_STREAM_MODE="$2"; shift 2 ;;
      --remote-tmpdir) REMOTE_TMPDIR="$2"; shift 2 ;;
      --remote-backup-bin) REMOTE_BACKUP_BIN="$2"; shift 2 ;;
      --mbstream-bin) MBSTREAM_BIN="$2"; shift 2 ;;

      --zbx-enable) ZBX_ENABLE="$2"; shift 2 ;;
      --zbx-server) ZBX_SERVER="$2"; shift 2 ;;
      --zbx-host) ZBX_HOST="$2"; shift 2 ;;
      --zbx-sender) ZBX_SENDER="$2"; shift 2 ;;
      --zbx-notify-on-failure) ZBX_NOTIFY_ON_FAILURE="$2"; shift 2 ;;
      --zbx-notify-full-success) ZBX_NOTIFY_FULL_SUCCESS="$2"; shift 2 ;;
      --zbx-notify-incr-success) ZBX_NOTIFY_INCR_SUCCESS="$2"; shift 2 ;;
      --zbx-key-prefix) ZBX_KEY_PREFIX="$2"; shift 2 ;;

      --cleanup-after-backup) CLEANUP_AFTER_BACKUP="$2"; shift 2 ;;
      --min-full-backups) MIN_FULL_BACKUPS="$2"; shift 2 ;;
      --cleanup-dry-run) CLEANUP_DRY_RUN="$2"; shift 2 ;;
      -h|--help)
        usage
        exit 0
        ;;

      *)
        die "Unknown argument: $1"
        ;;
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

  if bool_is_true "$CLEANUP_AFTER_BACKUP"; then
    cleanup_old_backups
  else
    log "Cleanup after backup is disabled. Use --cleanup-after-backup true to enable."
  fi

  log "Full backup completed"
}

run_incremental_backup() {
  ensure_dir "$BACKUP_ROOT"
  ensure_dir "$LOG_DIR"
  read_password_from_file
  build_common_args

  local base last_ref lsn

  base="${BASE_DIR:-$(get_latest_full_backup)}"
  [[ -n "$base" ]] || die "No full backup found. Create a full backup first."

  last_ref="$(get_latest_incremental_or_base "$base")"
  lsn="$(get_backup_to_lsn_from_item "$last_ref")"

  [[ -n "$lsn" ]] || die "Could not read to_lsn from: $last_ref"

  TARGET_DIR="${TARGET_DIR:-$BACKUP_ROOT/${INCR_PREFIX}_${TIMESTAMP}}"
  LOG_FILE="$LOG_DIR/incr_${TIMESTAMP}.log"

  ensure_dir "$TARGET_DIR"
  ensure_dir "$TARGET_DIR/$META_DIR_NAME"

  log "Starting LOCAL incremental backup: $TARGET_DIR"
  log "Base backup item: $base"
  log "Incremental parent item: $last_ref"
  log "Incremental LSN: $lsn"

  "$MARIADB_BACKUP_BIN" \
    "${MARIADB_ARGS[@]}" \
    --backup \
    --target-dir="$TARGET_DIR" \
    --incremental-lsn="$lsn" \
    2>&1 | tee "$LOG_FILE"

  write_meta "$TARGET_DIR"
  echo "$(strip_archive_ext "$base")" > "$TARGET_DIR/$META_DIR_NAME/base_name"
  echo "$last_ref" > "$TARGET_DIR/$META_DIR_NAME/parent_ref"
  echo "$lsn" > "$TARGET_DIR/$META_DIR_NAME/incremental_lsn"
  echo "incremental" > "$TARGET_DIR/$META_DIR_NAME/backup_type"

  compress_backup_dir "$TARGET_DIR"

  if bool_is_true "$CLEANUP_AFTER_BACKUP"; then
    cleanup_old_backups
  else
    log "Cleanup after backup is disabled. Use --cleanup-after-backup true to enable."
  fi

  log "Local incremental backup completed"
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

ssh_remote_target() {
  if [[ -n "$SSH_USER" ]]; then
    echo "${SSH_USER}@${SSH_HOST}"
  else
    echo "$SSH_HOST"
  fi
}

build_ssh_array() {
  SSH_CMD=(ssh
    -o "BatchMode=yes"
    -o "StrictHostKeyChecking=$SSH_STRICT_HOST_KEY_CHECKING"
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
  )

  if [[ -n "$SSH_CONFIG" ]]; then
    SSH_CMD+=(-F "$SSH_CONFIG")
  fi

  if [[ -n "$SSH_PORT" ]]; then
    SSH_CMD+=(-p "$SSH_PORT")
  fi

  if [[ -n "$SSH_KEY" ]]; then
    SSH_CMD+=(-i "$SSH_KEY")
  fi
}

q() {
  printf '%q' "$1"
}

remote_backup_bin_command() {
  if [[ -n "$REMOTE_BACKUP_BIN" ]]; then
    printf '%q' "$REMOTE_BACKUP_BIN"
  else
    echo '$(command -v mariadb-backup || command -v mariabackup)'
  fi
}

get_backup_to_lsn() {
  local dir="$1"
  local checkpoints="$dir/xtrabackup_checkpoints"

  [[ -f "$checkpoints" ]] || die "xtrabackup_checkpoints not found: $checkpoints"

  awk -F= '/^[[:space:]]*to_lsn[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$checkpoints" | tail -n 1
}

run_remote_stream_full_backup() {
  ensure_dir "$BACKUP_ROOT"
  ensure_dir "$LOG_DIR"
  read_password_from_file
  require_bin "$MBSTREAM_BIN"

  TARGET_DIR="${TARGET_DIR:-$BACKUP_ROOT/${FULL_PREFIX}_${TIMESTAMP}}"
  LOG_FILE="$LOG_DIR/remote_full_${TIMESTAMP}.log"

  ensure_dir "$TARGET_DIR"
  ensure_dir "$TARGET_DIR/$META_DIR_NAME"

  local remote remote_cmd rc
  remote="$(ssh_remote_target)"
  build_ssh_array

  [[ -n "$PASSWORD" ]] || die "Password is empty. Use --password-file or --password."

  remote_cmd="
set -Eeuo pipefail
BIN=\$(command -v mariadb-backup || command -v mariabackup)
if [[ -z \"\$BIN\" ]]; then
  echo 'ERROR: mariadb-backup/mariabackup not found on remote server' >&2
  exit 1
fi

sudo -n \"\$BIN\" \
  --backup \
  --stream=xbstream \
  --user=$(q "$USER_NAME") \
  --password=$(q "$PASSWORD") \
  --socket=$(q "$SOCKET") \
  --parallel=$(q "$PARALLEL") \
  --open-files-limit=$(q "$OPEN_FILES_LIMIT") \
  --tmpdir=$(q "$TMPDIR") \
  --ftwrl-wait-timeout=$(q "$FTWRL_WAIT_TIMEOUT") \
  --ftwrl-wait-threshold=$(q "$FTWRL_WAIT_THRESHOLD") \
  --ftwrl-wait-query-type=$(q "$FTWRL_WAIT_QUERY_TYPE")
"

  log "Starting REMOTE full backup over SSH"
  log "Remote: $remote"
  log "Local target: $TARGET_DIR"

  set +e
  (
    set -o pipefail
    "${SSH_CMD[@]}" "$remote" "$remote_cmd" | "$MBSTREAM_BIN" -x -C "$TARGET_DIR"
  ) 2>&1 | tee "$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  set -e

  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi

  write_meta "$TARGET_DIR"
  echo "$(basename "$TARGET_DIR")" > "$TARGET_DIR/$META_DIR_NAME/base_name"
  echo "full" > "$TARGET_DIR/$META_DIR_NAME/backup_type"
  echo "$SSH_HOST" > "$TARGET_DIR/$META_DIR_NAME/source_host"

  compress_backup_dir "$TARGET_DIR"
  
  if bool_is_true "$CLEANUP_AFTER_BACKUP"; then
    cleanup_old_backups
  else
    log "Cleanup after backup is disabled. Use --cleanup-after-backup true to enable."
  fi

  log "REMOTE full backup completed"
}

run_remote_stream_incremental_backup() {
  ensure_dir "$BACKUP_ROOT"
  ensure_dir "$LOG_DIR"
  read_password_from_file
  require_bin "$MBSTREAM_BIN"

  local base last_ref real_last_ref lsn remote remote_cmd rc

  base="${BASE_DIR:-$(get_latest_full_backup)}"
  [[ -n "$base" ]] || die "No full backup found. Create full backup first."

  last_ref="$(get_latest_incremental_or_base "$base")"
  lsn="$(get_backup_to_lsn_from_item "$last_ref")"

  [[ -n "$lsn" ]] || die "Could not read to_lsn from: $last_ref"

  TARGET_DIR="${TARGET_DIR:-$BACKUP_ROOT/${INCR_PREFIX}_${TIMESTAMP}}"
  LOG_FILE="$LOG_DIR/remote_incr_${TIMESTAMP}.log"

  ensure_dir "$TARGET_DIR"
  ensure_dir "$TARGET_DIR/$META_DIR_NAME"

  remote="$(ssh_remote_target)"
  build_ssh_array

  [[ -n "$PASSWORD" ]] || die "Password is empty. Use --password-file or --password."

  remote_cmd="
set -Eeuo pipefail
BIN=\$(command -v mariadb-backup || command -v mariabackup)
if [[ -z \"\$BIN\" ]]; then
  echo 'ERROR: mariadb-backup/mariabackup not found on remote server' >&2
  exit 1
fi

sudo -n \"\$BIN\" \
  --backup \
  --stream=xbstream \
  --incremental-lsn=$(q "$lsn") \
  --user=$(q "$USER_NAME") \
  --password=$(q "$PASSWORD") \
  --socket=$(q "$SOCKET") \
  --parallel=$(q "$PARALLEL") \
  --open-files-limit=$(q "$OPEN_FILES_LIMIT") \
  --tmpdir=$(q "$TMPDIR") \
  --ftwrl-wait-timeout=$(q "$FTWRL_WAIT_TIMEOUT") \
  --ftwrl-wait-threshold=$(q "$FTWRL_WAIT_THRESHOLD") \
  --ftwrl-wait-query-type=$(q "$FTWRL_WAIT_QUERY_TYPE")
"

  log "Starting REMOTE incremental backup over SSH"
  log "Remote: $remote"
  log "Incremental LSN: $lsn"
  log "Local target: $TARGET_DIR"

  set +e
  (
    set -o pipefail
    "${SSH_CMD[@]}" "$remote" "$remote_cmd" | "$MBSTREAM_BIN" -x -C "$TARGET_DIR"
  ) 2>&1 | tee "$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  set -e

  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi

  write_meta "$TARGET_DIR"
  echo "$(strip_archive_ext "$base")" > "$TARGET_DIR/$META_DIR_NAME/base_name"
  echo "$last_ref" > "$TARGET_DIR/$META_DIR_NAME/parent_ref"
  echo "$lsn" > "$TARGET_DIR/$META_DIR_NAME/incremental_lsn"
  echo "incremental" > "$TARGET_DIR/$META_DIR_NAME/backup_type"
  echo "$SSH_HOST" > "$TARGET_DIR/$META_DIR_NAME/source_host"

  compress_backup_dir "$TARGET_DIR"
  
  if bool_is_true "$CLEANUP_AFTER_BACKUP"; then
    cleanup_old_backups
  else
    log "Cleanup after backup is disabled. Use --cleanup-after-backup true to enable."
  fi

  log "REMOTE incremental backup completed"
}

run_remote_restore() {
  assert_target_exists
  ensure_dir "$LOG_DIR"

  local real_target parent base remote remote_tmp remote_cmd rc
  real_target="$(resolve_backup_path "$TARGET_DIR")"

  parent="$(dirname "$real_target")"
  base="$(basename "$real_target")"

  LOG_FILE="$LOG_DIR/remote_restore_${TIMESTAMP}.log"

  remote="$(ssh_remote_target)"
  remote_tmp="$REMOTE_TMPDIR/restore_${TIMESTAMP}"

  build_ssh_array

  log "Starting REMOTE restore over SSH"
  log "Remote: $remote"
  log "Local prepared backup dir: $real_target"
  log "Remote temp dir: $remote_tmp"

  remote_cmd="
set -Eeuo pipefail

BIN=\$(command -v mariadb-backup || command -v mariabackup)
if [[ -z \"\$BIN\" ]]; then
  echo 'ERROR: mariadb-backup/mariabackup not found on remote server' >&2
  exit 1
fi

sudo -n mkdir -p $(q "$remote_tmp")
sudo -n tar -C $(q "$remote_tmp") -xf -

if $(bool_is_true "$STOP_SERVICE_ON_RESTORE" && echo true || echo false); then
  sudo -n systemctl stop $(q "$SERVICE_NAME")
fi

if [[ -d $(q "$DATADIR") ]] && [[ -n \"\$(sudo -n find $(q "$DATADIR") -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)\" ]]; then
  if ! $(bool_is_true "$FORCE_NON_EMPTY_DIRECTORIES" && echo true || echo false); then
    echo 'ERROR: Remote datadir is not empty: $(q "$DATADIR")' >&2
    exit 1
  fi
fi

if $(bool_is_true "$FORCE_NON_EMPTY_DIRECTORIES" && echo true || echo false); then
  sudo -n \"\$BIN\" --copy-back --force-non-empty-directories --target-dir=$(q "$remote_tmp/$base") --datadir=$(q "$DATADIR")
else
  sudo -n \"\$BIN\" --copy-back --target-dir=$(q "$remote_tmp/$base") --datadir=$(q "$DATADIR")
fi

if $(bool_is_true "$CHOWN_AFTER_RESTORE" && echo true || echo false); then
  sudo -n chown -R $(q "$MYSQL_OWNER") $(q "$DATADIR")
fi

if $(bool_is_true "$STOP_SERVICE_ON_RESTORE" && echo true || echo false); then
  sudo -n systemctl start $(q "$SERVICE_NAME")
fi

sudo -n rm -rf $(q "$remote_tmp")
"

  set +e
  (
    set -o pipefail
    tar -C "$parent" -cf - "$base" | "${SSH_CMD[@]}" "$remote" "$remote_cmd"
  ) 2>&1 | tee "$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  set -e

  return "$rc"
}

run_selected_remote_stream_mode() {
  case "$MODE" in
    full) run_remote_stream_full_backup ;;
    incr) run_remote_stream_incremental_backup ;;
    restore) run_remote_restore ;;
    *)
      die "Remote stream mode supports only: full, incr, restore. For prepare/info use local backup server mode."
      ;;
  esac
}

run_remote_stream_and_report() {
  ensure_dir "$LOG_DIR"

  [[ -n "$SSH_HOST" ]] || die "--ssh-host is required"

  local start_time end_time rc wrapper_log
  start_time="$(date '+%F %T')"
  wrapper_log="$LOG_DIR/remote_stream_${MODE}_${TIMESTAMP}.log"

  set +e
  (
    run_selected_remote_stream_mode
  ) 2>&1 | tee "$wrapper_log"
  rc="${PIPESTATUS[0]}"
  set -e

  end_time="$(date '+%F %T')"

  send_zabbix_report "$MODE" "$rc" "$start_time" "$end_time" "$wrapper_log"

  exit "$rc"
}

build_remote_command() {
  local args=("${ORIGINAL_ARGS[@]}" "--remote-run" "true" "--zbx-enable" "false")
  local cmd=""

  if bool_is_true "$SSH_SUDO"; then
    cmd="sudo -n "
  fi

  cmd+="$(printf '%q' "$SSH_REMOTE_SCRIPT")"

  local a
  for a in "${args[@]}"; do
    cmd+=" $(printf '%q' "$a")"
  done

  echo "$cmd"
}

run_selected_mode() {
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
    cleanup) run_cleanup ;;
    *) usage; die "Unsupported mode: $MODE" ;;
  esac
}

should_send_zabbix() {
  local mode="$1"
  local rc="$2"

  bool_is_true "$ZBX_ENABLE" || return 1

  case "$mode" in
    full|incr)
      return 0
      ;;
  esac

  return 1
}

send_zabbix_report() {
  local mode="$1"
  local rc="$2"
  local start_time="$3"
  local end_time="$4"
  local log_file="$5"

  should_send_zabbix "$mode" "$rc" || return 0

  [[ -n "$ZBX_SERVER" ]] || {
    log "Zabbix enabled but --zbx-server is empty. Skipping zabbix_sender."
    return 0
  }

  command -v "$ZBX_SENDER" >/dev/null 2>&1 || {
    log "zabbix_sender not found: $ZBX_SENDER. Skipping Zabbix report."
    return 0
  }

  local status result message run_host
  if [[ "$rc" -eq 0 ]]; then
    status=0
    result="SUCCESS"
  else
    status=1
    result="FAILED"
  fi

  if [[ -n "$SSH_HOST" && ! "$(bool_is_true "$REMOTE_RUN"; echo $?)" == "0" ]]; then
    run_host="$SSH_HOST"
  else
    run_host="$ZBX_HOST"
  fi

  message="MariaDB ${mode} backup ${result}. ZabbixHost=${ZBX_HOST}. RunHost=${run_host}. Start=${start_time}. End=${end_time}. RC=${rc}. Log=${log_file}"

  log "Sending Zabbix report: mode=$mode status=$status host=$ZBX_HOST"

  "$ZBX_SENDER" -z "$ZBX_SERVER" -s "$ZBX_HOST" -k "${ZBX_KEY_PREFIX}.${mode}.status" -o "$status" >/dev/null || true
  "$ZBX_SENDER" -z "$ZBX_SERVER" -s "$ZBX_HOST" -k "${ZBX_KEY_PREFIX}.${mode}.message" -o "$message" >/dev/null || true
  "$ZBX_SENDER" -z "$ZBX_SERVER" -s "$ZBX_HOST" -k "${ZBX_KEY_PREFIX}.${mode}.last_run" -o "$(date +%s)" >/dev/null || true

  if [[ "$rc" -eq 0 ]]; then
    "$ZBX_SENDER" -z "$ZBX_SERVER" -s "$ZBX_HOST" -k "${ZBX_KEY_PREFIX}.${mode}.success_last_run" -o "$(date +%s)" >/dev/null || true
  fi
}

run_local_and_report() {
  ensure_dir "$LOG_DIR"

  local start_time end_time rc wrapper_log
  start_time="$(date '+%F %T')"
  wrapper_log="$LOG_DIR/run_${MODE}_${TIMESTAMP}.log"

  set +e
  (
    run_selected_mode
  ) 2>&1 | tee "$wrapper_log"
  rc="${PIPESTATUS[0]}"
  set -e

  end_time="$(date '+%F %T')"

  send_zabbix_report "$MODE" "$rc" "$start_time" "$end_time" "$wrapper_log"

  exit "$rc"
}

run_ssh_and_report() {
  ensure_dir "$LOG_DIR"

  [[ -n "$SSH_HOST" ]] || die "--ssh-host is required for SSH mode"

  local start_time end_time rc wrapper_log remote remote_cmd
  start_time="$(date '+%F %T')"
  wrapper_log="$LOG_DIR/ssh_${MODE}_${TIMESTAMP}.log"

  if [[ -n "$SSH_USER" ]]; then
    remote="${SSH_USER}@${SSH_HOST}"
  else
    remote="$SSH_HOST"
  fi

  remote_cmd="$(build_remote_command)"

  local ssh_cmd=(ssh
    -o "BatchMode=yes"
    -o "StrictHostKeyChecking=$SSH_STRICT_HOST_KEY_CHECKING"
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
  )

  # Եթե ուզում ես օգտագործել կոնկրետ ssh config file
  if [[ -n "$SSH_CONFIG" ]]; then
    ssh_cmd+=(-F "$SSH_CONFIG")
  fi

  # Եթե --ssh-port տվել ես, միայն այդ դեպքում ավելացնի -p
  # Եթե չես տվել, թող ssh-ը կարդա .ssh/config-ից
  if [[ -n "$SSH_PORT" ]]; then
    ssh_cmd+=(-p "$SSH_PORT")
  fi

  # Եթե --ssh-key տվել ես, օգտագործի դա
  # Եթե չես տվել, թող ssh-ը կարդա IdentityFile-ը .ssh/config-ից
  if [[ -n "$SSH_KEY" ]]; then
    ssh_cmd+=(-i "$SSH_KEY")
  fi

  log "Running remote backup over SSH"
  log "Remote: $remote"
  log "Remote script: $SSH_REMOTE_SCRIPT"
  log "Mode: $MODE"

  set +e
  "${ssh_cmd[@]}" "$remote" "$remote_cmd" 2>&1 | tee "$wrapper_log"
  rc="${PIPESTATUS[0]}"
  set -e

  end_time="$(date '+%F %T')"

  send_zabbix_report "$MODE" "$rc" "$start_time" "$end_time" "$wrapper_log"

  exit "$rc"
}

read_file_from_archive_or_dir() {
  local item="$1"
  local relative_file="$2"
  local base

  if [[ -d "$item" ]]; then
    cat "$item/$relative_file"
    return 0
  fi

  base="$(basename "$item")"
  base="${base%.tar.zst}"
  base="${base%.tar.gz}"

  case "$item" in
    *.tar.zst)
      zstd -dc "$item" | tar -xOf - "$base/$relative_file"
      ;;
    *.tar.gz)
      gzip -dc "$item" | tar -xOf - "$base/$relative_file"
      ;;
    *)
      return 1
      ;;
  esac
}

get_backup_to_lsn_from_item() {
  local item="$1"

  read_file_from_archive_or_dir "$item" "xtrabackup_checkpoints" \
    | awk -F= '/^[[:space:]]*to_lsn[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' \
    | tail -n 1
}

main() {
  : "${FULL_PREFIX:=full}"
  : "${INCR_PREFIX:=inc}"
  : "${RETENTION_DAYS:=7}"
  : "${CLEANUP_AFTER_BACKUP:=false}"
  : "${MIN_FULL_BACKUPS:=2}"
  : "${CLEANUP_DRY_RUN:=false}"

  parse_args "$@"

  cleanup_tmp_extracts

  if [[ "$MODE" == "cleanup" ]]; then
    run_local_and_report
  elif [[ -n "$SSH_HOST" ]] && bool_is_true "$REMOTE_STREAM_MODE"; then
    run_remote_stream_and_report
  else
    run_local_and_report
  fi
}

main "$@"