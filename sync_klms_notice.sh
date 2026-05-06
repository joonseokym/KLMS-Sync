#!/bin/zsh

set -euo pipefail

COMMON_SH="$(cd "$(dirname "$0")" && pwd)/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$0" "${1:-}"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT
klms_require_login
sync_output="$(klms_run_sync_scope notice)"
print -r -- "$sync_output"
if [[ "$sync_output" != status=ok* && "$sync_output" != status=skipped* ]]; then
  exit 1
fi
klms_cleanup_runtime_tmp_if_enabled
