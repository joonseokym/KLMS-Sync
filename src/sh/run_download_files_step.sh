#!/bin/zsh
set -euo pipefail

if [[ "$#" -lt 9 ]]; then
  print -r -- "usage: run_download_files_step.sh script manifest output-root download-log archive-root result-json timeout max-attempts retry-delay [force]" >&2
  exit 64
fi

SCRIPT_PATH="$1"
MANIFEST_JSON="$2"
OUTPUT_ROOT="$3"
DOWNLOAD_LOG_JSON="$4"
DOWNLOAD_ARCHIVE_ROOT="$5"
DOWNLOAD_RESULT_JSON="$6"
TIMEOUT_SECONDS="$7"
MAX_ATTEMPTS="$8"
RETRY_DELAY_SECONDS="$9"
FORCE_DOWNLOAD="${10:-0}"

download_args=(
  /usr/bin/osascript
  -l
  JavaScript
  "$SCRIPT_PATH"
  "--manifest=$MANIFEST_JSON"
  "--output-root=$OUTPUT_ROOT"
  "--download-log=$DOWNLOAD_LOG_JSON"
  "--download-archive-root=$DOWNLOAD_ARCHIVE_ROOT"
  "--result-json=$DOWNLOAD_RESULT_JSON"
  "--timeout=$TIMEOUT_SECONDS"
  "--max-file-attempts=$MAX_ATTEMPTS"
  "--retry-delay-seconds=$RETRY_DELAY_SECONDS"
)

case "${FORCE_DOWNLOAD:l}" in
  1|true|yes|on)
    download_args+=("--force-download")
    ;;
esac

"${download_args[@]}"
