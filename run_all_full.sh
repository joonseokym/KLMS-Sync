#!/bin/zsh

set -euo pipefail

COMMON_SH="$(cd "$(dirname "$0")" && pwd)/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$0" "${1:-}"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT
klms_require_login

export KLMS_RUN_STARTED_EPOCH="${KLMS_RUN_STARTED_EPOCH:-$(date +%s)}"
export KLMS_SHARED_COURSE_PAGES_JSON="${KLMS_SHARED_COURSE_PAGES_JSON:-$CACHE_DIR/core/course_pages.json}"
export KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON="${KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON:-$CACHE_DIR/core/all_week_course_pages.json}"
export KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="${KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON:-$CACHE_DIR/core/supplemental_primary_pages.json}"

prefetched_dashboard="$CACHE_DIR/dashboard.json"
for namespace in core notice files; do
  mkdir -p "$CACHE_DIR/$namespace"
  if [[ -s "$prefetched_dashboard" ]]; then
    cp "$prefetched_dashboard" "$CACHE_DIR/$namespace/dashboard.json"
  fi
done

run_serial_job() {
  local job_name="$1"
  local script_path="$2"
  local started_epoch
  local finished_epoch
  local job_status=0

  started_epoch="$(date +%s)"
  print -r -- "== $job_name start $(date '+%Y-%m-%d %H:%M:%S %Z') =="
  (
    cd "$SCRIPT_DIR"
	/usr/bin/env -u KLMS_SHARED_SYNC_LOCK_HELD -u KLMS_SHARED_SYNC_LOCK_DIR \
	  KLMS_USE_EXISTING_DASHBOARD=1 \
	  KLMS_PARENT_LOGIN_PREFLIGHT_READY=1 \
	  KLMS_RUN_STARTED_EPOCH="$KLMS_RUN_STARTED_EPOCH" \
	  KLMS_SHARED_COURSE_PAGES_JSON="$KLMS_SHARED_COURSE_PAGES_JSON" \
	  KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON="$KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON" \
	  KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="$KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON" \
	  /bin/zsh "$script_path" "$CONFIG_PATH"
  ) || job_status=$?
  finished_epoch="$(date +%s)"
  print -r -- "== $job_name finish $(date '+%Y-%m-%d %H:%M:%S %Z') status=$job_status duration_s=$((finished_epoch - started_epoch)) =="
  return "$job_status"
}

run_serial_job core ./sync_klms_core.sh
run_serial_job notice ./sync_klms_notice.sh
run_serial_job files ./refresh_course_files.sh

if [[ "${KLMS_RUNTIME_TMP_CLEANUP_ENABLED:-1}" == "1" ]]; then
  max_age_hours="${KLMS_RUNTIME_TMP_MAX_AGE_HOURS:-24}"
  KLMS_RUNTIME_TMP_CLEANUP_TARGET="$TMP_ROOT_DIR" \
    /bin/zsh "$KLMS_SH_DIR/cleanup_runtime_tmp.sh" --max-age-hours "$max_age_hours" >/dev/null 2>&1 || true
fi
